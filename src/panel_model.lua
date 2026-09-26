-- Pure state and geometry for the in-game configuration panel.
--
-- This module deliberately has no FFI and no Windows calls so the slider grid,
-- hit testing and settings mapping can be unit tested offline. panel.lua owns
-- the window, painting and input and only reads through this model.
return function()
    local M = {}

    -- Width fits the full 'EnemySpawnMultiplier v21 by Natsun' title plus the
    -- toggle hint on the same row.
    M.CLIENT_W, M.CLIENT_H = 580, 500
    M.SLIDER_MIN, M.SLIDER_MAX = 0.1, 6.0
    M.SLIDER_STEPS = 59 -- inclusive 0.1 grid across 0.1 .. 6.0
    M.PATROL_SIZE_MIN, M.PATROL_SIZE_MAX = 0.1, 2.0
    M.PATROL_SIZE_STEPS = 19

    -- Above 1.0x the patrol pair is considered high pressure. The panel only
    -- warns; nothing is clamped, so a player who wants the load can still set it.
    M.PATROL_COUNT_RISK = 1.0
    M.PATROL_SIZE_RISK = 1.0

    -- Cooldown controls are a continuous interval in seconds: 2 s at the fast
    -- end, 30 s (native pacing) at the slow end.
    M.COOLDOWN_FAST, M.COOLDOWN_SLOW = 2.0, 30.0
    M.COOLDOWN_STEPS = 28 -- 1 s grid across 2 .. 30

    local DEFAULTS = {
        budget = 2.0, patrol_count = 1.0, patrol_size = 1.0,
        encounter_cd = M.COOLDOWN_FAST, patrol_cd = M.COOLDOWN_FAST, preset = 'heavy',
        fast_corpse = true,
    }

    local SLIDER_LABELS = {
        {key = 'budget', label = '增援预算'},
        {key = 'patrol_count', label = '巡逻数量'},
        {key = 'patrol_size', label = '巡逻规模', min = M.PATROL_SIZE_MIN, max = M.PATROL_SIZE_MAX, steps = M.PATROL_SIZE_STEPS},
        {key = 'encounter_cd', label = '增援 CD', kind = 'cooldown'},
        {key = 'patrol_cd', label = '巡逻 CD', kind = 'cooldown'},
    }
    -- Simple on/off rows rendered as checkboxes, below the sliders.
    local CHECKBOX_LABELS = {
        {key = 'fast_corpse', label = '尸体快速消失（保留布娃娃）'},
    }

    local RADIO_LABELS = {
        {value = 'heavy', label = '偏向重甲（重甲更多）'},
        {value = 'light_medium', label = '偏向轻中甲（轻中甲更多）'},
        {value = 'native', label = '原版（不改模板权重）'},
    }

    function M.reset()
        M.pending, M.committed = {}, nil
        for key, value in pairs(DEFAULTS) do M.pending[key] = value end
    end
    M.reset()

    -- Geometry is declared once so painting and hit testing can never disagree.
    function M.layout()
        local sliders = {}
        for index, def in ipairs(SLIDER_LABELS) do
            sliders[index] = {
                key = def.key, label = def.label, kind = def.kind or 'multiplier',
                min = def.min, max = def.max, steps = def.steps,
                x = 24, y = 52 + (index - 1) * 42, w = M.CLIENT_W - 48, h = 34,
            }
            local item = sliders[index]
            item.track_x, item.track_w = item.x + 126, item.w - 126 - 88
            item.track_y = item.y + 16
        end
        -- Checkbox rows sit directly under the slider block; the preset block
        -- follows them. Everything is derived so adding a slider or a checkbox
        -- cannot silently overlap what is below it.
        local last_slider = sliders[#sliders]
        local checkboxes = {}
        for index, def in ipairs(CHECKBOX_LABELS) do
            checkboxes[index] = {key = def.key, label = def.label,
                                 x = 28, y = last_slider.y + last_slider.h + 8 + (index - 1) * 28,
                                 w = M.CLIENT_W - 56, h = 24}
        end
        local last_checkbox = checkboxes[#checkboxes] or last_slider
        M.PRESET_HEADER_Y = last_checkbox.y + last_checkbox.h + 6
        local presets_y = M.PRESET_HEADER_Y + 24
        local radios = {}
        for index, def in ipairs(RADIO_LABELS) do
            radios[index] = {key = 'preset', value = def.value, label = def.label,
                             x = 28, y = presets_y + (index - 1) * 28,
                             w = M.CLIENT_W - 56, h = 24}
        end
        local last_radio = radios[#radios]
        local buttons_y = last_radio.y + last_radio.h + 16
        M.BUTTONS_Y = buttons_y
        local buttons = {
            {id = 'apply', label = '应用', x = 72, y = buttons_y, w = 92, h = 32, accent = true},
            {id = 'reset', label = '重置', x = 180, y = buttons_y, w = 92, h = 32},
            {id = 'export', label = '导出游戏日志', x = 288, y = buttons_y, w = 148, h = 32},
        }
        return {sliders = sliders, checkboxes = checkboxes, radios = radios, buttons = buttons}
    end

    function M.inside(x, y, item)
        return x >= item.x and x <= item.x + item.w and y >= item.y and y <= item.y + item.h
    end

    -- Snap a track position to the multiplier step grid.
    function M.slider_to_value(position)
        local steps = math.floor(position + 0.5)
        if steps < 0 then steps = 0 elseif steps > M.SLIDER_STEPS then steps = M.SLIDER_STEPS end
        return math.floor((M.SLIDER_MIN + steps * (M.SLIDER_MAX - M.SLIDER_MIN) / M.SLIDER_STEPS) * 10 + 0.5) / 10
    end

    -- Snap a track position to the cooldown step grid (whole seconds, 2 .. 30).
    function M.cooldown_to_value(position)
        local steps = math.floor(position + 0.5)
        if steps < 0 then steps = 0 elseif steps > M.COOLDOWN_STEPS then steps = M.COOLDOWN_STEPS end
        return M.COOLDOWN_FAST + steps
    end

    local function is_cooldown(item) return item.kind == 'cooldown' end

    function M.slider_ratio(item)
        local value = M.pending[item.key]
        if is_cooldown(item) then
            return (value - M.COOLDOWN_FAST) / (M.COOLDOWN_SLOW - M.COOLDOWN_FAST)
        end
        local min, max = item.min or M.SLIDER_MIN, item.max or M.SLIDER_MAX
        return (value - min) / (max - min)
    end

    function M.set_slider(item, x)
        local ratio = (x - item.track_x) / item.track_w
        if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end
        if is_cooldown(item) then
            M.pending[item.key] = M.cooldown_to_value(ratio * M.COOLDOWN_STEPS)
        else
            local min, max, steps = item.min or M.SLIDER_MIN, item.max or M.SLIDER_MAX, item.steps or M.SLIDER_STEPS
            M.pending[item.key] = math.floor((min + math.floor(ratio * steps + 0.5) * (max - min) / steps) * 10 + 0.5) / 10
        end
        return M.pending[item.key]
    end

    -- Is this slider currently in the high-pressure region? Only the patrol pair
    -- has thresholds; every other row is never "at risk".
    function M.at_risk(item)
        if item.key == 'patrol_count' then return M.pending.patrol_count > M.PATROL_COUNT_RISK end
        if item.key == 'patrol_size' then return M.pending.patrol_size > M.PATROL_SIZE_RISK end
        return false
    end

    -- True when any slider is over its threshold. The panel uses this for the
    -- corner warning; it is a display-only signal and never blocks Apply.
    function M.pressure_warning()
        return M.at_risk({key = 'patrol_count'}) or M.at_risk({key = 'patrol_size'})
    end

    -- Cooldown sliders deliberately show no number: the requested UI is just the
    -- fast/slow words at the two ends, so this returns an empty value label.
    function M.format(item)
        if is_cooldown(item) then return '' end
        return string.format('%.1fx', M.pending[item.key])
    end

    -- Map the panel state onto the patch.configure() surface. Cooldown sliders
    -- move along the native..short rate range; the short end additionally pins
    -- the reinforcement deadline to the 2 s preset.
    function M.settings(patch)
        return {
            budget = M.pending.budget,
            patrol_count = M.pending.patrol_count,
            patrol_size = M.pending.patrol_size,
            encounter_cd_seconds = M.pending.encounter_cd,
            patrol_cd_seconds = M.pending.patrol_cd,
            fast_corpse = M.pending.fast_corpse,
            preset = M.pending.preset,
        }
    end

    -- Mirror the profile that is already live so the panel opens showing the
    -- truth instead of the built-in defaults. Values outside the slider range are
    -- clamped for display; the shipped profiles are all inside it.
    function M.sync_from_patch(patch)
        M.pending.budget = M.slider_to_value(math.floor(
            (math.min(math.max(patch.budget_multiplier, M.SLIDER_MIN), M.SLIDER_MAX) - M.SLIDER_MIN)
            / (M.SLIDER_MAX - M.SLIDER_MIN) * M.SLIDER_STEPS + 0.5))
        M.pending.patrol_count = M.slider_to_value(math.floor(
            (math.min(math.max(patch.modifier_patrol_count, M.SLIDER_MIN), M.SLIDER_MAX) - M.SLIDER_MIN)
            / (M.SLIDER_MAX - M.SLIDER_MIN) * M.SLIDER_STEPS + 0.5))
        -- A disabled deadline clamp means the slow/native end, regardless of any
        -- stale interval value left behind by a previous configuration.
        if patch.encounter_deadline_enabled then
            M.pending.encounter_cd = M.cooldown_to_value(math.floor(
                (math.min(math.max(patch.encounter_max_interval or M.COOLDOWN_FAST,
                                   M.COOLDOWN_FAST), M.COOLDOWN_SLOW) - M.COOLDOWN_FAST)
                / (M.COOLDOWN_SLOW - M.COOLDOWN_FAST) * M.COOLDOWN_STEPS + 0.5))
        else
            M.pending.encounter_cd = M.COOLDOWN_SLOW
        end
        local size_steps = (math.min(math.max(patch.modifier_travelers_max_unit, M.PATROL_SIZE_MIN), M.PATROL_SIZE_MAX) - M.PATROL_SIZE_MIN)
            / (M.PATROL_SIZE_MAX - M.PATROL_SIZE_MIN) * M.PATROL_SIZE_STEPS
        M.pending.patrol_size = math.floor((M.PATROL_SIZE_MIN + math.floor(size_steps + 0.5)
            * (M.PATROL_SIZE_MAX - M.PATROL_SIZE_MIN) / M.PATROL_SIZE_STEPS) * 10 + 0.5) / 10
        -- The patrol curve has its own fastest-end scale, so decode it with the
        -- patrol rate rather than the reinforcement rate.
        local patrol_rate = patch.patrol_cooldown_fast_rate or patch.cooldown_fast_rate
        local patrol_seconds = M.COOLDOWN_SLOW
        if patrol_rate and patrol_rate > 1.0 then
            patrol_seconds = M.COOLDOWN_SLOW
                - (patch.modifier_patrol_cooldown - 1.0) / (patrol_rate - 1.0)
                    * (M.COOLDOWN_SLOW - M.COOLDOWN_FAST)
        end
        M.pending.patrol_cd = M.cooldown_to_value(math.floor(
            (math.min(math.max(patrol_seconds, M.COOLDOWN_FAST), M.COOLDOWN_SLOW) - M.COOLDOWN_FAST)
            / (M.COOLDOWN_SLOW - M.COOLDOWN_FAST) * M.COOLDOWN_STEPS + 0.5))
        if type(patch.fast_corpse) == 'boolean' then
            M.pending.fast_corpse = patch.fast_corpse
        end
        if not patch.template_bias_enabled then
            M.pending.preset = 'native'
        elseif patch.template_bias_light >= patch.template_bias_heavy then
            M.pending.preset = 'light_medium'
        else
            M.pending.preset = 'heavy'
        end
        return M.pending
    end

    -- Load a persisted profile onto the editor. Values are snapped onto the same
    -- slider grid the mouse uses, so a file written by an older build can never
    -- leave the knobs off-grid. Only recognised fields are accepted; a malformed
    -- file therefore degrades to the affected defaults instead of being applied
    -- wholesale. Returns true when at least one control was restored.
    function M.import(settings)
        if type(settings) ~= 'table' then return false end
        local function snap_multiplier(value)
            if type(value) ~= 'number' or value ~= value then return nil end
            local steps = (value - M.SLIDER_MIN) / (M.SLIDER_MAX - M.SLIDER_MIN) * M.SLIDER_STEPS
            return M.slider_to_value(steps)
        end
        local function snap_cooldown(value)
            if type(value) ~= 'number' or value ~= value then return nil end
            local steps = (value - M.COOLDOWN_FAST) / (M.COOLDOWN_SLOW - M.COOLDOWN_FAST) * M.COOLDOWN_STEPS
            return M.cooldown_to_value(steps)
        end
        local changed = false
        local snaps = {
            budget = snap_multiplier, patrol_count = snap_multiplier,
            patrol_size = function(value)
                if type(value) ~= 'number' or value ~= value then return nil end
                local steps = (value - M.PATROL_SIZE_MIN) / (M.PATROL_SIZE_MAX - M.PATROL_SIZE_MIN) * M.PATROL_SIZE_STEPS
                local snapped = M.PATROL_SIZE_MIN + math.floor(steps + 0.5) * (M.PATROL_SIZE_MAX - M.PATROL_SIZE_MIN) / M.PATROL_SIZE_STEPS
                return math.floor(snapped * 10 + 0.5) / 10
            end,
            encounter_cd = snap_cooldown, patrol_cd = snap_cooldown,
        }
        for key, snap in pairs(snaps) do
            local value = snap(settings[key])
            if value then M.pending[key] = value; changed = true end
        end
        local fast_corpse = settings.fast_corpse
        if type(fast_corpse) == 'boolean' then
            M.pending.fast_corpse = fast_corpse
            changed = true
        end
        local preset = settings.preset
        if preset == 'heavy' or preset == 'light_medium' or preset == 'native' then
            M.pending.preset = preset
            changed = true
        end
        return changed
    end

    function M.apply(patch)
        local ok, reason = patch.configure(M.settings(patch))
        if not ok then return false, reason end
        M.committed = {}
        for key, value in pairs(M.pending) do M.committed[key] = value end
        return true
    end

    -- Returns the widget a click at (x, y) lands on, or nil for the background.
    function M.hit(x, y)
        local widgets = M.layout()
        for _, item in ipairs(widgets.sliders) do
            if M.inside(x, y, {x = item.track_x - 8, y = item.y, w = item.track_w + 16, h = item.h}) then
                return 'slider', item
            end
        end
        for _, item in ipairs(widgets.checkboxes or {}) do
            if M.inside(x, y, item) then return 'checkbox', item end
        end
        for _, item in ipairs(widgets.radios) do
            if M.inside(x, y, item) then return 'radio', item end
        end
        for _, item in ipairs(widgets.buttons) do
            if M.inside(x, y, item) then return 'button', item end
        end
        if y < 40 then return 'title' end
        return nil
    end

    return M
end
