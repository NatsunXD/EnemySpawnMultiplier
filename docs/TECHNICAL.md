# Enemy Spawn Multiplier - technical reference

Targets Steam build `24826606` / EXE `1.8.45317.0`. All addresses are `game.dll`
RVAs or offsets from the named runtime object. Static evidence and the four
read-only captures are under `research/`; the field identification worked from a
plaintext typelib (`dl_library.dl_typelib`) plus the community field-name JSON,
not from guessing offsets.

## 1. Runtime boundary

The module writes committed `MEM_PRIVATE/PAGE_READWRITE` data only. It never
changes executable pages and does not import `VirtualProtect`,
`FlushInstructionCache`, `CreateRemoteThread` or `LoadLibrary`. Read-only
resource tables and image-backed cap tables are copied into private writable
allocations and their owning pointer is retargeted before any edit. Both the
executable and `game.dll` are SHA-256 checked before the first write.

Excluded by policy, with the reason each was rejected in testing:

- Executable-page patching. Earlier releases removed native branches by changing
  code bytes and were reported to trigger anti-cheat termination.
- Calling native spawn/enqueue/consume functions with reconstructed arguments.
  The reverted v17 experiment called `game.dll+0x948FA0` after matching a 16-byte
  prologue. A matching prologue proves the entry address and nothing else: not the
  ABI, not the descriptor layout, not pointer ownership, not the thread contract.
  Runtime testing produced frequent crashes.
- Manual queue-item copies, queue index writes and live population-counter
  writes.

Rejected experiments are recorded rather than deleted; several of the sections
below exist precisely to stop a future session from re-walking them.

## 2. Loader v15 integration

The archive carries two Lua resources:

- `mods/cowboybingus/enemy_spawn_multiplier` - plaintext, byte zero begins
  exactly with `-- HD2-Addon: mods/cowboybingus/enemy_spawn_multiplier`. This is
  the declaration scanned by Bingus Shared Loader v15.
- `mods/cowboybingus/enemy_spawn_multiplier_impl` - the compiled LuaJIT body.

The declaration name hashes to the entry resource, so no loader registry edit is
needed. Explicit legacy registration of the stable entry still works. The entry
forwards once and holds no logic of its own.

## 3. The config row is HiveMindComponent

The active director is read from `game.dll+0x276CA20`. The handle at
`director+0x6B0` resolves through the native generation hash table at
`director+0x51960`; on a miss the 38-slot resource-key table referenced by
`game.dll+0x276F0C0` at offset `+0xF116D8` is used, and on a further miss the
resource table is cloned into private memory and retargeted so its rows become
writable.

The resolved row is `director+0x519A4 + index*0x438`. The typelib records
`HiveMindComponent` as exactly 1080 bytes = `0x438`, which is why
`cfg_stride = 0x438`. Its layout, confirmed against the field-name JSON:

| Offset | Field |
|---|---|
| `+0x00` | `faction` |
| `+0x04` | `max_encounter_members_to_remove` |
| `+0x08` | `selected_encounter_member_weight_multiplier` |
| `+0x0C` | `traveler_settings.minimum_spawn_point_cooldown` |
| `+0x10` | `traveler_settings.maximum_spawn_point_cooldown` |
| `+0x14` | `patrol_spotting_settings` |
| `+0x24` | `starting_time_limit` and neighbours |
| `+0x38` | timed-interval / group-clamp / target block |
| `+0x78` | `forced_encounter_point_amount` |
| `+0x88` | `mission_difficulty_settings` (940 bytes) |
| `+0x434` | trailing flags |

`0x88 + 940 = 0x434`, and the four trailing bytes bring the row to `0x438`. The
two independent derivations agree, so the offsets below are not approximations.

## 4. Verified spawn levers

### 4.1 Encounter (reinforcement) budget

`director+0x518B0` is the per-reinforcement composition budget. It is not a
remaining pool and not a wave timer. `0x94AF30` reads it, applies environment and
config multipliers, and hands the result to the candidate selector at
`0x94CCF0 -> 0x94BCC0 -> 0x94B1C0`.

`0x94AF30` checks `cfg+0x78` first: when that float is positive it returns that
value directly and bypasses `0x518B0` entirely. `cfg+0x78` is
`forced_encounter_point_amount`, default `-1`. Because of that bypass, editing
`0x518B0` alone is not sufficient whenever a mission ships a positive override;
the preview profile therefore also writes `cfg+0x78` itself.

`0x94B4BC` truncates the budget to an integer and `0x94BB2E` clamps each
candidate cost with `max(cost, 1.0)`; the constant at `game.dll+0x211C5B0` was
read and is exactly `1.0`. Budget is therefore a point total spent on
template entries, and one template row can carry several units, so budget is not
a unit count.

### 4.2 Difficulty modifier curves - the two working cooldown levers

`mission_difficulty_settings` at `cfg+0x88` holds sixteen sub-blocks: 88, 36, 36
bytes, then thirteen 60-byte curves. Each 60-byte curve is fifteen floats laid
out 5 + 4 + 1 + 5. `game.dll+0xD49E70..0xD4B67A` is the evaluator: it blends
those curves between two source rows with `mulss`/`addss` weighted sums, so the
live values are per-difficulty and per-progress, not constants.

The four curves below were identified by name, then scaled by `3.0` in the
preview profile. The two cooldown effects were confirmed in game first; the
patrol-size curve was added afterwards and is documented in section 4.5.

| Config offset | Field | Effect |
|---|---|---|
| `cfg+0x164` | `encounter_cooldown_rate_modifier` | enemy reinforcement cooldown |
| `cfg+0x1A0` | `patrol_count_max_modifier` | how many patrols may exist |
| `cfg+0x1DC` | `patrol_spawn_cooldown_rate_modifier` | patrol spawn cooldown |
| `cfg+0x3F8` | `travelers_max_unit_count_multiplier` | units per patrol wave |

The remaining curves, same block layout, are available but unused:

`cfg+0x128` `encounter_points_modifier`, `cfg+0x218` `spawner_queue_limit_modifier`,
`cfg+0x254` `spawner_production_cooldown_rate_modifier`,
`cfg+0x290` `spawner_spawn_count_modifier`,
`cfg+0x2CC` `spawner_spawn_count_minimum_modifier`,
`cfg+0x308` `spawner_spawn_cooldown_rate_modifier`,
`cfg+0x344` `guard_force_member_count_max_modifier`,
`cfg+0x380` `global_spawner_cooldown_modifier`,
`cfg+0x3BC` `travelers_waves_cooldown_multiplier`,
`cfg+0x3F8` `travelers_max_unit_count_multiplier`.

### 4.3 Polarity of `_rate_` fields

Fields whose name contains `_rate_` are frequency multipliers: a larger value
means a shorter cooldown. Fields without `_rate_` are duration multipliers: a
smaller value means a shorter cooldown.

This is supported by the shipped curves themselves. As difficulty and progress
rise, `encounter_cooldown_rate_modifier` goes 0.9 -> 1.2 and
`patrol_spawn_cooldown_rate_modifier` goes 1.0 -> 1.6, while
`global_spawner_cooldown_modifier` goes 1.0 -> 0.55. Both directions express the
same intent - more pressure later - under the two different conventions.

The reading was confirmed in game: scaling the three `_rate_`/count curves by 3.0
produced a clearly shorter reinforcement cooldown and patrol refresh cooldown.

### 4.4 Every curve block is three indexed arrays

Each 60-byte curve is read by a dedicated getter with the same shape, for example
the queue-limit getter at `0x7F0CB0` and the spawn-count getter at `0x7F0F20`:

```asm
call 0x501490                      ; resolve the active 0x438 config row
mov  rbx, rax
call 0x94de00                      ; -> progression index 0..4
mulss xmm6, [rbx + idx*4 + BASE]        ; array A, progress
call 0x94de80                      ; -> player-count / influence index 0..4
mulss xmm6, [rbx + idx*4 + BASE+0x14]   ; array B, influence
mov  eax, [difficulty]             ; difficulty 1..7
mulss xmm6, [rbx + idx*4 + BASE+0x28]   ; array C, difficulty
```

`0x94DE00` reads `mission_progression_steps` (the first five floats of
`MissionDifficultySettings` at `cfg+0x88`) and returns the first step greater than
the live progress. `0x94DE80` compares `cfg+0x9C + i*4` against
`director+0x51948` and returns the first qualifying index. Both can return `-1`,
which the getters treat as "apply no multiplier".

So a block is three 5-float arrays selected by progress, player count and
difficulty, plus a fixed index used in one mission mode. A 60-byte block is
therefore fifteen floats; the typelib's 20/16/4/20 byte split is a packaging
artefact of the same fifteen values.

This matters when editing a curve: the value you scale is only the one for the
currently selected index. Scaling the whole 60-byte block is what the preview
does, so every progression step and difficulty ends up scaled.

### 4.5 Patrol squad size

The getter at `game.dll+0x943E40` is patrol-specific and computes both patrol
outputs in one pass:

```asm
mulss xmm7, [rbx + idx*4 + 0x420]   ; travelers_max_unit_count, index +0x28
movss [rsi], xmm6                   ; travelers_waves_cooldown -> parameter
cvtsi2ss xmm1, rax                  ; base unit count for this branch
mulss xmm1, xmm7                    ; x base_count * multiplier
cvttss2si ecx, xmm1                 ; round, then store as int
```

The result is `round(base_units * travelers_max_unit_count_multiplier)` where
`base_units` comes from `rdi+0x2EC`/`0x2F0`/`0x2F4`, chosen by the branch id at
`director+0x518BC` (2, 4 or 8). It also multiplies the cooldown by
`travelers_waves_cooldown_multiplier` (`cfg+0x3BC`) and by a per-branch float at
`rdi+0x2E0`/`0x2E4`/`0x2E8`.

That is why scaling `patrol_count_max_modifier` did not change squad size: it
selects how many patrols exist, not how many units each one carries. The unit
count is governed by `cfg+0x3F8` alone.

Measured vanilla patrol increments were 11-12 units per event in all three
captures, which is the native `base_units * multiplier` result.

### 4.6 Outpost and guard-force squad size

Non-patrol spawners use the generic spawner getters instead, and those were left
untouched:

- `cfg+0x290` `spawner_spawn_count_modifier` - units per spawner wave
  (`AiSpawnerComponent.spawn_count` at component `+0x8C`)
- `cfg+0x2CC` `spawner_spawn_count_minimum_modifier` - minimum units per wave
- `cfg+0x218` `spawner_queue_limit_modifier` - production queue depth
  (`AiSpawnerComponent.production_queue_limit` at `+0x88`)

Unlike `cfg+0x3F8`, these apply to every spawner type, so scaling them would also
change outposts and guard forces. They are deliberately not in the preview.

### 4.7 Cap rows and group clamp

`director+0x660` points at an object whose first `0xB0` bytes are real state and
are consumed whole by native function `0x93F0E0`. The object's rows sit after
those `0xB0` bytes. An earlier `0x10`-byte clone overlapped internal fields with
row data; the captured Automaton crash was an access violation at
`game.dll+0x93F210` where native code read the invalid pointer `0x6406AF11` out
of the corrupted table. Any clone must therefore carry all `0xB0` bytes plus the
rows, and must stay alive as long as native code can reach it.

The module raises nonzero per-type maxima and `cfg+0x48` (the group-size clamp) by
`10x`. Zero rows stay zero because zero is a native skip.

### 4.8 Encounter template weighting

Encounter waves pick templates from the candidate pool at
`director+0x432F8` (count at `director+0x5188C`, stride `0xD8`). Each candidate
carries a weight at `+0xC0`, a cost at `+0xD4`, an inline row set at `+0`, a row
count at `+0x60`, and a source-definition pointer at `+0xA8`.

The reweighting pass in `scale_candidate_weights` computes
`density = cost / planned_units` for every candidate, sorts the densities, and
splits them at the 50th and 80th percentile. Each band then receives a fixed
multiplier applied to that candidate's stored baseline weight:

| Band | Selection | Light-Medium profile | Heavy-focus profile |
|---|---|---|---|
| cheapest 50% | `density <= p50` | `3.6x` | `0.25x` |
| middle 30% | `p50 < density <= p80` | `1.25x` | `1.0x` |
| costliest 20% | `density > p80` | `0.25x` | `4.0x` |

Cost per planned unit is the closest available proxy for armour weight, so the
costliest quintile is where the heavy units live. The two profiles use the same
mechanism with opposite polarity, which is why `Light-Medium Bias` and the
heavy-focus preview share one code path.

Idempotence relies on a per-candidate key of
`index:source_pointer:cost`. A stored baseline is re-adopted only when the live
weight matches neither the baseline nor the last applied value, which is the case
the game re-rolls a candidate pool for a new mission.

## 5. Paths that are dead on this build

These were each tried, measured and rejected. They are recorded so they are not
retried.

### 5.1 The timed Patrol/Straggler scheduler never runs

`0x9511F0`, `0x951580` and `0x9516B0` are the three timed schedulers. Each one
gates on an enable flag before doing any work:

- `0x9511F0` and `0x951580` require `director+0x5189C != 0`
- `0x9516B0` requires `director+0x518A0 != 0`

Scanning every reference to `0x5189C`, `0x518A0`, `0x518A4` and `0x518A8` across
the whole of `game.dll` shows no instruction anywhere that stores a nonzero value
into `0x5189C` or `0x518A0`. `0x518A4`/`0x518A8` are only ever cleared by an
8-byte zero store at `0x9512DE`. In the two 300-second captures that recorded them
(1410 and 1439 samples) the four flags read `0000` in every single sample, and so
did all 7455 lines of the v16.8 in-game log.

The branches are therefore unreachable, which is why neither `/10`-scaling
`cfg+0x38..0x44` nor clamping `director+0x3A518`/`0x3A520` ever changed patrol
cadence. The interval fields are still written (they are correct and harmless if a
future build does reach the branch) but they are not the lever.

The four Patrol/Straggler candidate pools at `director+0x49178`, `0x4AC78`,
`0x4C778` and `0x4E278` were empty for 100% of both captures for the same
reason.

### 5.2 The Encounter deadline at `0x399D8` is written once

`0x94C030` compares the game clock against `director+0x399D8` before accepting a
new Encounter. The only instruction that stores into that field is `0x94CCE8`,
which sits in a fragment that is not covered by the PE exception table and runs
once during mission initialisation. Across three captures the value only drifted
downward and was never re-armed, so clamping it does nothing.

The v16.7 clamp is still present in the preview profile. It is inert on this
build, is guarded by a writable-private-data check, and does not fail closed when
the field is unreachable.

### 5.3 `TravelerSettings` spawn-point cooldown is not the patrol lever

`cfg+0x0C`/`cfg+0x10` are `TravelerSettings` minimum/maximum spawn-point
cooldown, documented as 30/60 seconds. The measured vanilla values on this build
are **5.0 / 10.0 seconds**, and measured patrol cadence is 45-63 seconds, so the
documented range does not describe this build's patrol rhythm. Scaling the pair
to 2/5 changed nothing observable.

The lesson generalises: the field-name JSON describes intent, not this build's
tuned numbers. Always read the live value before trusting a default.

### 5.4 `director+0x399F0` is a production beat, not a wave timer

`0x945F92` gates on `director+0x399F0`, and `0x950FA0` writes it as
`interval + clock`. It re-arms about every 4.9 seconds and is the only deadline
that is actually live during a mission. It corresponds to per-batch production,
not to wave spacing: 55 re-arms produced only two Encounter bursts.

### 5.5 The global spawner pool is idle

`0x950FC0` reads its pool from `director+0x48AB8` and its count from
`director+0x51898`. In both captures the count was `0` for the entire session and
the cooldown at `director+0x3A510` was never armed.

## 6. Profiles

Both profiles share one resource identity and one loader entry, so exactly one
package may be installed.

### v16 - `data-v16-native` / `data-v16-light-medium`

Encounter budget `6x` via `cfg+0x78`, nonzero caps and group clamp `10x`, timed
intervals `/10`. Illuminate GuardForce budget is reduced to `0.25x` so static
defenders leave headroom under the shared population gate. `Native Composition`
keeps template weights; `Light-Medium Bias` ranks candidates by cost per planned
unit (lowest 50% `3.6x`, next 30% `1.25x`, highest 20% `0.25x`) and falls back to
native weights on an unsupported layout instead of aborting the core tuning.

### Preview - `data-v16.12-preview-low-budget-patrol`

Reinforcement budget `0.2x`, and `cfg+0x78` is forced to the already-scaled
director base so a positive native override cannot bypass the reduction.

Four curves are scaled: `0x164` encounter cooldown `3.0x`, `0x1A0` patrol count
`3.0x`, `0x1DC` patrol spawn cooldown `3.0x`, and `0x3F8` units per patrol wave
`10.0x`. Each block keeps its own baseline so a second pass cannot stack, and if
the game re-blends a curve for a new difficulty the freshly blended native value
becomes the new baseline and is scaled once from there.

Encounter candidates are reweighted with the heavy-focus column of section 4.8:
the cheapest half drops to `0.25x`, the middle `30%` stays at `1.0x`, and the
costliest `20%` rises to `4.0x`.

GuardForce is not written at all, so static defenders keep their native budget
and schedule.

Timed intervals are fixed at `0.0-0.1` s. They are inert on this build per
section 5.1 but correct if the branch is ever reached. The maximum stays at `0.1`
rather than `0` because a zero maximum makes the native code skip the path
outright.

## 7. Remaining native limits

The checks at `0x947E69`, `0x947E79`, `0x9512B9` and `0x9512C5` are untouched.
They are the effective-70, component-448, desired-reached and combined-100 exits.
The effective-70 term mixes queued quantity with ProducedFighter and Encounter
type counts and has type exemptions; it is not a single configurable all-enemy
cap. The 448 term is the live component count.

`cfg+0x50` (desired target) is deliberately never scaled. `0x9511F0` first
compares the active component count against the scaled target and then rejects
when `(T-A)+(B-A) >= 100`. Raising `T` delays the first exit but also inflates
the second expression, which is why the v13 `2x` edit looked like intermittent
suppression rather than a clean speedup.

Position queries, the 96-slot queue, native demand and template availability all
remain active. Budget and caps change what a request may ask for; they do not
guarantee what gets instantiated.

## 8. Diagnostics

Log path: `%LOCALAPPDATA%/EnemySpawnMultiplier.log`, appended about once per
second and rotated at 4 MB.

| Token | Meaning |
|---|---|
| `p=` | Encounter budget, current/original |
| `gf=` | GuardForce budget, current/original |
| `f=` | faction from cap-table cardinality (automaton 61, terminid 44, illuminate 45) |
| `c=` | valid cap rows / total |
| `i=` | scaled Straggler/Patrol intervals |
| `g=` | group clamp, `d=` desired target |
| `o=` | effective `cfg+0x78` override |
| `tv=` | `TravelerSettings` spawn-point cooldown pair |
| `ms=` | applied difficulty-curve scale quadruple |
| `mv=` | live head float of each scaled curve after the write |
| `e=` | seconds until `0x399D8`; `pd=`/`sd=` Patrol/Straggler deadline deltas |
| `a=`/`b=` | the two scheduling counters that gate `0x9511F0` |
| `fl=` | the four scheduler enable flags |
| `T=` | probed director timer offsets within an hour of the mission clock |
| `t=` | deadlines shortened on this check |
| `n=` | a deadline existed but its field was not writable private data |
| `w=` | biased/available candidates, or the fallback reason |
| `cfg=` | active resolver result, `l=vanilla` confirms code branches untouched |

## 9. Validation status

Offline: 24 synthetic checks on the data path, 8 preview-profile checks, 7 package
checks. They cover budget and cap scaling, timer clamping, idempotence, config
resolution, resource and cap-table cloning, template bias, mission rebuilds,
queue and counter preservation, curve scaling from a stored baseline, re-blend
recovery, and the failure paths. Package tests verify the manifest, hashes, both
resource identities, the exact v15 declaration and forwarding target, absence of
custom DLLs, and absence of executable-page modification APIs.

In game: the preview profile's two target behaviours - shorter enemy
reinforcement cooldown and shorter patrol refresh cooldown - were confirmed on
the Terminid front. That confirms the polarity reading in section 4.3 and the
field mapping in section 4.2.

The artifact that confirmed both cooldown behaviours is:

```text
releases/Enemy-Spawn-Multiplier-Preview-Low-Budget-Fast-Cadence-v16.10-preview.zip
SHA-256 A2D9FD1F68A7882491B19058D7E287CC23B130DE30B44E583E153CCA063D2CE1
gameplay payload data/9ba626afa44a3aa3.patch_0
SHA-256 3000539AB5260591891E095C669B976AF1408508C38D95E534DC978AEF1B6170
```

The current preview build is:

```text
releases/Enemy-Spawn-Multiplier-Preview-Low-Budget-Fast-Cadence-v16.12-preview.zip
SHA-256 E7CF302E99566B30E97CE9C971A3BB34C4E33E40E1A227015250F6A1F6B3CFE2
gameplay payload data/9ba626afa44a3aa3.patch_0
SHA-256 391B0EF4DDEB27D918999004489EA80674611EE5F40DF2BF67D91814D9D9C3E7
```

The v16 pair carries no curve scaling, no traveler write, no deadline clamp and
no candidate reweighting, so its behaviour is the pre-existing 6x data profile;
its provenance manifest differs only in the extra descriptive metadata fields.

Offline: 24 synthetic checks on the data path, 9 preview-profile checks, 7 package
checks. The preview suite now also covers heavy-tier reweighting and the
no-stacking guarantee for candidate weights.

Rebuilding from the same source reproduces that ZIP byte for byte, so the tested
bytes and the shipped bytes are the same file. The gameplay payload hash is
recorded separately so a future rebuild that changes only packaging metadata can
still be compared against what was actually played.

Live confirmation covers the reinforcement cooldown, the patrol refresh cooldown
and the direction of the `_rate_` convention. Not yet exercised live: the 10x
patrol squad size, the heavy-tier candidate weighting, Automaton and Illuminate,
the Illuminate GuardForce `0.25x` path, mission-to-mission transitions inside one
process, and host versus solo differences. `runtime_verified` stays `false` in
the manifests until those are covered.
