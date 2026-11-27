---
status: accepted
---

# 普通掉落 1 倍落地、入包统一乘倍率与搬运物瞬时缩放还原策略

为了彻底根治此前 `FindAllOf("LootComponent")` 与 `FoliageMappings` 持久修改蓝图 CDO / `GEN_VARIABLE` 模板引发的新生成采集点复利暴增（3x → 9x → 27x 炸出几十个资源）以及 `ServerHandleInteract` 误判导致爆出物入包再乘一次的严重失衡问题，我们确立如下采集倍率架构：
1. **零模板/零持久修改**：彻底移除 `applyAllLootComponents()` 与对 `FoliageMappings` 的任何写入，绝不修改任何蓝图 CDO、`GEN_VARIABLE` 模板或世界 `ULootComponent` 的持久 `Count`。
2. **普通可入包物品「1 倍落地、入包乘倍率」**：锤橡果、砍植物、挖黏土/虫、击杀生物时地上均保持原版 1 倍物理爆出，统一在房主端 `ASurvivalPlayerCharacter:ServerHandleInteract` 拾取进背包（或按 `E` 搜刮死虫尸体直入背包）时按配置倍率补足 `(mult - 1)` 倍堆叠；通过读取真实的 `InteractableInRange` 与 `InteractableFoliageKeyInRange` 精确区分「采集/击杀爆出物与虫尸（总开关控制）」与「地面天然 ISM/预摆资源（自然直拾开关独立控制）」，并实施四重防刷拦截——排除玩家丢弃物与投掷物（原生 `GetDroppedBy()` / `bWasThrown` + 运行期 Hook `ServerDropItem / ServerHotDrop / ServerThrowItem / ServerHandleDrop` 登记）、排除拆毁建筑/取消蓝图返还物（Hook `ABuilding::DropItem / DropNewItem / BlueprintDropItems / CancelBuild`）、排除储物箱/掉落背包/工作台 UI 转移与不可堆叠装备、拦截地上 `StackSize > 1` 的整堆物品。
3. **肩扛搬运物瞬时 Pre/Post 还原**：草板、杂草茎等无法入包的肩扛搬运物仅在勾选对应开关时，于 `ULootComponent:SpawnLoot` Pre-Hook 瞬时放大搬运物条目（单棵封顶 12 根），并在 Post-Hook 中立即精确还原为原版 `Count`（支持嵌套栈式还原且跳过 CDO/模板对象）。

## Considered Options

- **仅在 `ULootComponent:SpawnLoot` 做全物品瞬时 Pre/Post 还原，地面拾取仅放行预摆/ISM**：虽能消除模板复利，但高倍率下锤橡果/矿石仍会在地面炸出大量物理实体滚动卡顿，且部分纯 C++ 内部调用的掉落可能绕过 Blueprint `ProcessEvent` Hook。
- **把草板/杂草茎也改为 1 倍落地、扛上肩时直接补满肩扛数量**：玩家默认肩扛上限仅 5 根，3 倍扛第 2 根即被上限截断浪费，且每根草板为独立 `UItem` 对象，运行期克隆同步给联机客机的风险远高于 `SpawnLoot` 瞬时缩放。
- **跨重启磁盘持久化已丢弃单件物品列表**：需额外向磁盘维护每个存档的丢弃 GUID 索引，引入清理与存档对齐复杂度，违背零存档侵入原则；当次会话内四重拦截已覆盖正常全部防刷场景。

## Consequences

- 正常游玩任意时长、任意切换难度/倍率或重载存档，底层 `ULootComponent` 蓝图模板始终保持原版 1 倍，数学上杜绝复利暴增与二次翻倍。
- 锤橡果/矿石/植物后地面物品数量清爽不卡顿，一次按 `E` 即可直接按倍率堆叠入包，房主开启后全队（含客机）统一生效。
- 玩家手动丢弃单个物品后若完全退出并重启游戏再拾取该跨重启残留单件，属于可接受的零磁盘污染边界取舍。
