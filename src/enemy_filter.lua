-- Data-only unit resource replacements for the director family selector.
-- Keep native eligibility, family accounting and budgets intact. A native
-- caller dereferences the selected resource even when the selector returns nil,
-- so excluding every row of a family is unsafe. Use a valid Warrior resource.
-- Never call native spawn/despawn functions or touch live/pending counters.
return function(api, game)
    local ffi = require('ffi')
    local M = {block_jumpers = false, block_yellow_spewers = false, block_green_spewers = false,
               block_bile_spitters = false, block_scavengers = false,
               block_shriekers = false, block_all_small = false}
    local SMALL_OPTIONS = {block_jumpers = true, block_bile_spitters = true,
                           block_scavengers = true, block_shriekers = true}
    local function selected(option)
        return option ~= nil and (M[option] == true or (M.block_all_small and SMALL_OPTIONS[option] == true))
    end
    local MODE, DIRECTOR = 0x33266A0, 0x3326D10
    local TAG_HASHES, SCAVENGER_FAMILY = 0x21E1920, 3478611010
    local HEADER_SIZE, STRIDE, RESOURCE_OFFSET = 0xB0, 0x80, 8
    -- Family IDs come from the current native rows, matched by UNIT RESOURCE
    -- to the generated roster/catalog; names[] indices are NOT family indices.
    local FAMILIES = {
        [137310222] = 'block_jumpers',       -- Pouncer
        [3517152816] = 'block_jumpers',      -- Hunter, both difficulty variants
        [333947844] = 'block_jumpers',       -- Spore Burst Hunter
        [1837263553] = 'block_yellow_spewers', -- Nursing Spewer
        [2255668545] = 'block_green_spewers',  -- Bile Spewer, tiers 1 and 2
        [96305411] = 'block_bile_spitters',   -- small Bile Spitter, separate from both Spewers
        [1428114468] = 'block_scavengers',    -- dedicated Spore Burst Scavenger row
        [2519355991] = 'block_shriekers',     -- native flying/guard Shrieker row
        [4197606685] = 'block_shriekers',     -- second native Shrieker row, same verified resource
    }
    local PROOFS = {
        {0x9531FE, '488d5758498d8dd4180500e8b2b1e20084c07426'},
        {0x949BF9, '498b4008'}, -- native resource resolver reads row + 8
        {0x86950C, '488b4008'}, -- caller requires a non-null selected row
    }
    local function bytes(hex)
        return (hex:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end))
    end
    local SCAVENGER_RESOURCES = {
        [bytes('4e7e99f66ba8ee51')] = true,
        [bytes('0c237b28ae3a8a9a')] = true,
    }
    local SPORE_SCAVENGER, SHRIEKER = bytes('01f51cbe314696db'), bytes('dd35245088000964')
    local function known_direct_resource(option, resource)
        if option == 'block_scavengers' then return resource == SPORE_SCAVENGER end
        if option == 'block_shriekers' then return resource == SHRIEKER end
        return true
    end
    local function u32(text, offset)
        if not text or #text < offset + 4 then return nil end
        local a, b, c, d = text:byte(offset + 1, offset + 4)
        return a + b * 256 + c * 65536 + d * 16777216
    end
    local function same(a, b) return a and b and api.distance(a, b) == 0 end
    local function pointer(address) return api.pointer(api.read(address, 8)) end
    local function pack_pointer(value)
        return ffi.string(ffi.new('uint8_t *[1]', value), 8)
    end
    local saved, proof_ok, scratch, scratch_size = {}, nil, nil, 0
    local status = {reason = 'enemy_filter_off', blocked = 0, restored = 0, source_swaps = 0}
    function M.status() return status end
    function M.configure(settings)
        if type(settings) ~= 'table' then return false, 'settings_not_a_table' end
        for _, key in ipairs({'block_jumpers', 'block_yellow_spewers', 'block_green_spewers', 'block_bile_spitters', 'block_scavengers', 'block_shriekers', 'block_all_small'}) do
            if settings[key] ~= nil and type(settings[key]) ~= 'boolean' then
                return false, key .. '_not_boolean'
            end
        end
        for _, key in ipairs({'block_jumpers', 'block_yellow_spewers', 'block_green_spewers', 'block_bile_spitters', 'block_scavengers', 'block_shriekers', 'block_all_small'}) do
            if settings[key] ~= nil then M[key] = settings[key] end
        end
        return true
    end
    local function finish(reason, blocked, restored, source_swaps)
        status = {reason = reason, blocked = blocked or 0, restored = restored or 0,
                  source_swaps = source_swaps or 0}
        return true, reason
    end
    local function snapshot(want_fallback)
        local mode = pointer(game + MODE)
        local mode_bytes = mode and api.read(mode, 0x44)
        local kind = u32(mode_bytes, 0x40)
        if not mode_bytes or u32(mode_bytes, 8) == 0 or not kind or kind < 1 or kind > 7 or kind == 4 then
            return nil, 'enemy_filter_waiting_for_mission'
        end
        local entity = api.pointer(mode_bytes, 0x38)
        local entity_bytes = entity and api.read(entity, 24)
        if not entity_bytes then return nil, 'enemy_filter_authority_unavailable' end
        if u32(entity_bytes, 0x14) % 2 ~= 1 then return nil, 'enemy_filter_host_only' end
        local director = pointer(game + DIRECTOR)
        local header = director and pointer(director + 0x660)
        local header_bytes = header and api.read(header, HEADER_SIZE)
        local count = u32(header_bytes, 8)
        local rows_address = header_bytes and api.pointer(header_bytes)
        if not rows_address or not count or count < 1 or count > 128 then
            return nil, 'enemy_filter_table_unavailable'
        end
        local rows = api.read(rows_address, count * STRIDE)
        if not rows then return nil, 'enemy_filter_rows_unreadable' end
        local difficulty_bytes, tags_bytes, difficulty, active_tags, tag_hashes
        if want_fallback then
            difficulty_bytes, tags_bytes = api.read(director + 0x518C4, 4), api.read(director + 0x518D4, 68)
            difficulty = u32(difficulty_bytes, 0)
            local tag_count = u32(tags_bytes, 64)
            if not difficulty or difficulty < 1 or difficulty > 10 or not tag_count or tag_count > 16 then
                return nil, 'enemy_filter_context_unavailable'
            end
            active_tags = {}
            for i = 0, tag_count - 1 do active_tags[u32(tags_bytes, i * 4)] = true end
            -- The engine initializes these hashes at runtime; disk bytes are
            -- not the mission hashes. Native indices 2/4/10 are tags 1/3/9.
            tag_hashes = api.read(game + TAG_HASHES, 128)
            local bile, pouncer, spore = u32(tag_hashes, 8), u32(tag_hashes, 16), u32(tag_hashes, 40)
            if not bile or not pouncer or not spore or bile == 0 or pouncer == 0 or spore == 0
                or bile == pouncer or bile == spore or pouncer == spore then
                return nil, 'enemy_filter_swap_context_unavailable'
            end
        end
        return {mode = mode, mode_bytes = mode_bytes, entity = entity, entity_bytes = entity_bytes,
                director = director, header = header, header_bytes = header_bytes,
                rows_address = rows_address, rows = rows, count = count,
                difficulty_bytes = difficulty_bytes, tags_bytes = tags_bytes,
                difficulty = difficulty, active_tags = active_tags, tag_hashes = tag_hashes}
    end
    local function stable(s)
        if not same(pointer(game + MODE), s.mode) or not same(pointer(game + DIRECTOR), s.director)
            or not same(pointer(s.director + 0x660), s.header) then return false end
        local current = api.read(s.mode, 0x44)
        return current and u32(current, 8) == u32(s.mode_bytes, 8)
            and u32(current, 0x40) == u32(s.mode_bytes, 0x40)
            and same(api.pointer(current, 0x38), s.entity)
            and api.read(s.entity, 24) == s.entity_bytes
            and api.read(s.header, HEADER_SIZE) == s.header_bytes
            and (not s.difficulty_bytes or api.read(s.director + 0x518C4, 4) == s.difficulty_bytes)
            and (not s.tags_bytes or api.read(s.director + 0x518D4, 68) == s.tags_bytes)
            and (not s.tag_hashes or api.read(game + TAG_HASHES, 128) == s.tag_hashes)
    end
    local function scavenger_option(s, resource)
        if not SCAVENGER_RESOURCES[resource] or s.difficulty < 2 then return nil end
        -- Native 0x949B80 chooses the highest priority; the first rule wins
        -- ties. Spore Scavengers (priority 2) beat both priority-0 swaps;
        -- Bile Spitters precede Pouncers when both tags are present.
        if s.active_tags[u32(s.tag_hashes, 40)] then return nil end
        if s.active_tags[u32(s.tag_hashes, 8)] then return 'block_bile_spitters' end
        if s.active_tags[u32(s.tag_hashes, 16)] then return 'block_jumpers' end
    end
    local function eligible(row, active_tags)
        for i = 0, 3 do
            local tag = u32(row, 0x68 + i * 4)
            if tag == 0 then break end
            if active_tags[tag] then return false end
        end
        for i = 0, 3 do
            local tag = u32(row, 0x58 + i * 4)
            if tag == 0 then break end
            if not active_tags[tag] then return false end
        end
        return true
    end
    local function warrior_resource(s)
        local best, best_weight = nil, 0
        -- Use only the two ordinary Warrior resources verified in this build.
        -- Scavengers are unsuitable: native mission swaps can turn them back
        -- into Pouncers. Warrior swaps stay in the Warrior/Hive Guard line.
        local low, high = bytes('b96be4a113e339be'), bytes('dc9c7cecc41f5432')
        for i = 0, s.count - 1 do
            local row = s.rows:sub(i * STRIDE + 1, (i + 1) * STRIDE)
            if u32(row, 0) == 2478129961 and eligible(row, s.active_tags) then
                local weight = ffi.new('float[1]')
                local offset = 0x30 + (s.difficulty - 1) * 4
                ffi.copy(weight, row:sub(offset + 1, offset + 4), 4)
                local resource = row:sub(9, 16)
                if weight[0] > best_weight and weight[0] < math.huge and (resource == low or resource == high) then
                    best, best_weight = resource, tonumber(weight[0])
                end
            end
        end
        return best
    end
    function M.update(allowed)
        local enabled = allowed ~= false and (M.block_jumpers or M.block_yellow_spewers
                                              or M.block_green_spewers or M.block_bile_spitters or M.block_scavengers
                                              or M.block_shriekers or M.block_all_small)
        if not enabled and next(saved) == nil then return finish('enemy_filter_off') end
        if proof_ok == nil then
            proof_ok = true
            for _, proof in ipairs(PROOFS) do
                local expected = bytes(proof[2])
                local current = api.read(game + proof[1], #expected)
                if not current then proof_ok = nil; return finish('enemy_filter_selector_unreadable') end
                if current ~= expected then proof_ok = false; break end
            end
        end
        if not proof_ok then return finish('enemy_filter_unsupported_selector') end
        local s, reason = snapshot(enabled)
        if not s then return finish(reason) end
        -- Baselines contain bytes, never foreign addresses. Keep them across
        -- missions if the engine reuses/copies our modified resource table.
        -- Fresh native slots replace those baselines below.
        local replacement = enabled and warrior_resource(s) or nil
        if enabled and not replacement then return finish('enemy_filter_no_valid_warrior') end
        local plans, seen = {}, {}
        for index = 0, s.count - 1 do
            local offset = index * STRIDE
            local family = u32(s.rows, offset)
            local option = FAMILIES[family]
            local scavenger = family == SCAVENGER_FAMILY
            if option or scavenger then
                local row = s.rows:sub(offset + 1, offset + STRIDE)
                -- Exclude only the owned resource hash and the existing cap
                -- scaler's +0x18 field from identity. Difficulty variants retain
                -- their distinct costs/weights/tags and restore independently.
                local row_key = row:sub(1, 8) .. row:sub(17, 24) .. row:sub(29, 128)
                if seen[row_key] then return finish('enemy_filter_ambiguous_rows') end
                seen[row_key] = true
                local resource = row:sub(9, 16)
                if resource == string.rep('\0', 8) then return finish('enemy_filter_row_layout_mismatch') end
                local baseline = saved[row_key]
                -- Resolve against the saved native resource on later ticks,
                -- including task-tag changes while our Warrior is installed.
                local original = resource
                if baseline and (resource == baseline.applied or resource == baseline.previous_applied) then
                    original = baseline.original
                end
                local source_option = enabled and scavenger and scavenger_option(s, original) or nil
                -- The direct Scavenger toggle also handles ordinary missions
                -- with no conversion tag. Retain the exact known-resource gate
                -- so another mod's custom resource in this family is preserved.
                local direct_scavenger = scavenger and selected('block_scavengers') and SCAVENGER_RESOURCES[original]
                local wanted = enabled and ((selected(option) and known_direct_resource(option, original))
                    or direct_scavenger or selected(source_option))
                local target = resource
                if wanted then
                    if not baseline then baseline = {original = resource} end
                    if resource ~= baseline.applied and resource ~= baseline.previous_applied then baseline.original = resource end
                    target = replacement
                elseif baseline and (resource == baseline.applied or resource == baseline.previous_applied) then
                    target = baseline.original
                end
                if wanted or baseline then
                    plans[#plans + 1] = {offset = offset, row_key = row_key, resource = resource, target = target,
                                         baseline = baseline, wanted = wanted,
                                         source_swap = selected(source_option)}
                end
            end
        end
        if #plans == 0 then
            if stable(s) then for row_key in pairs(saved) do if not seen[row_key] then saved[row_key] = nil end end end
            return finish(enabled and 'enemy_filter_no_matching_units' or 'enemy_filter_off')
        end
        if not stable(s) or api.read(s.rows_address, #s.rows) ~= s.rows then
            return finish('enemy_filter_waiting_for_stable_table')
        end
        local needs_write = false
        for _, plan in ipairs(plans) do if plan.resource ~= plan.target then needs_write = true end end
        -- Record every baseline before publishing a clone that contains all
        -- changes. An interrupted post-publication check must remain restorable.
        for _, plan in ipairs(plans) do
            if plan.wanted then
                if plan.baseline.applied ~= plan.target then
                    plan.baseline.previous_applied = plan.baseline.applied
                    plan.baseline.applied = plan.target
                end
                saved[plan.row_key] = plan.baseline
            end
        end
        if needs_write and not api.writable_data(s.rows_address, #s.rows) then
            if not api.writable_data(s.director + 0x660, 8) then return finish('enemy_filter_director_not_writable') end
            local size = HEADER_SIZE + #s.rows
            if not scratch or scratch_size < size then
                scratch = api.alloc_private(size)
                scratch_size = scratch and size or 0
            end
            local block = scratch
            if not block or not api.writable_data(block, size) then return finish('enemy_filter_clone_unavailable') end
            -- Copy the ENTIRE 0xB0 header, including native override metadata.
            -- Do not reuse/free blocks that the native game may still reference.
            local copied_rows = block + HEADER_SIZE
            ffi.copy(block, s.header_bytes, HEADER_SIZE)
            ffi.copy(copied_rows, s.rows, #s.rows)
            ffi.copy(block, pack_pointer(copied_rows), 8)
            -- Prepare every valid replacement before publishing the copied table.
            for _, plan in ipairs(plans) do
                ffi.copy(copied_rows + plan.offset + RESOURCE_OFFSET, plan.target, 8)
            end
            if not stable(s) or api.read(s.rows_address, #s.rows) ~= s.rows then
                return finish('enemy_filter_waiting_for_stable_table')
            end
            -- A failed/partial publish may still have exposed this allocation.
            scratch, scratch_size = nil, 0
            if not api.write(s.director + 0x660, pack_pointer(block))
                or not same(pointer(s.director + 0x660), block) then
                return finish('enemy_filter_retarget_failed')
            end
            s.header, s.rows_address = block, copied_rows
            s.header_bytes = api.read(block, HEADER_SIZE)
        end
        local blocked, restored, source_swaps = 0, 0, 0
        for _, plan in ipairs(plans) do
            local address = s.rows_address + plan.offset
            local row = api.read(address, STRIDE)
            local current_key = row and (row:sub(1, 8) .. row:sub(17, 24) .. row:sub(29, 128))
            if not stable(s) or current_key ~= plan.row_key then
                return finish('enemy_filter_waiting_for_stable_table', blocked, restored)
            end
            local current = row:sub(9, 16)
            if current ~= plan.resource and current ~= plan.target then
                return finish('enemy_filter_resource_changed', blocked, restored)
            end
            if plan.wanted then
                if plan.baseline.applied ~= plan.target then
                    plan.baseline.previous_applied = plan.baseline.applied
                    plan.baseline.applied = plan.target
                end
                saved[plan.row_key] = plan.baseline
            end
            if current ~= plan.target then
                if not api.write(address + RESOURCE_OFFSET, plan.target)
                    or api.read(address + RESOURCE_OFFSET, 8) ~= plan.target then
                    if stable(s) then api.write(address + RESOURCE_OFFSET, plan.resource) end
                    return finish('enemy_filter_write_failed', blocked, restored)
                end
            end
            if plan.wanted then
                blocked = blocked + 1
                if plan.source_swap then source_swaps = source_swaps + 1 end
            else saved[plan.row_key] = nil; restored = restored + 1 end
        end
        -- Drop vanished rows without dereferencing their old addresses.
        for row_key in pairs(saved) do if not seen[row_key] then saved[row_key] = nil end end
        return finish(blocked > 0 and 'enemy_filter_active' or 'enemy_filter_off', blocked, restored, source_swaps)
    end
    return M
end
