# Enemy Spawn Multiplier

## 中文说明
目前还不是很完善，主要是自己跟朋友一起玩嫌怪太少了所以用AI来搓了一个
毕竟修改了游戏刷怪相关的机制，所以最好是自己玩或者和朋友一起玩哦，不要去恶搞路人！！！
具体改动： 延长了拉烟时间以及刷怪的数量、减少了巡逻队刷新的CD、增加了刷怪上限

v15 适用于 Steam build `24826606` / EXE `1.8.45317.0`，

- `Native Composition`：游戏想怎么刷就怎么刷
- `Light-Medium Bias`：刷怪更倾向于刷中轻甲

两个版本的刷怪强度相同，并使用同一个资源 ID，只能安装其中一个。

### 安装

1. 关闭游戏。
2. 安装并启用原作者的 [Bingus Shared Loader v15 或更新版本](https://github.com/CowboyBingus/BingusSharedLoader/releases/tag/v15)。
3. 在 HDArsenal 或 HD2MM 中导入 `Enemy-Spawn-Multiplier-6x-Native-Composition-v15.zip` 或 `Enemy-Spawn-Multiplier-6x-Light-Medium-Bias-v15.zip`，二选一。
4. 删除旧版 Enemy Spawn Multiplier 条目，重新部署并重启游戏。

两个版本均通过合成内存行为测试和发布包检查。实战数量仍会受到阵营、难度、地图、出生位置和原生人口门槛影响。

[技术说明](docs/TECHNICAL.md) | [构建说明](CONTRIBUTING.md) | [安装说明](INSTALL.txt)

<details>
<summary>English</summary>

v15 targets Steam build `24826606` / EXE `1.8.45317.0` and provides two mutually exclusive packages. Native Composition preserves native Encounter template weights. Light-Medium Bias ranks the current candidate pool by cost per planned unit and applies `3.6x`, `1.25x`, and `0.25x` selection weights to the lightest 50%, middle 30%, and heaviest 20%.

Both variants use the native Encounter budget override at `6x`, scale nonzero per-type caps and the group clamp to `10x`, and divide Patrol/Straggler intervals by `10`. Future deadlines longer than the new maximum interval are clamped so the initial native delay and failed-position-query backoff do not hide the faster configuration. The desired target stays native because scaling it can make the native combined-100 rejection fire more often.

The mod changes writable private data only and does not modify executable pages. Native population gates, position checks, template availability, and queue processing remain active.

Install the official [Bingus Shared Loader v15 or newer](https://github.com/CowboyBingus/BingusSharedLoader/releases/tag/v15), then install either `Enemy-Spawn-Multiplier-6x-Native-Composition-v15.zip` or `Enemy-Spawn-Multiplier-6x-Light-Medium-Bias-v15.zip`. Loader v15 discovers the declared entry automatically; no registry edit or custom loader fork is required.

[Technical walkthrough](docs/TECHNICAL.md) | [Build instructions](CONTRIBUTING.md) | [Installation](INSTALL.txt)

</details>
