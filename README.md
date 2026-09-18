# Enemy Spawn Multiplier 6x

## 中文说明

这是 **data-v9 / 6 倍遭遇刷怪增强版**，适用于 Steam build **24826606** / EXE **1.8.45317.0**。

本 MOD 需要 Bingus Shared Loader，并要求 Loader 注册以下资源：

`mods/cowboybingus/enemy_spawn_multiplier`

### 功能

- 遭遇基础组合预算提高为原来的 6 倍。
- 非零的每类敌人上限提高为原来的 5 倍。
- Patrol 和 Straggler 的间隔缩短为原来的五分之一，最短 0.2 秒。
- 巡逻组数量限制提高为原来的 5 倍。
- 移除四个已确认的人口提前退出条件：有效数量 70、组件数量 448、达到期望数量、合计需求 100。
- 保留位置查询、模板可用性和敌人点数等原生选择条件。

本版本不会直接修改待生成队列数量、队列记账计数、原生时间戳或 ProducedFighter 计数。配置表如果位于只读私有内存，会先复制到可写内存再修改。

### 安装

1. 关闭游戏。
2. 在 HDArsenal 或 HD2MM 中导入 `Enemy-Spawn-Multiplier-6x-v9.zip`。
3. 同时启用 `Bingus-Shared-Loader-v12.zip`，并让 Loader 按其安装说明获得启动资源优先级。
4. 删除或替换旧版 Enemy Spawn Multiplier 条目，然后重新部署。
5. 重新启动游戏，确保旧进程中的内存修改已经清除。

### 日志

进入任务后查看 `%LOCALAPPDATA%/EnemySpawnMultiplier.log`：

- `data-v9`：当前数据版本。
- `spawn_multiplier_ready`：活动配置已解析、校验并完成缩放。
- `spawn_multiplier_partial`：预算或上限已应用，但活动配置尚未解析；`cfg=` 会记录原因，后续初始化仍会重试。
- `i=`：先显示 Straggler、再显示 Patrol 的间隔；`g=`：巡逻组数量限制。
- `d=`：未修改的活动期望数量；`l=off`：四个提前退出分支已禁用。
- `cfg=director:...` 或 `cfg=resource:...`：配置来源、索引和地址。
- `t=0`：没有直接修改原生时间戳，属于预期结果。
- `x=`：原生 ProducedFighter 计数，不是配置的人口上限。

### 验证范围

构建包含 21 项数据和内存行为测试，以及 6 项归档和发布包测试。离线测试不能替代实际任务中的刷怪量、多玩家同步和不同种族任务验证。

[技术说明](docs/TECHNICAL.md) | [构建说明](CONTRIBUTING.md) | [安装说明](INSTALL.txt)

<details>
<summary>English</summary>

This is **data-v9**, for Steam build **24826606** / EXE **1.8.45317.0**. It requires Bingus Shared Loader with the `mods/cowboybingus/enemy_spawn_multiplier` resource registered.

This build multiplies the Encounter base composition budget by six and nonzero per-type caps by five. For the active spawn config, it divides Patrol and Straggler intervals by five (minimum 0.2 seconds) and multiplies the group-size clamp by five. It removes four confirmed population early exits: effective count 70, component count 448, desired reached, and combined demand 100.

It resolves the active handle through the native director hash table and the resource-key fallback. When the resource fallback points at a read-only private table, it clones the full table into private writable memory and retargets the manager's table pointer before editing the selected row. Pending queue quantities, the queue accounting counter at `director+0x36C0`, native timestamps and the ProducedFighter counter at `director+0x620` remain read-only. Position queries, template availability and candidate costs still apply. Gameplay verification remains pending.

Install `Enemy-Spawn-Multiplier-6x-v9.zip` with `Bingus-Shared-Loader-v12.zip` through HDArsenal or HD2MM, replace older Enemy Spawn Multiplier entries, deploy, and restart the game before testing.

After entering a mission, check `%LOCALAPPDATA%/EnemySpawnMultiplier.log` for `data-v9`, `spawn_multiplier_ready`, `spawn_multiplier_partial`, interval fields `i=`, group clamp `g=`, unchanged desired target `d=`, disabled population exits `l=off`, and configuration source `cfg=`. `t=0` is expected because native timestamps are not edited; `x=` is the native ProducedFighter count, not a configured population limit.

[Technical walkthrough](docs/TECHNICAL.md) | [Build instructions](CONTRIBUTING.md) | [Installation](INSTALL.txt)

</details>
