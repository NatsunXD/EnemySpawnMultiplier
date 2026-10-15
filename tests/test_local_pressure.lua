local source,build=assert(arg[1]),assert(arg[2])
local factory=assert(loadfile(source..'/experiments/local_pressure.lua'))()
local M=factory()
local n=0
local function pass(s) n=n+1;print('PASS: '..s) end
local request={count=4,size=1.8,rate=6}
local c=M.controller()
local v,event
for _=1,4 do v=c.step(request,95,1,true,true);assert(v.count==4) end
for _=1,2 do v=c.step(request,96,1,true,true);assert(v.count==4) end
v=c.step(request,nil,1,true,true);assert(v.count==4)
for _=1,2 do v=c.step(request,100,1,true,true);assert(v.count==4) end
v,event=c.step(request,100,1,true,true)
assert(v.count==1 and v.size==1 and v.rate==3 and v.remaining==10 and event)
pass('strict >95 needs three consecutive valid samples; 95 and invalid samples reset confirmation')
request.count,request.size,request.rate=2,0.5,1
for _=1,99 do
    v=c.step(request,101,0.1,true,true)
    assert(v.count==1 and v.size==1 and v.rate==0.5)
end
v,event=c.step(request,101,0.1,true,true)
assert(v.count==2 and v.size==0.5 and v.rate==1 and v.remaining==0 and event)
v=c.step(request,96,1,true,true);assert(v.count==2)
v=c.step(request,96,1,true,true);assert(v.count==2)
v=c.step(request,96,1,true,true);assert(v.count==1)
pass('fixed ten-second hold is not prolonged by pressure; restores latest settings and requires fresh confirmation')
v=c.step(request,101,0,true,false);assert(v.remaining==10)
v=c.step(request,nil,0,false,false);assert(v.count==2 and v.rate==1)
v=c.step(request,100,1,true,true);assert(v.count==2)
v,event=c.step(request,101,1,true,true);assert(v.count==1 and event:find('above native gate',1,true))
c.reset();v=c.step(request,0,1,true,true);assert(v.count==2)
pass('single H>100 triggers immediately; switch-off restores without waiting and reset clears holds')

local function near(a,b) return math.abs(a-b)<1e-7 end
local smooth=M.controller(true)
local user={count=4,size=1.8,rate=6}
for _=1,5 do v=smooth.step(user,96,1,true,true);assert(v.remaining==0) end
for _=1,5 do v=smooth.step(user,100,1,true,true);assert(v.remaining==0) end
for _=1,2 do v=smooth.step(user,101,1,true,true);assert(v.remaining==0) end
v=smooth.step(user,100,1,true,true);assert(v.remaining==0)
for _=1,2 do v=smooth.step(user,101,1,true,true);assert(v.remaining==0) end
v=smooth.step(user,nil,1,true,true);assert(v.remaining==0)
for _=1,3 do v,event=smooth.step(user,101,1,true,true) end
assert(near(v.count,1.3) and near(v.size,1.08) and near(v.rate,4.5) and v.remaining==20 and v.rate_remaining==10)
assert(event:find('3 samples >100',1,true))
pass('only three consecutive valid H>100 samples trigger; H=100, 96 and invalid readings reset confirmation; no immediate trigger')
for _=1,60 do v=smooth.step(user,80,0.1,true,false) end
assert(near(v.remaining,14) and near(v.rate_remaining,4) and near(v.count,2.11) and near(v.size,1.296) and near(v.rate,4.5))
for _=1,20 do v=smooth.step(user,80,0.1,true,false) end
assert(v.phase=='local_h100_recover' and near(v.count,2.38) and near(v.size,1.368) and near(v.rate,5.25))
for _=1,20 do v,event=smooth.step(user,80,0.1,true,false) end
assert(near(v.remaining,10) and v.rate_remaining==0 and near(v.count,2.65) and near(v.size,1.44) and v.rate==6 and not event)
for _=1,100 do v,event=smooth.step(user,80,0.1,true,false) end
assert(v.remaining==0 and v.count==4 and v.size==1.8 and v.rate==6 and event=='restored: 20s elapsed')
pass('quantities keep 10% bonus and recover linearly for 20s; rate independently holds 75% for 6s and restores over 4s')
for _=1,2 do v=smooth.step(user,101,0,true,true);assert(v.remaining==0) end
v=smooth.step(user,101,0,true,true);assert(v.remaining==20 and v.rate_remaining==10)
for _=1,7 do v=smooth.step(user,80,1,true,true) end
assert(v.phase=='local_h100_recover')
v,event=smooth.step(user,101,0.1,true,false)
assert(v.remaining<13 and not event,'stale H must not refresh the timer')
for _=1,2 do v,event=smooth.step(user,101,0.1,true,true);assert(v.remaining<20 and not event) end
v,event=smooth.step(user,101,0.1,true,true)
assert(v.remaining==20 and v.rate_remaining==10 and near(v.count,1.3) and event:find('retrigger:',1,true))
for _=1,2 do v=smooth.step(user,101,1,true,true) end
v=smooth.step(user,nil,1,true,true);assert(v.remaining==17)
for _=1,2 do v=smooth.step(user,101,1,true,true);assert(v.remaining<20) end
v,event=smooth.step(user,101,1,true,true)
assert(v.remaining==20 and event:find('retrigger:',1,true))
for _=1,12 do v=smooth.step(user,80,1,true,true) end
assert(v.rate_remaining==0 and near(v.rate,6) and near(v.remaining,8))
for _=1,3 do v,event=smooth.step(user,101,0.1,true,true) end
assert(v.remaining==20 and v.rate_remaining==10 and near(v.rate,4.5) and event:find('retrigger:',1,true))
pass('fresh threshold samples refresh 20s quantity and 10s rate timers, even after rate restored; invalid/stale samples cannot retrigger')
user.count,user.size,user.rate=0.5,0.8,2
v=smooth.step(user,80,0,true,false)
assert(v.count==0.5 and v.size==0.8 and v.rate==1.5)
for _=1,8 do v=smooth.step(user,80,1,true,true) end
user.count,user.size,user.rate=6,2,4
v=smooth.step(user,80,0,true,false)
assert(near(v.count,3.3) and near(v.size,1.46) and near(v.rate,3.5))
v,event=smooth.step(user,101,0,false,true)
assert(v.count==6 and v.size==2 and v.rate==4 and v.remaining==0 and v.rate_remaining==0 and event)
smooth.reset();v=smooth.step(user,80,0,true,false);assert(v.remaining==0)
pass('sub-one quantities never increase; recovery follows latest user settings; OFF and reset restore immediately')

local function bytes(n,size)
    local t={};for i=1,size do t[i]=string.char(n%256);n=math.floor(n/256) end
    return table.concat(t)
end
local game,dir,mode,pop=0x10000000,0x20000000,0x30000000,0x40000000
local patch={mode_rva=0x100,director_rva=0x108,cfg_handle_offset=0x6b0,
    dynamic_spawn_enabled=true,modifier_patrol_count=4,modifier_travelers_max_unit=1.8,modifier_patrol_cooldown=6}
local mem={
    [game+patch.mode_rva]=bytes(mode,8),[game+patch.director_rva]=bytes(dir,8),
    [game+0x3326D18]=bytes(pop,8),[mode+8]=bytes(1,4),[dir+0x680]=bytes(1,4),
    [dir+patch.cfg_handle_offset]=bytes(0x60000000,8),[dir+0x36C0]=bytes(10,4),
    [pop+0x1c]=bytes(70,4),[dir+0x61c]=bytes(0,8),
}
local reads,queries,total=0,0,0
local fail,changing,identity,guard=false,false,false,false
local seen={}
local api={distance=function(a,b) return a-b end,
    pointer=function(b)
        local v=0;for i=8,1,-1 do v=v*256+b:byte(i) end
        return v>=0x10000 and v<0x800000000000 and v or nil
    end,
    query_region=function(p)
        queries=queries+1
        return math.floor(p/0x10000000)*0x10000000,0x08000000,0x1000,guard and 0x104 or 4
    end,
    read=function(p,size)
        assert(p~=game+0x33264d8,'registry diagnostic should not be scanned')
        reads=reads+1;total=total+size;seen[p]=(seen[p] or 0)+1
        if fail and p==pop+0x1c then return nil end
        if changing and p==dir+0x36c0 and seen[p]>1 then return bytes(11,4) end
        if identity and p==game+patch.mode_rva and seen[p]>1 then return bytes(mode+0x1000,8) end
        return mem[p]
    end,
    write=function() error('sampler must never write') end,
}
local s=M.create(api,patch,true)
for _=1,9 do s.update(game,dir,0.1) end
assert(reads==0)
s.update(game,dir,0.1)
assert(reads==17 and queries==4 and total==104,reads..'/'..queries..'/'..total)
assert(s.sample.h==80 and s.sample.s70==80 and s.progress_enabled)
local function tick(dt) seen={};return s.update(game,dir,dt or 1) end
for _=1,6 do tick();assert(s.effective.count==4) end
assert(s.stats.s70_ge70==7 and s.stats.h_gt95==0 and s.stats.peak_s70==80)
pass('coherent 1 Hz diagnostics cost 17 reads / 104 bytes; S70 crossing alone never changes settings')
mem[pop+0x1c]=bytes(86,4)
mem[dir+0x61c]=bytes(20,4)..bytes(10,4)
tick();tick();assert(s.effective.count==4)
tick();assert(s.effective.count==1 and s.effective.size==1 and s.effective.rate==3)
assert(s.sample.s70==66 and s.sample.h==96 and s.stats.h_gt95==3)
local holding_reads=reads
fail=true;tick();assert(s.sample==nil and s.effective.remaining==9)
fail=false
patch.dynamic_spawn_enabled=false;tick()
assert(s.progress_enabled and s.effective.count==4 and s.effective.phase=='progression_only')
assert(reads>holding_reads and s.sample.h==96 and s.stats.invalid==1)
pass('H100 response ignores S70; invalid samples do not extend hold; switch-off keeps progression and diagnostic reads')
local original_reads=reads
local unknown=M.create(api,patch,false);unknown.update(game,dir,1)
assert(reads==original_reads and not unknown.progress_enabled and unknown.sample==nil)
patch.dynamic_spawn_enabled=true
changing=true;tick();assert(s.sample==nil);changing=false
identity=true;tick();assert(s.sample==nil);identity=false
guard=true;tick();assert(s.sample==nil);guard=false
mem[dir+0x36c0]=bytes(0xffffffff,4);tick();assert(s.sample==nil)
mem[dir+0x36c0]=bytes(1,4);mem[pop+0x1c]=bytes(0,4)
tick();assert(s.sample.s70==-29)
mem[dir+0x36c0]=bytes(10,4);mem[pop+0x1c]=bytes(91,4)
tick();assert(s.effective.count==1 and s.stats.h_gt100==1)
mem[dir+0x36c0]=bytes(0,4);mem[pop+0x1c]=bytes(0,4)
for _=1,10 do tick() end
assert(s.effective.count==4 and s.effective.rate==6 and s.progress_enabled)
s.update(game,dir+0x1000,0);assert(s.stats.valid==0 and s.effective.count==4)
s.reset();assert(s.effective==nil and s.sample==nil and not s.progress_enabled)
pass('racing identities, protection, invalid counts fail closed; signed S70, immediate H>100, owner and timer restoration work')
patch.dynamic_combined_switch=true
mem[dir+0x36c0]=bytes(10,4);mem[pop+0x1c]=bytes(91,4)
local combined=M.create(api,patch,true)
for _=1,2 do seen={};combined.update(game,dir,1);assert(combined.effective.count==4) end
seen={};combined.update(game,dir,1)
assert(combined.mode=='h100_compensation' and combined.progress_enabled and near(combined.effective.count,1.3))
patch.dynamic_spawn_enabled=false;seen={};combined.update(game,dir,1)
assert(not combined.progress_enabled and combined.effective.count==4 and combined.effective.rate==6)
assert(combined.effective.phase=='off' and combined.sample.h==101 and combined.stats.valid==4)
patch.dynamic_spawn_enabled=true
for _=1,2 do seen={};combined.update(game,dir,1);assert(combined.effective.count==4) end
seen={};combined.update(game,dir,1)
assert(combined.progress_enabled and near(combined.effective.count,1.3))
patch.dynamic_combined_switch=nil
pass('combined switch disables both compensation paths and cancels hold, while both gate diagnostics continue')

local model_factory=assert(loadfile(source..'/panel_model.lua'))()
local decorate=assert(loadfile(source..'/experiments/local_panel_model.lua'))()
local m=decorate(model_factory)()
assert(m.text('dynamic_spawn')=='软门槛（测试）')
assert(m.text('dynamic_spawn','en')=='Soft limit (test)')
patch.modifier_patrol_count,patch.modifier_travelers_max_unit,patch.modifier_patrol_cooldown=4,1.8,6
patch.budget_multiplier=2;patch.patrol_cooldown_fast_rate=6
patch.dynamic={effective={count=1,size=1,rate=3},progress_enabled=true}
m.sync_from_patch(patch)
assert(m.pending.patrol_count==4 and m.pending.patrol_size==1.8 and m.pending.patrol_cd==2)
assert(m.pending.dynamic_spawn==true)
local file=assert(io.open(build..'/mod.wrapper.lua','r'));local wrapper=file:read('*a');file:close()
assert(wrapper:find('LOCAL TEST ONLY',1,true) and wrapper:find('function M.controller(',1,true))
assert(not wrapper:find('function approach(value,target,step)',1,true),'normal pressure controller leaked into test')
if wrapper:find('patch.dynamic_combined_switch = true',1,true) then
    assert(wrapper:find("patch.dynamic_curve_policy = 'unit_all_half_extraction'",1,true))
    assert(not wrapper:find('create_model = create_local_model(create_model)',1,true))
    assert(not wrapper:find('Soft limit (test)',1,true))
    local original=model_factory()
    assert(original.pending.dynamic_spawn==true)
    assert(original.text('dynamic_spawn')=='动态生成补偿')
    assert(original.text('dynamic_spawn','en')=='Dynamic spawn compensation')
else assert(wrapper:find('create_model = create_local_model(create_model)',1,true)) end
pass('local-only bilingual toggle and runtime module are selected explicitly; effective changes do not move sliders')
print(n..' local soft-limit test checks passed; synthetic only.')
