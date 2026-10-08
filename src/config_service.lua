-- One committed profile for the F8 editor, MODS menu and disk. No native calls.
return function(create_model, patch, options)
    options = options or {}
    local model, listeners = create_model(), {}
    local store, log = options.store, options.log or function() end
    local M = {revision = 0, restored = false}
    local function copy(values)
        local result = {}
        for key, value in pairs(values) do result[key] = value end
        return result
    end
    local function emit(kind, detail) pcall(log, kind, detail or '') end
    model.sync_from_patch(patch)
    local current = copy(model.pending)
    local numeric = {
        budget={0.1,6,0.1}, patrol_count={0.1,6,0.1}, patrol_size={0.1,2,0.1},
        encounter_cd={2,30,1}, patrol_cd={2,30,1},
    }
    local function valid(key, value)
        local range = numeric[key]
        if range then
            if type(value) ~= 'number' or value ~= value or value == math.huge
                or value == -math.huge or value < range[1] - 1e-7 or value > range[2] + 1e-7 then return false end
            local steps = (value - range[1]) / range[3]
            return math.abs(steps - math.floor(steps + 0.5)) < 1e-6
        end
        if key == 'preset' then return value == 'heavy' or value == 'light_medium' or value == 'native' end
        for _, field in ipairs(model.BOOLEAN_FIELDS) do
            if key == field then return type(value) == 'boolean' end
        end
        if key == 'language' then return value == 'zh' or value == 'en' end
        return false
    end
    function M.current() return copy(current) end
    function M.text(key, language) return model.text(key, language or current.language) end
    function M.subscribe(listener)
        listeners[#listeners + 1] = listener
        return function()
            for i, fn in ipairs(listeners) do
                if fn == listener then table.remove(listeners, i); break end
            end
        end
    end
    function M.commit(changes, source, restoring)
        if type(changes) ~= 'table' then return false, 'settings_not_a_table' end
        local next_profile, changed, gameplay = copy(current), {}, false
        for key, value in pairs(changes) do
            if not valid(key, value) then return false, 'invalid_' .. tostring(key) end
            next_profile[key] = value
            if current[key] ~= value then
                changed[key] = true
                if key ~= 'language' then gameplay = true end
            end
        end
        if gameplay or restoring then
            local candidate = create_model()
            candidate.pending = next_profile
            local called, accepted, reason = pcall(patch.configure, candidate.settings(patch))
            if not called then return false, tostring(accepted) end
            if not accepted then return false, reason end
        end
        if not next(changed) and not restoring then return true end
        current = next_profile
        model.set_language(current.language)
        M.revision = M.revision + 1
        if store and not restoring then
            local called, saved, reason = pcall(store.save, copy(current))
            if not called or not saved then emit('config_save_error', tostring(called and reason or saved)) end
        end
        emit(restoring and 'config_restored' or 'config_committed',
            'source=' .. tostring(source) .. ' revision=' .. M.revision .. ' language=' .. current.language)
        for _, listener in ipairs(listeners) do
            local ok, reason = pcall(listener, copy(current), copy(changed), source)
            if not ok then emit('config_sync_error', tostring(reason)) end
        end
        return true
    end
    -- This store is authoritative when both it and the menu have saved values.
    -- Only when it is absent may the bridge import the menu's saved profile.
    if store then
        local called, saved, reason = pcall(store.load)
        if called and saved then
            model.import(saved)
            local accepted, why = M.commit(model.pending, 'restore', true)
            M.restored = accepted == true
            if not accepted then emit('config_restore_rejected', tostring(why)) end
        elseif not called or (reason and reason ~= 'not_found') then
            emit('config_load_skipped', tostring(called and reason or saved))
        end
    end
    return M
end
