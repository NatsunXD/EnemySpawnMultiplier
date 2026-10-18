-- LOCAL TEST ONLY / combined spawn-guard controller.
-- H=Q+B and S70 are sampled at 1 Hz only (no high-frequency scans).
-- Request spacing is always on; mission/gate/soft-pop are optional under the master switch.
return function()
    local M={mode='local_h100_test'}
    local function delta(dt)
        return type(dt)=='number' and dt==dt and math.max(0,math.min(dt,1)) or 0
    end
    local function bonus_floor(user,keep)
        if user>1 then return 1+(user-1)*keep end
        return user
    end
    local function lerp(a,b,t) return a+(b-a)*math.max(0,math.min(1,t)) end

    -- Legacy local-test controller (non-combined builds).
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
                end
            elseif sampled then
                if h then
                    c.high=h>95 and c.high+1 or 0
                    if h>100 or c.high>=3 then
                        c.high=0;c.remaining=10
                        event='trigger: H='..tostring(h)..(h>100 and ' above native gate' or ' 3 samples >95')
                    end
                else c.high=0 end
            end
            local active=c.remaining>0
            if smooth and active then
                local recovery=math.max(0,math.min(1,(20-c.remaining)/20))
                local rate_recovery=math.max(0,math.min(1,(4-c.rate_remaining)/4))
                local count=bonus_floor(request.count,0.1)
                local size=bonus_floor(request.size,0.1)
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

    -- Combined spawn-guard: S70 gate + raised H soft pop + always-on request spacing.
    function M.guard_controller()
        local c={
            h_high=0,h_remaining=0,h_rate_remaining=0,
            s70_high=0,s70_hard=false,
            held_count=nil,held_size=nil,held_rate=nil,
            boost_cooldown=0,
        }
        local out={}
        -- Tunables (1 Hz sampling; no extra scans).
        local H_TRIGGER,H_CONFIRM,H_HOLD,H_RATE_HOLD,H_RATE_RECOVER=200,3,20,6,4
        local H_KEEP,H_RATE_FACTOR=0.80,0.92
        -- Ride the patrol gate: full below 64, proportional trim through 74, emergency at >=78.
        local S70_SOFT,S70_FLOAT_HI,S70_HARD,S70_RELEASE,S70_CONFIRM=64,74,78,68,2
        local S70_FLOAT_COUNT_MIN,S70_FLOAT_SIZE_MIN,S70_FLOAT_RATE_MIN=0.50,0.32,0.82
        local SPACING=0.5

        function c.reset()
            c.h_high,c.h_remaining,c.h_rate_remaining=0,0,0
            c.s70_high,c.s70_hard=0,false
            c.held_count,c.held_size,c.held_rate=nil,nil,nil
            c.boost_cooldown=0
        end

        function c.step(request,sample,dt,flags,sampled)
            flags=flags or {}
            local master=flags.master==true
            local use_gate=master and flags.patrol_gate~=false
            local use_soft=master and flags.soft_pop~=false
            local event,gate_event
            local count,size,rate=request.count,request.size,request.rate
            local s70=sample and sample.s70
            local h=sample and sample.h

            -- --- Patrol gate throttle (S70), primary anti-crash ---
            if use_gate then
                if sampled then
                    if s70 and s70>=S70_HARD then
                        c.s70_high=c.s70_high+1
                        if c.s70_high>=S70_CONFIRM then
                            if not c.s70_hard then gate_event='patrol_gate_hard: S70='..tostring(s70) end
                            c.s70_hard=true
                        end
                    else
                        c.s70_high=0
                        if c.s70_hard and s70 and s70<=S70_RELEASE then
                            c.s70_hard=false
                            gate_event='patrol_gate_release: S70='..tostring(s70)
                        elseif c.s70_hard and not s70 then
                            -- Invalid sample: keep hard latch; do not release on bad reads.
                        end
                    end
                end
                if c.s70_hard then
                    count,size=1,1
                    rate=math.max(1,request.rate*0.5)
                    out.gate_phase='patrol_gate_hard'
                elseif s70 and s70>=S70_SOFT then
                    local span=S70_FLOAT_HI-S70_SOFT
                    local t=(s70-S70_SOFT)/span
                    if t>1 then t=1 end
                    local keep_c=1+(S70_FLOAT_COUNT_MIN-1)*t
                    local keep_s=1+(S70_FLOAT_SIZE_MIN-1)*t
                    local keep_r=1+(S70_FLOAT_RATE_MIN-1)*t
                    count=bonus_floor(request.count,keep_c)
                    size=bonus_floor(request.size,keep_s)
                    rate=request.rate*keep_r
                    out.gate_phase='patrol_gate_soft'
                else
                    out.gate_phase=use_gate and 'patrol_gate_open' or 'patrol_gate_off'
                end
            else
                c.s70_high,c.s70_hard=0,false
                out.gate_phase='patrol_gate_off'
            end

            -- --- Total population soft limit (raised H threshold) ---
            if use_soft then
                local was=c.h_remaining>0
                c.h_remaining=math.max(0,c.h_remaining-delta(dt))
                c.h_rate_remaining=math.max(0,c.h_rate_remaining-delta(dt))
                if c.h_rate_remaining<1e-6 then c.h_rate_remaining=0 end
                if sampled then
                    c.h_high=h and h>H_TRIGGER and c.h_high+1 or 0
                    if c.h_high>=H_CONFIRM then
                        c.h_high=0
                        c.h_remaining=H_HOLD
                        c.h_rate_remaining=H_RATE_HOLD+H_RATE_RECOVER
                        event=(was and 'retrigger: H=' or 'trigger: H=')..tostring(h)
                            ..' 3 samples >'..tostring(H_TRIGGER)
                    end
                end
                if c.h_remaining<1e-6 then
                    c.h_remaining=0
                    if was and not event then event='restored: '..tostring(H_HOLD)..'s elapsed' end
                end
                if c.h_remaining>0 then
                    local recovery=math.max(0,math.min(1,(H_HOLD-c.h_remaining)/H_HOLD))
                    local rate_recovery=math.max(0,math.min(1,(H_RATE_RECOVER-c.h_rate_remaining)/H_RATE_RECOVER))
                    if c.h_rate_remaining>H_RATE_RECOVER then rate_recovery=0 end
                    local floor_c=bonus_floor(count,H_KEEP)
                    local floor_s=bonus_floor(size,H_KEEP)
                    local floor_r=rate*H_RATE_FACTOR
                    count=lerp(floor_c,count,recovery)
                    size=lerp(floor_s,size,recovery)
                    rate=lerp(floor_r,rate,rate_recovery)
                    out.soft_phase=c.h_rate_remaining<=H_RATE_RECOVER and 'soft_pop_recover' or 'soft_pop_hold'
                else
                    out.soft_phase=use_soft and 'soft_pop_watch' or 'soft_pop_off'
                end
            else
                c.h_high,c.h_remaining,c.h_rate_remaining=0,0,0
                out.soft_phase='soft_pop_off'
            end

            -- --- Always-on request spacing (increases only; shared cooldown) ---
            c.boost_cooldown=math.max(0,(c.boost_cooldown or 0)-delta(dt))
            if not master then count,size,rate=request.count,request.size,request.rate end
            local rising=(c.held_count and count>c.held_count+1e-6)
                or (c.held_size and size>c.held_size+1e-6)
                or (c.held_rate and rate>c.held_rate+1e-6)
                or (not c.held_count and not c.held_size and not c.held_rate)
            if c.held_count and rising and c.boost_cooldown>1e-6 then
                count,size,rate=c.held_count,c.held_size,c.held_rate
            elseif rising and (c.held_count or c.held_size or c.held_rate) then
                if c.held_count and count>c.held_count then
                    count=math.min(count,c.held_count+math.max(0.05,(count-c.held_count)*0.5))
                end
                if c.held_size and size>c.held_size then
                    size=math.min(size,c.held_size+math.max(0.05,(size-c.held_size)*0.5))
                end
                if c.held_rate and rate>c.held_rate then
                    rate=math.min(rate,c.held_rate+math.max(0.05,(rate-c.held_rate)*0.5))
                end
                c.boost_cooldown=SPACING
            end
            c.held_count,c.held_size,c.held_rate=count,size,rate

            out.count,out.size,out.rate=count,size,rate
            out.remaining=c.h_remaining
            out.rate_remaining=c.h_rate_remaining
            out.s70_hard=c.s70_hard
            if not master then
                out.phase='spacing_only'
            elseif c.s70_hard then
                out.phase='patrol_gate_hard'
            elseif c.h_remaining>0 then
                out.phase=out.soft_phase
            elseif out.gate_phase=='patrol_gate_soft' then
                out.phase='patrol_gate_soft'
            else
                out.phase='spawn_guard_watch'
            end
            return out,event or gate_event
        end
        return c
    end

    function M.create(api,patch,known_build)
        local combined=patch.dynamic_combined_switch==true
        local c=combined and M.guard_controller() or M.controller(combined)
        local s={mode=combined and 'spawn_guard' or M.mode,
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
            local pe=read(dir+0x61C,8)
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
            local master=known_build==true and patch.dynamic_spawn_enabled~=false
            local guard_mission=patch.guard_mission~=false
            local guard_gate=patch.guard_patrol_gate~=false
            local guard_soft=patch.guard_soft_pop~=false
            -- Mission/extract protection follows master + sub-toggle.
            if combined then
                s.progress_enabled=master and guard_mission
            else
                s.progress_enabled=known_build==true and (not patch.dynamic_combined_switch or patch.dynamic_spawn_enabled)
            end
            local enabled=known_build==true and patch.dynamic_spawn_enabled~=false
            local sampled=false
            if known_build then
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
            if combined then
                s.effective,event=c.step(request,s.sample,dt,{
                    master=master,patrol_gate=guard_gate,soft_pop=guard_soft,
                },sampled)
            else
                s.effective,event=c.step(request,s.sample and s.sample.h,dt,enabled,sampled)
            end
            if event then s.event=event end
            if event and (event:find('restored:',1,true) or event:find('patrol_gate_release',1,true)) then
                s.elapsed=0
            end
            if combined and not master then
                -- keep spacing_only phase from controller
            elseif not combined and patch.dynamic_combined_switch and not patch.dynamic_spawn_enabled then
                s.effective.phase='off'
            end
            if not known_build then s.effective.phase='unsupported_build' end
            return s.effective
        end
        return s
    end
    return M
end
