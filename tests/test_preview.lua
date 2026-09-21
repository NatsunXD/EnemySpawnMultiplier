-- Preview profile checks: low Encounter budget, near-zero timed paths, native GuardForce.
local source, build, executable_hash = assert(arg[1]), assert(arg[2]), assert(arg[3])
local ffi = require('ffi')
local create_api = assert(loadfile(source .. '/windows_api.lua'))()
local patch = assert(loadfile(source .. '/spawn_patch.lua'))()

-- Mirror the overrides emitted by scripts/module.py for the preview variant.
patch.budget_multiplier = 0.4
patch.budget_override_multiplier = 0.4
patch.derive_override_from_base = false
patch.force_override_to_base = true
patch.encounter_deadline_enabled = true
patch.encounter_max_interval = 2.0
patch.probe_timers_enabled = true
patch.traveler_cooldown_enabled = false
patch.traveler_cooldown_min = 0.0
patch.traveler_cooldown_max = 0.0
patch.modifier_scale_enabled = true
patch.modifier_encounter_cooldown = 3.0
patch.modifier_patrol_count = 3.0
patch.modifier_patrol_cooldown = 3.0
patch.modifier_travelers_max_unit = 10.0
patch.template_bias_enabled = true
patch.template_bias_light = 0.25
patch.template_bias_medium = 1.0
patch.template_bias_heavy = 4.0
patch.guardforce_write_enabled = false
patch.illuminate_guardforce_multiplier = 1.0
patch.interval_mode = 'fixed'
patch.fixed_interval_min = 0.0
patch.fixed_interval_max = 0.1
patch.allow_zero_interval_min = true
patch.cap_multiplier = 10
patch.group_multiplier = 10

local real = create_api()
local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end
assert(real.module_hash(real.module(nil)) == executable_hash)
assert(real.read(ffi.cast('void *', 1), 8) == nil)
assert(not real.writable_data(real.module(nil), 1))

local DIRECTOR_SIZE = 0x54000
local director_storage = ffi.new('uint8_t[?]', DIRECTOR_SIZE)
local director = ffi.cast('uint8_t *', director_storage)
local bias_templates_storage = ffi.new('uint8_t[?]', 16 * 0x100)
local bias_templates = ffi.cast('uint8_t *', bias_templates_storage)
local header_storage = ffi.new('uint8_t[?]', patch.cap_header_size)
local header = ffi.cast('uint8_t *', header_storage)
local entries_storage = ffi.new('uint8_t[?]', 64 * patch.entry_stride)
local entries = ffi.cast('uint8_t *', entries_storage)
local mode_storage = ffi.new('uint8_t[0x44]')
local mode = ffi.cast('uint8_t *', mode_storage)
local game_storage = ffi.new('uint8_t[1]')
local game = ffi.cast('uint8_t *', game_storage)
local time_storage = ffi.new('uint8_t[32]')
local time = ffi.cast('uint8_t *', time_storage)
local handle_storage = ffi.new('uint8_t[16]')
local handle = ffi.cast('uint8_t *', handle_storage)
local hash_storage = ffi.new('uint8_t[64]')
local hash_table = ffi.cast('uint8_t *', hash_storage)
local resource_manager_storage = ffi.new('uint8_t[?]', patch.resource_table_offset + 8)
local resource_manager = ffi.cast('uint8_t *', resource_manager_storage)
local resource_storage = ffi.new('uint8_t[?]', 0x260 + 38 * patch.cfg_stride)
local resource_root = ffi.cast('uint8_t *', resource_storage)
local resource_root_live = resource_root
local director_present, mode_present, time_present, writes = false, false, false, 0
local encounter_deadline_unwritable = false

local function pointer(value) return ffi.string(ffi.new('void *[1]', value), 8) end
local function put_ptr(dest, value) ffi.copy(dest, ffi.new('void *[1]', value), 8) end
local function put_u32(dest, value) ffi.copy(dest, ffi.new('uint32_t[1]', value), 4) end
local function put_f32(dest, value) ffi.copy(dest, ffi.new('float[1]', value), 4) end
local function put_u64(dest, value) ffi.copy(dest, ffi.new('uint64_t[1]', value), 8) end
local function get_u32(dest)
    local value = ffi.new('uint32_t[1]')
    ffi.copy(value, dest, 4)
    return tonumber(value[0])
end
local function get_f32(dest)
    local value = ffi.new('float[1]')
    ffi.copy(value, dest, 4)
    return tonumber(value[0])
end
local function get_u64(dest)
    local value = ffi.new('uint64_t[1]')
    ffi.copy(value, dest, 8)
    return tonumber(value[0])
end

local api = setmetatable({}, {__index = real})
api.read = function(address, size)
    if real.distance(address, game + patch.cfg_invalid_generation_rva) == 0 then
        return string.rep('\255', 4)
    end
    if real.distance(address, game + patch.resource_manager_rva) == 0 then
        return pointer(resource_manager)
    end
    if real.distance(address, resource_manager + patch.resource_table_offset) == 0 then
        return pointer(resource_root_live)
    end
    if real.distance(address, game + patch.director_rva) == 0 then
        assert(size == 8)
        if not director_present then return string.rep('\0', 8) end
        return pointer(director)
    end
    if real.distance(address, game + patch.mode_rva) == 0 then
        assert(size == 8)
        if not mode_present then return string.rep('\0', 8) end
        return pointer(mode)
    end
    if real.distance(address, game + patch.time_rva) == 0 then
        assert(size == 8)
        if not time_present then return string.rep('\0', 8) end
        return pointer(time)
    end
    return real.read(address, size)
end
api.write = function(address, bytes)
    writes = writes + 1
    local result = real.write(address, bytes)
    if result and real.distance(address, resource_manager + patch.resource_table_offset) == 0 then
        resource_root_live = api.pointer(bytes)
    end
    return result
end
api.writable_data = function(address, size)
    if encounter_deadline_unwritable
        and real.distance(address, director + patch.encounter_deadline_offset) == 0 then
        return false
    end
    return real.writable_data(address, size)
end

local function fill_row(base, index, ident, maximum)
    local row = base + index * patch.entry_stride
    ffi.fill(row, patch.entry_stride, 0)
    put_u32(row, ident)
    put_u32(row + patch.max_offset, maximum)
end
local function fill_entry(index, ident, maximum) fill_row(entries, index, ident, maximum) end
local function faction_caps(rows, first)
    local caps = {}
    for index = 1, rows do caps[index] = {first + index, 1} end
    return caps
end

local function mission(caps, points, guardforce)
    director_present, mode_present, time_present = true, true, true
    ffi.fill(director_storage, DIRECTOR_SIZE, 0)
    ffi.fill(header_storage, patch.cap_header_size, 0)
    ffi.fill(entries_storage, 64 * patch.entry_stride, 0)
    ffi.fill(mode_storage, 0x44, 0)
    ffi.fill(time_storage, 32, 0)
    ffi.fill(handle_storage, 16, 0)
    ffi.fill(hash_storage, 64, 0)
    ffi.fill(resource_storage, ffi.sizeof(resource_storage), 0)
    resource_root_live = resource_root
    put_u32(mode + 8, 1)
    put_u64(time + 0x18, 1000000)
    put_u32(handle + 8, 123)
    put_ptr(director + patch.cfg_handle_offset, handle)
    put_ptr(director + patch.cfg_table_offset, hash_table)
    put_u32(director + patch.cfg_count_offset, 1)
    put_u32(director + patch.cfg_hash_multiplier_offset, 0)
    put_u32(director + patch.cfg_sentinel_offset, 0)
    put_u32(hash_table, 123)
    put_u32(hash_table + 4, 0)
    put_ptr(director + patch.cap_table_offset, header)
    put_ptr(header, entries)
    put_u32(header + 8, #caps)
    for index, cap in ipairs(caps) do fill_entry(index - 1, cap[1], cap[2]) end
    put_f32(director + patch.points_offset, points)
    put_f32(director + patch.points_offset + 4, guardforce)
end

local function fill_config(min8, max8, min1, max1, group, desired, override)
    local cfg = director + patch.cfg_base_offset
    put_f32(cfg + 0x0c, 30)
    put_f32(cfg + 0x10, 60)
    for index = 0, 14 do
        put_f32(cfg + 0x164 + index * 4, 1.0)
        put_f32(cfg + 0x1a0 + index * 4, 1.0)
        put_f32(cfg + 0x1dc + index * 4, 1.0)
        put_f32(cfg + 0x3f8 + index * 4, 1.0)
    end
    put_f32(cfg + 0x38, min8)
    put_f32(cfg + 0x3c, max8)
    put_f32(cfg + 0x40, min1)
    put_f32(cfg + 0x44, max1)
    put_u32(cfg + 0x48, group)
    put_u32(cfg + 0x50, desired or 30)
    put_f32(cfg + patch.cfg_override_offset, override)
    put_f32(cfg + 0x80, 2)
end
local function fill_candidate(index, weight, cost, units)
    local candidate = director + patch.candidate_pool_offset + index * patch.candidate_stride
    local template = bias_templates + index * 0x100
    ffi.fill(candidate, patch.candidate_stride, 0)
    ffi.fill(template, 0x100, 0)
    put_u32(candidate, index + 1)
    put_u32(candidate + 4, units)
    put_u32(candidate + 0x60, 1)
    put_ptr(candidate + patch.candidate_template_offset, template)
    put_f32(candidate + patch.candidate_weight_offset, weight)
    put_f32(candidate + patch.candidate_cost_offset, cost)
end
local function candidate_weight(index)
    return get_f32(director + patch.candidate_pool_offset
        + index * patch.candidate_stride + patch.candidate_weight_offset)
end
local function approx(a, b) return math.abs(a - b) <= 0.002 end
local function assert_config(min8, max8, min1, max1, group, desired)
    local cfg = director + patch.cfg_base_offset
    assert(approx(get_f32(cfg + 0x38), min8))
    assert(approx(get_f32(cfg + 0x3c), max8))
    assert(approx(get_f32(cfg + 0x40), min1))
    assert(approx(get_f32(cfg + 0x44), max1))
    assert(get_u32(cfg + 0x48) == group)
    assert(get_u32(cfg + 0x50) == (desired or 30))
    assert(approx(get_f32(cfg + 0x80), 2))
end

-- Fresh mission: Encounter falls to 0.1x, GuardForce remains native, timed paths
-- use 0.0-0.1 seconds, the enemy reinforcement cooldown is clamped to two
-- seconds, and pending deadlines are clamped to their new maximum.
director_present = false
assert(patch.apply(api, game))
mission(faction_caps(45, 2000), 100, 600)
fill_config(20, 40, 8, 14, 10, 30, -1)
put_u64(director + patch.timer_offsets[1], 41000000)
put_u64(director + patch.timer_offsets[2], 15000000)
put_u64(director + patch.encounter_deadline_offset, 61000000)
local ok, reason, active = patch.apply(api, game)
assert(ok and active and reason == 'spawn_multiplier_ready')
assert(approx(get_f32(director + patch.points_offset), 40))
assert(approx(get_f32(director + patch.points_offset + 4), 600))
assert_config(0, 0.1, 0, 0.1, 100, 30)
assert(approx(get_f32(director + patch.cfg_base_offset + patch.cfg_override_offset), 40))
assert(get_u32(entries + patch.max_offset) == 10)
assert(get_u64(director + patch.timer_offsets[1]) == 1100000)
assert(get_u64(director + patch.timer_offsets[2]) == 1100000)
assert(get_u64(director + patch.encounter_deadline_offset) == 3000000)
assert(patch.detail:find('p=40.0/100.0', 1, true))
assert(patch.detail:find('o=40.00', 1, true))
assert(patch.detail:find('e=', 1, true) and patch.detail:find('m=', 1, true))
assert(patch.detail:find('a=', 1, true) and patch.detail:find('b=', 1, true))
assert(patch.detail:find('pd=', 1, true) and patch.detail:find('sd=', 1, true))
assert(patch.detail:find('fl=', 1, true))
assert(patch.detail:find(' T=', 1, true))
assert(patch.detail:find('gf=600.0/600.0', 1, true))
assert(patch.detail:find('i=0.00-0.10/0.00-0.10', 1, true))
assert(patch.detail:find('g=100', 1, true))
assert(patch.detail:find('d=30', 1, true))
assert(patch.detail:find('t=3', 1, true))
assert(patch.detail:find('tv=30.0-60.0', 1, true))
assert(patch.detail:find('ms=3.0/3.0/3.0/10.0', 1, true))
assert(patch.detail:find('mv=3.00/3.00/3.00/10.00', 1, true))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x164), 3.0))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x1a0), 3.0))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x1dc), 3.0))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x164 + 14 * 4), 3.0))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x3f8), 10.0))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x3f8 + 14 * 4), 10.0))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x0c), 30))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x10), 60))
pass('preview lowers Encounter to 0.4x and clamps the reinforcement cooldown to two seconds')

local settled_writes = writes
ok, reason, active = patch.apply(api, game)
assert(ok and active and writes == settled_writes)
assert(approx(get_f32(director + patch.points_offset), 40))
assert(approx(get_f32(director + patch.points_offset + 4), 600))
assert_config(0, 0.1, 0, 0.1, 100, 30)
assert(get_u64(director + patch.encounter_deadline_offset) == 3000000)
assert(approx(get_f32(director + patch.cfg_base_offset + 0x0c), 30))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x10), 60))
pass('preview budget, interval and cooldown writes are idempotent')

-- A pending reinforcement cooldown that is already due or inside the new window
-- is left untouched, and an unwritable field fails closed instead of half-applying.
director_present = false
assert(patch.apply(api, game))
mission(faction_caps(45, 2000), 100, 600)
fill_config(20, 40, 8, 14, 10, 30, -1)
put_u64(director + patch.encounter_deadline_offset, 1500000)
ok, reason, active = patch.apply(api, game)
assert(ok and active)
assert(get_u64(director + patch.encounter_deadline_offset) == 1500000)
encounter_deadline_unwritable = true
put_u64(director + patch.encounter_deadline_offset, 61000000)
local frozen = ffi.string(director + patch.encounter_deadline_offset, 8)
ok, reason, active = patch.apply(api, game)
assert(ok and active)
assert(ffi.string(director + patch.encounter_deadline_offset, 8) == frozen)
assert(patch.detail:find('n=spawn_encounter_timer_not_writable_private_data', 1, true))
encounter_deadline_unwritable = false
pass('cooldown clamp leaves due deadlines alone and reports an unwritable field')

-- A strict preview ignores the native override value and forces the resolved
-- config to the already-scaled director base, preventing a positive override
-- from bypassing the 0.4x budget.
director_present = false
assert(patch.apply(api, game))
mission(faction_caps(45, 2000), 100, 600)
fill_config(20, 40, 8, 14, 10, 30, 20)
ok, reason, active = patch.apply(api, game)
assert(ok and active)
assert(approx(get_f32(director + patch.cfg_base_offset + patch.cfg_override_offset), 40))
local override_writes = writes
ok, reason, active = patch.apply(api, game)
assert(ok and active and writes == override_writes)
assert(approx(get_f32(director + patch.cfg_base_offset + patch.cfg_override_offset), 40))
pass('strict preview forces the effective override to the scaled base and remains idempotent')

-- Difficulty modifier blocks must scale from the stored baseline. A second pass
-- over the already-scaled row must not multiply them again.
director_present = false
assert(patch.apply(api, game))
mission(faction_caps(45, 2000), 100, 600)
fill_config(0, 0.1, 0, 0.1, 100, 30, -1)
ok, reason, active = patch.apply(api, game)
assert(ok and active)
assert(approx(get_f32(director + patch.cfg_base_offset + 0x164), 3.0))
local modifier_writes = writes
ok, reason, active = patch.apply(api, game)
assert(ok and active and writes == modifier_writes)
assert(approx(get_f32(director + patch.cfg_base_offset + 0x164), 3.0))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x1dc + 14 * 4), 3.0))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x3f8 + 14 * 4), 10.0))
pass('already-scaled difficulty modifier blocks are not scaled twice')

-- A block the game re-blends for a new difficulty must adopt the new native
-- value as its baseline instead of stacking the previous scale on top.
put_f32(director + patch.cfg_base_offset + 0x1a0, 2.0)
ok, reason, active = patch.apply(api, game)
assert(ok and active)
assert(approx(get_f32(director + patch.cfg_base_offset + 0x1a0), 6.0))
put_f32(director + patch.cfg_base_offset + 0x1a0, 2.0)
ok, reason, active = patch.apply(api, game)
assert(ok and active)
assert(approx(get_f32(director + patch.cfg_base_offset + 0x1a0), 6.0))
pass('a re-blended modifier block is re-scaled once from its new native value')

-- A config already in the preview state must not multiply its group or intervals again.
director_present = false
assert(patch.apply(api, game))
mission(faction_caps(45, 2000), 100, 600)
fill_config(0, 0.1, 0, 0.1, 100, 30, -1)
ok, reason, active = patch.apply(api, game)
assert(ok and active)
assert_config(0, 0.1, 0, 0.1, 100, 30)
assert(approx(get_f32(director + patch.points_offset), 40))
assert(approx(get_f32(director + patch.points_offset + 4), 600))
pass('preview does not stack on an already-scaled config')

-- A zero maximum interval would make the native path skip; the preview must
-- reject that layout and leave the config untouched rather than disabling spawns.
director_present = false
assert(patch.apply(api, game))
mission(faction_caps(45, 2000), 100, 600)
fill_config(20, 0, 8, 14, 10, 30, -1)
local cfg_before = ffi.string(director + patch.cfg_base_offset + 0x38, 0x1c)
ok, reason, active = patch.apply(api, game)
assert(ok and active and reason == 'spawn_multiplier_partial')
assert(patch.detail:find('spawn_config_layout_mismatch', 1, true))
assert(ffi.string(director + patch.cfg_base_offset + 0x38, 0x1c) == cfg_before)
assert(approx(get_f32(director + patch.cfg_base_offset + 0x3c), 0))
pass('preview rejects zero maximum intervals instead of disabling the timed path')

-- Heavy-focus bias: candidates are ranked by cost per planned unit, so the
-- costliest quintile is the heavy tier. It must gain weight while the cheapest
-- half loses weight, and a second pass must not stack the change.
director_present = false
assert(patch.apply(api, game))
mission(faction_caps(45, 2000), 100, 600)
fill_config(20, 40, 8, 14, 10, 30, -1)
put_u32(director + patch.candidate_count_offset, 5)
fill_candidate(0, 1.0, 10.0, 10)
fill_candidate(1, 1.0, 20.0, 10)
fill_candidate(2, 1.0, 30.0, 10)
fill_candidate(3, 1.0, 80.0, 10)
fill_candidate(4, 1.0, 200.0, 10)
ok, reason, active = patch.apply(api, game)
assert(ok and active and reason == 'spawn_multiplier_ready')
assert(patch.detail:find('w=5/5', 1, true))
assert(approx(candidate_weight(0), 0.25))
assert(approx(candidate_weight(1), 0.25))
assert(approx(candidate_weight(2), 0.25))
assert(approx(candidate_weight(3), 1.0))
assert(approx(candidate_weight(4), 4.0))
local bias_writes = writes
ok, reason, active = patch.apply(api, game)
assert(ok and active and writes == bias_writes)
assert(approx(candidate_weight(4), 4.0))
assert(approx(candidate_weight(0), 0.25))
pass('heavy tier candidates gain weight and the bias does not stack')

print(count .. ' preview profile checks passed; no executable code was modified.')
