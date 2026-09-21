# Enemy Spawn Multiplier

## 中文说明
目前还不是很完善，主要是自己跟朋友一起玩嫌怪太少了所以用AI来搓了一个

毕竟修改了游戏刷怪相关的机制，所以最好是自己玩或者和朋友一起玩哦，不要去恶搞路人！！！

具体改动： 延长了拉烟时间以及刷怪的数量、减少了巡逻队刷新的CD、增加了刷怪上限

### V15往后版本已适配原版Bingus Shared Loader v15 或更新版本

- `Native Composition`：游戏想怎么刷就怎么刷
- `Light-Medium Bias`：刷怪更倾向于刷中轻甲
- `Preview Low Budget Patrol`：遭遇预算降至原版 0.1x，巡逻/散兵刷新间隔改为 0.0-0.1 秒，组规模上限保持 10x，守军预算和刷新机制保持原版

三个版本使用同一个资源 ID，只能安装其中一个。

### 安装

1. 关闭游戏。
2. 安装并启用原作者的 [Bingus Shared Loader v15 或更新版本](https://github.com/CowboyBingus/BingusSharedLoader/releases) 并设置为最高优先级。
3. 在 HDArsenal 或 HD2MM 中导入 `Enemy-Spawn-Multiplier-6x-Native-Composition-v16.zip`、`Enemy-Spawn-Multiplier-6x-Light-Medium-Bias-v16.zip` 或 `Enemy-Spawn-Multiplier-Preview-Low-Budget-Patrol-v17-preview.zip`，三选一。
4. 重新部署并重启游戏。

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

v16 targets Steam build `24826606` / EXE `1.8.45317.0` and provides two mutually exclusive packages. Native Composition preserves native Encounter template weights. Light-Medium Bias ranks supported Encounter candidates by cost per planned unit using their inline composition rows and falls back to native weights when a faction uses an incompatible layout.

Both variants use the native Encounter budget override at `6x`, scale nonzero per-type caps and the group clamp to `10x`, and divide Patrol/Straggler intervals by `10`. Future deadlines longer than the new maximum interval are clamped so the initial native delay and failed-position-query backoff do not hide the faster configuration. The desired target stays native because scaling it can make the native combined-100 rejection fire more often.

The mod changes writable private data only and does not modify executable pages. Illuminate GuardForce budget is reduced to one quarter during initialization so static defenders leave capacity under the shared native population gate. Native population gates, position checks, template availability, and queue processing remain active.

Install the official [Bingus Shared Loader v15 or newer](https://github.com/CowboyBingus/BingusSharedLoader/releases/tag/v15), then install exactly one of `Enemy-Spawn-Multiplier-6x-Native-Composition-v16.zip`, `Enemy-Spawn-Multiplier-6x-Light-Medium-Bias-v16.zip`, or `Enemy-Spawn-Multiplier-Preview-Low-Budget-Patrol-v17-preview.zip`. Loader v15 discovers the declared entry automatically; no registry edit or custom loader fork is required.

A preview package tests the opposite density split: `Enemy-Spawn-Multiplier-Preview-Low-Budget-Patrol-v17-preview.zip` lowers the Encounter composition budget to `0.1x`, runs timed Patrol/Straggler intervals at `0.0-0.1` seconds, keeps the `10x` cap and group expansion, and leaves GuardForce/static defenders on the native budget and schedule. It uses the same resource ID, so install it instead of either v16 variant.

[Technical walkthrough](docs/TECHNICAL.md) | [Build instructions](CONTRIBUTING.md) | [Installation](INSTALL.txt)

</details>
