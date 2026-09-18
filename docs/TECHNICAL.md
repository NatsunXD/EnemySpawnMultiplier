# Enemy Spawn Multiplier data-v9

Targets Steam build 24826606 / EXE 1.8.45317.0. Addresses below are game.dll RVAs or explicitly named object offsets. Static findings are recorded in `research/SPAWN_FINDINGS_2026-09-18.md` at the workspace root. Gameplay verification is pending.

## Active config resolution

`game.dll+0x276CA20` holds the director. Mission presence uses the mode pointer at `game.dll+0x276C3D0` and `mode+8`. The active spawn handle is at `director+0x6B0`.

Native resolver `0x501490` compares handle generation `handle+8` with `game.dll+0x2786C64`. Unless it matches that invalid-generation value, the resolver hashes the generation through the table at `director+0x51960`. Capacity is at `+0x51968`, empty-key sentinel at `+0x5196C`, hash multiplier at `+0x51970`. Entries are 8-byte key/index pairs. The initial slot is the low 32-bit product masked by capacity minus one; collisions use linear probing. A valid index resolves to `director+0x519A4 + index*0x438`.

The patch follows this path, validates a power-of-two capacity up to 64, and conservatively accepts director indices below 8. Multiplication is reduced modulo capacity first to preserve low bits with Lua's double-precision arithmetic. Hash capacity is not treated as a count of config objects.

An invalid generation, missing hash entry or index `0xFFFFFFFF` invokes the resource-key fallback corresponding to native `0x500E60`. The manager pointer is at `game.dll+0x276F0C0`; its `+0xF116D8` points to a 38-slot table with 16-byte entries. The full unsigned 64-bit key at `handle+0` is hashed modulo 38, with linear probing and zero as the empty key. An entry's index at `+8` resolves to `table+0x260 + index*0x438`. The implementation hashes the key byte-by-byte without converting it to a lossy Lua number. Resource indices are bounded below 38.

Only the selected config is edited. Director configs must already be private, writable, non-executable memory. A read-only resource table is copied as one `0x260 + 38*0x438` block into private writable memory, the manager's `+0xF116D8` pointer is retargeted, and then the selected row is edited. If the manager pointer cannot be retargeted, activation remains partial. Separately, the four population branches listed below are edited on executable image pages after exact byte validation.

## Changes

| Field | Meaning | Edit |
|---|---|---|
| director+0x518B0 | Encounter base composition budget | x6 |
| director+0x518B4 | Guardforce budget | Read for validation only |
| cfg+0x38/+0x3C | Type 8 Straggler intervals | /5, minimum 0.2 seconds |
| cfg+0x40/+0x44 | Type 1 Patrol intervals | /5, minimum 0.2 seconds |
| cfg+0x48 | Group-size clamp | x5 |
| cfg+0x50 | Desired target | Read-only |
| cfg+0x80 | Another count scaler | Unchanged |
| director+0x660 cap table, row+0x18 | Nonzero per-type maxima | x5 |
| director+0x36D0 + slot*0x908, slot+0x900 | Queued submission quantity | Read-only |
| director+0x36C0 | Pending-quantity accounting | Read-only |

Cap rows are 0x80 bytes, identified by the id at +0. Zero maxima retain the native skip semantics. Image-backed cap tables are copied to a private allocation before the director's table pointer is retargeted. Repeated updates retain baselines and avoid multiplying their own writes. Config reload recovery retains the previous vanilla/scaled interval heuristic, so unfamiliar mission layouts still need live validation.

The Encounter chain `0x94CCF0 -> 0x94AF30 -> 0x94BCC0 -> 0x94B1C0` reads the base budget, applies config/environment factors and spends a local integer copy on weighted candidates. Candidate templates can contain multiple type/count records. More budget can support more candidates or different composition; it is not an exact enemy-count multiplier. A positive cfg+0x78 overrides the base-budget calculation and remains unchanged.

Timed Patrol uses a different weighted selection path (`0x94AD00`). Increasing the Encounter budget does not directly multiply Patrol quantities. Patrol and Straggler use the interval and clamp edits shown above, but their requested quantity remains limited by native demand. Straggler also draws a random count between a lower bound and its clamped upper bound.

## Removed population exits

Four conditional branches are replaced with NOPs after exact original-byte validation:

| Branch RVA | Original | Replacement | Removed exit |
|---|---|---|---|
| `0x947E69` | `7D B0` | `90 90` | effective count >= 70 |
| `0x947E79` | `73 A0` | `90 90` | component count >= 448 |
| `0x9512B9` | `0F 83 8D 02 00 00` | six NOPs | active count >= desired target |
| `0x9512C5` | `0F 83 81 02 00 00` | six NOPs | combined demand >= 100 |

The patch changes only the rejection branches; it keeps the calculations and later group-size clipping intact. The API accepts only committed executable image pages, temporarily uses execute/read/write protection, restores the original protection, flushes the instruction cache and verifies readback. If a later branch fails validation or writing, branches changed by that attempt are restored in reverse order.

## Desired target and pending queue

`cfg+0x50` remains read-only in v9. Its value is retained in the `d=` diagnostic so live tests can correlate the game's selected target with observed spawning without combining that experiment with the branch removals.

Native submissions place requests in a 96-slot ring at `director+0x36D0` with a 0x908 stride. Each slot stores its request type at `+0x8F4` and queued quantity at `+0x900`; `director+0x36C0` is pending-quantity accounting used by native population gates. V7 multiplied both values, which could make those gates reject later requests sooner. V9 leaves queue slots and `+0x36C0` untouched.

## Native timing and limits

This build never writes the pending timestamps at director+0x3A518/+0x3A520. The next successful native scheduling roll uses the edited intervals. This avoids the v5 possibility of dividing an already-shortened interval again. Resource-table cloning is persistent for the current manager table and is re-established if a later mission rebuild restores the original pointer.

The native update clears and rebuilds director+0x610..+0x638 as per-type counts. In particular, +0x620 is ProducedFighter count, not a configurable population exemption. The patch reads it only for diagnostics. The former 70 check used queued quantity plus a manager count minus Encounter and ProducedFighter counts, with type/flag exceptions; the following component-manager comparison used 448. V9 disables both rejection branches without overwriting any counter.

The earlier demand check computes T from cfg+0x50 and a scale, A from one component manager and B from another. It formerly exited when A >= T or unsigned((T-A)+(B-A)) >= 100. V9 disables both exits while leaving T, A, B and the later group clamp calculations intact. Position-query retries, queueing and template limits can still prevent the observed total from tracking the configured multipliers.

## Lifecycle and diagnostics

The package is one named Lua resource: `mods/cowboybingus/enemy_spawn_multiplier`. GUID remains `7d2c8e41-5b6a-4f19-9e3d-1a84c0b572fe`. The separately installed Bingus Shared Loader loads it; this package contains no loader replacement or custom DLL.

The lifecycle checks supported module hashes, preserves the previous update callback and checks mission data every 100 ms. Fatal write/layout failures stop this module's checks. Missing or unsupported config resolution is recoverable: budget/caps can be active with status `spawn_multiplier_partial`; later checks can become `spawn_multiplier_ready` when the active config succeeds. Before any usable data, the status is `waiting_for_mission` or `waiting_for_spawn_config`.

`%LOCALAPPDATA%/EnemySpawnMultiplier.log` contains revision, status and diagnostic detail. `p=` is budget/current baseline, `c=` valid/total cap rows, `i=` Straggler then Patrol intervals, `g=` group clamp, `d=` the unchanged active desired target, `l=off` confirms the four code branches are disabled, and `cfg=` is the source/index/address or failure reason. `t=0` records that pending timestamps are not edited. `x=` reports native ProducedFighter count. A ready status verifies writes, not gameplay totals.

## Validation

The offline suite uses local synthetic allocations to test the four exact branch replacements, one-time patching, separate 6x budget and 5x cap/group/interval factors, desired and pending queue preservation, native counter and timestamp preservation, active-config selection, hash collisions, resource fallback, idempotence, mission reinitialization, private cap cloning, layout failures and callback behavior. ZIP checks cover manifest version, resource identity, hashes, code-patch API presence, forbidden remote-thread/DLL-loading payloads and relocation. The release records runtime verification as false until tested in game.
