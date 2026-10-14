# Optional Terminid replacement filters

All seven settings default to `false`, use the existing version-1 profile, and
are available in both the bilingual F8 panel and the optional MODS menu.
They only commit on Apply. The existing shared configuration service batches a
MODS Apply into one configure/save operation and preserves unrelated UI drafts.

| Setting | Selected family / source |
| --- | --- |
| `block_jumpers` | Pouncer, both Hunter tiers, Spore Burst Hunter; confirmed Scavenger-to-Pouncer sources |
| `block_yellow_spewers` | Nursing Spewer |
| `block_green_spewers` | Both Bile Spewer tiers |
| `block_bile_spitters` | Bile Spitter; confirmed Scavenger-to-Spitter sources |
| `block_scavengers` | Ordinary and Spore Burst Scavengers, including low difficulty |
| `block_shriekers` | Both verified Shrieker family rows |
| `block_all_small` | Effective OR of jumpers, spitters, scavengers and shriekers; does not overwrite individual selections or include Spewers |

## Runtime boundary

`enemy_filter.lua` changes the eight resource bytes at row offset `+0x08` in the
director's family table (`+0x660`, `0x80` row stride). Family IDs are matched to
native unit resources, not to display-name array positions. Native weights,
eligibility, caps, costs, tags, live counters and pending queues are preserved.
No native spawn/despawn function is called and no executable memory is modified.

Excluding every row is unsafe because a native caller dereferences the selected
row. Instead the filter chooses an eligible, positively weighted ordinary
Warrior row for the current difficulty: `BE39E313A1E46BB9` or
`32541FC4EC7C9CDC`. Native Warrior/Hive Guard swap rules still apply. This is a
resource substitution, not a reduction to the director's budget or unit count.

Runtime mission hashes and native rule priority resolve Scavenger conversion
sources: the spore rule takes precedence, and Spitter wins a tie with Pouncer.
Ordinary Scavenger, Spore Scavenger and Shrieker options additionally require
their verified source resource hashes; unknown/custom resources in those rows
are preserved.

The loader constructs this feature only when both module hashes match the
supported inputs in `scripts/archive.py`. The filter also checks native selector
instruction signatures, mission/host authority, complete table reads, writable
private memory, stable identities and write readback. Immutable tables are
copied into private memory with the entire `0xB0` header before publication.
Published copies are never freed while the native engine may reference them.

Restoration records contain original resource bytes and row identities, not old
foreign addresses. Disabling an option restores owned values only when the
current table is safely accessible and host authority is present. This survives
row reordering, difficulty changes and reused tables without overwriting a new
external resource. It does not restore a stale pointer after leaving a mission.

The feature follows the upstream Public/SOS latch, including returning to the
ship before clearing it. Unknown, invalid or unreadable privacy pauses new
replacements. Confirmed SOS use and unsupported probe builds gate the feature.
Probe initialization/runtime exceptions preserve upstream availability/retry
behavior. Existing multiplier, cooldown, corpse, input and SOS algorithms are
unchanged.

## Validation

The normal `python -B scripts/build.py panel-menus` build includes:

- `test_enemy_filter.lua`: private-memory replacements/restoration, readonly
  clones, host loss, mission changes, race/read/write faults, native conversion
  priority, master/individual behavior and known-resource guards.
- `test_enemy_filter_integration.lua`: old profiles, strict boolean validation,
  one-save menu batches, restoration across restart, both languages, and the
  real loader's Public/SOS/build/privacy failure paths.
- Existing panel, configuration, loader, optional-menu and package tests. When
  `HD2_MOD_OPTIONS_SOURCE` points to a ModOptionsMenu checkout, the upstream API
  test also applies all seven toggles, reopens F8 and checks translated labels.

These are offline checks, including isolated Win32 panel tests. In-game spawn
coverage, host/client behavior and stability remain unverified for this port.
Scripted/direct-resource spawns and already cached resources can bypass the
table. Earlier local observations included remaining Pouncers; the source of
those spawns was not established. Do not describe this as removing every enemy
of the selected kinds from every mission.
