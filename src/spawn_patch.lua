-- Data-only spawn tuning profiles for the supported 1.8.46015.0 build.
-- Encounter points are a per-reinforcement composition budget from
-- director+0x518B0, not a remaining pool. Timed Patrol/Straggler frequency comes
-- from the resolved 0x43C config at director+0x519AC. The v18 profiles raise the
-- Encounter budget and shorten both timed paths. The Fast Cadence profile lowers
-- the
-- Encounter budget while driving the timed paths to their positive scheduling
-- floor, and can leave GuardForce entirely native. A zero maximum interval makes
-- the native code skip that timed path, so that profile pins 0.0-0.1 seconds.
-- Zero per-type cap rows are a native skip. Population counters and executable
-- code remain read-only.
local ffi
local patch = {
    budget_multiplier = 6,
    budget_override_multiplier = 6,
    derive_override_from_base = true,
    force_override_to_base = false,
    encounter_deadline_enabled = false,
    encounter_max_interval = 2.0,
    -- cfg+0x0C/+0x10 are TravelerSettings.minimum/maximum_spawn_point_cooldown
    -- in HiveMindComponent: "the amount of time that a spawn point goes on
    -- cooldown after being used". Documented default is 30-60 seconds and the
    -- measured patrol cadence was 45-63 seconds across two vanilla sessions.
    traveler_cooldown_enabled = false,
    traveler_cooldown_min = 0,
    traveler_cooldown_max = 0,
    -- MissionDifficultySettings modifier curves inside the same 0x43C row.
    -- Each block is 15 floats (5 + 4 + 1 + 5) blended per difficulty/progress by
    -- game.dll+0xFE5280. A value of 0 disables that block. Fields whose name
    -- contains _rate_ are frequency multipliers; cooldown shrinks as they grow.
    modifier_scale_enabled = false,
    modifier_encounter_cooldown = 0,   -- cfg+0x164 encounter_cooldown_rate_modifier
    modifier_patrol_count = 0,         -- cfg+0x1A0 patrol_count_max_modifier
    modifier_patrol_cooldown = 0,      -- cfg+0x1DC patrol_spawn_cooldown_rate_modifier
    modifier_travelers_max_unit = 0,   -- cfg+0x3F8 travelers_max_unit_count_multiplier
    modifier_state_key = 'none',
    guardforce_write_enabled = true,
    template_bias_enabled = false,
    template_bias_light = 3.6,
    template_bias_medium = 1.25,
    template_bias_heavy = 0.25,
    illuminate_guardforce_multiplier = 0.25,
    -- Cap-table counts last measured on 1.8.45317.0; the section layout is unchanged
    -- through 1.8.46015.0, so a mismatch still only labels the faction unknown.
    -- A mismatch only labels the faction unknown and skips Illuminate guard scaling.
    faction_cap_counts = {automaton = 61, terminid = 44, illuminate = 45},
    cap_multiplier = 10,
    interval_mode = 'divide',
    interval_divisor = 10,
    fixed_interval_min = 0.1,
    fixed_interval_max = 0.1,
    allow_zero_interval_min = false,
    group_multiplier = 10,
    director_rva = 0x3326D10,
    mode_rva = 0x33266A0,
    time_rva = 0x3326348,
    cap_table_offset = 0x660,
    cap_header_size = 0xB0,
    points_offset = 0x518B0,
    encounter_deadline_offset = 0x399D8,
    encounter_manager_rva = 0x3326618,
    encounter_manager_count_offset = 0x934,
    scheduler_a_rva = 0x3326588,
    scheduler_a_offset = 0x4A4,
    scheduler_b_rva = 0x3326D18,
    scheduler_b_offset = 0x1C,
    scheduler_flags = {0x5189C, 0x518A0, 0x518A4, 0x518A8},
    probe_timer_offsets = {0x399D0, 0x399E8, 0x399F0, 0x3A510, 0x3A528, 0x3A530, 0x3A538},
    probe_timers_enabled = false,
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
    cfg_table_offset = 0x51968,
    cfg_count_offset = 0x51970,
    cfg_hash_multiplier_offset = 0x51978,
    cfg_sentinel_offset = 0x51974,
    cfg_invalid_generation_rva = 0x3483C24,
    resource_manager_rva = 0x346BF98,
    resource_table_offset = 0xF12B18,
    resource_slots = 38,
    cfg_base_offset = 0x519AC,
    cfg_override_offset = 0x78,
    cfg_stride = 0x43C,
    cfg_max = 8,
    min_interval = 0.1,
    max_interval = 600,
    min_group = 1,
    max_group = 64,
    vanilla_patrol_max_floor = 12,
}
-- Live-reconfiguration surface for the in-game panel. The panel only ever
-- assigns into these same fields, so the 0.1 s updater picks a change up on its
-- next pass without a mission reload. Every value is range-checked before it is
-- accepted; a rejected change must leave the previous configuration in place.
patch.budget_min, patch.budget_max = 0.1, 6.0
patch.modifier_min, patch.modifier_max = 0.1, 6.0
-- Cooldown sliders are expressed as a target interval in seconds. The fast end
-- is the aggressive preset; the slow end leaves the native curve untouched and
-- disables the deadline clamp, so it corresponds to the game's own pacing
-- (documented around 30 s for this setting). In between, the rate curve is
-- interpolated. Only the reinforcement deadline has a true seconds-level lever;
-- the patrol path is a rate curve, so its slider interpolates the same way and
-- the seconds value is the target that curve is chosen to approximate.
patch.cooldown_fast_seconds, patch.cooldown_slow_seconds = 2.0, 30.0
-- The two paths have different fastest-end rate scales. Reinforcement keeps the
-- 3x curve; the patrol refresh curve is pushed to 6x at the fast end because the
-- patrol scheduling gate tolerates a much shorter cooldown than the
-- reinforcement admission path. Both slow ends return the curve to native 1.0.
patch.cooldown_fast_rate = 3.0          -- reinforcement fastest-end rate
patch.patrol_cooldown_fast_rate = 6.0   -- patrol fastest-end rate
patch.cooldown_min_seconds, patch.cooldown_max_seconds = patch.cooldown_fast_seconds, patch.cooldown_slow_seconds

-- Map a target interval in seconds onto a rate curve plus, for the
-- reinforcement path, the deadline clamp. t is 0 at the fast end and 1 at the
-- slow end; at t == 1 the curve is left native and the clamp is disabled.
-- fast_rate is supplied by the caller so the two paths can use different scales.
local function cooldown_profile(seconds, fast_rate)
    local span = patch.cooldown_slow_seconds - patch.cooldown_fast_seconds
    if span <= 0 then return nil end
    -- Inline NaN/huge guard: this helper is defined above the shared `finite`
    -- local, which is not in scope at this point in the chunk.
    if type(fast_rate) ~= 'number' or fast_rate ~= fast_rate or math.abs(fast_rate) == math.huge
        or fast_rate < 1.0 then
        return nil
    end
    local t = (seconds - patch.cooldown_fast_seconds) / span
    if t < 0 or t > 1 then return nil end
    local rate = fast_rate + (1.0 - fast_rate) * t
    return rate, t < 1.0, seconds
end
patch.presets = {
    -- Heavy focus, as used by the Fast Cadence line.
    heavy = {light = 0.25, medium = 1.0, heavy = 4.0},
    -- Light/medium focus, as used by the Light-Medium Bias line.
    light_medium = {light = 3.6, medium = 1.25, heavy = 0.25},
}

-- Reject rather than clamp: a caller that asks for a value outside the
-- supported range has a bug, and silently substituting a different multiplier
-- would make the in-game panel disagree with the applied configuration.
local function checked_range(value, low, high)
    if type(value) ~= 'number' or value ~= value then return nil end
    if value < low or value > high then return nil end
    return value
end

-- settings = {budget, patrol_count, patrol_size,
--             encounter_cd_seconds, patrol_cd_seconds, preset}
-- budget / patrol_count / patrol_size are plain multipliers in
--   [budget_min, budget_max] and [modifier_min, modifier_max].
-- encounter_cd_seconds / patrol_cd_seconds are target intervals in
--   [cooldown_fast_seconds, cooldown_slow_seconds]. The fast end scales the rate
--   curve up and, for reinforcements, clamps the pending deadline; the slow end
--   restores the native curve and removes the clamp.
-- preset is 'heavy', 'light_medium' or 'native'.
function patch.configure(settings)
    if type(settings) ~= 'table' then return false, 'settings_not_a_table' end
    local next_budget = settings.budget
    if next_budget ~= nil then
        next_budget = checked_range(next_budget, patch.budget_min, patch.budget_max)
        if not next_budget then return false, 'budget_out_of_range' end
    end
    local next_patrol_count = settings.patrol_count
    if next_patrol_count ~= nil then
        next_patrol_count = checked_range(next_patrol_count, patch.modifier_min, patch.modifier_max)
        if not next_patrol_count then return false, 'patrol_count_out_of_range' end
    end
    local next_patrol_size = settings.patrol_size
    if next_patrol_size ~= nil then
        next_patrol_size = checked_range(next_patrol_size, patch.modifier_min, patch.modifier_max)
        if not next_patrol_size then return false, 'patrol_size_out_of_range' end
    end
    local next_encounter_cd = settings.encounter_cd_seconds
    if next_encounter_cd ~= nil then
        next_encounter_cd = checked_range(next_encounter_cd,
            patch.cooldown_fast_seconds, patch.cooldown_slow_seconds)
        if not next_encounter_cd then return false, 'encounter_cd_out_of_range' end
    end
    local next_patrol_cd = settings.patrol_cd_seconds
    if next_patrol_cd ~= nil then
        next_patrol_cd = checked_range(next_patrol_cd,
            patch.cooldown_fast_seconds, patch.cooldown_slow_seconds)
        if not next_patrol_cd then return false, 'patrol_cd_out_of_range' end
    end
    local preset = settings.preset
    if preset ~= nil and preset ~= 'native' and not patch.presets[preset] then
        return false, 'preset_unknown'
    end

    if next_budget then
        patch.budget_multiplier = next_budget
        patch.budget_override_multiplier = next_budget
        -- The override is always pinned to the already-scaled director value, so
        -- a budget change cannot be bypassed by a positive native override.
        patch.force_override_to_base = true
        patch.derive_override_from_base = false
    end
    if next_patrol_count then patch.modifier_patrol_count = next_patrol_count end
    if next_patrol_size then patch.modifier_travelers_max_unit = next_patrol_size end
    if next_encounter_cd then
        local rate, clamp, seconds = cooldown_profile(next_encounter_cd, patch.cooldown_fast_rate)
        if not rate then return false, 'encounter_cd_profile_mismatch' end
        patch.modifier_encounter_cooldown = rate
        patch.encounter_deadline_enabled = clamp
        patch.encounter_max_interval = seconds
    end
    if next_patrol_cd then
        local rate = cooldown_profile(next_patrol_cd, patch.patrol_cooldown_fast_rate)
        if not rate then return false, 'patrol_cd_profile_mismatch' end
        patch.modifier_patrol_cooldown = rate
    end
    if preset then
        local weights = patch.presets[preset]
        if weights then
            patch.template_bias_enabled = true
            patch.template_bias_light = weights.light
            patch.template_bias_medium = weights.medium
            patch.template_bias_heavy = weights.heavy
        else
            -- Reverting to native weights is handled by scale_candidate_weights,
            -- which restores every weight this profile already wrote.
            patch.template_bias_enabled = false
        end
    end
    -- Once a curve has been scaled it stays enabled, because a scale of exactly
    -- 1.0 is what restores the stored native baseline on a live switch back to
    -- "native". Disabling the block would leave the scaled values in place.
    local wanted_scale = (patch.modifier_patrol_count ~= 1.0)
        or (patch.modifier_travelers_max_unit ~= 1.0)
        or (patch.modifier_encounter_cooldown ~= 1.0)
        or (patch.modifier_patrol_cooldown ~= 1.0)
    patch.modifier_scale_enabled = patch.modifier_scale_enabled or wanted_scale
    return true
end

local originals = {}
local clones = {block = nil, size = 0}
local resource_clone = {source = nil, block = nil, size = 0}
local override_state = {}
local modifier_state = {}
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
    local i38, i3c, i40, i44, group, desired, override = 0, 0, 0, 0, 0, 0, -1
    if cfg then
        i38, i3c, i40, i44, group, desired, override =
            cfg.i38, cfg.i3c, cfg.i40, cfg.i44, cfg.group, cfg.desired,
            cfg.override or -1
    end
    patch.detail = string.format('p=%.1f/%s gf=%.1f/%s f=%s c=%d/%d t=%d x=%d i=%.2f-%.2f/%.2f-%.2f g=%d d=%d o=%.2f l=vanilla',
        points or 0,
        original and string.format('%.1f', original) or '-',
        guardforce or 0,
        guardforce_original and string.format('%.1f', guardforce_original) or '-',
        faction or 'unknown',
        valid or 0, count or 0, timers or 0, pop or 0,
        i38, i3c, i40, i44, group, desired, override)
    patch.detail = patch.detail .. string.format(' tv=%.1f-%.1f',
        cfg and cfg.traveler_min or 0, cfg and cfg.traveler_max or 0)
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
local function scale_points(api, director, points, budget)
    if not (points > 0) then return true end
    if not mission.points_original then
        mission.points_original = points
    end
    local original = mission.points_original
    local target = original * budget
    if near(points, target) then
        mission.points_applied = target
        return true
    end
    -- Either the field still holds the value this profile last wrote, or the
    -- native code consumed it back down toward the original point total. Both
    -- mean the stored original stays authoritative, so a changed budget simply
    -- writes the new target instead of adopting the scaled value as a baseline.
    local ours = mission.points_applied and near(points, mission.points_applied)
    local write
    if ours or points <= original * 1.05 then
        write = target
    elseif points > target * 1.05 then
        mission.points_original = points
        write = points * budget
    else
        mission.points_applied = points
        return true
    end
    if not api.write(director + patch.points_offset, pack_f32(write))
        or not near(number(api.read(director + patch.points_offset, 4), 0), write) then
        return false, 'spawn_points_write_failed'
    end
    mission.points_applied = write
    return true
end
local function scale_guardforce(api, director, guardforce, faction)
    if not patch.guardforce_write_enabled then
        if guardforce > 0 and not mission.guardforce_original then
            mission.guardforce_original = guardforce
        end
        return true, guardforce
    end
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
local function read_u32_at(api, address)
    local bytes = address and api.read(address, 4)
    return bytes and u32(bytes, 0) or 0
end
local function deadline_delta(api, address, now)
    local bytes = api.read(address, 8)
    local value = bytes and u64(bytes, 0)
    if not now or not value then return -1 end
    return (value - now) / patch.timer_units_per_second
end
local function scheduler_status(api, game, director)
    local clock = api.pointer(api.read(game + patch.time_rva, 8))
    local now_bytes = clock and api.read(clock + 0x18, 8)
    local now = now_bytes and u64(now_bytes, 0)
    local manager = api.pointer(api.read(game + patch.encounter_manager_rva, 8))
    local lists = read_u32_at(api, manager and manager + patch.encounter_manager_count_offset)
    local a_manager = api.pointer(api.read(game + patch.scheduler_a_rva, 8))
    local b_manager = api.pointer(api.read(game + patch.scheduler_b_rva, 8))
    local a = read_u32_at(api, a_manager and a_manager + patch.scheduler_a_offset)
    local b = read_u32_at(api, b_manager and b_manager + patch.scheduler_b_offset)
    local flags = {}
    for index, offset in ipairs(patch.scheduler_flags) do
        flags[index] = read_u32_at(api, director + offset) ~= 0 and 1 or 0
    end
    local text = string.format(' e=%.2f m=%d a=%d b=%d pd=%.2f sd=%.2f fl=%d%d%d%d',
        deadline_delta(api, director + patch.encounter_deadline_offset, now), lists,
        a, b,
        deadline_delta(api, director + patch.timer_offsets[2], now),
        deadline_delta(api, director + patch.timer_offsets[1], now),
        flags[1], flags[2], flags[3], flags[4])
    if patch.probe_timers_enabled and now then
        local parts = {}
        for _, value in ipairs(patch.probe_timer_offsets) do
            local bytes = api.read(director + value, 8)
            local raw = bytes and u64(bytes, 0)
            if raw then
                local delta = (raw - now) / patch.timer_units_per_second
                if delta > -3600 and delta < 3600 then
                    parts[#parts + 1] = string.format('%x:%.1f', value, delta)
                end
            end
        end
        text = text .. ' T=' .. table.concat(parts, ',')
    end
    return text
end
local function scale_candidate_weights(api, director)
    if not patch.template_bias_enabled then
        -- A live switch back to native weights must undo the bias this profile
        -- already wrote, otherwise the scaled weights would stay in place with
        -- nothing left to restore them.
        local restored = 0
        if mission.weights then
            for _, state in pairs(mission.weights) do
                if state.applied and state.address
                    and not near(state.applied, state.baseline) then
                    if not api.write(state.address + patch.candidate_weight_offset,
                                     pack_f32(state.baseline)) then
                        return nil, 0, 'spawn_candidate_weight_restore_failed'
                    end
                    restored = restored + 1
                end
                state.applied = nil
            end
        end
        return 0, 0
    end
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
            state = {baseline = weight, applied = nil, address = address}
            mission.weights[key] = state
        elseif state.applied and not near(weight, state.applied) and not near(weight, state.baseline) then
            state.baseline, state.applied = weight, nil
        end
        state.address = address
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
local MODIFIER_BLOCK_SIZE = 15
-- 0x3F8 is the only patrol-specific size lever: game.dll+0x94E900 computes the
-- traveler unit count as round(base_count * cfg[curve_index + 0x3F8]). The other
-- two patrol curves control how many patrols exist and how often they appear.
local MODIFIER_BLOCKS = {
    {offset = 0x164, key = 'encounter_cooldown', label = 'spawn_modifier_encounter_cooldown'},
    {offset = 0x1a0, key = 'patrol_count', label = 'spawn_modifier_patrol_count'},
    {offset = 0x1dc, key = 'patrol_cooldown', label = 'spawn_modifier_patrol_cooldown'},
    {offset = 0x3f8, key = 'travelers_max_unit', label = 'spawn_modifier_travelers_max_unit'},
}
local function modifier_scales()
    return {
        encounter_cooldown = patch.modifier_encounter_cooldown,
        patrol_count = patch.modifier_patrol_count,
        patrol_cooldown = patch.modifier_patrol_cooldown,
        travelers_max_unit = patch.modifier_travelers_max_unit,
    }
end
local function scale_modifier_block(api, address, offset, scale, label)
    if not finite(scale) or scale <= 0 then return 0, -1 end
    if scale < 0.05 or scale > 50 then
        return nil, label .. '_scale_out_of_range'
    end
    if not api.writable_data(address + offset, MODIFIER_BLOCK_SIZE * 4) then
        return nil, label .. '_not_writable_private_data'
    end
    -- cdata pointers are not reliable table keys here; the existing override
    -- state uses the string form for the same reason.
    local state_key = tostring(address)
    local store = modifier_state[state_key]
    if not store then store = {}; modifier_state[state_key] = store end
    local saved = store[offset]
    local current = {}
    for index = 0, MODIFIER_BLOCK_SIZE - 1 do
        local bytes = api.read(address + offset + index * 4, 4)
        if not bytes then return nil, label .. '_unreadable' end
        current[index] = number(bytes, 0)
        if not finite(current[index]) then return nil, label .. '_layout_mismatch' end
    end
    if not saved then
        saved = {baseline = {}}
        for index = 0, MODIFIER_BLOCK_SIZE - 1 do saved.baseline[index] = current[index] end
        store[offset] = saved
    end
    local changed = 0
    for index = 0, MODIFIER_BLOCK_SIZE - 1 do
        local base = saved.baseline[index]
        if base ~= 0 then
            local live = current[index]
            local target = base * scale
            if not near(live, target) then
                -- Three cases reach this point. `live` equal to the stored
                -- baseline means the game never took our value; `live` equal to
                -- `base * saved.applied_scale` means it still holds the value
                -- this profile last wrote. Both mean the stored baseline is
                -- authoritative, so a scale change (including a live panel
                -- change) just recomputes the target. Anything else is the game
                -- re-blending a new native row, which becomes the new baseline.
                local ours = saved.applied_scale and (base * saved.applied_scale) or base
                if not (near(live, base) or near(live, ours)) then
                    saved.baseline[index] = live
                    target = live * scale
                end
                if not api.write(address + offset + index * 4, pack_f32(target))
                    or not near(number(api.read(address + offset + index * 4, 4) or '', 0), target) then
                    return nil, label .. '_write_failed'
                end
                changed = changed + 1
            end
        end
    end
    saved.applied_scale = scale
    local head = api.read(address + offset, 4)
    return changed, head and number(head, 0) or -1
end
local function copy_cfg(cfg)
    return {
        i38 = cfg.i38, i3c = cfg.i3c, i40 = cfg.i40, i44 = cfg.i44,
        group = cfg.group, desired = cfg.desired, override = cfg.override,
        traveler_min = cfg.traveler_min, traveler_max = cfg.traveler_max,
    }
end
local function read_config(api, address)
    local bytes = api.read(address + 0x38, 0x1c)
    if not bytes or #bytes < 0x1c then return nil end
    local override_bytes = api.read(address + patch.cfg_override_offset, 4)
    if not override_bytes then return nil end
    -- The traveler pair is only read for diagnostics unless the profile actually
    -- writes it, so a build that never touches these fields keeps its old
    -- accept/reject behaviour exactly.
    local traveler_min, traveler_max = 0, 0
    local traveler_bytes = api.read(address + 0x0c, 8)
    if traveler_bytes then
        local low, high = number(traveler_bytes, 0), number(traveler_bytes, 4)
        if finite(low) and finite(high) then traveler_min, traveler_max = low, high end
    end
    local cfg = {
        traveler_min = traveler_min,
        traveler_max = traveler_max,
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
    if patch.traveler_cooldown_enabled
        and (cfg.traveler_min < 0 or cfg.traveler_max < 0 or cfg.traveler_min > cfg.traveler_max) then
        return nil
    end
    if patch.allow_zero_interval_min then
        if cfg.i38 < 0 or cfg.i3c <= 0 or cfg.i40 < 0 or cfg.i44 <= 0 then return nil end
    elseif cfg.i38 <= 0 or cfg.i3c <= 0 or cfg.i40 <= 0 or cfg.i44 <= 0 then
        return nil
    end
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
local function interval_target(original, is_maximum)
    if patch.interval_mode == 'fixed' then
        if not finite(patch.fixed_interval_min) or not finite(patch.fixed_interval_max)
            or patch.fixed_interval_min < 0 or patch.fixed_interval_max <= 0
            or patch.fixed_interval_min > patch.fixed_interval_max then
            return nil
        end
        if is_maximum then return patch.fixed_interval_max end
        return patch.fixed_interval_min
    end
    local target = original / patch.interval_divisor
    if target < patch.min_interval then return patch.min_interval end
    return target
end
local function write_interval(api, address, offset, current, target)
    if near(current, target) then return true end
    return api.write(address + offset, pack_f32(target))
        and near(number(api.read(address + offset, 4) or '', 0), target)
end
local function clamp_deadline(api, address, limit, label)
    local bytes = api.read(address, 8)
    local pending = bytes and u64(bytes, 0)
    if not pending or pending <= limit then return 0 end
    if not api.writable_data(address, 8) then return 0, label .. '_not_writable_private_data' end
    if not api.write(address, pack_u64(limit))
        or u64(api.read(address, 8) or '', 0) ~= limit then
        return nil, label .. '_write_failed'
    end
    return 1
end
local function clamp_timers(api, game, director, cfg)
    if not cfg then return 0 end
    local clock = api.pointer(api.read(game + patch.time_rva, 8))
    if not clock then return 0 end
    local now_bytes = api.read(clock + 0x18, 8)
    local now = now_bytes and u64(now_bytes, 0)
    if not now or now < 0 or now > 9000000000000000 then return 0 end
    local changed, notes = 0, {}
    local maximums = {cfg.i3c, cfg.i44}
    for index, offset in ipairs(patch.timer_offsets) do
        local limit = now + math.floor(maximums[index] * patch.timer_units_per_second + 0.5)
        local applied, note = clamp_deadline(api, director + offset, limit, 'spawn_timer')
        if applied == nil then return nil, note end
        changed = changed + applied
        if note then notes[#notes + 1] = note end
    end
    if patch.encounter_deadline_enabled then
        if not finite(patch.encounter_max_interval) or patch.encounter_max_interval < 0.1
            or patch.encounter_max_interval > 600 then
            return nil, 'spawn_encounter_interval_profile_mismatch'
        end
        local limit = now + math.floor(patch.encounter_max_interval * patch.timer_units_per_second + 0.5)
        local applied, note = clamp_deadline(api, director + patch.encounter_deadline_offset, limit,
            'spawn_encounter_timer')
        if applied == nil then return nil, note end
        changed = changed + applied
        if note then notes[#notes + 1] = note end
    end
    if #notes > 0 then return changed, table.concat(notes, ',') end
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
    -- Native 0x505F50 uses an unsigned 64-bit key modulo 38. Reducing
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
        or not api.writable_data(address + patch.cfg_override_offset, 4)
        or (patch.traveler_cooldown_enabled and not api.writable_data(address + 0x0c, 8)) then
        return 0, nil, 'spawn_config_not_writable_private_data@' .. source
    end
    if patch.modifier_scale_enabled then
        for _, block in ipairs(MODIFIER_BLOCKS) do
            if not api.writable_data(address + block.offset, MODIFIER_BLOCK_SIZE * 4) then
                return 0, nil, block.label .. '_not_writable_private_data@' .. source
            end
        end
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
                    traveler_min = cfg.traveler_min,
                    traveler_max = cfg.traveler_max,
                }
            else
                baseline = copy_cfg(cfg)
            end
        end
        mission.cfg[key] = baseline
    end
    local t38 = interval_target(baseline.i38, false)
    local t3c = interval_target(baseline.i3c, true)
    local t40 = interval_target(baseline.i40, false)
    local t44 = interval_target(baseline.i44, true)
    if not t38 or not t3c or not t40 or not t44 then
        return nil, 'spawn_interval_profile_mismatch'
    end
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
    local tvc_min, tvc_max = baseline.traveler_min, baseline.traveler_max
    if patch.traveler_cooldown_enabled then
        local target_min, target_max = patch.traveler_cooldown_min, patch.traveler_cooldown_max
        if not finite(target_min) or not finite(target_max)
            or target_min < 0 or target_max <= 0 or target_min > target_max then
            return nil, 'spawn_traveler_interval_profile_mismatch'
        end
        if not write_interval(api, address, 0x0c, cfg.traveler_min, target_min)
            or not write_interval(api, address, 0x10, cfg.traveler_max, target_max) then
            return nil, 'spawn_traveler_write_failed'
        end
        tvc_min, tvc_max = target_min, target_max
    end
    patch.modifier_detail = ''
    if patch.modifier_scale_enabled then
        local scales = modifier_scales()
        local parts = {}
        for _, block in ipairs(MODIFIER_BLOCKS) do
            local applied, head = scale_modifier_block(api, address, block.offset, scales[block.key], block.label)
            if applied == nil then return nil, head end
            parts[#parts + 1] = string.format('%.2f', head)
        end
        patch.modifier_detail = ' mv=' .. table.concat(parts, '/')
            .. ' ms=' .. string.format('%.1f/%.1f/%.1f/%.1f',
                scales.encounter_cooldown, scales.patrol_count,
                scales.patrol_cooldown, scales.travelers_max_unit)
    end
    local override_target
    local state_key = tostring(address)
    local state = override_state[state_key]
    if patch.force_override_to_base then
        local points_bytes = api.read(director + patch.points_offset, 4)
        local base_points = points_bytes and number(points_bytes, 0) or 0
        if finite(base_points) and base_points > 0 then
            override_target = base_points
        end
    elseif cfg.override > 0 then
        if state and near(cfg.override, state.applied) then
            override_target = state.applied
        else
            override_target = cfg.override * patch.budget_override_multiplier
        end
    elseif patch.derive_override_from_base then
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
        override = override_target or cfg.override,
        traveler_min = tvc_min, traveler_max = tvc_max,
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

    local ok, reason = scale_points(api, director, points, patch.budget_multiplier)
    if not ok then return false, reason, false end
    local faction = faction_name(count)
    local guard_ok, scaled_guardforce = scale_guardforce(api, director, guardforce, faction)
    if not guard_ok then return false, scaled_guardforce, false end
    local weighted, candidate_count, bias_reason = scale_candidate_weights(api, director)
    if weighted == nil then return false, candidate_count, false end
    local configs, cfg_live, cfg_reason = scale_config(api, game, director)
    if configs == nil then return false, cfg_live, false end
    local timers, timer_note = clamp_timers(api, game, director, cfg_live)
    if timers == nil then return false, timer_note, false end
    local pop_live = read_pop(api, director)
    local scaled_points = mission.points_applied or points
    describe(scaled_points, mission.points_original, valid, count, timers, pop_live, cfg_live,
        scaled_guardforce, mission.guardforce_original, faction)
    patch.detail = patch.detail .. scheduler_status(api, game, director)
        .. (timer_note and (' n=' .. timer_note) or '')
        .. (patch.modifier_detail or '')
        .. ' w=' .. tostring(weighted) .. '/' .. tostring(candidate_count)
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
