-- Run against the actual optional addon sources, with no native menu update.
-- <luajit> test_mod_options_upstream.lua <ESM src> <scratch> <ModOptionsMenu root>
local source,build,upstream=assert(arg[1]),assert(arg[2]),assert(arg[3])
local create_model=assert(loadfile(source..'/panel_model.lua'))()
local create_config=assert(loadfile(source..'/config_service.lua'))()
local create_options=assert(loadfile(source..'/mod_options.lua'))()
local patch=assert(loadfile(source..'/spawn_patch.lua'))()
assert(patch.configure({budget=2,patrol_count=1,patrol_size=1,encounter_cd_seconds=2,
    patrol_cd_seconds=2,preset='heavy',fast_corpse=true}))
local writes,configures=0,0
local original_configure=patch.configure
patch.configure=function(values) configures=configures+1; return original_configure(values) end
local config=create_config(create_model,patch,{store={load=function() return nil,'not_found' end,
    save=function() writes=writes+1; return true end}})
local directory=build..'/upstream-menu-test'
os.execute('mkdir "'..directory:gsub('/','\\')..'" 2>nul')
for _,suffix in ipairs({'','.bak','.tmp'}) do os.remove(directory..'/ModOptionsMenu.values'..suffix) end
local Text=dofile(upstream..'/src/bingus_text.lua')
_G.mom_text={module=Text,locales={en=dofile(upstream..'/locales/en.lua'),bundled={}}}
local context
_G.mom_files=setmetatable({},{__index=function(files,name)
    local chunk=assert(loadfile(upstream..'/src/'..name..'.lua'))
    local function run(mom) context=mom; return chunk(mom) end
    rawset(files,name,run); return run
end})
_G.ModOptionsMenu,_G.BingusRuntime,_G.BingusTranslations=nil,nil,nil
_G.update=function() end
_G.CowboyBingusModLoader={log_directory=directory,open_log=function()
    return {write=function() end,flush=function() end}
end}
dofile(upstream..'/src/mod_options_menu.lua')
local menu=assert(ModOptionsMenu)
assert(menu.api==1 and menu.version>=2)
local bridge=create_options(config)
bridge.pump(0.1)
assert(bridge.status=='ready',tostring(bridge.reason))
local prefix='natsun.enemy_spawn_multiplier.'
assert(#context.state.mods==1 and #context.state.mods[1].order==15)
assert(not menu.ready(),'test must never activate native integration')
print('PASS: all fifteen real menu registrations accepted, one category, native integration inactive')

context.set_pending(prefix..'budget',3.7)
context.set_pending(prefix..'patrol_count',2.1)
context.set_pending(prefix..'preset',2)
context.set_pending(prefix..'fast_corpse',false)
context.set_pending(prefix..'language',2)
assert(config.current().budget==2)
assert(context.apply_pending()==5)
assert(config.current().budget==2,'callbacks must be batched until bridge pump')
bridge.pump(0.1)
assert(math.abs(patch.budget_multiplier-3.7)<1e-6 and patch.fast_corpse==false)
assert(config.current().language=='en' and config.current().preset=='light_medium')
assert(configures==1 and writes==1)
print('PASS: actual menu APPLY batches five changes into one gameplay commit and save')

context.translation.refresh()
assert(context.state.options[prefix..'budget'].label=='Wave budget')
assert(context.state.options[prefix..'preset'].choices[2]=='LIGHT / MEDIUM UNITS')
assert(config.commit({language='zh'},'panel-language'))
context.translation.refresh()
assert(context.state.options[prefix..'budget'].label==config.text('budget'))
assert(menu.get(prefix..'language')==1)
assert(configures==1,'language switching must not touch gameplay')
print('PASS: real menu refreshes labels and choices in both languages')

context.set_pending(prefix..'budget',6)
context.set_pending(prefix..'patrol_cd',30)
assert(config.commit({budget=4.2},'panel'))
assert(context.state.pending[prefix..'budget']==nil)
assert(context.state.pending[prefix..'patrol_cd']==30)
assert(math.abs(menu.get(prefix..'budget')-4.2)<1e-6)
local before=configures
bridge.pump(0.1); assert(configures==before,'real set must not dispatch on_change')
context.drop_pending()
assert(menu.get(prefix..'patrol_cd')==2,'cancelled menu edits must not apply')
print('PASS: real set synchronizes F8, replaces same-field draft and preserves unrelated edits')

-- The actual F8 editor and actual menu share the same service.
local create_panel=assert(loadfile(source..'/panel.lua'))()
local panel=assert(create_panel(create_model,patch,{config=config,log=function() end}))
panel.model.pending.patrol_size=0.7
context.set_pending(prefix..'budget',2.8)
context.set_pending(prefix..'language',2)
context.apply_pending(); bridge.pump(0.1)
assert(panel.model.pending.budget==2.8 and panel.model.pending.patrol_size==0.7)
assert(panel.model.language=='en')
assert(panel.apply())
assert(math.abs(menu.get(prefix..'patrol_size')-0.7)<1e-6)
assert(panel.set_language('zh'))
assert(menu.get(prefix..'language')==1)
-- Exercise the real language-button message handler, including after Reset.
panel.model.reset()
local ffi=require('ffi')
ffi.cdef [[int64_t ESMTest_SendMessageA(void *, uint32_t, uint64_t, int64_t) __asm__("SendMessageA");]]
local button=panel.model.layout().buttons[4]
local x,y=button.x+5,button.y+5
ffi.load('user32').ESMTest_SendMessageA(panel.window,0x0201,1,x+y*65536)
assert(panel.model.language=='en' and config.current().language=='en')
assert(menu.get(prefix..'language')==2)
assert(config.current().patrol_size==0.7,'language button must not submit Reset drafts')
panel.close()
print('PASS: actual F8 panel and actual MODS API synchronize both ways')
local filter_keys = {'block_jumpers', 'block_yellow_spewers', 'block_green_spewers',
    'block_bile_spitters', 'block_scavengers', 'block_shriekers', 'block_all_small'}
local before_calls, before_writes = configures, writes
for _, key in ipairs(filter_keys) do context.set_pending(prefix .. key, true) end
assert(context.apply_pending() == 7)
bridge.pump(0.1)
assert(configures == before_calls + 1 and writes == before_writes + 1)
for _, key in ipairs(filter_keys) do assert(patch[key] and config.current()[key]) end
local reopened = assert(create_panel(create_model, patch, {config=config, log=function() end}))
for _, key in ipairs(filter_keys) do assert(reopened.model.pending[key] == true) end
reopened.model.pending.block_all_small = false
assert(reopened.apply())
assert(menu.get(prefix .. 'block_all_small') == false)
assert(menu.get(prefix .. 'block_jumpers') and menu.get(prefix .. 'block_yellow_spewers'))
for _, language in ipairs({'en', 'zh'}) do
    assert(reopened.set_language(language))
    context.translation.refresh()
    for _, key in ipairs(filter_keys) do
        assert(context.state.options[prefix .. key].label == config.text(key))
    end
end
reopened.close()
print('PASS: actual menu batches all filters, reopens F8, preserves individual choices and translates every row')
print('6 upstream integration checks passed; no game process or native menu update involved.')
