-- Raises the HiveMind encounter budget to 6x, expands data-driven caps/group
-- clamps to 10x and shortens patrol/straggler intervals to one tenth. Live spawn
-- frequency and per-wave group clamp come from the native
-- handle/hash resolver for the 0x438 config at director+0x519A4, not from
-- encounter points. Encounter points are a per-reinforcement composition
-- budget; they are not a remaining pool and do not control how often waves
-- fire. Illuminate GuardForce budget is reduced before static POI population
-- fills the shared native gate. Zero per-type cap rows are a native skip.
-- Population counters remain read-only. Existing Patrol and Straggler deadlines
-- are only shortened when they exceed the scaled maximum.
local ffi
local patch = {
    budget_multiplier = 6,
    budget_override_multiplier = 6,
    template_bias_enabled = false,
    template_bias_light = 3.6,
    template_bias_medium = 1.25,
    template_bias_heavy = 0.25,
    illuminate_guardforce_multiplier = 0.25,
    -- Raw cap-table counts observed on the supported 1.8.45317.0 build.
    faction_cap_counts = {automaton = 61, terminid = 44, illuminate = 45},
    cap_multiplier = 10,
    interval_divisor = 10,
    group_multiplier = 10,
    director_rva = 0x276CA20,
    mode_rva = 0x276c3d0,
    time_rva = 0x276C068,
    cap_table_offset = 0x660,
    cap_header_size = 0xB0,
    points_offset = 0x518B0,
    candidate_pool_offset = 0x432F8,
    candidate_count_offset = 0x5188C,
    candidate_stride = 0xD8,
    candidate_template_offset = 0xA8, -- source definition pointer; rows are inline at +0
    candidate_weight_offset = 0xC0,
    candidate_cost_offset = 0xD4,
    candidate_max = 256,
    pop_offset = 0x620, -- native ProducedFighter count; read-only diagnostic
    timer_offsets = {0x3A518, 0x3A520},
    timer_units_per_second = 1000000,
    entry_stride = 0x80,
    max_offset = 0x18,
    min_count = 1,
    max_count = 128,
    min_max = 1,
    max_max = 512,
    cfg_handle_offset = 0x6B0,
    cfg_table_offset = 0x51960,
    cfg_count_offset = 0x51968,
    cfg_hash_multiplier_offset = 0x51970,
    cfg_sentinel_offset = 0x5196c,
    cfg_invalid_generation_rva = 0x2786C64,
    resource_manager_rva = 0x276F0C0,
    resource_table_offset = 0xF116D8,
    resource_slots = 38,
    cfg_base_offset = 0x519A4,
    cfg_override_offset = 0x78,
    cfg_stride = 0x438,
    cfg_max = 8,
    min_interval = 0.1,
    max_interval = 600,
    min_group = 1,
    max_group = 64,
    vanilla_patrol_max_floor = 12,
}
local originals = {}
local clones = {block = nil, size = 0}
local resource_clone = {source = nil, block = nil, size = 0}
local override_state = {}
local mission = {
    director = nil, key = nil, points_original = nil, points_applied = nil,
    guardforce_original = nil, guardforce_applied = nil,
    cfg = nil, weights = nil,
}
patch.detail = ''

local function u32(bytes, offset)
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function pack_u32(value)
    ffi = ffi or require('ffi')
    local buffer = ffi.new('uint32_t[1]', value)
    return ffi.string(buffer, 4)
end
local function u64(bytes, offset)
    if not bytes or offset < 0 or offset + 8 > #bytes then return nil end
    ffi = ffi or require('ffi')
    local value = ffi.new('uint64_t[1]')
    ffi.copy(value, bytes:sub(offset + 1, offset + 8), 8)
    return tonumber(value[0])
end
local function pack_u64(value)
    ffi = ffi or require('ffi')
    local buffer = ffi.new('uint64_t[1]', value)
    return ffi.string(buffer, 8)
end
local function pack_ptr(address)
    ffi = ffi or require('ffi')
    local buffer = ffi.new('uintptr_t[1]', ffi.cast('uintptr_t', address))
    return ffi.string(buffer, 8)
end
local function number(bytes, offset)
    ffi = ffi or require('ffi')
    local value = ffi.new('float[1]')
    ffi.copy(value, bytes:sub(offset + 1, offset + 4), 4)
    return tonumber(value[0])
end
local function pack_f32(value)
    ffi = ffi or require('ffi')
    local buffer = ffi.new('float[1]', value)
    return ffi.string(buffer, 4)
end
local function near(a, b)
    if a ~= a or b ~= b then return false end
    return math.abs(a - b) <= math.max(0.0005, math.abs(b) * 0.002)
end
local function finite(value)
    return value == value and math.abs(value) ~= math.huge
end
local function reset()
    originals = {}
    mission.director, mission.key = nil, nil
    mission.points_original, mission.points_applied = nil, nil
    mission.guardforce_original, mission.guardforce_applied = nil, nil
    mission.cfg, mission.weights = nil, nil
end
local function same_pointer(api, first, second)
    return first and second and api.distance(first, second) == 0
end
local function in_mission(api, game)
    local mode = api.pointer(api.read(game + patch.mode_rva, 8))
    if not mode then return false end
    local mode_bytes = api.read(mode, 12)
    return mode_bytes ~= nil and u32(mode_bytes, 8) ~= 0
end
local function faction_name(count)
    for name, expected in pairs(patch.faction_cap_counts) do
        if count == expected then return name end
    end
    return 'unknown'
end
local function describe(points, original, valid, count, timers, pop, cfg,
                        guardforce, guardforce_original, faction)
    local i38, i3c, i40, i44, group, desired = 0, 0, 0, 0, 0, 0
    if cfg then
        i38, i3c, i40, i44, group, desired =
            cfg.i38, cfg.i3c, cfg.i40, cfg.i44, cfg.group, cfg.desired
    end
    patch.detail = string.format('p=%.1f/%s gf=%.1f/%s f=%s c=%d/%d t=%d x=%d i=%.2f-%.2f/%.2f-%.2f g=%d d=%d l=vanilla',
        points or 0,
        original and string.format('%.1f', original) or '-',
        guardforce or 0,
        guardforce_original and string.format('%.1f', guardforce_original) or '-',
        faction or 'unknown',
        valid or 0, count or 0, timers or 0, pop or 0,
        i38, i3c, i40, i44, group, desired)
end
local function retarget_table(api, director, table_bytes, rows, table_size)
    ffi = ffi or require('ffi')
    local size = patch.cap_header_size + table_size
    if not clones.block or clones.size < size then
        clones.block = api.alloc_private(size)
        clones.size = clones.block and size or 0
        if not clones.block then return nil, 'spawn_clone_alloc_failed' end
    end
    local block = clones.block
    local copy = block + patch.cap_header_size
    ffi.copy(copy, rows, table_size)
    ffi.copy(block, table_bytes, patch.cap_header_size)
    ffi.copy(block, pack_ptr(copy), 8)
    if not api.writable_data(block, size) then
        return nil, 'spawn_clone_not_writable_private_data'
    end
    if not api.write(director + patch.cap_table_offset, pack_ptr(block))
        or not same_pointer(api, api.pointer(api.read(director + patch.cap_table_offset, 8)), block) then
        return nil, 'spawn_cap_retarget_failed'
    end
    return copy
end
local function ensure_resource_clone(api, game, manager, root)
    local size = 0x260 + patch.resource_slots * patch.cfg_stride
    if resource_clone.block and resource_clone.size >= size then
        if same_pointer(api, resource_clone.block, root) then return resource_clone.block end
        if same_pointer(api, resource_clone.source, root) then
            if not api.writable_data(manager + patch.resource_table_offset, 8) then
                return nil, 'spawn_config_resource_table_not_writable_private_data'
            end
            if api.write(manager + patch.resource_table_offset, pack_ptr(resource_clone.block))
                and same_pointer(api, api.pointer(api.read(manager + patch.resource_table_offset, 8)), resource_clone.block) then
                return resource_clone.block
            end
            return nil, 'spawn_config_resource_retarget_failed'
        end
    end
    if not api.writable_data(manager + patch.resource_table_offset, 8) then
        return nil, 'spawn_config_resource_table_not_writable_private_data'
    end
    ffi = ffi or require('ffi')
    local block = api.alloc_private(size)
    if not block then return nil, 'spawn_config_resource_clone_alloc_failed' end
    local ok = pcall(ffi.copy, block, root, size)
    if not ok then return nil, 'spawn_config_resource_clone_read_failed' end
    if not api.write(manager + patch.resource_table_offset, pack_ptr(block))
        or not same_pointer(api, api.pointer(api.read(manager + patch.resource_table_offset, 8)), block) then
        return nil, 'spawn_config_resource_retarget_failed'
    end
    resource_clone.source, resource_clone.block, resource_clone.size = root, block, size
    return block
end
local function scale_points(api, director, points)
    if not (points > 0) then return true end
    if not mission.points_original then
        if mission.points_applied and near(points, mission.points_applied) then
            mission.points_original = points / patch.budget_multiplier
        else
            mission.points_original = points
        end
    end
    local target = mission.points_original * patch.budget_multiplier
    if points <= mission.points_original * 1.05 then
        if not api.write(director + patch.points_offset, pack_f32(target))
            or not near(number(api.read(director + patch.points_offset, 4), 0), target) then
            return false, 'spawn_points_write_failed'
        end
        mission.points_applied = target
    elseif near(points, target) then
        mission.points_applied = target
    elseif points > target * 1.05 then
        mission.points_original = points
        target = points * patch.budget_multiplier
        if not api.write(director + patch.points_offset, pack_f32(target))
            or not near(number(api.read(director + patch.points_offset, 4), 0), target) then
            return false, 'spawn_points_write_failed'
        end
        mission.points_applied = target
    else
        mission.points_applied = points
    end
    return true
end
local function scale_guardforce(api, director, guardforce, faction)
    if faction ~= 'illuminate' or not (guardforce > 0) then return true, guardforce end
    if not mission.guardforce_original then
        mission.guardforce_original = guardforce
    elseif not near(guardforce, mission.guardforce_original)
        and not near(guardforce, mission.guardforce_applied or -1) then
        mission.guardforce_original = guardforce
    end
    local target = mission.guardforce_original * patch.illuminate_guardforce_multiplier
    if not near(guardforce, target) then
        if not api.writable_data(director + patch.points_offset + 4, 4)
            or not api.write(director + patch.points_offset + 4, pack_f32(target))
            or not near(number(api.read(director + patch.points_offset + 4, 4) or '', 0), target) then
            return false, 'spawn_guardforce_write_failed'
        end
    end
    mission.guardforce_applied = target
    return true, target
end
local function read_pop(api, director)
    local raw = api.read(director + patch.pop_offset, 4)
    return raw and u32(raw, 0) or 0
end
local function scale_candidate_weights(api, director)
    if not patch.template_bias_enabled then return 0, 0 end
    local count_bytes = api.read(director + patch.candidate_count_offset, 4)
    if not count_bytes then return 0, 0, 'spawn_candidate_count_unreadable' end
    local count = u32(count_bytes, 0)
    if count == 0 then return 0, 0 end
    if count > patch.candidate_max then return 0, count, 'spawn_candidate_count_mismatch' end
    local base = director + patch.candidate_pool_offset
    local size = count * patch.candidate_stride
    if not api.writable_data(base, size) then
        return 0, count, 'spawn_candidate_pool_not_writable_private_data'
    end
    mission.weights = mission.weights or {}
    local candidates, densities = {}, {}
    for index = 0, count - 1 do
        local address = base + index * patch.candidate_stride
        local bytes = api.read(address, patch.candidate_stride)
        if not bytes then return 0, count, 'spawn_candidate_unreadable' end
        local source = api.pointer(bytes, patch.candidate_template_offset)
        local weight = number(bytes, patch.candidate_weight_offset)
        local cost = number(bytes, patch.candidate_cost_offset)
        if not source or not finite(weight) or not finite(cost)
            or weight < 0 or weight > 1000000 or cost <= 0 or cost > 1000000 then
            return 0, count, 'spawn_candidate_layout_mismatch'
        end
        local rows = u32(bytes, 0x60)
        if rows < 1 or rows > 8 then return 0, count, 'spawn_candidate_template_layout_mismatch' end
        local units = 0
        for row = 0, rows - 1 do
            local type_id = u32(bytes, row * 12)
            local quantity = u32(bytes, row * 12 + 4)
            if type_id == 0 then return 0, count, 'spawn_candidate_type_mismatch' end
            if quantity > 1024 then return 0, count, 'spawn_candidate_quantity_mismatch' end
            units = units + quantity
        end
        if units < 1 or units > 8192 then return 0, count, 'spawn_candidate_quantity_mismatch' end
        local key = tostring(index) .. ':' .. tostring(source) .. ':' .. string.format('%.3f', cost)
        local state = mission.weights[key]
        if not state then
            state = {baseline = weight, applied = nil}
            mission.weights[key] = state
        elseif state.applied and not near(weight, state.applied) and not near(weight, state.baseline) then
            state.baseline, state.applied = weight, nil
        end
        local density = cost / units
        candidates[#candidates + 1] = {address = address, state = state, density = density}
        densities[#densities + 1] = density
    end
    table.sort(densities)
    local light_cut = densities[math.max(1, math.ceil(#densities * 0.50))]
    local medium_cut = densities[math.max(1, math.ceil(#densities * 0.80))]
    for _, item in ipairs(candidates) do
        local factor = patch.template_bias_heavy
        if item.density <= light_cut then factor = patch.template_bias_light
        elseif item.density <= medium_cut then factor = patch.template_bias_medium end
        local target = item.state.baseline * factor
        local current_bytes = api.read(item.address + patch.candidate_weight_offset, 4)
        local current = current_bytes and number(current_bytes, 0)
        if not current or not finite(current) then return nil, 'spawn_candidate_weight_unreadable' end
        if not near(current, target) then
            if not api.write(item.address + patch.candidate_weight_offset, pack_f32(target))
                or not near(number(api.read(item.address + patch.candidate_weight_offset, 4) or '', 0), target) then
                return nil, 'spawn_candidate_weight_write_failed'
            end
        end
        item.state.applied = target
    end
    return #candidates, count
end
local function copy_cfg(cfg)
    return {
        i38 = cfg.i38, i3c = cfg.i3c, i40 = cfg.i40, i44 = cfg.i44,
        group = cfg.group, desired = cfg.desired, override = cfg.override,
    }
end
local function read_config(api, address)
    local bytes = api.read(address + 0x38, 0x1c)
    if not bytes or #bytes < 0x1c then return nil end
    local override_bytes = api.read(address + patch.cfg_override_offset, 4)
    if not override_bytes then return nil end
    local cfg = {
        i38 = number(bytes, 0),
        i3c = number(bytes, 4),
        i40 = number(bytes, 8),
        i44 = number(bytes, 12),
        group = u32(bytes, 0x10),
        desired = u32(bytes, 0x18),
        override = number(override_bytes, 0),
    }
    if not (finite(cfg.i38) and finite(cfg.i3c) and finite(cfg.i40) and finite(cfg.i44)
        and finite(cfg.override)) then
        return nil
    end
    if cfg.i38 <= 0 or cfg.i3c <= 0 or cfg.i40 <= 0 or cfg.i44 <= 0 then return nil end
    if cfg.i38 > cfg.i3c or cfg.i40 > cfg.i44 then return nil end
    local limit = patch.max_interval * patch.interval_divisor
    if cfg.i38 > limit or cfg.i3c > limit or cfg.i40 > limit or cfg.i44 > limit then return nil end
    if cfg.group < patch.min_group or cfg.group > patch.max_group * patch.group_multiplier then return nil end
    if cfg.desired > 10000 then return nil end
    return cfg
end
local function vanilla_config(cfg)
    return cfg.group <= patch.max_group and cfg.i3c >= patch.vanilla_patrol_max_floor
end
local function interval_target(original)
    local target = original / patch.interval_divisor
    if target < patch.min_interval then return patch.min_interval end
    return target
end
local function write_interval(api, address, offset, current, target)
    if near(current, target) then return true end
    return api.write(address + offset, pack_f32(target))
        and near(number(api.read(address + offset, 4) or '', 0), target)
end
local function clamp_timers(api, game, director, cfg)
    if not cfg then return 0 end
    local clock = api.pointer(api.read(game + patch.time_rva, 8))
    if not clock then return 0 end
    local now_bytes = api.read(clock + 0x18, 8)
    local now = now_bytes and u64(now_bytes, 0)
    if not now or now < 0 or now > 9000000000000000 then return 0 end
    local maximums = {cfg.i3c, cfg.i44}
    local changed = 0
    for index, offset in ipairs(patch.timer_offsets) do
        local bytes = api.read(director + offset, 8)
        local pending = bytes and u64(bytes, 0)
        local limit = now + math.floor(maximums[index] * patch.timer_units_per_second + 0.5)
        if pending and pending > limit and api.writable_data(director + offset, 8) then
            if not api.write(director + offset, pack_u64(limit))
                or u64(api.read(director + offset, 8), 0) ~= limit then
                return nil, 'spawn_timer_write_failed'
            end
            changed = changed + 1
        end
    end
    return changed
end
local function resolve_resource_config(api, game, key)
    if key == string.rep('\0', 8) then return nil, 'spawn_config_resource_key_missing' end
    local manager = api.pointer(api.read(game + patch.resource_manager_rva, 8))
    if not manager then return nil, 'spawn_config_resource_manager_missing' end
    local root = api.pointer(api.read(manager + patch.resource_table_offset, 8))
    if not root then return nil, 'spawn_config_resource_table_missing' end
    local cloned, clone_reason = ensure_resource_clone(api, game, manager, root)
    if not cloned then return nil, clone_reason end
    root = cloned
    -- Native 0x500E60 uses an unsigned 64-bit key modulo 38. Reducing
    -- byte-by-byte avoids losing low bits through Lua's double precision.
    local slot = 0
    for byte = 8, 1, -1 do slot = (slot * 256 + key:byte(byte)) % patch.resource_slots end
    for _ = 1, patch.resource_slots do
        local entry = api.read(root + slot * 16, 16)
        if not entry then return nil, 'spawn_config_resource_unreadable' end
        local entry_key = entry:sub(1, 8)
        if entry_key == key then
            local index = u32(entry, 8)
            if index >= patch.resource_slots then return nil, 'spawn_config_resource_index_mismatch' end
            return root + 0x260 + index * patch.cfg_stride, 'resource:' .. index
        end
        if entry_key == string.rep('\0', 8) then break end
        slot = (slot + 1) % patch.resource_slots
    end
    return nil, 'spawn_config_resource_unresolved'
end
local function resolve_config(api, game, director)
    local handle_bytes = api.read(director + patch.cfg_handle_offset, 8)
    local handle = handle_bytes and api.pointer(handle_bytes, 0)
    if not handle then return nil, 'spawn_config_handle_missing' end
    local handle_data = api.read(handle, 12)
    if not handle_data then return nil, 'spawn_config_handle_unreadable' end
    local generation = u32(handle_data, 8)
    local invalid = api.read(game + patch.cfg_invalid_generation_rva, 4)
    if not invalid then return nil, 'spawn_config_generation_unreadable' end
    if generation == u32(invalid, 0) then
        return resolve_resource_config(api, game, handle_data:sub(1, 8))
    end

    local count_bytes = api.read(director + patch.cfg_count_offset, 4)
    local count = count_bytes and u32(count_bytes, 0) or 0
    local multiplier_bytes = api.read(director + patch.cfg_hash_multiplier_offset, 4)
    if not multiplier_bytes then return nil, 'spawn_config_hash_unreadable' end
    local hash_multiplier = u32(multiplier_bytes, 0)
    local table_bytes = api.read(director + patch.cfg_table_offset, 8)
    local hash_table = table_bytes and api.pointer(table_bytes, 0)
    local sentinel_bytes = api.read(director + patch.cfg_sentinel_offset, 4)
    local sentinel = sentinel_bytes and u32(sentinel_bytes, 0)
    if count == 0 then return resolve_resource_config(api, game, handle_data:sub(1, 8)) end
    if not hash_table or sentinel == nil then return nil, 'spawn_config_hash_unreadable' end
    if count < 1 or count > 64 then return nil, 'spawn_config_hash_layout_mismatch' end
    local power = count
    while power > 1 and power % 2 == 0 do power = power / 2 end
    if power ~= 1 then return nil, 'spawn_config_hash_layout_mismatch' end

    -- The native lookup hashes the active handle generation, then linearly
    -- probes the compact (key, config-index) table until the sentinel.
    local slot = ((hash_multiplier % count) * (generation % count)) % count
    for _ = 0, count - 1 do
        local entry = api.read(hash_table + slot * 8, 8)
        if not entry then return nil, 'spawn_config_hash_unreadable' end
        local key, index = u32(entry, 0), u32(entry, 4)
        if key == generation then
            if index == 0xFFFFFFFF then break end
            if index >= patch.cfg_max then return nil, 'spawn_config_index_mismatch' end
            return director + patch.cfg_base_offset + index * patch.cfg_stride, 'director:' .. index
        end
        if key == sentinel then break end
        slot = (slot + 1) % count
    end
    return resolve_resource_config(api, game, handle_data:sub(1, 8))
end
local function scale_config(api, game, director)
    local address, source = resolve_config(api, game, director)
    if not address then return 0, nil, source end
    local scaled, first = 0, nil
    mission.cfg = mission.cfg or {}
    local cfg = read_config(api, address)
    if not cfg then return 0, nil, 'spawn_config_layout_mismatch@' .. source end
    if not api.writable_data(address + 0x38, 0x1c)
        or not api.writable_data(address + patch.cfg_override_offset, 4) then
        return 0, nil, 'spawn_config_not_writable_private_data@' .. source
    end
    local key = source .. ':' .. tostring(address)
    local baseline = mission.cfg[key]
    if not baseline then
        if vanilla_config(cfg) then
            baseline = copy_cfg(cfg)
        else
            local restored = math.floor(cfg.group / patch.group_multiplier + 0.5)
            if cfg.group % patch.group_multiplier == 0
                and restored >= patch.min_group and restored <= patch.max_group then
                baseline = {
                    i38 = cfg.i38 * patch.interval_divisor,
                    i3c = cfg.i3c * patch.interval_divisor,
                    i40 = cfg.i40 * patch.interval_divisor,
                    i44 = cfg.i44 * patch.interval_divisor,
                    group = restored,
                    desired = cfg.desired,
                    override = cfg.override,
                }
            else
                baseline = copy_cfg(cfg)
            end
        end
        mission.cfg[key] = baseline
    end
    local t38 = interval_target(baseline.i38)
    local t3c = interval_target(baseline.i3c)
    local t40 = interval_target(baseline.i40)
    local t44 = interval_target(baseline.i44)
    if t38 > t3c then t38 = t3c end
    if t40 > t44 then t40 = t44 end
    local tgroup = baseline.group * patch.group_multiplier
    if tgroup > patch.max_group * patch.group_multiplier then
        tgroup = patch.max_group * patch.group_multiplier
    end
    if not write_interval(api, address, 0x38, cfg.i38, t38)
        or not write_interval(api, address, 0x3c, cfg.i3c, t3c)
        or not write_interval(api, address, 0x40, cfg.i40, t40)
        or not write_interval(api, address, 0x44, cfg.i44, t44) then
        return nil, 'spawn_interval_write_failed'
    end
    if cfg.group ~= tgroup then
        if not api.write(address + 0x48, pack_u32(tgroup))
            or u32(api.read(address + 0x48, 4) or '', 0) ~= tgroup then
            return nil, 'spawn_group_write_failed'
        end
    end
    local override_target
    local state_key = tostring(address)
    local state = override_state[state_key]
    if cfg.override > 0 then
        if state and near(cfg.override, state.applied) then
            override_target = state.applied
        else
            override_target = cfg.override * patch.budget_override_multiplier
        end
    else
        local points_bytes = api.read(director + patch.points_offset, 4)
        local base_points = points_bytes and number(points_bytes, 0) or 0
        if finite(base_points) and base_points > 0 then
            override_target = base_points * patch.budget_override_multiplier
        end
    end
    if override_target and override_target > 0 then
        if not near(cfg.override, override_target) then
            if not api.write(address + patch.cfg_override_offset, pack_f32(override_target))
                or not near(number(api.read(address + patch.cfg_override_offset, 4) or '', 0), override_target) then
                return nil, 'spawn_budget_override_write_failed'
            end
        end
        override_state[state_key] = {applied = override_target}
    end
    scaled = 1
    first = {
        i38 = t38, i3c = t3c, i40 = t40, i44 = t44,
        group = tgroup, desired = baseline.desired,
    }
    return scaled, first, source .. '@' .. tostring(address)
end

function patch.apply(api, game)
    if not in_mission(api, game) then
        reset()
        describe()
        return true, 'waiting_for_mission', false
    end
    local director = api.pointer(api.read(game + patch.director_rva, 8))
    if not director then
        reset()
        describe()
        return true, 'waiting_for_mission', false
    end
    local header_bytes = api.read(director + patch.cap_table_offset, 16)
    local header = header_bytes and api.pointer(header_bytes, 0)
    local entries, table_bytes, rows, table_size, count = nil, nil, nil, 0, 0
    local pending, valid, key = {}, 0, 'none'
    if header then
        table_bytes = api.read(header, patch.cap_header_size)
        if not table_bytes then return false, 'spawn_table_unreadable', false end
        entries = api.pointer(table_bytes, 0)
        count = u32(table_bytes, 8)
        if entries and count >= patch.min_count and count <= patch.max_count then
            table_size = count * patch.entry_stride
            rows = api.read(entries, table_size)
            if not rows then return false, 'spawn_entries_unreadable', false end
            key = tostring(count)
            for index = 0, count - 1 do
                local offset = index * patch.entry_stride
                local ident = u32(rows, offset)
                local maximum = u32(rows, offset + patch.max_offset)
                key = key .. ':' .. ident
                if ident == 0 then
                    if maximum ~= 0 then return false, 'spawn_entry_layout_mismatch', false end
                else
                    if maximum > patch.max_max * patch.cap_multiplier then
                        return false, 'spawn_entry_layout_mismatch', false
                    end
                    if maximum >= patch.min_max then
                        valid = valid + 1
                        pending[#pending + 1] = {offset = offset, ident = ident, maximum = maximum}
                    end
                end
            end
        end
    end
    if not same_pointer(api, mission.director, director) or mission.key ~= key then
        originals = {}
        mission.director, mission.key = director, key
        mission.points_original, mission.points_applied = nil, nil
        mission.guardforce_original, mission.guardforce_applied = nil, nil
        mission.cfg, mission.weights = nil, nil
    end
    local points_bytes = api.read(director + patch.points_offset, 8)
    if not points_bytes then return false, 'spawn_points_unreadable', false end
    if not api.writable_data(director + patch.points_offset, 4) then
        return false, 'spawn_points_are_not_writable_private_data', false
    end
    local points = number(points_bytes, 0)
    local guardforce = number(points_bytes, 4)
    if points ~= points or points < 0 or points > 1000000
        or guardforce ~= guardforce or guardforce < 0 or guardforce > 1000000 then
        return false, 'spawn_points_layout_mismatch', false
    end

    -- Recheck identity immediately before writes; mission init can rebuild
    -- the director between the layout walk and the first store.
    local current = api.pointer(api.read(game + patch.director_rva, 8))
    if not same_pointer(api, current, director)
        or (header_bytes and api.read(director + patch.cap_table_offset, 16) ~= header_bytes)
        or (table_bytes and api.read(header, patch.cap_header_size) ~= table_bytes)
        or (rows and api.read(entries, table_size) ~= rows) then
        describe(points, mission.points_original, valid, count, 0, 0, nil,
            guardforce, mission.guardforce_original, faction_name(count))
        return true, 'waiting_for_stable_mission', false
    end

    if #pending > 0 then
        if not api.writable_data(entries, table_size) then
            local cloned, reason = retarget_table(api, director, table_bytes, rows, table_size)
            if not cloned then return false, reason, false end
            entries = cloned
        end
        if not api.writable_data(entries, table_size) then
            return false, 'spawn_entries_are_not_writable_private_data', false
        end
        for _, entry in ipairs(pending) do
            local baseline = originals[entry.ident]
            if not baseline then
                if entry.maximum > patch.max_max then
                    local candidate = entry.maximum / patch.cap_multiplier
                    if entry.maximum % patch.cap_multiplier ~= 0
                        or candidate < patch.min_max or candidate > patch.max_max then
                        return false, 'spawn_entry_layout_mismatch', false
                    end
                    baseline = candidate
                else
                    baseline = entry.maximum
                end
                originals[entry.ident] = baseline
            end
            local target = baseline * patch.cap_multiplier
            if target > patch.max_max * patch.cap_multiplier then
                return false, 'spawn_cap_overflow', false
            end
            if entry.maximum == baseline then
                local address = entries + entry.offset + patch.max_offset
                if not api.write(address, pack_u32(target))
                    or u32(api.read(address, 4) or '', 0) ~= target then
                    return false, 'spawn_cap_write_failed', false
                end
            elseif entry.maximum ~= target then
                return false, 'spawn_cap_changed_underneath', false
            end
        end
    end

    local ok, reason = scale_points(api, director, points)
    if not ok then return false, reason, false end
    local faction = faction_name(count)
    local guard_ok, scaled_guardforce = scale_guardforce(api, director, guardforce, faction)
    if not guard_ok then return false, scaled_guardforce, false end
    local weighted, candidate_count, bias_reason = scale_candidate_weights(api, director)
    if weighted == nil then return false, candidate_count, false end
    local configs, cfg_live, cfg_reason = scale_config(api, game, director)
    if configs == nil then return false, cfg_live, false end
    local timers, timer_reason = clamp_timers(api, game, director, cfg_live)
    if timers == nil then return false, timer_reason, false end
    local pop_live = read_pop(api, director)
    local scaled_points = mission.points_applied or points
    describe(scaled_points, mission.points_original, valid, count, timers, pop_live, cfg_live,
        scaled_guardforce, mission.guardforce_original, faction)
    patch.detail = patch.detail .. ' w=' .. tostring(weighted) .. '/' .. tostring(candidate_count)
        .. (bias_reason and (':' .. bias_reason) or '')
        .. ' cfg=' .. tostring(cfg_reason)
    if configs > 0 then
        return true, 'spawn_multiplier_ready', true
    end
    if mission.points_applied or #pending > 0 or points > 0 or valid > 0 then
        return true, 'spawn_multiplier_partial', true
    end
    return true, 'waiting_for_spawn_config', false
end
return patch
