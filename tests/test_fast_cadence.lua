-- Fast Cadence profile checks: reduced Encounter budget, near-zero timed paths, native GuardForce,
-- scaled cooldown/patrol curves and heavy-focus candidate weighting.
local source, build, executable_hash = assert(arg[1]), assert(arg[2]), assert(arg[3])
-- The same profile checks serve Fast Cadence (6x/6x) and the local 2x/3x patrol
-- preview. Expected patrol scales are passed by the builder so neither variant
-- silently drifts from the other.
local expected_patrol_count = tonumber(arg[4]) or 6.0
local expected_travelers_max_unit = tonumber(arg[5]) or 6.0
local ffi = require('ffi')
local create_api = assert(loadfile(source .. '/windows_api.lua'))()
local patch = assert(loadfile(source .. '/spawn_patch.lua'))()

-- Mirror the overrides emitted by scripts/module.py for the Fast Cadence variant.
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
patch.modifier_patrol_count = expected_patrol_count
patch.modifier_patrol_cooldown = 3.0
patch.modifier_travelers_max_unit = expected_travelers_max_unit
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
assert(patch.detail:find(string.format('ms=3.0/%.1f/3.0/%.1f', expected_patrol_count, expected_travelers_max_unit), 1, true))
assert(patch.detail:find(string.format('mv=3.00/%.2f/3.00/%.2f', expected_patrol_count, expected_travelers_max_unit), 1, true))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x164), 3.0))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x1a0), expected_patrol_count))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x1dc), 3.0))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x164 + 14 * 4), 3.0))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x3f8), expected_travelers_max_unit))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x3f8 + 14 * 4), expected_travelers_max_unit))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x0c), 30))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x10), 60))
pass('fast cadence lowers Encounter to 0.4x and clamps the reinforcement cooldown to two seconds')

local settled_writes = writes
ok, reason, active = patch.apply(api, game)
assert(ok and active and writes == settled_writes)
assert(approx(get_f32(director + patch.points_offset), 40))
assert(approx(get_f32(director + patch.points_offset + 4), 600))
assert_config(0, 0.1, 0, 0.1, 100, 30)
assert(get_u64(director + patch.encounter_deadline_offset) == 3000000)
assert(approx(get_f32(director + patch.cfg_base_offset + 0x0c), 30))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x10), 60))
pass('fast cadence budget, interval and cooldown writes are idempotent')

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

-- A strict Fast Cadence profile ignores the native override value and forces the resolved
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
pass('strict fast cadence forces the effective override to the scaled base and remains idempotent')

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
assert(approx(get_f32(director + patch.cfg_base_offset + 0x3f8 + 14 * 4), expected_travelers_max_unit))
pass('already-scaled difficulty modifier blocks are not scaled twice')

-- A block the game re-blends for a new difficulty must adopt the new native
-- value as its baseline instead of stacking the previous scale on top. The probe
-- deliberately avoids the native 1.0: with a 2.0x profile a 2.0 probe would already
-- equal the scaled target and the write could not be observed.
local reblend_native = 2.5
put_f32(director + patch.cfg_base_offset + 0x1a0, reblend_native)
ok, reason, active = patch.apply(api, game)
assert(ok and active)
assert(approx(get_f32(director + patch.cfg_base_offset + 0x1a0), reblend_native * expected_patrol_count))
put_f32(director + patch.cfg_base_offset + 0x1a0, reblend_native)
ok, reason, active = patch.apply(api, game)
assert(ok and active)
assert(approx(get_f32(director + patch.cfg_base_offset + 0x1a0), reblend_native * expected_patrol_count))
pass('a re-blended modifier block is re-scaled once from its new native value')

-- A config already in the Fast Cadence state must not multiply its group or intervals again.
director_present = false
assert(patch.apply(api, game))
mission(faction_caps(45, 2000), 100, 600)
fill_config(0, 0.1, 0, 0.1, 100, 30, -1)
ok, reason, active = patch.apply(api, game)
assert(ok and active)
assert_config(0, 0.1, 0, 0.1, 100, 30)
assert(approx(get_f32(director + patch.points_offset), 40))
assert(approx(get_f32(director + patch.points_offset + 4), 600))
pass('fast cadence does not stack on an already-scaled config')

-- A zero maximum interval would make the native path skip; the Fast Cadence profile must
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
pass('fast cadence rejects zero maximum intervals instead of disabling the timed path')

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

-- Live reconfiguration: the in-game panel assigns into the same fields while a
-- mission is running, and the next updater pass must apply the new profile
-- without stacking on the values this profile already wrote.
director_present = false
assert(patch.apply(api, game))
mission(faction_caps(45, 2000), 100, 600)
fill_config(20, 40, 8, 14, 10, 30, -1)
ok, reason, active = patch.apply(api, game)
assert(ok and active)
local scaled_points = get_f32(director + patch.points_offset)
assert(scaled_points ~= 100)
assert(patch.configure{budget = 2.0, patrol_count = 2.0, patrol_size = 3.0,
                       encounter_cd_seconds = 30.0, patrol_cd_seconds = 30.0,
                       preset = 'heavy'})
ok, reason, active = patch.apply(api, game)
assert(ok and active)
-- 100 native points x the new 2x budget, not the previous scaled value x 2.
assert(approx(get_f32(director + patch.points_offset), 200))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x1a0), 2.0))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x3f8), 3.0))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x164), 1.0))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x1dc), 1.0))
local live_writes = writes
ok, reason, active = patch.apply(api, game)
assert(ok and active and writes == live_writes)
pass('live budget, patrol and cooldown reconfiguration applies without stacking')

-- A mid-range cooldown position must interpolate the rate curve rather than
-- snapping to one of the two ends, and the reinforcement deadline must follow.
director_present = false
assert(patch.apply(api, game))
mission(faction_caps(45, 2000), 100, 600)
fill_config(20, 40, 8, 14, 10, 30, -1)
assert(patch.configure{encounter_cd_seconds = 16.0, patrol_cd_seconds = 9.0})
ok, reason, active = patch.apply(api, game)
assert(ok and active)
local enc_rate = get_f32(director + patch.cfg_base_offset + 0x164)
local patrol_rate = get_f32(director + patch.cfg_base_offset + 0x1dc)
-- The two paths have different fastest-end scales, so each is bounded by its
-- own rate.
assert(enc_rate > 1.0 and enc_rate < patch.cooldown_fast_rate)
assert(patrol_rate > 1.0 and patrol_rate < patch.patrol_cooldown_fast_rate)
assert(enc_rate ~= patrol_rate)
assert(approx(patch.encounter_max_interval, 16.0))
assert(patch.encounter_deadline_enabled == true)
pass('mid-range cooldown positions interpolate the rate curve')

-- The patrol fastest end is the requested 6x, while reinforcement stays at 3x;
-- both slow ends return to native 1.0.
director_present = false
assert(patch.apply(api, game))
mission(faction_caps(45, 2000), 100, 600)
fill_config(20, 40, 8, 14, 10, 30, -1)
assert(patch.configure{encounter_cd_seconds = 2.0, patrol_cd_seconds = 2.0})
ok, reason, active = patch.apply(api, game)
assert(ok and active)
assert(approx(get_f32(director + patch.cfg_base_offset + 0x1dc), 6.0))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x164), 3.0))
assert(patch.configure{encounter_cd_seconds = 30.0, patrol_cd_seconds = 30.0})
ok, reason, active = patch.apply(api, game)
assert(ok and active)
assert(approx(get_f32(director + patch.cfg_base_offset + 0x1dc), 1.0))
assert(approx(get_f32(director + patch.cfg_base_offset + 0x164), 1.0))
pass('patrol fast end is 6x, reinforcement stays 3x, both slow ends are native')

-- Direction: sliding right (longer target seconds) must lengthen the effective
-- cooldown, i.e. lower the rate. The previous UI had this inverted.
director_present = false
assert(patch.apply(api, game))
mission(faction_caps(45, 2000), 100, 600)
fill_config(20, 40, 8, 14, 10, 30, -1)
assert(patch.configure{encounter_cd_seconds = 2.0})
ok, reason, active = patch.apply(api, game)
assert(ok and active)
local fast_rate = get_f32(director + patch.cfg_base_offset + 0x164)
assert(patch.configure{encounter_cd_seconds = 30.0})
ok, reason, active = patch.apply(api, game)
assert(ok and active)
local slow_rate = get_f32(director + patch.cfg_base_offset + 0x164)
assert(fast_rate > slow_rate, 'fast end must yield a higher rate than the slow end')
assert(approx(slow_rate, 1.0))
assert(approx(fast_rate, patch.cooldown_fast_rate))
pass('sliding toward slow lengthens the cooldown (direction is not inverted)')



-- Switching the preset back to native must undo the candidate weights already
-- written, not just stop touching them.
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
assert(ok and active)
assert(approx(candidate_weight(4), 4.0))
assert(patch.configure{preset = 'native'})
ok, reason, active = patch.apply(api, game)
assert(ok and active)
for index = 0, 4 do assert(approx(candidate_weight(index), 1.0)) end
pass('live preset switch back to native restores every candidate weight')

-- Out-of-range settings must be rejected without disturbing the live values.
local before_budget = patch.budget_multiplier
local ok_range, range_reason = patch.configure{budget = 99.0}
assert(ok_range == false and range_reason == 'budget_out_of_range')
assert(patch.budget_multiplier == before_budget)
local ok_preset, preset_reason = patch.configure{preset = 'nonsense'}
assert(ok_preset == false and preset_reason == 'preset_unknown')
assert(patch.configure{budget = 99.0} == false)
pass('rejected live settings leave the active configuration untouched')

-- Integration: progression compensation changes only the five progression
-- floats, keeps zero sentinels, restores on disabling, and never stacks.
director_present=false;assert(patch.apply(api,game))
mission(faction_caps(45,2000),100,600)
fill_config(20,40,8,14,10,30,-1)
assert(patch.configure{patrol_count=2,patrol_size=1.5,encounter_cd_seconds=30,patrol_cd_seconds=30,preset='native'})
local cfg=director+patch.cfg_base_offset
local blocks={0x164,0x1a0,0x1dc,0x3f8}
for _,off in ipairs(blocks) do
    put_f32(cfg+off,1.3)
    for i=1,4 do put_f32(cfg+off+i*4,1.3+i*0.1) end
    put_f32(cfg+off+3*4,0) -- native zero remains a zero
    put_f32(cfg+off+5*4,2.2)
end
local create_dynamic=assert(loadfile(source..'/dynamic_spawn.lua'))()
assert(patch.configure{dynamic_spawn=true})
patch.dynamic=create_dynamic().create(api,patch,true)
assert(patch.apply(api,game))
for _,off in ipairs(blocks) do
    local scale=off==0x1a0 and 2 or off==0x3f8 and 1.5 or 1
    for i=0,4 do assert(approx(get_f32(cfg+off+i*4),(i==3 and 0 or 1.3*scale))) end
    assert(approx(get_f32(cfg+off+5*4),2.2*scale))
end
local stable_writes=writes
assert(patch.apply(api,game));assert(writes==stable_writes,'unchanged curves must not be rewritten')
assert(patch.modifier_patrol_count==2 and patch.modifier_travelers_max_unit==1.5)
assert(patch.dynamic.progress_enabled and patch.dynamic.effective.phase=='progression_only')
assert(patch.dynamic.sample==nil)
pass('real progression-only session writes initial-tier curves at requested multipliers, preserves zeros and does not stack')
assert(patch.configure{dynamic_spawn=false})
assert(patch.apply(api,game))
for _,off in ipairs(blocks) do
    local scale=off==0x1a0 and 2 or off==0x3f8 and 1.5 or 1
    for i=0,4 do assert(approx(get_f32(cfg+off+i*4),(i==3 and 0 or (1.3+i*0.1)*scale))) end
end
pass('switching compensation off restores original progression and requested multipliers')
-- All-one profiles still restore after turning compensation off.
director_present=false;assert(patch.apply(api,game));patch.dynamic=nil
mission(faction_caps(45,2000),100,600);fill_config(20,40,8,14,10,30,-1)
assert(patch.configure{patrol_count=1,patrol_size=1,encounter_cd_seconds=30,patrol_cd_seconds=30})
patch.modifier_scale_enabled=false
put_f32(director+patch.cfg_base_offset+0x1a0+16,1.3)
assert(patch.configure{dynamic_spawn=true})
patch.dynamic=create_dynamic().create(api,patch,true)
assert(patch.apply(api,game));assert(approx(get_f32(director+patch.cfg_base_offset+0x1a0+16),1))
assert(patch.configure{dynamic_spawn=false})
assert(patch.apply(api,game));assert(approx(get_f32(director+patch.cfg_base_offset+0x1a0+16),1.3))
pass('all-one profiles also restore progression after compensation is disabled')
-- Unified v24 policy: all 65 progression entries are exactly neutral, while
-- user scales remain on the other existing axes. Both extraction sources are
-- attenuated from a saved native baseline, including OFF/ON and foreign edits.
director_present=false;assert(patch.apply(api,game));patch.dynamic=nil
mission(faction_caps(45,2000),100,600);fill_config(20,40,8,14,10,30,-1)
cfg=director+patch.cfg_base_offset
patch.dynamic_curve_policy='unit_all_half_extraction'
local all_blocks={0x128,0x164,0x1a0,0x1dc,0x218,0x254,0x290,0x2cc,0x308,0x344,0x380,0x3bc,0x3f8}
for _,off in ipairs(all_blocks) do
    for i=0,14 do put_f32(cfg+off+i*4,1+i*0.1) end
    put_f32(cfg+off+12,0)
    put_f32(cfg+off+36,1.4)
end
for i,off in ipairs({0x104,0x110,0x11c}) do
    put_f32(cfg+off,1);put_f32(cfg+off+4,i==3 and 4 or i==2 and 1.5 or 1.2)
    put_f32(cfg+off+8,200)
end
put_f32(cfg+0xe0,1.7) -- influence curve outside extraction must stay native
assert(patch.configure{dynamic_spawn=true,patrol_count=2,patrol_size=1.5,
    encounter_cd_seconds=30,patrol_cd_seconds=2})
patch.dynamic=create_dynamic().create(api,patch,true)
local function assert_unit_curves()
    for _,off in ipairs(all_blocks) do
        local scale=off==0x1a0 and 2 or off==0x3f8 and 1.5 or off==0x1dc and 6 or 1
        for i=0,4 do assert(approx(get_f32(cfg+off+i*4),1)) end
        for i=5,14 do
            assert(approx(get_f32(cfg+off+i*4),(i==9 and 1.2 or 1+i*0.1)*scale))
        end
    end
    assert(approx(get_f32(cfg+0x108),1.1) and approx(get_f32(cfg+0x114),1.25)
        and approx(get_f32(cfg+0x120),1.2))
    for _,off in ipairs({0x104,0x110,0x11c}) do
        assert(approx(get_f32(cfg+off),1) and approx(get_f32(cfg+off+8),200))
    end
    assert(approx(get_f32(cfg+0xe0),1.7))
end
assert(patch.apply(api,game));assert_unit_curves()
stable_writes=writes;assert(patch.apply(api,game));assert(writes==stable_writes)
assert(patch.configure{dynamic_spawn=false});assert(patch.apply(api,game))
for _,off in ipairs(all_blocks) do
    local scale=off==0x1a0 and 2 or off==0x3f8 and 1.5 or off==0x1dc and 6 or 1
    for i=0,4 do assert(approx(get_f32(cfg+off+i*4),(i==3 and 0 or 1+i*0.1)*scale)) end
    assert(approx(get_f32(cfg+off+36),1.4*scale))
end
assert(approx(get_f32(cfg+0x120),4))
assert(patch.configure{dynamic_spawn=true});assert(patch.apply(api,game));assert_unit_curves()
-- Reductions/zero disable sentinels in extraction are not bonuses.
put_f32(cfg+0x104,0.8);put_f32(cfg+0x128+36,0)
put_f32(cfg+0x120,6)
assert(patch.apply(api,game))
assert(approx(get_f32(cfg+0x104),0.8) and get_f32(cfg+0x128+36)==0)
assert(approx(get_f32(cfg+0x120),1.2))
stable_writes=writes;assert(patch.apply(api,game));assert(writes==stable_writes)
assert(patch.configure{dynamic_spawn=false});assert(patch.apply(api,game))
assert(approx(get_f32(cfg+0x104),0.8) and approx(get_f32(cfg+0x120),6))
pass('all 65 progression values equal 1; extraction bonuses halve once; OFF restores zeros and updated baselines')
-- Verify both bounds, interpolation-range values, original-distance retention,
-- restoration and idempotence for the tightened patrol extraction curve.
assert(patch.configure{dynamic_spawn=true})
put_f32(cfg+0x11c,0.8);put_f32(cfg+0x120,1.2)
assert(patch.apply(api,game))
assert(approx(get_f32(cfg+0x11c),1) and approx(get_f32(cfg+0x120),1.1))
assert(approx(get_f32(cfg+0x124),200))
stable_writes=writes;assert(patch.apply(api,game));assert(writes==stable_writes)
assert(patch.configure{dynamic_spawn=false});assert(patch.apply(api,game))
assert(approx(get_f32(cfg+0x11c),0.8) and approx(get_f32(cfg+0x120),1.2))
put_f32(cfg+0x11c,1);put_f32(cfg+0x120,6)
pass('patrol extraction-distance endpoints stay within 1-1.2 without stacking and restore original bounds when OFF')
-- The same policy must work through the complete private resource clone and
-- mutate only the active row, with independent baselines for that new address.
local resource_key=string.char(239,205,171,137,103,69,35,241)
ffi.copy(handle,resource_key,8);put_u32(handle+8,0xffffffff)
ffi.copy(resource_root+15*16,resource_key,8);put_u32(resource_root+15*16+8,1)
ffi.copy(resource_root+0x260+patch.cfg_stride,cfg,patch.cfg_stride)
for _,off in ipairs(blocks) do
    local scale=off==0x1a0 and 2 or off==0x3f8 and 1.5 or off==0x1dc and 6 or 1
    for i=0,14 do
        local dest=resource_root+0x260+patch.cfg_stride+off+i*4
        put_f32(dest,get_f32(dest)/scale)
    end
end
put_f32(resource_root+0x260+0x128,1.8) -- inactive row must not be changed
assert(patch.configure{dynamic_spawn=true});assert(patch.apply(api,game))
assert(patch.detail:find('cfg=resource:1',1,true))
local resource_cfg=resource_root_live+0x260+patch.cfg_stride
for _,off in ipairs(all_blocks) do
    for i=0,4 do assert(approx(get_f32(resource_cfg+off+i*4),1)) end
end
assert(approx(get_f32(resource_cfg+0x120),1.2))
assert(approx(get_f32(resource_root_live+0x260+0x128),1.8))
stable_writes=writes;assert(patch.apply(api,game));assert(writes==stable_writes)
assert(patch.configure{dynamic_spawn=false});assert(patch.apply(api,game))
assert(approx(get_f32(resource_cfg+0x120),6) and get_f32(resource_cfg+0x128+12)==0)
put_u32(handle+8,123)
pass('neutral progression and halved extraction work in the private resource clone without editing inactive rows')
-- Invalid added spans fail closed before either extraction source is changed.
assert(patch.configure{dynamic_spawn=true})
put_f32(cfg+0x218,0/0)
local invalid_ok,invalid_reason=patch.apply(api,game)
assert(not invalid_ok and invalid_reason=='spawn_compensation_layout_mismatch',invalid_reason)
assert(approx(get_f32(cfg+0x120),6))
put_f32(cfg+0x218,1)
put_f32(cfg+0x104,-1)
invalid_ok,invalid_reason=patch.apply(api,game)
assert(not invalid_ok and invalid_reason=='spawn_extraction_layout_mismatch',invalid_reason)
assert(approx(get_f32(cfg+0x120),6))
pass('malformed full modifier span and extraction records fail before new compensation writes')
patch.dynamic_curve_policy=nil
if arg[6]=='local_test' or arg[6]=='combined' then
    -- Use the real local sampler/session and existing memory writer together.
    director_present=false;assert(patch.apply(api,game));patch.dynamic=nil
    mission(faction_caps(45,2000),100,600);fill_config(20,40,8,14,10,30,-1)
    put_u32(director+0x680,1)
    local pop_storage=ffi.new('uint8_t[0x20]')
    local pop=ffi.cast('uint8_t *',pop_storage)
    local read,query=api.read,api.query_region
    api.read=function(address,size)
        if real.distance(address,game+0x3326d18)==0 then return pointer(pop) end
        return read(address,size)
    end
    api.query_region=function(address)
        local off=real.distance(address,game)
        if off>=0 and off<0x4000000 then return game,0x4000000,0x1000,4 end
        return query(address)
    end
    local local_factory=assert(loadfile(source..'/experiments/local_pressure.lua'))()
    local combined=arg[6]=='combined'
    patch.dynamic_combined_switch=combined
    patch.dynamic_curve_policy=combined and 'unit_all_half_extraction' or nil
    assert(patch.configure{dynamic_spawn=false,patrol_count=4,patrol_size=1.8,
        encounter_cd_seconds=30,patrol_cd_seconds=2,
        guard_mission=true,guard_patrol_gate=true,guard_soft_pop=true})
    put_u32(director+0x36c0,10);put_u32(pop+0x1c,86)
    -- Keep S70 low while H is tested: S70=Q+B-P-E.
    put_u32(director+0x61c,40);put_u32(director+0x620,40)
    put_f32(director+patch.cfg_base_offset+0x1a0+16,1.5)
    patch.dynamic=local_factory().create(api,patch,true);patch.dynamic_dt=1
    assert(patch.apply(api,game))
    assert(patch.dynamic.progress_enabled==not combined and patch.dynamic.sample.h==96)
    assert(approx(get_f32(director+patch.cfg_base_offset+0x1a0+16),combined and 6 or 4))
    assert(patch.configure{dynamic_spawn=true})
    if combined then
        for _=1,5 do assert(patch.apply(api,game));assert(patch.dynamic.effective.remaining==0) end
        -- H=Q+B>200; keep S70=H-P-E <64 so soft-pop is measured alone (P=E=80 → S70=41).
        put_u32(director+0x61c,80);put_u32(director+0x620,80)
        put_u32(pop+0x1c,191)
        for _=1,2 do assert(patch.apply(api,game));assert(patch.dynamic.effective.remaining==0) end
        put_u32(pop+0x1c,190) -- H=200 must not trigger (strict >)
        assert(patch.apply(api,game));assert(patch.dynamic.effective.remaining==0)
        put_u32(pop+0x1c,191)
        for _=1,3 do assert(patch.apply(api,game)) end
        assert(patch.dynamic.effective.phase=='soft_pop_hold')
        -- 80% excess retain: 1+(4-1)*0.80=3.4, 1+(1.8-1)*0.80=1.64, rate 6*0.92=5.52
        assert(approx(patch.dynamic.effective.count,3.4) and approx(patch.dynamic.effective.size,1.64)
            and approx(patch.dynamic.effective.rate,5.52))
        assert(patch.configure{dynamic_spawn=false});assert(patch.apply(api,game))
        assert(not patch.dynamic.progress_enabled and patch.dynamic.effective.phase=='spacing_only')
        assert(patch.configure{dynamic_spawn=true,guard_soft_pop=false,guard_patrol_gate=true})
        put_u32(pop+0x1c,30);put_u32(director+0x61c,0);put_u32(director+0x620,0) -- S70=H=40 open
        for _=1,3 do assert(patch.apply(api,game)) end
        put_u32(pop+0x1c,80) -- S70=90 emergency band (>=78)
        for _=1,2 do assert(patch.apply(api,game)) end
        assert(patch.dynamic.effective.phase=='patrol_gate_hard'
            and approx(patch.dynamic.effective.count,1) and approx(patch.dynamic.effective.size,1))
        put_u32(pop+0x1c,30) -- release at <=68
        for _=1,2 do assert(patch.apply(api,game)) end
        assert(patch.dynamic.effective.phase=='spawn_guard_watch' or patch.dynamic.effective.phase=='spacing_only'
            or patch.dynamic.effective.phase=='patrol_gate_open'
            or patch.dynamic.effective.count>=1)
    else
        for _=1,3 do assert(patch.apply(api,game)) end
        assert(patch.dynamic.effective.phase=='local_h100_hold')
        for i=0,14 do
            assert(approx(get_f32(director+patch.cfg_base_offset+0x1a0+i*4),1))
            assert(approx(get_f32(director+patch.cfg_base_offset+0x3f8+i*4),1))
            assert(approx(get_f32(director+patch.cfg_base_offset+0x1dc+i*4),3))
        end
        for _=1,10 do assert(patch.apply(api,game)) end
        assert(approx(get_f32(director+patch.cfg_base_offset+0x1a0),4))
        assert(approx(get_f32(director+patch.cfg_base_offset+0x3f8),1.8))
        assert(approx(get_f32(director+patch.cfg_base_offset+0x1dc),6))
    end
    assert(patch.configure{dynamic_spawn=false});assert(patch.apply(api,game))
    assert(patch.dynamic.progress_enabled==not combined)
    api.read,api.query_region=read,query
    pass(combined and 'spawn_guard: H>200 soft-pop keep80% and S70 emergency gate throttle through real writer'
        or 'real local session writes 1x quantities/half rate then restores after 10s; progression stays active with switch OFF')
end
print(count .. ' fast cadence profile checks passed; no executable code was modified.')
