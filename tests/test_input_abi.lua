-- Replay the production declarations in an isolated Lua VM. No window or real
-- keyboard/mouse API call is needed: a private callback supplies return bits.
local source = assert(arg[1])
local order = assert(arg[2])
local ffi = require('ffi')
local bit = require('bit')
local file = assert(io.open(source .. '/panel.lua', 'rb'))
local panel = file:read('*a')
file:close()

local peer = 'int16_t GetAsyncKeyState(int key);'
if order == 'peer-first' then
    ffi.cdef(peer)
elseif order == 'legacy-peer-first' then
    ffi.cdef('int32_t GetAsyncKeyState(int key);')
else
    assert(order == 'panel-first')
end
local declarations = 0
for block in panel:gmatch('ffi%.cdef%s*%[%[(.-)%]%]') do
    ffi.cdef(block)
    declarations = declarations + 1
end
assert(declarations == 2, 'expected both production panel declaration blocks')
ffi.cdef(peer)

-- Derive the callable pointer type from the shared export declaration itself.
-- Resolving the address does not poll user input or call the native export.
local library = ffi.load('user32')
local shared_type = ffi.typeof('$ *', ffi.typeof(library.GetAsyncKeyState))
local correct_type = ffi.typeof('int16_t (*)(int32_t)')

local sample = 0
local raw = ffi.cast('int32_t (*)(int32_t)', function(key)
    assert(key == 1 or key == 0x77, 'unexpected mouse/F8 virtual key')
    return sample >= 0x80000000 and sample - 0x100000000 or sample
end)
local shared = ffi.cast(shared_type, raw)
local private = ffi.cast('ESP_GetAsyncKeyState_t', raw)
local pressed = {0x8000, 0x8001, 0xffff8000, 0xffff8001,
                 0x12348000, 0x56788000, 0x98768000, 0xabcd8001}
local released = {0, 1, 0x12340000, 0x98760000}
local shared_passed, private_passed, total = 0, 0, 0
for _, up in ipairs(released) do
    for _, down in ipairs(pressed) do
        sample = up
        local shared_up = shared(1) >= 0
        local private_up = bit.band(private(0x77), 0x8000) == 0
        sample = down
        local shared_down = shared(1) < 0
        local private_down = bit.band(private(0x77), 0x8000) ~= 0
        if shared_up and shared_down then shared_passed = shared_passed + 1 end
        if private_up and private_down then private_passed = private_passed + 1 end
        total = total + 1
    end
end
raw:free()
print(string.format('Input ABI %s shared=%d/%d private=%d/%d',
    order, shared_passed, total, private_passed, total))
assert(private_passed == total, 'private F8 binding misread the pressed bit')
if order == 'legacy-peer-first' then
    assert(shared_passed < total, 'fixture did not reproduce a prior wrong declaration')
else
    assert(shared_passed == total, 'unchanged peer signed input check dropped clicks')
end
if order ~= 'legacy-peer-first' then
    assert(tostring(shared_type) == tostring(correct_type),
        'panel polluted shared GetAsyncKeyState: ' .. tostring(shared_type))
end
assert(tostring(ffi.typeof('ESP_GetAsyncKeyState_t')) == tostring(correct_type),
    'panel private input pointer must also return signed 16-bit SHORT')
print(string.format('PASS: input ABI %s shared=%d/%d private=%d/%d; no native input called',
    order, shared_passed, total, private_passed, total))
