-- Anchor probe checks.
--
-- The probe replaces the build-hash gate, so it must accept a healthy layout and
-- reject one whose pinned slots have clearly moved. It reads data only.
local source = assert(arg[1])
local create_anchors = assert(loadfile(source .. '/anchor_check.lua'))()

local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end

local function patch()
    return {
        mode_rva = 0x1000, director_rva = 0x2000, time_rva = 0x3000,
        resource_manager_rva = 0x4000, cfg_stride = 0x43C,
    }
end

-- A minimal api: the probe only needs read, pointer, distance.
local function make_api(values)
    local api = {}
    function api.read(address, size)
        local key = address
        if values[key] == nil then return nil end
        return values[key](size)
    end
    function api.pointer(bytes, offset)
        if not bytes or #bytes < 8 then return nil end
        local v = 0
        for i = 1, 8 do v = v + bytes:byte(i) * 2 ^ (8 * (i - 1)) end
        if v < 0x10000 or v >= 2 ^ 47 then return nil end
        return {address = v}
    end
    function api.distance(a, b)
        local aa = type(a) == 'table' and a.address or a
        local bb = type(b) == 'table' and b.address or b
        return aa - bb
    end
    return api
end

local GAME = 0x100000

-- Healthy: null slots (still on the ship) are acceptable.
local nulls = {[GAME+0x1000]=function() return string.rep('\0',8) end,
               [GAME+0x2000]=function() return string.rep('\0',8) end,
               [GAME+0x3000]=function() return string.rep('\0',8) end,
               [GAME+0x4000]=function() return string.rep('\0',8) end}
local anchors = create_anchors(patch())
local ok, failed = anchors.run(make_api(nulls), GAME)
assert(ok == true and failed == 0, 'null slots must be accepted')
pass('anchor probe accepts uninitialised (null) slots')

-- Healthy: real-looking pointers.
local function ptr_bytes(v)
    local b = {}
    for i = 1, 8 do b[i] = string.char(math.floor(v / 2^(8*(i-1))) % 256) end
    return table.concat(b)
end
local live = {[GAME+0x1000]=function() return ptr_bytes(0x200000) end,
              [GAME+0x2000]=function() return ptr_bytes(0x300000) end,
              [GAME+0x3000]=function() return ptr_bytes(0x400000) end,
              [GAME+0x4000]=function() return ptr_bytes(0x500000) end}
anchors = create_anchors(patch())
ok, failed = anchors.run(make_api(live), GAME)
assert(ok == true and failed == 0, 'valid pointers must be accepted')
pass('anchor probe accepts plausible pointers')

-- Broken: unreadable slot.
local broken = {[GAME+0x2000]=function() return nil end}
anchors = create_anchors(patch())
ok, failed = anchors.run(make_api(broken), GAME)
assert(ok == false and failed >= 1, 'an unreadable slot must be reported')
pass('anchor probe reports an unreadable slot')

-- Broken: garbage that is not a plausible pointer.
local garbage = {}
for _, off in ipairs({0x1000,0x2000,0x3000,0x4000}) do
    garbage[GAME+off] = function() return string.rep('\255', 8) end
end
anchors = create_anchors(patch())
ok, failed = anchors.run(make_api(garbage), GAME)
assert(ok == false and failed >= 1, 'garbage pointer slots must be reported')
pass('anchor probe reports implausible pointers')

-- The stride sanity check must reject a nonsense record size.
anchors = create_anchors({mode_rva=0x1000, director_rva=0x2000, time_rva=0x3000,
                          resource_manager_rva=0x4000, cfg_stride = 0x10})
ok, failed = anchors.run(make_api(nulls), GAME)
assert(ok == false, 'an implausible cfg stride must fail')
assert(anchors.summary():find('stride=', 1, true) ~= nil)
pass('anchor probe rejects an implausible config stride')

-- The summary must name every probe so a log line is actionable.
anchors = create_anchors(patch())
anchors.run(make_api(live), GAME)
local s = anchors.summary()
for _, name in ipairs({'mode', 'director', 'time', 'resource', 'stride'}) do
    assert(s:find(name, 1, true), 'summary is missing ' .. name)
end
pass('anchor summary names every probe')

print(count .. ' anchor probe checks passed; read-only, no game access.')
