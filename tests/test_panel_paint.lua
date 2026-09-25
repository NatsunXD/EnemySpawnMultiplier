-- Painter-safety checks: constant definitions and warning colour wiring.
--
-- An undefined colour constant is silent in Lua: `cond and C_MISSING or C_TITLE`
-- short-circuits to the fallback, so the UI keeps drawing and nothing errors. That
-- is exactly how a red value text shipped as white. These checks make the failure
-- loud instead.
local source = assert(arg[1])
local path = source .. '/panel.lua'
local file = assert(io.open(path, 'r'))
local text = file:read('*a')
file:close()

local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end

-- Every C_* constant referenced by the painter must have a `local C_* =` line.
local defined = {}
for name in text:gmatch('local%s+(C_[A-Z_]+)%s*=') do defined[name] = true end
local missing = {}
for name in text:gmatch('%f[%w_](C_[A-Z_]+)%f[^%w_]') do
    if not defined[name] and not missing[name] then
        missing[name] = true
        missing[#missing + 1] = name
    end
end
assert(#missing == 0, 'undefined colour constant(s) referenced: ' .. table.concat(missing, ', '))
assert(defined.C_DANGER, 'the danger colour must be defined')
pass('every referenced colour constant is defined')

-- The value readout must consult the risk predicate and must have a colour that
-- differs from the normal one, otherwise "turns red" degrades to "stays white".
assert(text:find('model.at_risk', 1, true), 'the value readout must use model.at_risk')
local danger = text:match('local C_DANGER%s*=%s*rgb%((.-)%)')
local title = text:match('local C_TITLE%s*=%s*rgb%((.-)%)')
assert(danger and title, 'both colours must be defined via rgb()')
assert(danger ~= title, 'the danger colour must differ from the normal value colour')
pass('the value readout is wired to the risk predicate with a distinct colour')

-- The corner warning must be drawn with the warning colour and only when the
-- predicate reports pressure.
local warn = text:match('local C_WARN%s*=%s*rgb%((.-)%)')
assert(warn and warn ~= danger, 'the warning colour must differ from the danger colour')
assert(text:find('model.pressure_warning()', 1, true), 'the corner warning must consult the predicate')
assert(text:find('PRESSURE_WARNING', 1, true), 'the warning string must exist')
pass('the corner warning is gated on the predicate and uses the warning colour')

print(count .. ' painter safety checks passed; no window was created.')
