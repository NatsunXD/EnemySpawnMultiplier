# Enemy Spawn Multiplier 6x

## 中文说明

这是 data-v9，适用于 Steam build `24826606` / EXE `1.8.45317.0`。

这个 MOD 调的是游戏导演的刷怪配置。简单说，Encounter 预算决定一轮拉烟能花掉多少刷怪点数；巡逻队和 Straggler 则按各自的间隔继续抽取队伍。这个版本把预算和部分刷怪上限放大，所以一轮拉烟能持续更久，巡逻队也能更快重新出现。

### 改了什么

- Encounter 基础预算改为原来的 6 倍。
- 所有原本大于零的单类刷怪上限改为原来的 5 倍。
- 巡逻队和 Straggler 的间隔除以 5，最低保留 0.2 秒。
- 巡逻队的组数量限制改为原来的 5 倍。
- 关闭四个会提前结束刷怪的判断：有效数量 70、组件数量 448、达到期望数量，以及合计需求 100。

游戏仍然会检查出生点、模板是否可用和每种敌人的刷怪点数。守卫、巡逻队和拉烟并不是无条件生成，地图位置、敌人模板和游戏本身的选择逻辑仍然生效。

MOD 不直接改待生成队列、队列记账、原生时间戳或 ProducedFighter 计数。配置表如果落在只读的私有内存里，会先复制到可写区域，再修改活动配置。这样做是为了让游戏继续使用自己的队列和计数。

### 安装

1. 关闭游戏。
2. 在 HDArsenal 或 HD2MM 中导入 `Enemy-Spawn-Multiplier-6x-v9.zip`。
3. 启用已经加入本模块注册项的 [BingusSharedLoader](https://github.com/NatsunXD/BingusSharedLoader)。
4. 删除旧版 Enemy Spawn Multiplier 条目，重新部署。
5. 重启游戏后再测试，避免沿用旧进程里的内存修改。

### 看日志

进入任务后查看 `%LOCALAPPDATA%/EnemySpawnMultiplier.log`。

- `data-v9` 是版本标记。
- `spawn_multiplier_ready` 表示活动配置已经找到、校验并写入。
- `spawn_multiplier_partial` 表示预算或刷怪上限已经写入，但活动配置还没解析成功；`cfg=` 会给出原因，后续会继续重试。
- `i=` 依次记录 Straggler 和巡逻队间隔，`g=` 是巡逻队组数量限制。
- `d=` 是游戏原本的期望数量，MOD 不改它。
- `l=off` 表示上面提到的四个提前结束判断已关闭。
- `cfg=director:...` 或 `cfg=resource:...` 记录配置的来源、索引和地址。
- `t=0` 表示没有直接改原生时间戳，这是预期结果。
- `x=` 是游戏自己的 ProducedFighter 计数，不是刷怪上限。

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
