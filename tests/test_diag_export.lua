-- Offline checks for the Desktop diagnostic exporter.
local source = assert(arg[1])
local create_diag = assert(loadfile(source .. '/diag_export.lua'))()

local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end

local root = ((os.getenv('TEMP') or os.getenv('TMP') or '.')
    .. '/esm_diag_test_' .. tostring(os.time())):gsub('\\', '/')
local appdata = root .. '/appdata'
local desktop = root .. '/desktop'

local function ensure_dir(path)
    local escaped = path:gsub('/', '\\'):gsub("'", "''")
    os.execute('powershell -NoProfile -Command "New-Item -ItemType Directory -Force -Path \''
        .. escaped .. '\' | Out-Null"')
end

ensure_dir(appdata)
ensure_dir(desktop)

local log = io.open(appdata .. '/EnemySpawnMultiplier.log', 'w')
assert(log, 'could not write test log under ' .. appdata)
log:write('hello log\n')
log:close()
local cfg = io.open(appdata .. '/EnemySpawnMultiplier.cfg', 'w')
assert(cfg, 'could not write test cfg')
cfg:write('version=1\nbudget=2\n')
cfg:close()

-- Prove the files are readable with the same path style export will try.
assert(io.open(appdata .. '/EnemySpawnMultiplier.log', 'r'), 'log missing before export')

local diag = create_diag({appdata = appdata, desktop = desktop})
local folder, name = diag.export({'revision=test', 'upd_ms=1.23'})
if type(folder) ~= 'string' then
    error('export failed: ' .. tostring(name), 0)
end
assert(folder:find('ESM', 1, true))
assert(type(name) == 'string')
local copied_log = io.open(folder:gsub('\\', '/') .. '/EnemySpawnMultiplier.log', 'r')
assert(copied_log, 'copied log missing in ' .. tostring(folder))
assert(copied_log:read('*a') == 'hello log\n')
copied_log:close()
local meta = io.open(folder:gsub('\\', '/') .. '/meta.txt', 'r')
assert(meta, 'meta missing')
local text = meta:read('*a')
meta:close()
assert(text:find('revision=test', 1, true))
assert(text:find('upd_ms=1.23', 1, true))
pass('export copies log/cfg and writes meta onto the Desktop folder')

print(string.format('diag_export: %d checks passed', count))
