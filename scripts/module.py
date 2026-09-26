"""Compile one independently installed gameplay module."""
import os
import struct
import subprocess
from archive import LUA, EXE_SHA, GAME_DLL_SHA, resource_hash


def lua_literal(value):
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, str):
        return "'" + value.replace('\\', '\\\\').replace("'", "\\'") + "'"
    if isinstance(value, (int, float)):
        return repr(value)
    raise TypeError(f'Unsupported Lua override type: {type(value).__name__}')


def build_module(root, build, module_name, patch_name, revision, template_bias=False, overrides=None,
                 with_panel=False):
    build.mkdir(parents=True, exist_ok=True)
    module = ''
    # The configuration panel is opt-in. Variants that never scale the patrol
    # curves would otherwise open a panel showing invented 0.1x values, and
    # pressing Apply would switch curve scaling on for a profile that
    # deliberately leaves those fields native.
    # anchor_check is part of the base module: it replaces the build-hash gate for
    # every variant, panel or not.
    source_pairs = [('create_api', 'windows_api.lua'), ('patch', patch_name)]
    if with_panel:
        # Persistence ships with the panel: config_store backs the sliders with a
        # local file so a committed profile survives a restart. diag_export powers
        # the Desktop diagnostic pack button (and is also used by the companion bat).
        source_pairs += [('create_panel', 'panel.lua'), ('create_model', 'panel_model.lua'),
                         ('create_bindings', 'bindings.lua'), ('create_store', 'config_store.lua'),
                         ('create_diag', 'diag_export.lua')]
        # Fast corpse decay ships with the panel, which carries its switch.
        source_pairs += [('corpse_data', 'corpse_data.lua'),
                         ('corpse_decayer_data', 'corpse_decayer_data.lua'),
                         ('create_corpse', 'corpse_clear.lua')]
    source_pairs += [('create_anchors', 'anchor_check.lua'),
                     ('install_loader', 'archive_loader.lua')]
    if not with_panel:
        module += 'local create_panel, create_model, create_bindings, create_store, create_diag = nil, nil, nil, nil, nil\n'
        module += 'local corpse_data, corpse_decayer_data, create_corpse = nil, nil, nil\n'
    for variable, filename in source_pairs:
        code = (root / 'src' / filename).read_text(encoding='utf-8')
        # VirtualProtect is allowed only in the memory-API module, which uses it
        # to toggle MEM_PRIVATE, non-executable data pages for the corpse-decay
        # snapshot and always restores the previous protection. Every other
        # native-modification API stays banned everywhere, and VirtualProtect
        # stays banned in every other source file.
        forbidden = ['FlushInstructionCache', 'CreateRemoteThread', 'LoadLibrary']
        if filename != 'windows_api.lua':
            forbidden.append('VirtualProtect')
        for banned in forbidden:
            if banned in code:
                raise ValueError(f'Unsupported native modification API in {filename}: {banned}')
        module += f'local {variable} = (function()\n{code}\nend)()\n'
        if variable == 'patch':
            if template_bias:
                module += 'patch.template_bias_enabled = true\n'
            for key in sorted((overrides or {}).keys()):
                module += f'patch.{key} = {lua_literal(overrides[key])}\n'
    module += ("local create_corpse_bound = function(api)\n"
               "    if not create_corpse or not corpse_data then return nil, 'corpse module absent' end\n"
               "    return create_corpse(api, corpse_data, corpse_decayer_data)\n"
               "end\n")
    module += f"install_loader(create_api, patch, {{revision = '{revision}', "
    module += f"exe_sha256 = '{EXE_SHA}', game_sha256 = '{GAME_DLL_SHA}'" + '}, create_panel, create_model, create_bindings, create_anchors, create_store, create_diag, create_corpse_bound)\n'
    path, output = build / 'mod.wrapper.lua', build / 'mod.ljbc'
    path.write_text(module, encoding='utf-8', newline='\n')
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    subprocess.run([str(LUA), '-bsdW', str(path), str(output)], env=env, check=True)
    bytecode = output.read_bytes()
    if bytecode[:5] != b'\x1bLJ\x02\x02':
        raise ValueError('LuaJIT bytecode mode differs from the game')
    implementation_name = module_name + '_impl'
    entry = (f'-- HD2-Addon: {module_name}\n'
             f"return require('{implementation_name}')\n").encode('ascii')
    entry_resource = struct.pack('<II', len(entry), 2) + entry
    implementation_resource = struct.pack('<II', len(bytecode), 2) + bytecode
    (build / 'entry.lua').write_bytes(entry)
    (build / 'entry.lua.main').write_bytes(entry_resource)
    (build / 'mod.lua.main').write_bytes(implementation_resource)
    return {
        resource_hash(module_name): entry_resource,
        resource_hash(implementation_name): implementation_resource,
    }
