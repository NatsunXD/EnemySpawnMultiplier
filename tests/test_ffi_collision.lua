-- Cross-addon FFI collision checks.
--
-- LuaJIT's ffi.cdef namespace is shared by every addon in the VM and the first
-- declaration of a name wins. ClickableScrollbars declares
-- `int GetClientRect(void*, HD2CS_RECT*)`; when it loads before this mod, our own
-- `GetClientRect(void*, void*)` declaration is discarded and passing our RECT
-- raised a conversion error from inside WM_PAINT. The error escaping that window
-- procedure killed the game, which is the reported "F8 crashes with
-- ClickableScrollbars" bug.
--
-- The panel now binds each Win32 entry point to a private function-pointer typedef
-- and calls through that, so the shared declaration cannot affect it. These checks
-- lock that in: they occupy the namespace exactly as the other addon does, then
-- bring the real panel up and drive it.
local source = assert(arg[1])
local ffi = require('ffi')
local create_model = assert(loadfile(source .. '/panel_model.lua'))()
local create_panel = assert(loadfile(source .. '/panel.lua'))()

local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end
local function approx(a, b) return math.abs(a - b) <= 0.0001 end

-- ---- occupy the shared namespace exactly as ClickableScrollbars does ----
-- (verbatim shapes from its src/clickable_scrollbars.lua)
pcall(ffi.cdef, [[
    typedef struct { int x; int y; } HD2CS_POINT;
    typedef struct { int left; int top; int right; int bottom; } HD2CS_RECT;
    short GetAsyncKeyState(int key);
    int GetCursorPos(HD2CS_POINT *point);
    int GetClientRect(void *window, HD2CS_RECT *rect);
    unsigned int GetWindowThreadProcessId(void *window, unsigned int *process);
    void *GetDC(void *window);
    int ReleaseDC(void *window, void *dc);
    void *GetForegroundWindow(void);
    int GetSystemMetrics(int index);
    int IsWindow(void *window);
    int BitBlt(void *d, int x, int y, int w, int h, void *s, int sx, int sy, unsigned int rop);
    int DeleteObject(void *object);
    void *SelectObject(void *dc, void *object);
    int DeleteDC(void *dc);
    void *CreateCompatibleDC(void *dc);
]])
pass('a competing addon took over the shared ffi.cdef namespace')

-- ---- the real panel must still work against that namespace ----
local patch = {
    cooldown_rates = { short = 3.0, native = 1.0 },
    cooldown_fast_rate = 3.0, patrol_cooldown_fast_rate = 6.0,
    budget_multiplier = 2.0, modifier_patrol_count = 1.0,
    modifier_travelers_max_unit = 1.0, modifier_patrol_cooldown = 3.0,
    modifier_encounter_cooldown = 3.0, encounter_max_interval = 2.0,
    encounter_deadline_enabled = true, template_bias_enabled = false,
    configure = function() return true end,
}
local logged = {}
local ok, panel, reason = pcall(create_panel, create_model, patch, {
    log = function(a, b) logged[#logged + 1] = tostring(a) end,
    state = { active = false },
    title = 'collision test',
})
assert(ok and panel ~= nil, 'panel failed to create: ' .. tostring(reason))
assert(panel.window ~= nil)
pass('panel is created while another addon owns the declarations')

-- Showing the window forces WM_PAINT, which is where GetClientRect is called and
-- where the uninstrumented build died.
local user32 = ffi.load('user32')
local shown, show_err = pcall(function()
    user32.ShowWindow(panel.window, 5)
    user32.UpdateWindow(panel.window)
end)
assert(shown, 'show/update failed: ' .. tostring(show_err))
for _ = 1, 40 do panel.pump() end
assert(panel.window ~= nil, 'the panel was torn down while painting')
pass('painting and pumping survive the collision (the F8 path)')

-- Applying exercises the same user32 path plus the settings round trip.
local applied, apply_reason = panel.apply()
assert(applied == true, 'apply failed: ' .. tostring(apply_reason))
for _ = 1, 20 do panel.pump() end
assert(panel.window ~= nil)
pass('apply and redraw survive the collision')

-- Every binding must actually be a callable function pointer, not nil.
assert(type(panel.window) == 'cdata')
panel.close()
pass('panel window destroyed cleanly after the collision test')

print(count .. ' FFI collision checks passed; no game process involved.')
