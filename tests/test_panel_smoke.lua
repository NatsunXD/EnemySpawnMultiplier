-- Real Win32 smoke test: create the panel window, force a paint, pump the
-- message queue and destroy it. This exercises RegisterClassExA,
-- CreateWindowExA, the GDI double-buffer paint path and the window procedure.
--
-- It loads the real panel and the real patch module (not stubs) so the panel's
-- configure() call is checked against the shipped implementation. patch.apply
-- is not called: that needs live game memory. The panel -> configure -> live
-- memory chain is covered by test_panel_model.lua and test_fast_cadence.lua.
-- Runs outside the game and never touches game memory.
local source = assert(arg[1])
local ffi = require('ffi')
local create_model = assert(loadfile(source .. '/panel_model.lua'))()
local create_panel = assert(loadfile(source .. '/panel.lua'))()
local patch = assert(loadfile(source .. '/spawn_patch.lua'))()

ffi.cdef [[
    int32_t ShowWindow(void *window, int32_t command);
    int32_t UpdateWindow(void *window);
    int32_t InvalidateRect(void *window, const void *rect, int32_t erase);
    void Sleep(uint32_t milliseconds);
    int32_t IsWindow(void *window);
]]
local user32, kernel32 = ffi.load('user32'), ffi.load('kernel32')

local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end

-- The real patch starts on its shipped defaults; confirm the panel can drive it.
assert(patch.configure and type(patch.configure) == 'function')

local logged = {}
local ok, panel, reason = pcall(create_panel, create_model, patch, {
    log = function(a, b) logged[#logged + 1] = tostring(a) .. ' ' .. tostring(b) end,
    state = {active = false},
})
assert(ok, 'panel creation threw: ' .. tostring(panel))
assert(panel ~= nil, 'panel was not created: ' .. tostring(reason))
assert(panel.window ~= nil and user32.IsWindow(panel.window) ~= 0, 'panel window handle is invalid')
pass('panel window created against the real patch module')

user32.ShowWindow(panel.window, 5)
user32.InvalidateRect(panel.window, nil, 1)
user32.UpdateWindow(panel.window)
for _ = 1, 20 do panel.pump(); kernel32.Sleep(15) end
pass('panel painted and pumped without fault')

for _ = 1, 20 do panel.pump(); kernel32.Sleep(5) end
pass('repeated pump stays stable')

-- sync_from_patch must mirror whatever profile is already live.
local synced = create_model()
local live = {budget_multiplier = 3.0, modifier_patrol_count = 4.5,
              modifier_travelers_max_unit = 1.5, encounter_deadline_enabled = false,
              encounter_max_interval = 30.0, modifier_patrol_cooldown = 1.0,
              cooldown_fast_rate = 3.0, patrol_cooldown_fast_rate = 6.0,
              template_bias_enabled = false}
synced.sync_from_patch(live)
assert(math.abs(synced.pending.budget - 3.0) < 0.001)
assert(math.abs(synced.pending.patrol_count - 4.5) < 0.001)
assert(math.abs(synced.pending.patrol_size - 1.5) < 0.001)
assert(math.abs(synced.pending.encounter_cd - 30.0) < 0.001)
assert(math.abs(synced.pending.patrol_cd - 30.0) < 0.001)
assert(synced.pending.preset == 'native')
pass('panel syncs its controls from the live profile')

-- Drive the panel's apply path through the model and the real configure().
local model = create_model()
model.pending.budget, model.pending.patrol_count, model.pending.patrol_size = 1.5, 3.0, 0.5
model.pending.encounter_cd, model.pending.patrol_cd = 30.0, 2.0
model.pending.preset = 'light_medium'
local applied, apply_reason = model.apply(patch)
assert(applied, 'panel apply rejected: ' .. tostring(apply_reason))
assert(math.abs(patch.budget_multiplier - 1.5) < 0.0001)
assert(math.abs(patch.modifier_patrol_count - 3.0) < 0.0001)
assert(math.abs(patch.modifier_travelers_max_unit - 0.5) < 0.0001)
-- 30 s is the slow end: native curve, no deadline clamp.
assert(math.abs(patch.modifier_encounter_cooldown - 1.0) < 0.0001)
assert(patch.encounter_deadline_enabled == false)
-- 2 s is the fast end for the patrol path: it uses the patrol rate scale.
assert(math.abs(patch.modifier_patrol_cooldown - patch.patrol_cooldown_fast_rate) < 0.0001)
assert(patch.template_bias_enabled == true)
assert(math.abs(patch.template_bias_light - 3.6) < 0.0001)
pass('panel apply reaches the real patch configure surface')

-- Switching the preset back to native must flip the live bias flag off.
model.pending.preset = 'native'
assert(model.apply(patch))
assert(patch.template_bias_enabled == false)
pass('panel native preset disables template bias on the real patch')

-- The toggle hint is user-visible contract: it must always be a drawable string
-- (a nil hint would silently blank that corner of the header).
assert(type(panel.toggle_hint) == 'string' and #panel.toggle_hint > 0)

-- With a Mod Bindings Menu bridge present and ready, the panel must drive the
-- toggle from that binding and advertise it, rather than silently using F8.
local bound = {registered = false, down = false}
local bridge = {
    register = function() bound.registered = true; return true end,
    is_down = function() return bound.down end,
}
local ok2, panel2, reason2 = pcall(create_panel, create_model, patch, {
    log = function() end, state = {active = false},
    bindings = bridge, title = 'EnemySpawnMultiplier v20 by Natsun',
})
assert(ok2 and panel2 ~= nil, 'panel with bindings failed: ' .. tostring(reason2))
assert(bound.registered, 'the bridge was never asked to register')
panel2.pump()
assert(panel2.open == false)
-- A down edge on the custom binding must toggle the panel open.
bound.down = true
panel2.pump()
assert(panel2.open == true, 'the custom binding did not open the panel')
-- And it must toggle closed on release then press.
bound.down = false
panel2.pump()
bound.down = true
panel2.pump()
assert(panel2.open == false, 'the custom binding did not close the panel')
panel2.close()
pass('custom binding toggles the panel instead of F8')

panel.close()
assert(panel.window == nil)
pass('panel window destroyed cleanly')

print(count .. ' panel smoke checks passed; window created and destroyed outside the game.')
