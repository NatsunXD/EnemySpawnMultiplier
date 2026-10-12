-- Deterministic accounting: synthetic callback costs and in-memory file I/O.
local source = assert(arg[1])
local function start(fail_io)
    local clock, opens, closes, statuses, writes = 0, 0, 0, 0, {}
    local clock_reads, native_reads = 0, 0
    local env = setmetatable({print=function() end}, {__index=_G})
    env._G=env
    env.os={getenv=function(name) return name=='LOCALAPPDATA' and 'offline-log' or nil end,
        clock=function() clock_reads=clock_reads+1; return clock end}
    env.io={open=function()
        opens=opens+1
        if fail_io then error('simulated disk failure') end
        return {seek=function() return 1 end,
            write=function(_,bytes) writes[#writes+1]=bytes; clock=clock+0.002 end,
            close=function() closes=closes+1 end}
    end}
    local callback_calls=0
    env.update=function(dt,a,b,c)
        clock=clock+0.100 -- previous hook must be excluded from ESM time
        callback_calls=callback_calls+1
        return a,b,c
    end
    local patch={detail='',in_mission=function() return true end,
        apply=function() clock=clock+0.001; return true,'active',true end}
    local changing=0
    local corpse={update=function() clock=clock+0.006;changing=changing+59 end,
        status=function()
            statuses=statuses+1
            return {enabled=true,mode='seed',located=true,epoch=1,reason='applied=0 already=100 skipped=0',
                decayer_already=changing,applied=0,already=100,skipped=0}
        end}
    local chunk=assert(loadfile(source..'/archive_loader.lua'));setfenv(chunk,env)
    chunk()(function() return {module=function(name) return name and 0x100000 or 0x200000 end,
        module_hash=function(address) return address==0x100000 and 'game' or 'exe' end,
        read=function(address,size)
            native_reads=native_reads+1
            if address==0x100000+0x33264D8 and size==8 then return 'pointer!' end
            if address==0x300000+0x0c and size==4 then return string.char(116,0,0,0) end
        end,
        pointer=function(bytes) return bytes=='pointer!' and 0x300000 or nil end} end,patch,
        {revision='offline',exe_sha256='exe',game_sha256='game'},nil,nil,nil,nil,nil,nil,
        function() return corpse end)
    return env,function() return opens,closes,table.concat(writes),clock_reads,statuses,callback_calls,native_reads end
end

local env,counts=start(false)
for _=1,3600 do
    local a,b,c=env.update(1/60,'first',nil,'third')
    assert(a=='first' and b==nil and c=='third','update tuple changed')
end
local opens,closes,output,clocks,statuses,previous,native_reads=counts()
local bb=env.EnemySpawnMultiplier.blackbox
assert(opens<=12 and opens==closes,'file batching budget exceeded: '..opens)
assert(clocks<=8500,'more than 2 clocks/frame + 2 clocks/patch tick: '..clocks)
assert(statuses<=120,'corpse status was polled at frame frequency')
assert(previous==3600)
assert(native_reads<=4 and bb.component_gate_count==116,'component diagnostic exceeded two reads per summary')
assert(bb.last_total_ms>=5.9 and bb.last_total_ms<20,'full ESM cost missing or previous hook included: '..tostring(bb.last_total_ms))
assert(bb.suppressed>3000,'slow frames were not suppressed')
local _,alerts=output:gsub('bb_alert','')
local _,corpse=output:gsub('corpse_status','')
assert(alerts<=48 and corpse==1,'changing counters or sustained lag spammed logs')
assert(output:find('bb_summary',1,true),'missing low-frequency full-cost summary')
print(string.format('PASS: blackbox 60s/3600 frames: batches=%d alerts=%d corpse_lines=%d clocks=%d status_reads=%d',
    opens,alerts,corpse,clocks,statuses))

local state=env.EnemySpawnMultiplier
for i=1,1000 do state.log('flood',string.rep('x',10000)) end
assert(bb.dropped>=968,'bounded queue did not reject overflow')
state.flush_log()
local _,_,overflow=counts()
assert(#overflow-#output<=16*1024+1024,'flush exceeded bounded queue bytes')
print('PASS: log overflow is bounded and counted')

local failed,failure_counts=start(true)
for _=1,3600 do assert(failed.update(1/60,'alive')=='alive') end
local failures=failure_counts()
assert(failures<=12,'disk failure retried at frame frequency')
assert(failed.EnemySpawnMultiplier.blackbox.dropped>0)
print('PASS: disk exceptions preserve callback chain and five-second retry budget')
