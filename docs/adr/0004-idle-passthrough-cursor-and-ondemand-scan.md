---
status: accepted
---

# 悬浮层空闲零开销直通、单系统光标托管与 Lua 按需扫描架构

为彻底根治关闭菜单后鼠标指针随视角高速闪烁以及正常游玩期间周期性掉帧问题，我们对 C++ 悬浮层与 Lua 引擎层确立三项长期架构约束：
1. **菜单关闭零干扰与菜单期 Win32 光标 API 条件接管**：永久开启 `ImGuiConfigFlags_NoMouseCursorChange` 并关闭 `io.MouseDrawCursor`；菜单关闭时完全不调用 `ImGui_ImplWin32_WndProcHandler`、绝不触碰光标与输入捕获（M 地图悬停改为只读 `GetCursorPos`）；由于 UE4 的 `FSlateApplication::Tick()` / `FWindowsCursor` 在 3D 游玩态下每帧直接调用 `USER32!SetCursor(NULL)` / `ShowCursor(FALSE)` / `ClipCursor` / `SetCursorPos` 绕过 `WM_SETCURSOR`，我们在上述 4 个 Win32 光标 API 上安装轻量化 MinHook——菜单关闭时单条原子判断零开销直通原 API，仅当菜单打开且游戏窗口处于前台时拦截 UE4 对光标的隐藏、锁框与居中拉回，同时记录 UE4 最新光标/锁框/显示计数期望，在关闭菜单或 `Alt+Tab` 失焦瞬间精确还原并派发 `WM_SETCURSOR` 交还 UE4。
2. **渲染层空闲零开销直通 + 后台异步 IPC**：当菜单关闭、M 地图关闭且开场提示条已消失时，`Present` 直接放行，跳过 DX12 围栏等待、BackBuffer 资源屏障、命令提交与 ImGui 帧构建；同时把 JSON 文件读写与解析全部移出渲染线程交由独立后台 I/O 线程完成，渲染线程仅读取 `std::shared_ptr` 不可变快照。
3. **Lua 游玩期零全图扫描与客机本地多源追踪**：停用周期全图 `LODActors` 扫表与任何 `FindAllOf("LootComponent")` 扫表（掉落倍率改为 ADR-0005 约束）；目录与乳牙数改为进图首次、打开 M 地图（打开期间降频至 1.8 秒同步一次，拖拽缩放仍由 C++ 满帧直读 Slate 内存）、打开 Mod 菜单超 5 秒静默轻刷新（`refresh_catalog_soft`）或手动刷新时按需更新，并对 `status.json` 写盘做脏检查且缓存高频 UObject 句柄。多人联机客机端因 `LODActors` 为服务端独占，自动改为本地多源扫描（全队共享的 `TrackedCollectibles` 乳牙/SCA.B + 全图原生同步 ISM 植被 + 客机网络相关性范围内已加载的 `HarvestNode / SurvivalCreature / SpawnedItem / ScienceCollectable / OminentChest`），保持主客机独立追踪且零联机协议风险。

## Considered Options

- **继续使用 ImGui 软件光标（`io.MouseDrawCursor = true`）并在菜单关闭时隐藏**：软件光标比硬件光标多 1~2 帧渲染延迟，且鼠标移到系统原生输入法候选窗上时会被遮挡；而 UE4 底层本身是通过 `WM_SETCURSOR` 设置 `SetCursor(NULL)` 来隐显光标，托管单一系统原生光标更契合引擎机制。
- **保留低频（如 60 秒）后台全图扫描或分帧切片扫描**：虽然刚打开菜单瞬间无需等待 0.3~0.5 秒刷新，但在正常战斗/跑图期间仍会持续占用 UE4 游戏主线程 CPU 并增加调度复杂度。
- **把 C++ 悬浮层与 Lua 通信改为命名管道 / 共享内存**：长期可行，但需要双端引入新的底层 FFI/原生绑定并破坏现有离线回归测试与零依赖绿色分享包约定；将文件 IPC 迁到独立后台线程 + 脏检查写入即可在不改通信协议的前提下完全消除渲染线程与游戏线程 I/O 抖动。

## Consequences

- 正常游玩（菜单与 M 地图关闭）时，C++ 悬浮层 GPU 额外提交为 0、渲染线程文件 I/O 为 0、系统光标干预为 0，Lua 主线程周期全图扫描与无效写盘均为 0。
- 关闭菜单长时间游玩后首次按 `Insert/F8` 打开菜单时，目录与乳牙统计会通过静默 `refresh_catalog_soft` 在约 0.3~0.5 秒内自动同步最新状态；`USurvivalGameModeSettings` 仍通过缓存句柄轻心跳维持，与 ADR-0001 保持兼容。
