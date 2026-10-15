-- Render the panel and dump the client area to a BMP so the layout can be
-- inspected visually without launching the game.
local source, output = assert(arg[1]), assert(arg[2])
local ffi = require('ffi')

ffi.cdef [[
    int32_t ShowWindow(void *window, int32_t command);
    int32_t UpdateWindow(void *window);
    int32_t InvalidateRect(void *window, const void *rect, int32_t erase);
    void Sleep(uint32_t milliseconds);
    void *GetDC(void *window);
    int32_t ReleaseDC(void *window, void *dc);
    void *CreateCompatibleDC(void *dc);
    void *CreateCompatibleBitmap(void *dc, int32_t w, int32_t h);
    void *SelectObject(void *dc, void *obj);
    int32_t BitBlt(void *dst, int32_t x, int32_t y, int32_t w, int32_t h, void *src, int32_t sx, int32_t sy, uint32_t rop);
    int32_t GetDIBits(void *dc, void *bitmap, uint32_t start, uint32_t lines, void *bits, void *info, uint32_t usage);
    int32_t GetClientRect(void *window, void *rect);
    int32_t DeleteObject(void *obj);
    int32_t DeleteDC(void *dc);
]]

local user32, gdi32, kernel32 = ffi.load('user32'), ffi.load('gdi32'), ffi.load('kernel32')
local create_model = assert(loadfile(source .. '/panel_model.lua'))()
if arg[5]=='local_test' then
    create_model=assert(loadfile(source..'/experiments/local_panel_model.lua'))()(create_model)
end
-- The instrumented copy in build/ has paint traces removed for this capture.
local create_panel = assert(loadfile(source .. '/panel.lua'))()
local patch = {cooldown_fast_rate = 3.0, patrol_cooldown_fast_rate = 6.0, cooldown_fast_seconds = 2.0, cooldown_slow_seconds = 30.0,
               configure = function() return true end}
local panel = assert(create_panel(create_model, patch, {
    log = function() end, state = {active = false},
    title = 'EnemySpawnMultiplier v24 by Natsun',
}))

user32.ShowWindow(panel.window, 5)
user32.InvalidateRect(panel.window, nil, 1)
user32.UpdateWindow(panel.window)
-- Show the state just after a successful Apply, which is the path that used to
-- crash the panel out of existence.
if arg[4]~='default' then
    panel.model.pending.budget, panel.model.pending.patrol_count = 3.5, 4.0
    panel.model.pending.patrol_size, panel.model.pending.preset = 1.8, 'light_medium'
    panel.model.pending.encounter_cd, panel.model.pending.patrol_cd = 2.0, 18.0
end
assert(panel.apply())
assert(panel.set_language(arg[3] or 'zh'))
-- The button handler repaints after Apply; mirror that so the capture shows the
-- post-apply state rather than the initial paint.
user32.InvalidateRect(panel.window, nil, 0)
user32.UpdateWindow(panel.window)
for _ = 1, 10 do panel.pump(); kernel32.Sleep(10) end

local RECT = ffi.typeof('struct { int32_t left, top, right, bottom; }')
local rect = ffi.new(RECT)
user32.GetClientRect(panel.window, rect)
local width, height = rect.right, rect.bottom

local window_dc = user32.GetDC(panel.window)
local memory = gdi32.CreateCompatibleDC(window_dc)
local bitmap = gdi32.CreateCompatibleBitmap(window_dc, width, height)
gdi32.SelectObject(memory, bitmap)
gdi32.BitBlt(memory, 0, 0, width, height, window_dc, 0, 0, 0x00CC0020)

-- 32bpp bottom-up DIB.
local BITMAPINFOHEADER = ffi.typeof([[struct {
    uint32_t size; int32_t width, height; uint16_t planes, bit_count;
    uint32_t compression, size_image; int32_t xppm, yppm; uint32_t used, important;
}]])
local header = ffi.new(BITMAPINFOHEADER)
header.size = ffi.sizeof(BITMAPINFOHEADER)
header.width, header.height = width, -height  -- negative: top-down
header.planes, header.bit_count = 1, 32
header.compression = 0
local pixels = ffi.new('uint8_t[?]', width * height * 4)
assert(gdi32.GetDIBits(memory, bitmap, 0, height, pixels, header, 0) == height)

-- BMP file: 14-byte file header, 40-byte info header, then BGRA rows.
local file = assert(io.open(output, 'wb'))
local function u16(v) file:write(string.char(v % 256, math.floor(v / 256) % 256)) end
local function u32(v) file:write(string.char(v % 256, math.floor(v / 256) % 256,
                                          math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)) end
local data_size = width * height * 4
u16(0x4D42); u32(14 + 40 + data_size); u16(0); u16(0); u32(54)
u32(40); u32(width); u32(-height); u16(1); u16(32); u32(0); u32(data_size)
u32(2835); u32(2835); u32(0); u32(0)
file:write(ffi.string(pixels, data_size))
file:close()

gdi32.DeleteObject(bitmap)
gdi32.DeleteDC(memory)
user32.ReleaseDC(panel.window, window_dc)
panel.close()
print('captured ' .. width .. 'x' .. height .. ' -> ' .. output)
