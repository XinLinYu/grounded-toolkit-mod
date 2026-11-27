---
status: accepted
---

# 窗口主线程按需恢复 IME/TSF 与原生/自绘混合候选框策略

为了让 GroundedQoL 中文悬浮菜单内的文本输入框正常唤起中文输入法并展示候选字，我们选择绕开 Dear ImGui 默认在 DX12/DX11 渲染线程调用的 `Platform_SetImeDataFn`，改为在输入框获焦（`io.WantTextInput`）变化时通过非阻塞 `PostMessageW` 投递到游戏主窗口线程，先检测并暂存解绑 UE4 绑定在窗口上的空 TSF 禁用文档管理器（`ITfThreadMgr::AssociateFocus(hWnd, nullptr)`），再调用 `ImmAssociateContextEx(..., IACE_DEFAULT)` 促使 Windows CUAS 恢复活跃 TSF/IMM 输入法上下文并定位候选窗；同时采用混合候选框策略——窗口/无边框全屏优先走系统原生候选窗，独占全屏或用户手动切换时自动降级为 ImGui 内嵌自绘拼音与候选条（通过 IMM32 与 TSF `ITfUIElementSink` 采集候选字），并在失焦或关闭菜单瞬间精确还原 UE4 原先的 TSF 与 IMM 禁用状态。

## Considered Options

- **仅在 `HookedWndProc` 放行 `WM_IME_*` 并依赖 ImGui 默认实现**：UE4（`FWindowsTextInputMethodSystem`）在非引擎文本框时会主动解绑窗口 `HIMC`，且 DX12 下 `Present` 运行在 RHI/渲染线程而非窗口线程，直接调用 `ImmGetContext` / `ImmSetCompositionWindow` 会因线程亲和性静默失败，同时 UE4 原 `WndProc` 会吞掉 `WM_IME_CHAR`。
- **纯系统原生候选窗（不提供自绘兜底）**：实现最简单，但在独占全屏或部分第三方输入法/Steam 覆盖层叠加场景下，系统原生候选框可能被游戏交换链遮挡导致盲打。
- **全程强制屏蔽系统窗口、统一由 ImGui 自绘候选条**：视觉风格统一且不受全屏影响，但在 Grounded 默认的无边框全屏模式下会丢失微软拼音、微信输入法、搜狗等自带皮肤、云候选与短语体验，且部分独立外挂式输入法不暴露完整候选列表。

## Consequences

- 仅当菜单内任意输入框获焦时临时唤醒输入法，保持系统当前中英文状态不强切；离开输入框或关闭菜单立即还原禁用状态，避免正常游玩按 `WASD` / `E` / `M` 时误弹中文候选框。
- 中文组词期间拦截并消化 `Esc` 优先取消当前组词，避免误关闭整个 Mod 菜单。
- 提供可持久化的「输入法候选框模式（自动 / 强制系统原生 / 强制内置自绘）」切换选项，兼顾默认开箱即用与特殊输入法/全屏环境兜底。
