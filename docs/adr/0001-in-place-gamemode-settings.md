---
status: accepted
---

# 原地覆写运行时游戏模式设置以保留 Steam 成就

为了在不将存档切换为自定义模式（`EGameMode::Custom`）的前提下提供伤害倍率、无材料建造/制作、死亡背包保留与免除死亡耐久惩罚，我们选择直接原地修改活跃的 `USurvivalGameModeSettings` 运行时实例字段，并在关闭开关时按缓存的原版基准值精确还原，绝不调用 `SwapToCustom()`、`SetGameMode()` 或 `UpdateCustomSettings()`。

## Considered Options

- **调用官方 `UpdateCustomSettings()` / `SwapToCustom()`**：虽然直接由引擎持久化且天然同步自定义面板，但会触发 `OnGameModeChanged` 并将 `CurrentGameMode` 永久切换为 `Custom`，导致 `UAchievementsComponent` 永久锁定该存档的 Steam 成就。
- **拦截并改写玩家死亡结算函数（Hook 死亡逻辑）**：可实现更细粒度的物品过滤，但跨游戏小版本维护成本高，且需要自行处理联机客户端同步与异常中断回滚。

## Consequences

- 存档始终保持 `Normal / Relaxed / Hard` 原版生存模式，卸载插件后不留任何存档污染，Steam 成就完全不受影响。
- 插件需要在每次进入存档与定时心跳中维持对 `USurvivalGameModeSettings` 的覆写（并在读档或切换世界时清空缓存的原版基准值），且联机时仅房主端生效（由房主自然同步给全队）。
