-- LOCAL TEST ONLY. Selected explicitly by the builder; absent from normal ZIPs.
-- H=Q+B is the ONLY control input. S70 is diagnostic only; no native calls/writes.
return function()
    local M={mode='local_h100_test'}
    local function delta(dt)
        return type(dt)=='number' and dt==dt and math.max(0,math.min(dt,1)) or 0
    end
    function M.controller(smooth)
        local c={high=0,remaining=0,rate_remaining=0}
        local out={}
        function c.reset() c.high,c.remaining,c.rate_remaining=0,0,0 end
        function c.step(request,h,dt,enabled,sampled)
            local event
            if not enabled then
                if c.remaining>0 then event='cancelled: switch off' end
                c.reset()
            elseif smooth then
                local was_active=c.remaining>0
                c.remaining=math.max(0,c.remaining-delta(dt))
                c.rate_remaining=math.max(0,c.rate_remaining-delta(dt))
                if c.rate_remaining<1e-6 then c.rate_remaining=0 end
                if sampled then
                    c.high=h and h>100 and c.high+1 or 0
                    if c.high>=3 then
                        c.high=0;c.remaining=20;c.rate_remaining=10
                        event=(was_active and 'retrigger: H=' or 'trigger: H=')..tostring(h)
                            ..' 3 samples >100'
                    end
                end
                if c.remaining<1e-6 then
                    c.remaining=0
                    if was_active and not event then event='restored: 20s elapsed' end
                end
            elseif c.remaining>0 then
                c.remaining=math.max(0,c.remaining-delta(dt))
                if c.remaining<1e-6 then
                    c.remaining=0;c.high=0;event='restored: 10s elapsed'
                end -- Never extend or retrigger an active hold.
            elseif sampled then
                if h then
                    c.high=h>95 and c.high+1 or 0
                    if h>100 or c.high>=3 then
                        c.high=0;c.remaining=10
                        event='trigger: H='..tostring(h)..(h>100 and ' above native gate' or ' 3 samples >95')
                    end
                else c.high=0 end -- Invalid reads break confirmation.
            end
            local active=c.remaining>0
            if smooth and active then
                local recovery=math.max(0,math.min(1,(20-c.remaining)/20))
                local rate_recovery=math.max(0,math.min(1,(4-c.rate_remaining)/4))
                -- Only the bonus above 1 is reduced; sub-1 user settings stay
                -- below 1. Recompute from current user values, never our output.
                local count=request.count>1 and 1+(request.count-1)*0.1 or request.count
                local size=request.size>1 and 1+(request.size-1)*0.1 or request.size
                local rate=request.rate*0.75
                out.count=count+(request.count-count)*recovery
                out.size=size+(request.size-size)*recovery
                out.rate=rate+(request.rate-rate)*rate_recovery
            else
                out.count=active and 1 or request.count
                out.size=active and 1 or request.size
                out.rate=active and request.rate*0.5 or request.rate
            end
            out.phase=active and (smooth and c.rate_remaining<=4 and 'local_h100_recover' or 'local_h100_hold')
                or enabled and 'local_h100_watch' or 'progression_only'
            out.remaining=c.remaining
            out.rate_remaining=c.rate_remaining
            return out,event
        end
        return c
    end
    function M.create(api,patch,known_build)
        local c=M.controller(patch.dynamic_combined_switch==true)
        local s={mode=patch.dynamic_combined_switch and 'h100_compensation' or M.mode,
            owner=nil,elapsed=0,sample=nil,effective=nil,progress_enabled=false}
        local request,regions={},{}
        local function same(a,b) return a and b and api.distance(a,b)==0 end
        local function read(p,n)
            if not p then return nil end
            local found
            for _,r in ipairs(regions) do
                local off=api.distance(p,r.base)
                if off>=0 and off+n<=r.size then found=true;break end
            end
            if not found then
                local base,size,state,protect=api.query_region(p)
                if not base or state~=0x1000 or protect==1 or protect%512>=256 then return nil end
                local off=api.distance(p,base)
                if off<0 or off+n>size then return nil end
                regions[#regions+1]={base=base,size=size}
            end
            local b=api.read(p,n);return b and #b==n and b or nil
        end
        local function pointer(p) local b=read(p,8);return b and api.pointer(b) end
        local function u32(b)
            local a,x,y,z=b:byte(1,4);return a+x*256+y*65536+z*16777216
        end
        local function snapshot(game,dir)
            regions={}
            local mode=pointer(game+patch.mode_rva)
            local pop=pointer(game+0x3326D18)
            local active=mode and read(mode+8,4)
            local live=read(dir+0x680,4)
            local cfg=read(dir+patch.cfg_handle_offset,8)
            local q,b=read(dir+0x36C0,4),pop and read(pop+0x1C,4)
            local pe=read(dir+0x61C,8) -- S70 logging only.
            if not (active and live and cfg and q and b and pe) or u32(active)==0 or u32(live)==0 then return nil end
            if not same(pointer(game+patch.director_rva),dir)
                or not same(pointer(game+patch.mode_rva),mode)
                or not same(pointer(game+0x3326D18),pop)
                or read(mode+8,4)~=active or read(dir+0x680,4)~=live
                or read(dir+patch.cfg_handle_offset,8)~=cfg
                or read(dir+0x36C0,4)~=q or read(pop+0x1C,4)~=b
                or read(dir+0x61C,8)~=pe then return nil end
            local Q,B,E,P=u32(q),u32(b),u32(pe:sub(1,4)),u32(pe:sub(5,8))
            if Q>65536 or B>65536 or E>65536 or P>65536 then return nil end
            local v=(Q+B-P-E)%4294967296;if v>=2147483648 then v=v-4294967296 end
            return {q=Q,b=B,p=P,e=E,h=(Q+B)%4294967296,s70=v}
        end
        function s.reset()
            c.reset();s.owner=nil;s.elapsed=0;s.sample=nil;s.effective=nil
            s.progress_enabled=false;s.event=nil;s.observation_event=nil
            s.cross70,s.cross100=false,false
            s.stats={valid=0,invalid=0,s70_ge70=0,h_gt95=0,h_gt100=0,peak_s70=nil,peak_h=nil}
        end
        function s.update(game,dir,dt)
            if not same(s.owner,dir) then s.reset();s.owner=dir end
            request.count,request.size,request.rate=patch.modifier_patrol_count,patch.modifier_travelers_max_unit,patch.modifier_patrol_cooldown
            -- The combined build couples both features; legacy test stays isolated.
            s.progress_enabled=known_build==true and (not patch.dynamic_combined_switch or patch.dynamic_spawn_enabled)
            local enabled=known_build==true and patch.dynamic_spawn_enabled
            local sampled=false
            if known_build then -- Diagnose both gates even with the compensation switch OFF.
                s.elapsed=s.elapsed+delta(dt)
                if s.elapsed>=1-1e-9 then
                    s.elapsed=0;sampled=true
                    local ok,value=pcall(snapshot,game,dir);s.sample=ok and value or nil
                    local stats=s.stats
                    if s.sample then
                        local v=s.sample
                        stats.valid=stats.valid+1
                        stats.peak_s70=math.max(stats.peak_s70 or v.s70,v.s70)
                        stats.peak_h=math.max(stats.peak_h or v.h,v.h)
                        if v.s70>=70 then stats.s70_ge70=stats.s70_ge70+1 end
                        if v.h>95 then stats.h_gt95=stats.h_gt95+1 end
                        if v.h>100 then stats.h_gt100=stats.h_gt100+1 end
                        if (v.s70>=70 and not s.cross70) or (v.h>100 and not s.cross100) then
                            s.observation_event='S70='..v.s70..' H='..v.h..' gate_condition_only'
                        end
                        s.cross70,s.cross100=v.s70>=70,v.h>100
                    else stats.invalid=stats.invalid+1 end
                end
            else s.elapsed=0;s.sample=nil end
            local event
            s.effective,event=c.step(request,s.sample and s.sample.h,dt,enabled,sampled)
            if event then s.event=event end
            if event=='restored: 10s elapsed' or event=='restored: 20s elapsed' then s.elapsed=0 end
            if patch.dynamic_combined_switch and not patch.dynamic_spawn_enabled then s.effective.phase='off' end
            if not known_build then s.effective.phase='unsupported_build' end
            return s.effective
        end
        return s
    end
    return M
end
