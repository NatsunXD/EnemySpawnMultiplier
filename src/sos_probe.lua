-- Read-only SOS beacon usage probe.
--
-- Detects when the local host has spent the SOS stratagem (lobby becomes
-- publicly joinable for the rest of the mission). Never writes memory and never
-- removes the stratagem from the wheel.
--
-- Offsets are keyed by game.dll PE TimeDateStamp + SizeOfImage. Unknown builds
-- report unsupported so the loader can fail closed until the table is updated.

return function()
    local SOS_ID = 3193487269
    -- Stratagem definition IDs that must never be treated as SOS (from SOS Beacon
    -- Offline's deny list). Kept so a wrong def_index cannot false-positive.
    local DENY = {
        [863373678] = true,
        [2266266587] = true,
        [867876502] = true,
    }
    -- Known-good layouts. Add a row after each game update using bb_sos logs
    -- (actual_stamp / actual_image).
    local BUILDS = {
        {
            stamp = 1790161983,
            image = 74727424,
            def_root = 0x37CB600,
            id_at = 4,
            def_max = 160,
            arr_off = 0x347CE50,
            rec_stride = 0x1690,
            rec_max = 32,
            arr_cnt_at = 0x2D200,
            peer_ctx = 0x347CEF0,
            peer_at = 0xB398,
            slot_at = 0x1C0,
            slot_stride = 0x30,
            slot_max = 32,
            slot_cnt_at = 0x7C0,
            uses_at = 4,
        },
    }

    local function u32(bytes, offset)
        if type(bytes) ~= 'string' or offset < 0 or offset + 4 > #bytes then
            return nil
        end
        local a, b, c, d = bytes:byte(offset + 1, offset + 4)
        if d == nil then return nil end
        return a + b * 256 + c * 65536 + d * 16777216
    end

    local function i32_uses(raw)
        if raw == nil then return nil end
        if raw >= 2147483648 then
            return raw - 4294967296
        end
        return raw
    end

    local function find_build(stamp, image)
        for index = 1, #BUILDS do
            local row = BUILDS[index]
            if row.stamp == stamp and row.image == image then
                return row
            end
        end
        return nil
    end

    local function read_pe(api, game)
        local dos = api.read(game, 64)
        if not dos or dos:sub(1, 2) ~= 'MZ' then
            return nil, nil, 'no_mz'
        end
        local lfanew = u32(dos, 0x3C)
        if not lfanew or lfanew < 64 or lfanew > 1048576 then
            return nil, nil, 'bad_lfanew'
        end
        local pe = api.read(game + lfanew, 0x58)
        if not pe or pe:sub(1, 4) ~= 'PE\0\0' then
            return nil, nil, 'no_pe'
        end
        return u32(pe, 8), u32(pe, 0x50), nil
    end

    -- Pure decision helper (unit-tested without game memory).
    -- sample fields: build ('ok'|'mismatch'|'pending'|'error'),
    --   sos_present, uses, live, read_ok, fail_streak, max_fail
    local function interpret(sample)
        sample = type(sample) == 'table' and sample or {}
        if sample.build == 'mismatch' then
            return {
                gate = true,
                sticky = false,
                unsupported = true,
                reason = 'sos_probe_build_mismatch',
                event = 'build_mismatch',
            }
        end
        if sample.build ~= 'ok' then
            return {
                gate = false,
                sticky = false,
                unsupported = false,
                reason = nil,
                event = 'build_' .. tostring(sample.build or 'pending'),
            }
        end
        if sample.read_ok == false then
            local streak = (tonumber(sample.fail_streak) or 0) + 1
            local max_fail = tonumber(sample.max_fail) or 3
            if sample.live and streak >= max_fail then
                return {
                    gate = true,
                    sticky = false,
                    unsupported = true,
                    reason = 'sos_probe_unreliable',
                    event = 'read_fail_closed',
                    fail_streak = streak,
                }
            end
            return {
                gate = false,
                sticky = false,
                unsupported = false,
                reason = nil,
                event = 'read_fail',
                fail_streak = streak,
            }
        end
        if not sample.live then
            return {
                gate = false,
                sticky = false,
                unsupported = false,
                reason = nil,
                event = 'ship',
                fail_streak = 0,
                sos_present = sample.sos_present == true,
                uses = sample.uses,
            }
        end
        if sample.sos_present == true then
            local uses = sample.uses
            if uses == nil then
                return {
                    gate = false,
                    sticky = false,
                    unsupported = false,
                    reason = nil,
                    event = 'uses_missing',
                    fail_streak = 0,
                }
            end
            if uses == 0 then
                return {
                    gate = true,
                    sticky = true,
                    unsupported = false,
                    reason = 'privacy_gate_sos',
                    event = 'sos_spent',
                    fail_streak = 0,
                    sos_present = true,
                    uses = 0,
                }
            end
            return {
                gate = false,
                sticky = false,
                unsupported = false,
                reason = nil,
                event = 'sos_available',
                fail_streak = 0,
                sos_present = true,
                uses = uses,
            }
        end
        return {
            gate = false,
            sticky = false,
            unsupported = false,
            reason = nil,
            event = 'sos_absent',
            fail_streak = 0,
            sos_present = false,
        }
    end

    local function def_id(api, game, layout, index)
        if type(index) ~= 'number' or index < 1 or index > layout.def_max then
            return nil
        end
        local obj = api.pointer(api.read(game + layout.def_root + index * 8, 8))
        if not obj then return nil end
        return u32(api.read(obj + layout.id_at, 4), 0)
    end

    local function local_record(api, game, layout)
        local arr = api.pointer(api.read(game + layout.arr_off, 8))
        local ctx = api.pointer(api.read(game + layout.peer_ctx, 8))
        if not arr or not ctx then return nil end
        local peer = api.read(ctx + layout.peer_at, 8)
        if not peer then return nil end
        local count = u32(api.read(arr + layout.arr_cnt_at, 4), 0)
        if not count or count < 1 or count > layout.rec_max then
            count = layout.rec_max
        end
        for index = 0, count - 1 do
            local rec = arr + index * layout.rec_stride
            local head = api.read(rec, 8)
            if head == peer then
                return rec
            end
        end
        return nil
    end

    local function read_sos_slot(api, game, layout)
        local rec = local_record(api, game, layout)
        if not rec then
            return { read_ok = false, why = 'no_record' }
        end
        local count = u32(api.read(rec + layout.slot_cnt_at, 4), 0)
        if count == nil or count > layout.slot_max then
            return { read_ok = false, why = 'bad_count' }
        end
        for index = 0, count - 1 do
            local base = rec + layout.slot_at + index * layout.slot_stride
            local raw = api.read(base, layout.slot_stride)
            if not raw or #raw ~= layout.slot_stride then
                return { read_ok = false, why = 'bad_slot' }
            end
            local def_index = u32(raw, 0)
            local id = nil
            if def_index and def_index ~= 0 then
                id = def_id(api, game, layout, def_index)
            end
            if id == SOS_ID and not DENY[id] then
                local uses = i32_uses(u32(raw, layout.uses_at))
                return {
                    read_ok = true,
                    sos_present = true,
                    uses = uses,
                    slot = index,
                    def_index = def_index,
                }
            end
        end
        return { read_ok = true, sos_present = false, uses = nil, slot_count = count }
    end

    local function create(api)
        local session = {
            build = 'pending',
            stamp = nil,
            image = nil,
            layout = nil,
            sticky = false,
            unsupported = false,
            fail_streak = 0,
            last_event = nil,
            last_detail = nil,
            sos_present = nil,
            uses = nil,
        }

        function session.reset_latch()
            session.sticky = false
            session.fail_streak = 0
            session.sos_present = nil
            session.uses = nil
            -- unsupported / build identity survive until process exit.
        end

        function session.probe(game, opts)
            opts = type(opts) == 'table' and opts or {}
            local live = opts.live == true
            if session.unsupported then
                return true, session.unsupported and (
                    session.build == 'mismatch' and 'sos_probe_build_mismatch'
                        or 'sos_probe_unreliable'), session.last_detail
            end
            if session.sticky then
                return true, 'privacy_gate_sos', session.last_detail
            end

            if session.build == 'pending' or opts.refresh_build then
                local stamp, image, err = read_pe(api, game)
                session.stamp, session.image = stamp, image
                if not stamp or not image then
                    session.fail_streak = (session.fail_streak or 0) + 1
                    session.last_event = 'pe_' .. tostring(err or 'error')
                    session.last_detail = string.format(
                        'build=pending pe=%s fail_streak=%d',
                        tostring(err or '?'), session.fail_streak)
                    if session.fail_streak >= 3 then
                        session.build = 'error'
                        session.unsupported = true
                        session.last_event = 'pe_fail_closed'
                        return true, 'sos_probe_unreliable', session.last_detail
                    end
                    -- Keep pending so the loader retries on the next interval.
                    session.build = 'pending'
                    return false, nil, session.last_detail
                end
                session.fail_streak = 0
                local layout = find_build(stamp, image)
                if not layout then
                    session.build = 'mismatch'
                    session.unsupported = true
                    session.layout = nil
                    session.last_event = 'build_mismatch'
                    session.last_detail = string.format(
                        'build=mismatch actual_stamp=%d actual_image=%d',
                        stamp, image)
                    return true, 'sos_probe_build_mismatch', session.last_detail
                end
                session.build = 'ok'
                session.layout = layout
                session.last_event = 'build_ok'
                session.last_detail = string.format(
                    'build=ok stamp=%d image=%d', stamp, image)
                -- Fall through to a slot read when live; on ship, build check alone
                -- is enough for this tick.
                if not live then
                    return false, nil, session.last_detail
                end
            end

            if session.build ~= 'ok' or not session.layout then
                return false, nil, session.last_detail
            end

            local slot = read_sos_slot(api, game, session.layout)
            local decision = interpret({
                build = 'ok',
                live = live,
                read_ok = slot.read_ok == true,
                sos_present = slot.sos_present == true,
                uses = slot.uses,
                fail_streak = session.fail_streak,
                max_fail = 3,
            })
            session.fail_streak = decision.fail_streak or 0
            if decision.sos_present ~= nil then
                session.sos_present = decision.sos_present
            end
            if decision.uses ~= nil then
                session.uses = decision.uses
            elseif slot.uses ~= nil then
                session.uses = slot.uses
            end
            if decision.unsupported then
                session.unsupported = true
            end
            if decision.sticky then
                session.sticky = true
            end
            session.last_event = decision.event
            session.last_detail = string.format(
                'build=%s event=%s live=%s present=%s uses=%s slot=%s why=%s sticky=%s unsupported=%s',
                tostring(session.build), tostring(decision.event), tostring(live),
                tostring(slot.sos_present), tostring(slot.uses), tostring(slot.slot),
                tostring(slot.why or '-'), tostring(session.sticky),
                tostring(session.unsupported))
            if decision.gate then
                return true, decision.reason, session.last_detail
            end
            return false, nil, session.last_detail
        end

        return session
    end

    return {
        SOS_ID = SOS_ID,
        BUILDS = BUILDS,
        interpret = interpret,
        find_build = find_build,
        create = create,
    }
end
