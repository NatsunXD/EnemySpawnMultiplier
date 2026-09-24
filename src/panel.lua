-- In-game configuration panel for Enemy Spawn Multiplier.
--
-- The Bingus Shared Loader exposes no drawing API, and hooking the game's D3D
-- present path would mean reaching outside the data-only boundary this project
-- deliberately keeps. This panel is therefore a separate top-level Win32 window
-- owned by the game process and painted with GDI. It never touches executable
-- pages, never calls native game functions, and only ever assigns into the same
-- patch.* fields the 0.1 s updater already reads, so a change is picked up on
-- the next updater pass without a mission reload.
--
-- The window is created with WS_EX_NOACTIVATE so clicking it does not steal
-- focus from the game. The toggle key is polled on the game thread instead of
-- relying on keyboard focus: when the Mod Bindings Menu addon is installed the
-- player-assigned binding is used, otherwise F8 is the fallback default.
return function(create_model, patch, callbacks)
    callbacks = callbacks or {}
    local log = callbacks.log or function() end
    local model = create_model()
    -- Optional Mod Bindings Menu bridge. When it is present the toggle uses the
    -- binding the player assigned there; otherwise the built-in F8 fallback is
    -- used exactly as before.
    local bindings = callbacks.bindings
    local TITLE = callbacks.title or 'EnemySpawnMultiplier'
    local ffi = require('ffi')
    local bit = require('bit')
    if not ffi.abi('64bit') then return nil, 'panel_requires_windows_x64' end

    ffi.cdef [[
        int32_t GetAsyncKeyState(int32_t key);
        void *GetModuleHandleA(const char *name);
        void *GetForegroundWindow(void);
        uint32_t GetWindowThreadProcessId(void *window, uint32_t *pid);
        uint32_t GetCurrentProcessId(void);
        int16_t RegisterClassExA(const void *wndclass);
        void *CreateWindowExA(uint32_t ex_style, const char *class_name, const char *window_name,
                              uint32_t style, int32_t x, int32_t y, int32_t width, int32_t height,
                              void *parent, void *menu, void *instance, void *param);
        int64_t DefWindowProcA(void *window, uint32_t message, uint64_t wparam, int64_t lparam);
        int32_t DestroyWindow(void *window);
        int32_t ShowWindow(void *window, int32_t command);
        int32_t UpdateWindow(void *window);
        int32_t InvalidateRect(void *window, const void *rect, int32_t erase);
        int32_t PeekMessageA(void *message, void *window, uint32_t filter_min, uint32_t filter_max, uint32_t remove);
        int32_t TranslateMessage(const void *message);
        int64_t DispatchMessageA(const void *message);
        void *SetCapture(void *window);
        int32_t ReleaseCapture(void);
        int32_t GetWindowRect(void *window, void *rect);
        int32_t GetCursorPos(void *point);
        int32_t MoveWindow(void *window, int32_t x, int32_t y, int32_t width, int32_t height, int32_t repaint);
        void *SetCursor(void *cursor);
        void *LoadCursorA(void *instance, const char *name);
        int32_t GetClientRect(void *window, void *rect);
        uint32_t GetLastError(void);
        void *BeginPaint(void *window, void *paint);
        int32_t EndPaint(void *window, const void *paint);
        void *GetDC(void *window);
        int32_t ReleaseDC(void *window, void *dc);
        int32_t FillRect(void *dc, const void *rect, void *brush);
        int32_t DrawTextW(void *dc, const uint16_t *text, int32_t count, void *rect, uint32_t format);
        int32_t MultiByteToWideChar(uint32_t codepage, uint32_t flags, const char *input, int32_t input_length,
                                    uint16_t *output, int32_t output_length);

        void *CreateSolidBrush(uint32_t color);
        void *CreatePen(int32_t style, int32_t width, uint32_t color);
        void *SelectObject(void *dc, void *object);
        int32_t DeleteObject(void *object);
        void *CreateCompatibleDC(void *dc);
        void *CreateCompatibleBitmap(void *dc, int32_t width, int32_t height);
        int32_t BitBlt(void *dst, int32_t x, int32_t y, int32_t width, int32_t height,
                       void *src, int32_t sx, int32_t sy, uint32_t rop);
        int32_t DeleteDC(void *dc);
        int32_t RoundRect(void *dc, int32_t left, int32_t top, int32_t right, int32_t bottom,
                          int32_t width, int32_t height);
        int32_t Ellipse(void *dc, int32_t left, int32_t top, int32_t right, int32_t bottom);
        int32_t Rectangle(void *dc, int32_t left, int32_t top, int32_t right, int32_t bottom);
        int32_t SetTextColor(void *dc, uint32_t color);
        int32_t SetBkMode(void *dc, int32_t mode);
        void *CreateFontA(int32_t height, int32_t width, int32_t escapement, int32_t orientation,
                          int32_t weight, uint32_t italic, uint32_t underline, uint32_t strikeout,
                          uint32_t charset, uint32_t out_precision, uint32_t clip_precision,
                          uint32_t quality, uint32_t pitch, const char *face);
    ]]

    local user32 = ffi.load('user32')
    local gdi32 = ffi.load('gdi32')
    local kernel32 = ffi.load('kernel32')

    local WNDCLASSEXA = ffi.typeof([[struct {
        uint32_t cbSize; uint32_t style; void *wnd_proc;
        int32_t cls_extra; int32_t wnd_extra;
        void *instance; void *icon; void *cursor; void *background;
        const char *menu_name; const char *class_name; void *icon_small;
    }]])
    local RECT = ffi.typeof('struct { int32_t left, top, right, bottom; }')
    local MSG = ffi.typeof([[struct {
        void *window; uint32_t message; uint32_t padding;
        uint64_t wparam; int64_t lparam; uint32_t time; int32_t x; int32_t y;
    }]])
    local POINT = ffi.typeof('struct { int32_t x, y; }')
    local PAINTSTRUCT = ffi.typeof([[struct {
        void *dc; int32_t erase; uint32_t padding; int32_t left, top, right, bottom;
        int32_t restore; int32_t inc_update; uint8_t reserved[32];
    }]])

    -- Message and style constants actually used below.
    local WM_DESTROY, WM_CLOSE, WM_PAINT, WM_ERASEBKGND = 0x0002, 0x0010, 0x000F, 0x0014
    local WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MOUSEMOVE, WM_SETCURSOR = 0x0201, 0x0202, 0x0200, 0x0020
    local WS_POPUP, WS_VISIBLE = 0x80000000, 0x10000000
    local WS_EX_TOPMOST, WS_EX_TOOLWINDOW, WS_EX_NOACTIVATE = 0x00000008, 0x00000080, 0x08000000
    local SW_HIDE, SW_SHOW = 0, 5
    local PM_REMOVE = 1
    local HTCLIENT = 1
    local DT_LEFT, DT_VCENTER, DT_SINGLELINE, DT_CENTER = 0, 4, 0x20, 1
    local TRANSPARENT = 1
    local SRCCOPY = 0x00CC0020
    local IDC_ARROW = ffi.cast('const char *', 32512)
    local VK_F8 = 0x77
    local MK_LBUTTON = 1

    local function rgb(r, g, b) return r + g * 256 + b * 65536 end
    local C_BG       = rgb(0x1E, 0x1E, 0x1E)
    local C_BAR      = rgb(0x27, 0x27, 0x27)
    local C_TITLE    = rgb(0xF2, 0xF2, 0xF2)
    local C_LABEL    = rgb(0xC2, 0xC2, 0xC2)
    local C_DIM      = rgb(0x8A, 0x8A, 0x8A)
    local C_TRACK    = rgb(0x3A, 0x3A, 0x3A)
    local C_ACCENT   = rgb(0x4A, 0x9E, 0xFF)
    local C_KNOB     = rgb(0xFF, 0xFF, 0xFF)
    local C_BUTTON   = rgb(0x33, 0x33, 0x33)
    local C_OK       = rgb(0x6E, 0xC7, 0x7A)
    local C_WARN     = rgb(0xE0, 0xB4, 0x5A)
    local FOOTER_WAITING = '尚未进入建立：修改已保存，进图后生效'
    local FOOTER_ACTIVE  = '已生效'
    local CD_FAST_LABEL  = '快'
    local CD_SLOW_LABEL  = '慢'

    local CLIENT_W, CLIENT_H = model.CLIENT_W, model.CLIENT_H

    -- UTF-8 to UTF-16 for DrawTextW. The ANSI DrawTextA entry point would render
    -- the Chinese labels as mojibake on a non-UTF-8 system code page.
    local function wide(text)
        -- MultiByteToWideChar lives in kernel32, not user32; resolving it from
        -- the wrong module yields a bogus pointer and faults on the first paint.
        local length = kernel32.MultiByteToWideChar(65001, 0, text, -1, nil, 0)
        if length <= 0 then return nil end
        local buffer = ffi.new('uint16_t[?]', length)
        if kernel32.MultiByteToWideChar(65001, 0, text, -1, buffer, length) <= 0 then return nil end
        return buffer, length - 1
    end

    -- The loader state says whether a mission is running. A change made on the
    -- ship is committed immediately but only takes effect once a mission starts,
    -- so the panel must say which of the two it is.
    local runtime = callbacks.state
    local panel = {open = false, dragging_window = false, drag_slider = nil,
                   status = '', status_until = 0, model = model,
                   toggle_hint = 'F8 开关'}

    -- Every log call goes through here and always supplies both arguments: the
    -- loader's writer concatenates the detail, so a one-argument call raises.
    -- Declared before first use; a later local would not be in scope above.
    local function emit(status, detail)
        pcall(log, status, detail or '')
    end

    -- Register as early as possible so the Mod Bindings Menu row exists even
    -- before the first pump. pump() keeps retrying while the addon is absent.
    if bindings and type(bindings.register) == 'function' then
        pcall(bindings.register)
    end

    -- Open showing the profile that is actually live, not the panel defaults.
    local synced, sync_reason = pcall(model.sync_from_patch, patch)
    if not synced then
        emit('panel_sync_error', tostring(sync_reason))
    end

    function panel.apply()
        -- Applying must never raise: this runs from the window procedure, and an
        -- error there would escape into the updater hook.
        local called, ok, reason = pcall(model.apply, patch)
        if not called then
            panel.status, panel.status_until = '失败：' .. tostring(ok), os.clock() + 3.0
            emit('panel_apply_error', tostring(ok))
            return false
        end
        if not ok then
            panel.status, panel.status_until = '失败：' .. tostring(reason), os.clock() + 3.0
            emit('panel_apply_rejected', tostring(reason))
            return false
        end
        panel.status, panel.status_until = '已应用', os.clock() + 1.5
        local p = model.pending
        emit('panel_applied', string.format(
            'budget=%.1f count=%.1f size=%.1f enc_cd=%.0fs patrol_cd=%.0fs preset=%s',
            p.budget, p.patrol_count, p.patrol_size, p.encounter_cd, p.patrol_cd, p.preset))
        return true
    end

    -- ---------------------------------------------------------------- drawing
    local function brush(color) return gdi32.CreateSolidBrush(color) end

    local function fill(dc, x, y, w, h, color)
        local rect = ffi.new(RECT, x, y, x + w, y + h)
        local handle = brush(color)
        user32.FillRect(dc, rect, handle)
        gdi32.DeleteObject(handle)
    end

    local function draw_text(dc, text, x, y, w, h, color, center)
        if type(text) ~= 'string' or text == '' then return end
        local buffer, length = wide(text)
        if not buffer then return end
        local rect = ffi.new(RECT, x, y, x + w, y + h)
        gdi32.SetTextColor(dc, color)
        gdi32.SetBkMode(dc, TRANSPARENT)
        local format = center and (DT_CENTER + DT_VCENTER + DT_SINGLELINE) or (DT_LEFT + DT_VCENTER + DT_SINGLELINE)
        user32.DrawTextW(dc, buffer, length, rect, format)
    end

    local function rounded(dc, x, y, w, h, radius, color)
        local fill_brush, edge_pen = brush(color), gdi32.CreatePen(0, 1, color)
        local old_brush = gdi32.SelectObject(dc, fill_brush)
        local old_pen = gdi32.SelectObject(dc, edge_pen)
        gdi32.RoundRect(dc, x, y, x + w, y + h, radius, radius)
        gdi32.SelectObject(dc, old_brush)
        gdi32.SelectObject(dc, old_pen)
        gdi32.DeleteObject(edge_pen)
        gdi32.DeleteObject(fill_brush)
    end

    local function paint(window)
        local paint_struct = ffi.new(PAINTSTRUCT)
        local dc = user32.BeginPaint(window, paint_struct)
        if dc == nil then return end
        local client = ffi.new(RECT)
        user32.GetClientRect(window, client)
        local width, height = client.right, client.bottom
        -- A minimized or not-yet-laid-out window reports a zero client area;
        -- CreateCompatibleBitmap would fail and the following BitBlt would run
        -- on invalid handles.
        if width <= 0 or height <= 0 then
            user32.EndPaint(window, paint_struct)
            return
        end

        -- Double buffer so slider drags do not flicker.
        local memory = gdi32.CreateCompatibleDC(dc)
        local bitmap = gdi32.CreateCompatibleBitmap(dc, width, height)
        local old_bitmap = gdi32.SelectObject(memory, bitmap)

        fill(memory, 0, 0, width, height, C_BG)
        fill(memory, 0, 0, width, 40, C_BAR)
        draw_text(memory, TITLE, 16, 0, width - 140, 40, C_TITLE)
        draw_text(memory, panel.toggle_hint, width - 124, 0, 108, 40, C_DIM)

        local widgets = model.layout()
        for _, item in ipairs(widgets.sliders) do
            draw_text(memory, item.label, item.x, item.y, 120, item.h, C_LABEL)
            local track_x, track_w, track_y = item.track_x, item.track_w, item.track_y
            fill(memory, track_x, track_y - 2, track_w, 5, C_TRACK)
            local ratio = model.slider_ratio(item)
            local knob_x = track_x + math.floor(ratio * track_w + 0.5)
            fill(memory, track_x, track_y - 2, math.max(1, knob_x - track_x), 5, C_ACCENT)
            local knob = brush(C_KNOB)
            local old = gdi32.SelectObject(memory, knob)
            gdi32.Ellipse(memory, knob_x - 7, track_y - 9, knob_x + 7, track_y + 5)
            gdi32.SelectObject(memory, old)
            gdi32.DeleteObject(knob)
            if item.kind == 'cooldown' then
                -- No numeric readout on the cooldown rows; the two ends carry
                -- the meaning instead.
                draw_text(memory, CD_FAST_LABEL, track_x - 34, item.y, 28, item.h, C_DIM, true)
                draw_text(memory, CD_SLOW_LABEL, track_x + track_w + 6, item.y, 28, item.h, C_DIM, true)
            else
                draw_text(memory, model.format(item), item.x + item.w - 72, item.y, 72, item.h, C_TITLE)
            end
        end

        draw_text(memory, '模板预设', 24, 256, 200, 20, C_DIM)
        for _, item in ipairs(widgets.radios) do
            local selected = model.pending[item.key] == item.value
            local cx, cy = item.x + 8, item.y + item.h / 2
            local ring = brush(C_TRACK)
            local old = gdi32.SelectObject(memory, ring)
            gdi32.Ellipse(memory, cx - 8, cy - 8, cx + 8, cy + 8)
            gdi32.SelectObject(memory, old)
            gdi32.DeleteObject(ring)
            if selected then
                local dot = brush(C_ACCENT)
                old = gdi32.SelectObject(memory, dot)
                gdi32.Ellipse(memory, cx - 4, cy - 4, cx + 4, cy + 4)
                gdi32.SelectObject(memory, old)
                gdi32.DeleteObject(dot)
            end
            draw_text(memory, item.label, item.x + 26, item.y, item.w - 26, item.h,
                      selected and C_TITLE or C_LABEL)
        end

        for _, item in ipairs(widgets.buttons) do
            rounded(memory, item.x, item.y, item.w, item.h, 8, item.accent and C_ACCENT or C_BUTTON)
            draw_text(memory, item.label, item.x, item.y, item.w, item.h, C_TITLE, true)
        end

        -- Prefer the transient apply result; otherwise state what the committed
        -- configuration will do, so "did it apply?" is never ambiguous.
        local footer, footer_color = nil, C_OK
        if runtime and runtime.active == false then
            footer, footer_color = FOOTER_WAITING, C_WARN
        else
            footer, footer_color = FOOTER_ACTIVE, C_OK
        end
        if panel.status ~= '' and os.clock() < panel.status_until then
            footer, footer_color = panel.status, C_OK
        end
        draw_text(memory, footer, 24, 410, CLIENT_W - 48, 24, footer_color)

        gdi32.BitBlt(dc, 0, 0, width, height, memory, 0, 0, SRCCOPY)
        gdi32.SelectObject(memory, old_bitmap)
        gdi32.DeleteObject(bitmap)
        gdi32.DeleteDC(memory)
        user32.EndPaint(window, paint_struct)
    end

    -- ------------------------------------------------------------- window proc
    local function handle_mouse_down(x, y)
        local kind, item = model.hit(x, y)
        if kind == 'slider' then
            panel.drag_slider = item
            model.set_slider(item, x)
            user32.InvalidateRect(panel.window, nil, 0)
        elseif kind == 'radio' then
            model.pending[item.key] = item.value
            user32.InvalidateRect(panel.window, nil, 0)
        elseif kind == 'button' then
            if item.id == 'apply' then
                panel.apply()
            elseif item.id == 'reset' then
                model.reset()
            end
            user32.InvalidateRect(panel.window, nil, 0)
        elseif kind == 'title' then
            local cursor, rect = ffi.new(POINT), ffi.new(RECT)
            if user32.GetCursorPos(cursor) ~= 0 and user32.GetWindowRect(panel.window, rect) ~= 0 then
                panel.drag_offset_x, panel.drag_offset_y = cursor.x - rect.left, cursor.y - rect.top
                panel.dragging_window = true
                user32.SetCapture(panel.window)
            end
        end
    end

    -- lparam packs two signed 16-bit client coordinates. lparam is declared as
    -- int64_t, so reduce it to the low 32 bits before unpacking the halves.
    local function packed_xy(value)
        local packed = tonumber(bit.band(ffi.cast('uint32_t', value), 0xFFFFFFFF))
        local x = packed % 0x10000
        local y = math.floor(packed / 0x10000)
        if x >= 0x8000 then x = x - 0x10000 end
        if y >= 0x8000 then y = y - 0x10000 end
        return x, y
    end

    local function drag_window_to_cursor()
        local cursor, rect = ffi.new(POINT), ffi.new(RECT)
        if user32.GetCursorPos(cursor) == 0 then return end
        if user32.GetWindowRect(panel.window, rect) == 0 then return end
        user32.MoveWindow(panel.window, cursor.x - panel.drag_offset_x, cursor.y - panel.drag_offset_y,
                          rect.right - rect.left, rect.bottom - rect.top, 1)
    end

    local function window_proc(window, message, wparam, lparam)
        if message == WM_PAINT then
            paint(window)
            return 0
        elseif message == WM_ERASEBKGND then
            return 1
        elseif message == WM_LBUTTONDOWN then
            local x, y = packed_xy(lparam)
            handle_mouse_down(x, y)
            return 0
        elseif message == WM_MOUSEMOVE then
            local x, y = packed_xy(lparam)
            if panel.drag_slider then
                model.set_slider(panel.drag_slider, x)
                user32.InvalidateRect(window, nil, 0)
            elseif panel.dragging_window and bit.band(wparam, MK_LBUTTON) ~= 0 then
                drag_window_to_cursor()
            end
            return 0
        elseif message == WM_LBUTTONUP then
            if panel.dragging_window then user32.ReleaseCapture() end
            panel.drag_slider, panel.dragging_window = nil, false
            return 0
        elseif message == WM_SETCURSOR then
            if bit.band(lparam, 0xFFFF) == HTCLIENT then user32.SetCursor(panel.cursor) end
            return 1
        elseif message == WM_CLOSE then
            user32.ShowWindow(window, SW_HIDE)
            panel.open = false
            return 0
        elseif message == WM_DESTROY then
            panel.window = nil
            return 0
        end
        return user32.DefWindowProcA(window, message, wparam, lparam)
    end

    local ok, err = pcall(function()
        local instance = kernel32.GetModuleHandleA(nil)
        local wndclass = ffi.new(WNDCLASSEXA)
        panel.cursor = user32.LoadCursorA(nil, IDC_ARROW)
        wndclass.cbSize = ffi.sizeof(wndclass)
        wndclass.style = 0
        wndclass.wnd_proc = ffi.cast('void *', ffi.cast('int64_t (*)(void *, uint32_t, uint64_t, int64_t)', window_proc))
        wndclass.instance = instance
        wndclass.cursor = panel.cursor
        wndclass.background = nil
        wndclass.class_name = 'HD2EnemySpawnMultiplierPanel'
        panel.wndclass = wndclass
        if user32.RegisterClassExA(wndclass) == 0 then
            -- A window class may be registered only once per process. Reuse the
            -- existing one when it is already ours; otherwise the class really
            -- failed to register and CreateWindowExA would fail too.
            local ERROR_CLASS_ALREADY_EXISTS = 1410
            if kernel32.GetLastError() ~= ERROR_CLASS_ALREADY_EXISTS then
                error('panel_register_class_failed')
            end
        end
        panel.window = user32.CreateWindowExA(
            WS_EX_TOPMOST + WS_EX_TOOLWINDOW + WS_EX_NOACTIVATE,
            wndclass.class_name, TITLE, WS_POPUP,
            120, 120, CLIENT_W, CLIENT_H, nil, nil, instance, nil)
        if panel.window == nil then error('panel_create_window_failed') end
    end)
    if not ok then
        log('panel_unavailable', tostring(err))
        return nil, tostring(err)
    end

    -- ------------------------------------------------------------------- pump
    local previous_key = false
    local binding_logged = false
    local fallback_hint = panel.toggle_hint

    function panel.pump()
        if panel.window == nil then return end

        -- Resolve the toggle. The Mod Bindings Menu binding wins once it is
        -- available; until then (and when the addon is absent) fall back to F8.
        local key
        if bindings then
            bindings.register()
            local down = bindings.is_down()
            if down ~= nil then
                key = down
                if not binding_logged then
                    binding_logged = true
                    emit('panel_binding_active', 'using the Mod Bindings Menu slot')
                end
            end
        end
        if key == nil then
            key = bit.band(user32.GetAsyncKeyState(VK_F8), 0x8000) ~= 0
        end
        panel.toggle_hint = binding_logged and '自定义键' or fallback_hint

        if key and not previous_key then
            panel.open = not panel.open
            user32.ShowWindow(panel.window, panel.open and SW_SHOW or SW_HIDE)
            if panel.open then user32.InvalidateRect(panel.window, nil, 0) end
        end
        previous_key = key
        -- Restrict the pump to this window. Peeking the whole thread queue would
        -- drain messages that belong to the game's own windows and break its
        -- input handling.
        local message = ffi.new(MSG)
        while user32.PeekMessageA(message, panel.window, 0, 0, PM_REMOVE) ~= 0 do
            user32.TranslateMessage(message)
            -- Contain a fault to the single message that caused it. Without
            -- this, one bad handler escapes into the updater hook, which tears
            -- the panel down for the rest of the session and leaves F8 dead.
            local dispatched, err = pcall(user32.DispatchMessageA, message)
            if not dispatched then
                emit('panel_message_error', tostring(err))
            end
        end
    end

    function panel.close()
        if panel.window then user32.DestroyWindow(panel.window) end
        panel.window = nil
    end

    return panel
end
