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
-- That table is rebuilt by the game and its layout moved
-- between 1.8.45850 and 1.8.46015, so fixed anchors are only a fast path now.
-- When every old anchor fails its identity check, the module scans the live
-- table for the complete Regular DecaySettings signature instead. This keeps the
-- feature working across table rebuilds without writing to a stale offset.
--
-- Only mode == Regular is touched. Delays are set to ~5 seconds (not 0.1):
-- that matches Faster Corpse Cleanup "normal ragdoll" / corpse-clear-5s-v1,
-- which shortens sink timing while leaving ragdoll physics alone. The original
-- pair is remembered and restored when the panel switch is turned off.
return function(api, data, decayer_data)
    local ffi = require('ffi')
    local M = {}

    local TABLE_HEADER = string.char(112, 202, 193, 128, 76, 68, 76, 68, 1, 0, 0, 0)
    local MODE_SIGNATURE = string.char(1, 0, 0, 0)
    local HEADER_PROBE = 64
    local LOW_LIMIT, HIGH_LIMIT = 0x10000, 0x800000000000
    local QUERIES_PER_PASS = 128
    local READS_PER_PASS = 16
    local PASS_INTERVAL = 0.5
    -- Keep each cross-process read bounded. The old 4 MiB chunk was large
    -- enough to monopolise a frame on a busy heap, and the completed sweep was
    -- immediately repeated forever. A 256 KiB chunk makes the work interruptible
    -- at the update cadence; the scan is now one-shot until a recheck detects a
    -- rebuilt table.
    local DYNAMIC_CHUNK = 256 * 1024
    local DYNAMIC_OVERLAP = 24
    local MAX_EMPTY_SCAN_ROUNDS = 3
    local SEED_RECHECK_SECONDS = 5.0
    local MAX_MATCHES_PER_PASS = 256
    local MAX_RECORDS = 4096

    local function cpu_now()
        if type(os) == 'table' and type(os.clock) == 'function' then
            local ok, value = pcall(os.clock)
            if ok and type(value) == 'number' then return value end
        end
        return 0
    end

    local MODE_REGULAR = 1
    -- Ragdoll-preserving profile: ~5 s before sink, not near-instant 0.1 s.
    local MIN_DELAY = 5.0
    local MAX_DELAY = 5.0
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
        scan_rounds = 0, gave_up = false,
        dynamic_candidates = 0, dynamic_applied = 0, dynamic_already = 0,
        dynamic_skipped = 0, dynamic_errors = 0, dynamic_seen = {},
        dynamic_sweeps = 0,
        dynamic_bytes = nil, dynamic_amount = 0, dynamic_chunk_base = 0,
        dynamic_mode_pos = nil, dynamic_decay_pattern = 1, dynamic_decay_pos = 1,
        total_applied = 0, total_already = 0, total_written = 0,
        mapped_headers = 0, readonly_headers = 0, base_protection = 0,
        header_probes = {},
        decayer_applied = 0, decayer_already = 0, decayer_skipped = 0,
        decayer_seen = {}, decayer_originals = {}, decayer_touched = {},
        originals = {}, touched = {}, accumulator = 0.0,
        reason = 'idle', passes = 0, mode = 'seed',
        seed_wait = 0, seed_settled = false, epoch = 0,
        dynamic_order = {}, decayer_order = {}, check_index = 1, decayer_index = 1,
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
        state.dynamic_order, state.decayer_order = {}, {}
        state.check_index, state.decayer_index = 1, 1
        state.originals, state.touched = {}, {}
        state.decayer_seen, state.decayer_originals, state.decayer_touched = {}, {}, {}
        state.seed_wait, state.seed_settled = 0, false
        state.dynamic_wait = 0
        state.dynamic_bytes, state.dynamic_amount = nil, 0
        state.dynamic_mode_pos, state.dynamic_decay_pattern = nil, 1
        state.dynamic_decay_pos = 1
    end

    -- Locate the generated-entity table. This is only the table header; the
    -- record offsets inside it are no longer trusted until each one passes the
    -- signature check in apply_record().
    local function scan_pass()
        local queries, reads = 0, 0
        local deadline = cpu_now()+0.002
        while state.cursor < HIGH_LIMIT and queries < QUERIES_PER_PASS and reads < READS_PER_PASS do
            local base, region_size, region_state, protection, region_type = api.query_region(state.cursor)
            queries = queries + 1
            if not base or not region_size or region_size <= 0 then
                -- End-of-address-space and query failures share the bounded
                -- round counter. Resetting here used to bypass that counter.
                state.cursor = HIGH_LIMIT
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
                        state.epoch = state.epoch + 1
                        state.scan_rounds = 0
                        state.dynamic_cursor, state.dynamic_done, state.dynamic_wait = 0, false, 0
                        state.dynamic_candidates, state.dynamic_applied = 0, 0
                        state.dynamic_already, state.dynamic_skipped, state.dynamic_errors = 0, 0, 0
                        state.total_applied, state.total_already, state.total_written = 0, 0, 0
                        state.decayer_applied, state.decayer_already, state.decayer_skipped = 0, 0, 0
                        state.decayer_seen = {}
                        state.dynamic_seen = {}
                        state.dynamic_bytes, state.dynamic_amount = nil, 0
                        state.dynamic_mode_pos, state.dynamic_decay_pattern = nil, 1
                        state.dynamic_decay_pos = 1
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
            if cpu_now()>=deadline then break end
        end
        if state.cursor >= HIGH_LIMIT then
            state.scan_rounds = state.scan_rounds + 1
            if state.scan_rounds >= MAX_EMPTY_SCAN_ROUNDS then
                state.gave_up = true
                state.mode = 'gave_up'
                state.reason = 'entities_scan_gave_up'
                return false
            end
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
            state.reason = 'entities_scanning'
        end
        return false
    end

    local function record_is_regular(bytes, offset, known)
        if #bytes < offset + RECORD_BYTES then return false end
        if u32(bytes, offset) ~= MODE_REGULAR then return false end
        local accel = f32(bytes, offset + 4)
        local min_delay = f32(bytes, offset + 8)
        local max_delay = f32(bytes, offset + 12)
        local unk = f32(bytes, offset + 16)
        if not (near(accel, 0.5) or near(accel, 0.2)) then return false end
        if not near_any(min_delay, {5, 7, 10, 30, 60}) then return false end
        if not near_any(max_delay, {90, 120}) and not (known and near(max_delay, MAX_DELAY)) then return false end
        if not near_any(unk, {0, 8, 10}) then return false end
        -- +0x10 is the recovered unknown float, +0x14 the bool and padding.
        -- Records are not 4-byte aligned in this table (the live layout puts
        -- them at offset % 4 == 2), so callers must search every byte offset.
        local unk_bool = bytes:byte(offset + 21)
        local pad1, pad2, pad3 = bytes:byte(offset + 22, offset + 24)
        if unk_bool == nil or unk_bool > 1 then return false end
        if pad1 ~= 0 or pad2 ~= 0 or pad3 ~= 0 then return false end
        return true
    end

    local function write_record(address, live_min, live_max, live_decay)
        local min_is_target, max_is_target = near(live_min, MIN_DELAY), near(live_max, MAX_DELAY)
        if not min_is_target and not near(live_min, 5) and not near(live_min, 7)
            and not near(live_min, 10) and not near(live_min, 30) and not near(live_min, 60) then
            return 'min_unexpected'
        end
        if not max_is_target and not near(live_max, 90) and not near(live_max, 120) then
            return 'max_unexpected'
        end
        if min_is_target and max_is_target and near(live_decay, DECAY_FLOAT) then return 'already' end
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
        local current = live_decay
        if current then
            if not near(current, DECAY_FLOAT) then
                local bytes = api.encode_f32(DECAY_FLOAT)
                local writer = api.write_decay or api.write
                if not writer(address + 16, bytes) or api.read(address + 16, 4) ~= bytes then
                    return 'decay_write_failed'
                end
            end
        end
        if min_is_target and max_is_target and near(current, DECAY_FLOAT) then
            return 'already'
        end
        return 'applied'
    end

    local function table_live()
        if not state.found or not state.base_number then return false end
        local base, size, committed, _, kind = api.query_region(state.base_number)
        return base == state.base_number and size == state.region_size
            and committed == 0x1000 and kind == 0x20000
            and api.read(state.base_number, #TABLE_HEADER) == TABLE_HEADER
    end

    local function known_record(bytes, original)
        return bytes and original and record_is_regular(bytes, 0, true)
            and near(f32(bytes, 4), original.accel)
            and bytes:sub(21, 24) == original.tail
            and (near(f32(bytes, 8), original.min) or near(f32(bytes, 8), MIN_DELAY))
            and (near(f32(bytes, 12), original.max) or near(f32(bytes, 12), MAX_DELAY))
            and (near(f32(bytes, 16), original.decay) or near(f32(bytes, 16), DECAY_FLOAT))
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
            state.originals[anchor] = {min = live_min, max = live_max, decay = raw,
                accel = live_accel, tail = bytes:sub(21,24)}
        end
        state.touched[anchor] = true
        local result = write_record(address, live_min, live_max, live_unk)
        return result
    end

    -- CorpseDecayerComponent: raise the eligibility radius so every nearby
    -- corpse enters the decay path. DeleteTheDead changed radius 1/3 -> 300.
    -- Keyed by the numeric offset inside the entity table, never by a pointer:
    -- LuaJIT cdata pointers are poor table keys, and offsets are stable.
    local function write_decayer(absolute, live_radius, expected_node)
        if near(live_radius, DECAYER_RADIUS) then return 'already' end
        if not (near(live_radius, 1.0) or near(live_radius, 3.0)) then return 'radius_unexpected' end
        local address = state.base + absolute
        local writable = api.writable_decay or api.writable_data
        if not writable(address, DECAYER_BYTES) then return 'not_writable' end
        local before = api.read(address, DECAYER_BYTES)
        if not before or not near(f32(before, 0), live_radius)
            or (expected_node and before:sub(5,8)~=expected_node) then return 'identity_changed' end
        if not state.decayer_originals[absolute] then
            state.decayer_originals[absolute] = {radius = live_radius, node = before:sub(5,8)}
        end
        state.decayer_touched[absolute] = true
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
                    result = write_decayer(anchor, live_radius, bytes:sub(5,8))
                end
            end
            note_decayer(result, anchor, bytes and f32(bytes, 0) or 0)
            if result == 'applied' then n.applied = n.applied + 1
            elseif result == 'already' then n.already = n.already + 1
            else n.skipped = n.skipped + 1 end
        end
        return n
    end

    local function apply_seed_pass()
        state.decayer_applied, state.decayer_already, state.decayer_skipped = 0, 0, 0
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

    local function apply_dynamic(absolute)
        if state.dynamic_seen[absolute] then return 'seen' end
        if #state.dynamic_order >= MAX_RECORDS then
            state.gave_up, state.mode, state.reason = true, 'gave_up', 'dynamic_record_limit'
            return 'limit'
        end
        -- The chunk is a snapshot: re-read this record immediately before writing.
        local address = state.base + absolute
        local bytes = api.read(address, RECORD_BYTES)
        local previous = state.originals[absolute]
        if not bytes or not (previous and known_record(bytes,previous) or record_is_regular(bytes,0)) then return 'changed' end
        local live_min, live_max, live_unk = f32(bytes,8), f32(bytes,12), f32(bytes,16)
        state.dynamic_seen[absolute] = true
        state.dynamic_order[#state.dynamic_order+1] = absolute
        state.dynamic_candidates = state.dynamic_candidates + 1
        if not state.originals[absolute] then
            state.originals[absolute] = {min=live_min,max=live_max,decay=live_unk,
                accel=f32(bytes,4),tail=bytes:sub(21,24)}
        end
        state.touched[absolute] = true -- also guards restore after a partial write
        local result = write_record(address,live_min,live_max,live_unk)
        if result == 'applied' then
            state.total_applied = state.total_applied + 1
        elseif result == 'already' then
            state.total_already = state.total_already + 1
        else
            state.dynamic_skipped = state.dynamic_skipped + 1
            state.skip_reasons[result] = (state.skip_reasons[result] or 0) + 1
        end
        return result
    end

    local function recheck_dynamic()
        for _ = 1, math.min(8, #state.dynamic_order) do
            local absolute = state.dynamic_order[state.check_index]
            local bytes = api.read(state.base + absolute, RECORD_BYTES)
            if not known_record(bytes, state.originals[absolute]) then return false end
            local result = write_record(state.base+absolute,f32(bytes,8),f32(bytes,12),f32(bytes,16))
            if result ~= 'already' and result ~= 'applied' then return false end
            state.check_index = state.check_index % #state.dynamic_order + 1
        end
        for _ = 1, math.min(8, #state.decayer_order) do
            local absolute = state.decayer_order[state.decayer_index]
            local bytes = api.read(state.base+absolute, DECAYER_BYTES)
            local original = state.decayer_originals[absolute]
            if not bytes or not original or bytes:sub(5,8) ~= original.node then return false end
            local result = write_decayer(absolute, f32(bytes,0),original.node)
            if result ~= 'already' and result ~= 'applied' then return false end
            state.decayer_index = state.decayer_index % #state.decayer_order + 1
        end
        return #state.dynamic_order > 0 or #state.decayer_order > 0
    end

    local function dynamic_pass()
        local deadline = cpu_now()+0.002
        if not state.base or not state.base_number or state.region_size <= 0 then
            state.reason = 'dynamic_no_region'
            return
        end
        if state.dynamic_done then
            state.reason = string.format('dynamic_complete applied=%d already=%d candidates=%d',
                                         state.total_applied, state.total_already,
                                         state.dynamic_candidates)
            return
        end
        if state.dynamic_cursor >= state.region_size then
            state.dynamic_done = true
            state.dynamic_wait = 0
            state.dynamic_sweeps = state.dynamic_sweeps + 1
            state.reason = string.format('dynamic_complete applied=%d already=%d candidates=%d',
                                         state.total_applied, state.total_already,
                                         state.dynamic_candidates)
            return
        end

        if not state.dynamic_bytes then
            -- A new sweep must see every record again; otherwise rows that were
            -- rewritten by the game after the previous pass would be skipped.
            if state.dynamic_cursor == 0 then state.dynamic_seen = {} end
            local amount = math.min(DYNAMIC_CHUNK, state.region_size - state.dynamic_cursor)
            local read_size = math.min(amount + DYNAMIC_OVERLAP,
                                       state.region_size - state.dynamic_cursor)
            local bytes = api.read(state.base_number + state.dynamic_cursor, read_size)
            if not bytes then
                state.reason = 'dynamic_unreadable'
                state.dynamic_cursor = state.dynamic_cursor + amount
                return
            end
            state.dynamic_bytes = bytes
            state.dynamic_amount = amount
            state.dynamic_chunk_base = state.dynamic_cursor
            state.dynamic_mode_pos = 1
            state.dynamic_decay_pattern = 1
            state.dynamic_decay_pos = 1
        end

        local bytes = state.dynamic_bytes
        local matches = 0
        if cpu_now()>=deadline then return end
        while state.dynamic_mode_pos do
            local hit = bytes:find(MODE_SIGNATURE, state.dynamic_mode_pos, true)
            if not hit then
                state.dynamic_mode_pos = nil
                break
            end
            local offset = hit - 1
            local absolute = state.dynamic_chunk_base+offset
            local original = state.originals[absolute]
            if record_is_regular(bytes,offset) or (original and known_record(bytes:sub(offset+1,offset+RECORD_BYTES),original)) then
                apply_dynamic(absolute)
            end
            state.dynamic_mode_pos = hit + 1
            matches = matches + 1
            if matches >= MAX_MATCHES_PER_PASS or cpu_now() >= deadline or state.gave_up then
                state.reason = 'dynamic_scan'
                return
            end
        end

        while state.dynamic_decay_pattern <= #DECAYER_PATTERNS do
            local pattern = DECAYER_PATTERNS[state.dynamic_decay_pattern]
            local hit = bytes:find(pattern, state.dynamic_decay_pos, true)
            if hit then
                local offset = hit - 1
                local absolute = state.dynamic_chunk_base + offset
                if not state.decayer_seen[absolute] then
                    if #state.decayer_order >= MAX_RECORDS then
                        state.gave_up, state.mode, state.reason = true, 'gave_up', 'dynamic_record_limit'
                        return
                    end
                    state.decayer_seen[absolute] = true
                    state.decayer_order[#state.decayer_order+1] = absolute
                    local live_radius = f32(bytes, offset)
                    if live_radius then
                        note_decayer(write_decayer(absolute, live_radius, bytes:sub(offset+5,offset+8)), absolute, live_radius)
                    end
                end
                state.dynamic_decay_pos = hit + 1
            else
                state.dynamic_decay_pattern = state.dynamic_decay_pattern + 1
                state.dynamic_decay_pos = 1
            end
            matches = matches + 1
            if matches >= MAX_MATCHES_PER_PASS or cpu_now() >= deadline or state.gave_up then
                state.reason = 'dynamic_scan'
                return
            end
        end

        state.dynamic_cursor = state.dynamic_cursor + state.dynamic_amount
        state.dynamic_bytes, state.dynamic_amount = nil, 0
        state.dynamic_mode_pos, state.dynamic_decay_pattern = nil, 1
        state.dynamic_decay_pos = 1
        if state.dynamic_cursor >= state.region_size then
            state.dynamic_done = true
            state.dynamic_wait = 0
            state.dynamic_sweeps = state.dynamic_sweeps + 1
        end
        state.reason = 'dynamic_scan'
    end

    local function apply_pass()
        if not table_live() then
            reset_scan()
            state.reason = 'entities_identity_changed'
            return
        end
        if not state.seed_dead then
            if state.seed_settled then
                state.seed_wait = state.seed_wait + PASS_INTERVAL
                if state.seed_wait < SEED_RECHECK_SECONDS then return end
                state.seed_wait = 0
            end
            local n = apply_seed_pass()
            -- Partial drift matters too: surviving anchors must not hide moved
            -- rows. Carry existing originals into the dynamic sweep.
            local decay_failed = n.skipped > 0
            local dn = n.decayer or {applied = 0, already = 0, skipped = 0}
            local decayer_present = type(decayer_data) == 'table' and #decayer_data > 0
            local decayer_failed = decayer_present
                and dn.skipped > 0
            if decay_failed or decayer_failed then
                state.seed_dead = true
                -- Keep records already changed during a partial seed pass in
                -- the rolling verification ledger; discover moved native rows.
                for absolute in pairs(state.decayer_originals) do
                    state.decayer_seen[absolute]=true
                    state.decayer_order[#state.decayer_order+1]=absolute
                end
                state.mode = 'dynamic'
            else
                state.mode = 'seed'
                state.seed_settled = true
                state.applied, state.already, state.skipped, state.mismatched =
                    n.applied, n.already, n.skipped, n.mismatched
                state.reason = string.format('applied=%d already=%d skipped=%d',
                                             n.applied, n.already, n.skipped)
                return
            end
        end
        if state.dynamic_done then
            if not recheck_dynamic() then
                reset_scan()
                state.reason = 'dynamic_identity_changed'
            end
        else
            dynamic_pass()
            if state.dynamic_done and #state.dynamic_order == 0 and #state.decayer_order == 0 then
                state.gave_up, state.mode, state.reason = true, 'gave_up', 'dynamic_no_records'
            end
        end
        -- Expose lifetime totals once the dynamic path is active. A single sweep
        -- can wrap before the next status read, so per-sweep counters alone would
        -- report applied=0 even while rows are being written every pass.
        state.applied, state.already, state.skipped = state.total_applied,
            state.total_already, state.dynamic_skipped
        state.mismatched = state.dynamic_errors
    end

    function M.update(dt)
        if not state.enabled or state.gave_up then return state.reason end
        state.accumulator = state.accumulator + ((type(dt) == 'number' and dt == dt and dt > 0) and dt or 0)
        if state.accumulator < PASS_INTERVAL then return state.reason end
        state.accumulator = 0
        state.passes = state.passes + 1
        if not state.found then scan_pass() else apply_pass() end
        return state.reason
    end

    function M.restore()
        if not table_live() then
            reset_scan()
            state.reason = 'restore_identity_changed'
            return 0
        end
        local restored = 0
        local writer = api.write_decay or api.write
        for anchor in pairs(state.touched) do
            local original = state.originals[anchor]
            local address = state.base + anchor
            local bytes = api.read(address, RECORD_BYTES)
            if known_record(bytes, original) then
                local ok = true
                for _, field in ipairs({{8, original.min, MIN_DELAY}, {12, original.max, MAX_DELAY},
                                        {16, original.decay, DECAY_FLOAT}}) do
                    if near(f32(bytes,field[1]),field[3]) then
                        local encoded = api.encode_f32(field[2])
                        ok = writer(address+field[1],encoded) and api.read(address+field[1],4)==encoded and ok
                    end
                end
                if ok then restored = restored + 1 end
            end
        end
        for absolute, original in pairs(state.decayer_originals) do
            local address = state.base+absolute
            local bytes = api.read(address, DECAYER_BYTES)
            if bytes and bytes:sub(5,8)==original.node and near(f32(bytes,0),DECAYER_RADIUS) then
                local encoded = api.encode_f32(original.radius)
                if writer(address,encoded) and api.read(address,4)==encoded then restored=restored+1 end
            end
        end
        reset_scan()
        state.applied, state.already = 0, 0
        state.decayer_applied, state.decayer_already, state.decayer_skipped = 0, 0, 0
        state.reason = 'restored=' .. restored
        return restored
    end

    function M.set_enabled(enabled)
        local wanted = enabled and true or false
        if wanted == state.enabled then return end
        state.enabled = wanted
        if wanted then
            if state.gave_up then
                state.gave_up = false
                state.scan_rounds = 0
                reset_scan()
            end
            state.reason = 'enabled'
        else
            M.restore()
        end
    end

    function M.status()
        return {
            enabled = state.enabled, located = state.found, mode = state.mode, epoch = state.epoch,
            applied = state.applied, already = state.already,
            skipped = state.skipped, mismatched = state.mismatched,
            passes = state.passes, reason = state.reason,
            dynamic_cursor = state.dynamic_cursor, dynamic_size = state.region_size,
            dynamic_candidates = state.dynamic_candidates,
            dynamic_sweeps = state.dynamic_sweeps,
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
