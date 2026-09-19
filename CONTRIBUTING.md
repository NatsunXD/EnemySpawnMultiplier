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

The builder verifies the supported EXE and game.dll hashes, compiles both Lua variants, runs synthetic memory checks, and inspects each archive in Python. It writes `releases/Enemy-Spawn-Multiplier-6x-Native-Composition-v14.zip` and `releases/Enemy-Spawn-Multiplier-6x-Light-Medium-Bias-v14.zip`. Pass `base` or `light-medium` to build only one variant. It does not install or launch the game.

This package requires Bingus Shared Loader with `mods/cowboybingus/enemy_spawn_multiplier` in the coordinator list.
