-- Production progression-only behavior, plus retained offline feedback research.
local source=assert(arg[1])
local M=assert(loadfile(source..'/dynamic_spawn.lua'))()()
local count=0
local function pass(name) count=count+1;print('PASS: '..name) end
local function near(a,b) return math.abs(a-b)<1e-6 end
local req={count=3,size=2,rate=6}
local warn={s70=55,h=70,components=100}
local high={s70=62,h=80,components=100}
local low={s70=49,h=79,components=100}
local c=M.controller()
local v=c.step(req,warn,1,true);assert(v.count==3)
v=c.step(req,warn,1,true);assert(v.count==3)
v=c.step(req,warn,1,true)
assert(near(v.count,2.96) and near(v.size,1.98) and v.rate==6)
pass('55 warning requires three valid samples and removes proportional extras')
for _=1,80 do v=c.step(req,warn,1,true) end
assert(v.count==1 and v.size==1 and v.rate==6)
for _=1,2 do v=c.step(req,high,1,true);assert(v.rate==6) end
v=c.step(req,high,1,true);assert(near(v.rate,5.95))
assert(req.count==3 and req.size==2 and req.rate==6)
pass('warning never slows rate; sustained 62 slows only after quantities reach 1x')
for _=1,9 do v=c.step(req,low,1,true);assert(v.count==1 and near(v.rate,5.95)) end
v=c.step(req,low,1,true);assert(near(v.count,1.1) and near(v.size,1.1) and v.rate==6)
for _=1,100 do v=c.step(req,low,1,true) end
assert(v.count==3 and v.size==2 and v.rate==6)
pass('10 seconds of continuous low pressure precedes bounded gradual recovery')
c.reset()
for _=1,2 do c.step(req,high,1,true) end
v=c.step(req,nil,1,true);assert(v.phase=='unknown')
for _=1,2 do v=c.step(req,high,1,true);assert(v.count==3) end
v=c.step(req,high,1,true);assert(v.count<3)
local held=v.count
for _=1,9 do c.step(req,low,1,true) end
c.step(req,nil,1,true)
for _=1,9 do v=c.step(req,low,1,true);assert(v.count==held) end
v=c.step(req,{s70=50,h=79},1,true);assert(v.count==held)
pass('invalid samples and hysteresis reset continuity and never cause recovery')
c.reset()
for _=1,3 do v=c.step(req,{s70=54,h=84},1,true) end
assert(v.count==3)
for _=1,3 do v=c.step(req,{s70=0,h=85},1,true) end
assert(v.count<3 and v.rate==6)
for _=1,1000 do v=c.step(req,high,1,true) end
assert(v.count==1 and v.size==1 and v.rate==1)
v=c.step({count=0.1,size=0.5,rate=1},high,1,true)
assert(v.count==0.1 and v.size==0.5 and v.rate==1)
v=c.step(req,nil,1,false);assert(v.count==3 and v.size==2 and v.rate==6)
pass('85 triggers independently; floors respect user values below 1; disabling restores')

local function bytes(n,size)
    local t={};for i=1,size do t[i]=string.char(n%256);n=math.floor(n/256) end
    return table.concat(t)
end
local game,dir,mode,pop,registry=0x10000000,0x20000000,0x30000000,0x40000000,0x50000000
local patch={mode_rva=0x100,director_rva=0x108,cfg_handle_offset=0x638,
    dynamic_spawn_enabled=true,modifier_patrol_count=3,modifier_travelers_max_unit=2,modifier_patrol_cooldown=6}
local mem={}
mem[game+patch.mode_rva]=bytes(mode,8);mem[game+patch.director_rva]=bytes(dir,8)
mem[game+0x3326D18]=bytes(pop,8);mem[game+0x33264D8]=bytes(registry,8)
mem[mode+8]=bytes(1,4);mem[dir+0x680]=bytes(1,4);mem[dir+0x638]=bytes(0x60000000,8)
mem[dir+0x36C0]=bytes(10,4);mem[dir+0x61C]=bytes(2,4)..bytes(3,4)
mem[pop+0x1C]=bytes(57,4);mem[registry+0xC]=bytes(100,4)
local reads,queries,total=0,0,0
local fail,changing,identity_change,protect=nil,false,false,4
local seen={}
local api={distance=function(a,b) return a-b end,
    pointer=function(b)
        local n=0;for i=8,1,-1 do n=n*256+b:byte(i) end
        return n>=0x10000 and n<0x800000000000 and n or nil
    end,
    query_region=function(p)
        queries=queries+1
        local base=math.floor(p/0x10000000)*0x10000000
        return base,0x08000000,0x1000,protect
    end,
    read=function(p,n)
        reads=reads+1;total=total+n;seen[p]=(seen[p] or 0)+1
        if p==fail then return nil end
        if changing and p==dir+0x36C0 and seen[p]>1 then return bytes(11,4) end
        if identity_change and p==game+patch.mode_rva and seen[p]>1 then return bytes(mode+0x1000,8) end
        local b=mem[p];return b and #b==n and b or nil
    end,
    write=function() error('pressure sampler must NEVER write') end,
}
local progression=M.create(api,patch,true)
for _=1,200 do
    local effective=progression.update(game,dir,1)
    assert(effective.count==3 and effective.size==2 and effective.rate==6)
    assert(effective.phase=='progression_only' and progression.progress_enabled)
    assert(progression.sample==nil and progression.elapsed==0)
end
assert(reads==0 and queries==0 and total==0)
pass('production profile preserves requested patrol multipliers indefinitely without pressure sampling')
patch.modifier_patrol_count,patch.modifier_travelers_max_unit,patch.modifier_patrol_cooldown=5,1.8,4
progression.update(game,dir,0)
assert(progression.effective.count==5 and progression.effective.size==1.8 and progression.effective.rate==4)
patch.dynamic_spawn_enabled=false;progression.update(game,dir,1)
assert(not progression.progress_enabled and progression.effective.phase=='off')
patch.dynamic_spawn_enabled=true;progression.update(game,dir,0.1)
assert(progression.progress_enabled and progression.effective.phase=='progression_only')
progression.update(game,dir+0x1000,1)
assert(progression.owner==dir+0x1000 and progression.progress_enabled and progression.sample==nil)
local unknown=M.create(api,patch,false);unknown.update(game,dir,1)
assert(not unknown.progress_enabled and unknown.effective.phase=='unsupported_build')
assert(unknown.effective.count==5 and reads==0 and queries==0)
progression.reset();assert(progression.effective==nil and not progression.progress_enabled)
patch.modifier_patrol_count,patch.modifier_travelers_max_unit,patch.modifier_patrol_cooldown=3,2,6
pass('progression-only changes follow user settings immediately; toggle, owner, build and reset stay isolated')
-- Explicit opt-in below exists only to keep prior research regression coverage.
local s=M.create(api,patch,true,true)
for _=1,9 do s.update(game,dir,0.1) end
assert(reads==0 and queries==0)
s.update(game,dir,0.1)
assert(s.sample.s70==62 and s.sample.h==67 and s.sample.p==3 and s.sample.e==2)
assert(reads==21 and total==128 and queries==5,reads..'/'..total..'/'..queries)
local initial_reads=reads
for _=1,9 do s.update(game,dir,0.1) end
assert(reads==initial_reads)
pass('1 Hz sampler reads 128 bytes in 21 bounded reads and five region queries, without writes')
local function tick() seen={};s.update(game,dir,1) end
fail=pop+0x1C;tick();assert(s.sample==nil and s.effective.phase=='unknown');fail=nil
changing=true;tick();assert(s.sample==nil);changing=false
identity_change=true;tick();assert(s.sample==nil);identity_change=false
protect=0x104;tick();assert(s.sample==nil);protect=4
mem[dir+0x36C0]=bytes(0xffffffff,4);tick();assert(s.sample==nil)
mem[dir+0x36C0]=bytes(1,4)
mem[dir+0x61C]=bytes(2,4)..bytes(3,4);mem[pop+0x1C]=bytes(0,4)
tick();assert(s.sample.s70==-4)
pass('missing, racing, changed-identity, guarded and invalid reads fail closed; signed math preserved')
patch.dynamic_spawn_enabled=false;initial_reads=reads;tick()
assert(reads==initial_reads and not s.progress_enabled and s.effective.count==3)
patch.dynamic_spawn_enabled=true
local unsupported=M.create(api,patch,false);unsupported.update(game,dir,1)
assert(reads==initial_reads and not unsupported.progress_enabled)
s.reset();assert(s.sample==nil and s.effective==nil and not s.progress_enabled)
pass('disabled, unsupported and reset sessions perform no sampling or compensation')
print(count..' dynamic spawn checks passed; synthetic only, no game accessed.')
