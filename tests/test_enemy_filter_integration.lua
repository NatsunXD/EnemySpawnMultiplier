-- Offline profile/menu/loader contracts. No game process or native spawning.
local source, build = assert(arg[1]), assert(arg[2])
local create_model = assert(loadfile(source .. '/panel_model.lua'))()
local create_config = assert(loadfile(source .. '/config_service.lua'))()
local create_store = assert(loadfile(source .. '/config_store.lua'))()
local create_options = assert(loadfile(source .. '/mod_options.lua'))()
local create_filter = assert(loadfile(source .. '/enemy_filter.lua'))()
local keys = {'block_jumpers', 'block_yellow_spewers', 'block_green_spewers',
    'block_bile_spitters', 'block_scavengers', 'block_shriekers', 'block_all_small'}
local checks = 0
local function pass(name) checks = checks + 1; print('PASS: ' .. name) end
local function fresh() return assert(loadfile(source .. '/spawn_patch.lua'))() end
local codec = create_store({dir = build})
local patch = fresh()
patch.enemy_filter = create_filter({}, nil)
local disk = codec.decode('version=1\nbudget=3\npreset=native\nlanguage=en\n')
local saves, calls = 0, 0
local configure = patch.configure
patch.configure = function(values) calls = calls + 1; return configure(values) end
local config = create_config(create_model, patch, {store = {
    load = function() return disk end,
    save = function(values) saves = saves + 1; disk = codec.decode(assert(codec.encode(values))); return true end,
}})
assert(config.restored and config.current().budget == 3 and config.current().language == 'en')
for _, key in ipairs(keys) do
    assert(config.current()[key] == false and patch[key] == false and patch.enemy_filter[key] == false)
end
pass('legacy profiles retain existing settings and start all enemy filters disabled')

for _, key in ipairs(keys) do
    local before = patch.budget_multiplier
    assert(not patch.configure({budget = 4, [key] = 'true'}))
    assert(patch.budget_multiplier == before and patch[key] == false)
    assert(not config.commit({budget = 4, [key] = 1}, 'test'))
    assert(patch.budget_multiplier == before)
end
assert(not patch.enemy_filter.configure(nil))
pass('invalid filter settings reject the entire update before other values change')

local prefix = 'natsun.enemy_spawn_multiplier.'
local menu = {api = 1, version = 3, specs = {}, values = {}, callbacks = {}}
function menu.register_option(id, spec) menu.specs[id] = spec; menu.values[id] = spec.default; return true end
function menu.get(id) return menu.values[id] end
function menu.set(id, value) menu.values[id] = value; return true end
function menu.on_change(id, fn) menu.callbacks[id] = fn; return true end
local bridge = create_options(config, {get_menu = function() return menu end})
bridge.pump(0.1)
assert(bridge.status == 'ready' and bridge.registered == 15)
local previous_calls, previous_saves = calls, saves
for _, key in ipairs(keys) do menu.values[prefix .. key] = true; menu.callbacks[prefix .. key](true) end
assert(calls == previous_calls and saves == previous_saves)
bridge.pump(0.1)
assert(calls == previous_calls + 1 and saves == previous_saves + 1)
for _, key in ipairs(keys) do
    assert(patch[key] == true and patch.enemy_filter[key] == true and disk[key] == true)
end
pass('MODS batches all seven toggles into one configure/save and reaches the real filter')

assert(config.commit({block_all_small = false, block_yellow_spewers = false}, 'panel'))
assert(patch.block_jumpers and patch.block_scavengers and patch.block_shriekers and patch.block_green_spewers)
assert(menu.values[prefix .. 'block_all_small'] == false and disk.block_all_small == false)
local restarted_patch = fresh()
restarted_patch.enemy_filter = create_filter({}, nil)
local restored = create_config(create_model, restarted_patch, {store = {load = function() return disk end}})
for _, key in ipairs(keys) do assert(restored.current()[key] == disk[key] and restarted_patch[key] == disk[key]) end
assert(restored.current().language == 'en')
pass('turning off the master preserves individual selections through menu sync and restart')

local model = create_model()
model.import(config.current())
for _, language in ipairs({'zh', 'en'}) do
    assert(model.set_language(language))
    for _, key in ipairs(keys) do
        assert(model.text(key) ~= key and model.text(key .. '_desc') ~= key .. '_desc')
    end
    local widgets = model.layout()
    for _, control in ipairs(widgets.checkboxes) do
        local kind, hit = model.hit(control.x + 5, control.y + 5)
        assert(kind == 'checkbox' and hit.key == control.key)
        assert(control.y + control.h < widgets.radios[1].y)
    end
    assert(widgets.buttons[4].y + widgets.buttons[4].h + 40 <= model.CLIENT_H)
end
model.reset()
for _, key in ipairs(keys) do assert(model.pending[key] == false) end
pass('both languages expose all options without overlap; Reset clears filters only on Apply')

-- The actual loader owns the Public/SOS policy. Intercept only foreign-memory
-- filter updates, whose resource writes are tested in test_enemy_filter.lua.
local function loader_fixture(options)
    options = options or {}
    local s = {privacy = options.privacy or '1', live = true, allowed = {}, forwarded = 0,
        builds = 0, writes = 0, broken = false, readable = true, filter = nil}
    local settings_path = 'private-fixture/Arrowhead/Helldivers2/saves/test_user_settings.config'
    local env = setmetatable({print = function() end, os = {
        getenv = function(name) return name == 'APPDATA' and 'private-fixture' or nil end,
    }, io = {open = function(path)
        if not s.readable or path:gsub('\\', '/') ~= settings_path then return nil end
        return {read = function() return 'privacy_mode = ' .. s.privacy end, close = function() end}
    end}, update = function() s.forwarded = s.forwarded + 1; return 'previous-update' end}, {__index = _G})
    env._G = env
    -- Supply the directory listing at the Win32 boundary; no real account files.
    local real_require = require
    env.require = function(name)
        if name ~= 'ffi' then return real_require(name) end
        local ffi = require('ffi')
        return setmetatable({load = function(library)
            if library ~= 'kernel32' then return ffi.load(library) end
            return {
                FindFirstFileA = function(_, data)
                    ffi.copy(data + 44, 'test_user_settings.config\0')
                    return ffi.cast('void *', 1)
                end,
                FindNextFileA = function() return 0 end,
                FindClose = function() return 1 end,
            }
        end, cast = function(kind, value)
            if type(value) == 'function' then return value end
            return ffi.cast(kind, value)
        end}, {__index = ffi})
    end
    local p = fresh()
    p.in_mission = function() return s.live end
    p.apply = function() s.writes = s.writes + 1; return true, 'test-active', true end
    if options.patch_failure then p.apply = function() return false, 'test_patch_failed', false end end
    local chunk = assert(loadfile(source .. '/archive_loader.lua'))
    setfenv(chunk, env)
    local factory = function()
        return {module = function(name) return name and 'game' or 'exe' end,
            module_hash = function(module) return options.unknown and 'changed' or module end}
    end
    local probe = options.probe or {build = 'ok', sticky = false, unsupported = false,
        probe = function() return false end, reset_latch = function() end}
    local make_sos = options.make_sos or function() return {create = function() return probe end} end
    chunk()(factory, p, {revision = 'test', exe_sha256 = 'exe', game_sha256 = 'game'},
        nil, create_model, nil, nil, nil, nil, nil, create_config, nil, make_sos,
        function()
            s.builds = s.builds + 1
            local filter = create_filter({}, nil)
            filter.update = function(allowed)
                s.allowed[#s.allowed + 1] = allowed
                if s.broken and allowed then error('synthetic filter failure') end
                return true
            end
            s.filter = filter
            return filter
        end)
    s.state, s.patch = env.EnemySpawnMultiplier, p
    function s.tick(n) for _ = 1, n or 25 do assert(env.update(0.1) == 'previous-update') end end
    return s
end

local s = loader_fixture()
assert(s.state.config.commit({block_all_small = true}, 'test'))
s.tick(1)
assert(s.builds == 1 and s.allowed[#s.allowed] == true and s.filter.block_all_small)
s.privacy = '0'; s.tick()
assert(s.allowed[#s.allowed] == false)
s.privacy = '1'; s.tick()
assert(s.allowed[#s.allowed] == false, 'must preserve upstream mission latch')
s.live = false; s.tick(); s.live = true; s.tick()
assert(s.allowed[#s.allowed] == true)
pass('real loader restores filters on Public and honors the upstream latch until returning to ship')

for _, raw in ipairs({'unknown', '-1', '9'}) do
    local denied = loader_fixture({privacy = raw}); denied.tick()
    for _, allowed in ipairs(denied.allowed) do assert(allowed == false) end
end
local unknown = loader_fixture({unknown = true}); unknown.tick()
assert(unknown.builds == 0 and #unknown.allowed == 0)
pass('unknown privacy and unsupported builds cannot enable the resource filter')

local missing = loader_fixture(); missing.tick(1)
assert(missing.allowed[#missing.allowed] == true)
missing.readable = false; missing.tick()
assert(missing.allowed[#missing.allowed] == false)
missing.readable = true; missing.tick()
assert(missing.allowed[#missing.allowed] == true)
pass('temporarily missing privacy files suspend replacements instead of reusing stale private permission')

for _, opts in ipairs({
    {gated = true, probe = {build = 'ok', sticky = true, unsupported = false}},
    {gated = true, probe = {build = 'mismatch', unsupported = true}},
    {make_sos = function() error('failed SOS factory') end},
    {probe = {build = 'ok', probe = function() error('failed SOS read') end}},
}) do
    local denied = loader_fixture(opts); denied.tick()
    for _, allowed in ipairs(denied.allowed) do assert(allowed == (not opts.gated)) end
    assert(denied.forwarded == 25 and denied.writes == (opts.gated and 0 or 25))
end
pass('confirmed SOS/build gates pause filters; probe exceptions preserve upstream availability and forwarding')

local faulty = loader_fixture(); faulty.broken = true; faulty.tick(2)
assert(#faulty.allowed == 2 and faulty.allowed[1] == true and faulty.allowed[2] == false)
assert(faulty.state.enemy_filter == nil and faulty.patch.enemy_filter == nil and faulty.forwarded == 2)
local stopped = loader_fixture({patch_failure = true}); stopped.tick(2)
assert(stopped.allowed[#stopped.allowed] == false)
pass('filter faults attempt restoration and isolate the feature; stopped multiplier updates also restore')

print(checks .. ' enemy filter integration checks passed; synthetic memory and private settings only.')
