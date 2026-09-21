# Enemy Spawn Multiplier v16 and preview profiles

The release targets Steam build `24826606` / EXE `1.8.45317.0`. Addresses are
`game.dll` RVAs or offsets from the named runtime object. Static evidence is in
`research/SPAWN_FINDINGS_2026-09-18.md` at the workspace root.

## Runtime boundary

The module writes only committed `MEM_PRIVATE/PAGE_READWRITE` data. It does not
change executable pages or import `VirtualProtect` or
`FlushInstructionCache`. Read-only resource tables and image-backed cap tables
are copied to private writable allocations before their owning pointer is
retargeted. Every supported executable and `game.dll` is hash checked first.

The reverted v17 experiment called the internal enqueue function at
`game.dll+0x948FA0` with a reconstructed descriptor and payload. A matching
function prologue verified only the entry address; it did not prove the complete
argument layout or ownership rules. Runtime testing produced frequent crashes,
so native spawn/enqueue/consume calls, manual queue-item copies, queue-index
writes, and live-counter writes are outside the supported boundary. Future
experiments must remain read-only until a complete writable private-data layout
is validated across all three factions.

The object referenced by `director+0x660` is `0xB0` bytes, although its first
`0x10` bytes are enough to locate the cap rows. Native function `0x93F0E0`
copies and consumes the complete object. v16 therefore preserves all `0xB0`
bytes in the private clone and places the copied rows after it. The older
`0x10`-byte clone overlapped internal fields with row data; the captured
Automaton crash was an access violation at `game.dll+0x93F210` while native
code read the invalid address `0x6406AF11` from the corrupted internal table.

## Loader v15 integration

The archive contains two Lua resources. The stable entry resource
`mods/cowboybingus/enemy_spawn_multiplier` is plaintext and begins exactly with
`-- HD2-Addon: mods/cowboybingus/enemy_spawn_multiplier`. This is the declaration
scanned by the official Bingus Shared Loader v15. It forwards once to the
LuaJIT-bytecode resource `mods/cowboybingus/enemy_spawn_multiplier_impl`, which
contains the existing module. The declaration name hashes to the entry resource,
so no loader registry change is required. Explicit legacy registration of the
stable entry remains compatible.

The active director is read from `game.dll+0x276CA20`. The config handle at
`director+0x6B0` is resolved through the native-style generation hash table at
`director+0x51960`. Hash misses use the 38-slot resource-key table referenced by
the manager at `game.dll+0x276F0C0`, offset `+0xF116D8`. Only the resolved
`0x438` config row is edited.

## Data changes

The v16 profiles and the preview profile share the same resource identity and
loader entry. Install exactly one package. The table below describes the v16
profiles; the preview is documented separately after it.

| Field | Meaning | v16 behavior |
|---|---|---|
| `director+0x518B0` | Encounter composition budget | `6x` |
| `director+0x518B4` | GuardForce/static defender budget | Illuminate only: `0.25x` |
| `cfg+0x78` | Positive native budget override | `6x` baseline |
| cap table row `+0x18` | Nonzero per-type maximum | `10x` |
| `cfg+0x38/+0x3C` | Straggler min/max interval | `/10`, minimum 0.1 s |
| `cfg+0x40/+0x44` | Patrol min/max interval | `/10`, minimum 0.1 s |
| `cfg+0x48` | Group-size clamp | `10x` |
| `cfg+0x50` | Desired target | unchanged |
| `director+0x3A518` | Pending Straggler deadline | future maximum clamp |
| `director+0x3A520` | Pending Patrol deadline | future maximum clamp |

The game clock is read from the object at `game.dll+0x276C068`, offset `+0x18`.
On each 100 ms module check, a pending deadline is changed only when it is later
than `now + scaled maximum interval`. A due deadline or a future deadline already
inside that window is left alone. This prevents repeated timer division while
allowing an existing vanilla deadline or native 5-second query-failure retry to
adopt the faster v16 schedule.

## Preview profile: low Encounter / high timed patrol

`data-v17-preview-low-budget-patrol` is a mutually exclusive preview package
that tests whether pressure can be shifted away from Encounter waves toward the
timed Patrol/Straggler paths:

| Field | v16 behavior | Preview behavior |
|---|---|---|
| `director+0x518B0` Encounter budget | `6x` | `0.1x` |
| `director+0x518B4` GuardForce budget | Illuminate `0.25x` | unchanged; no write |
| `cfg+0x78` positive override | `6x` baseline | `0.1x`; non-positive native override is left native |
| cap table row `+0x18` | `10x` | `10x` |
| `cfg+0x38/+0x3C` Straggler interval | `/10`, floor `0.1 s` | fixed minimum `0.0`, maximum `0.1 s` |
| `cfg+0x40/+0x44` Patrol interval | `/10`, floor `0.1 s` | fixed minimum `0.0`, maximum `0.1 s` |
| `cfg+0x48` group clamp | `10x` | `10x` |
| `cfg+0x50` desired target | unchanged | unchanged |

The native timed paths at `0x9513AB` and `0x9514C7` compare the maximum interval
against zero and skip the path when it is zero. For that reason the preview
keeps the maximum at `0.1` seconds. The minimum may be zero because the native
random calculation computes `max - min` and adds the minimum back. The module
also refuses a config whose maximum interval is zero instead of silently
disabling Patrol or Straggler spawning.

Preview writes the Encounter budget to `0.1x` and does not synthesize a positive
`cfg+0x78` override when the native value is non-positive. This avoids the
double-scaling path that would otherwise produce `0.01x` after the director
budget was already reduced. If a mission already contains a positive override,
the preview scales that value by `0.1x` and tracks it idempotently.

GuardForce is left completely native in the preview: the module does not write
`director+0x518B4` for any faction. The 10x cap and group expansion remains in
place so timed patrol groups can request larger data-driven sizes, but the
native effective-70, component-448, desired-target and combined-100 gates still
apply. The preview does not add executable code patches or native spawn calls.

`cfg+0x50` is deliberately no longer scaled. Native function `0x9511F0` first
checks the active component count against the scaled target, then rejects when
`(T-A)+(B-A) >= 100`. Raising `T` delays the first exit but also increases the
second expression. The v13 `2x` edit therefore caused state-dependent suppression
and could look like intermittent deactivation.

## Remaining native limits

The checks at RVAs `0x947E69`, `0x947E79`, `0x9512B9`, and `0x9512C5` remain
unchanged. They include the effective-70, component-448, desired-reached, and
combined-100 exits. The 70 calculation contains queued quantity and component
counts with type exceptions; it is not a single configurable all-enemy cap.

Earlier releases removed these branches by changing executable bytes and were
reported to trigger anti-cheat termination. v16 does not restore that method.
The `10x` cap and group fields raise data-driven limits and can allow a request
to be larger before a native gate rejects later work, while `/10` intervals and
deadline clamping make eligible requests occur much more consistently. They do
not guarantee ten times the visible population.

Encounter budget selection follows `0x94CCF0 -> 0x94AF30 -> 0x94BCC0 ->
0x94B1C0`. Timed Patrol uses the separate weighted path at `0x94AD00`; its
frequency comes from the config intervals and deadlines rather than Encounter
points. Position queries, the 96-slot queue, native demand, and template
availability remain active.

## Composition variants

Native Composition leaves candidate weights unchanged. Light-Medium Bias reads
the active Encounter candidate pool, computes template cost per planned unit,
and ranks it within the current faction and difficulty. The lowest 50% receives
`3.6x` weight, the next 30% receives `1.25x`, and the highest 20% receives
`0.25x`. Candidate rows are read inline at `candidate+0`; `candidate+0xA8` is
only validated as the source-definition pointer and is never changed. Baselines
are retained so repeated checks do not stack multipliers.

Faction cap-table cardinality identifies the active roster on the supported build:
Automaton 61, Terminid 44, and Illuminate 45. Candidate structures are not identical across
all three factions. If the optional bias reader sees an unsupported layout, it
logs the reason, leaves weights native, and continues the core tuning. This
prevents the earlier Automaton path from stopping after budget/cap writes but
before config and timer changes.

Illuminate's 45-row table also gates a `0.25x` GuardForce budget adjustment.
The write occurs at the budget source during initialization; no live type count,
queue entry, or existing unit is modified. Reducing static defenders creates
headroom under the unchanged shared population checks.

## Diagnostics and validation

The log revision is `data-v16-native`, `data-v16-light-medium`, or
`data-v17-preview-low-budget-patrol`. `p=` reports
Encounter budget, `gf=` GuardForce current/original budget, `f=` detected
faction, `c=` cap rows, `i=` scaled Straggler/Patrol intervals, `g=` group clamp,
`d=` unchanged desired target, `t=` deadlines shortened on the latest check,
`w=` biased/available candidates or its fallback reason, and `cfg=` the active
resolver result. `l=vanilla` confirms executable population branches are unchanged.

Offline tests use synthetic private allocations to cover budget/cap scaling,
timer clamping, idempotence, config resolution, resource and cap-table cloning,
template bias, mission rebuilds, queue/counter preservation, and failure paths.
The preview suite additionally covers the `0.1x` Encounter write, native
GuardForce preservation, fixed `0.0-0.1` second intervals, zero-maximum
rejection, positive-override scaling, and no-stacking behavior.
Package tests verify the manifest, hashes, both resource identities, the exact
v15 discovery declaration and forwarding target, absence of custom DLLs, and
absence of executable-page modification APIs. Runtime verification remains false
until a matching game build is tested.
