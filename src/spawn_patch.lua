-- Raises the HiveMind encounter budget to 6x while retaining the proven 5x
-- cap/group and 5x faster patrol/straggler interval configuration. Live spawn
-- frequency and per-wave group clamp come from the native
-- handle/hash resolver for the 0x438 config at director+0x519A4, not from
-- encounter points. Encounter points are a per-reinforcement composition
-- budget; they are not a remaining pool and do not control how often waves
-- fire. Guardforce / static POI budgets stay vanilla. Zero per-type cap rows
-- are a native skip. Native patrol timestamps and population counters remain
-- read-only diagnostics so the director can own its timing and accounting.
local ffi
local patch = {
    budget_multiplier = 6,
    cap_multiplier = 5,
    interval_divisor = 5,
    group_multiplier = 5,
    director_rva = 0x276CA20,
    mode_rva = 0x276c3d0,
    time_rva = 0x276C068,
    cap_table_offset = 0x660,
    points_offset = 0x518B0,
    pop_offset = 0x620, -- native ProducedFighter count; read-only diagnostic
    timer_offsets = {0x3A518, 0x3A520}, -- native timestamps; read-only
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
    cfg_stride = 0x438,
    cfg_max = 8,
    min_interval = 0.2,
    max_interval = 600,
    min_group = 1,
    max_group = 64,
    vanilla_patrol_max_floor = 12,
    native_patches = {
        {name = 'effective_70', rva = 0x947E69,
         expected = string.char(0x7D, 0xB0), replacement = string.char(0x90, 0x90)},
        {name = 'component_448', rva = 0x947E79,
         expected = string.char(0x73, 0xA0), replacement = string.char(0x90, 0x90)},
        {name = 'desired_reached', rva = 0x9512B9,
         expected = string.char(0x0F, 0x83, 0x8D, 0x02, 0x00, 0x00),
         replacement = string.char(0x90, 0x90, 0x90, 0x90, 0x90, 0x90)},
        {name = 'combined_100', rva = 0x9512C5,
         expected = string.char(0x0F, 0x83, 0x81, 0x02, 0x00, 0x00),
         replacement = string.char(0x90, 0x90, 0x90, 0x90, 0x90, 0x90)},
    },
}
local originals = {}
local clones = {block = nil, size = 0}
local resource_clone = {source = nil, block = nil, size = 0}
local mission = {
    director = nil, key = nil, points_original = nil, points_applied = nil,
    cfg = nil,
}
patch.detail = ''
local native_patches_ready = false

local function u32(bytes, offset)
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function pack_u32(value)
    ffi = ffi or require('ffi')
    local buffer = ffi.new('uint32_t[1]', value)
    return ffi.string(buffer, 4)
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
    mission.cfg = nil
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
local function describe(points, original, valid, count, timers, pop, cfg)
    local i38, i3c, i40, i44, group, desired = 0, 0, 0, 0, 0, 0
    if cfg then
        i38, i3c, i40, i44, group, desired =
            cfg.i38, cfg.i3c, cfg.i40, cfg.i44, cfg.group, cfg.desired
    end
    patch.detail = string.format('p=%.1f/%s c=%d/%d t=%d x=%d i=%.2f-%.2f/%.2f-%.2f g=%d d=%d l=off',
        points or 0,
        original and string.format('%.1f', original) or '-',
        valid or 0, count or 0, timers or 0, pop or 0,
        i38, i3c, i40, i44, group, desired)
end
local function apply_native_patches(api, game)
    if native_patches_ready then return true end
    if type(api.patch_code) ~= 'function' then return false, 'spawn_code_writer_missing' end
    local applied = {}
    for _, item in ipairs(patch.native_patches) do
        local address = game + item.rva
        local before = api.read(address, #item.expected)
        if before ~= item.replacement then
            if before ~= item.expected then
                for index = #applied, 1, -1 do
                    local previous = applied[index]
                    api.patch_code(game + previous.rva, previous.replacement, previous.expected)
                end
                return false, 'spawn_limit_bytes_mismatch@' .. item.name
            end
            local ok, reason = api.patch_code(address, item.expected, item.replacement)
            if not ok then
                for index = #applied, 1, -1 do
                    local previous = applied[index]
                    api.patch_code(game + previous.rva, previous.replacement, previous.expected)
                end
                return false, 'spawn_limit_patch_failed@' .. item.name .. ':' .. tostring(reason)
            end
            applied[#applied + 1] = item
        end
    end
    native_patches_ready = true
    return true
end
local function retarget_table(api, director, table_bytes, rows, table_size)
    ffi = ffi or require('ffi')
    local size = 16 + table_size
    if not clones.block or clones.size < size then
        clones.block = api.alloc_private(size)
        clones.size = clones.block and size or 0
        if not clones.block then return nil, 'spawn_clone_alloc_failed' end
    end
    local block = clones.block
    local copy = block + 16
    ffi.copy(copy, rows, table_size)
    ffi.copy(block, pack_ptr(copy) .. table_bytes:sub(9, 16), 16)
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
local function read_pop(api, director)
    local raw = api.read(director + patch.pop_offset, 4)
    return raw and u32(raw, 0) or 0
end
local function copy_cfg(cfg)
    return {
        i38 = cfg.i38, i3c = cfg.i3c, i40 = cfg.i40, i44 = cfg.i44,
        group = cfg.group, desired = cfg.desired,
    }
end
local function read_config(api, address)
    local bytes = api.read(address + 0x38, 0x1c)
    if not bytes or #bytes < 0x1c then return nil end
    local cfg = {
        i38 = number(bytes, 0),
        i3c = number(bytes, 4),
        i40 = number(bytes, 8),
        i44 = number(bytes, 12),
        group = u32(bytes, 0x10),
        desired = u32(bytes, 0x18),
    }
    if not (finite(cfg.i38) and finite(cfg.i3c) and finite(cfg.i40) and finite(cfg.i44)) then
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
    if not api.writable_data(address + 0x38, 0x14) then
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
    scaled = 1
    first = {
        i38 = t38, i3c = t3c, i40 = t40, i44 = t44,
        group = tgroup, desired = cfg.desired,
    }
    return scaled, first, source .. '@' .. tostring(address)
end

function patch.apply(api, game)
    local patched, patch_reason = apply_native_patches(api, game)
    if not patched then return false, patch_reason, false end
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
        table_bytes = api.read(header, 16)
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
        mission.cfg = nil
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
        or (rows and api.read(entries, table_size) ~= rows) then
        describe(points, mission.points_original, valid, count, 0, 0)
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
    local configs, cfg_live, cfg_reason = scale_config(api, game, director)
    if configs == nil then return false, cfg_live, false end
    local pop_live = read_pop(api, director)
    local scaled_points = mission.points_applied or points
    describe(scaled_points, mission.points_original, valid, count, 0, pop_live, cfg_live)
    patch.detail = patch.detail .. ' cfg=' .. tostring(cfg_reason)
    if configs > 0 then
        return true, 'spawn_multiplier_ready', true
    end
    if mission.points_applied or #pending > 0 or points > 0 or valid > 0 then
        return true, 'spawn_multiplier_partial', true
    end
    return true, 'waiting_for_spawn_config', false
end
return patch
