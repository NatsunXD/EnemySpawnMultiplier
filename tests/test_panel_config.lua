-- Panel persistence integration: a profile applied on one launch must be
-- restored on the next, and a broken file must never stop the panel opening.
-- This wires the REAL panel, model, patch and config store together and only
-- creates the Win32 window; no game memory is touched.
local source, build = assert(arg[1]), assert(arg[2])
local create_model = assert(loadfile(source .. '/panel_model.lua'))()
local create_panel = assert(loadfile(source .. '/panel.lua'))()
local patch = assert(loadfile(source .. '/spawn_patch.lua'))()
local create_store = assert(loadfile(source .. '/config_store.lua'))()

local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end
local function approx(a, b) return math.abs(a - b) <= 0.0001 end

local directory = build .. '/panel-config-test'
os.execute('mkdir "' .. directory:gsub('/', '\\') .. '" 2>nul')
local config_path = directory .. '/EnemySpawnMultiplier.cfg'
os.remove(config_path)
local store = create_store({dir = directory})

local logged = {}
local function make_panel()
    logged = {}
    local ok, panel, reason = pcall(create_panel, create_model, patch, {
        log = function(a, b) logged[#logged + 1] = tostring(a) .. ' ' .. tostring(b) end,
        state = {active = false}, store = store,
    })
    assert(ok, 'panel creation threw: ' .. tostring(panel))
    assert(panel ~= nil, 'panel was not created: ' .. tostring(reason))
    return panel
end
local function saw_event(name)
    for _, line in ipairs(logged) do
        if line:find(name, 1, true) then return true end
    end
    return false
end

-- First launch: no file, so the editor mirrors the live (shipped) profile.
local panel = make_panel()
assert(not saw_event('config_restored'))
assert(approx(panel.model.pending.budget, patch.budget_multiplier))
pass('first launch opens on the live profile when no config file exists')

-- Commit a distinctive profile. Apply must reach the patch and persist it.
panel.model.pending.budget, panel.model.pending.patrol_count = 4.5, 3.0
panel.model.pending.encounter_cd, panel.model.pending.patrol_cd = 12.0, 2.0
panel.model.pending.preset = 'light_medium'
assert(panel.apply() == true, 'apply failed')
assert(approx(patch.budget_multiplier, 4.5))
local file = assert(io.open(config_path, 'r'), 'config file was not written')
local contents = file:read('*a'); file:close()
assert(contents:find('budget=4.5', 1, true))
assert(contents:find('encounter_cd=12', 1, true))
assert(contents:find('preset=light_medium', 1, true))
assert(not contents:find('patrol_size', 1, true))
pass('pressing Apply commits the profile to the patch and to disk')

-- Simulate a restart: the patch comes back on its shipped defaults and a fresh
-- panel must pull the saved profile back before any updater pass.
panel.close()
patch.budget_multiplier, patch.budget_override_multiplier = 6.0, 6.0
patch.modifier_patrol_count, patch.modifier_travelers_max_unit = 0.5, 0.5
patch.encounter_deadline_enabled = false
local restarted = make_panel()
assert(saw_event('config_restored'), 'restore was not reported')
assert(approx(patch.budget_multiplier, 4.5), 'budget was not restored')
assert(approx(patch.modifier_patrol_count, 3.0), 'patrol count was not restored')
assert(approx(patch.modifier_travelers_max_unit, 1.0), 'patrol size must stay fixed at 1.0')
assert(approx(restarted.model.pending.budget, 4.5))
assert(restarted.model.pending.preset == 'light_medium')
pass('a later launch restores the saved profile before the first updater pass')

-- A corrupt file must degrade to the live profile rather than raising or
-- applying an out-of-range value.
restarted.close()
local broken = assert(io.open(config_path, 'w'))
broken:write('version=1\nbudget=not-a-number\nencounter_cd=9999\npreset=bogus\n')
broken:close()
local recovered = make_panel()
assert(approx(recovered.model.pending.budget, patch.budget_multiplier))
assert(recovered.model.pending.encounter_cd <= 30.0)
pass('a corrupt config file cannot stop the panel or push an invalid value')

recovered.close()
print(count .. ' panel persistence checks passed; no game process involved.')
