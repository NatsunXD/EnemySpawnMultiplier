# Enemy Spawn Multiplier

## 中文说明

这是一个用于调整《绝地潜兵 2》敌人生成参数的模组。目前只维护 Panel 版本。

Panel 版本按 F8 打开配置面板，可调整增援预算、巡逻数量、巡逻规模以及增援和巡逻冷却。

面板默认开启“尸体快速消失”：每 0.5 秒检查一次实体数据，先尝试固定锚点，失效时自动按 `DecaySettings` 与 `CorpseDecayerComponent` 的完整字段签名扫描：仅将 `DeathDecayMode_Regular` 的 `min_delay`/`max_delay` 改为 0.1 秒、衰减速度字段改为 10，并将尸体衰减检测半径由 1/3 放大到 300；关闭开关时恢复原值。

模组会把诊断信息追加写入 `%LOCALAPPDATA%/EnemySpawnMultiplier.log`。面板内的“导出游戏日志”按钮可以把日志、配置和运行状态导出到桌面诊断包。

### 安装

1. 关闭游戏。
2. 安装并启用官方 [Bingus Shared Loader v15 或更新版本](https://github.com/CowboyBingus/BingusSharedLoader/releases)，并设置为最高优先级。
3. 从 releases 页面安装唯一的 Panel 模组包。
4. 重新启动游戏。

### 配置保存

Panel 版本点击“应用”后，会将配置保存到 `%LOCALAPPDATA%/EnemySpawnMultiplier.cfg`，下次启动时自动恢复。配置文件损坏或缺失时会使用内置默认值。

## English

Only the Panel version is maintained. Press F8 to open the configuration panel and adjust the reinforcement budget, patrol count, patrol size, reinforcement cooldown and patrol cooldown. Patrol size ranges from `0.1x` to `2.0x` and defaults to `1.0x`.

"Fast corpse disappearance" is enabled by default. Every 0.5 seconds the mod checks the live entity data, first trying fixed anchors and then falling back to a full `DecaySettings` signature scan when those have moved. Only `DeathDecayMode_Regular` records are shortened to `min_delay = max_delay = 0.1 s`; turning the checkbox off restores the original values.

Diagnostics are appended to `%LOCALAPPDATA%/EnemySpawnMultiplier.log`. The panel can export the log, configuration and runtime state to a Desktop diagnostic pack.

Install the official [Bingus Shared Loader v15 or newer](https://github.com/CowboyBingus/BingusSharedLoader/releases), then install the single Panel package from the releases page.

The Panel build saves the committed profile to `%LOCALAPPDATA%/EnemySpawnMultiplier.cfg` and restores it automatically on the next launch.

[Technical walkthrough](docs/TECHNICAL.md) | [Build instructions](CONTRIBUTING.md) | [Installation](INSTALL.txt)
