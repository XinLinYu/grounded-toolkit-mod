// 真实 DX12 / DX11 渲染宿主自动化回归测试：
// 加载编译好的 GroundedQoLOverlay.dll，创建真实 DX12（或 DX11）SwapChain，
// 验证 Present Hook、ImGui 中文初始化、Insert/F8 菜单切换、
// 原生 UE4 UWidget->SWidget->FGeometry 内存读取与 M 地图标点零误差绘制，及 ResizeBuffers 无崩溃。

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
    MockSWidget* gcWidget = nullptr;   // +0xE0
    MockRefCtrl* gcRefCtrl = nullptr;  // +0xE8
    MockSWidget* myWidget = nullptr;   // +0xF0
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

static int RunDx12Test(const std::wstring& dllPath) {
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
    size_t slash = dllPath.find_last_of(L"\\/");
    std::wstring dataDir = dllPath.substr(0, slash) + L"\\data";
    WriteNativeSlateMapData(dataDir, fixture);

    // 等待 DLL 后台线程完成 MinHook 挂钩
    Sleep(800);

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

    // 模拟按下 Insert 打开中文 Mod 菜单并渲染 6 帧
    SendMessageW(hwnd, WM_KEYDOWN, VK_INSERT, 0);
    if (!pumpAndPresent(6)) return 12;
    int st2 = queryState();
    std::printf("[TEST-DX12] After Insert key state=0x%X (expect bit2=MenuOpen)\n", st2);
    if ((st2 & 4) == 0) {
        std::printf("[FAIL] Insert key did NOT open Mod menu!\n");
        return 13;
    }

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

    // 清理测试用的 map_live.json
    DeleteFileW((dataDir + L"\\map_live.json").c_str());

    std::printf("[PASS] DX12 full regression test PASSED!\n");
    TerminateProcess(GetCurrentProcess(), 0);
    return 0;
}

static int RunDx11Test(const std::wstring& dllPath) {
    std::printf("[TEST-DX11] Loading DLL...\n");
    HMODULE mod = LoadLibraryW(dllPath.c_str());
    if (!mod) return 21;
    auto queryState = reinterpret_cast<QueryStateFn>(GetProcAddress(mod, "GroundedQoL_QueryTestState"));
    if (!queryState) return 22;

    Sleep(800);

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

    std::printf("[PASS] DX11 full regression test PASSED!\n");
    TerminateProcess(GetCurrentProcess(), 0);
    return 0;
}

int wmain(int argc, wchar_t** argv) {
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
