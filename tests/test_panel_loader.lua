-- Regression: pressing Apply must not fault the panel out of existence.
--
-- The reported failure was: drag a slider, press Apply, the window vanishes and
-- F8 stops working. Cause: panel.apply() called the loader's log writer with a
-- single argument, and that writer concatenates its detail parameter, so the nil
-- raised inside the window procedure. The updater hook then disabled the panel
-- permanently. This test wires the REAL archive_loader log writer to the REAL
-- panel so a one-argument call can never pass unnoticed again.
local source, build = assert(arg[1]), assert(arg[2])
local ffi = require('ffi')
local create_model = assert(loadfile(source .. '/panel_model.lua'))()
local create_panel = assert(loadfile(source .. '/panel.lua'))()
-- The panel is always wired to the real gameplay patch in the shipped module.
local patch = assert(loadfile(source .. '/spawn_patch.lua'))()

local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end

-- A temp log directory so the loader writes a real file we can inspect.
local temp = build .. '/panel-log-test'
os.execute('mkdir "' .. temp:gsub('/', '\\') .. '" 2>nul')
local log_path = temp .. '/EnemySpawnMultiplier.log'
os.remove(log_path)

local identity = {revision = 'test-revision', exe_sha256 = 'exe', game_sha256 = 'game'}
local updates = 0
local env = setmetatable({
    print = function() end,
    os = {getenv = function(name) return name == 'LOCALAPPDATA' and temp or nil end},
    update = function() updates = updates + 1; return 'ok' end,
}, {__index = _G})
env._G = env

local factory_calls = 0
local function factory()
    factory_calls = factory_calls + 1
    return {
        module = function(name) return name and 'game' or 'exe' end,
        module_hash = function(module) return module end,
    }
end
-- Use the real patch module. Its apply() needs live game memory, so the probe
-- wrapper only supplies the detail field the loader reports on.
patch.apply = function() patch.detail = ''; return true, 'waiting_for_mission', false end

local chunk = assert(loadfile(source .. '/archive_loader.lua')); setfenv(chunk, env)
local loader = chunk(); setfenv(loader, env)
loader(factory, patch, identity, create_panel, create_model)
assert(factory_calls == 1)
local state = env.EnemySpawnMultiplier
assert(state and state.panel, 'loader did not create the panel')
pass('loader creates the panel through the real log writer')

-- The updater must keep pumping the panel without fault.
for _ = 1, 5 do assert(env.update(0.1)) end
assert(state.panel ~= nil, 'panel was disabled by an updater pass')
pass('updater pumps the panel without disabling it')

-- The exact reported flow: drag a slider, then press Apply. Dragging must also
-- be safe through the real window procedure.
local widgets = state.panel.model.layout()
local budget_slider = widgets.sliders[1]
local dragged = state.panel.model.set_slider(budget_slider,
    budget_slider.track_x + budget_slider.track_w * 0.75)
assert(type(dragged) == 'number' and dragged > 2.0 and dragged <= 6.0)
assert(state.panel.apply() == true, 'apply after a slider drag failed')
assert(state.panel ~= nil, 'panel died after drag-and-apply')
pass('dragging a slider then pressing Apply keeps the panel alive')

-- The reported crash: apply through the real panel, real model, real log writer.
local ok, applied, reason = pcall(state.panel.apply)
assert(ok, 'panel.apply raised: ' .. tostring(applied))
assert(applied == true, 'panel.apply returned false: ' .. tostring(reason))
pass('pressing Apply does not raise through the real log writer')

-- The panel must still be alive and pumpable after Apply, which is exactly what
-- failed in game.
assert(state.panel ~= nil)
local pumped, pump_reason = pcall(state.panel.pump)
assert(pumped, 'pump failed after Apply: ' .. tostring(pump_reason))
assert(state.panel ~= nil, 'panel was torn down after Apply')
pass('panel survives Apply and keeps pumping (F8 stays functional)')

-- The success must be recorded in the real log file with both fields.
local file = assert(io.open(log_path, 'r'), 'log file missing')
local contents = file:read('*a'); file:close()
assert(contents:find('panel_ready', 1, true), 'no panel_ready line')
assert(contents:find('panel_applied', 1, true), 'no panel_applied line')
assert(contents:find('budget=', 1, true), 'panel_applied detail missing')
pass('real log records panel_applied with its detail')

-- A one-argument log call must be tolerated rather than raising. This calls the
-- real writer exposed by the loader: omitting the detail is exactly what caused
-- the reported crash, so it must stay safe for any future call site.
assert(type(state.log) == 'function', 'loader did not expose its log writer')
local ok2, err2 = pcall(state.log, 'one_arg_probe')
assert(ok2, 'one-argument log call raised: ' .. tostring(err2))
local file2 = assert(io.open(log_path, 'r'))
local contents2 = file2:read('*a'); file2:close()
assert(contents2:find('one_arg_probe', 1, true), 'one-argument log call was not recorded')
pass('real log writer tolerates a missing detail argument')

-- The footer must reflect whether a mission is running, so a change made on the
-- ship is not silently mistaken for "nothing happened".
assert(env.EnemySpawnMultiplier.active == false)
assert(state.panel ~= nil)
pass('panel remains available on the ship so changes can be staged')

state.panel.close()

-- Shared settings and MODS must survive a failed optional Win32 window.
local create_config = assert(loadfile(source .. '/config_service.lua'))()
local create_options = assert(loadfile(source .. '/mod_options.lua'))()
local prefix = 'natsun.enemy_spawn_multiplier.'
local specs, values, callbacks = {}, {}, {}
local menu = {api=1,version=3,
    register_option=function(id,spec) specs[id]=spec; values[id]=spec.default; return true end,
    get=function(id) return values[id] end,
    set=function(id,value) values[id]=value; return true end,
    on_change=function(id,fn) callbacks[id]=fn; return true end}
env.EnemySpawnMultiplier=nil
local saved={budget=3,patrol_count=1,patrol_size=0.8,encounter_cd=15,
    patrol_cd=20,preset='native',fast_corpse=false,language='en'}
local saves=0
loader(factory,patch,identity,function() error('simulated panel failure') end,
    create_model,nil,nil,function() return {
        load=function() return saved end,
        save=function(profile) saved=profile; saves=saves+1; return true end}
    end,nil,nil,create_config,function(config,options)
        options.get_menu=function() return menu end
        return create_options(config,options)
    end)
local independent=assert(env.EnemySpawnMultiplier)
assert(independent.panel==nil and independent.config and independent.mods_menu)
assert(patch.budget_multiplier==3 and patch.fast_corpse==false)
env.update(0.1)
assert(independent.mods_menu.status=='ready' and values[prefix..'budget']==3)
values[prefix..'budget']=4.7; callbacks[prefix..'budget'](4.7)
values[prefix..'language']=1; callbacks[prefix..'language'](1)
env.update(0.1)
assert(patch.budget_multiplier==4.7 and saved.language=='zh' and saves==1)
pass('loader restores cfg and applies MODS changes even when the F8 window fails')

-- Probe failures must block both writers while preserving the previous update.
local live, writes, decay_updates, scans = true, 0, 0, 0
local gated_patch = {
    in_mission=function() return live end,
    apply=function()
        writes=writes+1
        return true, live and 'active' or 'waiting_for_mission', live
    end,
}
local gated_corpse = {
    update=function() decay_updates=decay_updates+1 end,
    set_enabled=function() end,
}
local function start_gate(create_sos)
    local isolated = setmetatable({print=function() end,
        os={getenv=function() return nil end},
        update=function() return 'forwarded' end}, {__index=_G})
    isolated._G=isolated
    local gate_chunk=assert(loadfile(source .. '/archive_loader.lua'))
    setfenv(gate_chunk,isolated)
    gate_chunk()(factory,gated_patch,identity,nil,nil,nil,nil,nil,nil,
        function() return gated_corpse end,nil,nil,create_sos)
    return isolated
end
local thrown=start_gate(function() return {create=function() return {
    build='ok',probe=function() scans=scans+1; error('probe read failed') end,
} end} end)
for _=1,50 do assert(thrown.update(0.1)=='forwarded') end
assert(scans==1 and writes==0 and decay_updates==0)
assert(thrown.EnemySpawnMultiplier.status=='sos_probe_unreliable')
pass('throwing SOS probe blocks spawn and corpse updates without retrying')

for _, failing in ipairs({
    function() error('factory failed') end,
    function() return {create=function() error('session failed') end} end,
}) do
    local failed=start_gate(failing)
    assert(failed.update(0.1)=='forwarded')
    assert(writes==0 and decay_updates==0)
    assert(failed.EnemySpawnMultiplier.status=='sos_probe_unreliable')
end
pass('failed SOS initialization blocks writers and preserves the update chain')

scans=0
local session={build='ok',sticky=false,unsupported=false}
session.probe=function()
    scans=scans+1; session.sticky=true
    return true,'privacy_gate_sos','spent'
end
session.reset_latch=function() session.sticky=false end
local latched=start_gate(function() return {create=function() return session end} end)
for _=1,50 do latched.update(0.1) end
assert(scans==1 and writes==0 and decay_updates==0 and session.sticky)
live=false; latched.update(0.1)
assert(not session.sticky and writes==1 and decay_updates==1)
pass('SOS latch blocks both writers until return to ship')
print(count .. ' panel loader-integration checks passed; no game process involved.')
