"""Build and verify Enemy Spawn Multiplier variants without launching the game."""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys

sys.dont_write_bytecode = True

from archive import LUA, sha, EXE_SHA, GAME_DLL_SHA, GAME, ARCHIVE, TYPE, make_archive, resource_hash
from package import package_release
from module import build_module

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
TESTS = ROOT / 'tests'
BUILD = ROOT / 'build'
RESOURCE = 'mods/cowboybingus/enemy_spawn_multiplier'
IMPLEMENTATION_RESOURCE = RESOURCE + '_impl'
VARIANTS = {
    'base': {
        'revision': 'data-v20-native',
        'public_version': 'v20',
        'name': 'Enemy Spawn Multiplier 6x Native Composition',
        'description': 'Uses the native encounter budget override path at 6x, scales nonzero per-type caps and the group clamp to 10x, shortens Patrol/Straggler intervals to one tenth, and reduces Illuminate static-guard budget to preserve reinforcement capacity. Native template weights, population gates and executable code remain unchanged. Requires the official Bingus Shared Loader v15 or newer.',
        'template_bias': False,
    },
    'light-medium': {
        'revision': 'data-v20-light-medium',
        'public_version': 'v20',
        'name': 'Enemy Spawn Multiplier 6x Light-Medium Bias',
        'description': 'Uses the data-only spawn multipliers and favors Encounter templates with lower cost per unit. Unsupported faction template layouts fall back to native weights instead of stopping the core tuning. Illuminate static-guard budget is reduced to preserve reinforcement capacity. Requires the official Bingus Shared Loader v15 or newer.',
        'template_bias': True,
    },
    'fast-cadence': {
        'revision': 'data-v20-fast-cadence',
        'public_version': 'v20',
        'name': 'Enemy Spawn Multiplier Fast Cadence',
        'description': 'Behaviour-focused spawn retuning. Enemy reinforcement arrives on a much shorter cooldown, and both reinforcement waves and their point budget are steered toward heavier units, while patrols spawn more frequently, in greater numbers and in larger groups. The per-wave reinforcement point budget is reduced, so a wave is composed of fewer but heavier units rather than being larger overall. Changes writable private data only, verifies the supported game build before writing, keeps every changed value restorable from a stored baseline so repeated updates cannot stack, and never modifies executable code or calls native spawn functions. Requires the official Bingus Shared Loader v15 or newer.',
        'template_bias': True,
        'overrides': {
            'budget_multiplier': 0.4,
            'budget_override_multiplier': 0.4,
            'derive_override_from_base': False,
            'force_override_to_base': True,
            'encounter_deadline_enabled': True,
            'encounter_max_interval': 2.0,
            'traveler_cooldown_enabled': False,
            'traveler_cooldown_min': 0.0,
            'traveler_cooldown_max': 0.0,
            'modifier_scale_enabled': True,
            'modifier_encounter_cooldown': 3.0,
            'modifier_patrol_count': 6.0,
            'modifier_patrol_cooldown': 3.0,
            'modifier_travelers_max_unit': 6.0,
            'template_bias_light': 0.25,
            'template_bias_medium': 1.0,
            'template_bias_heavy': 4.0,
            'probe_timers_enabled': True,
            'guardforce_write_enabled': False,
            'illuminate_guardforce_multiplier': 1.0,
            'interval_mode': 'fixed',
            'fixed_interval_min': 0.0,
            'fixed_interval_max': 0.1,
            'allow_zero_interval_min': True,
            'cap_multiplier': 10,
            'group_multiplier': 10,
        },
    },
    'panel': {
        'revision': 'data-v20-panel-blackbox',
        'public_version': 'v20-blackbox',
        'name': 'Enemy Spawn Multiplier Panel Blackbox',
        'panel': True,
        'description': 'Panel build with a light always-on blackbox for crash triage. Press F8 for the configuration overlay; use Export game log to dump the live log/cfg onto the Desktop. Starts from 2x budget, 2x patrol count, 1x patrol size adjustable from 0.1x to 2x, both cooldowns at the fast end (2 s) and the heavy-focus preset. Logs updater cost and resource-clone events. Changes writable private data only. Requires the official Bingus Shared Loader v15 or newer.',
        'template_bias': True,
        'overrides': {
            'budget_multiplier': 2.0,
            'budget_override_multiplier': 2.0,
            'derive_override_from_base': False,
            'force_override_to_base': True,
            'encounter_deadline_enabled': True,
            'encounter_max_interval': 2.0,
            'traveler_cooldown_enabled': False,
            'traveler_cooldown_min': 0.0,
            'traveler_cooldown_max': 0.0,
            'modifier_scale_enabled': True,
            'modifier_encounter_cooldown': 3.0,
            'modifier_patrol_count': 2.0,
            'modifier_patrol_cooldown': 6.0,
            'modifier_travelers_max_unit': 1.0,
            'template_bias_light': 0.25,
            'template_bias_medium': 1.0,
            'template_bias_heavy': 4.0,
            'probe_timers_enabled': True,
            'guardforce_write_enabled': False,
            'illuminate_guardforce_multiplier': 1.0,
            'interval_mode': 'fixed',
            'fixed_interval_min': 0.0,
            'fixed_interval_max': 0.1,
            'allow_zero_interval_min': True,
            'cap_multiplier': 10,
            'group_multiplier': 10,
        },
    },
    'preview-patrol-2x-3x': {
        'revision': 'data-v20-preview-patrol-2x-3x',
        'public_version': 'v20-preview',
        'name': 'Enemy Spawn Multiplier Preview Patrol 2x-3x',
        'description': 'Local preview build for lower-end machines. Same reinforcement profile as Fast Cadence, but the patrol pair is rebalanced so far fewer entities are live at once: a smaller patrol count curve and smaller per-wave squad curve keep clear of the shared component gate that a crash-prone machine runs into. Changes writable private data only, verifies the supported game build before writing, keeps every changed value restorable from a stored baseline so repeated updates cannot stack, and never modifies executable code or calls native spawn functions. Requires the official Bingus Shared Loader v15 or newer.',
        'template_bias': True,
        'overrides': {
            'budget_multiplier': 0.4,
            'budget_override_multiplier': 0.4,
            'derive_override_from_base': False,
            'force_override_to_base': True,
            'encounter_deadline_enabled': True,
            'encounter_max_interval': 2.0,
            'traveler_cooldown_enabled': False,
            'traveler_cooldown_min': 0.0,
            'traveler_cooldown_max': 0.0,
            'modifier_scale_enabled': True,
            'modifier_encounter_cooldown': 3.0,
            'modifier_patrol_count': 2.0,
            'modifier_patrol_cooldown': 3.0,
            'modifier_travelers_max_unit': 3.0,
            'template_bias_light': 0.25,
            'template_bias_medium': 1.0,
            'template_bias_heavy': 4.0,
            'probe_timers_enabled': True,
            'guardforce_write_enabled': False,
            'illuminate_guardforce_multiplier': 1.0,
            'interval_mode': 'fixed',
            'fixed_interval_min': 0.0,
            'fixed_interval_max': 0.1,
            'allow_zero_interval_min': True,
            'cap_multiplier': 10,
            'group_multiplier': 10,
        },
    },
}


def run(args, **kwargs):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def inspect_archive(data):
    magic, version, count = struct.unpack_from('<III', data)
    if (magic, version) != (0xF0000011, 1):
        raise ValueError('Unsupported archive header')
    resources = []
    for index in range(count):
        entry = struct.unpack_from('<7Q6I', data, 104 + index * 80)
        offset, size = entry[2], entry[7]
        if offset % 16 or offset + size > len(data):
            raise ValueError('Archive resource is misaligned')
        if struct.unpack_from('<II', data, offset) != (size - 8, 2):
            raise ValueError('Archive resource is not a Lua resource')
        resources.append({'name': entry[0], 'type': entry[1], 'offset': offset, 'size': size, 'index': entry[12]})
    return {'num_files': count, 'resources': resources}


def main():
    if len(sys.argv) == 1:
        for key in VARIANTS:
            print(run([sys.executable, Path(__file__), key]).strip())
        return
    if len(sys.argv) != 2 or sys.argv[1] not in VARIANTS:
        raise SystemExit('Usage: build.py [base|light-medium|fast-cadence|panel|preview-patrol-2x-3x]')
    key = sys.argv[1]
    variant = VARIANTS[key]
    revision = variant['revision']
    settings = {
        'budget_multiplier': 6,
        'budget_override_multiplier': 6,
        'derive_override_from_base': True,
        'force_override_to_base': False,
        'encounter_deadline_enabled': False,
        'encounter_max_interval': 2.0,
        'traveler_cooldown_enabled': False,
        'traveler_cooldown_min': 0.0,
        'traveler_cooldown_max': 0.0,
        'modifier_scale_enabled': False,
        'modifier_encounter_cooldown': 0.0,
        'modifier_patrol_count': 0.0,
        'modifier_patrol_cooldown': 0.0,
        'modifier_travelers_max_unit': 0.0,
        'template_bias_light': 3.6,
        'template_bias_medium': 1.25,
        'template_bias_heavy': 0.25,
        'probe_timers_enabled': False,
        'guardforce_write_enabled': True,
        'illuminate_guardforce_multiplier': 0.25,
        'interval_mode': 'divide',
        'interval_divisor': 10,
        'fixed_interval_min': None,
        'fixed_interval_max': None,
        'allow_zero_interval_min': False,
        'cap_multiplier': 10,
        'group_multiplier': 10,
    }
    settings.update(variant.get('overrides') or {})
    build = BUILD / key
    for relative, expected in [('bin/helldivers2.exe', EXE_SHA), ('data/game/game.dll', GAME_DLL_SHA)]:
        if sha((GAME / relative).read_bytes()) != expected:
            raise ValueError('Unsupported game build: ' + relative)
    resources = build_module(ROOT, build, RESOURCE, 'spawn_patch.lua', revision,
                             template_bias=variant['template_bias'],
                             overrides=variant.get('overrides'),
                             with_panel=variant.get('panel', False))
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    tests = run([LUA, TESTS / 'test_data.lua', SOURCE, build, sha(LUA.read_bytes())], env=env)
    if key in ('fast-cadence', 'preview-patrol-2x-3x', 'panel'):
        tests += '\n' + run([LUA, TESTS / 'test_fast_cadence.lua', SOURCE, build, sha(LUA.read_bytes()),
                             settings['modifier_patrol_count'], settings['modifier_travelers_max_unit']], env=env)
    tests += '\n' + run([LUA, TESTS / 'test_panel_model.lua', SOURCE, build], env=env)
    tests += '\n' + run([LUA, TESTS / 'test_config_store.lua', SOURCE, build], env=env)
    tests += '\n' + run([LUA, TESTS / 'test_diag_export.lua', SOURCE], env=env)
    if variant.get('panel', False) and os.name == 'nt':
        tests += '\n' + run([LUA, TESTS / 'test_panel_config.lua', SOURCE, build], env=env)
    tests += '\n' + run([LUA, TESTS / 'test_bindings.lua', SOURCE], env=env)
    tests += '\n' + run([LUA, TESTS / 'test_anchor_check.lua', SOURCE], env=env)
    if os.name == 'nt':
        tests += '\n' + run([LUA, TESTS / 'test_panel_smoke.lua', SOURCE], env=env)
    tests += '\n' + run([LUA, TESTS / 'test_panel_loader.lua', SOURCE, BUILD], env=env)
    (build / 'offline-tests.txt').write_text(tests, encoding='utf-8')
    data = build / 'data'
    data.mkdir(exist_ok=True)
    archive = make_archive(resources)
    (data / ARCHIVE).write_bytes(archive)
    for suffix in ('.stream', '.gpu_resources'):
        (data / (ARCHIVE + suffix)).write_bytes(b'')
    inspection = inspect_archive(archive)
    (build / 'archive-inspection.json').write_text(json.dumps(inspection, indent=2) + '\n', encoding='utf-8')
    expected = {resource_hash(RESOURCE), resource_hash(IMPLEMENTATION_RESOURCE)}
    actual = {item['name'] for item in inspection['resources']}
    if inspection['num_files'] != 2 or actual != expected or any(item['type'] != TYPE for item in inspection['resources']):
        raise ValueError('Archive must contain only this mod module')
    files = {f'data/{ARCHIVE}{suffix}': f'build/{key}/data/{ARCHIVE}{suffix}'
             for suffix in ('', '.stream', '.gpu_resources')}
    report = {
        'name': variant['name'], 'slug': 'EnemySpawnMultiplier',
        'version': 20,
        'public_version': variant['public_version'],
        'guid': '7d2c8e41-5b6a-4f19-9e3d-1a84c0b572fe', 'revision': revision,
        'description': variant['description'],
        'game_exe_sha256': EXE_SHA, 'game_dll_sha256': GAME_DLL_SHA,
        'deployment_files': files, 'files': {path: sha((ROOT / path).read_bytes()) for path in files.values()},
        'data_change': {
            'director_pointer_rva': '0x3326D10', 'mode_rva': '0x33266A0',
            'cap_table_offset': '0x660', 'cap_header_clone_size': '0xB0',
            'encounter_points_offset': '0x518B0', 'guardforce_points_offset': '0x518B4',
            'pop_counter_offset': '0x620', 'timer_offsets': ['0x3A518', '0x3A520'],
            'config_resolver': 'native_handle_hash_with_resource_fallback', 'config_handle_offset': '0x6B0',
            'config_table_offset': '0x51968', 'config_count_offset': '0x51970',
            'config_hash_multiplier_offset': '0x51978', 'config_sentinel_offset': '0x51974',
            'config_invalid_generation_rva': '0x3483C24',
            'resource_manager_rva': '0x346BF98', 'resource_table_offset': '0xF12B18',
            'resource_hash_slots': 38,
            'resource_table_clone': True,
            'cfg_base_offset': '0x519AC', 'cfg_stride': '0x43C',
            'interval_offsets': ['0x38', '0x3c', '0x40', '0x44'], 'group_clamp_offset': '0x48',
            'desired_offset': '0x50', 'desired_write': False,
            'budget_override_offset': '0x78', 'budget_override_multiplier': settings['budget_override_multiplier'],
            'template_bias': 'relative_cost_per_unit' if variant['template_bias'] else 'native',
            'template_bias_quantiles': {'light_max': 0.5, 'medium_max': 0.8},
            'template_weight_multipliers': {'light': settings['template_bias_light'],
                                            'medium': settings['template_bias_medium'],
                                            'heavy': settings['template_bias_heavy']},
            'template_bias_unsupported_layout': 'native_weight_fallback',
            'faction_cap_counts': {'automaton': 61, 'terminid': 44, 'illuminate': 45},
            'illuminate_guardforce_multiplier': settings['illuminate_guardforce_multiplier'],
            'entry_stride': '0x80', 'max_offset': '0x18',
            'budget_multiplier': settings['budget_multiplier'], 'cap_multiplier': settings['cap_multiplier'],
            'derive_override_from_base': settings['derive_override_from_base'],
            'force_override_to_base': settings['force_override_to_base'],
            'encounter_deadline_offset': '0x399D8',
            'encounter_manager_rva': '0x3326618',
            'encounter_manager_count_offset': '0x934',
            'encounter_deadline_writer_rva': '0x957E08',
            'encounter_admission_rva': '0x957140',
            'scheduler_a_rva': '0x3326588', 'scheduler_a_offset': '0x4A4',
            'scheduler_b_rva': '0x3326D18', 'scheduler_b_offset': '0x1C',
            'scheduler_flags': ['0x5189C', '0x518A0', '0x518A4', '0x518A8'],
            'hive_mind_config': {'component': 'HiveMindComponent', 'row_size': '0x43C',
                                 'traveler_spawn_point_cooldown': ['0x0C', '0x10'],
                                 'travelers_max_unit_count_multiplier': '0x3F8',
                                 'travelers_getter_rva': '0x94E900',
                                 'patrol_count_max_modifier': '0x1A0',
                                 'patrol_spawn_cooldown_rate_modifier': '0x1DC',
                                 'travelers_waves_cooldown_multiplier': '0x3BC',
                                 'travelers_max_unit_count_multiplier': '0x3F8'},
            'traveler_cooldown_enabled': settings['traveler_cooldown_enabled'],
            'traveler_cooldown_min': settings['traveler_cooldown_min'],
            'traveler_cooldown_max': settings['traveler_cooldown_max'],
            'modifier_scale_enabled': settings['modifier_scale_enabled'],
            'modifier_blocks': {'encounter_cooldown_rate': '0x164', 'patrol_count_max': '0x1A0',
                                'patrol_spawn_cooldown_rate': '0x1DC', 'block_floats': 15,
                                'evaluator_rva': '0xFE5280'},
            'modifier_scales': {'encounter_cooldown': settings['modifier_encounter_cooldown'],
                                'patrol_count': settings['modifier_patrol_count'],
                                'patrol_cooldown': settings['modifier_patrol_cooldown'],
                                'travelers_max_unit': settings['modifier_travelers_max_unit']},
            'encounter_deadline_enabled': settings['encounter_deadline_enabled'],
            'encounter_max_interval': settings['encounter_max_interval'],
            'probe_timer_offsets': ['0x399D0', '0x399E8', '0x399F0', '0x3A510', '0x3A528', '0x3A530', '0x3A538'],
            'probe_timers_enabled': settings['probe_timers_enabled'],
            'timeline_log': {'interval_seconds': 1.0, 'rotate_bytes': 4194304},
            'interval_mode': settings['interval_mode'], 'interval_divisor': settings['interval_divisor'],
            'fixed_interval_min': settings['fixed_interval_min'], 'fixed_interval_max': settings['fixed_interval_max'],
            'allow_zero_interval_min': settings['allow_zero_interval_min'],
            'group_multiplier': settings['group_multiplier'],
            'mission_reset_check_seconds': 0.1,
            'guardforce_changed': 'illuminate_only' if settings['guardforce_write_enabled'] else 'none',
            'guardforce_write_enabled': settings['guardforce_write_enabled'],
            'live_counter_writes': False, 'pending_queue_writes': False,
            'native_timestamp_writes': 'future_deadline_clamp_only', 'runtime_verified': False,
            'native_code_patches': [],
        },
        'continuous_update_hook': True, 'shutdown_hook': False, 'executable_code_writes': 0,
        'executable_memory_changed': False,
        'configuration_panel': bool(variant.get('panel', False)),
        'loader_integration': {
            'minimum_loader_version': 15, 'api': 1,
            'discovery_entry': RESOURCE, 'implementation_resource': IMPLEMENTATION_RESOURCE,
            'legacy_registry_compatible': True,
        },
        'offline_tests': tests.strip().splitlines(),
    }
    report['requires'] = [{'name': 'Bingus Shared Loader', 'guid': '612eaf70-d682-43c7-9efd-16dcc695f977',
                           'api': 1, 'minimum_version': 15}]
    if variant.get('panel', False):
        # Optional companion: without it the panel keeps its built-in F8 toggle.
        report['optional_requires'] = [{'name': 'Mod Bindings Menu',
                                        'guid': 'e40fc537-c2a2-493b-ad0f-2255c6a0174e',
                                        'api': 1,
                                        'purpose': 'custom toggle key; F8 is used when absent'}]
    sources = list(SOURCE.glob('*.lua')) + list(TESTS.glob('*.lua')) + list((ROOT / 'scripts').glob('*.py'))
    report['source_sha256'] = {path.relative_to(ROOT).as_posix(): sha(path.read_bytes()) for path in sources}
    release = package_release(ROOT, build, report)
    package_tests = run([sys.executable, TESTS / 'test_package.py', release])
    (build / 'package-tests.txt').write_text(package_tests, encoding='utf-8')
    report['package_tests'] = package_tests.strip().splitlines()
    report['release'] = {'path': Path(os.path.relpath(release, ROOT)).as_posix(), 'sha256': sha(release.read_bytes())}
    report_path = BUILD / ('build-report-' + key + '.json')
    report_path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    if key == 'light-medium':
        (BUILD / 'build-report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(tests.strip())
    print(package_tests.strip())
    print('Built ' + release.name + '; no installation or game launch performed.')


if __name__ == '__main__':
    main()

