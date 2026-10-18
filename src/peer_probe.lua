-- Read-only squad peer-count probe.
--
-- Counts players in the local network session (host alone => 1). Offsets are
-- keyed by game.dll PE TimeDateStamp + SizeOfImage, matching sos_probe. Unknown
-- builds report count=nil so the loader treats the lobby as non-solo.

return function()
    local BUILDS = {
        {
            stamp = 1790161983,
            image = 74727424,
            ctx_off = 0x347CEF0,
            peer_count_at = 0x16390,
            max_peers = 4,
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

    local function create(api)
        local session = {
            build = 'pending',
            stamp = nil,
            image = nil,
            layout = nil,
            count = nil,
            solo = false,
            last_detail = nil,
            fail_streak = 0,
        }

        function session.probe(game)
            if session.build == 'mismatch' or session.build == 'error' then
                session.count, session.solo = nil, false
                return nil, session.last_detail
            end

            if session.build == 'pending' then
                local stamp, image, err = read_pe(api, game)
                session.stamp, session.image = stamp, image
                if not stamp or not image then
                    session.fail_streak = (session.fail_streak or 0) + 1
                    session.last_detail = string.format(
                        'build=pending pe=%s fail_streak=%d',
                        tostring(err or '?'), session.fail_streak)
                    if session.fail_streak >= 3 then
                        session.build = 'error'
                        session.count, session.solo = nil, false
                        session.last_detail = session.last_detail .. ' fail_closed=1'
                    end
                    return nil, session.last_detail
                end
                local layout = find_build(stamp, image)
                if not layout then
                    session.build = 'mismatch'
                    session.layout = nil
                    session.count, session.solo = nil, false
                    session.last_detail = string.format(
                        'build=mismatch actual_stamp=%d actual_image=%d',
                        stamp, image)
                    return nil, session.last_detail
                end
                session.build = 'ok'
                session.layout = layout
                session.fail_streak = 0
            end

            if session.build ~= 'ok' or not session.layout then
                session.count, session.solo = nil, false
                return nil, session.last_detail
            end

            local layout = session.layout
            local ctx = api.pointer(api.read(game + layout.ctx_off, 8))
            if not ctx then
                session.count, session.solo = nil, false
                session.last_detail = 'build=ok event=no_ctx'
                return nil, session.last_detail
            end
            local raw = api.read(ctx + layout.peer_count_at, 4)
            local count = u32(raw, 0)
            if count == nil or count < 1 or count > layout.max_peers then
                session.count, session.solo = nil, false
                session.last_detail = string.format(
                    'build=ok event=bad_count raw=%s', tostring(count))
                return nil, session.last_detail
            end
            session.count = count
            session.solo = count == 1
            session.last_detail = string.format(
                'build=ok event=ok count=%d solo=%s', count, tostring(session.solo))
            return count, session.last_detail
        end

        return session
    end

    return {
        BUILDS = BUILDS,
        find_build = find_build,
        create = create,
    }
end
