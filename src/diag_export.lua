-- Desktop diagnostic pack export for crash reports.
--
-- Copies the live log / rotated log / panel cfg into a timestamped folder on the
-- player's Desktop and writes a small meta.txt. No FFI: path discovery uses
-- environment variables, directory creation uses os.execute, and file copies
-- are plain Lua io. Kept free of spawn_patch so it can be unit-tested offline
-- and so a failure here can never take the updater down.
return function(options)
    options = options or {}
    local M = {}

    local LOG_NAME = 'EnemySpawnMultiplier.log'
    local CFG_NAME = 'EnemySpawnMultiplier.cfg'

    function M.appdata_dir()
        if options.appdata then return options.appdata end
        local base = os.getenv and os.getenv('LOCALAPPDATA')
        if type(base) ~= 'string' or base == '' then return nil end
        return base
    end

    function M.desktop_dir()
        if options.desktop then return options.desktop end
        local user = os.getenv and os.getenv('USERPROFILE')
        if type(user) ~= 'string' or user == '' then return nil end
        local primary = user .. '\\Desktop'
        -- OneDrive-redirected Desktops are common on Chinese Windows installs.
        local onedrive = os.getenv('OneDrive')
        if type(onedrive) == 'string' and onedrive ~= '' then
            local candidate = onedrive .. '\\Desktop'
            -- Prefer a Desktop that already has at least one readable marker; if
            -- neither can be probed, fall through to the USERPROFILE path.
            local probe = io.open(candidate .. '\\.', 'r')
            if probe then
                probe:close()
                return candidate
            end
        end
        return primary
    end

    local function stamp()
        if type(os.date) ~= 'function' then return 'export' end
        return os.date('%Y%m%d-%H%M%S')
    end

    local function mkdir(path)
        if options.mkdir then return options.mkdir(path) end
        -- PowerShell creates intermediate directories and handles UTF-8 folder names
        -- more reliably than cmd mkdir under the game's code page.
        local escaped = path:gsub('/', '\\'):gsub("'", "''")
        local command = 'powershell -NoProfile -Command "New-Item -ItemType Directory -Force -Path \''
            .. escaped .. '\' | Out-Null"'
        os.execute(command)
        return true
    end

    local function copy_file(source, destination)
        local input = io.open(source, 'rb')
        if not input then return false, 'missing:' .. source end
        local ok_read, data = pcall(input.read, input, '*a')
        input:close()
        if not ok_read then return false, 'read_failed' end
        local output, open_reason = io.open(destination, 'wb')
        if not output then return false, 'open_failed:' .. tostring(open_reason) end
        local ok_write, write_reason = pcall(output.write, output, data or '')
        output:close()
        if not ok_write then return false, 'write_failed:' .. tostring(write_reason) end
        return true, #(data or '')
    end

    -- meta_lines is an optional list of already-formatted "key=value" strings
    -- supplied by the loader (revision, hashes, last status, perf counters…).
    function M.export(meta_lines)
        local desktop = M.desktop_dir()
        if not desktop then return nil, 'no_desktop' end
        local appdata = M.appdata_dir()
        if not appdata then return nil, 'no_appdata' end

        local folder_name = 'ESM-diag-' .. stamp()
        local folder = desktop:gsub('/', '\\') .. '\\' .. folder_name
        mkdir(folder)

        local function candidate_paths(base, name)
            local slash = base:gsub('\\', '/') .. '/' .. name
            local back = base:gsub('/', '\\') .. '\\' .. name
            if slash == back then return {slash} end
            return {back, slash}
        end

        local copied = {}
        local names = {LOG_NAME, LOG_NAME .. '.1', CFG_NAME}
        for _, name in ipairs(names) do
            local destination = folder:gsub('/', '\\') .. '\\' .. name
            local ok, detail = false, nil
            for _, source in ipairs(candidate_paths(appdata, name)) do
                ok, detail = copy_file(source, destination)
                if ok then break end
            end
            if ok then
                copied[#copied + 1] = name .. '=' .. tostring(detail)
            end
        end
        if #copied == 0 then
            return nil, 'nothing_to_copy'
        end

        local meta_path = folder .. '\\meta.txt'
        local lines = {
            'EnemySpawnMultiplier diagnostic pack',
            'exported=' .. (type(os.date) == 'function' and os.date('!%Y-%m-%dT%H:%M:%SZ') or '?'),
            'folder=' .. folder_name,
        }
        if type(meta_lines) == 'table' then
            for _, line in ipairs(meta_lines) do
                if type(line) == 'string' and line ~= '' then
                    lines[#lines + 1] = line
                end
            end
        end
        lines[#lines + 1] = 'copied=' .. table.concat(copied, ',')
        lines[#lines + 1] = 'note=attach this whole folder when reporting a crash; every player in the lobby should export their own pack'
        local meta = io.open(meta_path, 'w')
        if meta then
            meta:write(table.concat(lines, '\n') .. '\n')
            meta:close()
        end
        return folder, folder_name
    end

    return M
end
