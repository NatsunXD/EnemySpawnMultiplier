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

print(string.format('PASS: sos_probe (%d checks)', count))
