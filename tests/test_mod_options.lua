-- Shared configuration, batching, persistence and hostile optional APIs.
local source, build = assert(arg[1]), assert(arg[2])
local create_model = assert(loadfile(source .. '/panel_model.lua'))()
local create_config = assert(loadfile(source .. '/config_service.lua'))()
local create_options = assert(loadfile(source .. '/mod_options.lua'))()
local create_store = assert(loadfile(source .. '/config_store.lua'))()
local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end
local function clone(t) local r = {}; for k,v in pairs(t) do r[k]=v end; return r end
local function approx(a,b) return math.abs(a-b)<1e-6 end
local function fresh(saved)
    local patch = assert(loadfile(source .. '/spawn_patch.lua'))()
    assert(patch.configure({budget=2,patrol_count=1,patrol_size=1,
        encounter_cd_seconds=2,patrol_cd_seconds=2,preset='heavy',fast_corpse=true}))
    local calls, writes, disk = 0, 0, saved and clone(saved)
    local configure = patch.configure
    patch.configure = function(values) calls=calls+1; return configure(values) end
    local store = {load=function() return disk, disk and nil or 'not_found' end,
        save=function(values) disk=clone(values); writes=writes+1; return true end}
    local config = create_config(create_model,patch,{store=store})
    return config,patch,function() return calls,writes,disk end
end
local function fake_menu(saved, version)
    local m={api=1,version=version or 3,specs={},values={},callbacks={},pending={},sets=0}
    function m.register_option(id,spec)
        m.specs[id]=spec
        local value=saved and saved[id]
        if value==nil then value=spec.default end
        m.values[id]=value
        return true
    end
    function m.get(id) return m.values[id] end
    function m.set(id,value)
        assert(m.specs[id],'unknown option')
        m.values[id],m.pending[id]=value,nil
        m.sets=m.sets+1
        return true
    end
    function m.on_change(id,fn) m.callbacks[id]=fn; return true end
    function m.apply(changes)
        for id,value in pairs(changes) do m.values[id]=value; m.callbacks[id](value,id) end
    end
    return m
end
local prefix='natsun.enemy_spawn_multiplier.'
local config,patch,stats=fresh()
local menu=fake_menu()
local bridge=create_options(config,{get_menu=function() return menu end})
bridge.pump(0.1)
assert(bridge.status=='ready' and bridge.registered==15)
local calls,writes=stats()
assert(calls==0 and writes==0,'unchanged startup must not rewrite profile')
pass('registers fifteen options without extra writes or a Runtime dependency')

menu.apply({[prefix..'budget']=3.5,[prefix..'patrol_count']=2.5,
    [prefix..'patrol_size']=0.5,[prefix..'encounter_cd']=12,[prefix..'patrol_cd']=18,
    [prefix..'preset']=2,[prefix..'fast_corpse']=false,[prefix..'language']=2})
assert(patch.budget_multiplier==2,'callbacks must not apply partial profiles')
bridge.pump(0.1)
calls,writes=stats()
assert(calls==1 and writes==1,'one APPLY must configure and save once')
assert(patch.budget_multiplier==3.5 and patch.modifier_patrol_count==2.5)
assert(patch.modifier_travelers_max_unit==0.5 and patch.fast_corpse==false)
assert(config.current().preset=='light_medium' and config.current().language=='en')
assert(type(menu.specs[prefix..'budget'].label)=='function')
assert(menu.specs[prefix..'budget'].label()=='Wave budget')
pass('multi-field MODS APPLY commits once, including false toggle and language')

local exposed=config.current(); exposed.budget=6
assert(config.current().budget==3.5,'callers must not mutate committed state')
menu.pending[prefix..'patrol_cd']=25
assert(config.commit({budget=4,language='zh'},'panel'))
assert(menu.get(prefix..'budget')==4 and menu.get(prefix..'language')==1)
assert(menu.pending[prefix..'patrol_cd']==25,'unrelated menu drafts must survive F8 apply')
calls,writes=stats(); bridge.pump(0.1)
local calls2,writes2=stats(); assert(calls==calls2 and writes==writes2,'set must not cause a feedback loop')
pass('F8 commits sync to MODS without loops or discarding unrelated drafts')

local before_calls=select(1,stats())
assert(config.commit({language='en'},'panel-language'))
assert(select(1,stats())==before_calls,'language must not reconfigure gameplay')
assert(config.current().budget==4 and menu.get(prefix..'language')==2)
pass('language-only change preserves gameplay and syncs to MODS')

local old=config.current()
for _,value in ipairs({0,7,0.15,math.huge,0/0}) do
    assert(not config.commit({budget=value},'bad'))
end
assert(not config.commit({language='fr'},'bad'))
assert(not config.commit({preset='bogus'},'bad'))
assert(not config.commit({budget=3,fast_corpse='false'},'bad'))
assert(config.current().budget==old.budget and patch.budget_multiplier==old.budget)
menu.apply({[prefix..'budget']=999,[prefix..'fast_corpse']=false})
bridge.pump(0.1)
assert(menu.get(prefix..'budget')==old.budget and config.current().budget==old.budget)
pass('invalid batches leave profile unchanged and restore menu values')

local saved=config.current()
local restarted,restored=fresh(saved)
local stale=fake_menu({[prefix..'budget']=1,[prefix..'language']=1})
local rebridge=create_options(restarted,{get_menu=function() return stale end})
rebridge.pump(0.1)
assert(restarted.restored and restarted.current().budget==4 and restored.budget_multiplier==4)
assert(stale.get(prefix..'budget')==4 and stale.get(prefix..'language')==2)
pass('ESM cfg is authoritative over stale menu saves after restart')

local no_cfg,from_menu,menu_stats=fresh()
local available=fake_menu({[prefix..'budget']=5,[prefix..'language']=2})
local later=nil
local delayed=create_options(no_cfg,{get_menu=function() return later end})
delayed.pump(1); assert(delayed.status=='waiting')
assert(no_cfg.commit({patrol_size=0.7},'panel'),'F8 works before menu loads')
later=available; delayed.pump(0.1)
assert(from_menu.budget_multiplier==2 and available.get(prefix..'patrol_size')==0.7)
pass('late menu registration cannot replace a profile already applied in F8')
local new_cfg,new_patch=fresh()
local import_bridge=create_options(new_cfg,{get_menu=function() return available end})
available.values={} -- registration returns the configured saved values
import_bridge.pump(0.1)
assert(new_patch.budget_multiplier==5 and new_cfg.current().language=='en')
pass('first launch may restore menu values when no ESM cfg exists')

local lookup=0
local missing=create_options(config,{get_menu=function() lookup=lookup+1; return nil end})
missing.pump(5); for _=1,20 do missing.pump(1) end
assert(missing.status=='unavailable' and lookup==1)
local incompatible=create_options(config,{get_menu=function() return {api=99} end})
incompatible.pump(1); assert(incompatible.status=='unavailable')
local refused=fake_menu(); refused.register_option=function() return false,'full' end
local full=create_options(config,{get_menu=function() return refused end})
full.pump(1); assert(full.status=='unavailable')
local throwing=fake_menu(); throwing.set=function() error('menu write failed') end
local throws=create_options(config,{get_menu=function() return throwing end})
throws.pump(1)
assert(config.commit({budget=4.5},'panel'))
assert(throws.status=='unavailable' and patch.budget_multiplier==4.5)
pass('missing, incompatible, full and throwing menus leave F8 gameplay usable')

local v1=fake_menu(nil,1)
local old_bridge=create_options(config,{get_menu=function() return v1 end})
old_bridge.pump(1)
assert(old_bridge.status=='ready' and type(v1.specs[prefix..'budget'].label)=='string')
pass('older v1 menu uses static labels and still synchronizes values')

-- File persistence uses the real codec and old cfg files stay readable.
local directory=build..'/shared-config-test'
os.execute('mkdir "'..directory:gsub('/','\\')..'" 2>nul')
local store=create_store({dir=directory})
assert(store.save(config.current()))
local disk=assert(store.load()); assert(disk.language=='en' and disk.fast_corpse==false)
assert(store.decode('version=1\nbudget=3\npreset=heavy\n').language==nil)
assert(store.decode('version=1\nlanguage=bogus\nbudget=2\n').language==nil)
pass('language persists with profile; legacy and malformed language values are safe')

-- Real Win32 F8 panel attached to the same configuration service.
local create_panel=assert(loadfile(source..'/panel.lua'))()
local panel=assert(create_panel(create_model,patch,{config=config,log=function() end}))
panel.model.pending.patrol_cd=25 -- staged, not applied
menu.apply({[prefix..'budget']=3,[prefix..'language']=1})
bridge.pump(0.1)
assert(panel.model.pending.budget==3 and panel.model.pending.patrol_cd==25)
assert(panel.model.language=='zh')
assert(panel.set_language('en'))
assert(config.current().patrol_cd==18 and panel.model.pending.patrol_cd==25)
assert(panel.model.layout().sliders[1].label=='Wave budget')
assert(panel.apply())
assert(config.current().patrol_cd==25 and menu.get(prefix..'patrol_cd')==25)
panel.close()
assert(config.commit({budget=2},'mods'),'closing F8 must not invalidate shared config')
pass('real F8 panel syncs menu updates, preserves drafts and applies back to MODS')

print(count..' MODS synchronization checks passed; no game memory touched.')
