# Enemy Spawn Multiplier

## 中文说明

v9版本，适用于 Steam build `24826606` / EXE `1.8.45317.0`。

本 MOD 更改了刷怪配置。把预算和部分刷怪上限放大，让一轮拉烟能持续更久，巡逻队也能更快重新刷新。

### 改动

- 增援预算改为原来的 6 倍。
- 所有单类刷怪上限改为原来的 5 倍。
- 巡逻队时间间隔改为原本1/5，最低保留 0.2 秒。
- 巡逻队的组数量限制改为原来的 5 倍。
- 关闭提前结束刷怪的判断

游戏仍然会检查出生点、模板是否可用和每种敌人的刷怪点数。守卫、巡逻队和拉烟并不是无条件生成，地图位置、敌人模板和游戏本身的选择逻辑仍然生效。


### 安装

1. 关闭游戏。
2. 在 HDArsenal 或 HD2MM 中导入 `Enemy-Spawn-Multiplier-6x.zip`。
3. 启用已经加入本模块注册项的 [BingusSharedLoader](https://github.com/NatsunXD/BingusSharedLoader)。
4. 删除旧版 Enemy Spawn Multiplier 条目，重新部署。
5. 重启游戏后再测试，避免沿用旧进程里的内存修改。

这套改动已经通过 21 项数据和内存行为测试，以及 6 项归档和打包测试。测试不能代替实战结果；不同难度、种族、地图和多人房间仍可能让拉烟和巡逻队的体感不同。

[技术说明](docs/TECHNICAL.md) | [构建说明](CONTRIBUTING.md) | [安装说明](INSTALL.txt)

<details>
<summary>English</summary>

This is data-v9 for Steam build `24826606` / EXE `1.8.45317.0`.

The mod changes the director's spawn configuration. The Encounter budget controls how many spawn points a reinforcement call can spend, while Patrol and Straggler intervals control later group rolls. This version increases the budget and selected population caps, so a reinforcement call can last longer and patrol groups can roll again sooner.

Changes:

- Encounter base budget: 6x.
- Non-zero per-type spawn caps: 5x.
- Patrol and Straggler intervals: divided by 5, with a 0.2 second minimum.
- Patrol group-size clamp: 5x.
- Disabled four confirmed early exits: effective count 70, component count 448, desired reached, and combined demand 100.

Spawn positions, template availability and per-enemy spawn costs remain part of the native selection logic. The mod does not directly edit pending queue quantities, queue accounting, native timestamps or the ProducedFighter counter. Read-only private config tables are cloned into writable memory before the active row is changed.

Install `Enemy-Spawn-Multiplier-6x-v9.zip` with the [NatsunXD BingusSharedLoader](https://github.com/NatsunXD/BingusSharedLoader) through HDArsenal or HD2MM, remove older Enemy Spawn Multiplier entries, deploy, and restart the game before testing.

Check `%LOCALAPPDATA%/EnemySpawnMultiplier.log` after entering a mission. `data-v9` is the revision, `spawn_multiplier_ready` confirms the active config was written, `spawn_multiplier_partial` records a delayed or failed config lookup, `i=` lists Straggler and Patrol intervals, `g=` is the Patrol group clamp, `d=` is the unchanged desired target, `l=off` confirms the four early exits are disabled, `cfg=` records the config source, `t=0` confirms that native timestamps were left alone, and `x=` is the native ProducedFighter count rather than a population cap.

The build passed 21 data and memory behavior checks plus 6 archive and package checks. In-game results can still vary with difficulty, faction, map and multiplayer state.

[Technical walkthrough](docs/TECHNICAL.md) | [Build instructions](CONTRIBUTING.md) | [Installation](INSTALL.txt)

</details>
