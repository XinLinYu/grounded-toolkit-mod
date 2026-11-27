---
status: accepted
---

# 一键找回背包采用唤醒远距 LOD 并瞬移背包实体到玩家脚边

实现「一键找回背包」时，我们选择扫描世界中全部玩家掉落背包（包括通过 `ULootBagLODActor:ConvertToFullActorBlocking()` 唤醒远距离已卸载的背包代理），过滤掉建筑战利品袋（`ELootBagType != PlayerBackpack`）与已空背包后，将背包实体以小扇形错开瞬移到目标玩家正前方地面并调用 `ALootBag:ResyncReplicationTransform()` 同步联机坐标。

## Considered Options

- **调用引擎内置 `USurvivalGameplayStatics::RecoverPlayerBackpacks()`**：引擎原生支持把所有玩家背包送回开局手提箱（Kid Case），但存在每次读档只能用一次（`bHasRecoveredPlayerBackpacks`）的限制，且玩家仍需从地图另一端跑回出生点拾取。
- **直接调用 `UInventoryComponent::ServerTransferAllFrom()` 自动转入玩家背包**：当玩家当前背包格子已满或同时存在多个死亡背包时，会出现部分物品装不下的拆分溢出问题，还需额外兜底处理剩余容器。

## Consequences

- 玩家无论身处地图何处，点击后背包实体立刻出现在脚边，按 `E` 即可像原版一样自由拾取或挑拣，彻底规避满包溢出与丢物品风险。
- 移动世界实体依赖服务端权威，因此多人联机中该操作仅限房主执行（客机端灰显禁用）；房主可通过「找回我的背包」与「找回全队背包（在线队友送至各自脚边、离线玩家送至房主脚边）」兼顾单人与联机场景。
- **关键引擎安全约束**：Grounded 世界中大量未流式加载的实验室 Ominent 宝箱与建筑战利品袋底层同样使用 `ULootBagLODActor`，严禁对其批量调用 `ConvertToFullActorBlocking()`（否则会在未加载子关卡强行生成实体并引发 `UBaseLODActor` 空指针闪退）。因此在唤醒任何 LOD 前，必须先完成只读前置校验（`HUDMarkerManagerComponent` 的 `DroppedBackpack` 标记 / `BP_Backpack` 类型白名单与宝箱黑名单 / `UProxyLootBagActor` 归属者校验 / `UProxyInventoryComponent` 非空校验），仅唤醒确认匹配的少量玩家掉落背包。
