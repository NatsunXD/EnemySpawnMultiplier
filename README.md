# Enemy Spawn Multiplier

## 中文说明

v13 适用于 Steam build `24826606` / EXE `1.8.45317.0`，提供两个可选版本：

- `Native Composition`：保留游戏原本的敌人模板权重。
- `Light-Medium Bias`：偏向单位平均点数较低的模板。

两个版本使用相同资源 ID，只能选择其中一个安装。

### 改动

- 增援预算覆盖值为当前缩放预算的 6 倍。
- 所有非零单类刷怪上限改为原来的 5 倍。
- 巡逻队和 Straggler 时间间隔改为原本的 1/5，最低保留 0.2 秒。
- 巡逻队的组数量限制改为原来的 5 倍。
- Encounter 期望数量改为原来的 2 倍，最高 95。
- 轻中甲版按“模板点数 / 计划单位数”排序：较轻的 50% 权重 3.6 倍，中间 30% 权重 1.25 倍，较重的 20% 权重 0.25 倍。

模组只修改私有可写数据，不修改游戏代码页。原生人口门槛、出生点检查、模板可用性和生成队列仍然生效。轻中甲分类采用单位平均点数，是跨阵营的相对偏向，不是硬编码装甲标签。

### 安装

1. 关闭游戏。
2. 在 HDArsenal 或 HD2MM 中导入 `Enemy-Spawn-Multiplier-6x-Native-Composition-v13.zip` 或 `Enemy-Spawn-Multiplier-6x-Light-Medium-Bias-v13.zip`，二选一。
3. 启用已经加入本模块注册项的 [BingusSharedLoader](https://github.com/NatsunXD/BingusSharedLoader)。
4. 删除旧版 Enemy Spawn Multiplier 条目，重新部署。
5. 重启游戏后再测试，避免沿用旧进程中的内存修改。

两个版本均通过 21 项数据和内存行为测试，以及 6 项归档和打包测试。实战结果仍会受难度、种族、地图和多人房间影响。

[技术说明](docs/TECHNICAL.md) | [构建说明](CONTRIBUTING.md) | [安装说明](INSTALL.txt)

<details>
<summary>English</summary>

v13 targets Steam build `24826606` / EXE `1.8.45317.0` and provides two mutually exclusive packages:

- `Native Composition` keeps native Encounter template weights.
- `Light-Medium Bias` favors templates with lower cost per planned unit.

Both variants use the native positive Encounter budget override at 6x, scale non-zero per-type caps and the Patrol group clamp by 5x, divide Patrol and Straggler intervals by 5, and scale the Encounter desired target by 2x with a cap of 95.

The biased variant ranks the current faction and difficulty candidate pool by cost per planned unit. The lower 50% receives a 3.6x weight, the middle 30% receives 1.25x, and the highest-cost 20% receives 0.25x. This is a relative cross-faction preference rather than an armor-tag lookup.

The mod changes writable private data only. It does not modify executable pages. Native population gates, spawn-position checks, template availability, and queue processing remain active.

Install either `Enemy-Spawn-Multiplier-6x-Native-Composition-v13.zip` or `Enemy-Spawn-Multiplier-6x-Light-Medium-Bias-v13.zip` with [NatsunXD BingusSharedLoader](https://github.com/NatsunXD/BingusSharedLoader), then remove older Enemy Spawn Multiplier entries, deploy, and restart the game.

Both variants pass 21 data and memory behavior checks plus 6 archive and package checks.

[Technical walkthrough](docs/TECHNICAL.md) | [Build instructions](CONTRIBUTING.md) | [Installation](INSTALL.txt)

</details>
