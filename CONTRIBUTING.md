# Build from source

Windows x64, Python 3.10+, Git, and MinGW gcc. Fetch LuaJIT with `python -B scripts/bootstrap_dependencies.py` if `tools/src/LuaJIT` is missing, then from `tools/src/LuaJIT/src`:

```bat
mingw32-make XCFLAGS="-DLUAJIT_DISABLE_GC64"
```

Put Git `usr\bin` on PATH so `uname`, `sed` and `[` exist. Set `HD2_GAME_ROOT` if needed, then from the repository root:

```powershell
$env:HD2_LUAJIT = (Resolve-Path 'tools/src/LuaJIT/src/luajit.exe').Path
$env:HD2_GAME_ROOT = 'D:\SteamLibrary\steamapps\common\Helldivers 2'
python -B scripts/build.py
```

The builder verifies the supported EXE and game.dll hashes, compiles all configured Lua variants, runs synthetic memory checks, and inspects each archive in Python. It writes `releases/Enemy-Spawn-Multiplier-6x-Native-Composition-v20.zip`, `releases/Enemy-Spawn-Multiplier-6x-Light-Medium-Bias-v20.zip`, and `releases/Enemy-Spawn-Multiplier-Fast-Cadence-v20.zip`. Pass `base`, `light-medium`, `fast-cadence`, `panel`, or `preview-patrol-2x-3x` to build only
one variant. `panel` adds the in-game F8 configuration overlay
(`releases/Enemy-Spawn-Multiplier-Panel-v20.zip`); `preview-patrol-2x-3x` is the local
`2x` patrol count / `3x` patrol squad preview. The builder does not install or launch the game.

This package requires the official Bingus Shared Loader v15 or newer. The archive exposes a plaintext `mods/cowboybingus/enemy_spawn_multiplier` discovery entry and keeps the compiled implementation in `mods/cowboybingus/enemy_spawn_multiplier_impl`. The v15 loader discovers the entry without a coordinator-list edit; the stable entry name also remains compatible with legacy explicit registration.
