/*
 * 文件：overlay/src/dllmain.cpp
 * 职责：GroundedQoLOverlay.dll 入口模块与导出符号定义。
 * 线程与加载约束：
 *   - Windows Loader Lock 期间禁止直接加载 D3D/DXGI 模块或安装 MinHook 钩子，
 *     因此 DllMain(DLL_PROCESS_ATTACH) 仅拉起独立后台线程 InitThreadProc 执行初始化。
 *   - DLL_PROCESS_DETACH 时根据 reserved 区分显式 FreeLibrary 与进程退出，防止进程退出阶段 join 线程死锁。
 *   - GroundedQoL_Bootstrap 供 UE4SS Lua 通过 package.loadlib 触发加载；
 *     GroundedQoL_QueryTestState 与辅助测试导出符号供离线自动化回归测试验证全部业务规则。
 */

#include "dx11_hook.h"
#include "ipc.h"
#include "overlay_ui.h"

#include <Windows.h>
#include <atomic>
#include <string>

namespace {

HMODULE g_selfModule = nullptr;
std::atomic<bool> g_started{false};

/// 查询当前 DLL 所在绝对目录（不含末尾分隔符），用于定位同级 data/ 通信目录。
std::wstring GetDllDirectory(HMODULE mod) {
    wchar_t buf[MAX_PATH * 2]{};
    DWORD len = GetModuleFileNameW(mod, buf, static_cast<DWORD>(std::size(buf)));
    std::wstring full(buf, len);
    size_t pos = full.find_last_of(L"\\/");
    return (pos == std::wstring::npos) ? L"." : full.substr(0, pos);
}

/// 独立初始化线程：脱离 Windows Loader Lock 后初始化异步 IPC、重置当次日志并安装 DX12/DX11 钩子。
DWORD WINAPI InitThreadProc(LPVOID) {
    std::wstring dir = GetDllDirectory(g_selfModule);
    gqol::IpcBridge::Instance().Initialize(dir);
    // 每次进程启动清空旧的 overlay.log，确保日志仅反映本次运行期的诊断信息
    DeleteFileW((dir + L"\\data\\overlay.log").c_str());
    gqol::OverlayLog("GroundedQoLOverlay.dll initialized in PID=%lu", GetCurrentProcessId());
    gqol::InstallGraphicsHook();
    return 0;
}

} // namespace

/// 供 UE4SS Lua 通过 package.loadlib 触发 LoadLibraryA 的轻量引导导出符号。
extern "C" __declspec(dllexport) int __cdecl GroundedQoL_Bootstrap(void*) {
    return 0;
}

/// 供自动化回归测试查询当前激活图形后端与渲染状态的位掩码导出函数。
/// 位定义：
///   bit0 = DX12 已激活
///   bit1 = DX11 已激活
///   bit2 = 菜单已打开
///   bit3 = M 地图本帧已绘制有效标点
///   bit4 = 最近一帧走了空闲零开销直通路径（跳过 DX12/DX11 提交）
///   bit5 = 当前窗口线程 IME 已启用
///   bit6 = 当前处于中文输入法组词中
///   bit7 = 当前自绘候选条模式生效
///   bit8 = 最近一帧顶层前景自绘候选条已实际绘制
extern "C" __declspec(dllexport) int __cdecl GroundedQoL_QueryTestState() {
    int flags = 0;
    const char* api = gqol::GetActiveGraphicsBackend();
    if (api && api[0] == 'D' && api[2] == '1' && api[3] == '2') flags |= (1 << 0);
    if (api && api[0] == 'D' && api[2] == '1' && api[3] == '1') flags |= (1 << 1);
    if (gqol::IsMenuOpen()) flags |= (1 << 2);
    if (gqol::GetLastRenderedMapPinCount() > 0) flags |= (1 << 3);
    if (gqol::WasLastFrameIdlePassThrough()) flags |= (1 << 4);
    auto ime = gqol::GetImeCandidateState();
    if (ime.active) flags |= (1 << 5);
    if (ime.composing) flags |= (1 << 6);
    if (ime.useSelfDrawnUi) flags |= (1 << 7);
    if (gqol::WasSelfDrawnImeBarRenderedLastFrame()) flags |= (1 << 8);
    return flags;
}

/// 供自动化回归测试读取运行期统计指标（空闲直通帧数、完整渲染帧数、自定义测试辅助）。
extern "C" __declspec(dllexport) void __cdecl GroundedQoL_QueryTestMetrics(
    unsigned long long* outIdleFrames,
    unsigned long long* outRenderedFrames,
    int* outImeCharCount) {
    gqol::GetTestMetrics(outIdleFrames, outRenderedFrames, outImeCharCount);
}

/// 供自动化回归测试强制跳过开场 10 秒提示条，以即时验证空闲零开销直通路径。
extern "C" __declspec(dllexport) void __cdecl GroundedQoL_TestExpireStartupBanner() {
    gqol::ForceExpireStartupBannerForTest();
}

/// 供自动化回归测试直接驱动输入框获焦态以验证窗口线程 IME 激活与还原行为。
extern "C" __declspec(dllexport) void __cdecl GroundedQoL_TestSetWantTextInput(int want, float x, float y) {
    gqol::ForceWantTextInputForTest(want != 0, x, y);
}

/// 供自动化回归测试注入自绘候选列表并验证顶层前景渲染与零抢焦鼠标点击。
extern "C" __declspec(dllexport) void __cdecl GroundedQoL_TestInjectImeCandidates(
    const char* compositionUtf8, const char* const* candidates, int count) {
    gqol::ForceInjectImeCandidatesForTest(compositionUtf8, candidates, count);
}

/// 供自动化回归测试查询最近一次被鼠标点击选中的候选字页内索引（-1 表示未点击）。
extern "C" __declspec(dllexport) int __cdecl GroundedQoL_TestGetLastClickedCandidate() {
    return gqol::GetLastClickedImeCandidateForTest();
}

/// DLL 生命周期入口：Attach 时保证只拉起一次初始化线程，Detach 时安全卸载图形钩子与异步 IPC 线程。
BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID reserved) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hModule);
        g_selfModule = hModule;
        if (!g_started.exchange(true)) {
            HANDLE hThread = CreateThread(nullptr, 0, InitThreadProc, nullptr, 0, nullptr);
            if (hThread) {
                CloseHandle(hThread);
            }
        }
    } else if (reason == DLL_PROCESS_DETACH) {
        const bool processTerminating = (reserved != nullptr);
        gqol::UninstallGraphicsHook(processTerminating);
        gqol::IpcBridge::Instance().Shutdown(processTerminating);
    }
    return TRUE;
}
