local source = assert(arg[1])
local create = assert(loadfile(source .. '/peer_probe.lua'))()
local probe = create()
local count = 0
local function pass(name)
    count = count + 1
    print('PASS: ' .. name)
end

assert(probe.find_build(1790161983, 74727424) ~= nil)
assert(probe.find_build(1, 2) == nil)
pass('known build row is present')

local ffi = require('ffi')
local function pack32(value)
    return ffi.string(ffi.new('uint32_t[1]', value), 4)
end
local function pack64(value)
    return ffi.string(ffi.new('uint64_t[1]', value), 8)
end

local game, ctx = 0x10000000, 0x22000000
local layout = probe.find_build(1790161983, 74727424)
local memory = {
    [game] = 'MZ' .. string.rep('\0', 58) .. pack32(128),
    [game + 128] = 'PE\0\0' .. string.rep('\0', 4) .. pack32(layout.stamp)
        .. string.rep('\0', 68) .. pack32(layout.image) .. string.rep('\0', 4),
    [game + layout.ctx_off] = pack64(ctx),
    [ctx + layout.peer_count_at] = pack32(1),
}
local api = {
    read = function(address, size)
        local bytes = memory[address]
        return bytes and #bytes == size and bytes or nil
    end,
    pointer = function(bytes)
        if not bytes or #bytes ~= 8 then return nil end
        local value = ffi.new('uint64_t[1]')
        ffi.copy(value, bytes, 8)
        return tonumber(value[0])
    end,
}

local session = probe.create(api)
local n, detail = session.probe(game)
assert(n == 1 and session.solo == true and session.build == 'ok')
assert(detail:find('count=1', 1, true))
pass('solo peer count reads as 1')

memory[ctx + layout.peer_count_at] = pack32(3)
n = session.probe(game)
assert(n == 3 and session.solo == false)
pass('multiplayer peer count reads as non-solo')

memory[ctx + layout.peer_count_at] = pack32(0)
n = session.probe(game)
assert(n == nil and session.solo == false and session.count == nil)
pass('invalid count fails closed to non-solo')

memory[game + layout.ctx_off] = pack64(0)
local broken = probe.create(api)
memory[game + layout.ctx_off] = pack64(ctx)
memory[ctx + layout.peer_count_at] = pack32(1)
-- mismatch PE stamp
memory[game + 128] = 'PE\0\0' .. string.rep('\0', 4) .. pack32(1)
    .. string.rep('\0', 68) .. pack32(2) .. string.rep('\0', 4)
local bad = probe.create(api)
assert(bad.probe(game) == nil and bad.build == 'mismatch' and bad.solo == false)
pass('unknown PE build fails closed to non-solo')

print(string.format('peer_probe: %d checks passed', count))
