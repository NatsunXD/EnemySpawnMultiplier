"""Compile one independently installed gameplay module."""
import os
import struct
import subprocess
from archive import LUA, EXE_SHA, GAME_DLL_SHA, resource_hash


def build_module(root, build, module_name, patch_name, revision, template_bias=False):
    build.mkdir(parents=True, exist_ok=True)
    module = ''
    for variable, filename in [('create_api', 'windows_api.lua'), ('patch', patch_name),
                               ('install_loader', 'archive_loader.lua')]:
        code = (root / 'src' / filename).read_text(encoding='utf-8')
        for forbidden in ('VirtualProtect', 'FlushInstructionCache', 'CreateRemoteThread', 'LoadLibrary'):
            if forbidden in code:
                raise ValueError(f'Unsupported native modification API in {filename}: {forbidden}')
        module += f'local {variable} = (function()\n{code}\nend)()\n'
        if variable == 'patch' and template_bias:
            module += 'patch.template_bias_enabled = true\n'
    module += f"install_loader(create_api, patch, {{revision = '{revision}', "
    module += f"exe_sha256 = '{EXE_SHA}', game_sha256 = '{GAME_DLL_SHA}'" + '})\n'
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
