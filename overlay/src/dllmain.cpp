#include "dx11_hook.h"
#include "ipc.h"
#include "overlay_ui.h"

#include <Windows.h>
#include <atomic>
#include <string>

namespace {

HMODULE g_selfModule = nullptr;
std::atomic<bool> g_started{false};

std::wstring GetDllDirectory(HMODULE mod) {
    wchar_t buf[MAX_PATH * 2]{};
    DWORD len = GetModuleFileNameW(mod, buf, static_cast<DWORD>(std::size(buf)));
    std::wstring full(buf, len);
    size_t pos = full.find_last_of(L"\\/");
    return (pos == std::wstring::npos) ? L"." : full.substr(0, pos);
}

DWORD WINAPI InitThreadProc(LPVOID) {
    std::wstring dir = GetDllDirectory(g_selfModule);
    gqol::IpcBridge::Instance().Initialize(dir);
    // 每次进程启动清空旧的 overlay.log，确保日志反映当次运行状态
    DeleteFileW((dir + L"\\data\\overlay.log").c_str());
    gqol::OverlayLog("GroundedQoLOverlay.dll initialized in PID=%lu", GetCurrentProcessId());
    gqol::InstallGraphicsHook();
    return 0;
}

} // namespace

/// 供 UE4SS Lua 通过 package.loadlib 触发加载的导出符号。
extern "C" __declspec(dllexport) int __cdecl GroundedQoL_Bootstrap(void*) {
    return 0;
}

/// 供自动化回归测试查询当前菜单状态与图形后端的诊断导出函数。
extern "C" __declspec(dllexport) int __cdecl GroundedQoL_QueryTestState() {
    int flags = 0;
    const char* api = gqol::GetActiveGraphicsBackend();
    if (api && api[0] == 'D' && api[2] == '1' && api[3] == '2') flags |= 1; // DX12
    if (api && api[0] == 'D' && api[2] == '1' && api[3] == '1') flags |= 2; // DX11
    if (gqol::IsMenuOpen()) flags |= 4;
    if (gqol::GetLastRenderedMapPinCount() > 0) flags |= 8;
    return flags;
}

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
