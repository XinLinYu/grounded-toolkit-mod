/*
 * 文件：overlay/tests/overlay_regression_test.cpp
 * 职责：GroundedQoLOverlay.dll 离线自动化回归测试宿主程序（真实 DX12 / DX11 SwapChain）。
 * 验证项：
 *   1. DLL 加载后自动写出默认 data/config.json，包含死亡保护字段与 imeCandidateMode=0；
 *   2. MinHook 正确拦截 Present / Present1 / ResizeBuffers / ExecuteCommandLists 并自动识别 DX12 / DX11；
 *   3. 模拟 UE 4.27 精确内存布局的 UWidget->SWidget->FGeometry，验证旋转/缩放下 M 地图标点 0.00px 投影误差；
 *   4. 光标零干扰不变量（ADR-0004 / Q3 / Q8）：
 *      - 菜单关闭时 WM_SETCURSOR / 鼠标事件原样透传给 UE4，绝不被 ImGui 篡改光标或 SetCapture 引发闪烁；
 *      - 菜单打开时托管单一系统原生光标并吞掉游戏鼠标事件；Alt+Tab 失焦不关菜单但临时让出光标/IME；
 *      - 菜单关闭瞬间主动派发 WM_SETCURSOR 交还 UE4 隐藏光标。
 *   5. 窗口主线程混合中文输入法（ADR-0003 / Q1 / Q2 / Q6）：
 *      - 模拟 UE4 启动禁用窗口 HIMC；开菜单未聚焦文本框时保持禁用；聚焦输入框后在窗口线程按需恢复 HIMC；
 *      - 组词期按 Esc 仅取消组词不关菜单；WM_IME_CHAR 中文字符正确进入 ImGui 不被吞；失焦后精确还原禁用态；
 *      - DX11 用例验证预置 imeCandidateMode=2（强制内置自绘）持久化加载与生效标志。
 *   6. 空闲零开销直通与打开菜单自动软刷新（ADR-0004 / Q5 / Q9）：
 *      - 菜单关闭 + M 地图关闭 + 开场横幅过期后 Present 走零开销直通路径，不增加完整渲染帧数；
 *      - 打开菜单超过冷却后自动推送 refresh_catalog_soft 指令。
 *   7. ResizeBuffers（Alt+Tab / 分辨率切换）安全重建后缓冲无崩溃，房主与联机客机 UI 渲染正常。
 */

#include <Windows.h>
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <imm.h>
#include <msctf.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>

#pragma comment(lib, "imm32")
#pragma comment(lib, "ole32")

using QueryStateFn = int(__cdecl*)();
using QueryMetricsFn = void(__cdecl*)(unsigned long long*, unsigned long long*, int*);
using VoidTestFn = void(__cdecl*)();
using SetWantTextFn = void(__cdecl*)(int, float, float);
using InjectImeCandFn = void(__cdecl*)(const char*, const char* const*, int);
using GetClickedCandFn = int(__cdecl*)();

static int g_origSetCursorCalls = 0;
static int g_origMouseDownCalls = 0;
static int g_origMouseMoveCalls = 0;
static bool g_simUe4HideCursor = true;

/// 模拟 UE4 游戏主窗口消息回调（在游玩状态下于 WM_SETCURSOR 调用 SetCursor(NULL) 隐藏光标）。
static LRESULT CALLBACK TestWndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_SETCURSOR) {
        g_origSetCursorCalls++;
        if (g_simUe4HideCursor && LOWORD(lParam) == HTCLIENT) {
            ::SetCursor(nullptr);
            return TRUE;
        }
    } else if (msg == WM_LBUTTONDOWN) {
        g_origMouseDownCalls++;
        return 0;
    } else if (msg == WM_MOUSEMOVE) {
        g_origMouseMoveCalls++;
        return 0;
    } else if (msg == WM_IME_CHAR) {
        // 模拟 UE4 原窗口过程会吞掉 WM_IME_CHAR（若 HookedWndProc 漏拦截并透传下来，中文输入会彻底丢失）
        return 0;
    }
    return DefWindowProcW(hWnd, msg, wParam, lParam);
}

struct MockRefCtrl {
    uint64_t vtable = 0;
    int32_t strongCount = 2;
    int32_t weakCount = 2;
};

struct MockUeFGeometry {
    float sizeX = 0, sizeY = 0;
    float scale = 1.0f;
    float absPosX = 0, absPosY = 0;
    float localPosX = 0, localPosY = 0;
    float m00 = 1, m01 = 0, m10 = 0, m11 = 1;
    float transX = 0, transY = 0;
    uint8_t bHasRenderTransform = 1;
    uint8_t pad[3]{};
};
static_assert(sizeof(MockUeFGeometry) == 0x38, "MockUeFGeometry must be 0x38 bytes");

struct alignas(16) MockSWidget {
    uint8_t pad0[0xD0]{};
    MockUeFGeometry cachedGeom{};
};
static_assert(offsetof(MockSWidget, cachedGeom) == 0xD0, "cachedGeom offset must be 0xD0");

struct alignas(16) MockUWidget {
    uint8_t pad0[0xE0]{};
    MockSWidget* gcWidget = nullptr;
    MockRefCtrl* gcRefCtrl = nullptr;
    MockSWidget* myWidget = nullptr;
    MockRefCtrl* myRefCtrl = nullptr;
    uint8_t pad1[0x10]{};
};
static_assert(offsetof(MockUWidget, gcWidget) == 0xE0, "gcWidget offset must be 0xE0");
static_assert(offsetof(MockUWidget, myWidget) == 0xF0, "myWidget offset must be 0xF0");

struct alignas(16) MockMapPanel {
    uint8_t pad0[0x3A0]{};
    float maxBoundsX = 80000.0f;
    float maxBoundsY = 80000.0f;
    float minBoundsX = -80000.0f;
    float minBoundsY = -80000.0f;
    float texSizeX = 2048.0f;
    float texSizeY = 2048.0f;
    uint8_t pad1[0x90]{};
};

struct NativeMapMockFixture {
    MockRefCtrl refCtrl;
    MockSWidget sCanvas, sBorder, sRootWin, sPlayerIcon;
    MockUWidget uCanvas, uBorder, uRootWin, uPlayerIcon;
    MockMapPanel panel;

    NativeMapMockFixture() {
        sRootWin.cachedGeom.sizeX = 1280.0f;
        sRootWin.cachedGeom.sizeY = 720.0f;
        sRootWin.cachedGeom.m00 = 1.0f;
        sRootWin.cachedGeom.m11 = 1.0f;
        sRootWin.cachedGeom.transX = 100.0f;
        sRootWin.cachedGeom.transY = 50.0f;
        uRootWin.gcWidget = &sRootWin;
        uRootWin.gcRefCtrl = &refCtrl;

        sBorder.cachedGeom.sizeX = 1280.0f;
        sBorder.cachedGeom.sizeY = 660.0f;
        sBorder.cachedGeom.m00 = 1.0f;
        sBorder.cachedGeom.m11 = 1.0f;
        sBorder.cachedGeom.transX = 100.0f;
        sBorder.cachedGeom.transY = 110.0f;
        uBorder.myWidget = &sBorder;
        uBorder.myRefCtrl = &refCtrl;

        sCanvas.cachedGeom.sizeX = 2048.0f;
        sCanvas.cachedGeom.sizeY = 2048.0f;
        sCanvas.cachedGeom.m00 = 0.0f;
        sCanvas.cachedGeom.m01 = 0.5f;
        sCanvas.cachedGeom.m10 = -0.5f;
        sCanvas.cachedGeom.m11 = 0.0f;
        sCanvas.cachedGeom.transX = 1252.0f;
        sCanvas.cachedGeom.transY = -102.0f;
        uCanvas.myWidget = &sCanvas;
        uCanvas.myRefCtrl = &refCtrl;

        sPlayerIcon.cachedGeom.sizeX = 24.0f;
        sPlayerIcon.cachedGeom.sizeY = 24.0f;
        sPlayerIcon.cachedGeom.m00 = 1.0f;
        sPlayerIcon.cachedGeom.m11 = 1.0f;
        sPlayerIcon.cachedGeom.transX = 842.4f - 12.0f;
        sPlayerIcon.cachedGeom.transY = 512.4f - 12.0f;
        uPlayerIcon.gcWidget = &sPlayerIcon;
        uPlayerIcon.gcRefCtrl = &refCtrl;
    }
};

static void WriteNativeSlateMapData(const std::wstring& dataDir, const NativeMapMockFixture& fx) {
    CreateDirectoryW(dataDir.c_str(), nullptr);
    char buf[2048];
    std::snprintf(buf, sizeof(buf),
        "{\n"
        "  \"mapOpen\": true,\n"
        "  \"hasTransform\": false,\n"
        "  \"vpW\": 1280, \"vpH\": 720,\n"
        "  \"panelAddr\": \"0x%llX\",\n"
        "  \"canvasAddr\": \"0x%llX\",\n"
        "  \"fallbackCanvasAddr\": \"0x%llX\",\n"
        "  \"borderAddr\": \"0x%llX\",\n"
        "  \"rootWinAddr\": \"0x%llX\",\n"
        "  \"playerIconAddr\": \"0x%llX\",\n"
        "  \"minBoundsX\": -80000, \"minBoundsY\": -80000,\n"
        "  \"maxBoundsX\": 80000, \"maxBoundsY\": 80000,\n"
        "  \"texSizeX\": 2048, \"texSizeY\": 2048,\n"
        "  \"hasPlayerPos\": true, \"playerX\": 16000, \"playerY\": -16000, \"playerZ\": 0,\n"
        "  \"pins\": [\n"
        "    {\"id\":\"__molar\",\"n\":\"普通乳牙\",\"cat\":\"collectible\",\"x\":16000,\"y\":-16000,\"z\":100,\"c\":-1,\"col\":false},\n"
        "    {\"id\":\"__megamolar\",\"n\":\"高级乳牙 (巨型)\",\"cat\":\"collectible\",\"x\":-20000,\"y\":15000,\"z\":-500,\"c\":-2,\"col\":false},\n"
        "    {\"id\":\"item:FoodMint\",\"n\":\"薄荷碎片\",\"cat\":\"item\",\"x\":0,\"y\":0,\"z\":50,\"c\":0,\"col\":false}\n"
        "  ]\n"
        "}\n",
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&fx.panel)),
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&fx.uCanvas)),
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&fx.uCanvas)),
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&fx.uBorder)),
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&fx.uRootWin)),
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&fx.uPlayerIcon)));

    std::ofstream ofs(dataDir + L"\\map_live.json", std::ios::binary | std::ios::trunc);
    ofs << buf;
}

static void WriteMapClosedData(const std::wstring& dataDir) {
    CreateDirectoryW(dataDir.c_str(), nullptr);
    std::ofstream ofs(dataDir + L"\\map_live.json", std::ios::binary | std::ios::trunc);
    ofs << "{\"mapOpen\":false}\n";
}

static void WriteMockStatusData(const std::wstring& dataDir, bool isHost, bool liveKeepInv, bool liveNoDurPen) {
    CreateDirectoryW(dataDir.c_str(), nullptr);
    char buf[1024];
    std::snprintf(buf, sizeof(buf),
        "{\n"
        "  \"inWorld\": true,\n"
        "  \"isHost\": %s,\n"
        "  \"difficulty\": \"中等 (Medium)\",\n"
        "  \"livePlayerDamage\": 1.5,\n"
        "  \"liveEnemyDamage\": 1.0,\n"
        "  \"liveKeepInventoryOnDeath\": %s,\n"
        "  \"liveNoDeathDurabilityPenalty\": %s,\n"
        "  \"uncollectedMilkMolars\": 40,\n"
        "  \"uncollectedMegaMolars\": 20,\n"
        "  \"totalMilkMolars\": 74,\n"
        "  \"totalMegaMolars\": 45,\n"
        "  \"catalogCount\": 120,\n"
        "  \"lootCompCount\": 85,\n"
        "  \"stackSummary\": \"Resource:10->100\",\n"
        "  \"surveyedItemName\": \"\",\n"
        "  \"lastMessage\": \"回归测试模拟状态\"\n"
        "}\n",
        isHost ? "true" : "false",
        liveKeepInv ? "true" : "false",
        liveNoDurPen ? "true" : "false");

    std::ofstream ofs(dataDir + L"\\status.json", std::ios::binary | std::ios::trunc);
    ofs << buf;
}

static std::string ReadTextFile(const std::wstring& path) {
    std::ifstream ifs(path, std::ios::binary);
    std::ostringstream ss;
    ss << ifs.rdbuf();
    return ss.str();
}

static void PumpMessages() {
    MSG m{};
    while (PeekMessageW(&m, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&m);
        DispatchMessageW(&m);
    }
}

/// DX12 全流程回归测试：配置初始化 + 图形挂钩 + 0 像素误差地图投影 + 光标零干扰 + 窗口线程混合 IME + 空闲零开销直通 + ResizeBuffers。
static int RunDx12Test(const std::wstring& dllPath) {
    size_t slash = dllPath.find_last_of(L"\\/");
    std::wstring dataDir = dllPath.substr(0, slash) + L"\\data";
    DeleteFileW((dataDir + L"\\config.json").c_str());
    DeleteFileW((dataDir + L"\\actions.json").c_str());

    std::printf("[TEST-DX12] Loading DLL...\n");
    HMODULE mod = LoadLibraryW(dllPath.c_str());
    if (!mod) {
        std::printf("[FAIL] LoadLibraryW failed: %lu\n", GetLastError());
        return 1;
    }
    auto queryState = reinterpret_cast<QueryStateFn>(GetProcAddress(mod, "GroundedQoL_QueryTestState"));
    auto queryMetrics = reinterpret_cast<QueryMetricsFn>(GetProcAddress(mod, "GroundedQoL_QueryTestMetrics"));
    auto expireBanner = reinterpret_cast<VoidTestFn>(GetProcAddress(mod, "GroundedQoL_TestExpireStartupBanner"));
    auto setWantText = reinterpret_cast<SetWantTextFn>(GetProcAddress(mod, "GroundedQoL_TestSetWantTextInput"));
    auto injectIme = reinterpret_cast<InjectImeCandFn>(GetProcAddress(mod, "GroundedQoL_TestInjectImeCandidates"));
    auto getClickedCand = reinterpret_cast<GetClickedCandFn>(GetProcAddress(mod, "GroundedQoL_TestGetLastClickedCandidate"));
    if (!queryState || !queryMetrics || !expireBanner || !setWantText || !injectIme || !getClickedCand) {
        std::printf("[FAIL] Missing test exports in DLL\n");
        return 2;
    }

    NativeMapMockFixture fixture;
    WriteNativeSlateMapData(dataDir, fixture);
    WriteMockStatusData(dataDir, true, true, false);

    Sleep(800);

    // 1. 断言默认配置包含死亡保护与 imeCandidateMode=0
    {
        std::string cfgText = ReadTextFile(dataDir + L"\\config.json");
        if (cfgText.find("\"keepInventoryOnDeath\": false") == std::string::npos ||
            cfgText.find("\"noDeathDurabilityPenalty\": false") == std::string::npos ||
            cfgText.find("\"imeCandidateMode\": 0") == std::string::npos) {
            std::printf("[FAIL] Default config.json missing expected fields!\nContent:\n%s\n", cfgText.c_str());
            return 20;
        }
        std::printf("[TEST-DX12] Verified default config fields (death protection + imeCandidateMode=0)\n");
    }

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = TestWndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"GQOL_DX12_RegressionHost";
    RegisterClassExW(&wc);

    HWND hwnd = CreateWindowExW(0, wc.lpszClassName, L"GQOL DX12 Test",
                                WS_OVERLAPPEDWINDOW, 100, 100, 1280, 720,
                                nullptr, nullptr, wc.hInstance, nullptr);
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);

    // 模拟 UE4 FWindowsTextInputMethodSystem 同时通过 TSF 空禁用文档管理器 + IMM 禁用窗口输入法
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ITfThreadMgr* tsfMgr = nullptr;
    ITfDocumentMgr* ue4DisabledDoc = nullptr;
    ITfDocumentMgr* origCuasDoc = nullptr;
    TfClientId tsfClientId = TF_CLIENTID_NULL;
    if (SUCCEEDED(CoCreateInstance(CLSID_TF_ThreadMgr, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&tsfMgr))) && tsfMgr) {
        tsfMgr->Activate(&tsfClientId);
        if (SUCCEEDED(tsfMgr->CreateDocumentMgr(&ue4DisabledDoc)) && ue4DisabledDoc) {
            tsfMgr->AssociateFocus(hwnd, ue4DisabledDoc, &origCuasDoc);
        }
    }
    ::ImmAssociateContextEx(hwnd, nullptr, 0);
    if (HIMC initCheck = ::ImmGetContext(hwnd)) {
        ::ImmReleaseContext(hwnd, initCheck);
        std::printf("[FAIL] Failed to simulate UE4 IME detach before test!\n");
        return 21;
    }

    IDXGIFactory4* factory = nullptr;
    ID3D12Device* dev = nullptr;
    ID3D12CommandQueue* queue = nullptr;
    IDXGISwapChain1* swap1 = nullptr;
    IDXGISwapChain3* swap3 = nullptr;
    ID3D12CommandAllocator* alloc = nullptr;
    ID3D12GraphicsCommandList* cmdList = nullptr;
    ID3D12Fence* fence = nullptr;
    HANDLE fenceEvt = CreateEventW(nullptr, FALSE, FALSE, nullptr);

    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))) ||
        FAILED(D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&dev)))) {
        std::printf("[FAIL] Failed to create DX12 device\n");
        return 3;
    }

    D3D12_COMMAND_QUEUE_DESC qd{};
    qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    if (FAILED(dev->CreateCommandQueue(&qd, IID_PPV_ARGS(&queue)))) return 4;

    DXGI_SWAP_CHAIN_DESC1 sd{};
    sd.BufferCount = 2;
    sd.Width = 1280;
    sd.Height = 720;
    sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    sd.SampleDesc.Count = 1;

    if (FAILED(factory->CreateSwapChainForHwnd(queue, hwnd, &sd, nullptr, nullptr, &swap1))) return 5;
    swap1->QueryInterface(IID_PPV_ARGS(&swap3));

    dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&alloc));
    dev->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, nullptr, IID_PPV_ARGS(&cmdList));
    cmdList->Close();
    dev->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence));

    UINT64 fval = 0;
    auto pumpAndPresent = [&](int frames) -> bool {
        for (int i = 0; i < frames; ++i) {
            PumpMessages();
            alloc->Reset();
            cmdList->Reset(alloc, nullptr);
            cmdList->Close();
            ID3D12CommandList* lists[] = {cmdList};
            queue->ExecuteCommandLists(1, lists);

            HRESULT hr = swap3->Present(0, 0);
            if (FAILED(hr)) {
                std::printf("[FAIL] DX12 Present failed: 0x%08lX\n", hr);
                return false;
            }
            fval++;
            queue->Signal(fence, fval);
            if (fence->GetCompletedValue() < fval) {
                fence->SetEventOnCompletion(fval, fenceEvt);
                WaitForSingleObject(fenceEvt, 1000);
            }
            Sleep(16);
        }
        return true;
    };

    if (!pumpAndPresent(8)) return 10;

    int st1 = queryState();
    std::printf("[TEST-DX12] After 8 frames state=0x%X (expect bit0=DX12, bit3=MapPinsRendered)\n", st1);
    if ((st1 & 1) == 0) {
        std::printf("[FAIL] Overlay did NOT initialize DX12 backend!\n");
        return 11;
    }
    if ((st1 & 8) == 0) {
        std::printf("[FAIL] NativeSlateFGeometry map projection did NOT render any pins!\n");
        return 18;
    }

    // 2. 验证 0.00px 投影精度
    {
        std::string logText = ReadTextFile(dataDir + L"\\overlay.log");
        if (logText.find("NativeSlateFGeometry") == std::string::npos ||
            logText.find("playerErr=0.00px") == std::string::npos) {
            std::printf("[FAIL] overlay.log did not confirm 0.00px NativeSlateFGeometry accuracy!\nLog:\n%s\n", logText.c_str());
            return 19;
        }
        std::printf("[TEST-DX12] Verified NativeSlateFGeometry playerErr=0.00px\n");
    }

    // 3. 验证菜单关闭时的零光标干扰不变量（ADR-0004 / Issue #2）
    {
        int prevSetCur = g_origSetCursorCalls;
        int prevMouseDown = g_origMouseDownCalls;
        int prevMouseMove = g_origMouseMoveCalls;
        ::SetCursor(::LoadCursorW(nullptr, IDC_IBEAM)); // 故意先设一个非空光标
        SendMessageW(hwnd, WM_SETCURSOR, reinterpret_cast<WPARAM>(hwnd), MAKELPARAM(HTCLIENT, WM_MOUSEMOVE));
        SendMessageW(hwnd, WM_MOUSEMOVE, 0, MAKELPARAM(300, 300));
        SendMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(300, 300));

        if (g_origSetCursorCalls != prevSetCur + 1 || ::GetCursor() != nullptr) {
            std::printf("[FAIL] Menu-closed WM_SETCURSOR was interfered with! origCalls=%d->%d cursor=%p\n",
                        prevSetCur, g_origSetCursorCalls, ::GetCursor());
            return 30;
        }
        if (g_origMouseDownCalls != prevMouseDown + 1 || g_origMouseMoveCalls != prevMouseMove + 1 || ::GetCapture() != nullptr) {
            std::printf("[FAIL] Menu-closed mouse events or capture were interfered with! down=%d->%d move=%d->%d cap=%p\n",
                        prevMouseDown, g_origMouseDownCalls, prevMouseMove, g_origMouseMoveCalls, ::GetCapture());
            return 31;
        }
        std::printf("[TEST-DX12] Verified menu-closed ZERO cursor/capture interference!\n");
    }

    // 4. 验证空闲零开销直通路径（ADR-0004 / Issue #3）
    {
        WriteMapClosedData(dataDir);
        expireBanner();
        Sleep(150); // 等待后台异步 IPC 线程同步 mapOpen=false
        if (!pumpAndPresent(3)) return 32;

        unsigned long long idleBefore = 0, renderedBefore = 0;
        int imeChars0 = 0;
        queryMetrics(&idleBefore, &renderedBefore, &imeChars0);

        if (!pumpAndPresent(8)) return 33;

        unsigned long long idleAfter = 0, renderedAfter = 0;
        queryMetrics(&idleAfter, &renderedAfter, &imeChars0);
        int stIdle = queryState();
        std::printf("[TEST-DX12] Idle pass-through check: state=0x%X idle=%llu->%llu rendered=%llu->%llu\n",
                    stIdle, idleBefore, idleAfter, renderedBefore, renderedAfter);
        if ((stIdle & (1 << 4)) == 0 || (idleAfter - idleBefore) < 8 || renderedAfter != renderedBefore) {
            std::printf("[FAIL] Idle zero-overhead pass-through did NOT skip DX12 rendering!\n");
            return 34;
        }
        std::printf("[TEST-DX12] Verified DX12 idle zero-overhead pass-through!\n");
    }

    // 5. 按 Insert 首次打开 Mod 菜单：验证首次必显示光标、菜单期拦截 UE4 每帧 SetCursor(NULL)/ShowCursor(FALSE)/ClipCursor/SetCursorPos 零闪烁与自动软刷新（ADR-0004 / Q3 / Q9）
    // 先模拟 UE4 3D 游玩态下把光标藏起来（ShowCursor(FALSE) 循环 + SetCursor(NULL)）
    while (::ShowCursor(FALSE) >= 0) {}
    ::SetCursor(nullptr);

    SendMessageW(hwnd, WM_KEYDOWN, VK_INSERT, 0);
    if (!pumpAndPresent(6)) return 12;
    int st2 = queryState();
    if ((st2 & 4) == 0) {
        std::printf("[FAIL] Insert key did NOT open Mod menu!\n");
        return 13;
    }

    {
        int prevSetCur = g_origSetCursorCalls;
        int prevMouseDown = g_origMouseDownCalls;
        // 首次打开瞬间必须立即可见（未触发 WM_SETCURSOR 前也不应为 NULL）
        if (::GetCursor() == nullptr) {
            std::printf("[FAIL] First menu open cursor was NULL!\n");
            return 35;
        }
        // 模拟 UE4 FSlateApplication::Tick() 每帧直接调用 Win32 API 尝试隐藏/闪烁/锁框/拉回光标（30 次高频冲击）
        RECT ue4LockRect{200, 200, 260, 260};
        for (int iter = 0; iter < 30; ++iter) {
            ::SetCursor(nullptr);
            // 验证 UE4 风格的 while(::ShowCursor(FALSE) >= 0){} 立刻终止且不藏光标
            int guardLoops = 0;
            while (::ShowCursor(FALSE) >= 0 && guardLoops < 10) { guardLoops++; }
            if (guardLoops >= 10) {
                std::printf("[FAIL] HookedShowCursor caused UE4 ShowCursor(FALSE) loop hang!\n");
                return 35;
            }
            ::ClipCursor(&ue4LockRect);
            ::SetCursorPos(10, 10);
            if (::GetCursor() == nullptr) {
                std::printf("[FAIL] UE4 direct SetCursor(NULL) flickered/hid cursor during menu open at iter=%d!\n", iter);
                return 35;
            }
            RECT curClip{};
            if (::GetClipCursor(&curClip) && curClip.right - curClip.left <= 65 && curClip.bottom - curClip.top <= 65) {
                std::printf("[FAIL] UE4 ClipCursor locked mouse while Mod menu was open!\n");
                return 35;
            }
            SendMessageW(hwnd, WM_SETCURSOR, reinterpret_cast<WPARAM>(hwnd), MAKELPARAM(HTCLIENT, WM_MOUSEMOVE));
            if (::GetCursor() == nullptr) {
                std::printf("[FAIL] WM_SETCURSOR resulted in NULL cursor during menu open!\n");
                return 35;
            }
        }
        // 连续模拟完整鼠标点击（按下 -> SetCapture -> 抬起 -> ReleaseCapture 同步重入 WM_CAPTURECHANGED），
        // 严格回归防复发：此前非递归 mutex 会在此处同步重入并抛 std::system_error 闪退！
        SendMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(300, 300));
        SendMessageW(hwnd, WM_CAPTURECHANGED, 0, 0);
        SendMessageW(hwnd, WM_LBUTTONUP, 0, MAKELPARAM(300, 300));
        if (g_origSetCursorCalls != prevSetCur || ::GetCursor() == nullptr) {
            std::printf("[FAIL] Menu-open did NOT take over single OS cursor cleanly! origCalls=%d->%d cur=%p\n",
                        prevSetCur, g_origSetCursorCalls, ::GetCursor());
            return 35;
        }
        if (g_origMouseDownCalls != prevMouseDown) {
            std::printf("[FAIL] Menu-open leaked WM_LBUTTONDOWN to game!\n");
            return 36;
        }

        // 写入模拟大目录并模拟点击 Tab 2 区域，验证 Tab 2 渲染 + ImGuiListClipper + 完整点击链路无崩溃
        {
            std::ofstream catOfs(dataDir + L"\\catalog.json", std::ios::binary | std::ios::trunc);
            catOfs << "[";
            for (int ci = 0; ci < 200; ++ci) {
                if (ci > 0) catOfs << ",";
                catOfs << "{\"id\":\"item:TestItem" << ci << "\",\"name\":\"测试物品" << ci
                       << "\",\"rawName\":\"TestItem" << ci << "\",\"category\":\"item\",\"count\":"
                       << (ci + 1) << ",\"surveyable\":true,\"rowName\":\"TestItem" << ci << "\"}";
            }
            catOfs << "]";
        }
        Sleep(420); // 等待后台异步 IPC 线程加载 catalog.json
        // 点击菜单顶部第二标签页大约位置（窗口居中 1280x720，宽 800 高 700 -> 左上角 (240,10)，TabBar 约在 y=105, Tab2 x≈470）
        SendMessageW(hwnd, WM_MOUSEMOVE, 0, MAKELPARAM(470, 105));
        SendMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(470, 105));
        if (!pumpAndPresent(2)) return 36;
        SendMessageW(hwnd, WM_LBUTTONUP, 0, MAKELPARAM(470, 105));
        if (!pumpAndPresent(4)) return 36;

        // 等待后台异步写盘线程写出 refresh_catalog_soft
        Sleep(150);
        std::string actText = ReadTextFile(dataDir + L"\\actions.json");
        if (actText.find("refresh_catalog_soft") == std::string::npos) {
            std::printf("[FAIL] Opening menu did NOT trigger refresh_catalog_soft action! actions.json=%s\n", actText.c_str());
            return 37;
        }
        std::printf("[TEST-DX12] Verified menu-open OS cursor takeover, re-entrant click/capture safety, Tab 2 catalog render, and refresh_catalog_soft!\n");
    }

    // 6. 验证窗口主线程按需 IME 激活、组词期 Esc 防误关、WM_IME_CHAR 中文输入与失焦还原（ADR-0003 / Issue #1）
    {
        // 6a. 打开菜单但未点击输入框前，IME 仍保持 UE4 的禁用态（防跑图误触）
        if (HIMC beforeFocus = ::ImmGetContext(hwnd)) {
            ::ImmReleaseContext(hwnd, beforeFocus);
            std::printf("[FAIL] IME should remain detached before any textbox gets focus!\n");
            return 38;
        }

        // 6b. 模拟点击搜索框获焦 -> 窗口线程自动解绑 UE4 的 TSFDisabledDocumentManager 并恢复 CUAS/HIMC
        setWantText(1, 220.0f, 340.0f);
        PumpMessages();
        HIMC activeHimc = ::ImmGetContext(hwnd);
        int stIme = queryState();
        if (!activeHimc || (stIme & (1 << 5)) == 0) {
            if (activeHimc) ::ImmReleaseContext(hwnd, activeHimc);
            std::printf("[FAIL] Window-thread IME failed to activate on textbox focus! himc=%p state=0x%X\n",
                        activeHimc, stIme);
            return 39;
        }
        ::ImmReleaseContext(hwnd, activeHimc);
        if (tsfMgr && ue4DisabledDoc) {
            ITfDocumentMgr* curDoc = nullptr;
            ITfDocumentMgr* tmpDoc = nullptr;
            tsfMgr->AssociateFocus(hwnd, nullptr, &curDoc);
            if (curDoc) tsfMgr->AssociateFocus(hwnd, curDoc, &tmpDoc);
            if (tmpDoc) tmpDoc->Release();
            bool stillDisabled = (curDoc == ue4DisabledDoc);
            bool missingCuasWhenHadOrig = (origCuasDoc != nullptr && curDoc == nullptr);
            if (curDoc) curDoc->Release();
            if (stillDisabled || missingCuasWhenHadOrig) {
                std::printf("[FAIL] UE4 TSFDisabledDocumentManager was NOT detached cleanly! curDoc=%p disabled=%p origCuas=%p\n",
                            curDoc, ue4DisabledDoc, origCuasDoc);
                return 47;
            }
        }

        // 6c. 模拟拼音组词期间按 Esc -> 仅取消组词，绝不关掉 Mod 菜单
        SendMessageW(hwnd, WM_IME_STARTCOMPOSITION, 0, 0);
        if ((queryState() & (1 << 6)) == 0) {
            std::printf("[FAIL] WM_IME_STARTCOMPOSITION did NOT set composing state!\n");
            return 40;
        }
        SendMessageW(hwnd, WM_KEYDOWN, VK_ESCAPE, 0);
        int stAfterEsc = queryState();
        if ((stAfterEsc & (1 << 2)) == 0 || (stAfterEsc & (1 << 6)) != 0) {
            std::printf("[FAIL] Esc during IME composition closed menu or failed to cancel composition! state=0x%X\n",
                        stAfterEsc);
            return 41;
        }

        // 6d. 模拟中文字符经 WM_IME_CHAR 提交（"薄荷" U+8584 U+8377），验证经 DefWindowProcW -> WM_CHAR 进入 ImGui 而不被 UE4 吞掉
        unsigned long long d1 = 0, d2 = 0;
        int imeBefore = 0, imeAfter = 0;
        queryMetrics(&d1, &d2, &imeBefore);
        SendMessageW(hwnd, WM_IME_CHAR, 0x8584, 0);
        SendMessageW(hwnd, WM_IME_CHAR, 0x8377, 0);
        PumpMessages();
        queryMetrics(&d1, &d2, &imeAfter);
        if ((imeAfter - imeBefore) < 2) {
            std::printf("[FAIL] Chinese WM_IME_CHAR characters did NOT reach ImGui! delta=%d\n", imeAfter - imeBefore);
            return 42;
        }

        // 6e. Alt+Tab 切窗（WM_KILLFOCUS -> WM_SETFOCUS）：保持菜单打开但临时释放 IME，切回后自动恢复
        SendMessageW(hwnd, WM_KILLFOCUS, 0, 0);
        if ((queryState() & (1 << 2)) == 0) {
            std::printf("[FAIL] Alt+Tab (WM_KILLFOCUS) unexpectedly closed Mod menu!\n");
            return 43;
        }
        if (HIMC duringKill = ::ImmGetContext(hwnd)) {
            ::ImmReleaseContext(hwnd, duringKill);
            std::printf("[FAIL] Alt+Tab (WM_KILLFOCUS) did NOT detach IME!\n");
            return 44;
        }
        SendMessageW(hwnd, WM_SETFOCUS, 0, 0);
        PumpMessages();

        // 6f. 文本框失焦 -> 窗口线程精确还原 UE4 禁用 IME 与 TSFDisabledDocumentManager 状态
        setWantText(0, 0.0f, 0.0f);
        PumpMessages();
        if (HIMC afterBlur = ::ImmGetContext(hwnd)) {
            ::ImmReleaseContext(hwnd, afterBlur);
            std::printf("[FAIL] IME was NOT detached back to UE4 state after textbox blur!\n");
            return 45;
        }
        if (tsfMgr && ue4DisabledDoc) {
            ITfDocumentMgr* restoredDoc = nullptr;
            ITfDocumentMgr* tmpDoc = nullptr;
            tsfMgr->AssociateFocus(hwnd, nullptr, &restoredDoc);
            if (restoredDoc) tsfMgr->AssociateFocus(hwnd, restoredDoc, &tmpDoc);
            if (tmpDoc) tmpDoc->Release();
            bool restoredOk = (restoredDoc == ue4DisabledDoc);
            if (restoredDoc) restoredDoc->Release();
            if (!restoredOk) {
                std::printf("[FAIL] UE4 TSFDisabledDocumentManager was NOT restored after textbox blur!\n");
                return 48;
            }
        }
        std::printf("[TEST-DX12] Verified window-thread TSF+IMM unlock/restore, Esc composition guard, Chinese WM_IME_CHAR, and Alt+Tab!\n");
    }

    // 7. 切换联机客机状态 + ResizeBuffers 稳定性验证
    Sleep(450);
    WriteMockStatusData(dataDir, false, false, false);
    if (!pumpAndPresent(6)) return 13;

    HRESULT hrResize = swap3->ResizeBuffers(2, 1024, 600, DXGI_FORMAT_R8G8B8A8_UNORM, 0);
    if (FAILED(hrResize)) {
        std::printf("[FAIL] DX12 ResizeBuffers failed: 0x%08lX\n", hrResize);
        return 14;
    }
    if (!pumpAndPresent(5)) return 15;

    // 8. 按 F8 关闭菜单 -> 验证立即向 UE4 归还隐藏光标与 ClipCursor，并复测二次打开无闪烁
    Sleep(220);
    int prevSetCurBeforeClose = g_origSetCursorCalls;
    SendMessageW(hwnd, WM_KEYDOWN, VK_F8, 0);
    if (!pumpAndPresent(4)) return 16;
    int st3 = queryState();
    if ((st3 & 4) != 0) {
        std::printf("[FAIL] F8 key did NOT close Mod menu!\n");
        return 17;
    }
    if (g_origSetCursorCalls <= prevSetCurBeforeClose || ::GetCursor() != nullptr) {
        std::printf("[FAIL] Closing menu did NOT immediately hand cursor back to UE4! origCalls=%d->%d cur=%p\n",
                    prevSetCurBeforeClose, g_origSetCursorCalls, ::GetCursor());
        return 46;
    }
    ::ClipCursor(nullptr); // 解除测试中 UE4 锁框以便二次打开与退出

    // 9. 二次打开菜单再锤 15 次 UE4 SetCursor(NULL)，验证二次打开也全程 0 闪烁，然后再关闭
    Sleep(220);
    SendMessageW(hwnd, WM_KEYDOWN, VK_F8, 0);
    if (!pumpAndPresent(4)) return 49;
    for (int iter = 0; iter < 15; ++iter) {
        ::SetCursor(nullptr);
        SendMessageW(hwnd, WM_SETCURSOR, reinterpret_cast<WPARAM>(hwnd), MAKELPARAM(HTCLIENT, WM_MOUSEMOVE));
        if (::GetCursor() == nullptr) {
            std::printf("[FAIL] Second menu open flickered cursor at iter=%d!\n", iter);
            return 50;
        }
    }
    Sleep(220);
    SendMessageW(hwnd, WM_KEYDOWN, VK_F8, 0);
    if (!pumpAndPresent(4)) return 51;
    std::printf("[TEST-DX12] Verified first & second menu open ZERO cursor flicker + F8 clean restore!\n");

    DeleteFileW((dataDir + L"\\map_live.json").c_str());
    DeleteFileW((dataDir + L"\\status.json").c_str());
    DeleteFileW((dataDir + L"\\config.json").c_str());
    DeleteFileW((dataDir + L"\\actions.json").c_str());
    DeleteFileW((dataDir + L"\\catalog.json").c_str());

    std::printf("[PASS] DX12 full regression test PASSED!\n");
    std::fflush(stdout);
    TerminateProcess(GetCurrentProcess(), 0);
    return 0;
}

/// DX11 回退后端回归测试：验证预置死亡保护与强制内置自绘候选条配置持久化加载、DX11 初始化、菜单与空闲直通。
static int RunDx11Test(const std::wstring& dllPath) {
    size_t slash = dllPath.find_last_of(L"\\/");
    std::wstring dataDir = dllPath.substr(0, slash) + L"\\data";
    CreateDirectoryW(dataDir.c_str(), nullptr);

    {
        std::ofstream ofs(dataDir + L"\\config.json", std::ios::binary | std::ios::trunc);
        ofs << "{\n"
               "  \"keepInventoryOnDeath\": true,\n"
               "  \"noDeathDurabilityPenalty\": true,\n"
               "  \"imeCandidateMode\": 2,\n"
               "  \"stackEnabled\": true,\n"
               "  \"stackMultiplier\": 15\n"
               "}\n";
    }

    std::printf("[TEST-DX11] Loading DLL...\n");
    HMODULE mod = LoadLibraryW(dllPath.c_str());
    if (!mod) return 21;
    auto queryState = reinterpret_cast<QueryStateFn>(GetProcAddress(mod, "GroundedQoL_QueryTestState"));
    auto expireBanner = reinterpret_cast<VoidTestFn>(GetProcAddress(mod, "GroundedQoL_TestExpireStartupBanner"));
    auto setWantText = reinterpret_cast<SetWantTextFn>(GetProcAddress(mod, "GroundedQoL_TestSetWantTextInput"));
    auto injectIme = reinterpret_cast<InjectImeCandFn>(GetProcAddress(mod, "GroundedQoL_TestInjectImeCandidates"));
    auto getClickedCand = reinterpret_cast<GetClickedCandFn>(GetProcAddress(mod, "GroundedQoL_TestGetLastClickedCandidate"));
    if (!queryState || !expireBanner || !setWantText || !injectIme || !getClickedCand) return 22;

    Sleep(800);

    {
        std::string cfgText = ReadTextFile(dataDir + L"\\config.json");
        if (cfgText.find("\"keepInventoryOnDeath\": true") == std::string::npos ||
            cfgText.find("\"noDeathDurabilityPenalty\": true") == std::string::npos ||
            cfgText.find("\"imeCandidateMode\": 2") == std::string::npos) {
            std::printf("[FAIL] Pre-existing config was unexpectedly overwritten!\n");
            return 27;
        }
        std::printf("[TEST-DX11] Verified pre-existing config (including imeCandidateMode=2) preserved!\n");
    }

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = TestWndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"GQOL_DX11_RegressionHost";
    RegisterClassExW(&wc);

    HWND hwnd = CreateWindowExW(0, wc.lpszClassName, L"GQOL DX11 Test",
                                WS_OVERLAPPEDWINDOW, 100, 100, 1280, 720,
                                nullptr, nullptr, wc.hInstance, nullptr);
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);

    DXGI_SWAP_CHAIN_DESC sd{};
    sd.BufferCount = 1;
    sd.BufferDesc.Width = 1280;
    sd.BufferDesc.Height = 720;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    IDXGISwapChain* swap = nullptr;
    ID3D11Device* dev = nullptr;
    ID3D11DeviceContext* ctx = nullptr;
    D3D_FEATURE_LEVEL fl{};
    if (FAILED(D3D11CreateDeviceAndSwapChain(
            nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0,
            D3D11_SDK_VERSION, &sd, &swap, &dev, &fl, &ctx))) {
        std::printf("[FAIL] Failed to create DX11 SwapChain\n");
        return 23;
    }

    for (int i = 0; i < 6; ++i) {
        PumpMessages();
        if (FAILED(swap->Present(0, 0))) return 24;
        Sleep(16);
    }
    int st1 = queryState();
    std::printf("[TEST-DX11] After 6 frames state=0x%X (expect bit1=DX11, bit7=SelfDrawnIme)\n", st1);
    if ((st1 & 2) == 0 || (st1 & (1 << 7)) == 0) {
        std::printf("[FAIL] DX11 backend or imeCandidateMode=2 self-drawn mode NOT active!\n");
        return 25;
    }

    // 验证 DX11 空闲直通路径
    expireBanner();
    for (int i = 0; i < 4; ++i) {
        PumpMessages();
        if (FAILED(swap->Present(0, 0))) return 28;
        Sleep(16);
    }
    if ((queryState() & (1 << 4)) == 0) {
        std::printf("[FAIL] DX11 idle zero-overhead pass-through NOT active!\n");
        return 29;
    }

    SendMessageW(hwnd, WM_KEYDOWN, VK_F8, 0);
    for (int i = 0; i < 4; ++i) { PumpMessages(); swap->Present(0, 0); Sleep(16); }
    int st2 = queryState();
    std::printf("[TEST-DX11] After F8 state=0x%X (expect bit2=MenuOpen)\n", st2);
    if ((st2 & 4) == 0) return 26;

    // 验证内置自绘候选条（imeCandidateMode=2）在点击主菜单置顶后依然在顶层前景渲染、且鼠标点击候选字不抢焦点（ADR-0003 / Q4）
    setWantText(1, 360.0f, 260.0f);
    PumpMessages();
    const char* mockCands[] = {"\xE8\x96\x84\xE8\x8D\xB7", "\xE5\x8D\x9A\xE5\x90\x88", "\xE6\x8B\xA8\xE6\xB2\xB3"};
    injectIme("bohe", mockCands, 3);
    for (int i = 0; i < 3; ++i) { PumpMessages(); swap->Present(0, 0); Sleep(16); }
    if ((queryState() & (1 << 8)) == 0) {
        std::printf("[FAIL] Foreground self-drawn IME candidate bar did NOT render!\n");
        return 52;
    }

    // 故意连续点击 Mod 主菜单窗口多处区域（此前会把主菜单置顶覆盖 ##GQOL_ImeCandidateBar 导致弹窗消失）
    SendMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(500, 120));
    SendMessageW(hwnd, WM_LBUTTONUP, 0, MAKELPARAM(500, 120));
    for (int i = 0; i < 3; ++i) { PumpMessages(); swap->Present(0, 0); Sleep(16); }
    if ((queryState() & (1 << 8)) == 0) {
        std::printf("[FAIL] Self-drawn IME candidate bar disappeared after clicking Mod menu window!\n");
        return 53;
    }

    // 1) 点击候选条空白边缘区域：必须拦截不穿透且不触发误选
    SendMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(364, 296));
    SendMessageW(hwnd, WM_LBUTTONUP, 0, MAKELPARAM(364, 296));
    PumpMessages();
    if (getClickedCand() != -1 || (queryState() & (1 << 5)) == 0) {
        std::printf("[FAIL] Clicking candidate bar background triggered selection or lost IME focus! idx=%d state=0x%X\n",
                    getClickedCand(), queryState());
        return 54;
    }

    // 2) 点击顶层候选条内第 1 枚候选字（位于输入框 (360, 260) 正下方第二行芯片中心约 (390, 338)）
    int downBefore = g_origMouseDownCalls;
    SendMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(390, 338));
    SendMessageW(hwnd, WM_LBUTTONUP, 0, MAKELPARAM(390, 338));
    PumpMessages();
    int clickedIdx = getClickedCand();
    int stAfterClick = queryState();
    std::printf("[TEST-DX11] Self-drawn IME foreground click check: clickedIdx=%d state=0x%X origDown=%d->%d\n",
                clickedIdx, stAfterClick, downBefore, g_origMouseDownCalls);
    if (clickedIdx != 0 || (stAfterClick & (1 << 5)) == 0 || g_origMouseDownCalls != downBefore) {
        std::printf("[FAIL] Focus-safe candidate click failed! clickedIdx=%d state=0x%X\n", clickedIdx, stAfterClick);
        return 54;
    }
    injectIme("", nullptr, 0);
    setWantText(0, 0.0f, 0.0f);
    for (int i = 0; i < 2; ++i) { PumpMessages(); swap->Present(0, 0); Sleep(16); }
    std::printf("[TEST-DX11] Verified foreground self-drawn IME bar NEVER hidden by menu + focus-safe click!\n");

    DeleteFileW((dataDir + L"\\config.json").c_str());
    DeleteFileW((dataDir + L"\\actions.json").c_str());

    std::printf("[PASS] DX11 full regression test PASSED!\n");
    std::fflush(stdout);
    TerminateProcess(GetCurrentProcess(), 0);
    return 0;
}

int wmain(int argc, wchar_t** argv) {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    if (argc < 3) {
        std::printf("Usage: overlay_regression_test <dx12|dx11> <path_to_GroundedQoLOverlay.dll>\n");
        return 99;
    }
    if (wcscmp(argv[1], L"dx12") == 0) {
        return RunDx12Test(argv[2]);
    }
    if (wcscmp(argv[1], L"dx11") == 0) {
        return RunDx11Test(argv[2]);
    }
    return 98;
}
