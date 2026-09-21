return function(create_api, patch, build)
    if _G.EnemySpawnMultiplier then return end
    local state = {revision = build.revision, active = false, status = '', detail = '', elapsed = 1.0}
    _G.EnemySpawnMultiplier = state
    local LOG_LIMIT = 4 * 1024 * 1024
    local function log_line(status, detail)
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
    local function report(status, active, dt)
        state.active = active
        local detail = type(patch.detail) == 'string' and patch.detail or ''
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
    local ok, api, game = pcall(function()
        local api = create_api()
        local exe, game = api.module(nil), api.module('game.dll')
        assert(exe and game, 'Required game modules unavailable')
        assert(api.module_hash(exe) == build.exe_sha256, 'Unsupported executable; no change applied')
        assert(api.module_hash(game) == build.game_sha256, 'Unsupported game module; no change applied')
        assert(type(update) == 'function', 'Game update unavailable; no change applied')
        return api, game
    end)
    if not ok then report(tostring(api), false); return end
    report('waiting_for_mission', false)
    local previous = update
    local stopped, elapsed = false, 0.1
    local function check(dt)
        if stopped then return end
        elapsed = elapsed + ((type(dt) == 'number' and dt == dt and dt > 0) and dt or 0)
        if elapsed < 0.1 then return end
        elapsed = 0
        local called, accepted, reason, active = pcall(patch.apply, api, game)
        if not called then reason, accepted, active = tostring(accepted), false, false end
        if not accepted then stopped = true end
        report(tostring(reason), active == true, dt)
    end
    local function forward(dt, ...)
        check(dt)
        return ...
    end
    update = function(dt, ...)
        return forward(dt, previous(dt, ...))
    end
end
