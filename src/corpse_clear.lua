-- Fast corpse decay: shorten HealthComponent.DecaySettings min_delay/max_delay.
--
-- Field layout (game typelib + community DecaySettings.json):
--   +0x00 mode         (DeathDecayMode: 0 None, 1 Regular, 2 Long, 3 Instant)
--   +0x04 acceleration (float)
--   +0x08 min_delay    (float) -- only meaningful in Regular mode
--   +0x0C max_delay    (float) -- only meaningful in Regular mode
--   +0x10 unk_float    (float)
--   +0x14 unk_bool     (uint8, followed by 3 padding bytes)
--
-- The original DeleteTheDead records are offsets into one build of the loaded
-- generated-entity table. That table is rebuilt by the game and its layout moved
-- between 1.8.45850 and 1.8.46015, so fixed anchors are only a fast path now.
-- When every old anchor fails its identity check, the module scans the live
-- table for the complete Regular DecaySettings signature instead. This keeps the
-- feature working across table rebuilds without writing to a stale offset.
--
-- Only mode == Regular is touched. Both delays are set to 0.1 seconds; the
-- original pair is remembered and restored when the panel switch is turned off.
return function(api, data, decayer_data)
    local ffi = require('ffi')
    local M = {}

    local TABLE_HEADER = string.char(112, 202, 193, 128, 76, 68, 76, 68, 1, 0, 0, 0)
    local MODE_SIGNATURE = string.char(1, 0, 0, 0)
    local HEADER_PROBE = 64
    local LOW_LIMIT, HIGH_LIMIT = 0x10000, 0x800000000000
    local QUERIES_PER_PASS = 512
    local READS_PER_PASS = 64
    local PASS_INTERVAL = 0.5
    local DYNAMIC_CHUNK = 4 * 1024 * 1024
    local DYNAMIC_OVERLAP = 24

    local MODE_REGULAR = 1
    local MIN_DELAY = 0.1
    local MAX_DELAY = 0.1
    local DECAY_FLOAT = 10.0
    local RECORD_BYTES = 24
    -- CorpseDecayerComponent: {float radius, uint32 node}. The radius is the
    -- distance check that decides whether a corpse is eligible to decay at all;
    -- DeleteTheDead raises it from 1/3 to 300.
    local DECAYER_BYTES = 8
    local DECAYER_RADIUS = 300.0
    local DECAYER_NODES = {}
    -- Exact {f32 radius, u32 node} byte patterns. Only a handful of distinct
    -- pairs exist, so the table walk can use string.find instead of decoding
    -- every 4-byte window.
    local DECAYER_PATTERNS = {}
    if type(decayer_data) == 'table' then
        local seen_pattern = {}
        for _, row in ipairs(decayer_data) do
            local radius, node = row[2], row[3]
            DECAYER_NODES[node] = true
            local pattern = api.encode_f32(radius) .. api.encode_u32(node)
            if not seen_pattern[pattern] then
                seen_pattern[pattern] = true
                DECAYER_PATTERNS[#DECAYER_PATTERNS + 1] = pattern
            end
        end
    end

    local state = {
        cursor = LOW_LIMIT, base = nil, base_number = nil, region_size = 0,
        found = false, enabled = true, seed_dead = false,
        applied = 0, already = 0, skipped = 0, mismatched = 0,
        dynamic_cursor = 0, dynamic_done = false, dynamic_wait = 0,
        dynamic_candidates = 0, dynamic_applied = 0, dynamic_already = 0,
        dynamic_skipped = 0, dynamic_errors = 0, dynamic_seen = {},
        total_applied = 0, total_already = 0, total_written = 0,
        mapped_headers = 0, readonly_headers = 0, base_protection = 0,
        header_probes = {},
        decayer_applied = 0, decayer_already = 0, decayer_skipped = 0,
        decayer_seen = {}, decayer_originals = {}, decayer_touched = {},
        originals = {}, touched = {}, accumulator = 0.0,
        reason = 'idle', passes = 0, mode = 'seed',
    }

    local function u32(bytes, offset)
        local a, b, c, d = bytes:byte(offset + 1, offset + 4)
        if not a then return nil end
        return a + b * 256 + c * 65536 + d * 16777216
    end

    local function f32(bytes, offset)
        if #bytes < offset + 4 then return nil end
        local v = ffi.new('float[1]')
        ffi.copy(v, bytes:sub(offset + 1, offset + 4), 4)
        return tonumber(v[0])
    end

    local function near(a, b)
        if type(a) ~= 'number' or type(b) ~= 'number' then return false end
        if a ~= a or b ~= b then return false end
        return math.abs(a - b) <= math.max(0.0005, math.abs(b) * 0.002)
    end

    local function near_any(value, values)
        for _, expected in ipairs(values) do
            if near(value, expected) then return true end
        end
        return false
    end

    local function reset_scan()
        state.cursor, state.base, state.base_number, state.region_size = LOW_LIMIT, nil, nil, 0
        state.found, state.seed_dead = false, false
        state.dynamic_cursor, state.dynamic_done, state.dynamic_wait = 0, false, 0
        state.dynamic_candidates, state.dynamic_applied = 0, 0
        state.dynamic_already, state.dynamic_skipped, state.dynamic_errors = 0, 0, 0
        state.total_applied, state.total_already, state.total_written = 0, 0, 0
        state.dynamic_seen = {}
    end

    -- Locate the generated-entity table. This is only the table header; the
    -- record offsets inside it are no longer trusted until each one passes the
    -- signature check in apply_record().
    local function scan_pass()
        local queries, reads = 0, 0
        while state.cursor < HIGH_LIMIT and queries < QUERIES_PER_PASS and reads < READS_PER_PASS do
            local base, region_size, region_state, protection, region_type = api.query_region(state.cursor)
            queries = queries + 1
            if not base or not region_size or region_size <= 0 then
                if state.cursor <= LOW_LIMIT then
                    state.cursor = HIGH_LIMIT
                else
                    reset_scan()
                end
                break
            end
            local prot = protection % 256
            local readable = prot == 2 or prot == 4 or prot == 8
                or prot == 32 or prot == 64 or prot == 128
            if region_state == 0x1000 and math.floor(protection / 256) == 0
                and readable and (region_type == 0x20000 or region_type == 0x40000)
                and region_size >= #TABLE_HEADER then
                local amount = math.min(region_size, HEADER_PROBE)
                local bytes = api.read(base, amount)
                reads = reads + 1
                if bytes and bytes:sub(1, #TABLE_HEADER) == TABLE_HEADER then
                    -- Accept the table only when the exact predicate used by the
                    -- write path agrees. The live log showed a private copy whose
                    -- page protection made every single record come back
                    -- not_writable, so a matching header alone is not enough.
                    local writable = api.writable_decay or api.writable_data
                    if region_type == 0x20000 and writable(base, RECORD_BYTES) then
                        local live_base, live_size = api.query_region(base)
                        state.base, state.base_number = api.cast_uint8(base), base
                        state.region_size, state.found = live_size or region_size, true
                        state.base_protection = prot
                        state.dynamic_cursor, state.dynamic_done, state.dynamic_wait = 0, false, 0
                        state.dynamic_candidates, state.dynamic_applied = 0, 0
                        state.dynamic_already, state.dynamic_skipped, state.dynamic_errors = 0, 0, 0
                        state.total_applied, state.total_already, state.total_written = 0, 0, 0
                        state.decayer_applied, state.decayer_already, state.decayer_skipped = 0, 0, 0
                        state.decayer_seen = {}
                        state.dynamic_seen = {}
                        state.skip_reasons = {}
                        state.reason = string.format('entities_located_private_prot=%#x', prot)
                        return true
                    end
                    if region_type == 0x20000 then
                        -- A private copy that is not writable (for example a
                        -- read-only decrypted snapshot). Keep looking for the
                        -- writable heap copy the game actually mutates.
                        state.readonly_headers = state.readonly_headers + 1
                        state.reason = string.format('skip_readonly_private:%#x prot=%#x', base, prot)
                    else
                        -- MEM_MAPPED (0x40000): the read-only file image. Its
                        -- bytes match the header and every DecaySettings
                        -- signature, but writes are refused.
                        state.mapped_headers = state.mapped_headers + 1
                        state.reason = string.format('skip_mapped:%#x', base)
                    end
                    -- Keep a short ledger of what was seen so the next live log
                    -- states the real type/protection instead of guessing.
                    if #state.header_probes < 8 then
                        state.header_probes[#state.header_probes + 1] =
                            string.format('%#x/t%#x/p%#x', base, region_type, protection)
                    end
                end
            end
            local advance = base + region_size
            if advance <= state.cursor then advance = state.cursor + 0x1000 end
            state.cursor = advance
        end
        if state.cursor >= HIGH_LIMIT then
            reset_scan()
            if state.readonly_headers > 0 and state.mapped_headers > 0 then
                state.reason = string.format(
                    'no_writable_entities mapped=%d readonly_private=%d',
                    state.mapped_headers, state.readonly_headers)
            elseif state.readonly_headers > 0 then
                state.reason = string.format('no_writable_entities readonly_private=%d',
                                             state.readonly_headers)
            elseif state.mapped_headers > 0 then
                state.reason = string.format('no_writable_entities mapped=%d',
                                             state.mapped_headers)
            else
                state.reason = 'scan_wrapped'
            end
        else
            state.reason = string.format('scanning:%#x', state.cursor)
        end
        return false
    end

    local function record_is_regular(bytes, offset)
        if #bytes < offset + RECORD_BYTES then return false end
        if u32(bytes, offset) ~= MODE_REGULAR then return false end
        local accel = f32(bytes, offset + 4)
        local min_delay = f32(bytes, offset + 8)
        local max_delay = f32(bytes, offset + 12)
        local unk = f32(bytes, offset + 16)
        if not (near(accel, 0.5) or near(accel, 0.2)) then return false end
        if not near_any(min_delay, {5, 7, 10, 30, 60}) then return false end
        if not near_any(max_delay, {90, 120}) then return false end
        if not near_any(unk, {0, 8, 10}) then return false end
        -- +0x14 is unk_float, +0x18 is unk_bool, then 3 padding bytes.
        -- Records are not 4-byte aligned in this table (the live layout puts
        -- them at offset % 4 == 2), so callers must search every byte offset.
        local unk_bool = bytes:byte(offset + 21)
        local pad1, pad2, pad3 = bytes:byte(offset + 22, offset + 24)
        if unk_bool == nil or unk_bool > 1 then return false end
        if pad1 ~= 0 or pad2 ~= 0 or pad3 ~= 0 then return false end
        return true
    end

    local function write_record(address, live_min, live_max)
        local min_is_target, max_is_target = near(live_min, MIN_DELAY), near(live_max, MAX_DELAY)
        if not min_is_target and not near(live_min, 5) and not near(live_min, 7)
            and not near(live_min, 10) and not near(live_min, 30) and not near(live_min, 60) then
            return 'min_unexpected'
        end
        if not max_is_target and not near(live_max, 90) and not near(live_max, 120) then
            return 'max_unexpected'
        end
        local writable = api.writable_decay or api.writable_data
        if not writable(address, RECORD_BYTES) then return 'not_writable' end
        if not min_is_target then
            local bytes = api.encode_f32(MIN_DELAY)
            local writer = api.write_decay or api.write
            if not writer(address + 8, bytes) or api.read(address + 8, 4) ~= bytes then
                return 'min_write_failed'
            end
        end
        if not max_is_target then
            local bytes = api.encode_f32(MAX_DELAY)
            local writer = api.write_decay or api.write
            if not writer(address + 12, bytes) or api.read(address + 12, 4) ~= bytes then
                return 'max_write_failed'
            end
        end
        -- DeleteTheDead wrote +0x10 (unknown float) to 10 for every corpse record.
        -- The field name is not authoritative but the original mod clearly treated
        -- it as part of the decay timing; set it to the same fast value as the
        -- delays so the visible disappearance is not gated by it.
        local decay = api.read(address + 16, 4)
        if decay then
            local current = f32(decay, 0)
            if not near(current, DECAY_FLOAT) then
                local bytes = api.encode_f32(DECAY_FLOAT)
                local writer = api.write_decay or api.write
                if not writer(address + 16, bytes) or api.read(address + 16, 4) ~= bytes then
                    return 'decay_write_failed'
                end
            end
        end
        if min_is_target and max_is_target and decay and near(f32(decay, 0), DECAY_FLOAT) then
            return 'already'
        end
        return 'applied'
    end

    local function apply_record(row)
        local anchor, accel, min_delay, max_delay, unk = row[1], row[2], row[3], row[4], row[5]
        local address = state.base + anchor
        local bytes = api.read(address, RECORD_BYTES)
        if not bytes then return 'unreadable' end
        if u32(bytes, 0) ~= MODE_REGULAR then return 'not_regular' end
        local live_accel, live_min, live_max, live_unk =
            f32(bytes, 4), f32(bytes, 8), f32(bytes, 12), f32(bytes, 16)
        -- +0x10 is part of the record identity in the recovered table. Once the
        -- feature has written it, the live value is DECAY_FLOAT instead of the
        -- recorded 0/8, so accept either state rather than treating our own
        -- write as a layout mismatch.
        if not (near(live_accel, accel)
                and (near(live_unk, unk) or near(live_unk, DECAY_FLOAT))) then
            return 'identity_mismatch'
        end
        if not near(live_min, min_delay) and not near(live_min, MIN_DELAY) then return 'min_unexpected' end
        if not near(live_max, max_delay) and not near(live_max, MAX_DELAY) then return 'max_unexpected' end
        if not state.originals[anchor] then
            local raw = f32(bytes, 16)
            state.originals[anchor] = {min = live_min, max = live_max, decay = raw}
        end
        local result = write_record(address, live_min, live_max)
        if result == 'applied' then state.touched[anchor] = true end
        return result
    end

    -- CorpseDecayerComponent: raise the eligibility radius so every nearby
    -- corpse enters the decay path. DeleteTheDead changed radius 1/3 -> 300.
    -- Keyed by the numeric offset inside the entity table, never by a pointer:
    -- LuaJIT cdata pointers are poor table keys, and offsets are stable.
    local function write_decayer(absolute, live_radius)
        if near(live_radius, DECAYER_RADIUS) then return 'already' end
        if not (near(live_radius, 1.0) or near(live_radius, 3.0)) then return 'radius_unexpected' end
        local address = state.base + absolute
        local writable = api.writable_decay or api.writable_data
        if not writable(address, DECAYER_BYTES) then return 'not_writable' end
        local writer = api.write_decay or api.write
        local bytes = api.encode_f32(DECAYER_RADIUS)
        if not writer(address, bytes) or api.read(address, 4) ~= bytes then
            return 'radius_write_failed'
        end
        return 'applied'
    end

    local function note_decayer(result, absolute, live_radius)
        if result == 'applied' then
            state.decayer_applied = state.decayer_applied + 1
            if not state.decayer_originals[absolute] then
                state.decayer_originals[absolute] = live_radius
            end
            state.decayer_touched[absolute] = true
        elseif result == 'already' then
            state.decayer_already = state.decayer_already + 1
        else
            state.decayer_skipped = state.decayer_skipped + 1
            state.skip_reasons = state.skip_reasons or {}
            state.skip_reasons['decayer_' .. tostring(result)] =
                (state.skip_reasons['decayer_' .. tostring(result)] or 0) + 1
        end
    end

    -- Fixed-anchor pass for CorpseDecayerComponent rows.
    local function apply_decayer_seed()
        local n = {applied = 0, already = 0, skipped = 0}
        if type(decayer_data) ~= 'table' then return n end
        for _, row in ipairs(decayer_data) do
            local anchor, _, node = row[1], row[2], row[3]
            local bytes = api.read(state.base + anchor, DECAYER_BYTES)
            local result = 'unreadable'
            if bytes then
                local live_radius = f32(bytes, 0)
                if u32(bytes, 4) == node and live_radius then
                    result = write_decayer(anchor, live_radius)
                end
            end
            note_decayer(result, anchor, bytes and f32(bytes, 0) or 0)
            if result == 'applied' then n.applied = n.applied + 1
            elseif result == 'already' then n.already = n.already + 1
            else n.skipped = n.skipped + 1 end
        end
        return n
    end

    -- Signature pass: find every {radius, node} pair in the accepted table. This
    -- makes the feature survive table rebuilds, exactly like the DecaySettings
    -- scan above.
    local function apply_decayer_dynamic(chunk_bytes, chunk_base)
        if #DECAYER_PATTERNS == 0 then return end
        for _, pattern in ipairs(DECAYER_PATTERNS) do
            local pos = 1
            while true do
                local hit = chunk_bytes:find(pattern, pos, true)
                if not hit then break end
                local offset = hit - 1
                local absolute = chunk_base + offset
                if not state.decayer_seen[absolute] then
                    state.decayer_seen[absolute] = true
                    local live_radius = f32(chunk_bytes, offset)
                    if live_radius then
                        note_decayer(write_decayer(absolute, live_radius), absolute, live_radius)
                    end
                end
                pos = hit + 1
            end
        end
    end

    local function apply_seed_pass()
        local dn = apply_decayer_seed()
        local n = {applied = 0, already = 0, skipped = 0, mismatched = 0,
                   decayer = dn}
        for _, row in ipairs(data) do
            local why = apply_record(row)
            if why == 'applied' then n.applied = n.applied + 1
            elseif why == 'already' then n.already = n.already + 1
            else
                n.skipped = n.skipped + 1
                if why == 'identity_mismatch' or why == 'not_regular' then
                    n.mismatched = n.mismatched + 1
                end
            end
        end
        return n
    end

    local function apply_dynamic(absolute, live_min, live_max)
        if state.dynamic_seen[absolute] then return 'seen' end
        state.dynamic_seen[absolute] = true
        state.dynamic_candidates = state.dynamic_candidates + 1
        local address = state.base + absolute
        if not state.originals[absolute] then
            local raw = api.read(address + 16, 4)
            state.originals[absolute] = {min = live_min, max = live_max,
                                         decay = raw and f32(raw, 0) or 0}
        end
        local result = write_record(address, live_min, live_max)
        if result == 'applied' then
            state.touched[absolute] = true
            state.dynamic_applied = state.dynamic_applied + 1
            state.total_applied = state.total_applied + 1
            state.total_written = state.total_written + 1
        elseif result == 'already' then
            state.total_already = state.total_already + 1
            state.dynamic_already = state.dynamic_already + 1
        else
            state.dynamic_skipped = state.dynamic_skipped + 1
            -- Record the exact refusal reason; without it the live log only shows
            -- applied=0 and cannot distinguish a layout problem from a write
            -- permission problem.
            state.skip_reasons = state.skip_reasons or {}
            state.skip_reasons[result] = (state.skip_reasons[result] or 0) + 1
            if result == 'min_unexpected' or result == 'max_unexpected' or result == 'not_writable' then
                state.dynamic_errors = state.dynamic_errors + 1
            end
        end
        return result
    end

    local function dynamic_pass()
        if not state.base or not state.base_number or state.region_size <= 0 then
            state.reason = 'dynamic_no_region'
            return
        end
        if state.dynamic_cursor >= state.region_size then
            -- Do not stop after the first sweep: the table can be rebuilt, and a
            -- row can be allocated later. Restart immediately from the top.
            state.dynamic_cursor, state.dynamic_done, state.dynamic_wait = 0, false, 0
            state.dynamic_seen = {}
            state.reason = string.format('dynamic_wrap total_applied=%d total_already=%d candidates=%d',
                                         state.total_applied, state.total_already,
                                         state.dynamic_candidates)
            return
        end

        -- A new sweep must see every record again; otherwise rows that were
        -- rewritten by the game after the previous pass would be skipped.
        if state.dynamic_cursor == 0 then state.dynamic_seen = {} end
        local amount = math.min(DYNAMIC_CHUNK, state.region_size - state.dynamic_cursor)
        local read_size = math.min(amount + DYNAMIC_OVERLAP, state.region_size - state.dynamic_cursor)
        local bytes = api.read(state.base_number + state.dynamic_cursor, read_size)
        if not bytes then
            state.reason = 'dynamic_unreadable'
            state.dynamic_cursor = state.dynamic_cursor + amount
            return
        end

        local pos = 1
        while true do
            local hit = bytes:find(MODE_SIGNATURE, pos, true)
            if not hit then break end
            local offset = hit - 1
            if record_is_regular(bytes, offset) then
                local absolute = state.dynamic_cursor + offset
                local live_min, live_max = f32(bytes, offset + 8), f32(bytes, offset + 12)
                apply_dynamic(absolute, live_min, live_max)
            end
            pos = hit + 1
        end
        apply_decayer_dynamic(bytes, state.dynamic_cursor)
        state.dynamic_cursor = state.dynamic_cursor + amount
        state.reason = string.format('dynamic_scan %#x/%#x applied=%d already=%d skipped=%d',
                                     state.dynamic_cursor, state.region_size,
                                     state.dynamic_applied, state.dynamic_already,
                                     state.dynamic_skipped)
    end

    local function apply_pass()
        if not state.seed_dead then
            local n = apply_seed_pass()
            -- The fixed anchors may fail for several reasons (identity mismatch,
            -- unexpected min/max, unreadable). Each table is judged separately:
            -- either one failing means the old layout is unusable and the
            -- signature scanner must take over for both.
            local decay_failed = (n.applied + n.already == 0 and n.skipped == #data)
            local dn = n.decayer or {applied = 0, already = 0, skipped = 0}
            local decayer_present = type(decayer_data) == 'table' and #decayer_data > 0
            local decayer_failed = decayer_present
                and (dn.applied + dn.already == 0 and dn.skipped == #decayer_data)
            if decay_failed or decayer_failed then
                state.seed_dead = true
                state.mode = 'dynamic'
            else
                state.mode = 'seed'
                state.applied, state.already, state.skipped, state.mismatched =
                    n.applied, n.already, n.skipped, n.mismatched
                state.reason = string.format('applied=%d already=%d skipped=%d',
                                             n.applied, n.already, n.skipped)
                return
            end
        end
        dynamic_pass()
        -- Expose lifetime totals once the dynamic path is active. A single sweep
        -- can wrap before the next status read, so per-sweep counters alone would
        -- report applied=0 even while rows are being written every pass.
        state.applied, state.already, state.skipped = state.total_applied,
            state.total_already, state.dynamic_skipped
        state.mismatched = state.dynamic_errors
    end

    function M.update(dt)
        if not state.enabled then return state.reason end
        state.accumulator = state.accumulator + ((type(dt) == 'number' and dt == dt and dt > 0) and dt or 0)
        if state.accumulator < PASS_INTERVAL then return state.reason end
        state.accumulator = 0
        state.passes = state.passes + 1
        if not state.found then scan_pass() else apply_pass() end
        return state.reason
    end

    function M.restore()
        if not (state.found and state.base) then return 0 end
        local restored = 0
        for anchor in pairs(state.touched) do
            local original = state.originals[anchor]
            local address = state.base + anchor
            local writable = api.writable_decay or api.writable_data
            if original and writable(address, RECORD_BYTES) then
                local writer = api.write_decay or api.write
                local ok = writer(address + 8, api.encode_f32(original.min))
                    and writer(address + 12, api.encode_f32(original.max))
                if original.decay then
                    ok = ok and writer(address + 16, api.encode_f32(original.decay))
                end
                if ok then restored = restored + 1 end
            end
        end
        for absolute, original_radius in pairs(state.decayer_originals) do
            local address = state.base + absolute
            local writer = api.write_decay or api.write
            local bytes = api.encode_f32(original_radius)
            if writer(address, bytes) and api.read(address, 4) == bytes then
                restored = restored + 1
            end
        end
        state.touched, state.applied, state.already = {}, 0, 0
        state.decayer_touched, state.decayer_originals = {}, {}
        state.decayer_applied, state.decayer_already, state.decayer_skipped = 0, 0, 0
        state.reason = 'restored=' .. restored
        return restored
    end

    function M.set_enabled(enabled)
        local wanted = enabled and true or false
        if wanted == state.enabled then return end
        state.enabled = wanted
        if wanted then
            state.reason = 'enabled'
        else
            M.restore()
        end
    end

    function M.status()
        return {
            enabled = state.enabled, located = state.found, mode = state.mode,
            applied = state.applied, already = state.already,
            skipped = state.skipped, mismatched = state.mismatched,
            passes = state.passes, reason = state.reason,
            dynamic_cursor = state.dynamic_cursor, dynamic_size = state.region_size,
            dynamic_candidates = state.dynamic_candidates,
            mapped_headers = state.mapped_headers,
            readonly_headers = state.readonly_headers,
            base_protection = state.base_protection,
            header_probes = state.header_probes,
            skip_reasons = state.skip_reasons,
            decayer_applied = state.decayer_applied,
            decayer_already = state.decayer_already,
            decayer_skipped = state.decayer_skipped,
            decay_api = api.decay_status and api.decay_status() or nil,
        }
    end

    return M
end
