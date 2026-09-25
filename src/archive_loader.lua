return function(create_api, patch, build, create_panel, create_model, create_bindings, create_anchors,
                create_store, create_diag)
    if _G.EnemySpawnMultiplier then return end
    local state = {revision = build.revision, active = false, status = '', detail = '', elapsed = 1.0}
    _G.EnemySpawnMultiplier = state
    local LOG_LIMIT = 4 * 1024 * 1024
    -- Light blackbox: always on. Samples updater cost and suspicious transitions;
    -- never changes spawn behaviour.
    local PERF_SINGLE_MS = 5.0
    local PERF_WINDOW_MS = 30.0
    local blackbox = {
        last_status = nil,
        last_clone_event = 'none',
        window_start = 0,
        window_ms = 0,
        window_calls = 0,
        last_upd_ms = 0,
        alerts = 0,
    }

    local function log_line(status, detail)
        -- Callers may omit the detail. It is concatenated below, so normalise it
        -- here rather than letting a nil raise inside the panel's mouse handler,
        -- where the fault would propagate into the updater hook.
        status, detail = tostring(status or ''), tostring(detail or '')
        local directory = os.getenv('LOCALAPPDATA')
        if not directory then return end
        local path = directory .. '/EnemySpawnMultiplier.log'
        local file = io.open(path, 'a')
        if not file then return end
        local size = file:seek('end') or 0
        if size > LOG_LIMIT then
            file:close()
            os.remove(path .. '.1')
            os.rename(path, path .. '.1')
            file = io.open(path, 'a')
            if not file then return end
            file:write(build.revision .. '\n')
        elseif size == 0 then
            file:write(build.revision .. '\n')
        end
        local stamp = type(os.date) == 'function' and os.date('%H:%M:%S') or 't'
        file:write(stamp .. ' ' .. status .. ' ' .. detail .. '\n')
        file:close()
    end
    -- Exposed for diagnostics and so the writer's own contract can be tested
    -- against the shipped implementation rather than a reimplementation.
    state.log = log_line

    local function diag_snapshot()
        local diag = type(patch.diag) == 'table' and patch.diag or {}
        return {
            string.format('revision=%s', tostring(build.revision)),
            string.format('build=%s', tostring(state.build or '?')),
            string.format('exe=%s', tostring(state.exe_hash or '?')),
            string.format('game=%s', tostring(state.game_hash or '?')),
            string.format('status=%s', tostring(state.status or '')),
            string.format('active=%s', tostring(state.active)),
            string.format('upd_ms=%.2f', blackbox.last_upd_ms),
            string.format('upd_window_ms=%.2f', blackbox.window_ms),
            string.format('upd_window_calls=%d', blackbox.window_calls),
            string.format('bb_alerts=%d', blackbox.alerts),
            string.format('clone_active=%s', tostring(diag.resource_clone_active == true)),
            string.format('clone_size=%s', tostring(diag.resource_clone_size or 0)),
            string.format('clone_events=%s', tostring(diag.resource_clone_events or 0)),
            string.format('clone_last=%s', tostring(diag.last_clone_event or 'none')),
            string.format('detail=%s', tostring(state.detail or '')),
        }
    end

    local diag = nil
    if create_diag then
        local built, instance = pcall(create_diag)
        if built and instance then diag = instance end
    end

    local function export_pack()
        if not diag or type(diag.export) ~= 'function' then
            return nil, 'diag_unavailable'
        end
        local folder, name_or_err = diag.export(diag_snapshot())
        if not folder then
            log_line('bb_export_failed', tostring(name_or_err))
            return nil, name_or_err
        end
        log_line('bb_export_ok', tostring(folder))
        return folder, name_or_err
    end
    state.export_diag = export_pack

    local function bb_alert(reason, detail)
        blackbox.alerts = blackbox.alerts + 1
        log_line('bb_alert', tostring(reason) .. ' ' .. tostring(detail or ''))
    end

    local function report(status, active, dt, perf_suffix)
        state.active = active
        local detail = type(patch.detail) == 'string' and patch.detail or ''
        if perf_suffix and perf_suffix ~= '' then
            detail = (detail ~= '' and (detail .. ' ' .. perf_suffix) or perf_suffix)
        end
        local changed = state.status ~= status or state.detail ~= detail
        state.elapsed = state.elapsed + ((type(dt) == 'number' and dt == dt and dt > 0) and dt or 0)
        if not changed and state.elapsed < 1.0 then return end
        state.elapsed = 0
        state.status, state.detail = status, detail
        if changed then
            print('[EnemySpawnMultiplier] ' .. build.revision .. ': ' .. status .. (detail ~= '' and (' ' .. detail) or ''))
        end
        pcall(log_line, status, detail)
    end
    -- Build identity is informational, not a gate.
    --
    -- Hard-failing on the executable hash blocked a fully working build when an
    -- update changed the hashes without moving a single pinned address. The
    -- addresses this patch depends on are data slots, and every write is already
    -- guarded at runtime by structure, memory-class and read-back checks. So a
    -- hash mismatch is reported and then ignored; what decides whether the patch
    -- is safe to run is the anchor probe below plus those runtime guards.
    local function build_identity(api, exe, game)
        local exe_hash = api.module_hash(exe)
        local game_hash = api.module_hash(game)
        local exe_known = exe_hash == build.exe_sha256
        local game_known = game_hash == build.game_sha256
        if exe_known and game_known then
            return 'known_build', exe_hash, game_hash
        end
        return 'unknown_build', exe_hash, game_hash
    end

    local ok, api, game = pcall(function()
        local api = create_api()
        local exe, game = api.module(nil), api.module('game.dll')
        assert(exe and game, 'Required game modules unavailable')
        assert(type(update) == 'function', 'Game update unavailable; no change applied')
        return api, game
    end)
    if not ok then report(tostring(api), false); return end

    local identity, exe_hash, game_hash = build_identity(api, api.module(nil), game)
    state.build = identity
    state.exe_hash, state.game_hash = exe_hash, game_hash
    log_line(identity, string.format('exe=%s game=%s', exe_hash, game_hash))
    log_line('bb_ready', 'blackbox=on export=panel_or_bat')

    -- Anchor probe: confirms the pinned data slots still look like what the patch
    -- expects. This is the replacement for the hash gate. A failure does not stop
    -- the module; it is logged so a genuinely broken build is obvious, and each
    -- guarded write still fails closed on its own.
    if create_anchors then
        local built, anchors = pcall(create_anchors, patch)
        if built and anchors then
            state.anchors = anchors
            local probed, good, failed = pcall(anchors.run, api, game)
            if not probed then
                log_line('anchor_error', tostring(good))
            elseif not good then
                log_line('anchor_warning', string.format(
                    '%d probe(s) failed: %s', failed or 0, anchors.summary()))
            end
        end
    end

    report('waiting_for_mission', false)

    -- The configuration panel is optional and created only after the game build
    -- validated above. A panel failure is logged and then ignored: the gameplay
    -- patch must keep running even if no window can be created.
    local panel = nil
    if create_panel then
        -- The bindings bridge is optional and independent of the panel: if the
        -- Mod Bindings Menu addon is absent the provider simply never becomes
        -- ready and the panel keeps its built-in F8 default.
        local bindings = nil
        if create_bindings then
            local built, instance = pcall(create_bindings, {
                id = 'natsun.enemy_spawn_multiplier.toggle_panel',
                -- Existing game text used for the bindings row: "TOGGLE MENU".
                label_id = 0x4FADC001,
                slot = 2,
            })
            if built and instance then bindings = instance end
        end
        -- The config store is optional too: when it is missing the panel simply
        -- runs without persistence, which is what the smaller test harnesses do.
        local store = nil
        if create_store then
            local built, instance = pcall(create_store)
            if built and instance then store = instance end
        end
        local created, instance, reason = pcall(create_panel, create_model, patch, {
            log = log_line, state = state, bindings = bindings, store = store,
            export_diag = export_pack,
            title = 'EnemySpawnMultiplier v21 by Natsun',
        })
        if created and instance then
            panel = instance
            state.panel = panel
            log_line('panel_ready', 'press F8 to toggle; export dumps Desktop pack')
        else
            log_line('panel_unavailable', tostring(created and reason or instance))
        end
    end

    local function now_clock()
        if type(os) == 'table' and type(os.clock) == 'function' then
            return os.clock()
        end
        return 0
    end

    local previous = update
    local stopped, elapsed = false, 0.1
    local function check(dt)
        if stopped then return end
        elapsed = elapsed + ((type(dt) == 'number' and dt == dt and dt > 0) and dt or 0)
        if elapsed < 0.1 then return end
        elapsed = 0
        local t0 = now_clock()
        local called, accepted, reason, active = pcall(patch.apply, api, game)
        local upd_ms = (now_clock() - t0) * 1000.0
        blackbox.last_upd_ms = upd_ms
        local now = now_clock()
        if blackbox.window_start == 0 or (now - blackbox.window_start) >= 1.0 then
            blackbox.window_start, blackbox.window_ms, blackbox.window_calls = now, 0, 0
        end
        blackbox.window_ms = blackbox.window_ms + upd_ms
        blackbox.window_calls = blackbox.window_calls + 1
        if not called then reason, accepted, active = tostring(accepted), false, false end
        reason = tostring(reason or '')

        local diag_state = type(patch.diag) == 'table' and patch.diag or nil
        if diag_state and diag_state.last_clone_event
            and diag_state.last_clone_event ~= blackbox.last_clone_event then
            blackbox.last_clone_event = diag_state.last_clone_event
            log_line('bb_clone', string.format(
                'event=%s active=%s size=%s events=%s',
                tostring(diag_state.last_clone_event),
                tostring(diag_state.resource_clone_active),
                tostring(diag_state.resource_clone_size),
                tostring(diag_state.resource_clone_events)))
            if tostring(diag_state.last_clone_event):find('fail', 1, true)
                or tostring(diag_state.last_clone_event):find('not_writable', 1, true) then
                bb_alert('clone_fault', diag_state.last_clone_event)
            end
        end

        if blackbox.last_status and blackbox.last_status ~= reason then
            log_line('bb_phase', string.format('%s->%s active=%s',
                tostring(blackbox.last_status), reason, tostring(active == true)))
            if reason == 'waiting_for_mission'
                and blackbox.last_status ~= 'waiting_for_mission' then
                bb_alert('mission_exit', blackbox.last_status)
            end
        end
        blackbox.last_status = reason

        if reason:find('_failed', 1, true) or reason:find('not_writable', 1, true)
            or reason:find('changed_underneath', 1, true) then
            bb_alert('write_fault', reason)
        end
        if upd_ms >= PERF_SINGLE_MS then
            bb_alert('upd_slow', string.format('upd_ms=%.2f', upd_ms))
        elseif blackbox.window_ms >= PERF_WINDOW_MS and blackbox.window_calls > 0 then
            bb_alert('upd_window_heavy', string.format(
                'window_ms=%.2f calls=%d', blackbox.window_ms, blackbox.window_calls))
            -- Reset the window so a sustained load does not spam every tick.
            blackbox.window_start, blackbox.window_ms, blackbox.window_calls = now, 0, 0
        end

        local perf = string.format('upd_ms=%.2f win_ms=%.2f', upd_ms, blackbox.window_ms)
        if not accepted then stopped = true end
        report(reason, active == true, dt, perf)
    end
    local function forward(dt, ...)
        check(dt)
        if panel then
            local pumped, reason = pcall(panel.pump)
            if not pumped then
                -- Never let a UI fault take the updater down with it.
                log_line('panel_disabled', tostring(reason))
                pcall(panel.close)
                panel, state.panel = nil, nil
            end
        end
        return ...
    end
    update = function(dt, ...)
        return forward(dt, previous(dt, ...))
    end
end
