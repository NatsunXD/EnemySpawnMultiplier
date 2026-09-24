-- Bridge to the separately installed Mod Bindings Menu addon.
--
-- That addon exposes `_G.ModBindingsMenu` (api 1) with:
--   register_binding(id, label_id, slot) -> ok, reason
--   is_down(id)                         -> true/false, or nil while native input loads
-- Slot 1 belongs to Galactic Menu Hotkey; slot 2 is the only third-party slot.
-- `label_id` must be a game localization ID, not free text, so the bindings row
-- borrows an existing game string.
--
-- The two addons may start in either order, so registration is retried until it
-- succeeds. A slot conflict is permanent, so that stops the retries.
--
-- Mod Bindings Menu is strictly optional: when it is absent this provider reports
-- nothing and the panel keeps its built-in F8 default.
return function(options)
    options = options or {}
    local id = options.id
    local label_id = options.label_id
    local slot = options.slot or 2
    local provider = {registered = false, abandoned = false, reason = nil}

    local function menu()
        local candidate = rawget(_G, 'ModBindingsMenu')
        if type(candidate) ~= 'table' or candidate.api ~= 1 then return nil end
        return candidate
    end

    function provider.available()
        return menu() ~= nil
    end

    function provider.register()
        if provider.registered then return true end
        if provider.abandoned then return false end
        local host = menu()
        if not host or type(host.register_binding) ~= 'function' then return false end
        local ok, reason = host.register_binding(id, label_id, slot)
        if ok then
            provider.registered, provider.reason = true, nil
            return true
        end
        -- These two cannot resolve themselves by retrying.
        if reason == 'slot already in use' or reason == 'binding already registered differently'
            or reason == 'invalid binding registration' then
            provider.abandoned, provider.reason = true, reason
            return false
        end
        return false
    end

    function provider.is_down()
        if not provider.registered then return nil end
        local host = menu()
        if not host or type(host.is_down) ~= 'function' then return nil end
        local down = host.is_down(id)
        if type(down) ~= 'boolean' then return nil end
        return down
    end

    return provider
end
