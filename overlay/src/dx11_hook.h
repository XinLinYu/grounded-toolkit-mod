/*
 * 文件：overlay/src/dx11_hook.h
 * 职责：声明自适应 DirectX 12 / DirectX 11 图形钩子、窗口主线程混合 IME/TSF 管理、
 *       单一系统光标零干扰托管、空闲渲染直通以及诊断日志接口。
 * 说明：文件名沿用 dx11_hook.h 历史命名，内部完整支持 DX12（优先）与 DX11（自动回退）双后端。
 */

#pragma once

#include <Windows.h>
#include <string>
#include <vector>

namespace gqol {

/// 窗口线程与渲染线程共享的实时输入法组词与候选字快照（见 ADR-0003）。
struct ImeCandidateState {
    bool active = false;                 ///< 当前窗口线程是否已为聚焦的 ImGui 输入框临时启用 IME
    bool composing = false;              ///< 是否处于拼音/中文组词状态（用于 Esc 防误关与候选条显示）
    bool useSelfDrawnUi = false;         ///< 是否启用 ImGui 内置自绘候选条（独占全屏或手动指定）
    bool isExclusiveFullscreen = false;  ///< 当前 SwapChain 是否处于 DXGI 独占全屏状态
    std::string compositionUtf8;         ///< 当前正在输入的拼音/组词文本（UTF-8）
    int cursorByteOffset = 0;            ///< 组词光标在 compositionUtf8 中的字节偏移
    std::vector<std::string> candidates; ///< 当前页候选字列表（UTF-8）
    int selectedIndex = 0;               ///< 当前页内高亮选中的候选索引（0-based）
    int pageStart = 0;                   ///< 当前页首项在全部候选中的绝对偏移
    int totalCandidates = 0;             ///< 候选词总数
    float inputPosX = 0.0f;              ///< 聚焦输入框的光标 X（客户区坐标）
    float inputPosY = 0.0f;              ///< 聚焦输入框的光标 Y（客户区坐标）
    float inputLineHeight = 20.0f;       ///< 聚焦输入框行高
};

/// 安装 DX12 / DX11 自适应图形钩子（Present / Present1 / ResizeBuffers / ExecuteCommandLists / WndProc）。
bool InstallGraphicsHook();

/// 卸载全部钩子、还原窗口状态并释放 ImGui 与 DX12/DX11 图形资源。
/// @param processTerminating 若在 DllMain(DLL_PROCESS_DETACH) 进程退出路径调用，跳过可能阻塞的 GPU/线程等待。
void UninstallGraphicsHook(bool processTerminating = false);

/// 线程安全查询当前 Mod 悬浮菜单是否处于打开状态。
bool IsMenuOpen();

/// 线程安全设置 Mod 悬浮菜单的显示/隐藏状态。
void SetMenuOpen(bool open);

/// 获取当前激活的图形渲染后端名称（"DX12" / "DX11" / "Unknown"）。
const char* GetActiveGraphicsBackend();

/// 获取当前挂钩的游戏主窗口句柄（用于客户区坐标换算与被动光标读取）。
HWND GetGameHwnd();

/// 获取当前输入法组词与候选字状态快照（供 overlay_ui 绘制自绘候选条及状态展示）。
ImeCandidateState GetImeCandidateState();

/// 在内置自绘候选条中点击候选字时，投递到窗口主线程通知 IMM 选中对应候选项。
void SelectImeCandidateByPageIndex(int pageIdx);

/// 查询最近一帧是否命中了空闲零开销直通路径（供自动化回归测试验证 ADR-0004）。
bool WasLastFrameIdlePassThrough();

/// 获取离线回归测试所需的运行期统计计数。
void GetTestMetrics(unsigned long long* outIdleFrames,
                    unsigned long long* outRenderedFrames,
                    int* outImeCharCount);

/// 测试辅助：将启动横幅计时提前过期，便于测试即时验证空闲直通路径。
void ForceExpireStartupBannerForTest();

/// 测试辅助：模拟 ImGui 输入框获焦/失焦，触发窗口主线程 IME 同步消息。
void ForceWantTextInputForTest(bool want, float x, float y);

/// 线程安全写入悬浮层运行诊断日志到 data/overlay.log（printf 风格格式化）。
void OverlayLog(const char* fmt, ...);

} // namespace gqol
