return function(create_api, patch, build, create_panel, create_model, create_bindings, create_anchors,
                create_store, create_diag, create_corpse)
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

    -- Matchmaking privacy from the account settings file (Options → Gameplay →
    -- Matchmaking Privacy). privacy_mode 0 = Public; any other value is treated
    -- as non-public (Friends Only). When Public, spawn writes are skipped so a
    -- public lobby is not running the multiplier.
    --
    -- Do NOT use io.popen('cmd /c ...') here: on Windows that flashes a visible
    -- console every poll (~2s). Enumerate with FindFirstFileA and only io.open
    -- the chosen file afterwards.
    local PRIVACY_PUBLIC = 0
    local privacy = {raw = nil, label = 'unknown', public = false, path = nil, last_log = nil}
    local function find_user_settings(directory)
        local ok, chosen = pcall(function()
            local ffi = require('ffi')
            local kernel = ffi.load('kernel32')
            -- Opaque WIN32_FIND_DATAA (320 bytes). cFileName starts at offset 44;
            -- ftLastWriteTime (two DWORDs) at offset 20. Avoid named structs so a
            -- competing addon's cdef does not collide.
            local FindFirstFileA = ffi.cast(
                'void *(*)(const char *, void *)', kernel.FindFirstFileA)
            local FindNextFileA = ffi.cast(
                'int (*)(void *, void *)', kernel.FindNextFileA)
            local FindClose = ffi.cast('int (*)(void *)', kernel.FindClose)
            local data = ffi.new('uint8_t[320]')
            local pattern = directory .. '\\*_user_settings.config'
            local handle = FindFirstFileA(pattern, data)
            if handle == nil or handle == ffi.cast('void *', -1) then
                return nil
            end
            local best_name, best_high, best_low = nil, -1, -1
            repeat
                local name = ffi.string(data + 44)
                if name ~= '' and not name:find('%.old$', 1, false)
                    and name:find('_user_settings%.config$', 1, false) then
                    local low = ffi.cast('uint32_t *', data + 20)[0]
                    local high = ffi.cast('uint32_t *', data + 24)[0]
                    if high > best_high or (high == best_high and low > best_low) then
                        best_name, best_high, best_low = name, high, low
                    end
                end
            until FindNextFileA(handle, data) == 0
            FindClose(handle)
            return best_name
        end)
        if ok then return chosen end
        return nil
    end
    local function read_privacy()
        local appdata = os.getenv('APPDATA')
        if not appdata then return privacy end
        local directory = appdata .. '\\Arrowhead\\Helldivers2\\saves'
        local path = privacy.path
        if path then
            local probe = io.open(path, 'r')
            if not probe then
                privacy.path = nil
                path = nil
            else
                probe:close()
            end
        end
        if not path then
            local chosen = find_user_settings(directory)
            if not chosen then return privacy end
            path = directory .. '\\' .. chosen
        end
        local file = io.open(path, 'r')
        if not file then
            privacy.path = nil
            return privacy
        end
        local body = file:read('*a') or ''
        file:close()
        local raw = tonumber(body:match('privacy_mode%s*=%s*(%-?%d+)'))
        privacy.path = path
        privacy.raw = raw
        if raw == nil then
            privacy.label, privacy.public = 'unknown', false
        elseif raw == PRIVACY_PUBLIC then
            privacy.label, privacy.public = 'public', true
        else
            privacy.label, privacy.public = 'friends', false
        end
        return privacy
    end

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
            string.format('privacy=%s', tostring(privacy.label)),
            string.format('privacy_raw=%s', tostring(privacy.raw)),
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
    read_privacy()
    log_line('bb_privacy', string.format('privacy=%s raw=%s public=%s',
        tostring(privacy.label), tostring(privacy.raw), tostring(privacy.public)))
    privacy.last_log = string.format('%s/%s', tostring(privacy.label), tostring(privacy.raw))

    -- Fast corpse decay. Runs on its own interval (it accumulates dt internally),
    -- so it is driven from the same update callback but not the 0.1 s patch timer.
    local corpse, corpse_last_status, corpse_last_probes = nil, nil, nil
    if create_corpse then
        local built, instance, reason = pcall(create_corpse, api)
        if built and instance then
            corpse = instance
            patch.corpse = corpse
            patch.fast_corpse = true
            state.corpse = corpse
            log_line('corpse_ready', 'fast decay ~5s ragdoll-preserving; enabled by default')
        else
            log_line('corpse_unavailable', tostring(built and reason or instance))
        end
    end

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
    local privacy_elapsed = 1.0
    -- Once Public is seen while a mission is live, keep spawn/corpse gated until
    -- back on the ship. Flipping Friends mid-mission used to re-enable writes into
    -- a live director and correlated with a hard crash (diag 20260926-182912).
    local privacy_sticky = false
    local privacy_gated = false
    local function mission_live()
        if type(patch.in_mission) ~= 'function' then return false end
        local ok, yes = pcall(patch.in_mission, api, game)
        return ok and yes == true
    end
    local function check(dt)
        if stopped then return end
        elapsed = elapsed + ((type(dt) == 'number' and dt == dt and dt > 0) and dt or 0)
        if elapsed < 0.1 then return end
        elapsed = 0
        privacy_elapsed = privacy_elapsed + 0.1
        if privacy_elapsed >= 2.0 then
            privacy_elapsed = 0
            read_privacy()
            local marker = string.format('%s/%s', tostring(privacy.label), tostring(privacy.raw))
            if marker ~= privacy.last_log then
                privacy.last_log = marker
                log_line('bb_privacy', string.format('privacy=%s raw=%s public=%s sticky=%s',
                    tostring(privacy.label), tostring(privacy.raw), tostring(privacy.public),
                    tostring(privacy_sticky)))
            end
        end
        local live = mission_live()
        if privacy.public then
            privacy_sticky = true
        end
        if not live and privacy_sticky and not privacy.public then
            log_line('bb_privacy_latch', 'cleared on ship')
            privacy_sticky = false
        elseif not live then
            privacy_sticky = privacy.public
        end
        privacy_gated = privacy.public or privacy_sticky
        local t0 = now_clock()
        local called, accepted, reason, active
        if privacy_gated then
            -- Public (or sticky after Public): do not write spawn multipliers.
            called, accepted, reason, active = true, true, 'privacy_gate_public', false
        else
            called, accepted, reason, active = pcall(patch.apply, api, game)
        end
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
        if corpse and not privacy_gated then
            local stepped, reason = pcall(corpse.update, dt)
            if stepped and type(corpse.status) == 'function' then
                local snapshot = corpse.status()
                local marker = string.format('%s/%s/%s/%s/%s/%s/%s/%s',
                    tostring(snapshot.mode), tostring(snapshot.located),
                    tostring(snapshot.applied), tostring(snapshot.already),
                    tostring(snapshot.skipped), tostring(snapshot.dynamic_candidates),
                    tostring(snapshot.decayer_applied), tostring(snapshot.decayer_already))
                if marker ~= corpse_last_status then
                    corpse_last_status = marker
                    local probes = type(snapshot.header_probes) == 'table'
                        and table.concat(snapshot.header_probes, '|') or ''
                    local prot = ''
                    if type(snapshot.decay_api) == 'table' then
                        prot = string.format(' prot=%#x vp=%s',
                            tonumber(snapshot.decay_api.protection) or 0,
                            tostring(snapshot.decay_api.protect_calls))
                    end
                    local reasons = {}
                    if type(snapshot.skip_reasons) == 'table' then
                        for k, v in pairs(snapshot.skip_reasons) do
                            reasons[#reasons + 1] = tostring(k) .. '=' .. tostring(v)
                        end
                        table.sort(reasons)
                    end
                    log_line('corpse_status', string.format(
                        'mode=%s located=%s applied=%s already=%s skipped=%s candidates=%s decayer=%s/%s/%s reason=%s reasons=%s',
                        tostring(snapshot.mode), tostring(snapshot.located),
                        tostring(snapshot.applied), tostring(snapshot.already),
                        tostring(snapshot.skipped), tostring(snapshot.dynamic_candidates),
                        tostring(snapshot.decayer_applied), tostring(snapshot.decayer_already),
                        tostring(snapshot.decayer_skipped),
                        tostring(snapshot.reason), table.concat(reasons, ',')) .. prot)
                    if probes ~= '' and not corpse_last_probes then
                        corpse_last_probes = probes
                        log_line('corpse_probe', probes)
                    end
                end
            end
            if not stepped then
                -- The scan touches foreign memory; a fault here must not stop the
                -- gameplay patch, so disable just this feature.
                log_line('corpse_disabled', tostring(reason))
                if patch.corpse then patch.corpse.set_enabled(false) end
                patch.fast_corpse = false
                corpse, state.corpse = nil, nil
            end
        end
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
