# Enemy Spawn Multiplier 6x

**data-v9**, for Steam build **24826606** / EXE **1.8.45317.0**. Requires the separate **Bingus Shared Loader** with the `mods/cowboybingus/enemy_spawn_multiplier` resource registered.

This build multiplies the Encounter base composition budget by six and nonzero per-type caps by five. For the active spawn config, it divides Patrol and Straggler intervals by five (minimum 0.2 seconds) and multiplies the group-size clamp by five. It leaves `cfg+0x50` unchanged and removes four confirmed population early exits: effective count 70, component count 448, desired reached, and combined demand 100.

It resolves the active handle through the native director hash table and the resource-key fallback. When the resource fallback points at a read-only private table, it clones the full table into private writable memory and retargets the manager's table pointer before editing the selected row. Pending queue quantities, the queue accounting counter at `director+0x36C0`, native timestamps and the ProducedFighter counter at `director+0x620` remain read-only. Each code edit validates the original game bytes before changing the current process and rolls earlier edits back if a later edit fails. Position queries, template availability and candidate costs still apply. Gameplay verification is pending.

**Install:** Close the game, replace all previous Enemy Spawn Multiplier entries with `Enemy-Spawn-Multiplier-6x-v9.zip`, keep `Bingus-Shared-Loader-v12.zip` enabled, then deploy with **HDArsenal** or **HD2MM**. Restart before testing so earlier process-memory edits are discarded. See [installation](INSTALL.txt).

After entering a mission, check `%LOCALAPPDATA%/EnemySpawnMultiplier.log`:

- `data-v9` identifies this build.
- `spawn_multiplier_ready` means the active config was resolved, validated and scaled.
- `spawn_multiplier_partial` means budget/caps applied but the active config did not; `cfg=` gives the reason. Checks continue so delayed initialization can recover.
- `i=` lists Straggler/Patrol intervals; `g=` is their group clamp; `d=` is the unchanged active desired target; `l=off` confirms the four population early exits were patched. `cfg=director:...` or `cfg=resource:...` records the actual source and address.
- `t=0` is expected: there are no direct timestamp edits. `x=` is the native ProducedFighter count, not a configured population limit.

[Technical walkthrough](docs/TECHNICAL.md)
