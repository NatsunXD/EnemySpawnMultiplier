-- Mod Bindings Menu bridge checks: registration, ordering, conflicts and the
-- optional-dependency fallback. Pure Lua; no game process or native input.
local source = assert(arg[1])
local create_bindings = assert(loadfile(source .. '/bindings.lua'))()

local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end

local OPTS = {id = 'natsun.enemy_spawn_multiplier.toggle_panel',
              label_id = 0x4FADC001, slot = 2}

-- Absent addon: the provider must stay quiet so the panel keeps F8.
local saved = rawget(_G, 'ModBindingsMenu')
rawset(_G, 'ModBindingsMenu', nil)
local p = create_bindings(OPTS)
assert(p.available() == false)
assert(p.register() == false)
assert(p.is_down() == nil)
pass('absent Mod Bindings Menu leaves the panel on its F8 fallback')

-- Present and working: registration succeeds once and is idempotent.
local calls = {}
rawset(_G, 'ModBindingsMenu', {
    api = 1,
    register_binding = function(id, label_id, slot)
        calls[#calls + 1] = {id = id, label_id = label_id, slot = slot}
        return true
    end,
    is_down = function(id) return id == OPTS.id end,
})
p = create_bindings(OPTS)
assert(p.available() == true)
assert(p.register() == true)
assert(p.register() == true)
assert(#calls == 1, 'registration must not repeat after success')
assert(calls[1].id == OPTS.id)
assert(calls[1].label_id == 0x4FADC001)
assert(calls[1].slot == 2)
assert(p.is_down() == true)
pass('registration forwards id, label id and slot 2 exactly once')

-- is_down must report nil while native input is still loading, and the bridge
-- must not mistake that for a released key.
rawset(_G, 'ModBindingsMenu', {
    api = 1,
    register_binding = function() return true end,
    is_down = function() return nil end,
})
p = create_bindings(OPTS)
assert(p.register() == true)
assert(p.is_down() == nil)
pass('unavailable native input reports nil rather than a stuck key')

-- A slot taken by another addon is permanent: stop retrying, and stay quiet so
-- the panel keeps working on F8.
local attempts = 0
rawset(_G, 'ModBindingsMenu', {
    api = 1,
    register_binding = function() attempts = attempts + 1; return false, 'slot already in use' end,
    is_down = function() return nil end,
})
p = create_bindings(OPTS)
assert(p.register() == false)
assert(p.register() == false)
assert(attempts == 1, 'a permanent conflict must not be retried')
assert(p.is_down() == nil)
pass('slot conflict stops retrying and disables the bridge quietly')

-- Load-order independence: the addon may appear after the panel was created.
rawset(_G, 'ModBindingsMenu', nil)
p = create_bindings(OPTS)
assert(p.register() == false)
rawset(_G, 'ModBindingsMenu', {
    api = 1,
    register_binding = function() return true end,
    is_down = function() return false end,
})
assert(p.register() == true)
assert(p.is_down() == false)
pass('registration retries until a late-loading addon appears')

-- An api other than 1 must be ignored rather than called into.
rawset(_G, 'ModBindingsMenu', {api = 2, register_binding = function() return true end})
p = create_bindings(OPTS)
assert(p.available() == false and p.register() == false)
pass('an unexpected Mod Bindings Menu api version is ignored')

rawset(_G, 'ModBindingsMenu', saved)
print(count .. ' bindings bridge checks passed; no game process involved.')
