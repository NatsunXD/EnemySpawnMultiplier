local source = assert(arg[1])
local gate = assert(loadfile(source .. '/privacy_gate.lua'))()()
local count = 0
local function pass(name)
    count = count + 1
    print('PASS: ' .. name)
end

local s = gate.new()
assert(gate.on_privacy_sample(s, true, 2) == false)
assert(gate.on_privacy_sample(s, true, 2) == false)
assert(s.public_hold_s == 4 and not s.contaminated)
assert(gate.on_privacy_sample(s, true, 2) == true)
assert(s.contaminated and s.reason == 'public_hold')
pass('Public held across three 2s samples contaminates at 6s')

s = gate.new()
assert(gate.on_privacy_sample(s, true, 2) == false)
assert(gate.on_privacy_sample(s, false, 2) == false)
assert(s.public_hold_s == 0 and not s.contaminated)
assert(gate.on_privacy_sample(s, true, 2) == false)
assert(s.public_hold_s == 2)
pass('Friends mid-hold resets the Public accumulator')

s = gate.new()
local edges = gate.on_mission_edge(s, true, true)
assert(s.contaminated and s.reason == 'mission_start')
assert(edges[1] == 'contaminated:mission_start')
pass('mission start while Public contaminates immediately')

s = gate.new()
gate.on_mission_edge(s, true, false)
assert(not s.contaminated)
gate.on_privacy_sample(s, true, 2)
gate.on_privacy_sample(s, true, 2)
gate.on_privacy_sample(s, true, 2)
assert(s.contaminated and s.reason == 'public_hold')
local clear_events = gate.on_mission_edge(s, false, false)
assert(not s.contaminated)
assert(clear_events[1]:find('cleared:mission_return', 1, true))
pass('mission return on Friends clears contamination')

s = gate.new()
gate.on_sos(s)
assert(s.contaminated and s.reason == 'sos')
assert(gate.should_gate(s, true, false) == true)
assert(select(2, gate.should_gate(s, true, false)) == 'privacy_gate_sos')
pass('SOS contamination gates even when solo')

s = gate.new()
gate.on_privacy_sample(s, true, 6)
assert(s.contaminated and s.reason == 'public_hold')
assert(gate.should_gate(s, true, false) == false)
assert(gate.should_gate(s, false, false) == true)
assert(gate.should_gate(s, nil, false) == true)
pass('solo bypasses Public contamination; unknown peers do not')

s = gate.new()
gate.on_sos(s)
gate.on_mission_edge(s, true, false)
local pending = gate.on_mission_edge(s, false, true)
assert(s.contaminated and s.mission_return_pending)
assert(pending[1] == 'mission_return_pending')
local cleared, previous, how = gate.on_ship_tick(s, false, false, 0.1)
assert(cleared and previous == 'sos' and how == 'mission_return')
assert(not s.contaminated)
pass('mission return while still Public waits until Friends on ship')

s = gate.new()
gate.on_privacy_sample(s, true, 6)
assert(s.contaminated)
local dwell_clear, ticks = false, 0
while ticks < 1801 do
    ticks = ticks + 1
    dwell_clear = gate.on_ship_tick(s, false, false, 0.1)
    if dwell_clear then break end
end
assert(dwell_clear and ticks == 1800 and not s.contaminated)
pass('Friends dwell of 180s on ship clears contamination')

s = gate.new()
gate.on_privacy_sample(s, true, 6)
for _ = 1, 100 do gate.on_ship_tick(s, false, false, 0.1) end
assert(s.friends_dwell_s > 0)
gate.on_ship_tick(s, false, true, 0.1)
assert(s.friends_dwell_s == 0 and s.contaminated)
gate.on_ship_tick(s, true, false, 1)
assert(s.friends_dwell_s == 0)
pass('Public or mission pauses/resets Friends dwell')

assert(gate.should_gate(gate.new(), false, true) == true)
pass('live SOS gate wins regardless of contamination state')

print(string.format('privacy_gate: %d checks passed', count))
