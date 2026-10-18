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
        expected_revisions = {
            'data-v23-native', 'data-v23-light-medium', 'data-v23-fast-cadence',
            'data-v23-preview-patrol-2x-3x', 'data-v24-progression-only-panel-menus',
            'data-v24-local-h100-test',
            'data-v24-h100-3samples-quantity10pct-20s',
            'data-v24-spawn-guard-s70-h130',
            'data-v24-spawn-guard-s70-h150',
            'data-v24-spawn-guard-s70-h170',
            'data-v24-spawn-guard-s70-h200',
            'data-v24-spawn-guard-s70-float',
            'data-v24-spawn-guard-privacy-solo',
        }
        panel_like = ('data-v24-progression-only-panel-menus', 'data-v24-local-h100-test',
                      'data-v24-h100-3samples-quantity10pct-20s', 'data-v24-spawn-guard-s70-h130',
                      'data-v24-spawn-guard-s70-h150', 'data-v24-spawn-guard-s70-h170',
                      'data-v24-spawn-guard-s70-h200', 'data-v24-spawn-guard-s70-float',
                      'data-v24-spawn-guard-privacy-solo')
        assert provenance['revision'] in expected_revisions
        assert provenance['display_version'] == 'v24'
        suffix=provenance.get('release_suffix')
        expected_suffix = {
            'data-v24-h100-3samples-quantity10pct-20s': 'H100-3Samples-10Pct-20s',
            'data-v24-spawn-guard-s70-h130': 'SpawnGuard-S70-H130',
            'data-v24-spawn-guard-s70-h150': 'SpawnGuard-S70-H150',
            'data-v24-spawn-guard-s70-h170': 'SpawnGuard-S70-H170',
            'data-v24-spawn-guard-s70-h200': 'SpawnGuard-S70-H200',
            'data-v24-spawn-guard-s70-float': 'SpawnGuard-S70-Float',
            'data-v24-spawn-guard-privacy-solo': 'SpawnGuard-PrivacySolo',
        }.get(provenance['revision'])
        assert suffix == expected_suffix
        assert Path(sys.argv[1]).name == provenance['name'].replace(' ', '-') + '-v24' + ('-'+suffix if suffix else '') + '.zip'
        assert provenance['runtime_verified'] is False
        if provenance['revision'] in panel_like:
            dynamic=provenance['data_change']['dynamic_spawn']
            spawn_guard=provenance['revision'] in ('data-v24-spawn-guard-s70-h130',
                                                    'data-v24-spawn-guard-s70-h150',
                                                    'data-v24-spawn-guard-s70-h170',
                                                    'data-v24-spawn-guard-s70-h200',
                                                    'data-v24-spawn-guard-s70-float',
                                                    'data-v24-spawn-guard-privacy-solo')
            spawn_guard_h150=provenance['revision']=='data-v24-spawn-guard-s70-h150'
            spawn_guard_h170=provenance['revision']=='data-v24-spawn-guard-s70-h170'
            spawn_guard_h200=provenance['revision']=='data-v24-spawn-guard-s70-h200'
            spawn_guard_float=provenance['revision'] in ('data-v24-spawn-guard-s70-float',
                                                         'data-v24-spawn-guard-privacy-solo')
            combined=provenance['revision'] in ('data-v24-h100-3samples-quantity10pct-20s',
                                                 'data-v24-spawn-guard-s70-h130',
                                                 'data-v24-spawn-guard-s70-h150',
                                                 'data-v24-spawn-guard-s70-h170',
                                                 'data-v24-spawn-guard-s70-h200',
                                                 'data-v24-spawn-guard-s70-float',
                                                 'data-v24-spawn-guard-privacy-solo')
            local_test=provenance['revision'] in ('data-v24-local-h100-test',
                                                   'data-v24-h100-3samples-quantity10pct-20s',
                                                   'data-v24-spawn-guard-s70-h130',
                                                   'data-v24-spawn-guard-s70-h150',
                                                   'data-v24-spawn-guard-s70-h170',
                                                   'data-v24-spawn-guard-s70-h200',
                                                   'data-v24-spawn-guard-s70-float',
                                                   'data-v24-spawn-guard-privacy-solo')
            assert dynamic['default_enabled']
            if local_test:
                assert len(manifest['Description'])<150
                expected_mode = 'spawn_guard' if spawn_guard else ('h100_compensation' if combined else 'local_h100_test')
                assert dynamic['mode']==expected_mode and dynamic['sample_seconds']==1
                assert dynamic['pressure_feedback_enabled']
                assert dynamic['s70_control_enabled'] is spawn_guard
                assert dynamic['diagnostics']==['S70','H100']
                assert dynamic['confirmation_samples']==3
                if combined:
                    if spawn_guard_float: h_trig = 200
                    elif spawn_guard_h200: h_trig = 200
                    elif spawn_guard_h170: h_trig = 170
                    elif spawn_guard_h150: h_trig = 150
                    elif spawn_guard: h_trig = 130
                    else: h_trig = 100
                    assert dynamic['threshold_gt']==h_trig and not dynamic['immediate_trigger_enabled']
                    assert 'immediate_gt' not in dynamic
                    assert dynamic['hold_seconds']==0 and dynamic['recovery_seconds']==20 and dynamic['duration_seconds']==20
                    assert dynamic['rate_hold_seconds']==6 and dynamic['rate_recovery_seconds']==4 and dynamic['rate_duration_seconds']==10
                    if spawn_guard_float: keep = 0.80
                    elif spawn_guard_h200: keep = 0.75
                    elif spawn_guard_h170: keep = 0.55
                    elif spawn_guard_h150: keep = 0.40
                    elif spawn_guard: keep = 0.25
                    else: keep = 0.1
                    assert dynamic['patrol_count_bonus_retained']==keep and dynamic['patrol_size_bonus_retained']==keep
                    if spawn_guard_float: rate_f = 0.92
                    elif spawn_guard_h200: rate_f = 0.95
                    elif spawn_guard_h170: rate_f = 0.90
                    elif spawn_guard_h150: rate_f = 0.85
                    elif spawn_guard: rate_f = 0.80
                    else: rate_f = 0.75
                    assert dynamic['patrol_rate_factor']==rate_f
                    assert dynamic['retrigger']=='same_threshold_refreshes_quantity_20s_and_rate_10s'
                    assert dynamic['sub_one_quantities']=='unchanged'
                    assert dynamic['recovery_interpolation']=='linear_to_latest_applied_user_settings'
                    if spawn_guard:
                        if spawn_guard_float:
                            soft, soft_rate, spacing, release, confirm, hard = 64, 0.82, 0.5, 68, 2, 78
                        elif spawn_guard_h200:
                            soft, soft_rate, spacing, release, confirm, hard = 62, 1.0, 0.75, 58, 3, 65
                        elif spawn_guard_h170:
                            soft, soft_rate, spacing, release, confirm, hard = 58, 0.95, 1, 50, 2, 65
                        elif spawn_guard_h150:
                            soft, soft_rate, spacing, release, confirm, hard = 55, 0.90, 1, 50, 2, 65
                        else:
                            soft, soft_rate, spacing, release, confirm, hard = 50, 0.85, 2, 50, 2, 65
                        assert dynamic['s70_soft']==soft and dynamic['s70_hard']==hard and dynamic['s70_release']==release
                        assert dynamic['s70_confirm_samples']==confirm
                        assert dynamic['s70_soft_rate']==soft_rate
                        assert dynamic['request_spacing_seconds']==spacing and dynamic['request_spacing_always_on'] is True
                        if spawn_guard_float:
                            assert dynamic['s70_float_hi']==74
                            assert dynamic['s70_float_count_min']==0.50 and dynamic['s70_float_size_min']==0.32
                            assert 's70_soft_keep' not in dynamic and 's70_soft_keep_count' not in dynamic
                        elif spawn_guard_h200:
                            assert dynamic['s70_soft_keep_count']==0.95 and dynamic['s70_soft_keep_size']==0.60
                            assert 's70_soft_keep' not in dynamic
                        elif spawn_guard_h170:
                            assert dynamic['s70_soft_keep_count']==0.80 and dynamic['s70_soft_keep_size']==0.40
                            assert 's70_soft_keep' not in dynamic
                        else:
                            soft_keep = 0.55 if spawn_guard_h150 else 0.40
                            assert dynamic['s70_soft_keep']==soft_keep
                else:
                    assert dynamic['threshold_gt']==95 and dynamic['immediate_gt']==100
                    assert dynamic['hold_seconds']==10
                    assert dynamic['patrol_count']==1 and dynamic['patrol_size']==1
                    assert dynamic['patrol_rate_factor']==0.5
                if spawn_guard:
                    assert dynamic['switch']=='spawn_guard_mission_gate_soft_spacing'
                else:
                    assert dynamic['switch']==('soft_limit_and_progression_and_extraction' if combined else 'soft_limit_only')
                assert dynamic['progression']==('all_13_blocks_exact_1' if combined else 'always_initial_tier')
                if combined:
                    assert dynamic['progression_floats']==65 and dynamic['progression_zero_policy']=='set_to_1'
                    assert dynamic['extraction_bonus_factor']==0.5
                    assert dynamic['extraction_available_offsets']==[hex(0x128+i*60+36) for i in range(13)]
                    assert dynamic['extraction_distance_blocks']==['0x104','0x110','0x11C']
                    assert dynamic['extraction_patrol_distance_rate_range']==[1.0,1.2]
                    assert dynamic['extraction_patrol_distance_endpoint_offsets']==['0x11C','0x120']
            else:
                assert dynamic['mode']=='progression_only'
                assert not dynamic['pressure_feedback_enabled'] and dynamic['sample_seconds'] is None
                assert dynamic['patrol_multipliers']=='user_requested' and dynamic['progression']=='initial_tier'
            assert dynamic['background_only'] and not dynamic['pressure_counter_writes']
            budget=provenance['performance_budget']
            assert budget['pressure_reads_per_second']==(17 if local_test else 0)
            assert budget['pressure_bytes_per_second']==(104 if local_test else 0)
            assert budget['pressure_region_queries_per_second_max']==(17 if local_test else 0)
            assert budget['log_queue_bytes']==16384 and budget['log_queue_lines']==32
            assert budget['log_flush_seconds']==5 and budget['blackbox_summary_seconds']==30
            assert budget['clone_retention_bytes']==8388608 and budget['runtime_verified'] is False
        if provenance['revision'] in panel_like:
            assert provenance['shared_configuration'] == {
                'f8': True, 'mods_menu_optional': True, 'languages': ['zh', 'en'],
                'canonical_store': 'EnemySpawnMultiplier.cfg', 'mods_apply_batched': True,
                'runtime_dependency': False,
            }
            menu_dependency = next(d for d in provenance['optional_requires'] if d['name'] == 'Mod Options Menu')
            assert menu_dependency['minimum_version'] == '1.1' and menu_dependency['bingus_minimum_version'] == 18
        change = provenance.get('data_change')
        assert change is not None
        if provenance['revision'] in ('data-v23-fast-cadence', 'data-v23-preview-patrol-2x-3x',
                                      *panel_like):
            expected_patrol_count, expected_travelers_max_unit = (6.0, 6.0)
            if provenance['revision'] == 'data-v23-preview-patrol-2x-3x':
                expected_patrol_count, expected_travelers_max_unit = 2.0, 3.0
            elif provenance['revision'] in panel_like:
                expected_patrol_count = 1.0
                expected_travelers_max_unit = 1.0
            expected_budget = 2.0 if provenance['revision'] in panel_like else 0.4
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
            expected_patrol_cd = 6.0 if provenance['revision'] in panel_like else 3.0
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
            'discovery_entry': 'mods/natsun/enemy_spawn_multiplier',
            'implementation_resource': 'mods/natsun/enemy_spawn_multiplier_impl',
            'legacy_registry_compatible': False,
        }
        for name, digest in provenance['files'].items():
            assert hashlib.sha256(payloads[name]).hexdigest().upper() == digest
        main_archive = payloads['data/' + archive_name]
        assert struct.unpack_from('<III', main_archive) == (0xF0000011, 1, 2)
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
        from archive import resource_hash
        entry_name = 'mods/natsun/enemy_spawn_multiplier'
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
        # VirtualProtect is permitted for one narrow purpose: toggling a
        # MEM_PRIVATE, non-executable data page for the corpse-decay snapshot and
        # restoring it. The build-time guard in scripts/module.py enforces that it
        # can only appear in windows_api.lua; every other native-modification API
        # stays banned outright.
        assert b'flushinstructioncache' not in main_archive.lower()
        for data in payloads.values():
            lowered = data.lower()
            assert b'users\\' not in lowered and b'users/' not in lowered
            assert b'asset-key' not in lowered and b'hd2_native_stick.dll' not in lowered
            assert b'flushinstructioncache' not in lowered
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
