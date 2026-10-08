-- Synthetic private memory only. No UI, game attachment or native spawn call.
local source = assert(arg[1])
local ffi = require('ffi')
local factory = assert(loadfile(source .. '/enemy_filter.lua'))()
local checks = 0
local function pass(name) checks = checks + 1; print('PASS: ' .. name) end
local function ptrbytes(p) return ffi.string(ffi.new('uint8_t *[1]', p), 8) end
local function put(p, value) ffi.copy(p, ffi.new('uint32_t[1]', value), 4) end
local function value(p) return tonumber(ffi.cast('uint32_t *', p)[0]) end
local function binary(hex) return (hex:gsub('..', function(s) return string.char(tonumber(s, 16)) end)) end
local MARKER = 0xC323A525
-- Independently matched resource identities in the live 45-row snapshot.
local SPECIES = {
    {137310222, 'd98f5e6f5938b4aa', MARKER}, -- Pouncer
    {3517152816, 'cae174d5e2030e3d', 0},    -- Hunter tier 1
    {3517152816, 'bac045744432a85c', 0},    -- Hunter tier 2
    {333947844, 'e004009c72910a1f', 0xA3A3DB9F}, -- Spore Burst Hunter
    {1837263553, '9b0872d1fd2270cc', 0},    -- Nursing Spewer
    {2255668545, '4601e6e5cc99aa36', 0xDF4CB4E5}, -- Bile Spewer tier 1
    {2255668545, 'b791d5ac6452aecc', 0xDF4CB4E5}, -- Bile Spewer tier 2
    {839087686, '0102030405060708', 0},     -- Bile Titan, NOT Bile Spewer
    {1610950166, '0202030405060708', 0},    -- other family, NOT Nursing Spewer
    {2478129961, 'b96be4a113e339be', 0}, -- ordinary Warrior, low difficulty
    {2478129961, 'dc9c7cecc41f5432', 0}, -- ordinary Warrior, high difficulty
    {96305411, '3ddbd6ce493ea872', 0}, -- small Bile Spitter, NOT either Spewer
}
local CODE = {
    [0x9531FE] = binary('488d5758498d8dd4180500e8b2b1e20084c07426'),
    [0x949BF9] = binary('498b4008'), [0x86950C] = binary('488b4008'),
}
local SCAVENGERS = {
    {3478611010, '4e7e99f66ba8ee51', 0},
    {3478611010, '0c237b28ae3a8a9a', 0},
}
local SMALL_VARIANTS = {
    {1428114468, '01f51cbe314696db', 0}, -- Spore Burst Scavenger
    {2519355991, 'dd35245088000964', 0}, -- Shrieker guard/flying source
    {4197606685, 'dd35245088000964', 0}, -- second Shrieker family
}
local function simulation(readonly, with_swap_sources, with_small_variants)
    local species = SPECIES
    if with_swap_sources then
        species = {}
        for _, item in ipairs(SPECIES) do species[#species + 1] = item end
        for _, item in ipairs(SCAVENGERS) do species[#species + 1] = item end
        if with_small_variants then
            for _, item in ipairs(SMALL_VARIANTS) do species[#species + 1] = item end
        end
    end
    local s = {regions = {}, writes = 0, reads = 0, allocations = 0, readonly = readonly,
               readable = true, proofs = true, fail_write = false}
    local function allocate(size, immutable)
        local storage = ffi.new('uint8_t[?]', size)
        local p = storage + 0
        s.regions[#s.regions + 1] = {storage = storage, p = p, size = size, immutable = immutable}
        return p
    end
    s.mode, s.entity, s.director = allocate(0x44), allocate(24), allocate(0x51918)
    s.header, s.original_rows = allocate(0xB0), allocate(#species * 128, readonly)
    s.tag_hashes = allocate(128)
    put(s.tag_hashes + 8, 0xDF4CB4E5); put(s.tag_hashes + 16, MARKER); put(s.tag_hashes + 40, 0xA3A3DB9F)
    s.game = ffi.cast('uint8_t *', 0x10000000)
    put(s.mode + 8, 1); put(s.mode + 0x40, 1)
    ffi.copy(s.mode + 0x38, ptrbytes(s.entity), 8)
    put(s.entity + 8, 0x1234); put(s.entity + 0x14, 1)
    put(s.director + 0x518C4, 1)
    put(s.director + 0x518D4, MARKER)
    put(s.director + 0x518D8, 0xDF4CB4E5)
    put(s.director + 0x518DC, 0xA3A3DB9F)
    put(s.director + 0x51914, 3)
    ffi.copy(s.director + 0x660, ptrbytes(s.header), 8)
    ffi.copy(s.header, ptrbytes(s.original_rows), 8); put(s.header + 8, #species)
    -- Native override metadata must survive a read-only table clone.
    ffi.fill(s.header + 0x10, 0xA0, 0x5A)
    for index, item in ipairs(species) do
        local r = s.original_rows + (index - 1) * 128
        put(r, item[1]); ffi.copy(r + 8, binary(item[2]), 8)
        put(r + 0x10, index); put(r + 0x18, 0)
        for d = 0, 9 do ffi.cast('float *', r + 0x30 + d * 4)[0] = 1 end
        put(r + 0x58, item[3])
        if index == 10 or index == 11 then
            for d = 0, 9 do ffi.cast('float *', r + 0x30 + d * 4)[0] = (index == 10 and d < 3 or index == 11 and d >= 3) and 1 or 0 end
        end
    end
    s.before = ffi.string(s.original_rows, #species * 128)
    local function region(address, size)
        for _, r in ipairs(s.regions) do
            local offset = tonumber(ffi.cast('intptr_t', address) - ffi.cast('intptr_t', r.p))
            if offset >= 0 and offset + size <= r.size then return r end
        end
    end
    local api = {}
    function api.read(address, size)
        s.reads = s.reads + 1
        if not s.readable then return nil end
        if address == s.game + 0x33266A0 then return ptrbytes(s.mode) end
        if address == s.game + 0x3326D10 then return ptrbytes(s.director) end
        if address == s.game + 0x21E1920 then
            if s.on_read then s.on_read(address, size) end
            return ffi.string(s.tag_hashes, size)
        end
        for rva, code in pairs(CODE) do
            if address == s.game + rva then return s.proofs and code or string.rep('\0', size) end
        end
        if not region(address, size) then return nil end
        if s.on_read then s.on_read(address, size) end
        return ffi.string(address, size)
    end
    function api.pointer(text, offset)
        offset = offset or 0
        if not text or #text < offset + 8 then return nil end
        local p = ffi.new('uint8_t *[1]')
        ffi.copy(p, text:sub(offset + 1, offset + 8), 8)
        return p[0] ~= nil and p[0] or nil
    end
    function api.distance(a, b) return tonumber(ffi.cast('intptr_t', a) - ffi.cast('intptr_t', b)) end
    function api.writable_data(p, size)
        local r = region(p, size)
        return r ~= nil and not r.immutable and not s.unwritable
    end
    function api.write(p, text)
        if not api.writable_data(p, #text) then return false end
        s.writes = s.writes + 1
        if s.fail_write then return false end
        ffi.copy(p, text, s.partial_write and math.floor(#text / 2) or #text)
        if s.on_write then s.on_write(p, text) end
        return not s.partial_write
    end
    function api.alloc_private(size)
        s.allocations = s.allocations + 1
        if s.fail_alloc then return nil end
        return allocate(size)
    end
    s.mod = factory(api, s.game)
    function s.rows()
        local h = api.pointer(ffi.string(s.director + 0x660, 8))
        return api.pointer(ffi.string(h, 8)), h
    end
    function s.row(i) return s.rows() + (i - 1) * 128 end
    function s.resource(i) return ffi.string(s.row(i) + 8, 8) end
    function s.blocked(i) return (i <= 7 or i == 12) and (s.resource(i) == binary(SPECIES[10][2]) or s.resource(i) == binary(SPECIES[11][2])) end
    function s.exact() return ffi.string(s.rows(), #s.before) == s.before end
    function s.set(settings, allowed) assert(s.mod.configure(settings)); assert(s.mod.update(allowed)) end
    return s
end
-- Reference port of the observed native 0x177E3C0 predicate, independently of
-- the replacement module. Eligibility must remain exactly native.
local function eligible(row, active_tags)
    for n = 0, 3 do
        local excluded = value(row + 0x68 + 4 * n)
        if excluded == 0 then break end
        if active_tags[excluded] then return false end
    end
    for n = 0, 3 do
        local required = value(row + 0x58 + 4 * n)
        if required == 0 then break end
        if not active_tags[required] then return false end
    end
    return true
end
do
    local s = simulation()
    assert(s.mod.update() and s.reads == 0 and s.writes == 0 and s.allocations == 0)
    pass('default-off filtering performs no native reads, writes or allocations')
end
do
    local s = simulation()
    s.set({block_jumpers = true})
    for i = 1, 4 do assert(s.blocked(i)) end
    for i = 5, #SPECIES do assert(not s.blocked(i)) end
    local writes = s.writes
    assert(s.mod.update() and s.writes == writes)
    s.set({block_jumpers = false})
    assert(s.exact())
    pass('jumpers include Pouncer, both Hunter tiers and Spore Burst Hunter; repeated ticks do not stack')
end
do
    local s = simulation()
    s.set({block_yellow_spewers = true})
    for i = 1, #SPECIES do assert(s.blocked(i) == (i == 5)) end
    s.set({block_yellow_spewers = false, block_green_spewers = true})
    for i = 1, #SPECIES do assert(s.blocked(i) == (i == 6 or i == 7)) end
    s.set({block_green_spewers = false})
    assert(s.exact())
    pass('yellow and green target the verified unit resources, independently, and restore exactly')
end
do
    local s = simulation()
    s.set({block_bile_spitters = true})
    assert(s.blocked(12) and s.mod.status().blocked == 1)
    for i = 1, 11 do assert(not s.blocked(i)) end
    local actual = ffi.string(s.rows(), #s.before)
    for offset = 0, #actual - 1 do
        if not (offset >= 11 * 128 + 8 and offset < 11 * 128 + 16) then
            assert(actual:byte(offset + 1) == s.before:byte(offset + 1))
        end
    end
    put(s.director + 0x518C4, 10)
    assert(s.mod.update() and s.resource(12) == binary(SPECIES[11][2]))
    s.set({block_jumpers = true, block_yellow_spewers = true, block_green_spewers = true})
    assert(s.mod.status().blocked == 8)
    s.set({block_bile_spitters = false})
    assert(s.resource(12) == binary(SPECIES[12][2]) and s.mod.status().blocked == 7)
    for i = 1, 7 do assert(s.blocked(i)) end
    s.set({block_jumpers = false, block_yellow_spewers = false, block_green_spewers = false})
    assert(s.exact())
    pass('Bile Spitters alone change only their resource; difficulty changes and unchecking preserve the other three exclusions')
end
do
    local s = simulation()
    s.set({block_bile_spitters = true, block_yellow_spewers = true})
    local spitter, spewer = ffi.string(s.row(12), 128), ffi.string(s.row(5), 128)
    ffi.copy(s.row(12), spewer, 128); ffi.copy(s.row(5), spitter, 128)
    s.set({block_bile_spitters = false})
    assert(s.resource(5) == binary(SPECIES[12][2]) and s.blocked(12))
    s.set({block_yellow_spewers = false})
    assert(ffi.string(s.row(5), 128) == s.before:sub(1409, 1536))
    assert(ffi.string(s.row(12), 128) == s.before:sub(513, 640))
    pass('Bile Spitter restoration follows its row identity when the native table is reordered')
end
do
    local s = simulation()
    s.set({block_jumpers = true, block_yellow_spewers = true, block_green_spewers = true})
    for i = 1, 7 do
        local original = ffi.new('uint8_t[128]')
        ffi.copy(original, s.before:sub((i - 1) * 128 + 1, i * 128), 128)
        assert(eligible(s.row(i), {}) == eligible(original, {}))
        assert(eligible(s.row(i), {[MARKER] = true, [0xDF4CB4E5] = true, [0xA3A3DB9F] = true}))
        assert(s.resource(i) == binary(SPECIES[10][2]))
        assert(value(s.row(i) + 0x18) == 0)
    end
    assert(eligible(s.row(8), {}) and eligible(s.row(9), {}))
    local actual = ffi.string(s.rows(), #s.before)
    for offset = 0, #actual - 1 do
        local field = offset % 128
        if not (offset < 7 * 128 and (field >= 8 and field < 16)) then
            assert(actual:byte(offset + 1) == s.before:byte(offset + 1))
        end
    end
    s.set({block_jumpers = false})
    assert(not s.blocked(1) and not s.blocked(4) and s.blocked(5) and s.blocked(7))
    s.set({block_yellow_spewers = false, block_green_spewers = false})
    assert(s.exact())
    pass('valid Warrior resources replace targets while native eligibility, costs, tags, counters and other species stay intact')
end
do
    local s = simulation(true)
    s.set({block_jumpers = true, block_yellow_spewers = true, block_green_spewers = true, block_bile_spitters = true})
    local rows, header = s.rows()
    assert(rows ~= s.original_rows and s.allocations == 1)
    assert(ffi.string(s.original_rows, #s.before) == s.before)
    assert(ffi.string(header + 0x10, 0xA0) == string.rep(string.char(0x5A), 0xA0))
    assert(s.mod.status().blocked == 8 and s.blocked(12))
    s.set({block_jumpers = false, block_yellow_spewers = false, block_green_spewers = false, block_bile_spitters = false})
    assert(s.exact() and s.allocations == 1)
    pass('read-only resources are copied with the entire 0xB0 header; native originals and override metadata survive')
end
do
    local s = simulation()
    s.set({block_jumpers = true})
    assert(s.mod.update(false) and s.exact())
    local writes = s.writes
    assert(s.mod.update(false) and s.writes == writes)
    assert(s.mod.update(true) and s.blocked(1))
    pass('the public privacy gate restores owned fields and prevents new exclusions')
end
do
    local s = simulation()
    put(s.entity + 0x14, 0)
    s.set({block_jumpers = true})
    assert(s.writes == 0 and s.mod.status().reason == 'enemy_filter_host_only')
    put(s.entity + 0x14, 1); assert(s.mod.update() and s.blocked(1))
    put(s.entity + 0x14, 0)
    local writes = s.writes
    s.set({block_jumpers = false})
    assert(s.writes == writes)
    put(s.entity + 0x14, 1); assert(s.mod.update() and s.exact())
    pass('joining another host never writes; authority loss does not discard restoration baselines')
end
do
    local s = simulation()
    s.set({block_jumpers = true})
    put(s.mode + 8, 0); assert(s.mod.update())
    put(s.entity + 8, 0x5678); put(s.mode + 8, 1)
    s.set({block_jumpers = false})
    assert(s.exact())
    pass('ship/mission transitions preserve restoration when the engine reuses modified tables')
end
do
    local s = simulation()
    s.set({block_jumpers = true, block_yellow_spewers = true})
    local first, second = ffi.string(s.row(1), 128), ffi.string(s.row(5), 128)
    ffi.copy(s.row(1), second, 128); ffi.copy(s.row(5), first, 128)
    s.set({block_jumpers = false, block_yellow_spewers = false})
    assert(ffi.string(s.row(1), 128) == s.before:sub(513, 640))
    assert(ffi.string(s.row(5), 128) == s.before:sub(1, 128))
    pass('restoration follows full resource/variant identity after row reordering')
end
do
    local s = simulation()
    s.set({block_yellow_spewers = true})
    ffi.copy(s.row(5) + 8, binary(SPECIES[2][2]), 8)
    assert(s.mod.update() and s.blocked(5))
    s.set({block_yellow_spewers = false})
    assert(s.resource(5) == binary(SPECIES[2][2]))
    pass('a native resource refresh becomes the new restoration baseline')
end
do
    local s = simulation(true)
    s.on_write = function(p)
        if p == s.director + 0x660 then put(s.entity + 0x14, 0) end
    end
    s.set({block_jumpers = true, block_yellow_spewers = true, block_green_spewers = true})
    s.on_write = nil; put(s.entity + 0x14, 1)
    s.set({block_jumpers = false, block_yellow_spewers = false, block_green_spewers = false})
    assert(s.exact())
    pass('an interrupted clone publication retains every baseline, including rows not yet visited')
end
do
    local s = simulation()
    s.partial_write = true; s.set({block_green_spewers = true})
    assert(s.mod.status().reason == 'enemy_filter_write_failed' and s.exact())
    s.partial_write = false
    assert(s.mod.update() and s.blocked(6) and s.blocked(7))
    s.set({block_green_spewers = false}); assert(s.exact())
    pass('a partial resource write is rolled back and can subsequently recover/restore')
end
do
    local s = simulation()
    s.proofs = false; s.set({block_jumpers = true})
    assert(s.writes == 0 and s.allocations == 0 and s.mod.status().reason == 'enemy_filter_unsupported_selector')
    local t = simulation(true)
    t.fail_alloc = true; t.set({block_jumpers = true})
    assert(t.writes == 0 and t.exact())
    pass('unsupported native code and allocation failure leave native spawn data untouched')
end
do
    local s = simulation()
    s.on_read = function(p, size)
        if p == s.rows() and size == #s.before then put(s.entity + 8, value(s.entity + 8) + 1) end
    end
    s.set({block_jumpers = true})
    assert(s.writes == 0 and s.mod.status().reason == 'enemy_filter_waiting_for_stable_table')
    local t = simulation()
    t.readable = false; t.set({block_jumpers = true}); assert(t.writes == 0)
    t.readable = true; assert(t.mod.update() and t.blocked(1))
    pass('identity races and unreadable memory postpone writes instead of using stale pointers')
end
do
    local s = simulation()
    assert(not s.mod.configure({block_jumpers = true, block_green_spewers = 1}))
    assert(not s.mod.block_jumpers and s.writes == 0)
    assert(not s.mod.configure({block_jumpers = true, block_bile_spitters = 'true'}))
    assert(not s.mod.block_jumpers and not s.mod.block_bile_spitters and s.writes == 0)
    pass('invalid mixed profiles fail before any settings or memory change')
end

do
    local s = simulation()
    s.set({block_jumpers = true})
    put(s.director + 0x518C4, 6)
    assert(s.mod.update() and s.resource(1) == binary(SPECIES[11][2]))
    put(s.row(1) + 0x18, 40) -- existing core cap scaler owns this field
    s.set({block_jumpers = false})
    assert(s.resource(1) == binary(SPECIES[1][2]) and value(s.row(1) + 0x18) == 40)
    local t = simulation()
    ffi.copy(t.row(10) + 8, binary(SPECIES[1][2]), 8)
    ffi.copy(t.row(11) + 8, binary(SPECIES[1][2]), 8)
    t.set({block_jumpers = true})
    assert(t.writes == 0 and t.mod.status().reason == 'enemy_filter_no_valid_warrior')
    pass('difficulty selects the ordinary Warrior tier, cap scaling preserves restoration, and invalid fallbacks do not write')
end
do
    local s = simulation()
    s.set({block_jumpers = true})
    put(s.director + 0x518C4, 6); s.fail_write = true
    assert(s.mod.update() and s.mod.status().reason == 'enemy_filter_write_failed')
    assert(s.mod.update() and s.mod.status().reason == 'enemy_filter_write_failed')
    s.fail_write = false; s.set({block_jumpers = false})
    assert(s.exact())
    pass('failed replacement-tier changes retain the original resources for immediate uncheck/restoration')
end
local function mission_tags(s, difficulty, tags)
    put(s.director + 0x518C4, difficulty)
    ffi.fill(s.director + 0x518D4, 68)
    for i, tag in ipairs(tags) do put(s.director + 0x518D4 + (i - 1) * 4, tag) end
    put(s.director + 0x51914, #tags)
end
local function source_resources(s, expected)
    for i = 13, 14 do assert(s.resource(i) == binary(expected and SPECIES[11][2] or SCAVENGERS[i - 12][2])) end
end
do
    local s = simulation(false, true)
    mission_tags(s, 10, {MARKER})
    s.set({block_jumpers = true})
    source_resources(s, true)
    assert(s.mod.status().blocked == 6 and s.mod.status().source_swaps == 2)
    local writes = s.writes; assert(s.mod.update() and s.writes == writes)
    local actual = ffi.string(s.rows(), #s.before)
    for offset = 0, #actual - 1 do
        local index, field = math.floor(offset / 128) + 1, offset % 128
        if not ((index <= 4 or index >= 13) and field >= 8 and field < 16) then
            assert(actual:byte(offset + 1) == s.before:byte(offset + 1))
        end
    end
    s.set({block_jumpers = false}); assert(s.exact())
    pass('difficulty-10 Pouncer mission redirects both Scavenger sources to Warriors and restores every byte')
end
do
    local s = simulation(false, true)
    mission_tags(s, 1, {MARKER}); s.set({block_jumpers = true}); source_resources(s, false)
    mission_tags(s, 10, {}); assert(s.mod.update()); source_resources(s, false)
    mission_tags(s, 10, {MARKER}); assert(s.mod.update()); source_resources(s, true)
    mission_tags(s, 10, {}); assert(s.mod.update()); source_resources(s, false)
    mission_tags(s, 10, {MARKER}); assert(s.mod.update()); source_resources(s, true)
    assert(s.mod.update(false) and s.exact())
    pass('Scavengers stay native without the active swap; tag changes and privacy gating restore owned sources')
end
do
    local s = simulation(false, true)
    mission_tags(s, 10, {MARKER, 0xDF4CB4E5})
    s.set({block_jumpers = true}); source_resources(s, false)
    s.set({block_bile_spitters = true}); source_resources(s, true)
    s.set({block_bile_spitters = false}); source_resources(s, false)
    mission_tags(s, 10, {0xDF4CB4E5}); s.set({block_jumpers = false, block_bile_spitters = true})
    source_resources(s, true)
    mission_tags(s, 10, {MARKER, 0xDF4CB4E5, 0xA3A3DB9F})
    s.set({block_jumpers = true}); source_resources(s, false)
    assert(s.mod.status().source_swaps == 0)
    s.set({block_jumpers = false, block_bile_spitters = false}); assert(s.exact())
    pass('native first-rule ties and higher-priority Spore Scavengers preserve nonselected resulting species')
end
do
    local s = simulation(true, true)
    mission_tags(s, 10, {MARKER}); s.set({block_jumpers = true})
    source_resources(s, true); assert(s.allocations == 1 and ffi.string(s.original_rows, #s.before) == s.before)
    local a, b = ffi.string(s.row(13), 128), ffi.string(s.row(14), 128)
    ffi.copy(s.row(13), b, 128); ffi.copy(s.row(14), a, 128)
    s.set({block_jumpers = false})
    assert(s.resource(13) == binary(SCAVENGERS[2][2]) and s.resource(14) == binary(SCAVENGERS[1][2]))
    pass('read-only source tables clone safely and swapped source variants restore by identity')
end
do
    local s = simulation(false, true)
    local new_tag = 0x10203040
    put(s.tag_hashes + 16, new_tag); mission_tags(s, 10, {new_tag})
    s.set({block_jumpers = true}); source_resources(s, true)
    s.set({block_jumpers = false}); assert(s.exact())
    local t = simulation(false, true)
    mission_tags(t, 10, {MARKER})
    t.on_read = function(p)
        if p == t.game + 0x21E1920 then put(t.tag_hashes + 16, value(t.tag_hashes + 16) + 1) end
    end
    t.set({block_jumpers = true})
    assert(t.writes == 0 and t.mod.status().reason == 'enemy_filter_waiting_for_stable_table')
    local u = simulation(false, true)
    put(u.tag_hashes + 16, 0); u.set({block_jumpers = true})
    assert(u.writes == 0 and u.mod.status().reason == 'enemy_filter_swap_context_unavailable')
    pass('swap detection uses initialized runtime hashes and defers writes for hash races or invalid context')
end
do
    local s = simulation(false, true)
    mission_tags(s, 10, {MARKER})
    ffi.copy(s.row(13) + 8, binary('0102030405060708'), 8)
    s.set({block_jumpers = true})
    assert(s.resource(13) == binary('0102030405060708') and s.resource(14) == binary(SPECIES[11][2]))
    s.set({block_jumpers = false})
    assert(s.resource(13) == binary('0102030405060708') and s.resource(14) == binary(SCAVENGERS[2][2]))
    pass('unrecognized or externally changed Scavenger resources are preserved')
end
do
    local s = simulation(false, true)
    mission_tags(s, 10, {0x39E2D413})
    s.set({block_scavengers = true}); source_resources(s, true)
    assert(s.mod.status().blocked == 2 and s.mod.status().source_swaps == 0)
    local after = ffi.string(s.rows(), #s.before)
    for offset = 0, #after - 1 do
        local index, field = math.floor(offset / 128) + 1, offset % 128
        if not (index >= 13 and field >= 8 and field < 16) then
            assert(after:byte(offset + 1) == s.before:byte(offset + 1))
        end
    end
    s.set({block_scavengers = false}); assert(s.exact())
    mission_tags(s, 1, {}); s.set({block_scavengers = true})
    assert(s.resource(13) == binary(SPECIES[10][2]) and s.resource(14) == binary(SPECIES[10][2]))
    s.set({block_scavengers = false}); assert(s.exact())
    pass('ordinary Scavengers replace both known resources without a conversion tag and restore on every difficulty tier')
end
do
    local s = simulation(false, true)
    mission_tags(s, 10, {MARKER})
    s.set({block_scavengers = true, block_jumpers = true}); source_resources(s, true)
    s.set({block_scavengers = false}); source_resources(s, true)
    mission_tags(s, 10, {}); assert(s.mod.update()); source_resources(s, false)
    s.set({block_jumpers = false}); assert(s.exact())
    pass('unchecking ordinary Scavengers preserves the separately selected Pouncer conversion rule')
end
do
    local s = simulation(false, true, true)
    mission_tags(s, 10, {})
    s.set({block_all_small = true})
    local targets = {[1]=true,[2]=true,[3]=true,[4]=true,[12]=true,[13]=true,[14]=true,[15]=true,[16]=true,[17]=true}
    for i = 1, 17 do
        if targets[i] then assert(s.resource(i) == binary(SPECIES[11][2]))
        else assert(s.resource(i) == binary(SPECIES[i][2])) end
    end
    assert(s.mod.status().blocked == 10 and not s.mod.block_yellow_spewers and not s.mod.block_green_spewers)
    mission_tags(s, 10, {MARKER, 0xDF4CB4E5, 0xA3A3DB9F}); assert(s.mod.update())
    for i in pairs(targets) do assert(s.resource(i) == binary(SPECIES[11][2])) end
    s.set({block_scavengers = true, block_all_small = false})
    source_resources(s, true); assert(s.resource(15) == binary(SPECIES[11][2]))
    assert(s.resource(16) == binary(SMALL_VARIANTS[2][2]) and s.resource(17) == binary(SMALL_VARIANTS[3][2]))
    assert(s.mod.status().blocked == 3)
    s.set({block_scavengers = false}); assert(s.exact())
    pass('the all-small switch includes ground, spore and both flying families while preserving individual choices and Spewers')
end
do
    local s = simulation(true, true, true)
    mission_tags(s, 10, {})
    s.set({block_shriekers = true}); assert(s.mod.status().blocked == 2)
    assert(s.resource(16) == binary(SPECIES[11][2]) and s.resource(17) == binary(SPECIES[11][2]))
    s.set({block_shriekers = false, block_all_small = true})
    assert(s.allocations == 1 and ffi.string(s.original_rows, #s.before) == s.before)
    assert(s.mod.update(false) and s.exact())
    assert(s.mod.update(true) and s.mod.status().blocked == 10)
    s.set({block_all_small = false}); assert(s.exact())
    pass('flying and all-small options clone read-only tables and restore cleanly across the privacy gate')
end
do
    local s = simulation(false, true, true)
    mission_tags(s, 10, {})
    local custom = binary('0102030405060708')
    for _, i in ipairs({13,15,16}) do ffi.copy(s.row(i) + 8, custom, 8) end
    s.set({block_all_small = true})
    for _, i in ipairs({13,15,16}) do assert(s.resource(i) == custom) end
    assert(s.resource(14) == binary(SPECIES[11][2]) and s.resource(17) == binary(SPECIES[11][2]))
    s.set({block_all_small = false})
    for _, i in ipairs({13,15,16}) do assert(s.resource(i) == custom) end
    local t = simulation(false, true)
    assert(not t.mod.configure({block_jumpers = true, block_scavengers = 1}))
    assert(not t.mod.configure({block_shriekers = true, block_all_small = 'true'}))
    assert(not t.mod.block_jumpers and not t.mod.block_shriekers and not t.mod.block_all_small and t.writes == 0)
    pass('new small-species options preserve unknown resources and reject malformed toggles atomically')
end
print(checks .. ' enemy filter checks passed; synthetic memory only.')
