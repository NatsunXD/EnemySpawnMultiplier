"""Verify the release ZIP, including its manager manifest and artwork."""
import hashlib
import json
from pathlib import Path
import struct
import zlib
import sys
import tempfile
import zipfile


def main():
    archive_name = '9ba626afa44a3aa3.patch_0'
    with zipfile.ZipFile(sys.argv[1]) as package:
        payloads = {name: package.read(name) for name in package.namelist()}
        expected = {f'data/{archive_name}{suffix}' for suffix in ('', '.stream', '.gpu_resources')}
        expected |= {'manifest.json', 'EnemySpawnMultiplier-manifest.json', 'EnemySpawnMultiplier-README.txt', 'thumbnail.png'}
        assert set(payloads) == expected and len(package.namelist()) == len(expected)
        assert not any(name.lower().endswith(('.dll', '.exe', '.lua', '.ps1')) for name in payloads)
        manifest = json.loads(payloads['manifest.json'])
        provenance = json.loads(payloads['EnemySpawnMultiplier-manifest.json'])
        display_name = provenance['name'] + ' - ' + provenance['display_version']
        assert manifest.get('Version') == 1, 'HD2MM requires an explicit V1 manifest'
        assert manifest['Name'] == display_name
        assert manifest['Options'] == [{'Name': display_name, 'Description': manifest['Description'],
                                        'Include': ['data'], 'Image': 'thumbnail.png'}]
        assert manifest['IconPath'] == 'thumbnail.png'
        assert payloads['thumbnail.png'].startswith(b'\x89PNG\r\n\x1a\n')
        png, offset = payloads['thumbnail.png'], 8
        while offset < len(png):
            size = int.from_bytes(png[offset:offset + 4], 'big')
            kind = png[offset + 4:offset + 8]
            assert kind in (b'IHDR', b'IDAT', b'IEND')
            end = offset + 8 + size
            assert end + 4 <= len(png)
            assert zlib.crc32(png[offset + 4:end]) == int.from_bytes(png[end:end + 4], 'big')
            offset = end + 4
        assert offset == len(png)
        expected_versions = {
            'data-v20-native': 'v20',
            'data-v20-light-medium': 'v20',
            'data-v20-fast-cadence': 'v20',
            'data-v20-preview-patrol-2x-3x': 'v20-preview',
            'data-v20-panel': 'v20',
            'data-v20-panel-blackbox': 'v20-blackbox',
        }
        assert provenance['revision'] in expected_versions
        assert provenance['display_version'] == expected_versions[provenance['revision']]
        assert provenance['runtime_verified'] is False
        change = provenance.get('data_change')
        assert change is not None
        if provenance['revision'] in ('data-v20-fast-cadence', 'data-v20-preview-patrol-2x-3x',
                                      'data-v20-panel', 'data-v20-panel-blackbox'):
            expected_patrol_count, expected_travelers_max_unit = (6.0, 6.0)
            if provenance['revision'] == 'data-v20-preview-patrol-2x-3x':
                expected_patrol_count, expected_travelers_max_unit = 2.0, 3.0
            elif provenance['revision'] in ('data-v20-panel', 'data-v20-panel-blackbox'):
                expected_patrol_count = 2.0
                expected_travelers_max_unit = 1.0 if provenance['revision'] == 'data-v20-panel-blackbox' else 2.0
            expected_budget = 2.0 if provenance['revision'] in (
                'data-v20-panel', 'data-v20-panel-blackbox') else 0.4
            assert change['budget_multiplier'] == expected_budget
            assert change['budget_override_multiplier'] == expected_budget
            assert change['derive_override_from_base'] is False
            assert change['force_override_to_base'] is True
            assert change['encounter_deadline_offset'] == '0x399D8'
            assert change['encounter_deadline_writer_rva'] == '0x957E08'
            assert change['encounter_admission_rva'] == '0x957140'
            assert change['encounter_deadline_enabled'] is True
            assert change['encounter_max_interval'] == 2.0
            assert change['traveler_cooldown_enabled'] is False
            assert change['modifier_scale_enabled'] is True
            # The patrol refresh curve has its own fastest end. The panel build
            # ships that end at 6x; the Fast Cadence and preview builds keep the
            # long-standing 3x value they were tuned and live-tested with.
            expected_patrol_cd = 6.0 if provenance['revision'] in (
                'data-v20-panel', 'data-v20-panel-blackbox') else 3.0
            assert change['modifier_scales'] == {'encounter_cooldown': 3.0,
                                                 'patrol_count': expected_patrol_count,
                                                 'patrol_cooldown': expected_patrol_cd,
                                                 'travelers_max_unit': expected_travelers_max_unit}
            assert change['modifier_blocks']['encounter_cooldown_rate'] == '0x164'
            assert change['modifier_blocks']['patrol_count_max'] == '0x1A0'
            assert change['modifier_blocks']['patrol_spawn_cooldown_rate'] == '0x1DC'
            assert change['template_bias'] == 'relative_cost_per_unit'
            assert change['template_weight_multipliers'] == {'light': 0.25,
                                                             'medium': 1.0,
                                                             'heavy': 4.0}
            assert change['hive_mind_config']['travelers_max_unit_count_multiplier'] == '0x3F8'
            assert change['hive_mind_config']['travelers_getter_rva'] == '0x94E900'
            assert change['modifier_blocks']['block_floats'] == 15
            assert change['modifier_blocks']['evaluator_rva'] == '0xFE5280'
            assert change['hive_mind_config']['traveler_spawn_point_cooldown'] == ['0x0C', '0x10']
            assert change['probe_timers_enabled'] is True
            assert change['probe_timer_offsets'] == ['0x399D0', '0x399E8', '0x399F0', '0x3A510', '0x3A528', '0x3A530', '0x3A538']
            assert change['timeline_log'] == {'interval_seconds': 1.0, 'rotate_bytes': 4194304}
            assert change['encounter_manager_rva'] == '0x3326618'
            assert change['encounter_manager_count_offset'] == '0x934'
            assert change['scheduler_a_rva'] == '0x3326588'
            assert change['scheduler_a_offset'] == '0x4A4'
            assert change['scheduler_b_rva'] == '0x3326D18'
            assert change['scheduler_b_offset'] == '0x1C'
            assert change['scheduler_flags'] == ['0x5189C', '0x518A0', '0x518A4', '0x518A8']
            assert change['guardforce_write_enabled'] is False
            assert change['guardforce_changed'] == 'none'
            assert change['illuminate_guardforce_multiplier'] == 1.0
            assert change['interval_mode'] == 'fixed'
            assert change['fixed_interval_min'] == 0.0
            assert change['fixed_interval_max'] == 0.1
            assert change['allow_zero_interval_min'] is True
            assert change['group_multiplier'] == 10
        else:
            assert change['budget_multiplier'] == 6
            assert change['budget_override_multiplier'] == 6
            assert change['encounter_deadline_enabled'] is False
            assert change['traveler_cooldown_enabled'] is False
            assert change['modifier_scale_enabled'] is False
            assert change['probe_timers_enabled'] is False
            assert change['guardforce_write_enabled'] is True
            assert change['guardforce_changed'] == 'illuminate_only'
            assert change['illuminate_guardforce_multiplier'] == 0.25
            assert change['interval_mode'] == 'divide'
            assert change['interval_divisor'] == 10
            assert change['group_multiplier'] == 10
        assert provenance['requires'] == [{'name': 'Bingus Shared Loader',
                                           'guid': '612eaf70-d682-43c7-9efd-16dcc695f977',
                                           'api': 1, 'minimum_version': 15}]
        assert provenance['loader_integration'] == {
            'minimum_loader_version': 15,
            'api': 1,
            'discovery_entry': 'mods/cowboybingus/enemy_spawn_multiplier',
            'implementation_resource': 'mods/cowboybingus/enemy_spawn_multiplier_impl',
            'legacy_registry_compatible': True,
        }
        for name, digest in provenance['files'].items():
            assert hashlib.sha256(payloads[name]).hexdigest().upper() == digest
        main_archive = payloads['data/' + archive_name]
        assert struct.unpack_from('<III', main_archive) == (0xF0000011, 1, 2)
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
        from archive import resource_hash
        entry_name = 'mods/cowboybingus/enemy_spawn_multiplier'
        implementation_name = entry_name + '_impl'
        entries = [struct.unpack_from('<7Q6I', main_archive, 104 + index * 80) for index in range(2)]
        assert {entry[0] for entry in entries} == {resource_hash(entry_name), resource_hash(implementation_name)}
        resources = {}
        for index, entry in enumerate(entries):
            assert entry[1] == 0xA14E8DFA2CD117E2 and entry[-1] == index
            offset, size = entry[2], entry[7]
            assert offset % 16 == 0 and offset + size <= len(main_archive)
            assert struct.unpack_from('<II', main_archive, offset) == (size - 8, 2)
            resources[entry[0]] = main_archive[offset + 8:offset + size]
        declaration = ('-- HD2-Addon: ' + entry_name + '\n').encode('ascii')
        expected_entry = declaration + ("return require('" + implementation_name + "')\n").encode('ascii')
        assert resources[resource_hash(entry_name)] == expected_entry
        assert resources[resource_hash(entry_name)].startswith(declaration)
        assert len(declaration) <= 256 and not resources[resource_hash(entry_name)].startswith(b'\xef\xbb\xbf')
        assert not resources[resource_hash(entry_name)].startswith(b'\x1bLJ')
        assert resources[resource_hash(implementation_name)].startswith(b'\x1bLJ\x02\x02')
        assert payloads['data/' + archive_name + '.stream'] == b''
        assert payloads['data/' + archive_name + '.gpu_resources'] == b''
        assert b'virtualprotect' not in main_archive.lower()
        assert b'flushinstructioncache' not in main_archive.lower()
        for data in payloads.values():
            lowered = data.lower()
            assert b'users\\' not in lowered and b'users/' not in lowered
            assert b'asset-key' not in lowered and b'hd2_native_stick.dll' not in lowered
            assert b'virtualprotect' not in lowered and b'flushinstructioncache' not in lowered
            assert b'createremotethread' not in lowered and b'loadlibrary' not in lowered
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / 'An unrelated install location'
            package.extractall(destination)
            assert all((destination / name).read_bytes() == data for name, data in payloads.items())
    print('PASS: archive contents, V1 manager manifest, hashes, resource identity, privacy and relocation')
    print('PASS: official loader v15 declaration is plaintext, first, hash-matched and forwards to bytecode')
    print('7 package checks passed; ZIP contains three runtime archive files and no custom DLL.')


if __name__ == '__main__':
    main()
