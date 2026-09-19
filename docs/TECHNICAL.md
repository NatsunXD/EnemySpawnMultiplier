# Enemy Spawn Multiplier v14 variants

The release targets Steam build `24826606` / EXE `1.8.45317.0`. Addresses are
`game.dll` RVAs or offsets from the named runtime object. Static evidence is in
`research/SPAWN_FINDINGS_2026-09-18.md` at the workspace root.

## Runtime boundary

The module writes only committed `MEM_PRIVATE/PAGE_READWRITE` data. It does not
change executable pages or import `VirtualProtect` or
`FlushInstructionCache`. Read-only resource tables and image-backed cap tables
are copied to private writable allocations before their owning pointer is
retargeted. Every supported executable and `game.dll` is hash checked first.

The active director is read from `game.dll+0x276CA20`. The config handle at
`director+0x6B0` is resolved through the native-style generation hash table at
`director+0x51960`. Hash misses use the 38-slot resource-key table referenced by
the manager at `game.dll+0x276F0C0`, offset `+0xF116D8`. Only the resolved
`0x438` config row is edited.

## Data changes

| Field | Meaning | v14 behavior |
|---|---|---|
| `director+0x518B0` | Encounter composition budget | `6x` |
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
adopt the faster v14 schedule.

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
reported to trigger anti-cheat termination. v14 does not restore that method.
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
`0.25x`. Baselines are retained so repeated checks do not stack multipliers.

## Diagnostics and validation

The log revision is `data-v14-native` or `data-v14-light-medium`. `p=` reports
Encounter budget, `c=` cap rows, `i=` scaled Straggler/Patrol intervals, `g=`
group clamp, `d=` unchanged desired target, `t=` deadlines shortened on the
latest check, `w=` biased/available candidates, and `cfg=` the active resolver
result. `l=vanilla` confirms executable population branches are unchanged.

Offline tests use synthetic private allocations to cover budget/cap scaling,
timer clamping, idempotence, config resolution, resource and cap-table cloning,
template bias, mission rebuilds, queue/counter preservation, and failure paths.
Package tests verify the manifest, hashes, resource identity, absence of custom
DLLs, and absence of executable-page modification APIs. Runtime verification
remains false until a matching game build is tested.
