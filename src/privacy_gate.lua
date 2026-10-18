-- Pure matchmaking contamination latch (no game memory).
--
-- Contaminate when Public is held long enough, when a mission starts while
-- Public, or when SOS is spent. Clear only after a mission return on Friends,
-- or after Friends-only dwell on the ship. Solo (peer_count == 1) may bypass
-- Public/contamination gates; SOS never bypasses.

return function()
    local PUBLIC_HOLD_S = 6.0
    local FRIENDS_CLEAR_S = 180.0
    local PRIVACY_SAMPLE_S = 2.0

    local function new_state()
        return {
            contaminated = false,
            reason = nil,
            public_hold_s = 0,
            friends_dwell_s = 0,
            was_live = false,
            mission_return_pending = false,
        }
    end

    local function contaminate(state, reason)
        if state.contaminated and state.reason == 'sos' and reason ~= 'sos' then
            -- SOS stays the strongest reason until cleared.
            return false
        end
        local first = not state.contaminated
        state.contaminated = true
        state.reason = reason
        state.friends_dwell_s = 0
        return first
    end

    local function clear(state, how)
        if not state.contaminated then
            return false, nil
        end
        local previous = state.reason
        state.contaminated = false
        state.reason = nil
        state.public_hold_s = 0
        state.friends_dwell_s = 0
        state.mission_return_pending = false
        return true, previous, how
    end

    -- Called on each privacy-file sample (~2 s). sample_dt defaults to 2.
    local function on_privacy_sample(state, is_public, sample_dt)
        local dt = tonumber(sample_dt) or PRIVACY_SAMPLE_S
        if dt ~= dt or dt < 0 then dt = PRIVACY_SAMPLE_S end
        if is_public then
            state.public_hold_s = state.public_hold_s + dt
            state.friends_dwell_s = 0
            if state.public_hold_s + 1e-9 >= PUBLIC_HOLD_S then
                return contaminate(state, 'public_hold')
            end
            return false
        end
        state.public_hold_s = 0
        return false
    end

    -- Rising edge ship→mission: Public at that moment contaminates at once.
    -- Falling edge mission→ship: may clear when already Friends.
    local function on_mission_edge(state, live, is_public)
        local events = {}
        if live and not state.was_live then
            if is_public and contaminate(state, 'mission_start') then
                events[#events + 1] = 'contaminated:mission_start'
            end
        elseif state.was_live and not live then
            if state.contaminated then
                if not is_public then
                    local ok, previous, how = clear(state, 'mission_return')
                    if ok then
                        events[#events + 1] = 'cleared:' .. how .. ':' .. tostring(previous)
                    end
                else
                    state.mission_return_pending = true
                    events[#events + 1] = 'mission_return_pending'
                end
            end
        end
        state.was_live = live == true
        return events
    end

    local function on_sos(state)
        return contaminate(state, 'sos')
    end

    -- Ship-only Friends dwell while contaminated. Pauses in mission; resets on Public.
    local function on_ship_tick(state, live, is_public, dt)
        dt = tonumber(dt) or 0
        if dt ~= dt or dt < 0 then dt = 0 end
        if not state.contaminated then
            state.friends_dwell_s = 0
            return false, nil
        end
        if live or is_public then
            state.friends_dwell_s = 0
            return false, nil
        end
        if state.mission_return_pending then
            local ok, previous, how = clear(state, 'mission_return')
            if ok then
                return true, previous, how
            end
        end
        state.friends_dwell_s = state.friends_dwell_s + dt
        if state.friends_dwell_s + 1e-9 >= FRIENDS_CLEAR_S then
            local ok, previous, how = clear(state, 'friends_dwell')
            if ok then
                return true, previous, how
            end
        end
        return false, nil
    end

    -- solo: true only when peer_count is known and equal to 1.
    -- Unknown / nil / other counts are non-solo.
    local function should_gate(state, solo, sos_gated)
        if sos_gated == true then
            return true, 'privacy_gate_sos'
        end
        if state.contaminated and state.reason == 'sos' then
            return true, 'privacy_gate_sos'
        end
        if solo == true then
            return false, nil
        end
        if state.contaminated then
            return true, 'privacy_gate_contaminated'
        end
        return false, nil
    end

    return {
        PUBLIC_HOLD_S = PUBLIC_HOLD_S,
        FRIENDS_CLEAR_S = FRIENDS_CLEAR_S,
        PRIVACY_SAMPLE_S = PRIVACY_SAMPLE_S,
        new = new_state,
        contaminate = contaminate,
        clear = clear,
        on_privacy_sample = on_privacy_sample,
        on_mission_edge = on_mission_edge,
        on_sos = on_sos,
        on_ship_tick = on_ship_tick,
        should_gate = should_gate,
    }
end
