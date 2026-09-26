-- Fast corpse decay checks: table location, identity guard, the ~5 s write and
-- the restore path. Runs against a synthetic entity table; no game memory.
local source, build = assert(arg[1]), assert(arg[2])
local ffi = require('ffi')
local create_corpse = assert(loadfile(source .. '/corpse_clear.lua'))()
local data = assert(loadfile(source .. '/corpse_data.lua'))()
local decayer_data = assert(loadfile(source .. '/corpse_decayer_data.lua'))()

local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end
local function approx(a, b) return type(a) == 'number' and math.abs(a - b) <= 0.002 end

assert(#data > 0, 'corpse record table must not be empty')

-- A synthetic entity table: one region holding the header and the records at
-- their recorded anchors. The anchors reach ~18 MB, so the buffer is sized from
-- the data rather than guessed.
local max_anchor = 0
for _, row in ipairs(data) do
    if row[1] > max_anchor then max_anchor = row[1] end
end
local TABLE_SIZE = max_anchor + 64
local storage = ffi.new('uint8_t[?]', TABLE_SIZE)
local table_base = ffi.cast('uint8_t *', storage)
local HEADER = string.char(112, 202, 193, 128, 76, 68, 76, 68, 1, 0, 0, 0)
ffi.copy(table_base, HEADER, #HEADER)

local function put_f32(addr, v) ffi.copy(addr, ffi.new('float[1]', v), 4) end
local function put_u32(addr, v) ffi.copy(addr, ffi.new('uint32_t[1]', v), 4) end
local function get_f32(addr)
    local v = ffi.new('float[1]'); ffi.copy(v, addr, 4); return tonumber(v[0])
end

-- Seed every record with its recorded (unmodified) values.
for _, row in ipairs(data) do
    local anchor, accel, min_delay, max_delay, unk = row[1], row[2], row[3], row[4], row[5]
    local p = table_base + anchor
    put_u32(p + 0, 1)          -- DeathDecayMode_Regular
    put_f32(p + 4, accel)
    put_f32(p + 8, min_delay)
    put_f32(p + 12, max_delay)
    put_f32(p + 16, unk)
end

-- Materialize the CorpseDecayerComponent rows: {f32 radius, u32 node}.
assert(#decayer_data > 0, 'decayer record table must not be empty')
for _, row in ipairs(decayer_data) do
    local p = table_base + row[1]
    put_f32(p + 0, row[2])
    put_u32(p + 4, row[3])
end

-- Minimal api over that synthetic table. Contract (mirrors windows_api.lua):
-- addresses are plain numbers; only cast_uint8 hands back a real pointer.
local REGION_BASE, REGION_SIZE = 0x10000000, TABLE_SIZE
local function base_number() return REGION_BASE end
local api = {}
function api.query_region(address)
    if type(address) ~= 'number' then return nil end
    if address >= REGION_BASE and address < REGION_BASE + REGION_SIZE then
        return REGION_BASE, REGION_SIZE, 0x1000, 0x04, 0x20000
    end
    return REGION_BASE, REGION_SIZE, 0x1000, 0x04, 0x20000
end
function api.read(address, size)
    local a = tonumber(ffi.cast('uintptr_t', address))
    if a >= REGION_BASE and a + size <= REGION_BASE + REGION_SIZE then
        return ffi.string(table_base + (a - REGION_BASE), size)
    end
    return nil
end
function api.write(address, bytes)
    local a = tonumber(ffi.cast('uintptr_t', address))
    if not (a >= REGION_BASE and a + #bytes <= REGION_BASE + REGION_SIZE) then return false end
    ffi.copy(table_base + (a - REGION_BASE), bytes, #bytes)
    return true
end
function api.writable_data(address, size)
    local a = tonumber(ffi.cast('uintptr_t', address))
    return a >= REGION_BASE and a + size <= REGION_BASE + REGION_SIZE
end
function api.cast_uint8(address) return ffi.cast('uint8_t *', address) end
-- Mirror the shipped Windows API: the decay path has its own writable predicate
-- that also accepts PAGE_WRITECOPY, so the stub must provide the same surface.
function api.writable_decay(address, size) return api.writable_data(address, size) end
function api.write_decay(address, bytes) return api.write(address, bytes) end
function api.encode_f32(v) return ffi.string(ffi.new('float[1]', v), 4) end
function api.encode_u32(v) return ffi.string(ffi.new('uint32_t[1]', v), 4) end

local mod = create_corpse(api, data, decayer_data)
assert(type(mod.update) == 'function')

-- The scan is interval-gated; drive it with enough dt to pass each interval.
local function run(seconds)
    local steps = math.ceil(seconds / 0.1)
    for _ = 1, steps do mod.update(0.1) end
end

-- Interval gating: a single small dt must not run a pass.
local before = mod.status().passes
mod.update(0.01)
assert(mod.status().passes == before, 'a sub-interval dt must not trigger a pass')
pass('passes are gated to the 0.5 s interval')

-- Locate the table, then apply. Locating and applying happen in separate passes,
-- so the first pass only finds the table.
run(1)
assert(mod.status().located, 'the entity table was not located')
pass('locates the entity table')

-- After enough passes every row is either freshly written or already correct.
run(3)
local st = mod.status()
assert(st.applied + st.already + st.skipped == #data,
    'not every row was accounted for: ' .. tostring(st.reason))
assert(st.skipped == 0, 'no row should be skipped for a clean table')
pass('rewrites the decay delays and accounts for every row')

-- Spot-check the writes: every Regular row now holds min=max=5 (ragdoll profile).
local checked = 0
for _, row in ipairs(data) do
    local p = table_base + row[1]
    assert(approx(get_f32(p + 8), 5.0), 'min_delay not 5 at anchor ' .. tostring(row[1]))
    assert(approx(get_f32(p + 12), 5.0), 'max_delay not 5 at anchor ' .. tostring(row[1]))
    assert(approx(get_f32(p + 16), 10.0), 'decay float not 10 at anchor ' .. tostring(row[1]))
    checked = checked + 1
end
assert(checked == #data)
pass('every recorded row holds min_delay = max_delay = 5')

-- Idempotence: running again must not report fresh writes.
run(2)
local st2 = mod.status()
assert(st2.applied == 0, 'a later pass rewrote rows: ' .. tostring(st2.reason))
assert(st2.already == #data, 'a later pass should see every row already applied')
pass('repeat passes are idempotent')

-- Identity guard: corrupt one row's acceleration. That row must be skipped, not
-- written, while the others continue to be reported as already applied.
local victim = data[1][1]
put_f32(table_base + victim + 4, 123.456)
run(2)
local st3 = mod.status()
assert(st3.skipped >= 1, 'a mismatched row must be skipped')
assert(approx(get_f32(table_base + victim + 8), 5.0),
    'a row whose identity failed must not have been written again')
pass('a row whose identity no longer matches is skipped, not written')

-- Restore: a fresh instance that has applied the change must put every recorded
-- value back when the switch is turned off.
local mod2 = create_corpse(api, data, decayer_data)
-- Put the table back to its recorded state, including the row we corrupted above,
-- so this is a clean apply-then-restore cycle.
for _, row in ipairs(data) do
    local p = table_base + row[1]
    put_u32(p + 0, 1)
    put_f32(p + 4, row[2])
    put_f32(p + 8, row[3])
    put_f32(p + 12, row[4])
    put_f32(p + 16, row[5])
end
-- Drive this instance through locate and apply: one pass to find the table, then
-- passes until every row reports applied or already-applied.
local function drive_until_settled(m, want)
    for _ = 1, 120 do
        m.update(0.5)
        local s = m.status()
        if s.located and (s.applied + s.already) == want and s.skipped == 0 then return s end
    end
    return m.status()
end
local settled = drive_until_settled(mod2, #data)
assert(settled.located, 'second instance did not locate the table')
assert(settled.applied + settled.already == #data,
    'second instance did not settle: ' .. tostring(settled.reason))
mod2.set_enabled(false)
for _, row in ipairs(data) do
    local p = table_base + row[1]
    assert(approx(get_f32(p + 8), row[3]), 'min_delay was not restored')
    assert(approx(get_f32(p + 12), row[4]), 'max_delay was not restored')
end
pass('disabling the switch restores the original decay delays')


-- Dynamic fallback: simulate a game update that rebuilt the table and moved every
-- fixed anchor. Move each record only a little so it stays inside the synthetic
-- region while every recorded offset now points at the neighbouring record's
-- fields; this is the "identity check cannot match any anchor" case seen in the
-- live log (applied=0 already=0 skipped=100).
local SHIFT = 4
for _, row in ipairs(data) do
    local p = table_base + row[1]
    ffi.copy(p + 4, ffi.new('uint8_t[4]', {0, 0, 0, 0}), 4)
    put_f32(p + 8, 0)
    put_f32(p + 12, 0)
end
for _, row in ipairs(data) do
    local p = table_base + row[1] + SHIFT
    put_u32(p + 0, 1)
    put_f32(p + 4, row[2])
    put_f32(p + 8, row[3])
    put_f32(p + 12, row[4])
    put_f32(p + 16, row[5])
    ffi.copy(p + 20, ffi.new('uint8_t[4]', {0, 0, 0, 0}), 4)
end
local mod3 = create_corpse(api, data, decayer_data)
local dynamic_ready = false
for _ = 1, 180 do
    mod3.update(0.5)
    local s = mod3.status()
    if s.mode == 'dynamic' and s.dynamic_cursor >= s.dynamic_size and s.dynamic_size > 0 then
        dynamic_ready = true
        break
    end
end
assert(dynamic_ready, 'dynamic scanner did not finish on the synthetic table')
local dst = mod3.status()
assert(dst.dynamic_candidates >= #data,
    'dynamic scanner found fewer records than the synthetic table: ' .. tostring(dst.dynamic_candidates))
assert(dst.applied + dst.already >= #data, 'dynamic scanner did not settle every record')
for _, row in ipairs(data) do
    local p = table_base + row[1] + SHIFT
    assert(approx(get_f32(p + 8), 5.0), 'dynamic min_delay not applied')
    assert(approx(get_f32(p + 12), 5.0), 'dynamic max_delay not applied')
    assert(approx(get_f32(p + 16), 10.0), 'dynamic decay float not applied')
end
pass('dynamic signature scan recovers records after fixed anchors move')

-- Turning the dynamic instance off restores every record it captured.
mod3.set_enabled(false)
for _, row in ipairs(data) do
    local p = table_base + row[1] + SHIFT
    assert(approx(get_f32(p + 8), row[3]), 'dynamic min_delay was not restored')
    assert(approx(get_f32(p + 12), row[4]), 'dynamic max_delay was not restored')
    assert(approx(get_f32(p + 16), row[5]), 'dynamic decay float was not restored')
end
pass('disabling the dynamic scanner restores the original decay delays')


-- The live log showed the scanner matching the MEM_MAPPED (0x40000) read-only
-- file image: candidates rose into the thousands while applied stayed at 0
-- because every write to a mapped page is refused. DeleteTheDead explicitly
-- requires the MEM_PRIVATE (0x20000) heap copy and keeps looking otherwise.
-- Place a mapped copy first in the address walk and confirm the scanner skips it
-- and still finds the private copy behind it.
local MAP_BASE, MAP_SIZE = 0x05000000, TABLE_SIZE
local REGION_BASE2, REGION_SIZE2 = 0x10000000, REGION_SIZE
local mapped_storage = ffi.new('uint8_t[?]', MAP_SIZE)
local mapped_base = ffi.cast('uint8_t *', mapped_storage)
ffi.copy(mapped_base, HEADER, #HEADER)
for _, row in ipairs(data) do
    local p = mapped_base + row[1]
    put_u32(p + 0, 1)
    put_f32(p + 4, row[2])
    put_f32(p + 8, row[3])
    put_f32(p + 12, row[4])
    put_f32(p + 16, row[5])
    ffi.copy(p + 20, ffi.new('uint8_t[4]', {0, 0, 0, 0}), 4)
end
-- Reset the private table to its recorded state so the mapped copy and the
-- private copy start out identical.
for _, row in ipairs(data) do
    local p = table_base + row[1]
    put_u32(p + 0, 1)
    put_f32(p + 4, row[2])
    put_f32(p + 8, row[3])
    put_f32(p + 12, row[4])
    put_f32(p + 16, row[5])
    ffi.copy(p + 20, ffi.new('uint8_t[4]', {0, 0, 0, 0}), 4)
end

-- A realistic contiguous address-space model: each VirtualQuery returns the
-- region containing the queried address, and the gaps are single large regions
-- that the walk can skip in one step.
local function mixed_query(address)
    if type(address) ~= 'number' then return nil end
    if address < MAP_BASE then
        return address, MAP_BASE - address, 0x1000, 0x04, 0x20000
    end
    if address < MAP_BASE + MAP_SIZE then
        return MAP_BASE, MAP_SIZE, 0x1000, 0x02, 0x40000   -- MEM_MAPPED, read-only
    end
    if address < REGION_BASE2 then
        return address, REGION_BASE2 - address, 0x1000, 0x04, 0x20000
    end
    if address < REGION_BASE2 + REGION_SIZE2 then
        return REGION_BASE2, REGION_SIZE2, 0x1000, 0x04, 0x20000
    end
    return nil
end
local mixed_api = {}
for k, v in pairs(api) do mixed_api[k] = v end
mixed_api.query_region = mixed_query
mixed_api.read = function(address, size)
    local a = tonumber(ffi.cast('uintptr_t', address))
    if a >= MAP_BASE and a + size <= MAP_BASE + MAP_SIZE then
        return ffi.string(mapped_base + (a - MAP_BASE), size)
    end
    if a >= REGION_BASE2 and a + size <= REGION_BASE2 + REGION_SIZE2 then
        return ffi.string(table_base + (a - REGION_BASE2), size)
    end
    return nil
end
mixed_api.write = function(address, bytes)
    local a = tonumber(ffi.cast('uintptr_t', address))
    -- A mapped page must never be written; fail the test if it ever is.
    if a >= MAP_BASE and a + #bytes <= MAP_BASE + MAP_SIZE then
        error('attempted to write to the mapped file image')
    end
    if not (a >= REGION_BASE2 and a + #bytes <= REGION_BASE2 + REGION_SIZE2) then return false end
    ffi.copy(table_base + (a - REGION_BASE2), bytes, #bytes)
    return true
end
mixed_api.writable_data = function(address, size)
    local a = tonumber(ffi.cast('uintptr_t', address))
    if a >= MAP_BASE and a + size <= MAP_BASE + MAP_SIZE then return false end
    return a >= REGION_BASE2 and a + size <= REGION_BASE2 + REGION_SIZE2
end
mixed_api.writable_decay = mixed_api.writable_data
mixed_api.write_decay = mixed_api.write

local mod4 = create_corpse(mixed_api, data, decayer_data)
local mixed_ready = false
for _ = 1, 400 do
    mod4.update(0.5)
    local s = mod4.status()
    -- The private copy may be reached by the fixed anchors (mode=seed) or by the
    -- signature scan (mode=dynamic); either way every record must be accounted
    -- for with no skips, and no write may touch the mapped image.
    if s.located and s.skipped == 0 and (s.applied + s.already) >= #data then
        mixed_ready = true
        break
    end
end
local mst = mod4.status()
assert(mixed_ready, 'scanner did not settle on the private copy: ' .. tostring(mst.reason))
assert(mst.mapped_headers >= 1, 'the mapped copy was never noticed')
for _, row in ipairs(data) do
    local p = table_base + row[1]
    assert(approx(get_f32(p + 8), 5.0), 'private min_delay not applied')
    assert(approx(get_f32(p + 16), 10.0), 'private decay float not applied')
end
-- The mapped image must be untouched: it still holds the original delays.
for _, row in ipairs(data) do
    local p = mapped_base + row[1]
    assert(approx(get_f32(p + 8), row[3]), 'mapped image min_delay was modified')
    assert(approx(get_f32(p + 16), row[5]), 'mapped image decay float was modified')
end
pass('scanner skips the mapped file image and uses the private heap copy')


-- CorpseDecayerComponent: the eligibility radius must be raised from 1/3 to 300.
-- Reset the table to its recorded state first.
for _, row in ipairs(decayer_data) do
    local p = table_base + row[1]
    put_f32(p + 0, row[2])
    put_u32(p + 4, row[3])
end
local dmod = create_corpse(api, data, decayer_data)
local decayer_settled = false
for _ = 1, 200 do
    dmod.update(0.5)
    local s = dmod.status()
    if s.decayer_applied + s.decayer_already >= #decayer_data then
        decayer_settled = true
        break
    end
end
local dst = dmod.status()
assert(decayer_settled, 'decayer records were not settled: ' .. tostring(dst.reason))
assert(dst.decayer_skipped == 0, 'decayer records must not be skipped: ' .. tostring(dst.reason))
for _, row in ipairs(decayer_data) do
    local p = table_base + row[1]
    assert(approx(get_f32(p + 0), 300.0), 'decayer radius not raised to 300')
    -- The node hash must be left untouched.
    local node = 0
    for i = 0, 3 do node = node + string.byte(ffi.string(p + 4 + i, 1)) * 256 ^ i end
    assert(node == row[3], 'decayer node hash must not change')
end
pass('raises CorpseDecayerComponent radius to 300 for every record')

dmod.set_enabled(false)
for _, row in ipairs(decayer_data) do
    local p = table_base + row[1]
    assert(approx(get_f32(p + 0), row[2]), 'decayer radius was not restored')
end
pass('disabling the switch restores the original decayer radius')

print(count .. ' corpse decay checks passed; no game process involved.')
