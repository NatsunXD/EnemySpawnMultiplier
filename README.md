# Enemy Spawn Multiplier

## 中文说明

目前还不是很完善，主要是自己跟朋友一起玩嫌怪太少了所以用AI来搓了一个。

毕竟修改了游戏刷怪相关的机制，所以最好是自己玩或者和朋友一起玩哦，不要去恶搞路人！！！


### 版本

三个版本使用同一个资源 ID，只能安装其中一个，取向不同：

- `Native Composition`：整体提高刷怪强度，保持游戏原生的刷怪组合权重。
- `Light-Medium Bias`：整体提高刷怪强度，并让刷怪更倾向于中轻甲单位。
- `Fast Cadence`：把重心从"拉烟增强"移到"巡逻队激增"。敌人增援的冷却明显缩短；巡逻队出现得更频繁、数量更多、规模更大。同时这个版本会削弱拉烟效果
经多人测试反馈增强拉烟所带来的难度提升非常有限，因此后续只会主要维护`Fast Cadence`这个分支



### 安装

1. 关闭游戏。
2. 安装并启用原作者的 [Bingus Shared Loader v15 或更新版本](https://github.com/CowboyBingus/BingusSharedLoader/releases) 并设置为最高优先级。
3. 在 HDArsenal 或 HD2MM 中导入 releases 页面里的任意一个包，三选一。
4. 重新部署并重启游戏。

模组会把诊断信息追加写入 `%LOCALAPPDATA%/EnemySpawnMultiplier.log`。
提问时请附带当局log文件

## 🤝 参与贡献

欢迎任何形式的贡献！以下是标准贡献流程：

1. **Fork 仓库** - 点击右上角 Fork 按钮创建您的副本
2. **创建分支** - 基于开发分支创建特性分支：
   ```bash
   git checkout -b feature/your-feature-name
   ```
3. **提交修改** - 编写清晰的提交信息：
   ```bash
   git commit -m "feat: 添加新功能" -m "详细描述..."
   ```
4. **推送更改** - 将分支推送到您的远程仓库：
   ```bash
   git push origin feature/your-feature-name
   ```
5. **发起 PR** - 在 GitHub 上创建 Pull Request 到原仓库的 `main` 分支


[技术说明](docs/TECHNICAL.md) | [构建说明](CONTRIBUTING.md) | [安装说明](INSTALL.txt)

<details>
<summary>English</summary>

Three mutually exclusive packages share one resource ID, so install exactly one.

- `Native Composition` raises overall spawn pressure and keeps the game's native Encounter composition weights.
- `Light-Medium Bias` raises overall spawn pressure and steers Encounter composition toward lighter and medium units.
- `Fast Cadence` shifts the emphasis from wave size to cadence and composition. Enemy reinforcement arrives on a much shorter cooldown, and both the wave composition and its point budget are steered toward heavier units. Patrols appear more frequently, in greater numbers, and in larger groups. Because the per-wave reinforcement point budget is reduced, a wave is made of fewer but heavier units rather than being larger overall.

`Fast Cadence` deliberately opposes the other two: it aims for a steady, rapid stream of units instead of large individual waves.

Install the official [Bingus Shared Loader v15 or newer](https://github.com/CowboyBingus/BingusSharedLoader/releases), then install exactly one of the packages published on the releases page. Loader v15 discovers the declared entry automatically; no registry edit or custom loader fork is required.

The mod changes writable private data only and does not modify executable pages. Native population gates, position checks, template availability and queue processing remain active. Diagnostics are appended to `%LOCALAPPDATA%/EnemySpawnMultiplier.log`.

[Technical walkthrough](docs/TECHNICAL.md) | [Build instructions](CONTRIBUTING.md) | [Installation](INSTALL.txt)

</details>
