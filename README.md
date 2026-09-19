# Enemy Spawn Multiplier

## 中文说明

v14 适用于 Steam build `24826606` / EXE `1.8.45317.0`，提供两个互斥版本：

- `Native Composition`：保留游戏原本的 Encounter 模板权重。
- `Light-Medium Bias`：偏向单位平均点数较低的模板。较轻的 50% 为 `3.6x`，中间 30% 为 `1.25x`，较重的 20% 为 `0.25x`。

两个版本的刷怪强度相同，并使用同一个资源 ID，只能安装其中一个。

### v14 刷怪调整

- Encounter 预算覆盖值为当前基础预算的 `6x`。
- 所有非零单类刷怪上限改为原来的 `10x`。
- Patrol 和 Straggler 的配置间隔缩短到 `1/10`，最低 `0.1` 秒。
- 组数量限制提高到原来的 `10x`。
- 已排定的 Patrol/Straggler 计时如果仍长于新配置的最大间隔，会被截短到新的最大值。这使首轮刷新和位置查询失败后的退避也能及时采用新速度。
- `cfg+0x50` 目标值保持原生。v13 的 `2x` 会增大 `combined-100` 算式，在部分人口构成下反而阻止刷新。

模组只修改私有可写数据，不修改游戏代码页。原生 70/448 人口门槛、位置查询、模板可用性和生成队列仍会限制最终数量。v14 通过扩大数据上限、增大单次组上限和持续截短过长 CD 来提高实际触发稳定性，但不会伪装成已移除原生硬门槛。

### 安装

1. 关闭游戏。
2. 在 HDArsenal 或 HD2MM 中导入 `Enemy-Spawn-Multiplier-6x-Native-Composition-v14.zip` 或 `Enemy-Spawn-Multiplier-6x-Light-Medium-Bias-v14.zip`，二选一。
3. 启用已注册本模块的 [BingusSharedLoader](https://github.com/NatsunXD/BingusSharedLoader)。
4. 删除旧版 Enemy Spawn Multiplier 条目，重新部署并重启游戏。

两个版本均通过合成内存行为测试和发布包检查。实战数量仍会受到阵营、难度、地图、出生位置和原生人口门槛影响。

[技术说明](docs/TECHNICAL.md) | [构建说明](CONTRIBUTING.md) | [安装说明](INSTALL.txt)

<details>
<summary>English</summary>

v14 targets Steam build `24826606` / EXE `1.8.45317.0` and provides two mutually exclusive packages. Native Composition preserves native Encounter template weights. Light-Medium Bias ranks the current candidate pool by cost per planned unit and applies `3.6x`, `1.25x`, and `0.25x` selection weights to the lightest 50%, middle 30%, and heaviest 20%.

Both variants use the native Encounter budget override at `6x`, scale nonzero per-type caps and the group clamp to `10x`, and divide Patrol/Straggler intervals by `10`. Future deadlines longer than the new maximum interval are clamped so the initial native delay and failed-position-query backoff do not hide the faster configuration. The desired target stays native because scaling it can make the native combined-100 rejection fire more often.

The mod changes writable private data only and does not modify executable pages. Native population gates, position checks, template availability, and queue processing remain active.

Install either `Enemy-Spawn-Multiplier-6x-Native-Composition-v14.zip` or `Enemy-Spawn-Multiplier-6x-Light-Medium-Bias-v14.zip` with [NatsunXD BingusSharedLoader](https://github.com/NatsunXD/BingusSharedLoader), remove older Enemy Spawn Multiplier entries, deploy, and restart the game.

[Technical walkthrough](docs/TECHNICAL.md) | [Build instructions](CONTRIBUTING.md) | [Installation](INSTALL.txt)

</details>
