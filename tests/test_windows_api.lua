-- Real Win32 API checks for the numeric-address contract used by the corpse
-- scanner. LuaJIT will not implicitly convert a Lua number to a pointer, so this
-- must stay an explicit cast; the in-game failure was VirtualQuery receiving a
-- number and aborting the scanner on its first pass.
local source = assert(arg[1])
local ffi = require('ffi')
local create_api = assert(loadfile(source .. '/windows_api.lua'))()

local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end

local api = create_api()
local block = assert(api.alloc_private(64), 'private allocation failed')
local address = tonumber(ffi.cast('uintptr_t', block))
local base, size, state, protection, region_type = api.query_region(address)
assert(type(base) == 'number' and type(size) == 'number')
assert(state == 0x1000 and protection == 4 and region_type == 0x20000)
assert(address >= base and address < base + size)
pass('query_region accepts a plain numeric address')

assert(api.cast_uint8(address) ~= nil)
assert(api.writable_data(address, 16) == true)
local bytes = api.encode_f32(0.1)
assert(api.write(address + 8, bytes))
assert(api.read(address + 8, 4) == bytes)
pass('numeric-address read/write and writable_data remain valid')

-- Decay-specific write surface: accepts a MEM_PRIVATE data page even when it is
-- not PAGE_READWRITE, flips it only for the write, and restores it afterwards.
local decay_block = assert(api.alloc_private(64), 'decay allocation failed')
local decay_address = tonumber(ffi.cast('uintptr_t', decay_block))
local decay_prot = api.decay_protection(decay_address, 16)
assert(decay_prot == 0x04, 'fresh private allocation should be read-write')
assert(api.writable_decay(decay_address, 16) == true)
local decay_bytes = api.encode_f32(10.0)
assert(api.write_decay(decay_address + 8, decay_bytes))
assert(api.read(decay_address + 8, 4) == decay_bytes)
pass('writable_decay accepts a private data page and write_decay lands the value')

-- Only MEM_PRIVATE data pages may be accepted. The executable image (MEM_IMAGE)
-- and a null address must both be rejected.
assert(api.writable_decay(0, 4) == false, 'a null address must be rejected')
local exe_base = tonumber(ffi.cast('uintptr_t', api.module(nil)))
assert(exe_base and exe_base > 0, 'the host module base must resolve')
assert(api.writable_decay(exe_base, 4) == false,
    'a mapped module image must never be writable_decay')
pass('writable_decay rejects null and module-image addresses')

print(count .. ' Windows API checks passed; no game process involved.')
