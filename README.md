# Enemy Spawn Multiplier

## 中文说明

这是一个用于调整《绝地潜兵 2》敌人生成参数的模组。目前只维护 Panel 版本。

v23 按 F8 打开配置面板，可调整增援预算、巡逻数量、巡逻规模以及增援和巡逻冷却。安装可选的 [Mod Options Menu](https://github.com/CowboyBingus/ModOptionsMenu/releases) v1.1 或更新版本及 Bingus Shared Loader v18+ 后，也可以在暂停菜单的 MODS → Enemy Spawn Multiplier 中修改同一份配置；不需要 HD2Runtime。

两边都在点击“应用 / APPLY”后提交，并同步到另一边。另一边同字段的草稿会以最新已应用值为准，其他字段尚未应用的编辑保留。MODS 一次 APPLY 的多个字段只提交、保存一次。未安装菜单或菜单不可用时，F8 面板仍可独立使用。

F8 面板右下角的 English / 中文按钮即时切换语言；MODS 菜单也有“语言 / Language”选项。语言设置两边同步并保存。F8 文案即时刷新；MODS 文案按照菜单的公开接口，在关闭并重新打开暂停菜单后刷新。切换语言不会应用 F8 中尚未提交的刷怪参数，也不会重置参数。旧版 Mod Options Menu v1.0 仍可同步参数，但其菜单文案固定为英文。

面板在「模板预设」旁始终显示「本模组不支持野房使用！」。匹配隐私为公开时，或房主已消耗 SOS 信标后，模组会跳过刷怪写入（并暂停快速清尸），SOS 侦测为只读、约每 2 秒一次，闩锁后停止扫描。

模组会把诊断信息追加写入 `%LOCALAPPDATA%/EnemySpawnMultiplier.log`。面板内的“导出游戏日志”按钮可以把日志、配置和运行状态导出到桌面诊断包。

### 安装

1. 关闭游戏。
2. 安装并启用官方 [Bingus Shared Loader v15 或更新版本](https://github.com/CowboyBingus/BingusSharedLoader/releases)，并设置为最高优先级。
3. 从 releases 页面安装唯一的 Panel 模组包。
4. 重新启动游戏。
5. 若安装了牛仔哥的`ModBindingsMenu` MOD，则还需要在 游戏设置-按键绑定-MODS 中为`Toggle Menu`设置一个按键

### 配置保存

任一界面应用配置后，都会将参数和语言保存到 `%LOCALAPPDATA%/EnemySpawnMultiplier.cfg`，下次启动时自动恢复，旧配置文件继续可用。ESM 配置文件优先于菜单自己的旧保存值；只有没有可用 ESM 配置文件时，才首次导入菜单保存值。

## English

Only the Panel version is maintained. Press F8 to open the configuration panel and adjust the reinforcement budget, patrol count, patrol size, reinforcement cooldown and patrol cooldown. Patrol size ranges from `0.1x` to `2.0x` and defaults to `1.0x`.

v23 also supports the optional [Mod Options Menu](https://github.com/CowboyBingus/ModOptionsMenu/releases) v1.1+ with Bingus Shared Loader v18+. Open MODS → Enemy Spawn Multiplier in the escape menu. HD2Runtime is not required. Both interfaces commit on Apply and synchronize submitted fields; unrelated pending edits stay staged. F8 works without the menu.

Use the English / 中文 button in F8 or the Language option in MODS. The choice is synchronized and saved. F8 text changes immediately; reopen the escape menu to refresh MODS text. A language change preserves gameplay settings and unapplied F8 drafts. Menu v1.0 can synchronize values but shows static English text.

"Fast corpse disappearance" (ragdoll-preserving) is enabled by default. Every 0.5 seconds the mod checks the live entity data, first trying fixed anchors and then falling back to a full `DecaySettings` signature scan when those have moved. Only `DeathDecayMode_Regular` records are shortened to `min_delay = max_delay = 5 s`; turning the checkbox off restores the original values. The panel always shows that public lobbies are unsupported. Spawn writes (and fast corpse decay) are skipped while matchmaking privacy is Public, or after the host spends the SOS beacon; the SOS probe is read-only, polls about every 2 seconds, and stops scanning after the latch.

Diagnostics are appended to `%LOCALAPPDATA%/EnemySpawnMultiplier.log`. The panel can export the log, configuration and runtime state to a Desktop diagnostic pack.

Install the official [Bingus Shared Loader v15 or newer](https://github.com/CowboyBingus/BingusSharedLoader/releases), then install the single Panel package from the releases page.

The Panel build saves the committed profile and language to `%LOCALAPPDATA%/EnemySpawnMultiplier.cfg` and restores them automatically on the next launch. This file takes priority over stale menu saves; the menu's saved values are imported only when there is no usable ESM profile.

[Technical walkthrough](docs/TECHNICAL.md) | [Build instructions](CONTRIBUTING.md) | [Installation](INSTALL.txt) | [MIT License](LICENSE)
