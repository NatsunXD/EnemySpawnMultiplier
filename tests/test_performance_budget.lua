-- Reuse the current full gameplay fixture and count its real public API calls.
-- The fixture retains its original behavior assertions; no game process access.
local source, build, hash = assert(arg[1]), assert(arg[2]), assert(arg[3])
local file = assert(io.open(source .. '/../tests/test_data.lua','r'))
local code = file:read('*a');file:close()
local anchor='local function fill_row('
local pos=assert(code:find(anchor,1,true))
local instrumentation=[[
local perf={read=0,permission=0,write=0,bytes=0}
do
 local read,permission,write=api.read,api.writable_data,api.write
 api.read=function(a,n) perf.read=perf.read+1;perf.bytes=perf.bytes+n;return read(a,n) end
 api.writable_data=function(a,n) perf.permission=perf.permission+1;return permission(a,n) end
 api.write=function(a,b) perf.write=perf.write+1;return write(a,b) end
end
]]
local checks=[[
patch.template_bias_enabled=true
patch.template_bias_light,patch.template_bias_medium,patch.template_bias_heavy=0.25,1,4
patch.modifier_scale_enabled=true
patch.modifier_encounter_cooldown,patch.modifier_patrol_count=3,2
patch.modifier_patrol_cooldown,patch.modifier_travelers_max_unit=6,2
patch.probe_timers_enabled=true
patch.guardforce_write_enabled=false
patch.interval_mode,patch.allow_zero_interval_min='fixed',true
patch.fixed_interval_min,patch.fixed_interval_max=0,0.1
director_present=false;assert(patch.apply(api,game))
mission(vanilla,100,50);fill_config(20,40,8,14,10,30)
local function candidates(n)
 put_u32(director+patch.candidate_count_offset,n)
 for i=0,n-1 do
  local row=director+patch.candidate_pool_offset+i*patch.candidate_stride
  ffi.fill(row,patch.candidate_stride,0)
  put_u32(row,100+i);put_u32(row+4,8+i);put_u32(row+12,200+i);put_u32(row+16,40)
  put_u32(row+0x60,2);put_ptr(row+patch.candidate_template_offset,director+0x1000)
  put_f32(row+patch.candidate_weight_offset,1+i*0.1);put_f32(row+patch.candidate_cost_offset,20+i*4)
 end
end
candidates(11)
for _=1,6 do assert(patch.apply(api,game)) end
local function budget(name,maximum)
 perf.read,perf.permission,perf.write,perf.bytes=0,0,0,0
 for _=1,30 do local ok,reason=patch.apply(api,game);assert(ok and reason=='spawn_multiplier_ready',reason) end
 assert(perf.read<=maximum*30 and perf.permission<=6*30 and perf.write==0,
  name..' exceeded no-op API budget: '..(perf.read/30)..'/'..(perf.permission/30)..'/'..perf.write)
 print(string.format('BUDGET %s reads/pass=%.0f permission/pass=%.0f writes/pass=%.0f bytes/pass=%.0f',
  name,perf.read/30,perf.permission/30,perf.write/30,perf.bytes/30))
end
budget('hash, 11 candidates',70)
local key=string.char(239,205,171,137,103,69,35,241)
ffi.copy(handle,key,8);put_u32(handle+8,0xFFFFFFFF)
ffi.copy(resource_root+15*16,key,8);put_u32(resource_root+15*16+8,1)
ffi.copy(resource_root+0x260+patch.cfg_stride,director+patch.cfg_base_offset,patch.cfg_stride)
assert(patch.apply(api,game))
for _=1,6 do assert(patch.apply(api,game)) end
assert(patch.detail:find('cfg=resource:1',1,true))
budget('resource, 11 candidates',70)
director_present=false;assert(patch.apply(api,game))
mission(faction_caps(64,500),100,50);fill_config(20,40,8,14,10,30);candidates(64)
for _=1,6 do assert(patch.apply(api,game)) end
budget('hash, 64 candidates',125)
-- Many owner transitions must hit a finite retention ceiling without recycling
-- any object which native code may still reference.
for i=1,220 do
 director_present=false;assert(patch.apply(api,game))
 mission(vanilla,100,50);fill_config(20,40,8,14,10,30)
 ffi.copy(handle,key,8);put_u32(handle+8,0xFFFFFFFF)
 ffi.copy(resource_root+15*16,key,8);put_u32(resource_root+15*16+8,1)
 ffi.copy(resource_root+0x260+patch.cfg_stride,director+patch.cfg_base_offset,patch.cfg_stride)
 assert(patch.apply(api,game))
end
assert(patch.diag.retained_clone_bytes<=8*1024*1024 and patch.diag.retained_clone_bytes>7*1024*1024)
assert(patch.detail:find('spawn_config_resource_clone_alloc_failed',1,true)
 or patch.detail:find('spawn_config_resource_retry_limit',1,true),'long session clone quota did not fail closed')
print('PASS: retained native-visible clones are bounded to 8 MiB for a long session')
]]
code=code:sub(1,pos-1)..instrumentation..code:sub(pos)..checks
arg={source,build,hash}
assert(loadstring(code,'@performance-gameplay-fixture'))()
