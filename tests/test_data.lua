-- Local synthetic allocations and loader environments only; no game access.
local source, build, executable_hash = assert(arg[1]), assert(arg[2]), assert(arg[3])
local ffi = require('ffi')
local create_api = assert(loadfile(source .. '/windows_api.lua'))()
local patch = assert(loadfile(source .. '/spawn_patch.lua'))()
local real = create_api()
local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end
assert(real.module_hash(real.module(nil)) == executable_hash)
assert(real.read(ffi.cast('void *', 1), 8) == nil)
assert(not real.writable_data(real.module(nil), 1))
assert(not real.write(real.module(nil), '\0'))
pass('copied restricted writer hashes modules and refuses module pages')

local DIRECTOR_SIZE = 0x54000
local director_storage = ffi.new('uint8_t[?]', DIRECTOR_SIZE)
local director = ffi.cast('uint8_t *', director_storage)
local header_storage = ffi.new('uint8_t[16]')
local header = ffi.cast('uint8_t *', header_storage)
local image_storage = ffi.new('uint8_t[16]')
local image = ffi.cast('uint8_t *', image_storage)
local image_entries_storage = ffi.new('uint8_t[?]', 8 * patch.entry_stride)
local image_entries = ffi.cast('uint8_t *', image_entries_storage)
local entries_storage = ffi.new('uint8_t[?]', 8 * patch.entry_stride)
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
local bias_templates_storage = ffi.new('uint8_t[?]', 5 * 0x100)
local bias_templates = ffi.cast('uint8_t *', bias_templates_storage)
local resource_root_live = resource_root
local image_mode, director_present, mode_present, time_present, writes = false, false, false, false, 0

local function pointer(value) return ffi.string(ffi.new('void *[1]', value), 8) end
local function put_ptr(dest, value) ffi.copy(dest, ffi.new('void *[1]', value), 8) end
local function put_u32(dest, value) ffi.copy(dest, ffi.new('uint32_t[1]', value), 4) end
local function put_f32(dest, value) ffi.copy(dest, ffi.new('float[1]', value), 4) end
local function put_u64(dest, value) ffi.copy(dest, ffi.new('uint64_t[1]', value), 8) end
local function get_u64(dest)
    local value = ffi.new('uint64_t[1]')
    ffi.copy(value, dest, 8)
    return tonumber(value[0])
end
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
        if not director_present then return '\0\0\0\0\0\0\0\0' end
        return pointer(director)
    end
    if real.distance(address, game + patch.mode_rva) == 0 then
        assert(size == 8)
        if not mode_present then return '\0\0\0\0\0\0\0\0' end
        return pointer(mode)
    end
    if real.distance(address, game + patch.time_rva) == 0 then
        assert(size == 8)
        if not time_present then return '\0\0\0\0\0\0\0\0' end
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
    if image_mode then
        local delta = real.distance(address, image)
        if delta >= 0 and delta < 16 then return false end
        delta = real.distance(address, image_entries)
        if delta >= 0 and delta < 8 * patch.entry_stride then return false end
    end
    return real.writable_data(address, size)
end

local function fill_row(base, index, ident, maximum)
    local row = base + index * patch.entry_stride
    ffi.fill(row, patch.entry_stride, 0)
    put_u32(row, ident)
    put_u32(row + patch.max_offset, maximum)
end
local function fill_entry(index, ident, maximum)
    fill_row(entries, index, ident, maximum)
end

local function snapshot()
    return ffi.string(director_storage, DIRECTOR_SIZE) .. ffi.string(header_storage, 16) ..
        ffi.string(entries_storage, 8 * patch.entry_stride)
end

local function mission(caps, points, guardforce)
    director_present, image_mode, mode_present, time_present = true, false, true, true
    ffi.fill(director_storage, DIRECTOR_SIZE, 0)
    ffi.fill(header_storage, 16, 0)
    ffi.fill(entries_storage, 8 * patch.entry_stride, 0)
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
    for index, cap in ipairs(caps) do
        fill_entry(index - 1, cap[1], cap[2])
    end
    put_f32(director + patch.points_offset, points)
    put_f32(director + patch.points_offset + 4, guardforce)
end

local function ship()
    director_present, image_mode, mode_present, time_present = true, true, true, true
    ffi.fill(director_storage, DIRECTOR_SIZE, 0)
    ffi.fill(image_storage, 16, 0)
    ffi.fill(mode_storage, 0x44, 0)
    ffi.fill(time_storage, 32, 0)
    put_ptr(director + patch.cap_table_offset, image)
    put_f32(director + patch.points_offset, 0)
    put_f32(director + patch.points_offset + 4, 0)
    put_u64(time + 0x18, 1000000)
end

local vanilla = {{101, 8}, {202, 7}, {303, 10}}
local function assert_caps(expected)
    for index, value in ipairs(expected) do
        assert(get_u32(entries + (index - 1) * patch.entry_stride + patch.max_offset) == value)
    end
end

writes = 0
local ok, reason, active = patch.apply(api, game)
assert(ok and reason == 'waiting_for_mission' and not active and writes == 0)
ship()
ok, reason, active = patch.apply(api, game)
assert(ok and reason == 'waiting_for_mission' and not active and writes == 0)
pass('native executable code remains untouched; ship state waits without data writes')

mission(vanilla, 100, 50)
ok, reason, active = patch.apply(api, game)
assert(ok and active and reason == 'spawn_multiplier_partial')
assert_caps({80, 70, 100})
assert(get_f32(director + patch.points_offset) == 600)
assert(get_f32(director + patch.points_offset + 4) == 50)
assert(get_u32(director + patch.pop_offset) == 0)
local applied_writes = writes
ok, reason, active = patch.apply(api, game)
assert(ok and active and reason == 'spawn_multiplier_partial' and writes == applied_writes)
assert_caps({80, 70, 100})
assert(get_f32(director + patch.points_offset) == 600)
assert(get_f32(director + patch.points_offset + 4) == 50)
assert(get_u32(director + patch.pop_offset) == 0)
pass('even and odd caps and encounter points scale once; guardforce and native counters stay vanilla')

director_present = false
assert(patch.apply(api, game))
mission({{101, 0}, {202, 0}, {303, 0}}, 600, 600)
local zero_rows = ffi.string(entries_storage, 8 * patch.entry_stride)
writes = 0
ok, reason, active = patch.apply(api, game)
assert(ok and active and reason == 'spawn_multiplier_partial')
assert(ffi.string(entries_storage, 8 * patch.entry_stride) == zero_rows)
assert(get_f32(director + patch.points_offset) == 3600)
assert(get_f32(director + patch.points_offset + 4) == 600)
assert(get_u32(director + patch.pop_offset) == 0)
local zero_writes = writes
ok, reason, active = patch.apply(api, game)
assert(ok and active and writes == zero_writes)
assert(get_f32(director + patch.points_offset) == 3600)
pass('zero per-type maxes still scale encounter points without touching native counters')

mission(vanilla, 100, 50)
put_u64(director + patch.timer_offsets[1], 6000000)
put_u64(director + patch.timer_offsets[2], 11000000)
put_u32(director + patch.pop_offset, 17)
ok, reason, active = patch.apply(api, game)
assert(ok and active)
assert(get_u64(director + patch.timer_offsets[1]) == 6000000)
assert(get_u64(director + patch.timer_offsets[2]) == 11000000)
assert(get_u32(director + patch.pop_offset) == 17)
local timer_writes = writes
ok, reason, active = patch.apply(api, game)
assert(ok and active and writes == timer_writes)
assert(get_u64(director + patch.timer_offsets[1]) == 6000000)
pass('native patrol timestamps remain untouched; resolved config intervals control future rolls')

local function approx(a, b)
    return math.abs(a - b) <= 0.002
end
local function fill_config(min8, max8, min1, max1, group, desired)
    put_u32(director + patch.cfg_count_offset, 1)
    local cfg = director + patch.cfg_base_offset
    put_f32(cfg + 0x38, min8)
    put_f32(cfg + 0x3c, max8)
    put_f32(cfg + 0x40, min1)
    put_f32(cfg + 0x44, max1)
    put_u32(cfg + 0x48, group)
    put_u32(cfg + 0x50, desired or 30)
    put_f32(cfg + 0x80, 2)
end
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
local function fill_candidate(index, weight, cost, units)
    local candidate = director + patch.candidate_pool_offset + index * patch.candidate_stride
    local template = bias_templates + index * 0x100
    ffi.fill(template, 0x100, 0)
    put_u32(template, index + 1)
    put_u32(template + 4, units)
    put_u32(template + 0x60, 1)
    put_ptr(candidate + patch.candidate_template_offset, template)
    put_f32(candidate + patch.candidate_weight_offset, weight)
    put_f32(candidate + patch.candidate_cost_offset, cost)
end
local function candidate_weight(index)
    return get_f32(director + patch.candidate_pool_offset
        + index * patch.candidate_stride + patch.candidate_weight_offset)
end

director_present = false
assert(patch.apply(api, game))
mission(vanilla, 100, 50)
fill_config(20, 40, 8, 14, 10, 30)
put_u64(director + patch.timer_offsets[1], 41000000)
put_u64(director + patch.timer_offsets[2], 15000000)
ok, reason, active = patch.apply(api, game)
assert(ok and active and reason == 'spawn_multiplier_ready')
assert_config(2, 4, 0.8, 1.4, 100, 30)
assert(get_u64(director + patch.timer_offsets[1]) == 5000000)
assert(get_u64(director + patch.timer_offsets[2]) == 2400000)
assert(patch.detail:find('t=2', 1, true))
local cfg_writes = writes
ok, reason, active = patch.apply(api, game)
assert(ok and active and writes == cfg_writes)
assert_config(2, 4, 0.8, 1.4, 100, 30)
assert(get_f32(director + patch.points_offset) == 600)
assert(patch.detail:find('d=30', 1, true) and patch.detail:find('l=vanilla', 1, true))
put_u64(director + patch.timer_offsets[1], 500000)
put_u64(director + patch.timer_offsets[2], 2000000)
ok, reason, active = patch.apply(api, game)
assert(ok and active and writes == cfg_writes)
assert(get_u64(director + patch.timer_offsets[1]) == 500000)
assert(get_u64(director + patch.timer_offsets[2]) == 2000000)
assert(patch.detail:find('t=0', 1, true))
pass('budget grows 6x; caps and group grow 10x; intervals and pending deadlines shrink safely')

director_present = false
assert(patch.apply(api, game))
mission(vanilla, 100, 50)
fill_config(2, 4, 0.8, 1.4, 100, 30)
ok, reason, active = patch.apply(api, game)
assert(ok and active)
assert_config(2, 4, 0.8, 1.4, 100, 30)
pass('already-scaled spawn config is not multiplied again')

director_present = false
assert(patch.apply(api, game))
mission(vanilla, 100, 50)
fill_config(20, 40, 8, 14, 10, 30)
patch.template_bias_enabled = true
put_u32(director + patch.candidate_count_offset, 5)
fill_candidate(0, 1, 10, 10)
fill_candidate(1, 1, 20, 10)
fill_candidate(2, 1, 30, 10)
fill_candidate(3, 1, 80, 10)
fill_candidate(4, 1, 200, 10)
ok, reason, active = patch.apply(api, game)
assert(ok and active and reason == 'spawn_multiplier_ready')
assert(approx(candidate_weight(0), 3.6) and approx(candidate_weight(1), 3.6))
assert(approx(candidate_weight(2), 3.6) and approx(candidate_weight(3), 1.25))
assert(approx(candidate_weight(4), 0.25))
assert(patch.detail:find('w=5/5', 1, true))
local bias_writes = writes
assert(patch.apply(api, game) and writes == bias_writes)
patch.template_bias_enabled = false
pass('template cost per unit biases light and medium candidates without stacking')

director_present = false
assert(patch.apply(api, game))
mission(vanilla, 100, 50)
fill_config(20, 40, 8, 14, 10, 30)
local decoy = ffi.string(director + patch.cfg_base_offset, patch.cfg_stride)
local selected = director + patch.cfg_base_offset + 2 * patch.cfg_stride
ffi.copy(selected, decoy, #decoy)
put_u32(handle + 8, 0xFFFFFFFD)
put_u32(director + patch.cfg_count_offset, 8)
put_u32(director + patch.cfg_hash_multiplier_offset, 0xFFFFFFFF)
-- Exact low-bit product is 3, despite exceeding Lua's integer precision.
put_u32(hash_table + 3 * 8, 999)
put_u32(hash_table + 4 * 8, 0xFFFFFFFD)
put_u32(hash_table + 4 * 8 + 4, 2)
ok, reason, active = patch.apply(api, game)
assert(ok and active and reason == 'spawn_multiplier_ready')
assert(ffi.string(director + patch.cfg_base_offset, patch.cfg_stride) == decoy)
assert(get_u32(selected + 0x48) == 100 and approx(get_f32(selected + 0x38), 2))
assert(patch.detail:find('cfg=director:2', 1, true))
local hash_writes = writes
assert(patch.apply(api, game) and writes == hash_writes)
pass('native hash lookup preserves 32-bit low bits, probes collisions and ignores inactive slots')

director_present = false
assert(patch.apply(api, game))
mission(vanilla, 100, 50)
fill_config(20, 40, 8, 14, 10, 30)
decoy = ffi.string(director + patch.cfg_base_offset, patch.cfg_stride)
local resource_key = string.char(239, 205, 171, 137, 103, 69, 35, 241)
ffi.copy(handle, resource_key, 8)
put_u32(handle + 8, 0xFFFFFFFF)
-- 0xF123456789ABCDEF modulo 38 = 15 (computed independently).
ffi.copy(resource_root + 15 * 16, resource_key, 8)
put_u32(resource_root + 15 * 16 + 8, 1)
selected = resource_root + 0x260 + patch.cfg_stride
ffi.copy(selected, decoy, #decoy)
ok, reason, active = patch.apply(api, game)
assert(ok and active and reason == 'spawn_multiplier_ready')
selected = resource_root_live + 0x260 + patch.cfg_stride
assert(get_u32(selected + 0x48) == 100 and approx(get_f32(selected + 0x40), 0.8))
assert(ffi.string(director + patch.cfg_base_offset, patch.cfg_stride) == decoy)
assert(patch.detail:find('cfg=resource:1', 1, true))
local resource_writes = writes
assert(patch.apply(api, game) and writes == resource_writes)
-- A valid generation with no director hash match must use the same fallback.
put_u32(handle + 8, 321)
assert(patch.apply(api, game) and writes == resource_writes)
pass('resource-key fallback resolves full 64-bit keys for invalid generation and hash misses')

ffi.fill(resource_root_live, 0x260, 0)
ok, reason, active = patch.apply(api, game)
assert(ok and active and reason == 'spawn_multiplier_partial' and writes == resource_writes)
assert(patch.detail:find('cfg=spawn_config_resource_unresolved', 1, true))
assert(patch.detail:find('g=0', 1, true))
pass('unresolved active config reports partial activation and never scans decoy configs')

director_present = false
assert(patch.apply(api, game))
director_present, image_mode, mode_present, time_present = true, true, true, true
ffi.fill(director_storage, DIRECTOR_SIZE, 0)
ffi.fill(image_storage, 16, 0)
ffi.fill(image_entries_storage, 8 * patch.entry_stride, 0)
ffi.fill(mode_storage, 0x44, 0)
ffi.fill(time_storage, 32, 0)
put_u32(mode + 8, 1)
put_u64(time + 0x18, 1000000)
put_ptr(director + patch.cap_table_offset, image)
put_ptr(image, image_entries)
put_u32(image + 8, #vanilla)
for index, cap in ipairs(vanilla) do
    fill_row(image_entries, index - 1, cap[1], cap[2])
end
put_f32(director + patch.points_offset, 100)
put_f32(director + patch.points_offset + 4, 50)
local image_before = ffi.string(image_entries_storage, 8 * patch.entry_stride)
writes = 0
ok, reason, active = patch.apply(api, game)
assert(ok and active and reason == 'spawn_multiplier_partial')
assert(ffi.string(image_entries_storage, 8 * patch.entry_stride) == image_before)
local cloned_header = api.pointer(api.read(director + patch.cap_table_offset, 8))
assert(cloned_header and real.distance(cloned_header, image) ~= 0)
local cloned_entries = api.pointer(api.read(cloned_header, 8))
assert(cloned_entries and real.distance(cloned_entries, image_entries) ~= 0)
assert(get_u32(cloned_entries + patch.max_offset) == 80)
assert(get_u32(cloned_entries + patch.entry_stride + patch.max_offset) == 70)
assert(get_u32(cloned_entries + 2 * patch.entry_stride + patch.max_offset) == 100)
assert(get_f32(director + patch.points_offset) == 600)
assert(get_f32(director + patch.points_offset + 4) == 50)
local cloned_writes = writes
ok, reason, active = patch.apply(api, game)
assert(ok and active and writes == cloned_writes)
assert(get_u32(cloned_entries + patch.max_offset) == 80)
assert(get_f32(director + patch.points_offset) == 600)
pass('module-image cap tables are cloned into private memory and scaled once')

mission(vanilla, 100, 50)
ok, reason, active = patch.apply(api, game)
assert(ok and active and reason == 'spawn_multiplier_partial')
assert_caps({80, 70, 100})
assert(get_f32(director + patch.points_offset) == 600)
applied_writes = writes
ok, reason, active = patch.apply(api, game)
assert(ok and active and writes == applied_writes)

put_f32(director + patch.points_offset, 150)
ok, reason, active = patch.apply(api, game)
assert(ok and active and writes == applied_writes)
assert(get_f32(director + patch.points_offset) == 150)
assert(get_f32(director + patch.points_offset + 4) == 50)
put_f32(director + patch.points_offset, 80)
ok, reason, active = patch.apply(api, game)
assert(ok and active and get_f32(director + patch.points_offset) == 600)
put_f32(director + patch.points_offset, 800)
ok, reason, active = patch.apply(api, game)
assert(ok and active and get_f32(director + patch.points_offset) == 4800)
assert(get_f32(director + patch.points_offset + 4) == 50)
pass('consuming encounter points is left alone; a larger budget is scaled')

director_present = false
assert(patch.apply(api, game))
mission(vanilla, 100, 50)
ok, reason, active = patch.apply(api, game)
assert(ok and active)
assert_caps({80, 70, 100})
assert(get_f32(director + patch.points_offset) == 600)
-- Same mission identity with restored vanilla caps must reapply, not 4x.
fill_entry(0, 101, 8); fill_entry(1, 202, 7); fill_entry(2, 303, 10)
put_f32(director + patch.points_offset, 100)
ok, reason, active = patch.apply(api, game)
assert(ok and active)
assert_caps({80, 70, 100})
assert(get_f32(director + patch.points_offset) == 600)
pass('mission reset with the same enemy set reapplies configured multipliers instead of stacking')

mission({{101, 8}, {202, 7}, {303, 10}}, 100, 50)
local unchanged, old_writes = snapshot(), writes
for _, defect in ipairs({
    function() put_u32(entries, 0) end,
    function() put_u32(entries + patch.max_offset, 2048) end,
    function() put_f32(director + patch.points_offset, 0/0) end,
    function() put_f32(director + patch.points_offset + 4, -1) end,
}) do
    mission(vanilla, 100, 50)
    defect()
    unchanged, old_writes = snapshot(), writes
    assert(not patch.apply(api, game))
    assert(writes == old_writes and snapshot() == unchanged)
end
pass('layout mismatches fail closed and leave memory unchanged')

mission(vanilla, 100, 50)
for _, kind in ipairs({'unreadable', 'write_failure', 'identity_changed'}) do
    local altered = setmetatable({}, {__index = api})
    local reads = 0
    altered.read = function(address, size)
        if real.distance(address, game + patch.director_rva) == 0 then
            reads = reads + 1
            if kind == 'identity_changed' and reads == 2 then return pointer(director + 16) end
        end
        if kind == 'unreadable' and real.distance(address, header) == 0 then return nil end
        return api.read(address, size)
    end
    if kind == 'write_failure' then altered.write = function() return false end end
    mission(vanilla, 100, 50)
    unchanged, old_writes = snapshot(), writes
    local accepted, status = patch.apply(altered, game)
    if kind == 'identity_changed' then
        assert(accepted and status == 'waiting_for_stable_mission')
        assert(snapshot() == unchanged)
    else
        assert(not accepted)
        if kind ~= 'write_failure' then
            assert(writes == old_writes and snapshot() == unchanged)
        end
    end
end
pass('page, read, write and reset-race failures do not broaden the layout')

local identity = {revision = 'fixture', exe_sha256 = 'exe', game_sha256 = 'game'}
for _, mode in ipairs({'success', 'spawn_failure', 'exe', 'game', 'ffi'}) do
    local updates, checks, factories = 0, 0, 0
    local env = setmetatable({print = function() end, os = {getenv = function() end}}, {__index = _G})
    env._G = env
    local shutdown = function() end
    env.shutdown = shutdown
    env.update = function(dt, marker)
        assert(dt == 0.1 and marker == 123); updates = updates + 1
        return 'result', nil, marker
    end
    local function factory()
        factories = factories + 1
        if mode == 'ffi' then error('ffi unavailable') end
        return {
            module = function(name) return name and 'game' or 'exe' end,
            module_hash = function(module) return module == mode and 'mismatch' or module end,
        }
    end
    local probe = {apply = function()
        checks = checks + 1
        return mode ~= 'spawn_failure', checks == 1 and 'waiting_for_mission' or 'spawn_multiplier_ready', checks > 1
    end}
    local chunk = assert(loadfile(source .. '/archive_loader.lua')); setfenv(chunk, env)
    local loader = chunk(); setfenv(loader, env)
    loader(factory, probe, identity)
    loader(factory, probe, identity)
    for _ = 1, 5 do env.update(0.1, 123) end
    assert(updates == 5 and factories == 1 and env.shutdown == shutdown)
    assert(checks == ((mode == 'ffi' or mode == 'exe' or mode == 'game') and 0 or mode == 'spawn_failure' and 1 or 5))
    assert(env.EnemySpawnMultiplier.active == (mode == 'success'))
end
pass('loader handles failures, duplicate initialization and existing update callbacks')

local env = setmetatable({print = function() end, os = {getenv = function() end}}, {__index = _G})
env._G = env
env.update = function() return 1, nil, 3 end
local chunk = assert(loadfile(source .. '/archive_loader.lua')); setfenv(chunk, env)
local loader = chunk(); setfenv(loader, env)
loader(function() return {module = function(name) return name and 'game' or 'exe' end,
    module_hash = function(module) return module end} end,
    {apply = function() return true, 'waiting_for_mission', false end}, identity)
local results = {env.update(0.1)}
assert(results[1] == 1 and results[2] == nil and results[3] == 3 and select('#', env.update(0.1)) == 3)
pass('standalone update forwards return values unchanged')

local env = setmetatable({print = function() end, os = {getenv = function() end},
    update = function() end}, {__index = _G})
env._G = env
local previous = env.update
setfenv(assert(loadfile(build .. '/mod.ljbc')), env)()
assert(env.update == previous and env.EnemySpawnMultiplier.active == false)
pass('compiled module rejects the non-game test host')

local required_name, required_count
local entry_env = setmetatable({require = function(name)
    required_name, required_count = name, (required_count or 0) + 1
    return 'implementation-loaded'
end}, {__index = _G})
entry_env._G = entry_env
local entry_chunk = assert(loadfile(build .. '/entry.lua')); setfenv(entry_chunk, entry_env)
assert(entry_chunk() == 'implementation-loaded')
assert(required_name == 'mods/cowboybingus/enemy_spawn_multiplier_impl' and required_count == 1)
pass('v15 discovery entry preserves the legacy resource name and forwards once')

director_present = false
assert(patch.apply(api, game))
mission(vanilla, 100, 50)
fill_config(20, 40, 8, 14, 10, 30)
local queue_counter_offset, queue_base_offset = 0x36C0, 0x36D0
local queue_stride, queue_type_offset, queue_quantity_offset = 0x908, 0x8F4, 0x900
local queue_slot = director + queue_base_offset + 10 * queue_stride
put_u32(director + queue_counter_offset, 8)
put_u32(queue_slot + queue_type_offset, 3)
put_u32(queue_slot + queue_quantity_offset, 6)
local queue_before = ffi.string(director + queue_counter_offset, 0x20)
    .. ffi.string(queue_slot + queue_type_offset, 0x10)
ok, reason, active = patch.apply(api, game)
assert(ok and active and reason == 'spawn_multiplier_ready')
local queue_after = ffi.string(director + queue_counter_offset, 0x20)
    .. ffi.string(queue_slot + queue_type_offset, 0x10)
assert(queue_after == queue_before)
assert(get_u32(director + queue_counter_offset) == 8)
assert(get_u32(queue_slot + queue_quantity_offset) == 6)
assert(not patch.detail:find('q=', 1, true) and not patch.detail:find('qf=', 1, true))
pass('pending queue quantity and accounting remain read-only')

director_present = false
assert(patch.apply(api, game))
mission(vanilla, 100, 50)
fill_config(20, 40, 8, 14, 10, 60)
ok, reason, active = patch.apply(api, game)
assert(ok and active and reason == 'spawn_multiplier_ready')
assert_config(2, 4, 0.8, 1.4, 100, 60)
assert(patch.detail:find('d=60', 1, true))
pass('desired target remains native to avoid amplifying the combined-100 rejection gate')

print(count .. ' data-only spawn multiplier checks passed; no executable code was modified.')
