-- Local persistence for the in-game configuration panel.
--
-- The panel itself is transient: it lives in one process and its sliders start
-- from the build's shipped defaults on every launch. This module persists the
-- committed settings to a small key=value file under %LOCALAPPDATA% so the
-- configuration survives a game restart and can be restored before the first
-- updater pass.
--
-- The file is written by us and read by us, so it stays human-readable rather
-- than JSON (the game VM has no JSON library). Every field is range-checked on
-- read, so a truncated or hand-edited file can never push an out-of-range value
-- into patch.configure(). Pure string handling and io only: no FFI, no native
-- calls, so the encoding, parsing and fallbacks are unit-testable offline.
return function(options)
    options = options or {}
    local M = {}

    M.VERSION = 1
    M.FILENAME = options.filename or 'EnemySpawnMultiplier.cfg'

    -- Written in this order so the file is stable and diffable.
    -- patrol_size is no longer a panel control; ignore it if an older cfg still
    -- contains the field so restore cannot resurrect a removed slider.
    M.FIELDS = {'budget', 'patrol_count', 'encounter_cd', 'patrol_cd', 'preset'}

    -- Same ranges the panel and patch.configure() enforce. Values read back out
    -- of range are clamped here so a corrupt file degrades to a valid profile
    -- instead of being rejected wholesale.
    local MULTIPLIER = {min = 0.1, max = 6.0}
    local COOLDOWN = {min = 2.0, max = 30.0}
    local LIMITS = {
        budget = MULTIPLIER,
        patrol_count = MULTIPLIER,
        encounter_cd = COOLDOWN,
        patrol_cd = COOLDOWN,
    }
    local PRESETS = {heavy = true, light_medium = true, native = true}

    -- options.dir lets the tests point the store at a scratch directory instead
    -- of the real %LOCALAPPDATA%.
    function M.directory()
        if options.dir then return options.dir end
        local base = os.getenv and os.getenv('LOCALAPPDATA')
        if type(base) ~= 'string' or base == '' then return nil end
        return base
    end

    function M.path()
        local directory = M.directory()
        if not directory then return nil end
        return directory .. '/' .. M.FILENAME
    end

    local function format_number(value)
        -- Two decimals is the panel's own multiplier resolution; a whole-second
        -- cooldown prints without a trailing .00 but both parse back exactly.
        if value == math.floor(value) then return string.format('%d', value) end
        return string.format('%.2f', value)
    end

    function M.encode(settings)
        if type(settings) ~= 'table' then return nil, 'settings_not_a_table' end
        local lines = {'version=' .. tostring(M.VERSION)}
        for _, key in ipairs(M.FIELDS) do
            local value = settings[key]
            if value ~= nil then
                if type(value) == 'number' and value == value then
                    lines[#lines + 1] = key .. '=' .. format_number(value)
                elseif type(value) == 'string' and PRESETS[value] then
                    lines[#lines + 1] = key .. '=' .. value
                end
            end
        end
        return table.concat(lines, '\n') .. '\n'
    end

    function M.decode(text)
        if type(text) ~= 'string' or text == '' then return nil, 'empty' end
        local settings, version = {}, nil
        for line in text:gmatch('[^\r\n]+') do
            line = line:match('^%s*(.-)%s*$')
            if line ~= '' and line:sub(1, 1) ~= '#' then
                local key, value = line:match('^([%w_]+)%s*=%s*(.-)$')
                if key then
                    if key == 'version' then
                        version = tonumber(value)
                    elseif key == 'preset' then
                        if PRESETS[value] then settings.preset = value end
                    elseif LIMITS[key] then
                        local number = tonumber(value)
                        if number and number == number then
                            local limit = LIMITS[key]
                            if number < limit.min then number = limit.min end
                            if number > limit.max then number = limit.max end
                            settings[key] = number
                        end
                    end
                end
            end
        end
        -- A file from a future version may use fields this build cannot
        -- interpret, so refuse it rather than applying a partial profile.
        if version and version > M.VERSION then return nil, 'newer_version' end
        if next(settings) == nil then return nil, 'no_fields' end
        return settings
    end

    function M.load()
        local path = M.path()
        if not path then return nil, 'no_directory' end
        local file = io.open(path, 'r')
        if not file then return nil, 'not_found' end
        local ok, text = pcall(file.read, file, '*a')
        file:close()
        if not ok then return nil, 'read_failed' end
        return M.decode(text)
    end

    function M.save(settings)
        local path = M.path()
        if not path then return false, 'no_directory' end
        local encoded, reason = M.encode(settings)
        if not encoded then return false, reason end
        -- Write to a sibling temp file first: a crash mid-write then leaves the
        -- previous good configuration untouched instead of a half-written file.
        local temporary = path .. '.tmp'
        local file, open_reason = io.open(temporary, 'w')
        if not file then return false, 'open_failed:' .. tostring(open_reason) end
        local ok, write_reason = pcall(file.write, file, encoded)
        if not ok then
            file:close()
            os.remove(temporary)
            return false, 'write_failed:' .. tostring(write_reason)
        end
        file:close()
        -- os.rename refuses to overwrite on Windows, so drop the old file first.
        os.remove(path)
        if not os.rename(temporary, path) then
            os.remove(temporary)
            return false, 'rename_failed'
        end
        return true
    end

    return M
end
