/*
 * 文件：overlay/tests/overlay_regression_test.cpp
 * 职责：GroundedQoLOverlay.dll 离线自动化回归测试宿主程序（真实 DX12 / DX11 SwapChain）。
 * 验证项：
 *   1. DLL 加载后自动写出默认 data/config.json，且包含 keepInventoryOnDeath=false / noDeathDurabilityPenalty=false；
 *   2. MinHook 正确拦截 Present / Present1 / ResizeBuffers / ExecuteCommandLists 并自动识别 DX12 / DX11；
 *   3. 模拟 UE 4.27 精确内存布局的 UWidget->SWidget->FGeometry，验证旋转/缩放下 M 地图标点 0.00px 投影误差；
 *   4. Insert / F8 菜单切换在房主与联机客机两种 status.json 状态下均能无崩溃渲染（覆盖死亡保护禁用/启用分支）；
 *   5. ResizeBuffers（模拟 Alt+Tab / 改分辨率）安全重建后缓冲无崩溃。
 */

#include <Windows.h>
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>

using QueryStateFn = int(__cdecl*)();

/// 测试宿主窗口的默认消息回调（后续会被 DLL 的 HookedWndProc 子类化接管）。
static LRESULT CALLBACK TestWndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    return DefWindowProcW(hWnd, msg, wParam, lParam);
}

// 在进程内存中构造与 Maine-Win64-Shipping.exe 100% 相同偏移的模拟 UWidget / SWidget / FGeometry / UMapPanelWidget
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
    MockSWidget* gcWidget = nullptr;   // +0xE0（UUserWidget::MyGCWidget 路径）
    MockRefCtrl* gcRefCtrl = nullptr;  // +0xE8
    MockSWidget* myWidget = nullptr;   // +0xF0（UWidget::MyWidget 路径）
    MockRefCtrl* myRefCtrl = nullptr;  // +0xF8
    uint8_t pad1[0x10]{};
};
static_assert(offsetof(MockUWidget, gcWidget) == 0xE0, "gcWidget offset must be 0xE0");
static_assert(offsetof(MockUWidget, myWidget) == 0xF0, "myWidget offset must be 0xF0");

struct alignas(16) MockMapPanel {
    uint8_t pad0[0x3A0]{};
    float maxBoundsX = 80000.0f;  // +0x3A0
    float maxBoundsY = 80000.0f;  // +0x3A4
    float minBoundsX = -80000.0f; // +0x3A8
    float minBoundsY = -80000.0f; // +0x3AC
    float texSizeX = 2048.0f;     // +0x3B0
    float texSizeY = 2048.0f;     // +0x3B4
    uint8_t pad1[0x90]{};
};
static_assert(offsetof(MockMapPanel, maxBoundsX) == 0x3A0, "maxBoundsX offset must be 0x3A0");
static_assert(offsetof(MockMapPanel, minBoundsX) == 0x3A8, "minBoundsX offset must be 0x3A8");
static_assert(offsetof(MockMapPanel, texSizeX) == 0x3B0, "texSizeX offset must be 0x3B0");

/// 构造包含窗口偏移、裁剪边框、带 90 度旋转与 0.5x 缩放的画布及玩家图标的完整模拟夹具。
struct NativeMapMockFixture {
    MockRefCtrl refCtrl;
    MockSWidget sCanvas, sBorder, sRootWin, sPlayerIcon;
    MockUWidget uCanvas, uBorder, uRootWin, uPlayerIcon;
    MockMapPanel panel;

    NativeMapMockFixture() {
        // 模拟 1280x720 窗口全屏 UI_InGameMenu（走 UUserWidget::MyGCWidget 路径 +0xE0/+0xE8）
        sRootWin.cachedGeom.sizeX = 1280.0f;
        sRootWin.cachedGeom.sizeY = 720.0f;
        sRootWin.cachedGeom.m00 = 1.0f;
        sRootWin.cachedGeom.m11 = 1.0f;
        sRootWin.cachedGeom.transX = 100.0f; // 模拟窗口位于桌面 (100, 50)
        sRootWin.cachedGeom.transY = 50.0f;
        uRootWin.gcWidget = &sRootWin;
        uRootWin.gcRefCtrl = &refCtrl;

        // 模拟 MapBorder（顶部保留 60px 标题栏）
        sBorder.cachedGeom.sizeX = 1280.0f;
        sBorder.cachedGeom.sizeY = 660.0f;
        sBorder.cachedGeom.m00 = 1.0f;
        sBorder.cachedGeom.m11 = 1.0f;
        sBorder.cachedGeom.transX = 100.0f;
        sBorder.cachedGeom.transY = 110.0f;
        uBorder.myWidget = &sBorder;
        uBorder.myRefCtrl = &refCtrl;

        // 模拟 CollectibleCanvas：2048x2048，带 0.5x 缩放 + 90 度旋转（验证任意旋转与缩放！）
        // 旋转 90 度：m00=0, m01=0.5, m10=-0.5, m11=0，中心平移到窗口中心 (100+640, 50+360)
        sCanvas.cachedGeom.sizeX = 2048.0f;
        sCanvas.cachedGeom.sizeY = 2048.0f;
        sCanvas.cachedGeom.m00 = 0.0f;
        sCanvas.cachedGeom.m01 = 0.5f;
        sCanvas.cachedGeom.m10 = -0.5f;
        sCanvas.cachedGeom.m11 = 0.0f;
        // local=(1024,1024) 映射到桌面 (740, 410) => transX = 740 - (-0.5*1024) = 1252, transY = 410 - (0.5*1024) = -102
        sCanvas.cachedGeom.transX = 1252.0f;
        sCanvas.cachedGeom.transY = -102.0f;
        uCanvas.myWidget = &sCanvas;
        uCanvas.myRefCtrl = &refCtrl;

        // 模拟玩家在世界坐标 (16000, -16000)：
        // normX = (16000 - (-80000)) / 160000 = 0.6 => localX = 1024 + 0.1*2048 = 1228.8
        // normY = (-16000 - (-80000)) / 160000 = 0.4 => localY = 1024 - 0.1*2048 = 819.2
        // absX = 1228.8*0 + 819.2*(-0.5) + 1252 = 842.4 => dispX = 742.4
        // absY = 1228.8*0.5 + 819.2*0 - 102 = 512.4 => dispY = 462.4
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

/// 将模拟控件的进程内真实地址写入 data/map_live.json，供 DLL 走 NativeSlateFGeometry 路径读取。
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

/// 写入模拟的 data/status.json，用于回归测试房主与联机客机两种角色下的死亡保护 UI 分支。
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

/// 读取文本文件全部内容，用于断言 config.json 与 overlay.log 关键字段。
static std::string ReadTextFile(const std::wstring& path) {
    std::ifstream ifs(path, std::ios::binary);
    std::ostringstream ss;
    ss << ifs.rdbuf();
    return ss.str();
}

/// DX12 全流程回归测试：配置初始化 + 图形挂钩 + 0 像素误差地图投影 + 房主/客机菜单渲染 + ResizeBuffers。
static int RunDx12Test(const std::wstring& dllPath) {
    size_t slash = dllPath.find_last_of(L"\\/");
    std::wstring dataDir = dllPath.substr(0, slash) + L"\\data";
    // 先清理旧测试 config.json，确保本次能验证 DLL 首次初始化自动落盘的新字段默认值
    DeleteFileW((dataDir + L"\\config.json").c_str());

    std::printf("[TEST-DX12] Loading DLL...\n");
    HMODULE mod = LoadLibraryW(dllPath.c_str());
    if (!mod) {
        std::printf("[FAIL] LoadLibraryW failed: %lu\n", GetLastError());
        return 1;
    }
    auto queryState = reinterpret_cast<QueryStateFn>(GetProcAddress(mod, "GroundedQoL_QueryTestState"));
    if (!queryState) {
        std::printf("[FAIL] GroundedQoL_QueryTestState not found\n");
        return 2;
    }

    // 构造真实 UE4 偏移的内存模拟控件，验证 NativeSlateFGeometry 零误差投影与标点绘制
    NativeMapMockFixture fixture;
    WriteNativeSlateMapData(dataDir, fixture);
    WriteMockStatusData(dataDir, true, true, false);

    // 等待 DLL 后台线程完成 IpcBridge::Initialize 与 MinHook 挂钩
    Sleep(800);

    // 断言新配置字段（死亡背包保留、免除死亡耐久惩罚）已正确写入 config.json 且默认为 false
    {
        std::string cfgText = ReadTextFile(dataDir + L"\\config.json");
        if (cfgText.find("\"keepInventoryOnDeath\": false") == std::string::npos ||
            cfgText.find("\"noDeathDurabilityPenalty\": false") == std::string::npos) {
            std::printf("[FAIL] Default config.json missing expected death protection fields!\nContent:\n%s\n", cfgText.c_str());
            return 20;
        }
        std::printf("[TEST-DX12] Verified default death protection config fields in config.json!\n");
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
            MSG m{};
            while (PeekMessageW(&m, nullptr, 0, 0, PM_REMOVE)) {
                TranslateMessage(&m);
                DispatchMessageW(&m);
            }
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

    // 读取 overlay.log 验证 NativeSlateFGeometry 激活且玩家 0 像素误差自检通过
    {
        std::ifstream logFile(dataDir + L"\\overlay.log");
        std::ostringstream ss;
        ss << logFile.rdbuf();
        std::string logText = ss.str();
        if (logText.find("NativeSlateFGeometry") == std::string::npos ||
            logText.find("playerErr=0.00px") == std::string::npos) {
            std::printf("[FAIL] overlay.log did not confirm 0.00px NativeSlateFGeometry accuracy!\nLog:\n%s\n", logText.c_str());
            return 19;
        }
        std::printf("[TEST-DX12] Verified NativeSlateFGeometry playerErr=0.00px in overlay.log!\n");
    }

    // 模拟按下 Insert 打开中文 Mod 菜单并渲染 6 帧（房主模式）
    SendMessageW(hwnd, WM_KEYDOWN, VK_INSERT, 0);
    if (!pumpAndPresent(6)) return 12;
    int st2 = queryState();
    std::printf("[TEST-DX12] After Insert key state=0x%X (expect bit2=MenuOpen)\n", st2);
    if ((st2 & 4) == 0) {
        std::printf("[FAIL] Insert key did NOT open Mod menu!\n");
        return 13;
    }

    // 切换为联机客机状态并等待低频轮询周期，验证死亡保护区域灰显禁用分支渲染正常
    Sleep(500);
    WriteMockStatusData(dataDir, false, false, false);
    if (!pumpAndPresent(6)) return 13;

    // 模拟 ResizeBuffers（Alt+Tab / 分辨率切换）
    HRESULT hrResize = swap3->ResizeBuffers(2, 1024, 600, DXGI_FORMAT_R8G8B8A8_UNORM, 0);
    if (FAILED(hrResize)) {
        std::printf("[FAIL] DX12 ResizeBuffers failed: 0x%08lX\n", hrResize);
        return 14;
    }
    if (!pumpAndPresent(5)) return 15;

    // 模拟按 F8 关闭菜单
    Sleep(220);
    SendMessageW(hwnd, WM_KEYDOWN, VK_F8, 0);
    if (!pumpAndPresent(4)) return 16;
    int st3 = queryState();
    std::printf("[TEST-DX12] After F8 key state=0x%X (expect bit2=0 MenuClosed)\n", st3);
    if ((st3 & 4) != 0) {
        std::printf("[FAIL] F8 key did NOT close Mod menu!\n");
        return 17;
    }

    // 清理测试生成的临时 IPC 数据文件
    DeleteFileW((dataDir + L"\\map_live.json").c_str());
    DeleteFileW((dataDir + L"\\status.json").c_str());
    DeleteFileW((dataDir + L"\\config.json").c_str());

    std::printf("[PASS] DX12 full regression test PASSED!\n");
    std::fflush(stdout);
    TerminateProcess(GetCurrentProcess(), 0);
    return 0;
}

/// DX11 回退后端回归测试：验证预置启用配置的持久化加载、DX11 SwapChain 初始化、菜单打开与无崩溃渲染。
static int RunDx11Test(const std::wstring& dllPath) {
    size_t slash = dllPath.find_last_of(L"\\/");
    std::wstring dataDir = dllPath.substr(0, slash) + L"\\data";
    CreateDirectoryW(dataDir.c_str(), nullptr);

    // 预置开启死亡保护的 config.json，验证 DLL 启动加载已有配置时不覆盖用户的开启状态
    {
        std::ofstream ofs(dataDir + L"\\config.json", std::ios::binary | std::ios::trunc);
        ofs << "{\n"
               "  \"keepInventoryOnDeath\": true,\n"
               "  \"noDeathDurabilityPenalty\": true,\n"
               "  \"stackEnabled\": true,\n"
               "  \"stackMultiplier\": 15\n"
               "}\n";
    }

    std::printf("[TEST-DX11] Loading DLL...\n");
    HMODULE mod = LoadLibraryW(dllPath.c_str());
    if (!mod) return 21;
    auto queryState = reinterpret_cast<QueryStateFn>(GetProcAddress(mod, "GroundedQoL_QueryTestState"));
    if (!queryState) return 22;

    Sleep(800);

    // 确认预置配置被保留而未被默认值覆盖
    {
        std::string cfgText = ReadTextFile(dataDir + L"\\config.json");
        if (cfgText.find("\"keepInventoryOnDeath\": true") == std::string::npos ||
            cfgText.find("\"noDeathDurabilityPenalty\": true") == std::string::npos) {
            std::printf("[FAIL] Pre-existing death protection config was unexpectedly overwritten!\n");
            return 27;
        }
        std::printf("[TEST-DX11] Verified pre-existing death protection config preserved!\n");
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
        if (FAILED(swap->Present(0, 0))) return 24;
        Sleep(16);
    }
    int st1 = queryState();
    std::printf("[TEST-DX11] After 6 frames state=0x%X (expect bit1=DX11)\n", st1);
    if ((st1 & 2) == 0) {
        std::printf("[FAIL] Overlay did NOT initialize DX11 backend!\n");
        return 25;
    }

    SendMessageW(hwnd, WM_KEYDOWN, VK_F8, 0);
    for (int i = 0; i < 4; ++i) { swap->Present(0, 0); Sleep(16); }
    int st2 = queryState();
    std::printf("[TEST-DX11] After F8 state=0x%X (expect bit2=MenuOpen)\n", st2);
    if ((st2 & 4) == 0) return 26;

    DeleteFileW((dataDir + L"\\config.json").c_str());

    std::printf("[PASS] DX11 full regression test PASSED!\n");
    std::fflush(stdout);
    TerminateProcess(GetCurrentProcess(), 0);
    return 0;
}

/// 回归测试命令行入口：根据参数执行 dx12 或 dx11 完整验证流程。
int wmain(int argc, wchar_t** argv) {
    // 关闭 stdout 行/块缓冲，确保在管道重定向场景下 TerminateProcess 前所有日志完整落出
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
