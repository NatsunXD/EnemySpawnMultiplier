-- Pure state and geometry for the in-game configuration panel.
--
-- This module deliberately has no FFI and no Windows calls so the slider grid,
-- hit testing and settings mapping can be unit tested offline. panel.lua owns
-- the window, painting and input and only reads through this model.
return function()
    local M = {}
    M.language = 'zh'
    local TEXT = {
        zh = {
            budget='增援预算', patrol_count='巡逻数量', patrol_size='巡逻规模',
            encounter_cd='增援 CD', patrol_cd='巡逻 CD',
            fast_corpse='尸体快速消失（保留布娃娃）',
            fast_corpse_short='尸体快速消失', fast_corpse_hint='保留布娃娃',
            dynamic_spawn='动态生成补偿',
            dynamic_spawn_short='动态生成补偿',
            console='EnemySpawnMultiplier', console_hint='by Natsun',
            spawn_section='01 / 生成参数', assist_section='02 / 辅助控制',
            composition_section='03 / 增援构成',
            heavy_short='重甲优先', light_medium_short='轻中甲优先', native_short='原版构成',
            heavy_hint='提高重甲权重', light_medium_hint='提高轻 / 中甲权重', native_hint='保留原生权重',
            enabled='开启', disabled='关闭',
            heavy='偏向重甲（重甲更多）', light_medium='偏向轻中甲（轻中甲更多）',
            native='原版（不改模板权重）', presets='模板预设',
            apply='应用', reset='重置', export='导出游戏日志', language_button='English',
            language='语言 / Language', chinese='中文', english='English',
            applied='已应用', failed='失败：', export_unavailable='导出不可用',
            export_failed='导出失败', exported='已导出到桌面',
            waiting='尚未进入任务：配置已保存，进图后生效', active='已生效',
            wild_lobby='本模组不支持野房使用！',
            pressure='【民主预警】当前配置压力较大，游戏崩溃风险高',
            fast='快', slow='慢', toggle='F8 开关', custom_key='自定义键',
            budget_desc='每次增援的预算倍率，不是直接的敌人数量倍率。',
            patrol_count_desc='巡逻数量倍率；超过 1.0x 会增加压力和崩溃风险。',
            patrol_size_desc='巡逻规模倍率；超过 1.0x 会增加压力和崩溃风险。',
            encounter_cd_desc='目标增援间隔（秒）；30 秒使用原版节奏。',
            patrol_cd_desc='目标巡逻间隔（秒），通过倍率曲线近似；30 秒使用原版节奏。',
            fast_corpse_desc='加快尸体消失并保留布娃娃；关闭时恢复原值。',
            dynamic_spawn_desc='',
            preset_desc='调整增援模板权重：重甲、轻中甲或原版。',
            language_desc='切换 ESM 的中英文。F8 面板即时刷新；MODS 文案在重新打开暂停菜单后刷新。',
        },
        en = {
            budget='Wave budget', patrol_count='Patrol count', patrol_size='Patrol size',
            encounter_cd='Reinf. CD', patrol_cd='Patrol CD',
            fast_corpse='Fast corpse decay (keep ragdolls)',
            fast_corpse_short='Fast corpse decay', fast_corpse_hint='Keep ragdolls',
            dynamic_spawn='Dynamic spawn compensation',
            dynamic_spawn_short='Dynamic compensation',
            console='EnemySpawnMultiplier', console_hint='by Natsun',
            spawn_section='01 / SPAWN PARAMETERS', assist_section='02 / ASSIST CONTROLS',
            composition_section='03 / REINFORCEMENT MIX',
            heavy_short='HEAVY FOCUS', light_medium_short='LIGHT / MEDIUM', native_short='VANILLA',
            heavy_hint='Favor heavy units', light_medium_hint='Favor light / medium units', native_hint='Original template weights',
            enabled='ON', disabled='OFF',
            heavy='Heavy units (more heavy enemies)', light_medium='Light / medium units',
            native='Vanilla (original template weights)', presets='Composition preset',
            apply='Apply', reset='Reset', export='Export game logs', language_button='中文',
            language='Language / 语言', chinese='中文', english='English',
            applied='Applied', failed='Failed: ', export_unavailable='Export unavailable',
            export_failed='Export failed', exported='Exported to Desktop',
            waiting='Saved; takes effect when a mission starts', active='Active',
            wild_lobby='This mod does not support public lobbies!',
            pressure='High spawn pressure: increased risk of game crashes',
            fast='Fast', slow='Slow', toggle='F8 toggle', custom_key='Custom key',
            budget_desc='Budget per reinforcement wave, not a direct enemy-count multiplier.',
            patrol_count_desc='Patrol count multiplier. Above 1.0x increases load and crash risk.',
            patrol_size_desc='Patrol size multiplier. Above 1.0x increases load and crash risk.',
            encounter_cd_desc='Target reinforcement interval in seconds. 30 uses vanilla pacing.',
            patrol_cd_desc='Approximate patrol interval in seconds, mapped to a rate curve. 30 uses vanilla pacing.',
            fast_corpse_desc='Speed up corpse decay while keeping ragdolls; disabling restores original values.',
            dynamic_spawn_desc='',
            preset_desc='Reinforcement template weights: heavy, light / medium, or vanilla.',
            language_desc='ESM language. F8 updates immediately; reopen the escape menu to refresh MODS text.',
        },
    }
    function M.text(key, language)
        return (TEXT[language or M.language] or TEXT.zh)[key] or key
    end
    function M.set_language(language)
        if language ~= 'zh' and language ~= 'en' then return false end
        M.language, M.pending.language = language, language
        return true
    end

    M.CLIENT_W, M.CLIENT_H = 680, 640
    M.HEADER_H = 72
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
        fast_corpse = true, dynamic_spawn = true, language = 'zh',
    }

    local SLIDER_LABELS = {
        {key = 'budget'},
        {key = 'patrol_count'},
        {key = 'patrol_size', min = M.PATROL_SIZE_MIN, max = M.PATROL_SIZE_MAX, steps = M.PATROL_SIZE_STEPS},
        {key = 'encounter_cd', kind = 'cooldown'},
        {key = 'patrol_cd', kind = 'cooldown'},
    }
    -- Simple on/off rows rendered as checkboxes, below the sliders.
    local CHECKBOX_LABELS = {
        {key = 'fast_corpse'},
        {key = 'dynamic_spawn'},
    }

    local RADIO_LABELS = {
        {value = 'heavy'},
        {value = 'light_medium'},
        {value = 'native'},
    }

    function M.reset()
        M.pending = {}
        for key, value in pairs(DEFAULTS) do M.pending[key] = value end
        M.pending.language = M.language
    end
    M.reset()

    -- Geometry is declared once so painting and hit testing can never disagree.
    function M.layout()
        local sliders = {}
        for index, def in ipairs(SLIDER_LABELS) do
            sliders[index] = {
                key = def.key, label = M.text(def.key), kind = def.kind or 'multiplier',
                min = def.min, max = def.max, steps = def.steps,
                x = 36, y = 112 + (index - 1) * 42, w = M.CLIENT_W - 72, h = 36,
            }
            local item = sliders[index]
            item.track_x, item.track_w = item.x + 166, item.w - 166 - 84
            item.track_y = item.y + 18
        end
        local checkboxes = {}
        for index, def in ipairs(CHECKBOX_LABELS) do
            checkboxes[index] = {key = def.key, label = M.text(def.key),
                                 x = 32 + (index - 1) * 316, y = 372,
                                 w = 300, h = 44}
        end
        M.PRESET_HEADER_Y = 428
        local radios = {}
        for index, def in ipairs(RADIO_LABELS) do
            radios[index] = {key = 'preset', value = def.value, label = M.text(def.value..'_short'),
                             x = 32 + (index - 1) * 212, y = 456, w = 192, h = 46}
        end
        local buttons_y = 524
        M.BUTTONS_Y = buttons_y
        local buttons = {
            {id = 'apply', label = M.text('apply'), x = 32, y = buttons_y, w = 148, h = 40, accent = true},
            {id = 'reset', label = M.text('reset'), x = 192, y = buttons_y, w = 112, h = 40},
            {id = 'export', label = M.text('export'), x = 316, y = buttons_y, w = 180, h = 40},
            {id = 'language', label = M.text('language_button'), x = 508, y = buttons_y, w = 140, h = 40},
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
            dynamic_spawn = M.pending.dynamic_spawn,
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
        M.pending.dynamic_spawn=patch.dynamic_spawn_enabled~=false
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
        if settings.language == 'zh' or settings.language == 'en' then
            M.set_language(settings.language)
            changed = true
        end
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
        if type(settings.dynamic_spawn)=='boolean' then M.pending.dynamic_spawn=settings.dynamic_spawn;changed=true end
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
        M.set_language(M.pending.language or M.language)
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
        if y >=0 and y < M.HEADER_H then return 'title' end
        return nil
    end

    return M
end
