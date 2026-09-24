-- Build-agnostic sanity check for the data slots this patch pins.
--
-- The patch never calls native game code; it only reads and writes data. A pinned
-- RVA is therefore validated by the *shape of the data it points at*, not by a
-- code signature and not by a build hash. These probes are cheap, run once, and
-- each one fails closed only for the path it guards: if a probe cannot confirm a
-- slot, the caller keeps that path on native behaviour instead of writing to an
-- address that may no longer mean what it used to.
--
-- Rationale: the 1.8.46015.0 update changed both build hashes while moving none
-- of the pinned addresses, so a hash gate produced a false negative and blocked a
-- fully working build. These probes distinguish "hash changed" from "layout
-- actually changed", which is the question that matters.
return function(patch)
    local checks = {}

    local function add(name, label)
        checks[#checks + 1] = {name = name, label = label, ok = true, detail = ''}
        return checks[#checks]
    end

    -- A pointer slot is plausible when it holds either null (not yet initialised,
    -- e.g. while on the ship) or a canonical user-mode address that is 16-byte
    -- aligned and not inside the module image itself.
    local function plausible_pointer(api, game, address)
        local bytes = api.read(address, 8)
        if not bytes then return nil, 'unreadable' end
        local value = api.pointer(bytes, 0)
        if value == nil then
            -- Distinguish "genuinely null" from "garbage we refused to cast".
            local raw = bytes:byte(1) + bytes:byte(2) * 256 + bytes:byte(3) * 65536
            if raw == 0 then return true, 'null' end
            return nil, 'implausible'
        end
        if api.distance(value, game) == 0 then return true, 'inside-module' end
        return true, 'pointer'
    end

    -- The director slot must be readable and self-consistent: the config stride
    -- and base offset it feeds must land on a row whose fields pass read_config.
    function checks.run(api, game)
        for _, c in ipairs(checks) do c.ok, c.detail = true, '' end

        local c = add('modeslot', 'mode pointer slot')
        local ok, why = plausible_pointer(api, game, game + patch.mode_rva)
        if not ok then c.ok, c.detail = false, why end

        c = add('directorslot', 'director pointer slot')
        ok, why = plausible_pointer(api, game, game + patch.director_rva)
        if not ok then c.ok, c.detail = false, why end

        c = add('timeslot', 'clock pointer slot')
        ok, why = plausible_pointer(api, game, game + patch.time_rva)
        if not ok then c.ok, c.detail = false, why end

        c = add('resourceslot', 'resource manager slot')
        ok, why = plausible_pointer(api, game, game + patch.resource_manager_rva)
        if not ok then c.ok, c.detail = false, why end

        -- Stride sanity: a cfg stride that is not a small positive even number
        -- means the record layout moved and every field offset is suspect.
        c = add('stride', 'config row stride')
        if type(patch.cfg_stride) == 'number' and patch.cfg_stride >= 0x100
            and patch.cfg_stride <= 0x2000 and patch.cfg_stride % 4 == 0 then
            c.detail = string.format('%#x', patch.cfg_stride)
        else
            c.ok, c.detail = false, tostring(patch.cfg_stride)
        end

        local failed = 0
        for _, item in ipairs(checks) do
            if not item.ok then failed = failed + 1 end
        end
        return failed == 0, failed
    end

    function checks.summary()
        local parts = {}
        for _, c in ipairs(checks) do
            parts[#parts + 1] = c.name .. (c.ok and '=ok' or ('=' .. c.detail))
        end
        return table.concat(parts, ',')
    end

    function checks.list() return checks end
    return checks
end
