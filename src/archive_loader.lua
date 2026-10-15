return function(create_api, patch, build, create_panel, create_model, create_bindings, create_anchors,
                create_store, create_diag, create_corpse, create_config, create_options, create_sos, create_dynamic)
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

    -- Blackbox budget: <=32 lines / 16 KiB queued, one batch per 5 seconds,
    -- <=4 alerts per 5 seconds, summaries every 30 seconds. No per-frame
    -- formatting, sorting, memory walking or file handles for diagnostics.
    local LOG_INTERVAL, SUMMARY_INTERVAL = 5.0, 30.0
    local LOG_LINES, LOG_BYTES = 32, 16*1024
    local log_queue, log_bytes, log_elapsed, dropped = {}, 0, 0, 0
    local diagnostic_time, alert_window, alert_count = 0, 0, 0
    local alerts_by_reason = {}
    blackbox.total_ms, blackbox.max_ms, blackbox.calls = 0, 0, 0
    blackbox.summary_elapsed, blackbox.window_elapsed = 0, 0
    blackbox.suppressed, blackbox.dropped = 0, 0
    blackbox.log_batches, blackbox.clock_calls = 0, 0
    state.blackbox = blackbox
    local function log_line(status, detail)
        if #log_queue >= LOG_LINES then dropped=dropped+1; blackbox.dropped=dropped; return end
        local line = tostring(status or ''):sub(1,80) .. ' ' .. tostring(detail or ''):sub(1,900) .. '\n'
        if log_bytes+#line > LOG_BYTES then dropped=dropped+1; blackbox.dropped=dropped; return end
        log_queue[#log_queue+1], log_bytes = line, log_bytes+#line
    end
    local function flush_log()
        if #log_queue == 0 then return end
        local directory = os.getenv('LOCALAPPDATA')
        if not directory then log_queue,log_bytes={},0; return end
        local path = directory .. '/EnemySpawnMultiplier.log'
        -- Detach first: failures cannot cause an unbounded retry queue.
        local queued = log_queue
        log_queue, log_bytes = {}, 0
        local file
        local ok = pcall(function()
            file = io.open(path,'a')
            if not file then return end
            local size = file:seek('end') or 0
            if size > LOG_LIMIT then
                file:close(); file=nil
                os.remove(path..'.1'); os.rename(path,path..'.1')
                file=io.open(path,'a'); size=0
            end
            if not file then return end
            if size==0 then file:write(build.revision .. '\n') end
            local stamp = type(os.date)=='function' and os.date('%H:%M:%S') or 't'
            for i,line in ipairs(queued) do queued[i]=stamp..' '..line end
            file:write(table.concat(queued))
        end)
        if file then pcall(file.close,file) end
        blackbox.log_batches=blackbox.log_batches+1
        if not ok then dropped=dropped+#queued end
    end
    state.log, state.flush_log = log_line, flush_log

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
    -- Created after the Windows API is up; diag_snapshot closes over this binding.
    local sos_probe = nil
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
            string.format('sos_build=%s', tostring(sos_probe and sos_probe.build or 'absent')),
            string.format('sos_sticky=%s', tostring(sos_probe and sos_probe.sticky or false)),
            string.format('sos_unsupported=%s', tostring(sos_probe and sos_probe.unsupported or false)),
            string.format('sos_event=%s', tostring(sos_probe and sos_probe.last_event or '-')),
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
        flush_log() -- explicit user export may flush ahead of the periodic batch
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
        -- Key on reason, not fluctuating measurements. Global cap also bounds
        -- alternating fault categories; state is fixed to internal reason keys.
        if diagnostic_time-alert_window >= LOG_INTERVAL then
            alert_window, alert_count = diagnostic_time, 0
        end
        if alert_count >= 4 or (alerts_by_reason[reason] and diagnostic_time-alerts_by_reason[reason]<LOG_INTERVAL) then
            blackbox.suppressed=blackbox.suppressed+1
            return
        end
        alerts_by_reason[reason], alert_count = diagnostic_time, alert_count+1
        log_line('bb_alert',tostring(reason)..' '..(type(detail)=='number' and string.format('ms=%.2f',detail) or tostring(detail or '')))
    end

    local last_console = -LOG_INTERVAL
    local function report(status, active, dt, perf_suffix)
        state.active = active
        local detail = type(patch.detail) == 'string' and patch.detail or ''
        local changed = state.status ~= status
        state.detail = detail -- export current values without treating them as a transition
        if not changed then return end
        state.elapsed = 0
        state.status, state.detail = status, detail
        if diagnostic_time-last_console >= LOG_INTERVAL then
            last_console=diagnostic_time
            print('[EnemySpawnMultiplier] ' .. build.revision .. ': ' .. status .. (detail ~= '' and (' ' .. detail) or ''))
        end
        -- Performance samples are diagnostic data, not state identity. Including
        -- the changing `upd_ms/win_ms` suffix in `state.detail` made every 0.1 s
        -- update look like a state transition and opened/appended/closed the log
        -- file ten times per second. Keep the state stable and attach the latest
        -- sample only to the already-throttled log write.
        local logged_detail = detail
        if perf_suffix and perf_suffix ~= '' then
            local sample=type(perf_suffix)=='number' and string.format('patch_ms=%.2f',perf_suffix) or perf_suffix
            logged_detail = (logged_detail ~= '' and (logged_detail .. ' ' .. sample) or sample)
        end
        pcall(log_line, status, logged_detail)
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
    if create_dynamic then
        local built,module=pcall(create_dynamic)
        if built and type(module)=='table' then
            local made,session=pcall(module.create,api,patch,identity=='known_build',false)
            if made and session then patch.dynamic=session end
        end
        log_line('dynamic_ready',patch.dynamic and (patch.dynamic.mode=='h100_compensation'
            and 'ready; mode=h100_compensation H>95 x3 or H>100 hold_s=10 rate=half switch=soft_limit_and_progression diagnostics=70/100'
            or patch.dynamic.mode=='local_h100_test'
            and 'ready; mode=local_h100_test H>95 x3 or H>100 hold_s=10 rate=half progression=always_initial_tier'
            or 'ready; mode=progression_only pressure_feedback=off sample_s=none progression=initial_tier') or 'unavailable')
    end
    log_line(identity, string.format('exe=%s game=%s', exe_hash, game_hash))
    log_line('bb_ready', 'blackbox=on summary_s=30 flush_s=5 queue=32/16384 alerts=4/5s')

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

    if create_sos then
        local built, module = pcall(create_sos)
        if built and type(module) == 'table' and type(module.create) == 'function' then
            local made, session = pcall(module.create, api)
            if made and session then
                sos_probe = session
                log_line('bb_sos', 'probe=ready interval=2s fail_closed_on_mismatch=1')
            else
                log_line('bb_sos', 'probe=create_failed ' .. tostring(session))
            end
        else
            log_line('bb_sos', 'probe=module_failed ' .. tostring(module))
        end
    else
        log_line('bb_sos', 'probe=absent')
    end

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

    -- Shared configuration is independent of the Win32 window: MODS and saved
    -- settings still work if the optional F8 panel cannot be created.
    local store, config, mods_menu = nil, nil, nil
    if create_store then
        local built, instance = pcall(create_store)
        if built and instance then store = instance end
    end
    if create_config and create_model then
        local built, instance = pcall(create_config, create_model, patch, {store=store, log=log_line})
        if built and instance then config = instance; state.config = config
        else log_line('config_unavailable', tostring(instance)) end
    end
    if create_options and config then
        local built, instance = pcall(create_options, config, {log=log_line})
        if built and instance then mods_menu = instance; state.mods_menu = mods_menu
        else log_line('mods_menu_unavailable', tostring(instance)) end
    end

    -- The configuration panel is optional and created only after the game build
    -- validated above. A panel failure is logged and then ignored: the gameplay
    -- patch must keep running even if no window can be created.
    local panel = nil
    if create_panel then
        local panel_version = tostring(build.revision):match('v[%d%.]+') or 'v24'
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
        local created, instance, reason = pcall(create_panel, create_model, patch, {
            log = log_line, state = state, bindings = bindings, store = store, config = config,
            export_diag = export_pack,
            title = 'EnemySpawnMultiplier ' .. panel_version .. ' by Natsun',
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
            blackbox.clock_calls=blackbox.clock_calls+1
            return os.clock()
        end
        return 0
    end

    local previous = update
    local stopped, elapsed = false, 0
    local privacy_elapsed = 1.0
    local sos_elapsed = 1.9
    local SOS_INTERVAL = 2.0
    -- Once Public is seen while a mission is live, keep spawn/corpse gated until
    -- back on the ship. Flipping Friends mid-mission used to re-enable writes into
    -- a live director and correlated with a hard crash (diag 20260926-182912).
    local privacy_sticky = false
    local lobby_gated = false
    local function mission_live()
        if type(patch.in_mission) ~= 'function' then return false end
        local ok, yes = pcall(patch.in_mission, api, game)
        return ok and yes == true
    end
    local function check(dt)
        if stopped then return end
        elapsed = elapsed + ((type(dt) == 'number' and dt == dt and dt > 0) and dt or 0)
        if elapsed < 0.1 then return end
        local step_dt=math.min(elapsed,1)
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
        local privacy_gated = privacy.public or privacy_sticky

        -- SOS probe: low-frequency while a mission is live and the lobby is not
        -- already gated. After sticky/unsupported, scanning stops until ship
        -- (sticky) or process exit (unsupported / build mismatch).
        local sos_gated = false
        local sos_reason = nil
        if sos_probe then
            if not live and sos_probe.sticky then
                log_line('bb_sos_latch', 'cleared on ship')
                sos_probe.reset_latch()
            end
            if sos_probe.unsupported then
                sos_gated = true
                sos_reason = (sos_probe.build == 'mismatch')
                    and 'sos_probe_build_mismatch' or 'sos_probe_unreliable'
            elseif sos_probe.sticky then
                sos_gated = true
                sos_reason = 'privacy_gate_sos'
            else
                local need_build = sos_probe.build == 'pending'
                local scan = false
                if need_build or (live and not privacy_gated) then
                    sos_elapsed = sos_elapsed + 0.1
                    if sos_elapsed >= SOS_INTERVAL then
                        sos_elapsed = 0
                        scan = true
                    end
                end
                if scan then
                    local ok, gated, reason, detail = pcall(sos_probe.probe, game, {
                        live = live,
                        refresh_build = need_build,
                    })
                    if not ok then
                        log_line('bb_sos', 'probe_error ' .. tostring(gated))
                    else
                        local marker = tostring(detail or '')
                        if marker ~= '' and marker ~= sos_probe._last_log then
                            sos_probe._last_log = marker
                            log_line('bb_sos', marker)
                        end
                        if gated then
                            sos_gated = true
                            sos_reason = reason
                        end
                    end
                end
            end
        end

        lobby_gated = privacy_gated or sos_gated
        local t0 = now_clock()
        local called, accepted, reason, active
        if lobby_gated then
            -- Public, SOS-spent, or SOS probe unavailable: do not write multipliers.
            if privacy_gated then
                called, accepted, reason, active = true, true, 'privacy_gate_public', false
            else
                called, accepted, reason, active = true, true, tostring(sos_reason or 'privacy_gate_sos'), false
            end
        else
            patch.dynamic_dt=step_dt
            called, accepted, reason, active = pcall(patch.apply, api, game)
        end
        if patch.dynamic and (not live or lobby_gated) then patch.dynamic.reset() end
        if patch.dynamic and patch.dynamic.event then
            log_line('local_soft_limit',patch.dynamic.event)
            patch.dynamic.event=nil
        end
        if patch.dynamic and patch.dynamic.observation_event then
            log_line('local_gate_crossing',patch.dynamic.observation_event)
            patch.dynamic.observation_event=nil
        end
        local upd_ms = (now_clock() - t0) * 1000.0
        blackbox.last_upd_ms = upd_ms
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
        if not accepted then stopped = true end
        report(reason, active == true, dt, upd_ms)
    end
    local function sample_component_gate()
        -- Two guarded reads per 30-second summary, on the pinned build only.
        -- This is diagnostic data; it never changes native admission decisions.
        if state.build~='known_build' or type(api.read)~='function' or type(api.pointer)~='function' then return nil end
        local ok,value=pcall(function()
            local manager=api.pointer(api.read(game+0x33264D8,8))
            if not manager then return nil end
            local bytes=api.read(manager+0x0c,4)
            if not bytes or #bytes~=4 then return nil end
            local a,b,c,d=bytes:byte(1,4)
            return a+b*256+c*65536+d*16777216
        end)
        return ok and value or nil
    end

    local corpse_status_elapsed, corpse_snapshot = 0, nil
    local suspended = false
    local function forward(dt, ...)
        local started = now_clock() -- previous() has already returned
        local delta = type(dt)=='number' and dt==dt and dt>0 and math.min(dt,1) or 0
        diagnostic_time, log_elapsed = diagnostic_time+delta, log_elapsed+delta
        corpse_status_elapsed = corpse_status_elapsed+delta
        if mods_menu then
            local pumped, reason = pcall(mods_menu.pump, dt)
            if not pumped then
                mods_menu.status, mods_menu.reason = 'unavailable', tostring(reason)
                log_line('mods_menu_disabled', tostring(reason))
                mods_menu = nil
            end
        end
        check(dt)
        if lobby_gated and not suspended and type(patch.suspend)=='function' then
            pcall(patch.suspend,api,game)
            suspended=true
        elseif not lobby_gated then suspended=false end
        if corpse and not lobby_gated then
            local stepped, reason = pcall(corpse.update, dt)
            if stepped and corpse_status_elapsed >= 0.5 and type(corpse.status) == 'function' then
                corpse_status_elapsed = 0
                local snapshot = corpse.status()
                corpse_snapshot = snapshot
                local marker = table.concat({tostring(snapshot.enabled),tostring(snapshot.mode),
                    tostring(snapshot.located),tostring(snapshot.epoch),
                    tostring(snapshot.reason):match('^[^ :=]+') or ''},'/')
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
        blackbox.summary_elapsed = blackbox.summary_elapsed+delta
        if blackbox.summary_elapsed >= SUMMARY_INTERVAL then
            blackbox.summary_elapsed=0
            blackbox.component_gate_count=sample_component_gate()
            local dynamic=patch.dynamic
            local effective=dynamic and dynamic.effective
            if effective then
                local sample=dynamic.sample
                local stats=dynamic.stats
                if stats then
                    log_line('local_gate_stats',string.format(
                        'mission_samples=%d invalid=%d S70_ge70=%d H_gt95=%d H_gt100=%d peak_S70=%s peak_H=%s',
                        stats.valid,stats.invalid,stats.s70_ge70,stats.h_gt95,stats.h_gt100,
                        tostring(stats.peak_s70 or '-'),tostring(stats.peak_h or '-')))
                end
                log_line('bb_dynamic',string.format(
                    'phase=%s valid=%s requested=%.2f/%.2f/%.2f effective=%.2f/%.2f/%.2f S70=%s H=%s Q=%s P=%s E=%s B=%s C=%s',
                    tostring(effective.phase),tostring(sample~=nil),
                    patch.modifier_patrol_count,patch.modifier_travelers_max_unit,patch.modifier_patrol_cooldown,
                    effective.count,effective.size,effective.rate,
                    tostring(sample and sample.s70),tostring(sample and sample.h),
                    tostring(sample and sample.q),tostring(sample and sample.p),
                    tostring(sample and sample.e),tostring(sample and sample.b),tostring(sample and sample.components)))
            end
            log_line('bb_summary',string.format(
                'total_avg_ms=%.3f total_max_ms=%.3f calls=%d patch_ms=%.3f suppressed=%d dropped=%d corpse=%s/%s/%s clone_bytes=%s components=%s/448',
                blackbox.total_ms/math.max(1,blackbox.calls),blackbox.max_ms,blackbox.calls,
                blackbox.last_upd_ms,blackbox.suppressed,dropped,
                tostring(corpse_snapshot and corpse_snapshot.applied or 0),
                tostring(corpse_snapshot and corpse_snapshot.already or 0),
                tostring(corpse_snapshot and corpse_snapshot.skipped or 0),
                tostring(patch.diag and patch.diag.retained_clone_bytes or 0),
                tostring(blackbox.component_gate_count or 'unavailable')))
            blackbox.total_ms,blackbox.max_ms,blackbox.calls=0,0,0
        end
        if log_elapsed >= LOG_INTERVAL then
            log_elapsed=0
            flush_log()
        end
        local total_ms=math.max(0,(now_clock()-started)*1000)
        blackbox.last_total_ms=total_ms
        blackbox.total_ms=blackbox.total_ms+total_ms
        blackbox.max_ms=math.max(blackbox.max_ms,total_ms)
        blackbox.calls=blackbox.calls+1
        blackbox.window_ms=blackbox.window_ms+total_ms
        blackbox.window_elapsed=blackbox.window_elapsed+delta
        if total_ms>=PERF_SINGLE_MS then bb_alert('total_slow',total_ms) end
        if blackbox.window_elapsed>=1 then
            if blackbox.window_ms>=PERF_WINDOW_MS then
                bb_alert('total_window_heavy',blackbox.window_ms)
            end
            blackbox.window_ms,blackbox.window_elapsed=0,0
        end
        blackbox.dropped=dropped
        return ...
    end
    update = function(dt, ...)
        return forward(dt, previous(dt, ...))
    end
end
