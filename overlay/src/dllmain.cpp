/*
 * 文件：overlay/src/dllmain.cpp
 * 职责：GroundedQoLOverlay.dll 入口模块与导出符号定义。
 * 线程与加载约束：
 *   - Windows Loader Lock 期间禁止直接加载 D3D/DXGI 模块或安装 MinHook 钩子，
 *     因此 DllMain(DLL_PROCESS_ATTACH) 仅拉起独立后台线程 InitThreadProc 执行初始化。
 *   - GroundedQoL_Bootstrap 供 UE4SS Lua 通过 package.loadlib 触发加载；
 *     GroundedQoL_QueryTestState 供离线自动化回归测试宿主查询后端与渲染状态。
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

/// 独立初始化线程：脱离 Windows Loader Lock 后初始化 IPC、重置当次日志并安装 DX12/DX11 钩子。
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
/// 位定义：bit0=DX12 已激活, bit1=DX11 已激活, bit2=菜单已打开, bit3=M 地图本帧已绘制有效标点。
extern "C" __declspec(dllexport) int __cdecl GroundedQoL_QueryTestState() {
    int flags = 0;
    const char* api = gqol::GetActiveGraphicsBackend();
    if (api && api[0] == 'D' && api[2] == '1' && api[3] == '2') flags |= 1; // DX12
    if (api && api[0] == 'D' && api[2] == '1' && api[3] == '1') flags |= 2; // DX11
    if (gqol::IsMenuOpen()) flags |= 4;
    if (gqol::GetLastRenderedMapPinCount() > 0) flags |= 8;
    return flags;
}

/// DLL 生命周期入口：Attach 时保证只拉起一次初始化线程，Detach 时安全卸载图形钩子。
BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID /*reserved*/) {
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
        gqol::UninstallGraphicsHook();
    }
    return TRUE;
}
