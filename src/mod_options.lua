-- Optional public ModOptionsMenu API bridge. Does not access game memory.
return function(config, options)
    options = options or {}
    local log = options.log or function() end
    local get_menu = options.get_menu or function() return rawget(_G, 'ModOptionsMenu') end
    local M = {status = 'waiting', reason = nil, registered = 0}
    local prefix = 'natsun.enemy_spawn_multiplier.'
    local menu, elapsed, staged, dirty, syncing = nil, 0, {}, false, false
    local rows = {
        {key='budget', type='slider', min=0.1, max=6, step=0.1},
        {key='patrol_count', type='slider', min=0.1, max=6, step=0.1},
        {key='patrol_size', type='slider', min=0.1, max=2, step=0.1},
        {key='encounter_cd', type='slider', min=2, max=30, step=1},
        {key='patrol_cd', type='slider', min=2, max=30, step=1},
        {key='preset', type='choice', choices={'heavy','light_medium','native'}, label='presets'},
        {key='fast_corpse', type='toggle'},
        {key='block_jumpers', type='toggle'},
        {key='block_yellow_spewers', type='toggle'},
        {key='block_green_spewers', type='toggle'},
        {key='block_bile_spitters', type='toggle'},
        {key='block_scavengers', type='toggle'},
        {key='block_shriekers', type='toggle'},
        {key='block_all_small', type='toggle'},
        {key='language', type='choice', choices={'chinese','english'}, values={'zh','en'}},
    }
    local function emit(kind, detail) pcall(log, kind, detail or '') end
    local function fail(reason)
        M.status, M.reason = 'unavailable', tostring(reason)
        emit('mods_menu_unavailable', M.reason)
    end
    local function encode(row, profile)
        if row.type ~= 'choice' then return profile[row.key] end
        for index, value in ipairs(row.values or row.choices) do
            if profile[row.key] == value then return index end
        end
    end
    local function decode(row, value)
        if row.type ~= 'choice' then return value end
        if type(value) ~= 'number' or value % 1 ~= 0 then return nil end
        return (row.values or row.choices)[value]
    end
    local function push(profile, changed)
        syncing = true
        for _, row in ipairs(rows) do
            if not changed or changed[row.key] ~= nil then
                local value = encode(row, profile)
                local got, old = pcall(menu.get, prefix .. row.key)
                if not got or old ~= value then
                    local ok, accepted, reason = pcall(menu.set, prefix .. row.key, value)
                    if not ok or accepted == false then
                        syncing = false
                        fail(ok and reason or accepted)
                        return false
                    end
                end
            end
        end
        syncing = false
        return true
    end
    config.subscribe(function(profile, changed, source)
        if M.status == 'ready' and source ~= 'mods' then push(profile, changed) end
    end)
    local function register(candidate)
        menu = candidate
        local profile, imported = config.current(), {}
        local translated = (tonumber(menu.version) or 1) >= 2
        local function text(key)
            if translated then return function() return config.text(key) end end
            -- v1 only accepts static strings with byte limits.
            return config.text(key, 'en')
        end
        for _, row in ipairs(rows) do
            local spec = {type=row.type, mod='Enemy Spawn Multiplier',
                mod_id='natsun.enemy_spawn_multiplier', label=text(row.label or row.key),
                description=translated and text(row.key .. '_desc') or config.text(row.key .. '_desc', 'en'),
                default=encode(row, profile)}
            if row.type == 'choice' then
                spec.choices = {}
                for index, key in ipairs(row.choices) do spec.choices[index] = text(key) end
            elseif row.type == 'slider' then spec.min, spec.max, spec.step = row.min, row.max, row.step end
            local ok, accepted, reason = pcall(menu.register_option, prefix .. row.key, spec)
            if not ok or not accepted then fail(ok and reason or accepted); return end
            M.registered = M.registered + 1
            local got, saved = pcall(menu.get, prefix .. row.key)
            if not got then fail(saved); return end
            local value = decode(row, saved)
            if value ~= nil then imported[row.key] = value end
            local callback = function(new)
                if syncing or M.status ~= 'ready' then return end
                local decoded = decode(row, new)
                staged[row.key] = decoded == nil and '__invalid__' or decoded
                dirty = true
            end
            local hooked, success = pcall(menu.on_change, prefix .. row.key, callback)
            if not hooked or success == false then fail('change callback rejected: ' .. row.key); return end
        end
        M.status = 'ready'
        if not config.restored and config.revision == 0 then
            local accepted, reason = config.commit(imported, 'mods')
            if not accepted then emit('mods_menu_saved_rejected', tostring(reason)) end
        end
        -- No outstanding user edits exist at startup, so settle every row once.
        if push(config.current()) then emit('mods_menu_ready', #rows .. ' options; F8 and MODS share one profile') end
    end
    function M.pump(dt)
        if M.status == 'waiting' then
            elapsed = elapsed + (type(dt) == 'number' and dt == dt and dt > 0 and dt or 0)
            local candidate = get_menu()
            if candidate then
                if type(candidate) ~= 'table' or candidate.api ~= 1 then fail('incompatible API'); return end
                for _, name in ipairs({'register_option','get','set','on_change'}) do
                    if type(candidate[name]) ~= 'function' then fail('missing ' .. name); return end
                end
                register(candidate)
            elseif elapsed >= 5 then fail('not installed; F8 remains available') end
        end
        if M.status == 'ready' and dirty then
            -- All APPLY callbacks finish before this next update: commit once.
            local changes = staged
            staged, dirty = {}, false
            local accepted, reason = config.commit(changes, 'mods')
            if not accepted then
                emit('mods_menu_apply_rejected', tostring(reason))
                push(config.current(), changes)
            end
        end
    end
    return M
end
