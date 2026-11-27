/*
 * 文件：overlay/src/dx11_hook.cpp
 * 职责：实现自适应 DirectX 12 / DirectX 11 图形钩子与 Win32 WndProc 输入接管。
 * 关键架构说明：
 *   1. 通过临时隐藏窗口创建虚拟 DX12/DX11 SwapChain 解析 DXGI Present / Present1 / ResizeBuffers
 *      与 ID3D12CommandQueue::ExecuteCommandLists 真实虚表地址，并用 MinHook 注入钩子。
 *   2. DX12 下通过捕获游戏主 DIRECT 命令队列、独立维护每帧 CommandAllocator + Fence 围栏同步
 *      与 64 槽位 SRV 描述符堆，在不破坏游戏渲染管线的前提下将 Dear ImGui 合成到当前 BackBuffer。
 *   3. 使用 thread_local t_inPresent 防止 Present1 内部转发到 Present 造成的重入双绘；
 *      同时提供 WndProc 与 GetAsyncKeyState 双通道热键检测，兼容 Steam Overlay 与 RawInput。
 */

#include "dx11_hook.h"
#include "ipc.h"
#include "overlay_ui.h"

#include <d3d11.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <MinHook.h>
#include <imgui.h>
#include <imgui_impl_win32.h>
#include <imgui_impl_dx11.h>
#include <imgui_impl_dx12.h>

#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <fstream>
#include <mutex>
#include <vector>

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam);

namespace gqol {

namespace {

/// 当前已绑定并激活的图形 API 类型。
enum class GraphicsApi {
    None,
    DX11,
    DX12,
};

using PresentFn = HRESULT(STDMETHODCALLTYPE*)(IDXGISwapChain*, UINT, UINT);
using Present1Fn = HRESULT(STDMETHODCALLTYPE*)(IDXGISwapChain1*, UINT, UINT, const DXGI_PRESENT_PARAMETERS*);
using ResizeBuffersFn = HRESULT(STDMETHODCALLTYPE*)(IDXGISwapChain*, UINT, UINT, UINT, DXGI_FORMAT, UINT);
using ExecuteCommandListsFn = void(STDMETHODCALLTYPE*)(ID3D12CommandQueue*, UINT, ID3D12CommandList* const*);

// MinHook 保存的原函数蹦床指针与原窗口过程
PresentFn g_origPresent = nullptr;
Present1Fn g_origPresent1 = nullptr;
ResizeBuffersFn g_origResizeBuffers = nullptr;
ExecuteCommandListsFn g_origExecuteCommandLists = nullptr;
WNDPROC g_origWndProc = nullptr;

std::mutex g_logMutex;
std::mutex g_queueMutex;
std::mutex g_srvAllocMutex;

// 全局运行期状态（涉及渲染线程与消息线程共享的标志使用 atomic）
GraphicsApi g_activeApi = GraphicsApi::None;
HWND g_gameHwnd = nullptr;
IDXGISwapChain* g_boundSwapChain = nullptr;
bool g_imguiInitialized = false;
float g_uiScale = 1.0f;
unsigned long long g_initTick = 0;
unsigned long long g_lastToggleTick = 0;
bool g_prevInsertDown = false;
bool g_prevF8Down = false;
std::atomic<bool> g_menuOpen{false};
std::atomic<bool> g_shuttingDown{false};
// 防止 DXGI Present1 内部调用 Present 或第三方叠加层转发导致同一帧重复渲染 ImGui
thread_local bool t_inPresent = false;

// ==================== DX11 状态 ====================
ID3D11Device* g_d3d11Device = nullptr;
ID3D11DeviceContext* g_d3d11Context = nullptr;
ID3D11RenderTargetView* g_d3d11Rtv = nullptr;

// ==================== DX12 状态 ====================
/// 从 ExecuteCommandLists 捕获到的候选 DIRECT 命令队列，初始化时按 Device 指针精准匹配 SwapChain。
struct Dx12CandidateQueue {
    ID3D12Device* device = nullptr;
    ID3D12CommandQueue* queue = nullptr;
};
std::vector<Dx12CandidateQueue> g_candidateQueues;
std::atomic<bool> g_dx12QueueLocked{false};

/// DX12 每个交换链缓冲槽位的独立帧上下文（避免 GPU 尚未执行完时重置 CommandAllocator）。
struct Dx12FrameContext {
    ID3D12CommandAllocator* cmdAllocator = nullptr;
    ID3D12Resource* backBuffer = nullptr;
    D3D12_CPU_DESCRIPTOR_HANDLE rtvHandle{};
    UINT64 fenceValue = 0;
};

constexpr UINT kSrvHeapCapacity = 64;
ID3D12Device* g_d3d12Device = nullptr;
ID3D12CommandQueue* g_d3d12CommandQueue = nullptr;
ID3D12DescriptorHeap* g_d3d12RtvHeap = nullptr;
ID3D12DescriptorHeap* g_d3d12SrvHeap = nullptr;
UINT g_d3d12SrvIncrement = 0;
bool g_srvSlotUsed[kSrvHeapCapacity]{};
ID3D12GraphicsCommandList* g_d3d12CmdList = nullptr;
ID3D12Fence* g_d3d12Fence = nullptr;
HANDLE g_d3d12FenceEvent = nullptr;
UINT64 g_d3d12FenceValue = 0;
std::vector<Dx12FrameContext> g_dx12Frames;

/// ImGui DX12 后端纹理 SRV 描述符分配回调（从 64 槽位位图中线程安全分配空闲句柄）。
void SrvDescriptorAllocCallback(ImGui_ImplDX12_InitInfo* /*info*/,
                                D3D12_CPU_DESCRIPTOR_HANDLE* outCpu,
                                D3D12_GPU_DESCRIPTOR_HANDLE* outGpu) {
    std::lock_guard<std::mutex> lk(g_srvAllocMutex);
    UINT slot = 0;
    for (UINT i = 0; i < kSrvHeapCapacity; ++i) {
        if (!g_srvSlotUsed[i]) {
            g_srvSlotUsed[i] = true;
            slot = i;
            break;
        }
    }
    D3D12_CPU_DESCRIPTOR_HANDLE cpu = g_d3d12SrvHeap->GetCPUDescriptorHandleForHeapStart();
    D3D12_GPU_DESCRIPTOR_HANDLE gpu = g_d3d12SrvHeap->GetGPUDescriptorHandleForHeapStart();
    cpu.ptr += static_cast<SIZE_T>(slot) * g_d3d12SrvIncrement;
    gpu.ptr += static_cast<UINT64>(slot) * g_d3d12SrvIncrement;
    *outCpu = cpu;
    *outGpu = gpu;
}

/// ImGui DX12 后端纹理 SRV 描述符归还回调（根据 CPU 句柄偏移回收槽位）。
void SrvDescriptorFreeCallback(ImGui_ImplDX12_InitInfo* /*info*/,
                               D3D12_CPU_DESCRIPTOR_HANDLE cpuHandle,
                               D3D12_GPU_DESCRIPTOR_HANDLE /*gpuHandle*/) {
    std::lock_guard<std::mutex> lk(g_srvAllocMutex);
    if (!g_d3d12SrvHeap || g_d3d12SrvIncrement == 0) return;
    SIZE_T base = g_d3d12SrvHeap->GetCPUDescriptorHandleForHeapStart().ptr;
    if (cpuHandle.ptr >= base) {
        UINT slot = static_cast<UINT>((cpuHandle.ptr - base) / g_d3d12SrvIncrement);
        if (slot < kSrvHeapCapacity) {
            g_srvSlotUsed[slot] = false;
        }
    }
}

/// 带 180ms 防抖的菜单开关切换（防止 WndProc 与 AsyncKey 双通道同帧触发两次导致闪关）。
void ToggleMenuWithDebounce(const char* source) {
    unsigned long long now = GetTickCount64();
    if (now - g_lastToggleTick < 180) return;
    g_lastToggleTick = now;
    bool next = !g_menuOpen.load();
    g_menuOpen.store(next);
    OverlayLog("Menu toggled -> %s (via %s)", next ? "OPEN" : "CLOSED", source);
}

// ==================== DX11 辅助函数 ====================

/// 安全释放 DX11 渲染目标视图（在 ResizeBuffers 与卸载阶段必须先释放，否则重置交换链会失败）。
void ReleaseDx11Rtv() {
    if (g_d3d11Rtv) {
        g_d3d11Rtv->Release();
        g_d3d11Rtv = nullptr;
    }
}

/// 从当前 DX11 SwapChain 后缓冲重建 RenderTargetView。
void CreateDx11Rtv(IDXGISwapChain* swapChain) {
    ReleaseDx11Rtv();
    ID3D11Texture2D* backBuffer = nullptr;
    if (SUCCEEDED(swapChain->GetBuffer(0, IID_PPV_ARGS(&backBuffer))) && backBuffer) {
        g_d3d11Device->CreateRenderTargetView(backBuffer, nullptr, &g_d3d11Rtv);
        backBuffer->Release();
    }
}

// ==================== DX12 辅助函数 ====================

/// 向 DX12 命令队列发射围栏信号并阻塞等待 GPU 完成，用于 ResizeBuffers 与关闭前的资源安全释放。
void WaitForDx12GpuIdle() {
    if (!g_d3d12CommandQueue || !g_d3d12Fence || !g_d3d12FenceEvent) return;
    const UINT64 target = ++g_d3d12FenceValue;
    if (SUCCEEDED(g_d3d12CommandQueue->Signal(g_d3d12Fence, target))) {
        if (g_d3d12Fence->GetCompletedValue() < target) {
            g_d3d12Fence->SetEventOnCompletion(target, g_d3d12FenceEvent);
            WaitForSingleObject(g_d3d12FenceEvent, 2000);
        }
    }
}

/// 释放全部 DX12 后缓冲引用（ResizeBuffers 前必须将所有 BackBuffer 引用计数归零）。
void ReleaseDx12BackBuffers() {
    for (auto& f : g_dx12Frames) {
        if (f.backBuffer) {
            f.backBuffer->Release();
            f.backBuffer = nullptr;
        }
    }
}

/// 按 SwapChain 当前缓冲数量创建或重建 DX12 RTV 描述符堆、后缓冲绑定与各帧 CommandAllocator。
bool CreateDx12BackBuffers(IDXGISwapChain* swapChain) {
    DXGI_SWAP_CHAIN_DESC sd{};
    if (FAILED(swapChain->GetDesc(&sd)) || sd.BufferCount == 0) return false;

    if (g_d3d12RtvHeap) {
        g_d3d12RtvHeap->Release();
        g_d3d12RtvHeap = nullptr;
    }

    D3D12_DESCRIPTOR_HEAP_DESC rtvDesc{};
    rtvDesc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    rtvDesc.NumDescriptors = sd.BufferCount;
    rtvDesc.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
    if (FAILED(g_d3d12Device->CreateDescriptorHeap(&rtvDesc, IID_PPV_ARGS(&g_d3d12RtvHeap)))) {
        OverlayLog("DX12 CreateDescriptorHeap(RTV) failed");
        return false;
    }

    // 保留或扩展 FrameContext（按需创建 CommandAllocator）
    if (g_dx12Frames.size() != sd.BufferCount) {
        for (auto& f : g_dx12Frames) {
            if (f.backBuffer) f.backBuffer->Release();
            if (f.cmdAllocator) f.cmdAllocator->Release();
        }
        g_dx12Frames.clear();
        g_dx12Frames.resize(sd.BufferCount);
    }

    UINT rtvStep = g_d3d12Device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    D3D12_CPU_DESCRIPTOR_HANDLE handle = g_d3d12RtvHeap->GetCPUDescriptorHandleForHeapStart();

    for (UINT i = 0; i < sd.BufferCount; ++i) {
        if (!g_dx12Frames[i].cmdAllocator) {
            if (FAILED(g_d3d12Device->CreateCommandAllocator(
                    D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&g_dx12Frames[i].cmdAllocator)))) {
                OverlayLog("DX12 CreateCommandAllocator[%u] failed", i);
                return false;
            }
        }
        ID3D12Resource* bb = nullptr;
        if (FAILED(swapChain->GetBuffer(i, IID_PPV_ARGS(&bb))) || !bb) {
            OverlayLog("DX12 GetBuffer[%u] failed", i);
            return false;
        }
        g_d3d12Device->CreateRenderTargetView(bb, nullptr, handle);
        g_dx12Frames[i].backBuffer = bb;
        g_dx12Frames[i].rtvHandle = handle;
        g_dx12Frames[i].fenceValue = 0;
        handle.ptr += rtvStep;
    }
    return true;
}

/// 按 Device 指针查找匹配的 DIRECT 类型 DX12 命令队列。
ID3D12CommandQueue* FindDirectQueueForDevice(ID3D12Device* dev) {
    std::lock_guard<std::mutex> lk(g_queueMutex);
    for (const auto& c : g_candidateQueues) {
        if (c.device == dev && c.queue) {
            return c.queue;
        }
    }
    return nullptr;
}

// ==================== WndProc 钩子 ====================

/// 游戏主窗口消息钩子：处理菜单开关热键、打开菜单时吞掉键鼠输入（放行中文 IME）以及 M 地图快捷放路标。
LRESULT CALLBACK HookedWndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (g_shuttingDown.load()) {
        return CallWindowProcW(g_origWndProc, hWnd, msg, wParam, lParam);
    }

    if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) {
        if (wParam == VK_INSERT || wParam == VK_F8) {
            ToggleMenuWithDebounce(wParam == VK_INSERT ? "WndProc:Insert" : "WndProc:F8");
            return 0;
        }
        if (wParam == VK_ESCAPE && g_menuOpen.load()) {
            g_menuOpen.store(false);
            return 0;
        }
    }

    if (g_imguiInitialized) {
        ImGui_ImplWin32_WndProcHandler(hWnd, msg, wParam, lParam);

        if (g_menuOpen.load()) {
            // 放行 IME 消息给默认窗口过程，保证微软拼音等中文输入法候选框正常弹出
            if (msg == WM_IME_SETCONTEXT || msg == WM_IME_NOTIFY ||
                msg == WM_IME_STARTCOMPOSITION || msg == WM_IME_COMPOSITION ||
                msg == WM_IME_ENDCOMPOSITION || msg == WM_IME_REQUEST) {
                return DefWindowProcW(hWnd, msg, wParam, lParam);
            }

            // 菜单打开期间拦截游戏本体鼠标与键盘事件，防止点菜单按钮时角色同时挥武器或旋转视角
            switch (msg) {
                case WM_MOUSEMOVE:
                case WM_LBUTTONDOWN:
                case WM_LBUTTONUP:
                case WM_LBUTTONDBLCLK:
                case WM_RBUTTONDOWN:
                case WM_RBUTTONUP:
                case WM_RBUTTONDBLCLK:
                case WM_MBUTTONDOWN:
                case WM_MBUTTONUP:
                case WM_MOUSEWHEEL:
                case WM_MOUSEHWHEEL:
                case WM_XBUTTONDOWN:
                case WM_XBUTTONUP:
                case WM_KEYDOWN:
                case WM_KEYUP:
                case WM_SYSKEYDOWN:
                case WM_SYSKEYUP:
                case WM_CHAR:
                case WM_INPUT:
                    return 0;
                case WM_SETCURSOR:
                    SetCursor(LoadCursorW(nullptr, IDC_ARROW));
                    return TRUE;
                default:
                    break;
            }
        } else {
            // 菜单关闭且处于 M 地图悬停状态时，优先交给地图快捷键（G / Ctrl+左键）放原版路标
            if (HandleMapQuickShortcut(msg, wParam, lParam)) {
                return 0;
            }
        }
    }

    return CallWindowProcW(g_origWndProc, hWnd, msg, wParam, lParam);
}

// ==================== 初始化逻辑（自动区分 DX12 / DX11） ====================

/// 首次拦截到有效游戏主 SwapChain 时执行懒初始化，自动适配 DX12（优先）或 DX11 并挂接 WndProc。
bool TryInitImGuiForSwapChain(IDXGISwapChain* swapChain) {
    DXGI_SWAP_CHAIN_DESC sd{};
    if (FAILED(swapChain->GetDesc(&sd))) return false;
    if (!sd.OutputWindow || sd.BufferDesc.Width < 200 || sd.BufferDesc.Height < 200) {
        return false;
    }

    RECT rc{};
    GetClientRect(sd.OutputWindow, &rc);
    float h = static_cast<float>(std::max<LONG>(1, rc.bottom - rc.top));
    if (h < 200.0f) h = static_cast<float>(sd.BufferDesc.Height);
    float scale = std::clamp(h / 1080.0f, 1.0f, 2.25f);

    // 1. 优先尝试 DirectX 12（Grounded Steam Windows 11 默认使用 DX12）
    ID3D12Device* d12Dev = nullptr;
    if (SUCCEEDED(swapChain->GetDevice(IID_PPV_ARGS(&d12Dev))) && d12Dev) {
        ID3D12CommandQueue* queue = FindDirectQueueForDevice(d12Dev);
        if (!queue) {
            // 等待主渲染队列第一次调用 ExecuteCommandLists
            d12Dev->Release();
            return false;
        }

        IDXGISwapChain3* sc3 = nullptr;
        if (FAILED(swapChain->QueryInterface(IID_PPV_ARGS(&sc3))) || !sc3) {
            OverlayLog("DX12 swapChain does not support IDXGISwapChain3");
            d12Dev->Release();
            return false;
        }
        sc3->Release();

        g_dx12QueueLocked.store(true);
        g_d3d12Device = d12Dev; // 持有引用
        g_d3d12CommandQueue = queue;
        g_d3d12CommandQueue->AddRef();

        // 创建 ImGui SRV 描述符堆（支持 64 个纹理槽）
        D3D12_DESCRIPTOR_HEAP_DESC srvDesc{};
        srvDesc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
        srvDesc.NumDescriptors = kSrvHeapCapacity;
        srvDesc.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        if (FAILED(g_d3d12Device->CreateDescriptorHeap(&srvDesc, IID_PPV_ARGS(&g_d3d12SrvHeap)))) {
            OverlayLog("DX12 CreateDescriptorHeap(SRV) failed");
            return false;
        }
        g_d3d12SrvIncrement = g_d3d12Device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        memset(g_srvSlotUsed, 0, sizeof(g_srvSlotUsed));

        if (!CreateDx12BackBuffers(swapChain)) {
            return false;
        }

        if (FAILED(g_d3d12Device->CreateCommandList(
                0, D3D12_COMMAND_LIST_TYPE_DIRECT, g_dx12Frames[0].cmdAllocator, nullptr,
                IID_PPV_ARGS(&g_d3d12CmdList)))) {
            OverlayLog("DX12 CreateCommandList failed");
            return false;
        }
        g_d3d12CmdList->Close();

        if (FAILED(g_d3d12Device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&g_d3d12Fence)))) {
            OverlayLog("DX12 CreateFence failed");
            return false;
        }
        g_d3d12FenceEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        g_d3d12FenceValue = 0;

        g_gameHwnd = sd.OutputWindow;
        g_boundSwapChain = swapChain;
        g_uiScale = scale;

        IMGUI_CHECKVERSION();
        ImGui::CreateContext();
        ImGuiIO& io = ImGui::GetIO();
        io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
        io.IniFilename = nullptr;

        InitOverlayStyleAndFonts(g_uiScale);
        ImGui_ImplWin32_Init(g_gameHwnd);

        ImGui_ImplDX12_InitInfo initInfo{};
        initInfo.Device = g_d3d12Device;
        initInfo.CommandQueue = g_d3d12CommandQueue;
        initInfo.NumFramesInFlight = static_cast<int>(sd.BufferCount);
        initInfo.RTVFormat = sd.BufferDesc.Format;
        initInfo.DSVFormat = DXGI_FORMAT_UNKNOWN;
        initInfo.SrvDescriptorHeap = g_d3d12SrvHeap;
        initInfo.SrvDescriptorAllocFn = SrvDescriptorAllocCallback;
        initInfo.SrvDescriptorFreeFn = SrvDescriptorFreeCallback;

        if (!ImGui_ImplDX12_Init(&initInfo)) {
            OverlayLog("ImGui_ImplDX12_Init failed");
            return false;
        }

        g_origWndProc = reinterpret_cast<WNDPROC>(
            SetWindowLongPtrW(g_gameHwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(HookedWndProc)));
        g_activeApi = GraphicsApi::DX12;
        g_imguiInitialized = true;
        g_initTick = GetTickCount64();
        OverlayLog("DX12 ImGui initialized! HWND=0x%p Size=%ux%u Buffers=%u Format=%d Scale=%.2f",
                   g_gameHwnd, sd.BufferDesc.Width, sd.BufferDesc.Height,
                   sd.BufferCount, static_cast<int>(sd.BufferDesc.Format), g_uiScale);
        return true;
    }

    // 2. 回退到 DirectX 11
    ID3D11Device* d11Dev = nullptr;
    if (SUCCEEDED(swapChain->GetDevice(IID_PPV_ARGS(&d11Dev))) && d11Dev) {
        g_d3d11Device = d11Dev;
        g_d3d11Device->GetImmediateContext(&g_d3d11Context);
        g_gameHwnd = sd.OutputWindow;
        g_boundSwapChain = swapChain;
        g_uiScale = scale;
        CreateDx11Rtv(swapChain);

        IMGUI_CHECKVERSION();
        ImGui::CreateContext();
        ImGuiIO& io = ImGui::GetIO();
        io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
        io.IniFilename = nullptr;

        InitOverlayStyleAndFonts(g_uiScale);
        ImGui_ImplWin32_Init(g_gameHwnd);
        ImGui_ImplDX11_Init(g_d3d11Device, g_d3d11Context);

        g_origWndProc = reinterpret_cast<WNDPROC>(
            SetWindowLongPtrW(g_gameHwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(HookedWndProc)));
        g_activeApi = GraphicsApi::DX11;
        g_imguiInitialized = true;
        g_initTick = GetTickCount64();
        OverlayLog("DX11 ImGui initialized! HWND=0x%p Size=%ux%u Format=%d Scale=%.2f",
                   g_gameHwnd, sd.BufferDesc.Width, sd.BufferDesc.Height,
                   static_cast<int>(sd.BufferDesc.Format), g_uiScale);
        return true;
    }

    return false;
}

/// 在 Present 帧内轮询 Insert / F8 兜底热键（防止 RawInput 或 Steam Overlay 吞掉 WM_KEYDOWN）。
void PollFallbackHotkeys() {
    if (!g_gameHwnd || GetForegroundWindow() != g_gameHwnd) {
        g_prevInsertDown = false;
        g_prevF8Down = false;
        return;
    }
    bool insNow = (GetAsyncKeyState(VK_INSERT) & 0x8000) != 0;
    bool f8Now = (GetAsyncKeyState(VK_F8) & 0x8000) != 0;
    if (insNow && !g_prevInsertDown) {
        ToggleMenuWithDebounce("AsyncKey:Insert");
    } else if (f8Now && !g_prevF8Down) {
        ToggleMenuWithDebounce("AsyncKey:F8");
    }
    g_prevInsertDown = insNow;
    g_prevF8Down = f8Now;
}

/// 绘制启动后前 10 秒的左上角状态提示条，直观反馈插件已成功挂载。
void DrawStartupBanner() {
    unsigned long long elapsed = GetTickCount64() - g_initTick;
    if (elapsed > 10000 || g_menuOpen.load()) return;

    float alpha = 1.0f;
    if (elapsed > 8000) {
        alpha = std::clamp(1.0f - static_cast<float>(elapsed - 8000) / 2000.0f, 0.0f, 1.0f);
    }
    ImDrawList* dl = ImGui::GetForegroundDrawList();
    char text[160];
    std::snprintf(text, sizeof(text), "GroundedQoL 已就绪 (%s) | 按 Insert 或 F8 打开中文菜单",
                  GetActiveGraphicsBackend());
    ImVec2 sz = ImGui::CalcTextSize(text);
    float pad = 10.0f * g_uiScale;
    ImVec2 p0(18.0f * g_uiScale, 18.0f * g_uiScale);
    ImVec2 p1(p0.x + sz.x + pad * 2.0f, p0.y + sz.y + pad * 1.4f);
    ImU32 bg = IM_COL32(14, 22, 32, static_cast<int>(215 * alpha));
    ImU32 bd = IM_COL32(75, 200, 245, static_cast<int>(230 * alpha));
    ImU32 fg = IM_COL32(235, 248, 255, static_cast<int>(255 * alpha));
    dl->AddRectFilled(p0, p1, bg, 6.0f * g_uiScale);
    dl->AddRect(p0, p1, bd, 6.0f * g_uiScale, 0, 1.3f * g_uiScale);
    dl->AddText(ImVec2(p0.x + pad, p0.y + pad * 0.7f), fg, text);
}

/// 在单次 Present 周期内驱动热键兜底、IPC 轮询与 DX12/DX11 ImGui 帧提交。
void RenderFrameOnSwapChain(IDXGISwapChain* swapChain) {
    if (!g_imguiInitialized) {
        if (!TryInitImGuiForSwapChain(swapChain)) {
            return;
        }
    }
    if (swapChain != g_boundSwapChain) {
        return;
    }

    PollFallbackHotkeys();
    IpcBridge::Instance().PollFromLua();

    ImGuiIO& io = ImGui::GetIO();
    bool menuOpen = g_menuOpen.load();
    io.MouseDrawCursor = menuOpen;

    if (g_activeApi == GraphicsApi::DX12) {
        IDXGISwapChain3* sc3 = nullptr;
        if (FAILED(swapChain->QueryInterface(IID_PPV_ARGS(&sc3))) || !sc3) return;
        UINT backIdx = sc3->GetCurrentBackBufferIndex();
        sc3->Release();

        if (backIdx >= g_dx12Frames.size() || !g_dx12Frames[backIdx].backBuffer) {
            if (!CreateDx12BackBuffers(swapChain)) return;
            if (backIdx >= g_dx12Frames.size() || !g_dx12Frames[backIdx].backBuffer) return;
        }

        Dx12FrameContext& frame = g_dx12Frames[backIdx];
        // 等待该帧的 CommandAllocator 上次提交已由 GPU 执行完毕
        if (frame.fenceValue != 0 && g_d3d12Fence->GetCompletedValue() < frame.fenceValue) {
            g_d3d12Fence->SetEventOnCompletion(frame.fenceValue, g_d3d12FenceEvent);
            WaitForSingleObject(g_d3d12FenceEvent, 500);
        }

        ImGui_ImplDX12_NewFrame();
        ImGui_ImplWin32_NewFrame();
        ImGui::NewFrame();

        DrawStartupBanner();
        RenderOverlayFrame(menuOpen, g_uiScale);
        if (menuOpen != g_menuOpen.load()) {
            g_menuOpen.store(menuOpen);
        }

        ImGui::Render();

        if (FAILED(frame.cmdAllocator->Reset())) return;
        if (FAILED(g_d3d12CmdList->Reset(frame.cmdAllocator, nullptr))) return;

        D3D12_RESOURCE_BARRIER barrier{};
        barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barrier.Flags = D3D12_RESOURCE_BARRIER_FLAG_NONE;
        barrier.Transition.pResource = frame.backBuffer;
        barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
        barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET;

        g_d3d12CmdList->ResourceBarrier(1, &barrier);
        g_d3d12CmdList->OMSetRenderTargets(1, &frame.rtvHandle, FALSE, nullptr);
        ID3D12DescriptorHeap* heaps[] = {g_d3d12SrvHeap};
        g_d3d12CmdList->SetDescriptorHeaps(1, heaps);

        ImGui_ImplDX12_RenderDrawData(ImGui::GetDrawData(), g_d3d12CmdList);

        barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
        barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
        g_d3d12CmdList->ResourceBarrier(1, &barrier);
        g_d3d12CmdList->Close();

        ID3D12CommandList* cmdLists[] = {g_d3d12CmdList};
        if (g_origExecuteCommandLists) {
            g_origExecuteCommandLists(g_d3d12CommandQueue, 1, cmdLists);
        } else {
            g_d3d12CommandQueue->ExecuteCommandLists(1, cmdLists);
        }

        frame.fenceValue = ++g_d3d12FenceValue;
        g_d3d12CommandQueue->Signal(g_d3d12Fence, frame.fenceValue);
    } else if (g_activeApi == GraphicsApi::DX11) {
        if (!g_d3d11Rtv) {
            CreateDx11Rtv(swapChain);
        }
        ImGui_ImplDX11_NewFrame();
        ImGui_ImplWin32_NewFrame();
        ImGui::NewFrame();

        DrawStartupBanner();
        RenderOverlayFrame(menuOpen, g_uiScale);
        if (menuOpen != g_menuOpen.load()) {
            g_menuOpen.store(menuOpen);
        }

        ImGui::Render();
        if (g_d3d11Rtv) {
            g_d3d11Context->OMSetRenderTargets(1, &g_d3d11Rtv, nullptr);
            ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
        }
    }
}

// ==================== 图形钩子回调 ====================

/// DX12 ExecuteCommandLists 钩子：在初始化锁定前捕获游戏主 DIRECT 命令队列供 Present 复用。
void STDMETHODCALLTYPE HookedExecuteCommandLists(
    ID3D12CommandQueue* queue, UINT numCommandLists, ID3D12CommandList* const* ppCommandLists) {
    if (!g_shuttingDown.load() && !g_dx12QueueLocked.load() && queue) {
        D3D12_COMMAND_QUEUE_DESC desc = queue->GetDesc();
        if (desc.Type == D3D12_COMMAND_LIST_TYPE_DIRECT) {
            ID3D12Device* dev = nullptr;
            if (SUCCEEDED(queue->GetDevice(IID_PPV_ARGS(&dev))) && dev) {
                std::lock_guard<std::mutex> lk(g_queueMutex);
                bool exists = false;
                for (const auto& c : g_candidateQueues) {
                    if (c.device == dev && c.queue == queue) {
                        exists = true;
                        break;
                    }
                }
                if (!exists && g_candidateQueues.size() < 8) {
                    g_candidateQueues.push_back({dev, queue});
                    OverlayLog("Captured DIRECT DX12 CommandQueue=0x%p (Device=0x%p)", queue, dev);
                }
                dev->Release();
            }
        }
    }
    g_origExecuteCommandLists(queue, numCommandLists, ppCommandLists);
}

/// IDXGISwapChain::Present 钩子：带线程局部重入锁保护渲染悬浮层后再转交原 Present。
HRESULT STDMETHODCALLTYPE HookedPresent(IDXGISwapChain* swapChain, UINT syncInterval, UINT flags) {
    if (!g_shuttingDown.load() && !t_inPresent && swapChain) {
        t_inPresent = true;
        RenderFrameOnSwapChain(swapChain);
        t_inPresent = false;
    }
    return g_origPresent(swapChain, syncInterval, flags);
}

/// IDXGISwapChain1::Present1 钩子：兼容 UE4 DX12 Flip-Model 直接调用 Present1 的路径。
HRESULT STDMETHODCALLTYPE HookedPresent1(
    IDXGISwapChain1* swapChain, UINT syncInterval, UINT presentFlags, const DXGI_PRESENT_PARAMETERS* pPresentParameters) {
    if (!g_shuttingDown.load() && !t_inPresent && swapChain) {
        t_inPresent = true;
        RenderFrameOnSwapChain(swapChain);
        t_inPresent = false;
    }
    return g_origPresent1(swapChain, syncInterval, presentFlags, pPresentParameters);
}

/// IDXGISwapChain::ResizeBuffers 钩子：响应 Alt+Tab 或分辨率切换，先等 GPU 空闲并释放旧后缓冲，再重建。
HRESULT STDMETHODCALLTYPE HookedResizeBuffers(
    IDXGISwapChain* swapChain, UINT bufferCount, UINT width, UINT height,
    DXGI_FORMAT newFormat, UINT swapChainFlags) {
    if (g_imguiInitialized && swapChain == g_boundSwapChain) {
        OverlayLog("ResizeBuffers called (%ux%u, buffers=%u)", width, height, bufferCount);
        if (g_activeApi == GraphicsApi::DX12) {
            WaitForDx12GpuIdle();
            ReleaseDx12BackBuffers();
        } else if (g_activeApi == GraphicsApi::DX11) {
            ReleaseDx11Rtv();
            ImGui_ImplDX11_InvalidateDeviceObjects();
        }
    }

    HRESULT hr = g_origResizeBuffers(swapChain, bufferCount, width, height, newFormat, swapChainFlags);

    if (SUCCEEDED(hr) && g_imguiInitialized && swapChain == g_boundSwapChain) {
        if (g_activeApi == GraphicsApi::DX12) {
            CreateDx12BackBuffers(swapChain);
        } else if (g_activeApi == GraphicsApi::DX11) {
            CreateDx11Rtv(swapChain);
            ImGui_ImplDX11_CreateDeviceObjects();
        }
    }
    return hr;
}

struct ResolvedVTableAddrs {
    void* present = nullptr;
    void* present1 = nullptr;
    void* resizeBuffers = nullptr;
    void* executeCommandLists = nullptr;
};

/// 通过临时 DX12（失败则回退 DX11）SwapChain 解析真实虚表函数地址。
bool ResolveGraphicsVTables(ResolvedVTableAddrs& out) {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.style = CS_CLASSDC;
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"GroundedQoL_DummyGraphicsWnd";
    RegisterClassExW(&wc);

    HWND dummyHwnd = CreateWindowExW(
        0, wc.lpszClassName, L"", WS_OVERLAPPEDWINDOW,
        0, 0, 128, 128, nullptr, nullptr, wc.hInstance, nullptr);
    if (!dummyHwnd) {
        UnregisterClassW(wc.lpszClassName, wc.hInstance);
        return false;
    }

    // 1. 尝试 DX12 解析（可同时拿到 ExecuteCommandLists 与 DXGI Flip-Model SwapChain 虚表）
    IDXGIFactory4* factory = nullptr;
    ID3D12Device* dev12 = nullptr;
    ID3D12CommandQueue* queue12 = nullptr;
    IDXGISwapChain1* swap12 = nullptr;

    if (SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))) &&
        SUCCEEDED(D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&dev12)))) {
        D3D12_COMMAND_QUEUE_DESC qd{};
        qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        qd.Flags = D3D12_COMMAND_QUEUE_FLAG_NONE;
        if (SUCCEEDED(dev12->CreateCommandQueue(&qd, IID_PPV_ARGS(&queue12)))) {
            void** qVtable = *reinterpret_cast<void***>(queue12);
            out.executeCommandLists = qVtable[10];

            DXGI_SWAP_CHAIN_DESC1 sd1{};
            sd1.BufferCount = 2;
            sd1.Width = 128;
            sd1.Height = 128;
            sd1.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            sd1.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
            sd1.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
            sd1.SampleDesc.Count = 1;

            if (SUCCEEDED(factory->CreateSwapChainForHwnd(queue12, dummyHwnd, &sd1, nullptr, nullptr, &swap12)) && swap12) {
                void** sVtable = *reinterpret_cast<void***>(swap12);
                out.present = sVtable[8];
                out.resizeBuffers = sVtable[13];
                out.present1 = sVtable[22];
                OverlayLog("Resolved DX12 VTables: Present=0x%p Present1=0x%p Resize=0x%p ExecCmdLists=0x%p",
                           out.present, out.present1, out.resizeBuffers, out.executeCommandLists);
            }
        }
    }

    if (swap12) swap12->Release();
    if (queue12) queue12->Release();
    if (dev12) dev12->Release();
    if (factory) factory->Release();

    // 2. 若 DX12 解析未拿到 SwapChain（极端兼容情况），回退 DX11
    if (!out.present) {
        DXGI_SWAP_CHAIN_DESC sd{};
        sd.BufferCount = 1;
        sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        sd.OutputWindow = dummyHwnd;
        sd.SampleDesc.Count = 1;
        sd.Windowed = TRUE;
        sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

        IDXGISwapChain* dummySwap = nullptr;
        ID3D11Device* dummyDev = nullptr;
        ID3D11DeviceContext* dummyCtx = nullptr;
        D3D_FEATURE_LEVEL fl{};
        if (SUCCEEDED(D3D11CreateDeviceAndSwapChain(
                nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0,
                D3D11_SDK_VERSION, &sd, &dummySwap, &dummyDev, &fl, &dummyCtx)) && dummySwap) {
            void** vtable = *reinterpret_cast<void***>(dummySwap);
            out.present = vtable[8];
            out.resizeBuffers = vtable[13];
            OverlayLog("Resolved DX11 Fallback VTables: Present=0x%p Resize=0x%p", out.present, out.resizeBuffers);
        }
        if (dummySwap) dummySwap->Release();
        if (dummyCtx) dummyCtx->Release();
        if (dummyDev) dummyDev->Release();
    }

    DestroyWindow(dummyHwnd);
    UnregisterClassW(wc.lpszClassName, wc.hInstance);
    return out.present != nullptr && out.resizeBuffers != nullptr;
}

} // namespace

/// 追加一条带本地毫秒时间戳的诊断日志到 data/overlay.log（线程安全）。
void OverlayLog(const char* fmt, ...) {
    std::lock_guard<std::mutex> lk(g_logMutex);
    std::wstring dir = IpcBridge::Instance().GetDataDir();
    if (dir.empty()) return;
    std::wstring path = dir + L"\\overlay.log";

    char msg[1024];
    va_list args;
    va_start(args, fmt);
    std::vsnprintf(msg, sizeof(msg), fmt, args);
    va_end(args);

    SYSTEMTIME st{};
    GetLocalTime(&st);
    char line[1200];
    std::snprintf(line, sizeof(line), "[%02u:%02u:%02u.%03u] %s\n",
                  st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, msg);

    std::ofstream ofs(path, std::ios::binary | std::ios::app);
    if (ofs.is_open()) {
        ofs << line;
        ofs.flush();
    }
}

/// 等待 dxgi.dll 就绪、解析虚拟交换链虚表地址并通过 MinHook 挂接全部图形回调。
bool InstallGraphicsHook() {
    OverlayLog("InstallGraphicsHook() starting...");

    // 等待游戏加载 dxgi.dll（最长等待 30 秒）
    for (int i = 0; i < 120; ++i) {
        if (GetModuleHandleW(L"dxgi.dll")) {
            break;
        }
        Sleep(250);
    }

    ResolvedVTableAddrs addrs{};
    if (!ResolveGraphicsVTables(addrs)) {
        OverlayLog("ERROR: ResolveGraphicsVTables failed!");
        return false;
    }

    MH_STATUS st = MH_Initialize();
    if (st != MH_OK && st != MH_ERROR_ALREADY_INITIALIZED) {
        OverlayLog("ERROR: MH_Initialize failed: %d", static_cast<int>(st));
        return false;
    }

    if (addrs.executeCommandLists) {
        st = MH_CreateHook(addrs.executeCommandLists,
                           reinterpret_cast<void*>(&HookedExecuteCommandLists),
                           reinterpret_cast<void**>(&g_origExecuteCommandLists));
        OverlayLog("MH_CreateHook(ExecuteCommandLists) -> %d", static_cast<int>(st));
    }

    st = MH_CreateHook(addrs.present, reinterpret_cast<void*>(&HookedPresent),
                       reinterpret_cast<void**>(&g_origPresent));
    OverlayLog("MH_CreateHook(Present) -> %d", static_cast<int>(st));
    if (st != MH_OK) return false;

    if (addrs.present1 && addrs.present1 != addrs.present) {
        st = MH_CreateHook(addrs.present1, reinterpret_cast<void*>(&HookedPresent1),
                           reinterpret_cast<void**>(&g_origPresent1));
        OverlayLog("MH_CreateHook(Present1) -> %d", static_cast<int>(st));
    }

    st = MH_CreateHook(addrs.resizeBuffers, reinterpret_cast<void*>(&HookedResizeBuffers),
                       reinterpret_cast<void**>(&g_origResizeBuffers));
    OverlayLog("MH_CreateHook(ResizeBuffers) -> %d", static_cast<int>(st));
    if (st != MH_OK) return false;

    st = MH_EnableHook(MH_ALL_HOOKS);
    OverlayLog("MH_EnableHook(ALL) -> %d", static_cast<int>(st));
    return st == MH_OK;
}

/// 安全卸载窗口与图形钩子，等待 GPU 空闲并按序释放 ImGui 与 DX12/DX11 全部 COM 资源。
void UninstallGraphicsHook() {
    g_shuttingDown.store(true);
    if (g_gameHwnd && g_origWndProc) {
        SetWindowLongPtrW(g_gameHwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(g_origWndProc));
        g_origWndProc = nullptr;
    }
    MH_DisableHook(MH_ALL_HOOKS);
    MH_Uninitialize();

    if (g_imguiInitialized) {
        if (g_activeApi == GraphicsApi::DX12) {
            WaitForDx12GpuIdle();
            ImGui_ImplDX12_Shutdown();
        } else if (g_activeApi == GraphicsApi::DX11) {
            ImGui_ImplDX11_Shutdown();
        }
        ImGui_ImplWin32_Shutdown();
        ImGui::DestroyContext();
        g_imguiInitialized = false;
    }

    ReleaseDx11Rtv();
    if (g_d3d11Context) { g_d3d11Context->Release(); g_d3d11Context = nullptr; }
    if (g_d3d11Device) { g_d3d11Device->Release(); g_d3d11Device = nullptr; }

    ReleaseDx12BackBuffers();
    for (auto& f : g_dx12Frames) {
        if (f.cmdAllocator) f.cmdAllocator->Release();
    }
    g_dx12Frames.clear();
    if (g_d3d12CmdList) { g_d3d12CmdList->Release(); g_d3d12CmdList = nullptr; }
    if (g_d3d12Fence) { g_d3d12Fence->Release(); g_d3d12Fence = nullptr; }
    if (g_d3d12FenceEvent) { CloseHandle(g_d3d12FenceEvent); g_d3d12FenceEvent = nullptr; }
    if (g_d3d12RtvHeap) { g_d3d12RtvHeap->Release(); g_d3d12RtvHeap = nullptr; }
    if (g_d3d12SrvHeap) { g_d3d12SrvHeap->Release(); g_d3d12SrvHeap = nullptr; }
    if (g_d3d12CommandQueue) { g_d3d12CommandQueue->Release(); g_d3d12CommandQueue = nullptr; }
    if (g_d3d12Device) { g_d3d12Device->Release(); g_d3d12Device = nullptr; }
}

bool IsMenuOpen() {
    return g_menuOpen.load();
}

void SetMenuOpen(bool open) {
    g_menuOpen.store(open);
}

const char* GetActiveGraphicsBackend() {
    if (g_activeApi == GraphicsApi::DX12) return "DX12";
    if (g_activeApi == GraphicsApi::DX11) return "DX11";
    return "Unknown";
}

HWND GetGameHwnd() {
    return g_gameHwnd;
}

} // namespace gqol
