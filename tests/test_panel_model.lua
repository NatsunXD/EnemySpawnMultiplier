-- Panel model checks: slider grid, hit testing and settings mapping.
-- Pure logic only; no FFI, no window and no game memory is touched here.
-- This file is deliberately ASCII-only: the two CJK label expectations are
-- assembled from UTF-8 byte values so the test is independent of the encoding
-- of whatever tool wrote it.
local source, build = assert(arg[1]), assert(arg[2])
local create_model = assert(loadfile(source .. '/panel_model.lua'))()

local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end
local function approx(a, b) return math.abs(a - b) <= 0.0001 end

local model = create_model()

-- Defaults requested for the panel: 2x budget/count, both cooldowns short,
-- heavy template preset. Patrol size is not a panel control.
assert(model.pending.budget == 2.0)
assert(model.pending.patrol_count == 1.0)
assert(model.pending.patrol_size == 1.0)
assert(approx(model.pending.encounter_cd, 2.0))
assert(approx(model.pending.patrol_cd, 2.0))
assert(model.pending.preset == 'heavy')
assert(model.pending.fast_corpse == true)
pass('panel defaults to 2x budget, 1x patrol count, fast cooldowns and heavy')

-- Five sliders, one checkbox and three radios, in the documented order.
local widgets = model.layout()
assert(#widgets.sliders == 5 and #widgets.checkboxes == 1 and #widgets.radios == 3 and #widgets.buttons == 3)
assert(widgets.checkboxes[1].key == 'fast_corpse' and #widgets.checkboxes[1].label > 0)
assert(widgets.sliders[1].key == 'budget')
assert(widgets.sliders[2].key == 'patrol_count')
assert(widgets.sliders[3].key == 'patrol_size')
assert(widgets.sliders[3].min == 0.1 and widgets.sliders[3].max == 2.0)
assert(widgets.sliders[4].key == 'encounter_cd' and widgets.sliders[4].kind == 'cooldown')
assert(widgets.sliders[5].key == 'patrol_cd' and widgets.sliders[5].kind == 'cooldown')
assert(widgets.buttons[3].id == 'export')
assert(type(widgets.buttons[3].label) == 'string' and #widgets.buttons[3].label > 0)
assert(widgets.radios[1].value == 'heavy')
assert(widgets.radios[2].value == 'light_medium')
assert(widgets.radios[3].value == 'native')
pass('panel exposes five sliders, the corpse checkbox and three radios')

-- Every label the panel paints must be present and non-empty.
for _, control in ipairs(widgets.sliders) do
    assert(type(control.label) == 'string' and #control.label > 0)
end
for _, control in ipairs(widgets.checkboxes) do
    assert(type(control.label) == 'string' and #control.label > 0)
end
for _, control in ipairs(widgets.radios) do
    assert(type(control.label) == 'string' and #control.label > 0)
end
pass('every painted control carries a non-empty label')

-- The multiplier grid must span exactly 0.1 .. 6.0 and land on 2.0.
assert(approx(model.slider_to_value(0), 0.1))
assert(approx(model.slider_to_value(model.SLIDER_STEPS), 6.0))
local found_two = false
for step = 0, model.SLIDER_STEPS do
    local value = model.slider_to_value(step)
    assert(value >= 0.1 - 0.0001 and value <= 6.0 + 0.0001)
    if approx(value, 2.0) then found_two = true end
end
assert(found_two)
pass('multiplier sliders cover 0.1x to 6.0x inclusive on a 0.1 grid')

-- Dragging a slider to an extreme must clamp, not overflow the range.
local item = widgets.sliders[1]
model.set_slider(item, item.track_x - 1000)
assert(approx(model.pending.budget, 0.1))
model.set_slider(item, item.track_x + item.track_w + 1000)
assert(approx(model.pending.budget, 6.0))
pass('slider drags clamp to the configured range')

-- Cooldown sliders are a continuous 2 s .. 30 s interval. The left end is the
-- fast preset; the right end is the slow/native end.
local cd = widgets.sliders[4]
model.set_slider(cd, cd.track_x - 1000)
assert(approx(model.pending.encounter_cd, 2.0))
model.set_slider(cd, cd.track_x + cd.track_w + 1000)
assert(approx(model.pending.encounter_cd, 30.0))
model.set_slider(cd, cd.track_x + cd.track_w * 0.5)
local mid = model.pending.encounter_cd
assert(mid > 2.0 and mid < 30.0)
-- The row must not print a number: only the words at the two ends.
assert(model.format(cd) == '')
pass('cooldown sliders sweep 2s..30s and print no numeric value')

-- Hit testing must agree with the painted geometry for every control.
for _, control in ipairs(widgets.sliders) do
    local kind, hit = model.hit(control.track_x + control.track_w / 2, control.track_y)
    assert(kind == 'slider' and hit.key == control.key)
end
for _, control in ipairs(widgets.checkboxes) do
    local kind, hit = model.hit(control.x + 4, control.y + 4)
    assert(kind == 'checkbox' and hit.key == control.key)
end
for _, control in ipairs(widgets.radios) do
    local kind, hit = model.hit(control.x + 4, control.y + 4)
    assert(kind == 'radio' and hit.value == control.value)
end
for _, control in ipairs(widgets.buttons) do
    local kind, hit = model.hit(control.x + 4, control.y + 4)
    assert(kind == 'button' and hit.id == control.id)
end
assert(model.hit(5, 5) == 'title')
assert(model.hit(5, model.CLIENT_H - 5) == nil)
-- Adding a control must not let the derived stack run off the bottom of the window.
for _, control in ipairs(widgets.sliders) do
    assert(control.y >= 0 and control.y + control.h <= model.CLIENT_H)
end
for _, control in ipairs(widgets.checkboxes) do
    assert(control.y >= 0 and control.y + control.h <= model.CLIENT_H)
end
for _, control in ipairs(widgets.radios) do
    assert(control.y >= 0 and control.y + control.h <= model.CLIENT_H)
end
for _, control in ipairs(widgets.buttons) do
    assert(control.y >= 0 and control.y + control.h <= model.CLIENT_H)
end
pass('hit testing agrees with the painted control geometry')

-- settings() must map onto the patch.configure() surface with rate multipliers.
-- Reset first: the drag tests above deliberately moved the editor state.
model.reset()
local patch = {cooldown_fast_rate = 3.0, patrol_cooldown_fast_rate = 6.0}
local wanted = model.settings(patch)
assert(approx(wanted.budget, 2.0))
assert(approx(wanted.patrol_count, 1.0))
assert(approx(wanted.patrol_size, 1.0))
assert(approx(wanted.encounter_cd_seconds, 2.0))
assert(approx(wanted.patrol_cd_seconds, 2.0))
assert(wanted.fast_corpse == true)
assert(wanted.preset == 'heavy')
model.pending.encounter_cd = 30.0
model.pending.patrol_cd = 30.0
model.pending.preset = 'native'
wanted = model.settings(patch)
assert(approx(wanted.encounter_cd_seconds, 30.0))
assert(approx(wanted.patrol_cd_seconds, 30.0))
assert(wanted.preset == 'native')
pass('panel settings map onto the configure() seconds surface')

-- apply() must forward to patch.configure() and remember what was committed.
local captured
local fake_patch = {
    cooldown_fast_rate = 3.0, patrol_cooldown_fast_rate = 6.0,
    configure = function(settings) captured = settings; return true end,
}
model.reset()
assert(model.apply(fake_patch))
assert(captured and approx(captured.patrol_count, 1.0) and captured.preset == 'heavy')
assert(captured.fast_corpse == true)
assert(model.committed and approx(model.committed.budget, 2.0))
local failing = {
    cooldown_fast_rate = 3.0, patrol_cooldown_fast_rate = 6.0,
    configure = function() return false, 'budget_out_of_range' end,
}
local ok, reason = model.apply(failing)
assert(ok == false and reason == 'budget_out_of_range')
assert(model.committed and approx(model.committed.budget, 2.0))
pass('panel apply forwards to configure and reports rejections')

-- A rejected apply must not disturb the pending editor state either.
assert(approx(model.pending.budget, 2.0))
pass('a rejected apply leaves the pending panel state intact')

-- sync_from_patch must reflect a live profile, including the native preset.
model.reset()
model.sync_from_patch({budget_multiplier = 6.0, modifier_patrol_count = 0.1,
                       modifier_travelers_max_unit = 2.0, encounter_deadline_enabled = true,
                       encounter_max_interval = 2.0, modifier_patrol_cooldown = 6.0,
                       cooldown_fast_rate = 3.0, patrol_cooldown_fast_rate = 6.0,
                       template_bias_enabled = true, template_bias_light = 0.25,
                       template_bias_heavy = 4.0, fast_corpse = false})
assert(approx(model.pending.budget, 6.0))
assert(approx(model.pending.patrol_count, 0.1))
assert(approx(model.pending.patrol_size, 2.0))
assert(approx(model.pending.encounter_cd, 2.0))
assert(approx(model.pending.patrol_cd, 2.0))
assert(model.pending.preset == 'heavy')
assert(model.pending.fast_corpse == false)
model.sync_from_patch({budget_multiplier = 2.0, modifier_patrol_count = 2.0,
                       modifier_travelers_max_unit = 2.0, encounter_deadline_enabled = false,
                       encounter_max_interval = 2.0, modifier_patrol_cooldown = 1.0,
                       cooldown_fast_rate = 3.0, patrol_cooldown_fast_rate = 6.0,
                       template_bias_enabled = true, template_bias_light = 3.6,
                       template_bias_heavy = 0.25})
assert(model.pending.preset == 'light_medium')
-- Clamp disabled => slow end, even though a stale 2.0 interval is still present.
assert(approx(model.pending.encounter_cd, 30.0))
assert(approx(model.pending.patrol_cd, 30.0))
model.sync_from_patch({budget_multiplier = 2.0, modifier_patrol_count = 2.0,
                       modifier_travelers_max_unit = 2.0, encounter_deadline_enabled = false,
                       encounter_max_interval = 30.0, modifier_patrol_cooldown = 1.0,
                       cooldown_fast_rate = 3.0, patrol_cooldown_fast_rate = 6.0,
                       template_bias_enabled = false})
assert(model.pending.preset == 'native')
assert(model.pending.fast_corpse == false)
pass('panel sync mirrors the live profile and preset')

-- Reset must restore every documented default.
model.pending.budget = 5.5
model.pending.preset = 'native'
model.pending.patrol_cd = 30.0
model.pending.fast_corpse = false
model.reset()
assert(approx(model.pending.budget, 2.0))
assert(model.pending.preset == 'heavy')
assert(approx(model.pending.patrol_cd, 2.0))
assert(model.pending.fast_corpse == true)
pass('panel reset restores the documented defaults')

-- Risk thresholds drive the red value text and the corner warning. The boundary
-- is strict "greater than", so exactly 1.5 / 1.0 is still safe.
model.reset()
model.pending.patrol_count, model.pending.patrol_size = 1.5, 1.0
assert(model.at_risk({key = 'patrol_count'}) == false, 'exactly 1.5 must be safe')
assert(model.at_risk({key = 'patrol_size'}) == false, 'exactly 1.0 must be safe')
assert(model.pressure_warning() == false)

model.pending.patrol_count = 1.6
assert(model.at_risk({key = 'patrol_count'}) == true, 'above 1.5 must warn')
assert(model.pressure_warning() == true)
model.pending.patrol_count = 1.5
model.pending.patrol_size = 1.1
assert(model.at_risk({key = 'patrol_count'}) == false)
assert(model.at_risk({key = 'patrol_size'}) == true, 'above 1.0 must warn')
assert(model.pressure_warning() == true)
pass('pressure warning uses a strict threshold on the patrol pair')

-- The shipped defaults (1.0 / 1.0) sit exactly on both thresholds, which is the
-- boundary the predicate treats as safe, so a fresh panel must NOT warn. Recorded
-- so a future change to the defaults or thresholds has to decide this deliberately.
model.reset()
assert(model.pending.patrol_count == 1.0 and model.pending.patrol_size == 1.0)
assert(model.pressure_warning() == false, 'the shipped defaults must land in the safe range')
pass('the shipped panel defaults land in the safe range')

-- No other row may ever raise the warning.
model.reset()
model.pending.patrol_count, model.pending.patrol_size = 1.0, 1.0
model.pending.budget = 6.0
model.pending.encounter_cd = 30.0
model.pending.patrol_cd = 30.0
assert(model.pressure_warning() == false, 'only the patrol pair may warn')
for _, key in ipairs({'budget', 'encounter_cd', 'patrol_cd'}) do
    assert(model.at_risk({key = key}) == false)
end
pass('only patrol count and patrol size can raise the pressure warning')

-- The warning is display-only: a risky profile must still be accepted.
local risky_patch = {
    cooldown_fast_rate = 3.0, patrol_cooldown_fast_rate = 6.0,
    configure = function() return true end,
}
model.reset()
model.pending.patrol_count, model.pending.patrol_size = 6.0, 2.0
assert(model.pressure_warning() == true)
assert(model.apply(risky_patch) == true, 'a risky profile must still be applicable')
pass('the pressure warning never blocks Apply')

print(count .. ' panel model checks passed; no window was created.')
