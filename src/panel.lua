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
    -- Optional local config store. When present, the committed profile is saved
    -- on Apply and restored on the next game launch; when absent (as in the
    -- smaller test harnesses) the panel behaves exactly as before.
    local store = callbacks.store
    local config = callbacks.config
    -- Optional diagnostic pack exporter (Desktop dump). Best-effort only.
    local export_diag = callbacks.export_diag
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

    local user32_lib = ffi.load('user32')
    local gdi32_lib = ffi.load('gdi32')
    local kernel32_lib = ffi.load('kernel32')

    -- Bind every Win32 entry point to a private function pointer.
    --
    -- LuaJIT's ffi.cdef namespace is shared by every addon in the VM and the first
    -- declaration of a name wins. ClickableScrollbars declares
    -- `int GetClientRect(void*, HD2CS_RECT*)`; because it loads first, our own
    -- `GetClientRect(void*, void*)` declaration is discarded, and passing our RECT
    -- raises a conversion error from inside WM_PAINT. An error escaping that
    -- window procedure kills the process, which is the reported F8 crash.
    --
    -- Calling through these private typedefs takes the shared declaration out of
    -- the picture: the prototype used at the call site is the one written here, no
    -- matter what any other addon put into the namespace.
    ffi.cdef [[
        typedef struct { int32_t left, top, right, bottom; } ESP_RECT;
        typedef struct { int32_t x, y; } ESP_POINT;

        typedef int32_t (*ESP_GetAsyncKeyState_t)(int32_t);
        typedef void   *(*ESP_GetModuleHandleA_t)(const char *);
        typedef int32_t (*ESP_GetWindowThreadProcessId_t)(void *, uint32_t *);
        typedef uint32_t (*ESP_GetCurrentProcessId_t)(void);
        typedef int16_t (*ESP_RegisterClassExA_t)(const void *);
        typedef void   *(*ESP_CreateWindowExA_t)(uint32_t, const char *, const char *, uint32_t,
                                                 int32_t, int32_t, int32_t, int32_t,
                                                 void *, void *, void *, void *);
        typedef int64_t (*ESP_DefWindowProcA_t)(void *, uint32_t, uint64_t, int64_t);
        typedef int32_t (*ESP_DestroyWindow_t)(void *);
        typedef int32_t (*ESP_ShowWindow_t)(void *, int32_t);
        typedef int32_t (*ESP_UpdateWindow_t)(void *);
        typedef int32_t (*ESP_InvalidateRect_t)(void *, const void *, int32_t);
        typedef int32_t (*ESP_PeekMessageA_t)(void *, void *, uint32_t, uint32_t, uint32_t);
        typedef int32_t (*ESP_TranslateMessage_t)(const void *);
        typedef int64_t (*ESP_DispatchMessageA_t)(const void *);
        typedef void   *(*ESP_SetCapture_t)(void *);
        typedef int32_t (*ESP_ReleaseCapture_t)(void);
        typedef int32_t (*ESP_GetWindowRect_t)(void *, void *);
        typedef int32_t (*ESP_GetCursorPos_t)(void *);
        typedef int32_t (*ESP_MoveWindow_t)(void *, int32_t, int32_t, int32_t, int32_t, int32_t);
        typedef void   *(*ESP_SetCursor_t)(void *);
        typedef void   *(*ESP_LoadCursorA_t)(void *, const char *);
        typedef int32_t (*ESP_GetClientRect_t)(void *, void *);
        typedef void   *(*ESP_BeginPaint_t)(void *, void *);
        typedef int32_t (*ESP_EndPaint_t)(void *, const void *);
        typedef void   *(*ESP_GetDC_t)(void *);
        typedef int32_t (*ESP_ReleaseDC_t)(void *, void *);
        typedef int32_t (*ESP_FillRect_t)(void *, const void *, void *);
        typedef int32_t (*ESP_DrawTextW_t)(void *, const uint16_t *, int32_t, void *, uint32_t);
        typedef int32_t (*ESP_MultiByteToWideChar_t)(uint32_t, uint32_t, const char *, int32_t,
                                                     uint16_t *, int32_t);
        typedef void   *(*ESP_CreateSolidBrush_t)(uint32_t);
        typedef void   *(*ESP_CreatePen_t)(int32_t, int32_t, uint32_t);
        typedef void   *(*ESP_SelectObject_t)(void *, void *);
        typedef int32_t (*ESP_DeleteObject_t)(void *);
        typedef void   *(*ESP_CreateCompatibleDC_t)(void *);
        typedef void   *(*ESP_CreateCompatibleBitmap_t)(void *, int32_t, int32_t);
        typedef int32_t (*ESP_BitBlt_t)(void *, int32_t, int32_t, int32_t, int32_t,
                                        void *, int32_t, int32_t, uint32_t);
        typedef int32_t (*ESP_DeleteDC_t)(void *);
        typedef int32_t (*ESP_RoundRect_t)(void *, int32_t, int32_t, int32_t, int32_t,
                                           int32_t, int32_t);
        typedef int32_t (*ESP_Ellipse_t)(void *, int32_t, int32_t, int32_t, int32_t);
        typedef int32_t (*ESP_Rectangle_t)(void *, int32_t, int32_t, int32_t, int32_t);
        typedef int32_t (*ESP_SetTextColor_t)(void *, uint32_t);
        typedef int32_t (*ESP_SetBkMode_t)(void *, int32_t);
        typedef void *(*ESP_CreateFont_t)(int32_t,int32_t,int32_t,int32_t,int32_t,
            uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,const char *);
    ]]

    local function bind_export(lib, export, typedef_name)
        local symbol = lib[export]
        assert(symbol ~= nil, 'missing Win32 export: ' .. export)
        return ffi.cast(typedef_name, symbol)
    end

    local user32, gdi32, kernel32 = {}, {}, {}
    for export, typedef_name in pairs({
        GetAsyncKeyState = 'ESP_GetAsyncKeyState_t',
        GetWindowThreadProcessId = 'ESP_GetWindowThreadProcessId_t',
        RegisterClassExA = 'ESP_RegisterClassExA_t',
        CreateWindowExA = 'ESP_CreateWindowExA_t',
        DefWindowProcA = 'ESP_DefWindowProcA_t',
        DestroyWindow = 'ESP_DestroyWindow_t',
        ShowWindow = 'ESP_ShowWindow_t',
        UpdateWindow = 'ESP_UpdateWindow_t',
        InvalidateRect = 'ESP_InvalidateRect_t',
        PeekMessageA = 'ESP_PeekMessageA_t',
        TranslateMessage = 'ESP_TranslateMessage_t',
        DispatchMessageA = 'ESP_DispatchMessageA_t',
        SetCapture = 'ESP_SetCapture_t',
        ReleaseCapture = 'ESP_ReleaseCapture_t',
        GetWindowRect = 'ESP_GetWindowRect_t',
        GetCursorPos = 'ESP_GetCursorPos_t',
        MoveWindow = 'ESP_MoveWindow_t',
        SetCursor = 'ESP_SetCursor_t',
        LoadCursorA = 'ESP_LoadCursorA_t',
        GetClientRect = 'ESP_GetClientRect_t',
        BeginPaint = 'ESP_BeginPaint_t',
        EndPaint = 'ESP_EndPaint_t',
        GetDC = 'ESP_GetDC_t',
        ReleaseDC = 'ESP_ReleaseDC_t',
        FillRect = 'ESP_FillRect_t',
        DrawTextW = 'ESP_DrawTextW_t',
    }) do
        user32[export] = bind_export(user32_lib, export, typedef_name)
    end
    for export, typedef_name in pairs({
        CreateSolidBrush = 'ESP_CreateSolidBrush_t',
        CreatePen = 'ESP_CreatePen_t',
        SelectObject = 'ESP_SelectObject_t',
        DeleteObject = 'ESP_DeleteObject_t',
        CreateCompatibleDC = 'ESP_CreateCompatibleDC_t',
        CreateCompatibleBitmap = 'ESP_CreateCompatibleBitmap_t',
        BitBlt = 'ESP_BitBlt_t',
        DeleteDC = 'ESP_DeleteDC_t',
        RoundRect = 'ESP_RoundRect_t',
        Ellipse = 'ESP_Ellipse_t',
        Rectangle = 'ESP_Rectangle_t',
        SetTextColor = 'ESP_SetTextColor_t',
        SetBkMode = 'ESP_SetBkMode_t',
        CreateFontA = 'ESP_CreateFont_t',
    }) do
        gdi32[export] = bind_export(gdi32_lib, export, typedef_name)
    end
    kernel32.GetModuleHandleA = bind_export(kernel32_lib, 'GetModuleHandleA',
                                            'ESP_GetModuleHandleA_t')
    kernel32.GetCurrentProcessId = bind_export(kernel32_lib, 'GetCurrentProcessId',
                                               'ESP_GetCurrentProcessId_t')
    kernel32.GetLastError = bind_export(kernel32_lib, 'GetLastError',
                                        'uint32_t (*)(void)')
    kernel32.MultiByteToWideChar = bind_export(kernel32_lib, 'MultiByteToWideChar',
                                               'ESP_MultiByteToWideChar_t')

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
    local C_BG       = rgb(0x10, 0x13, 0x15)
    local C_BAR      = rgb(0x1A, 0x1E, 0x20)
    local C_TITLE    = rgb(0xF1, 0xF2, 0xE9)
    local C_LABEL    = rgb(0xD1, 0xD5, 0xCC)
    local C_DIM      = rgb(0xA2, 0xAD, 0xAA)
    local C_TRACK    = rgb(0x46, 0x4D, 0x4D)
    local C_ACCENT   = rgb(0xF4, 0xD8, 0x35)
    local C_BUTTON   = rgb(0x28, 0x2E, 0x30)
    local C_OK       = rgb(0xBF, 0xD4, 0x9C)
    local C_WARN     = rgb(0xE4, 0xC9, 0x69)
    local C_DANGER   = rgb(0xFF, 0x87, 0x76)
    local C_BORDER   = rgb(0x39, 0x42, 0x43)
    local C_SELECTED = rgb(0x32, 0x33, 0x25)
    local C_WARNING  = rgb(0x35, 0x21, 0x1E)
    local C_INK      = rgb(0x14, 0x18, 0x19)

    -- Three fixed fonts, created once and released with the window. Private
    -- function pointers preserve the shared-FFI collision protection.
    local fonts = {}
    for name,spec in pairs({body={16,600},small={13,500},heading={26,700}}) do
        local font=gdi32.CreateFontA(-spec[1],0,0,0,spec[2],0,0,0,1,0,0,5,0,'Microsoft YaHei UI')
        if font~=nil then fonts[name]=font end
    end
    local function release_fonts()
        for name,font in pairs(fonts) do gdi32.DeleteObject(font);fonts[name]=nil end
    end

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
                   toggle_hint = model.text('toggle')}

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

    -- ------------------------------------------------------------- persistence
    -- Saves are best-effort and never raise: a read-only profile directory or a
    -- full disk must not tear the panel down. The committed editor state is what
    -- gets written, because that is the profile the patch is actually running.
    local function save_settings()
        if config or not store then return end
        local called, ok, reason = pcall(store.save, model.pending)
        if not called then
            emit('config_save_error', tostring(ok))
        elseif not ok then
            emit('config_save_rejected', tostring(reason))
        end
    end

    -- Restore the profile saved on a previous launch. This runs during addon
    -- startup (before the first updater pass), so a saved configuration is live
    -- without the player having to open the panel or touch a slider.
    local function restore_settings()
        if config then model.import(config.current()); return end
        if not store then return end
        local called, saved, reason = pcall(store.load)
        if not called then
            emit('config_load_error', tostring(saved))
            return
        end
        if not saved then
            -- A first launch simply has no file yet; that is not a fault.
            if reason and reason ~= 'not_found' then
                emit('config_load_skipped', tostring(reason))
            end
            return
        end
        if not model.import(saved) then return end
        local applied, apply_reason = model.apply(patch)
        if applied then
            local p = model.pending
            emit('config_restored', string.format(
                'budget=%.1f count=%.1f enc_cd=%.0fs patrol_cd=%.0fs preset=%s',
                p.budget, p.patrol_count, p.encounter_cd, p.patrol_cd, p.preset))
        else
            -- A stored profile this build rejects must not leave the editor
            -- showing values that were never applied; fall back to the live one.
            emit('config_restore_rejected', tostring(apply_reason))
            pcall(model.sync_from_patch, patch)
        end
    end
    restore_settings()
    model.committed = {}
    for key, value in pairs(model.pending) do model.committed[key] = value end
    local unsubscribe
    if config then
        unsubscribe = config.subscribe(function(profile, changed)
            -- A submitted field wins; unrelated F8 drafts remain staged.
            for key in pairs(changed) do model.pending[key] = profile[key] end
            model.committed = profile
            if changed.language then
                model.set_language(profile.language)
                panel.status = ''
            end
            if panel.drag_slider and changed[panel.drag_slider.key] then panel.drag_slider = nil end
            if panel.window ~= nil then user32.InvalidateRect(panel.window, nil, 0) end
        end)
    end

    function panel.apply()
        -- Applying must never raise: this runs from the window procedure, and an
        -- error there would escape into the updater hook.
        local called, ok, reason
        if config then
            called, ok, reason = pcall(config.commit, model.pending, 'panel')
            if called and ok then model.committed = config.current() end
        else
            called, ok, reason = pcall(model.apply, patch)
        end
        if not called then
            panel.status, panel.status_until = model.text('failed') .. tostring(ok), os.clock() + 3.0
            emit('panel_apply_error', tostring(ok))
            return false
        end
        if not ok then
            panel.status, panel.status_until = model.text('failed') .. tostring(reason), os.clock() + 3.0
            emit('panel_apply_rejected', tostring(reason))
            return false
        end
        panel.status, panel.status_until = model.text('applied'), os.clock() + 1.5
        local p = model.pending
        emit('panel_applied', string.format(
            'budget=%.1f count=%.1f enc_cd=%.0fs patrol_cd=%.0fs preset=%s',
            p.budget, p.patrol_count, p.encounter_cd, p.patrol_cd, p.preset))
        -- Persist exactly what was just committed so the next launch restores it.
        save_settings()
        return true
    end

    function panel.set_language(language)
        local called, accepted, reason = true, true, nil
        if config then
            called, accepted, reason = pcall(config.commit, {language=language}, 'panel-language')
        else
            accepted = model.set_language(language)
            if accepted then
                model.committed.language = language
                if store then pcall(store.save, model.committed) end
            end
        end
        if not called or not accepted then
            emit('panel_language_rejected', tostring(called and reason or accepted))
            return false
        end
        model.set_language(language)
        panel.status = ''
        if panel.window ~= nil then user32.InvalidateRect(panel.window, nil, 0) end
        return true
    end

    function panel.export()
        if type(export_diag) ~= 'function' then
            panel.status, panel.status_until = model.text('export_unavailable'), os.clock() + 3.0
            emit('bb_export_unavailable', '')
            return false
        end
        local called, folder, err = pcall(export_diag)
        if not called then
            panel.status, panel.status_until = model.text('export_failed'), os.clock() + 3.0
            emit('bb_export_error', tostring(folder))
            return false
        end
        if not folder then
            panel.status, panel.status_until = model.text('export_failed') .. ': ' .. tostring(err), os.clock() + 3.0
            return false
        end
        panel.status, panel.status_until = model.text('exported'), os.clock() + 3.0
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

    local function draw_text(dc, text, x, y, w, h, color, center, font)
        if type(text) ~= 'string' or text == '' then return end
        local buffer, length = wide(text)
        if not buffer then return end
        local rect = ffi.new(RECT, x, y, x + w, y + h)
        gdi32.SetTextColor(dc, color)
        gdi32.SetBkMode(dc, TRANSPARENT)
        local format = center and (DT_CENTER + DT_VCENTER + DT_SINGLELINE) or (DT_LEFT + DT_VCENTER + DT_SINGLELINE)
        local handle=fonts[font or 'body']
        local previous=handle and gdi32.SelectObject(dc,handle)
        user32.DrawTextW(dc, buffer, length, rect, format)
        if previous then gdi32.SelectObject(dc,previous) end
    end

    local function frame(dc,x,y,w,h,edge,background)
        fill(dc,x,y,w,h,edge)
        fill(dc,x+1,y+1,w-2,h-2,background)
    end
    local function hover_key(kind,item)
        return kind..':'..tostring(item.id or item.key)..':'..tostring(item.value or '')
    end
    local function hovered(kind,item) return panel.hover==hover_key(kind,item) end
    local function section(dc,label,y)
        draw_text(dc,label,32,y,300,22,C_ACCENT,false,'small')
        fill(dc,344,y+10,304,1,C_BORDER)
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
        frame(memory,0,0,width,height,C_BORDER,C_BG)
        fill(memory, 1, 1, width-2, model.HEADER_H-1, C_BAR)
        fill(memory,0,0,width,3,C_ACCENT)
        fill(memory,20,17,4,35,C_ACCENT)
        draw_text(memory, model.text('console'), 32, 10, width - 144, 34, C_TITLE,false,'heading')
        draw_text(memory, model.text('console_hint'), 32, 44, width-160, 20,C_DIM,false,'small')
        draw_text(memory, (TITLE:match('[vV][%d%.]+') or ''):lower(), width-108, 52, 88, 16,C_DIM,true,'small')
        panel.toggle_hint = model.text(panel.custom_binding and 'custom_key' or 'toggle')
        frame(memory,width-108,22,88,28,C_TRACK,C_BG)
        draw_text(memory, panel.toggle_hint, width - 108, 22, 88, 28, C_LABEL,true,'small')
        frame(memory,20,84,width-40,246,C_BORDER,C_BAR)
        section(memory,model.text('spawn_section'),88)

        local widgets = model.layout()
        for _, item in ipairs(widgets.sliders) do
            if hovered('slider',item) or (panel.drag_slider and panel.drag_slider.key==item.key) then
                fill(memory,28,item.y,width-56,item.h,C_BUTTON)
            end
            draw_text(memory, item.label, item.x, item.y, 128, item.h, C_LABEL)
            local track_x, track_w, track_y = item.track_x, item.track_w, item.track_y
            fill(memory, track_x, track_y - 2, track_w, 4, C_TRACK)
            for tick=0,5 do
                fill(memory,track_x+math.floor(track_w*tick/5),track_y+5,1,4,C_TRACK)
            end
            local ratio = model.slider_ratio(item)
            local knob_x = track_x + math.floor(ratio * track_w + 0.5)
            fill(memory, track_x, track_y - 2, math.max(1, knob_x - track_x), 4, C_ACCENT)
            frame(memory,knob_x-5,track_y-9,10,18,C_INK,C_ACCENT)
            if item.kind == 'cooldown' then
                draw_text(memory, model.text('fast'), track_x - 38, item.y, 32, item.h, C_DIM, true,'small')
                draw_text(memory, model.text('slow'), track_x + track_w + 12, item.y, 60, item.h, C_DIM, true,'small')
            else
                -- The value turns red while this row is over its risk threshold, so
                -- the cause of the corner warning is visible at a glance.
                local value_color = model.at_risk(item) and C_DANGER or C_TITLE
                frame(memory,item.x+item.w-62,item.y+5,62,26,C_BORDER,C_BG)
                draw_text(memory, model.format(item), item.x + item.w - 62, item.y+5, 62, 26, value_color,true)
            end
        end

        section(memory,model.text('assist_section'),344)
        for _, item in ipairs(widgets.checkboxes or {}) do
            local checked = model.pending[item.key] and true or false
            frame(memory,item.x,item.y,item.w,item.h,hovered('checkbox',item) and C_ACCENT or C_BORDER,C_BAR)
            local label=model.text(item.key=='fast_corpse' and 'fast_corpse_short' or 'dynamic_spawn_short')
            local label_y=item.key=='fast_corpse' and 3 or 11
            draw_text(memory,label,item.x+12,item.y+label_y,item.w-60,22,checked and C_TITLE or C_LABEL)
            if item.key=='fast_corpse' then
                draw_text(memory,model.text('fast_corpse_hint'),item.x+12,item.y+24,item.w-24,17,C_DIM,false,'small')
            end
            local badge_y=item.key=='fast_corpse' and 7 or 14
            fill(memory,item.x+item.w-42,item.y+badge_y,32,17,checked and C_ACCENT or C_TRACK)
            draw_text(memory,model.text(checked and 'enabled' or 'disabled'),item.x+item.w-42,item.y+badge_y,
                32,17,checked and C_INK or C_TITLE,true,'small')
        end

        section(memory,model.text('composition_section'),model.PRESET_HEADER_Y)
        for _, item in ipairs(widgets.radios) do
            local selected = model.pending[item.key] == item.value
            frame(memory,item.x,item.y,item.w,item.h,(selected or hovered('radio',item)) and C_ACCENT or C_BORDER,
                selected and C_SELECTED or C_BAR)
            if selected then fill(memory,item.x,item.y,4,item.h,C_ACCENT) end
            draw_text(memory, item.label, item.x+14,item.y+3,item.w-24,22,selected and C_ACCENT or C_LABEL)
            draw_text(memory, model.text(item.value..'_hint'),item.x+14,item.y+25,item.w-24,17,C_DIM,false,'small')
        end

        for _, item in ipairs(widgets.buttons) do
            frame(memory,item.x,item.y,item.w,item.h,(item.accent or hovered('button',item)) and C_ACCENT or C_TRACK,
                item.accent and C_ACCENT or C_BUTTON)
            draw_text(memory,item.label,item.x,item.y,item.w,item.h,item.accent and C_INK or C_TITLE,true)
        end

        -- Prefer the transient apply result; otherwise state what the committed
        -- configuration will do, so "did it apply?" is never ambiguous.
        local footer, footer_color = nil, C_OK
        if runtime and runtime.active == false then
            footer, footer_color = model.text('waiting'), C_WARN
        else
            footer, footer_color = model.text('active'), C_OK
        end
        if panel.status ~= '' and os.clock() < panel.status_until then
            footer, footer_color = panel.status, C_OK
        end
        fill(memory,32,576,width-64,1,C_BORDER)
        fill(memory,32,589,5,5,footer_color)
        draw_text(memory, footer, 46, 581, CLIENT_W - 78, 22, footer_color,false,'small')

        -- High-pressure warning at the bottom. It reflects the editor state, so it
        -- appears as soon as a slider crosses the threshold and clears when the
        -- player moves it back; Apply is not required.
        if model.pressure_warning() then
            local PRESSURE_WARNING = model.text('pressure')
            fill(memory,20,CLIENT_H-32,width-40,24,C_WARNING)
            fill(memory,20,CLIENT_H-32,3,24,C_DANGER)
            draw_text(memory, PRESSURE_WARNING, 32, CLIENT_H - 32,
                      CLIENT_W - 64, 24, C_DANGER,false,'small')
        end

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
        elseif kind == 'checkbox' then
            model.pending[item.key] = not model.pending[item.key]
            user32.InvalidateRect(panel.window, nil, 0)
        elseif kind == 'radio' then
            model.pending[item.key] = item.value
            user32.InvalidateRect(panel.window, nil, 0)
        elseif kind == 'button' then
            if item.id == 'apply' then
                panel.apply()
            elseif item.id == 'reset' then
                model.reset()
            elseif item.id == 'export' then
                panel.export()
            elseif item.id == 'language' then
                panel.set_language(model.language == 'zh' and 'en' or 'zh')
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
            local kind,item=model.hit(x,y)
            local hover=item and hover_key(kind,item) or nil
            if hover~=panel.hover then panel.hover=hover;user32.InvalidateRect(window,nil,0) end
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
            80, 24, CLIENT_W, CLIENT_H, nil, nil, instance, nil)
        if panel.window == nil then error('panel_create_window_failed') end
    end)
    if not ok then
        release_fonts()
        if unsubscribe then unsubscribe(); unsubscribe = nil end
        log('panel_unavailable', tostring(err))
        return nil, tostring(err)
    end

    -- ------------------------------------------------------------------- pump
    local previous_key = false
    local binding_logged = false

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
                    panel.custom_binding = true
                    emit('panel_binding_active', 'using the Mod Bindings Menu slot')
                end
            end
        end
        if key == nil then
            key = bit.band(user32.GetAsyncKeyState(VK_F8), 0x8000) ~= 0
        end
        panel.toggle_hint = model.text(binding_logged and 'custom_key' or 'toggle')

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
        if unsubscribe then unsubscribe(); unsubscribe = nil end
        if panel.window then user32.DestroyWindow(panel.window) end
        panel.window = nil
        release_fonts()
    end

    return panel
end
