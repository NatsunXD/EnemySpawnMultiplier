-- Progression-only by default. Pressure feedback retained for offline research.
return function()
    local M = {}
    local function approach(value,target,step)
        if value<target then return math.min(target,value+step) end
        return math.max(target,value-step)
    end
    function M.controller()
        local c={count=nil,size=nil,rate=nil,low=0,high=0,severe=0,phase='idle'}
        local output={}
        function c.reset()
            c.count,c.size,c.rate=nil,nil,nil;c.low,c.high,c.severe=0,0,0;c.phase='idle'
        end
        function c.step(request,sample,dt,enabled)
            dt=type(dt)=='number' and dt==dt and math.max(0,math.min(dt,1)) or 0
            local fc,fs=math.min(1,request.count),math.min(1,request.size)
            c.count=math.min(request.count,math.max(fc,c.count or request.count))
            c.size=math.min(request.size,math.max(fs,c.size or request.size))
            local fr=math.min(1,request.rate)
            c.rate=math.min(request.rate,math.max(fr,c.rate or request.rate))
            if not enabled then
                c.count,c.size,c.rate=request.count,request.size,request.rate;c.low,c.high,c.severe=0,0,0;c.phase='off'
            elseif dt==0 then
                -- No extra samples or timer changes between the one-second ticks.
            elseif not sample then
                c.low,c.high,c.severe=0,0,0;c.phase='unknown' -- No recovery from failed reads.
            else
                local warning=sample.s70>=55 or sample.h>=85
                local severe=sample.s70>=62 or sample.h>=85
                local low=sample.s70<50 and sample.h<80
                if warning then
                    c.low=0;c.high=c.high+1
                    if c.high>=3 then
                        if c.count>fc+1e-6 or c.size>fs+1e-6 then
                            c.phase='reduce_size_count';c.severe=0
                            -- Remove 2..5% of the requested EXTRA multiplier per
                            -- second, proportionally for both controls.
                            local pressure=math.max((sample.s70-55)/15,(sample.h-85)/15)
                            local speed=0.02+0.03*math.max(0,math.min(pressure,1))
                            c.count=approach(c.count,fc,(request.count-fc)*speed*dt)
                            c.size=approach(c.size,fs,(request.size-fs)*speed*dt)
                            if c.count-fc<1e-6 then c.count=fc end
                            if c.size-fs<1e-6 then c.size=fs end
                        elseif severe then
                            c.severe=c.severe+1;c.phase='confirm_interval'
                            if c.severe>=3 then
                                c.phase='slow_patrol';c.rate=approach(c.rate,fr,0.05*dt)
                            end
                        else c.severe=0;c.phase='warning_hold' end
                    else c.phase='confirm_pressure' end
                elseif low then
                    c.high,c.severe=0,0;c.low=c.low+dt
                    if c.low>=10 then
                        c.phase='recover'
                        c.count=approach(c.count,request.count,0.1*dt)
                        c.size=approach(c.size,request.size,0.1*dt)
                        c.rate=approach(c.rate,request.rate,0.05*dt)
                        if c.count==request.count and c.size==request.size and c.rate==request.rate then c.phase='normal' end
                    else c.phase='low_hold' end
                else c.low,c.high,c.severe=0,0,0;c.phase='hold' end
            end
            output.count,output.size,output.rate=c.count,c.size,c.rate
            output.phase,output.low_seconds=c.phase,c.low
            return output
        end
        return c
    end
    function M.create(api,patch,known_build,pressure_enabled)
        -- Temporary test profile: production omits/sets false for this flag.
        -- No user setting or saved configuration can enable pressure feedback.
        pressure_enabled=pressure_enabled==true
        local c=M.controller()
        local s={elapsed=0,owner=nil,sample=nil,effective=nil,progress_enabled=false}
        local request={}
        local regions={}
        local function same(a,b) return a and b and api.distance(a,b)==0 end
        local function u32(b,o)
            local a,x,y,z=b:byte(o+1,o+4);return a+x*256+y*65536+z*16777216
        end
        local function read(p,n)
            if not p then return nil end
            local found
            for _,r in ipairs(regions) do
                local offset=api.distance(p,r.base)
                if offset>=0 and offset+n<=r.size then found=r;break end
            end
            if not found then
                local a,size,state,protection=api.query_region(p)
                if not a or state~=0x1000 or protection%512>=256 or protection==1
                    or api.distance(p,a)<0 or api.distance(p,a)+n>size then return nil end
                found={base=a,size=size};regions[#regions+1]=found
            end
            local b=api.read(p,n);return b and #b==n and b or nil
        end
        local function pointer(p) local b=read(p,8);return b and api.pointer(b) end
        local function snapshot(game,director)
            regions={} -- Cache only within this snapshot; never across seconds.
            local mode=pointer(game+patch.mode_rva)
            local pop=pointer(game+0x3326D18)
            local registry=pointer(game+0x33264D8)
            local m=mode and read(mode+8,4)
            local active=read(director+0x680,4)
            local cfg=read(director+patch.cfg_handle_offset,8)
            if not m or u32(m,0)==0 or not active or u32(active,0)==0 or not cfg then return nil end
            local q,pe,b,n=read(director+0x36C0,4),read(director+0x61C,8),pop and read(pop+0x1C,4),registry and read(registry+0x0C,4)
            if not (q and pe and b and n) then return nil end
            if not same(pointer(game+patch.director_rva),director) or not same(pointer(game+patch.mode_rva),mode)
                or not same(pointer(game+0x3326D18),pop) or not same(pointer(game+0x33264D8),registry)
                or read(mode+8,4)~=m or read(director+0x680,4)~=active
                or read(director+patch.cfg_handle_offset,8)~=cfg
                or read(director+0x36C0,4)~=q or read(director+0x61C,8)~=pe
                or read(pop+0x1C,4)~=b or read(registry+0x0C,4)~=n then return nil end
            local Q,E,P,B,C=u32(q,0),u32(pe,0),u32(pe,4),u32(b,0),u32(n,0)
            if Q>65536 or E>65536 or P>65536 or B>65536 or C>65536 then return nil end
            local v=(Q+B-P-E)%4294967296;if v>=2147483648 then v=v-4294967296 end
            return {q=Q,p=P,e=E,b=B,components=C,s70=v,h=(Q+B)%4294967296}
        end
        function s.reset()
            c.reset();s.elapsed=0;s.owner=nil;s.sample=nil;s.effective=nil;s.progress_enabled=false
        end
        function s.update(game,director,dt)
            request.count,request.size,request.rate=patch.modifier_patrol_count,patch.modifier_travelers_max_unit,patch.modifier_patrol_cooldown
            if not same(s.owner,director) then s.reset();s.owner=director end
            local enabled=patch.dynamic_spawn_enabled and known_build
            s.progress_enabled=enabled
            if not enabled then
                s.sample=nil;s.effective=c.step(request,nil,0,false)
                s.effective.phase=patch.dynamic_spawn_enabled and 'unsupported_build' or 'off';return s.effective
            end
            if not pressure_enabled then
                s.elapsed=0;s.sample=nil;s.effective=c.step(request,nil,0,false)
                s.effective.phase='progression_only'
                return s.effective
            end
            s.elapsed=s.elapsed+(type(dt)=='number' and dt==dt and math.max(0,math.min(dt,1)) or 0)
            if s.elapsed>=1-1e-9 then
                local elapsed=math.min(s.elapsed,1);s.elapsed=0
                local ok,value=pcall(snapshot,game,director);s.sample=ok and value or nil
                s.effective=c.step(request,s.sample,elapsed,true)
            else
                -- A user lowering a setting takes effect immediately; raising
                -- it cannot bypass a pressure hold between sample ticks.
                s.effective=c.step(request,s.sample,0,true)
            end
            return s.effective
        end
        return s
    end
    return M
end
