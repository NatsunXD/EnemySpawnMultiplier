-- Unit tests for the pure SOS gate decisions (no game memory).
local source = assert(arg[1])
local create = assert(loadfile(source .. '/sos_probe.lua'))()
local probe = create()
local count = 0
local function pass(name)
    count = count + 1
    print('PASS: ' .. name)
end

assert(probe.SOS_ID == 3193487269)
assert(probe.find_build(1790161983, 74727424) ~= nil)
assert(probe.find_build(1, 2) == nil)
pass('known build row is present')

local mismatch = probe.interpret({build = 'mismatch'})
assert(mismatch.gate == true and mismatch.unsupported == true)
assert(mismatch.reason == 'sos_probe_build_mismatch')
pass('build mismatch fails closed')

local pending = probe.interpret({build = 'pending'})
assert(pending.gate == false and pending.unsupported == false)
pass('pending build does not gate yet')

local available = probe.interpret({
    build = 'ok', live = true, read_ok = true, sos_present = true, uses = 1,
})
assert(available.gate == false and available.event == 'sos_available')
pass('SOS still available stays open')

local spent = probe.interpret({
    build = 'ok', live = true, read_ok = true, sos_present = true, uses = 0,
})
assert(spent.gate == true and spent.sticky == true)
assert(spent.reason == 'privacy_gate_sos')
pass('spent SOS sticky-gates')

local absent = probe.interpret({
    build = 'ok', live = true, read_ok = true, sos_present = false,
})
assert(absent.gate == false and absent.event == 'sos_absent')
pass('missing SOS slot does not gate')

local fail1 = probe.interpret({
    build = 'ok', live = true, read_ok = false, fail_streak = 0, max_fail = 3,
})
assert(fail1.gate == false and fail1.fail_streak == 1)
local fail3 = probe.interpret({
    build = 'ok', live = true, read_ok = false, fail_streak = 2, max_fail = 3,
})
assert(fail3.gate == true and fail3.unsupported == true)
assert(fail3.reason == 'sos_probe_unreliable')
pass('repeated live read failures fail closed')

local ship = probe.interpret({
    build = 'ok', live = false, read_ok = true, sos_present = true, uses = 0,
})
assert(ship.gate == false and ship.event == 'ship')
pass('ship clears urgency even if uses already zero')

-- Exercise the real reader and session using address-keyed synthetic bytes.
local ffi=require('ffi')
local function pack32(value)
    return ffi.string(ffi.new('uint32_t[1]',value),4)
end
local function pack64(value)
    return ffi.string(ffi.new('uint64_t[1]',value),8)
end
local game,arr,ctx,obj=0x10000000,0x21000000,0x22000000,0x23000000
local layout=probe.find_build(1790161983,74727424)
local peer=pack64(17)
local memory={
    [game]='MZ'..string.rep('\0',58)..pack32(128),
    [game+128]='PE\0\0'..string.rep('\0',4)..pack32(layout.stamp)
        ..string.rep('\0',68)..pack32(layout.image)..string.rep('\0',4),
    [game+layout.arr_off]=pack64(arr),
    [game+layout.peer_ctx]=pack64(ctx),
    [ctx+layout.peer_at]=peer,
    [arr+layout.arr_cnt_at]=pack32(1),
    [arr]=peer,
    [arr+layout.slot_cnt_at]=pack32(1),
    [game+layout.def_root+8]=pack64(obj),
    [obj+layout.id_at]=pack32(probe.SOS_ID),
}
local slot_at=arr+layout.slot_at
local function slot(uses)
    memory[slot_at]=pack32(1)..pack32(uses)..string.rep('\0',layout.slot_stride-8)
end
local reads=0
local api={
    read=function(address,size)
        reads=reads+1
        local bytes=memory[address]
        return bytes and #bytes==size and bytes or nil
    end,
    pointer=function(bytes)
        if not bytes or #bytes~=8 then return nil end
        local value=ffi.new('uint64_t[1]'); ffi.copy(value,bytes,8)
        return tonumber(value[0])
    end,
}
slot(1)
local actual=probe.create(api)
assert(actual.probe(game,{live=true})==false)
assert(actual.build=='ok' and actual.uses==1 and actual.sos_present)
slot(0)
local blocked,why=actual.probe(game,{live=true})
assert(blocked and why=='privacy_gate_sos' and actual.sticky)
local stopped_reads=reads
slot(1)
assert(actual.probe(game,{live=true})==true and reads==stopped_reads)
actual.reset_latch()
assert(actual.probe(game,{live=true})==false and actual.uses==1)
pass('real slot reader latches on spent SOS, stops reads and resets for next mission')

local failed=probe.create(api)
memory[slot_at]=nil
assert(failed.probe(game,{live=true})==false)
assert(failed.probe(game,{live=true})==false)
assert(failed.probe(game,{live=true})==true and failed.unsupported)
stopped_reads=reads
assert(failed.probe(game,{live=true})==true and reads==stopped_reads)
pass('real reader closes after repeated incomplete slots and stops further reads')

memory[game+128]='PE\0\0'..string.rep('\0',4)..pack32(1)
    ..string.rep('\0',68)..pack32(2)..string.rep('\0',4)
local mismatched=probe.create(api)
stopped_reads=reads
assert(mismatched.probe(game,{live=true})==true)
assert(mismatched.unsupported and mismatched.build=='mismatch' and reads==stopped_reads+2)
pass('real PE reader refuses unknown builds before accessing runtime slots')

print(string.format('PASS: sos_probe (%d checks)', count))
