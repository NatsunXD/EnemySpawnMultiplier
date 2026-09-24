-- Config persistence checks: encoding, parsing, clamping and atomic writes.
-- Pure Lua and io against a scratch directory; no FFI and no game memory.
local source, build = assert(arg[1]), assert(arg[2])
local create_store = assert(loadfile(source .. '/config_store.lua'))()

local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end

local directory = build .. '/config-store-test'
os.execute('mkdir "' .. directory:gsub('/', '\\') .. '" 2>nul')
os.remove(directory .. '/EnemySpawnMultiplier.cfg')
local store = create_store({dir = directory})

-- A full profile survives an encode/decode round trip unchanged.
local profile = {budget = 4.5, patrol_count = 3.0,
                 encounter_cd = 12.0, patrol_cd = 2.0, preset = 'light_medium'}
local text = store.encode(profile)
assert(type(text) == 'string' and text:sub(1, 8) == 'version=')
assert(not text:find('patrol_size', 1, true), 'patrol_size must not be persisted')
local decoded, reason = store.decode(text)
assert(decoded, tostring(reason))
assert(decoded.budget == 4.5 and decoded.patrol_count == 3.0 and decoded.patrol_size == nil)
assert(decoded.encounter_cd == 12.0 and decoded.patrol_cd == 2.0)
assert(decoded.preset == 'light_medium')
pass('a profile survives an encode/decode round trip')

-- Legacy cfg files that still contain patrol_size must load without resurrecting it.
local legacy = store.decode('version=1\nbudget=2.0\npatrol_count=2.0\npatrol_size=3.0\npreset=heavy\n')
assert(legacy and legacy.budget == 2.0 and legacy.patrol_size == nil)
pass('legacy patrol_size in cfg is ignored')

-- The panel path is only one line of text, so the save must go through the real
-- file system and read back byte-for-byte.
assert(store.save(profile))
local loaded, load_reason = store.load()
assert(loaded, tostring(load_reason))
assert(loaded.budget == 4.5 and loaded.preset == 'light_medium')
assert(not io.open(directory .. '/EnemySpawnMultiplier.cfg.tmp', 'r'), 'temp file was left behind')
pass('save/load round-trips through the file system and leaves no temp file')

-- Unknown keys, comments and blank lines are ignored; a missing file is a clean
-- "not_found" rather than an error.
os.remove(directory .. '/EnemySpawnMultiplier.cfg')
local missing, missing_reason = store.load()
assert(missing == nil and missing_reason == 'not_found')
local tolerant = store.decode('# comment\n\nversion=1\nbudget=3.0\nfuture_field=99\n')
assert(tolerant and tolerant.budget == 3.0 and tolerant.future_field == nil)
pass('unknown keys and comments are ignored; a missing file is not_found')

-- Malformed values must never reach patch.configure(): bad numbers are dropped,
-- out-of-range ones are clamped, and a preset outside the known set is dropped.
local clamped = store.decode('version=1\nbudget=999\nencounter_cd=oops\npreset=bogus\n')
assert(clamped and clamped.budget == 6.0)
assert(clamped.encounter_cd == nil and clamped.preset == nil)
local empty = store.decode('version=1\nnothing=1\n')
assert(empty == nil)
local newer = store.decode('version=999\nbudget=3.0\n')
assert(newer == nil)
pass('malformed values are clamped or dropped, future versions are refused')

-- A file for a future version must never be partially applied, and encode must
-- refuse a non-table instead of raising.
assert(select(1, store.encode(nil)) == nil)
pass('encode refuses a non-table without raising')

print(count .. ' config store checks passed; no game process involved.')
