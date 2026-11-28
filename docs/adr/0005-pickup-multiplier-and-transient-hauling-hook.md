---
status: accepted
---

# 普通掉落 1 倍落地、全路径 AddItem 入包乘倍率与搬运物瞬时缩放还原策略

为了彻底根治此前 `FindAllOf("LootComponent")` 与 `FoliageMappings` 持久修改蓝图 CDO / `GEN_VARIABLE` 模板引发的新生成采集点复利暴增（3x → 9x → 27x 炸出几十个资源），以及旧版仅挂 `ServerHandleInteract` 时因 `FWeakObjectPtr` 未解包、C++ 直接路由与自动装备/延迟拾取导致的自然直拾失效问题，我们确立如下采集倍率架构：
1. **零模板/零持久修改**：彻底移除 `applyAllLootComponents()` 与对 `FoliageMappings` 的任何写入，绝不修改任何蓝图 CDO、`GEN_VARIABLE` 模板或世界 `ULootComponent` 的持久 `Count`。
2. **普通可入包物品「1 倍落地、全路径入包与自动装备乘倍率」**：锤橡果、砍植物、挖黏土/虫、击杀生物时地上均保持原版 1 倍物理爆出，同时覆盖实机二进制确认的全部 4 条拾取入包/装备路径：
   - 常规背包入包（`TryPickupItem` 分支 4 经 `ServerAddItem(Item, true)` 尾调用 `AddItem(Item, true)`）与 `ULootComponent` 死虫摸尸直入背包（经 `IItemContainerInterface::Execute_AddItem` 调 `AddItem(Item, true)`）：统一由 `/Script/Maine.InventoryComponent:AddItem` Pre-Hook 校验可用余量后提前按倍率抬升 `item.StackSize`（使首次采集的背包数量与原生 `OnItemAdded` / `ClientOnItemAdded` HUD 播报 100% 同步走倍率；若入包被拒绝则在 Post-Hook 立即回滚），Post-Hook 负责超堆叠溢出与经严格校验的易腐昆虫生肉（`CanSpoil=true` 且不可装备/无耐久）副本补发，绝不将 `ServerAddItem` 列入非采集屏蔽列表；
   - 空手自动装备可堆叠物（`TryPickupItem` 分支 1/3，如鹅卵石/箭矢直接走 `UEquipmentComponent:ServerEquipItem(Item, bCheckInventory=false)` 绕过 `AddItem`）：由 `ServerEquipItem` Pre/Post Hook（仅 `bCheckInventory == false` 且做同对象防重）实时倍增已装备堆叠；
   - 手持同类可堆叠物继续拾取叠加（`TryPickupItem` 分支 2，直接在 C++ 中对主手武器调用 `AdjustStackSize` 并派发 `ClientOnItemAdded`，完全绕过 `AddItem` 与 `ServerEquipItem`）：由 `UInventoryComponent:ClientOnItemAdded`（`inAddItemDepth == 0`）与 `ServerHandleInteract` Post-Hook（兼顾联机客机）补齐倍率；
   - 超出 `maxStack` 或易腐昆虫生肉副本均统一通过 `ServerCreateAndAddItem` 自动溢出至空闲背包格（由 `inModExtraAddDepth` 防止递归）。
3. **精准区分自然直拾与全链路防刷拦截**：
   - 通过 Hook `ASpawnedItem:NotifySwapped(FromKey, bFromDamage)` 精确区分「ISM 天然植被直拾（`bFromDamage == false`）与预摆自然物（`PreplacedDesign = 2/3`）——受 `harvestAffectPickup` 独立控制」和「砍伐/破坏/击杀爆出及死虫摸尸——由总开关 `harvestEnabled` 控制」；同时在 `hasValidFoliageKey` 与 `UItem.ItemVisuals` 处统一解包 UE4SS `FWeakObjectPtr:Get()`。
   - 通过 `inNonHarvestAddDepth` 屏蔽全部箱子/背包转移、换格、合并、合成产出、内部 `ServerCreateAndAddItem` 及容器/烤肉架/晾干架交互；防刷校验仅对玩家角色（`ASurvivalPlayerCharacter`）与建筑/容器丢出的 `DroppedByActor` 生效（放行野生昆虫 `ASurvivalCreature` 死亡掉落物），`ServerReleaseThrow` 仅登记实际投掷武器的精确 `RowName`，`Building:BlueprintDropItems` 作为蓝图脚本钩子仅注册单回调绝不触碰同步深度计数器，并保留射出箭矢（`AttackOwner`）、玩家放置物（`PreplacedUser = 1`）、拆建返还与不可堆叠武器/防具/工具的严格 1 倍拦截。
4. **肩扛搬运物三入口瞬时 Pre/Post 还原**：草板、杂草茎等无法入包的肩扛搬运物仅在勾选对应开关时，于 `ULootComponent:SpawnLoot`、`OnDeath`、`OnDamaged` 三个入口共用每组件深度守卫（防止 `OnDeath` 嵌套调用 `SpawnLoot` 时二次叠加）做瞬时缩放（单棵倍率放大上限 12 根，且当原版单株固有掉落已达到或超过 12 根时保持原版数量绝不削减），并在最外层 Post-Hook 中立即精确还原为原版 `Count`（跳过全部 CDO/模板对象）。

## Considered Options

- **仅在 `ASurvivalPlayerCharacter:ServerHandleInteract` 拦截并快照背包**：会被直接走延迟动画、接触自动拾取、长按交互或 `FWeakObjectPtr` 未解包的自然直拾绕过，且无法覆盖 `TryPickupItem` 紧随 `AddItem` 后的自动装备（鹅卵石/箭矢）以及超 `maxStack` 溢出。
- **仅在 `ULootComponent:SpawnLoot` 做全物品瞬时 Pre/Post 还原，地面拾取仅放行预摆/ISM**：虽能消除模板复利，但高倍率下锤橡果/矿石仍会在地面炸出大量物理实体滚动卡顿，且部分纯 C++ 内部调用的掉落可能绕过 Blueprint `ProcessEvent` Hook。
- **把草板/杂草茎也改为 1 倍落地、扛上肩时直接补满肩扛数量**：玩家默认肩扛上限仅 5 根，3 倍扛第 2 根即被上限截断浪费，且每根草板为独立 `UItem` 对象，运行期克隆同步给联机客机的风险远高于瞬时缩放。
- **跨重启磁盘持久化已丢弃单件物品列表**：需额外向磁盘维护每个存档的丢弃 GUID 索引，引入清理与存档对齐复杂度，违背零存档侵入原则；当次会话内全链路防刷已覆盖正常全部防刷场景。

## Consequences

- 正常游玩任意时长、任意切换难度/倍率或重载存档，底层 `ULootComponent` 蓝图模板始终保持原版 1 倍，数学上杜绝复利暴增与二次翻倍。
- 无论玩家是直接拾取地面树枝/纤维/鹅卵石/小蘑菇、挖黏土/锤橡果/砍三叶草、摸死虫尸体、接触自动拾取还是拾取多件自然掉落堆，均可 100% 稳定触发入包倍率并自动处理超堆叠溢出，房主开启后全队（含客机）统一生效。
- 玩家手动丢弃单个物品后若完全退出并重启游戏再拾取该跨重启残留单件，属于可接受的零磁盘污染边界取舍。
