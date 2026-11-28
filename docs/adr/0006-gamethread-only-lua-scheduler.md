---
status: accepted
---

# 纯 GameThread 单线程 Lua 调度与启动引导策略

对三次连发闪退 Minidump（`21.22.32` / `21.47.28` / `22.04.51`）与 `UE4SS.dll`（v4.0.0 `#30afe5ff`）二进制反汇编联合取证确认，根本崩溃原因在于 **UE4SS 4.x 后台异步线程调用 `ExecuteInGameThread` 时对 `m_hook_lua` 产生无保护跨线程栈竞争**：

- `LoopAsync` 运行在独立 OS 后台线程上的 `m_async_lua`，而全部 `RegisterHook` 回调在游戏主线程（GameThread）上共享同一个 `lua_State*`（`m_hook_lua`，位于 `LuaMod + 0x88`）。
- 当后台线程调用 `ExecuteInGameThread(fn)` 时，`UE4SS.dll` 直接在后台线程对 `m_hook_lua` 依次执行 `lua_xmove(m_async_lua, m_hook_lua, 1)` 与 `luaL_ref(m_hook_lua, LUA_REGISTRYINDEX)`。UE4SS 的 `lua_lock` 仅加锁单个 Lua C-API 调用，并不保护多步栈操作序列、Lua VM 字节码执行或 GC 阶段。
- 在高频 Native `RegisterHook` 场景（特别是进出背包、切换场景、拾取/触碰掉落物与战斗期间）下，后台线程的 `lua_xmove` / `luaL_ref` 与主线程正在执行的 `RegisterHook` 回调并发改写同一个 `m_hook_lua->top` 栈指针，导致主线程将 `LUA_REGISTRYINDEX` 空闲链表整数（如 `0x5E` / `0x5F`）或偏移字符串错当成 `Table*` / `Userdata` 解引用，在 `luaH_getint` / `luaH_next` / `findsetreg` 处立即触发访问违例（`0xC0000005`）甚至堆损坏（`0xC0000374`）。

基于上述底层机制，我们确立以下单线程调度架构：

1. **彻底禁止后台异步 Lua 线程**：永久移除 `LoopAsync`，并在代码与回归测试中明令禁止任何运行期 `LoopAsync` / `ExecuteAsync` / `ExecuteWithDelay` 调用，以及从非 GameThread 调用 `ExecuteInGameThread`。
2. **启动期一次性 GameThread 引导**：脚本加载时仅调用**唯一一次** `ExecuteInGameThread(bootstrapOnGameThread)`（此时尚未注册任何 `RegisterHook`，`m_hook_lua` 完全空闲，不存在并发窗口）。在 `bootstrapOnGameThread()` 内于 GameThread 上串行完成：
   - 注册全部 45 个原版 UFunction Hook（`registerLootAndAntiExploitHooks()` 与 `registerPickupMultiplierHooks()`）；
   - 通过 UE4SS 4.x 原生纯主线程循环 `LoopInGameThreadWithDelay(100, onScheduledGameThreadCheck)`（由 `EngineTick` 挂钩在 GameThread 同步调度，支持 re-entrant 延迟队列）挂载主调度器。
3. **纯 Lua 轻量节流 + 有界状态维护**：`onScheduledGameThreadCheck()` 保持每 100ms 检查本地 `os.clock()` 是否到达地图刷新周期（0.25s/0.35s）或低频心跳周期（0.6s），未到期直接返回（零 UObject/磁盘开销）；同步为反刷/植被地址追踪表引入有界 TTL 与容量淘汰，并在 `scaleHaulingLootPre` / `restoreHaulingLootPost` 禁用时纯 Lua 零 UObject 早退。
4. **顺带根治 UE4SS 4.x `TSoftObjectPtrUserdata` 解析污染**：统一使用 `TSoftObjectPtrUserdata:GetObjectID():GetAssetPathName():ToString()` 解析 `BestiaryTable.Creature` 与 `ULootBagLODActor:GetActorClassSoft()`，过滤 `"Userdata:"` 指针文本，并在 Lua `pollConfig()` 与 C++ `IpcBridge::LoadConfigLocked()` 双向自动清洗历史脏 `trackedIds`。

## Considered Options

- **继续使用 `LoopAsync` + 调大轮询间隔（如 500ms / 1000ms）**：仅降低碰撞概率，无法根治跨线程并发写 `m_hook_lua` 栈的结构性竞态，在持续游玩或高密度战斗/拾取期仍会随机闪退。
- **在顶层直接调用 `RegisterHook` + `LoopInGameThreadWithDelay`，不使用启动引导**：加载脚本期间 `m_main_lua` 尚未退出，先注册的 Hook 已可能在 GameThread 上触发，与后续 `RegisterHook` / `LoopInGameThreadWithDelay` 的 `lua_xmove(..., m_hook_lua, 1)` 形成短暂启动期竞争窗口。
- **把 `onScheduledGameThreadCheck` 挂在 `RegisterHook("/Script/Engine.Actor:ReceiveTick", ...)` 上**：会无差别拦截所有 Actor 每帧 Tick，带来严重性能损耗，且不如 UE4SS 内置 `EngineTick` 驱动的 `LoopInGameThreadWithDelay` 轻量可靠。

## Consequences

- 启动引导完成后的整个游戏生命周期内，本 Mod 的全部 Hook 回调与定时逻辑 100% 串行运行在 UE 游戏主线程的 `m_hook_lua` 上，从根源上消灭跨线程 Lua 栈踩踏闪退。
- 定时检查在未到期时仅执行极轻量的时钟相减与布尔判断，对帧率影响可忽略，同时完整保留原有 M 地图 0.25s/0.35s 响应与 0.6s 状态/配置同步节奏。
- 依赖 RE-UE4SS v3.0.1+ / v4.x 提供的 `LoopInGameThreadWithDelay`（已随本 Mod 绿色包内置的 UE4SS v4.0.0 验证支持）。
