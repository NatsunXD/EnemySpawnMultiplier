"""Build and verify Enemy Spawn Multiplier 6x without launching the game."""
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
        'revision': 'data-v16-native',
        'name': 'Enemy Spawn Multiplier 6x Native Composition',
        'description': 'Uses the native encounter budget override path at 6x, scales nonzero per-type caps and the group clamp to 10x, shortens Patrol/Straggler intervals to one tenth, and reduces Illuminate static-guard budget to preserve reinforcement capacity. Native template weights, population gates and executable code remain unchanged. Requires the official Bingus Shared Loader v15 or newer.',
        'template_bias': False,
    },
    'light-medium': {
        'revision': 'data-v16-light-medium',
        'name': 'Enemy Spawn Multiplier 6x Light-Medium Bias',
        'description': 'Uses the data-only spawn multipliers and favors Encounter templates with lower cost per unit. Unsupported faction template layouts fall back to native weights instead of stopping the core tuning. Illuminate static-guard budget is reduced to preserve reinforcement capacity. Requires the official Bingus Shared Loader v15 or newer.',
        'template_bias': True,
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
        raise SystemExit('Usage: build.py [base|light-medium]')
    key = sys.argv[1]
    variant = VARIANTS[key]
    revision = variant['revision']
    build = BUILD / key
    for relative, expected in [('bin/helldivers2.exe', EXE_SHA), ('data/game/game.dll', GAME_DLL_SHA)]:
        if sha((GAME / relative).read_bytes()) != expected:
            raise ValueError('Unsupported game build: ' + relative)
    resources = build_module(ROOT, build, RESOURCE, 'spawn_patch.lua', revision,
                             template_bias=variant['template_bias'])
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    tests = run([LUA, TESTS / 'test_data.lua', SOURCE, build, sha(LUA.read_bytes())], env=env)
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
        'version': 16,
        'guid': '7d2c8e41-5b6a-4f19-9e3d-1a84c0b572fe', 'revision': revision,
        'description': variant['description'],
        'game_exe_sha256': EXE_SHA, 'game_dll_sha256': GAME_DLL_SHA,
        'deployment_files': files, 'files': {path: sha((ROOT / path).read_bytes()) for path in files.values()},
        'data_change': {
            'director_pointer_rva': '0x276CA20', 'mode_rva': '0x276c3d0',
            'cap_table_offset': '0x660', 'cap_header_clone_size': '0xB0',
            'encounter_points_offset': '0x518B0', 'guardforce_points_offset': '0x518B4',
            'pop_counter_offset': '0x620', 'timer_offsets': ['0x3A518', '0x3A520'],
            'config_resolver': 'native_handle_hash_with_resource_fallback', 'config_handle_offset': '0x6B0',
            'config_table_offset': '0x51960', 'config_count_offset': '0x51968',
            'config_hash_multiplier_offset': '0x51970', 'config_sentinel_offset': '0x5196C',
            'config_invalid_generation_rva': '0x2786C64',
            'resource_manager_rva': '0x276F0C0', 'resource_table_offset': '0xF116D8',
            'resource_hash_slots': 38,
            'resource_table_clone': True,
            'cfg_base_offset': '0x519A4', 'cfg_stride': '0x438',
            'interval_offsets': ['0x38', '0x3c', '0x40', '0x44'], 'group_clamp_offset': '0x48',
            'desired_offset': '0x50', 'desired_write': False,
            'budget_override_offset': '0x78', 'budget_override_multiplier': 6,
            'template_bias': 'relative_cost_per_unit' if variant['template_bias'] else 'native',
            'template_bias_quantiles': {'light_max': 0.5, 'medium_max': 0.8},
            'template_weight_multipliers': {'light': 3.6, 'medium': 1.25, 'heavy': 0.25},
            'template_bias_unsupported_layout': 'native_weight_fallback',
            'faction_cap_counts': {'automaton': 48, 'terminid': 44, 'illuminate': 42},
            'illuminate_guardforce_multiplier': 0.25,
            'entry_stride': '0x80', 'max_offset': '0x18',
            'budget_multiplier': 6, 'cap_multiplier': 10,
            'interval_divisor': 10, 'group_multiplier': 10,
            'mission_reset_check_seconds': 0.1, 'guardforce_changed': 'illuminate_only',
            'live_counter_writes': False, 'pending_queue_writes': False,
            'native_timestamp_writes': 'future_deadline_clamp_only', 'runtime_verified': False,
            'native_code_patches': [],
        },
        'continuous_update_hook': True, 'shutdown_hook': False, 'executable_code_writes': 0,
        'executable_memory_changed': False,
        'loader_integration': {
            'minimum_loader_version': 15, 'api': 1,
            'discovery_entry': RESOURCE, 'implementation_resource': IMPLEMENTATION_RESOURCE,
            'legacy_registry_compatible': True,
        },
        'offline_tests': tests.strip().splitlines(),
    }
    report['requires'] = [{'name': 'Bingus Shared Loader', 'guid': '612eaf70-d682-43c7-9efd-16dcc695f977',
                           'api': 1, 'minimum_version': 15}]
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
