/*
 * 文件：overlay/src/dx11_hook.cpp
 * 职责：实现自适应 DirectX 12 / DirectX 11 图形钩子、Win32 WndProc 输入隔离、
 *       窗口主线程按需恢复的混合 IME/TSF 中文输入法管理、单一系统原生光标托管，
 *       以及空闲零开销渲染直通（见 ADR-0003 / ADR-0004）。
 * 关键架构说明：
 *   1. 空闲零开销直通：当菜单关闭、M 地图关闭且开场提示条消失后，Present 直接放行，
 *      跳过 DX12 Fence 等待、BackBuffer ResourceBarrier、ExecuteCommandLists 与 ImGui 帧构建。
 *   2. 零光标干扰：永久设置 ImGuiConfigFlags_NoMouseCursorChange 且禁用 io.MouseDrawCursor；
 *      菜单关闭时完全不调用 ImGui_ImplWin32_WndProcHandler，绝不触碰 SetCursor/SetCapture/ClipCursor；
 *      菜单打开时在窗口线程托管单一系统光标并临时解锁 ClipCursor，关闭或 Alt+Tab 失焦立刻精确归还。
 *   3. 窗口主线程混合 IME/TSF：覆盖 ImGui Platform_SetImeDataFn，通过非阻塞 PostMessageW 切换到窗口线程
 *      按需调用 ImmAssociateContextEx(IACE_DEFAULT) 恢复被 UE4 禁用的输入法上下文并定位候选框；
 *      无边框/窗口模式走系统原生候选框，独占全屏或手动切自绘时由 IMM32 + TSF ITfUIElementSink
 *      采集拼音与候选列表交由 ImGui 绘制，失焦或关菜单立刻还原 UE4 原先的禁用状态。
 */

#include "dx11_hook.h"
#include "ipc.h"
#include "overlay_ui.h"

#include <d3d11.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <imm.h>
#include <msctf.h>
#include <MinHook.h>
#include <imgui.h>
#include <imgui_impl_win32.h>
#include <imgui_impl_dx11.h>
#include <imgui_impl_dx12.h>

#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>
#include <vector>

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam);

namespace gqol {

namespace {

/// 跨线程投递给游戏主窗口线程的私有消息（严格非阻塞 PostMessageW，避免与 RHI 线程死锁）。
constexpr UINT WM_GQOL_SYNC_IME = WM_APP + 0x4751;
constexpr UINT WM_GQOL_SYNC_CURSOR = WM_APP + 0x4752;
constexpr UINT WM_GQOL_SELECT_CANDIDATE = WM_APP + 0x4753;

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
using TFGetThreadMgrFn = HRESULT(WINAPI*)(ITfThreadMgr**);

// MinHook 保存的原函数蹦床指针与原窗口过程
PresentFn g_origPresent = nullptr;
Present1Fn g_origPresent1 = nullptr;
ResizeBuffersFn g_origResizeBuffers = nullptr;
ExecuteCommandListsFn g_origExecuteCommandLists = nullptr;
WNDPROC g_origWndProc = nullptr;

std::mutex g_logMutex;
std::mutex g_queueMutex;
std::mutex g_srvAllocMutex;
// 必须使用 recursive_mutex：ImGui_ImplWin32_WndProcHandler 内部调用 SetCapture/ReleaseCapture/TrackMouseEvent
// 时 Windows 会同步重入 HookedWndProc（如 WM_CAPTURECHANGED），非递归 mutex 会在同线程重入时抛 std::system_error 闪退。
std::recursive_mutex g_imguiInputMutex;
std::mutex g_imeStateMutex;

// 全局运行期状态（涉及渲染线程与消息线程共享的标志使用 atomic）
GraphicsApi g_activeApi = GraphicsApi::None;
HWND g_gameHwnd = nullptr;
IDXGISwapChain* g_boundSwapChain = nullptr;
bool g_imguiInitialized = false;
float g_uiScale = 1.0f;
std::atomic<unsigned long long> g_initTick{0};
unsigned long long g_lastToggleTick = 0;
unsigned long long g_lastFullscreenCheckTick = 0;
std::atomic<unsigned long long> g_lastSoftRefreshTriggerTick{0};
bool g_prevInsertDown = false;
bool g_prevF8Down = false;
bool g_prevRenderedMenuOpen = false;
std::atomic<bool> g_menuOpen{false};
std::atomic<bool> g_shuttingDown{false};
std::atomic<bool> g_isExclusiveFullscreen{false};
std::atomic<int> g_desiredImGuiCursor{ImGuiMouseCursor_Arrow};
// 防止 DXGI Present1 内部调用 Present 或第三方叠加层转发导致同一帧重复渲染 ImGui
thread_local bool t_inPresent = false;

// 性能与测试观测指标
std::atomic<bool> g_lastFrameIdle{false};
std::atomic<unsigned long long> g_idleFrameCount{0};
std::atomic<unsigned long long> g_renderedFrameCount{0};
std::atomic<int> g_imeCharsCommitted{0};

// ==================== 光标接管状态（严格仅在窗口主线程读写） ====================
bool g_cursorOverrideActive = false;
int g_showCursorAdded = 0;
bool g_hasSavedClipRect = false;
RECT g_savedClipRect{};

// ==================== IME / TSF 状态 ====================
// 渲染线程写入的期望状态 -> 通过 PostMessageW(WM_GQOL_SYNC_IME) 通知窗口主线程执行
std::atomic<bool> g_imeWantVisible{false};
std::atomic<float> g_imeWantPosX{0.0f};
std::atomic<float> g_imeWantPosY{0.0f};
std::atomic<float> g_imeWantLineH{20.0f};
std::atomic<bool> g_imeComposing{false};
std::atomic<unsigned long long> g_lastImeEndTick{0};
std::atomic<bool> g_imeForceTestOverride{false};

// 窗口主线程私有状态
bool g_imeAttachedOnWndThread = false;
bool g_ue4HadImeDisabled = false;
bool g_lastAppliedSelfDrawn = false;
ImeCandidateState g_imeState;

// TSF ITfUIElementSink（用于 Windows 10/11 现代微软拼音在内置自绘模式下的候选列表采集与 UE4 禁用文档管理器解绑）
class TsfUiElementSink;
ITfThreadMgr* g_tsfThreadMgr = nullptr;
ITfUIElementMgr* g_tsfUiElemMgr = nullptr;
ITfDocumentMgr* g_savedUe4TsfDocMgr = nullptr;
TsfUiElementSink* g_tsfSink = nullptr;
DWORD g_tsfSinkCookie = TF_INVALID_COOKIE;
bool g_tsfInitAttempted = false;

// ==================== DX11 状态 ====================
ID3D11Device* g_d3d11Device = nullptr;
ID3D11DeviceContext* g_d3d11Context = nullptr;
ID3D11RenderTargetView* g_d3d11Rtv = nullptr;

// ==================== DX12 状态 ====================
struct Dx12CandidateQueue {
    ID3D12Device* device = nullptr;
    ID3D12CommandQueue* queue = nullptr;
};
std::vector<Dx12CandidateQueue> g_candidateQueues;
std::atomic<bool> g_dx12QueueLocked{false};

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

// ==================== 编码与辅助工具 ====================

/// 将 UTF-16 宽字符串转换为 UTF-8 字符串（供 IMM32/TSF 拼音与候选字渲染使用）。
std::string WideToUtf8(const wchar_t* wstr, int wlen) {
    if (!wstr || wlen == 0) return {};
    int bytes = ::WideCharToMultiByte(CP_UTF8, 0, wstr, wlen, nullptr, 0, nullptr, nullptr);
    if (bytes <= 0) return {};
    std::string out(static_cast<size_t>(bytes), '\0');
    ::WideCharToMultiByte(CP_UTF8, 0, wstr, wlen, out.data(), bytes, nullptr, nullptr);
    // 剔除可能附带的末尾 NUL
    while (!out.empty() && out.back() == '\0') {
        out.pop_back();
    }
    return out;
}

/// 判定当前是否应当启用 ImGui 内置自绘候选条（结合配置模式与独占全屏检测，见 ADR-0003）。
bool ComputeUseSelfDrawnIme() {
    auto cfg = IpcBridge::Instance().GetConfigSnapshot();
    const int mode = cfg ? cfg->imeCandidateMode : 0;
    if (mode == 1) return false; // 强制系统原生候选框
    if (mode == 2) return true;  // 强制内置自绘候选条
    return g_isExclusiveFullscreen.load(std::memory_order_relaxed); // 自动：独占全屏降级内置自绘
}

/// 将 ImGui 光标枚举映射为对应的 Windows 原生系统光标资源 ID。
LPCWSTR ImGuiCursorToWin32(int imguiCursor) {
    switch (imguiCursor) {
        case ImGuiMouseCursor_TextInput:  return IDC_IBEAM;
        case ImGuiMouseCursor_ResizeAll:  return IDC_SIZEALL;
        case ImGuiMouseCursor_ResizeEW:   return IDC_SIZEWE;
        case ImGuiMouseCursor_ResizeNS:   return IDC_SIZENS;
        case ImGuiMouseCursor_ResizeNESW: return IDC_SIZENESW;
        case ImGuiMouseCursor_ResizeNWSE: return IDC_SIZENWSE;
        case ImGuiMouseCursor_Hand:       return IDC_HAND;
        case ImGuiMouseCursor_Wait:       return IDC_WAIT;
        case ImGuiMouseCursor_Progress:   return IDC_APPSTARTING;
        case ImGuiMouseCursor_NotAllowed: return IDC_NO;
        case ImGuiMouseCursor_Arrow:
        default:                          return IDC_ARROW;
    }
}

/// 在窗口主线程安全更新 Win32 IME 组词窗与候选窗锚点坐标（紧贴 ImGui 输入框正下方）。
void UpdateImeWindowPosOnWindowThread(HWND hWnd) {
    if (!hWnd) return;
    HIMC himc = ::ImmGetContext(hWnd);
    if (!himc) return;

    const LONG px = static_cast<LONG>(g_imeWantPosX.load(std::memory_order_relaxed));
    const LONG py = static_cast<LONG>(g_imeWantPosY.load(std::memory_order_relaxed));
    const LONG lh = std::max<LONG>(16, static_cast<LONG>(g_imeWantLineH.load(std::memory_order_relaxed)));

    COMPOSITIONFORM cf{};
    cf.dwStyle = CFS_POINT;
    cf.ptCurrentPos.x = px;
    cf.ptCurrentPos.y = py;
    ::ImmSetCompositionWindow(himc, &cf);

    CANDIDATEFORM candExcl{};
    candExcl.dwIndex = 0;
    candExcl.dwStyle = CFS_EXCLUDE;
    candExcl.ptCurrentPos.x = px;
    candExcl.ptCurrentPos.y = py + lh;
    candExcl.rcArea.left = px;
    candExcl.rcArea.top = py;
    candExcl.rcArea.right = px + 4;
    candExcl.rcArea.bottom = py + lh + 2;
    ::ImmSetCandidateWindow(himc, &candExcl);

    CANDIDATEFORM candPos{};
    candPos.dwIndex = 0;
    candPos.dwStyle = CFS_CANDIDATEPOS;
    candPos.ptCurrentPos.x = px;
    candPos.ptCurrentPos.y = py + lh + 2;
    ::ImmSetCandidateWindow(himc, &candPos);

    ::ImmReleaseContext(hWnd, himc);
}

/// 从 IMM32 读取当前拼音组词串与光标偏移到共享快照。
void ReadImmCompositionOnWindowThread(HWND hWnd, LPARAM lParam) {
    HIMC himc = ::ImmGetContext(hWnd);
    if (!himc) return;

    std::string compUtf8;
    int cursorByte = 0;
    bool hasCompUpdate = (lParam == 0) || ((lParam & (GCS_COMPSTR | GCS_CURSORPOS)) != 0);

    if (hasCompUpdate) {
        if (lParam != 0) {
            LONG bytes = ::ImmGetCompositionStringW(himc, GCS_COMPSTR, nullptr, 0);
            if (bytes > 0) {
                std::vector<wchar_t> wbuf(static_cast<size_t>(bytes / sizeof(wchar_t)) + 1, L'\0');
                LONG got = ::ImmGetCompositionStringW(himc, GCS_COMPSTR, wbuf.data(), static_cast<DWORD>(bytes));
                if (got > 0) {
                    int wlen = static_cast<int>(got / sizeof(wchar_t));
                    compUtf8 = WideToUtf8(wbuf.data(), wlen);
                    LONG curW = ::ImmGetCompositionStringW(himc, GCS_CURSORPOS, nullptr, 0);
                    if (curW >= 0 && curW <= wlen) {
                        cursorByte = static_cast<int>(WideToUtf8(wbuf.data(), static_cast<int>(curW)).size());
                    } else {
                        cursorByte = static_cast<int>(compUtf8.size());
                    }
                }
            }
        }
        std::lock_guard<std::mutex> lk(g_imeStateMutex);
        g_imeState.compositionUtf8 = std::move(compUtf8);
        g_imeState.cursorByteOffset = cursorByte;
        if (g_imeState.compositionUtf8.empty() && g_imeState.candidates.empty() && lParam == 0) {
            g_imeState.composing = false;
            g_imeComposing.store(false);
        }
    }

    ::ImmReleaseContext(hWnd, himc);
}

/// 从 IMM32 读取当前候选字列表到共享快照（供内置自绘候选条使用）。
void ReadImmCandidateListOnWindowThread(HWND hWnd) {
    HIMC himc = ::ImmGetContext(hWnd);
    if (!himc) return;

    DWORD bytes = ::ImmGetCandidateListW(himc, 0, nullptr, 0);
    if (bytes > 0) {
        std::vector<uint8_t> raw(bytes);
        auto* list = reinterpret_cast<CANDIDATELIST*>(raw.data());
        if (::ImmGetCandidateListW(himc, 0, list, bytes) > 0 && list->dwCount > 0) {
            const UINT count = list->dwCount;
            const UINT pageSize = (list->dwPageSize > 0) ? std::min<UINT>(list->dwPageSize, 10) : 9;
            UINT pageStart = list->dwPageStart;
            if (pageStart >= count) pageStart = 0;
            const UINT pageEnd = std::min<UINT>(count, pageStart + pageSize);

            std::vector<std::string> items;
            items.reserve(pageEnd - pageStart);
            for (UINT i = pageStart; i < pageEnd; ++i) {
                const DWORD off = list->dwOffset[i];
                if (off < bytes) {
                    const auto* ws = reinterpret_cast<const wchar_t*>(raw.data() + off);
                    items.push_back(WideToUtf8(ws, -1));
                }
            }

            int selInPage = 0;
            if (list->dwSelection >= pageStart && list->dwSelection < pageEnd) {
                selInPage = static_cast<int>(list->dwSelection - pageStart);
            }

            std::lock_guard<std::mutex> lk(g_imeStateMutex);
            g_imeState.candidates = std::move(items);
            g_imeState.selectedIndex = selInPage;
            g_imeState.pageStart = static_cast<int>(pageStart);
            g_imeState.totalCandidates = static_cast<int>(count);
        }
    }

    ::ImmReleaseContext(hWnd, himc);
}

/// 轻量 COM TSF UIElementSink：在内置自绘模式下接管现代 Win10/11 微软拼音候选列表并隐藏系统浮窗。
class TsfUiElementSink final : public ITfUIElementSink {
public:
    STDMETHODIMP QueryInterface(REFIID riid, void** ppvObj) override {
        if (!ppvObj) return E_INVALIDARG;
        *ppvObj = nullptr;
        if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_ITfUIElementSink)) {
            *ppvObj = static_cast<ITfUIElementSink*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    STDMETHODIMP_(ULONG) AddRef() override {
        return static_cast<ULONG>(InterlockedIncrement(&m_refCount));
    }

    STDMETHODIMP_(ULONG) Release() override {
        LONG r = InterlockedDecrement(&m_refCount);
        if (r == 0) {
            delete this;
            return 0;
        }
        return static_cast<ULONG>(r);
    }

    STDMETHODIMP BeginUIElement(DWORD dwUIElementId, BOOL* pbShow) override {
        if (!pbShow) return E_INVALIDARG;
        // 非本插件输入框获焦或当前使用系统原生候选框时，完整放行原生 TSF 浮窗（绝不干扰游戏原生聊天框）
        if (!g_imeAttachedOnWndThread || !ComputeUseSelfDrawnIme()) {
            *pbShow = TRUE;
            return S_OK;
        }
        *pbShow = FALSE;
        UpdateCandidateFromElement(dwUIElementId);
        return S_OK;
    }

    STDMETHODIMP UpdateUIElement(DWORD dwUIElementId) override {
        if (g_imeAttachedOnWndThread && ComputeUseSelfDrawnIme()) {
            UpdateCandidateFromElement(dwUIElementId);
        }
        return S_OK;
    }

    STDMETHODIMP EndUIElement(DWORD dwUIElementId) override {
        if (dwUIElementId == m_activeCandId) {
            m_activeCandId = 0;
            std::lock_guard<std::mutex> lk(g_imeStateMutex);
            g_imeState.candidates.clear();
            g_imeState.selectedIndex = 0;
            g_imeState.pageStart = 0;
            g_imeState.totalCandidates = 0;
        }
        return S_OK;
    }

private:
    void UpdateCandidateFromElement(DWORD dwUIElementId) {
        if (!g_tsfUiElemMgr) return;
        ITfUIElement* elem = nullptr;
        if (FAILED(g_tsfUiElemMgr->GetUIElement(dwUIElementId, &elem)) || !elem) return;

        ITfCandidateListUIElement* cand = nullptr;
        if (SUCCEEDED(elem->QueryInterface(IID_ITfCandidateListUIElement, reinterpret_cast<void**>(&cand))) && cand) {
            m_activeCandId = dwUIElementId;
            UINT total = 0;
            UINT selection = 0;
            UINT curPage = 0;
            UINT pageCount = 0;
            cand->GetCount(&total);
            cand->GetSelection(&selection);
            cand->GetCurrentPage(&curPage);
            cand->GetPageIndex(nullptr, 0, &pageCount);

            UINT pageStart = 0;
            UINT pageEnd = std::min<UINT>(total, 9);
            if (pageCount > 0) {
                std::vector<UINT> pageIndices(pageCount, 0);
                if (SUCCEEDED(cand->GetPageIndex(pageIndices.data(), pageCount, &pageCount)) && curPage < pageCount) {
                    pageStart = pageIndices[curPage];
                    pageEnd = (curPage + 1 < pageCount) ? pageIndices[curPage + 1] : total;
                }
            }
            if (pageEnd > pageStart + 10) pageEnd = pageStart + 10;

            std::vector<std::string> items;
            if (pageEnd > pageStart) {
                items.reserve(pageEnd - pageStart);
                for (UINT i = pageStart; i < pageEnd; ++i) {
                    BSTR bstr = nullptr;
                    if (SUCCEEDED(cand->GetString(i, &bstr)) && bstr) {
                        items.push_back(WideToUtf8(bstr, static_cast<int>(::SysStringLen(bstr))));
                        ::SysFreeString(bstr);
                    }
                }
            }

            int selInPage = (selection >= pageStart && selection < pageEnd)
                ? static_cast<int>(selection - pageStart)
                : 0;

            {
                std::lock_guard<std::mutex> lk(g_imeStateMutex);
                g_imeState.candidates = std::move(items);
                g_imeState.selectedIndex = selInPage;
                g_imeState.pageStart = static_cast<int>(pageStart);
                g_imeState.totalCandidates = static_cast<int>(total);
            }
            cand->Release();
        }
        elem->Release();
    }

    LONG m_refCount = 1;
    DWORD m_activeCandId = 0;
};

/// 在窗口主线程懒挂载 TSF ITfUIElementSink（若当前线程已存在 TSF ThreadMgr，则接入候选字监听）。
void EnsureTsfSinkOnWindowThread() {
    if (g_tsfInitAttempted) return;
    g_tsfInitAttempted = true;

    HMODULE msctf = ::GetModuleHandleW(L"msctf.dll");
    if (!msctf) {
        msctf = ::LoadLibraryW(L"msctf.dll");
    }
    if (!msctf) return;

    auto pGetThreadMgr = reinterpret_cast<TFGetThreadMgrFn>(::GetProcAddress(msctf, "TF_GetThreadMgr"));
    if (!pGetThreadMgr) return;

    ITfThreadMgr* mgr = nullptr;
    if (FAILED(pGetThreadMgr(&mgr)) || !mgr) {
        return;
    }
    g_tsfThreadMgr = mgr;

    ITfUIElementMgr* uiMgr = nullptr;
    ITfSource* src = nullptr;
    if (SUCCEEDED(mgr->QueryInterface(IID_ITfUIElementMgr, reinterpret_cast<void**>(&uiMgr))) &&
        SUCCEEDED(mgr->QueryInterface(IID_ITfSource, reinterpret_cast<void**>(&src)))) {
        auto* sink = new TsfUiElementSink();
        DWORD cookie = TF_INVALID_COOKIE;
        if (SUCCEEDED(src->AdviseSink(IID_ITfUIElementSink, sink, &cookie))) {
            g_tsfUiElemMgr = uiMgr;
            g_tsfSink = sink;
            g_tsfSinkCookie = cookie;
            OverlayLog("TSF ITfUIElementSink installed on window thread");
        } else {
            sink->Release();
            uiMgr->Release();
        }
        src->Release();
    } else {
        if (uiMgr) uiMgr->Release();
        if (src) src->Release();
    }
}

/// 卸载窗口主线程上的 TSF UIElementSink 与暂存的 UE4 文档管理器引用。
void ReleaseTsfSinkOnWindowThread() {
    if (g_savedUe4TsfDocMgr) {
        if (g_tsfThreadMgr && g_gameHwnd) {
            ITfDocumentMgr* tmp = nullptr;
            g_tsfThreadMgr->AssociateFocus(g_gameHwnd, g_savedUe4TsfDocMgr, &tmp);
            if (tmp) tmp->Release();
        }
        g_savedUe4TsfDocMgr->Release();
        g_savedUe4TsfDocMgr = nullptr;
    }
    if (g_tsfThreadMgr && g_tsfSinkCookie != TF_INVALID_COOKIE) {
        ITfSource* src = nullptr;
        if (SUCCEEDED(g_tsfThreadMgr->QueryInterface(IID_ITfSource, reinterpret_cast<void**>(&src))) && src) {
            src->UnadviseSink(g_tsfSinkCookie);
            src->Release();
        }
    }
    g_tsfSinkCookie = TF_INVALID_COOKIE;
    if (g_tsfSink) { g_tsfSink->Release(); g_tsfSink = nullptr; }
    if (g_tsfUiElemMgr) { g_tsfUiElemMgr->Release(); g_tsfUiElemMgr = nullptr; }
    if (g_tsfThreadMgr) { g_tsfThreadMgr->Release(); g_tsfThreadMgr = nullptr; }
}

/// 在窗口主线程停用本插件的临时 IME/TSF 关联，并精确还原 UE4 原先的禁用状态（绝不残留悬浮候选窗）。
void DeactivateImeOnWindowThread(HWND hWnd) {
    if (!hWnd) return;
    if (g_imeAttachedOnWndThread) {
        if (HIMC himc = ::ImmGetContext(hWnd)) {
            ::ImmNotifyIME(himc, NI_COMPOSITIONSTR, CPS_CANCEL, 0);
            ::ImmReleaseContext(hWnd, himc);
        }
        if (g_ue4HadImeDisabled) {
            ::ImmAssociateContextEx(hWnd, nullptr, 0);
        }
        if (g_savedUe4TsfDocMgr) {
            if (g_tsfThreadMgr) {
                ITfDocumentMgr* tmp = nullptr;
                g_tsfThreadMgr->AssociateFocus(hWnd, g_savedUe4TsfDocMgr, &tmp);
                if (tmp) tmp->Release();
                g_tsfThreadMgr->SetFocus(g_savedUe4TsfDocMgr);
            }
            g_savedUe4TsfDocMgr->Release();
            g_savedUe4TsfDocMgr = nullptr;
        }
        g_imeAttachedOnWndThread = false;
        g_ue4HadImeDisabled = false;
    }

    g_imeComposing.store(false);
    std::lock_guard<std::mutex> lk(g_imeStateMutex);
    g_imeState.active = false;
    g_imeState.composing = false;
    g_imeState.compositionUtf8.clear();
    g_imeState.cursorByteOffset = 0;
    g_imeState.candidates.clear();
    g_imeState.selectedIndex = 0;
    g_imeState.pageStart = 0;
    g_imeState.totalCandidates = 0;
}

/// 在窗口主线程同步 IME/TSF 启用状态、候选框显示模式与输入框锚点坐标。
void SyncImeOnWindowThread(HWND hWnd) {
    if (!hWnd) return;
    const bool want = g_menuOpen.load() && g_imeWantVisible.load() &&
        (::GetForegroundWindow() == hWnd || ::GetActiveWindow() == hWnd || g_imeForceTestOverride.load());
    const bool useSelfDrawn = ComputeUseSelfDrawnIme();

    if (!want) {
        DeactivateImeOnWindowThread(hWnd);
        std::lock_guard<std::mutex> lk(g_imeStateMutex);
        g_imeState.useSelfDrawnUi = useSelfDrawn;
        g_imeState.isExclusiveFullscreen = g_isExclusiveFullscreen.load(std::memory_order_relaxed);
        return;
    }

    EnsureTsfSinkOnWindowThread();

    bool modeChanged = (g_imeAttachedOnWndThread && g_lastAppliedSelfDrawn != useSelfDrawn);
    if (!g_imeAttachedOnWndThread) {
        // 1. 暂存并临时解绑 UE4 关联在窗口上的 TSF 文档管理器（UE4 的 TSFDisabledDocumentManager
        //    可能为空栈或压入了带 GUID_COMPARTMENT_KEYBOARD_DISABLED 的上下文，单靠 ImmAssociateContextEx
        //    无法覆盖它；菜单打开期间输入完全归本悬浮层，先暂存并解绑、失焦时精确归还给 UE4）。
        bool detachedUe4Tsf = false;
        if (g_tsfThreadMgr && !g_savedUe4TsfDocMgr) {
            ITfDocumentMgr* prevDoc = nullptr;
            HRESULT hrAssoc = g_tsfThreadMgr->AssociateFocus(hWnd, nullptr, &prevDoc);
            if (SUCCEEDED(hrAssoc) && prevDoc) {
                g_savedUe4TsfDocMgr = prevDoc;
                detachedUe4Tsf = true;
            }
            OverlayLog("TSF AssociateFocus(NULL) hr=0x%08lX prevDoc=0x%p", hrAssoc, prevDoc);
        }

        // 2. 检测并恢复 IMM32 默认上下文（若刚解绑了 UE4 TSF 文档管理器，则强制触发 CUAS 重建活跃绑定）
        HIMC existing = ::ImmGetContext(hWnd);
        if (existing) {
            ::ImmReleaseContext(hWnd, existing);
            g_ue4HadImeDisabled = false;
            if (detachedUe4Tsf) {
                ::ImmAssociateContext(hWnd, nullptr);
                ::ImmAssociateContextEx(hWnd, nullptr, IACE_DEFAULT);
            }
        } else {
            g_ue4HadImeDisabled = true;
            ::ImmAssociateContextEx(hWnd, nullptr, IACE_DEFAULT);
        }

        // 3. 主动将 TSF 焦点切到刚由 CUAS 恢复的活跃文档管理器（解决 AssociateFocus(NULL) 后 GetFocus 为空的问题）
        if (g_tsfThreadMgr && detachedUe4Tsf) {
            ITfDocumentMgr* cuasDoc = nullptr;
            ITfDocumentMgr* tmpDoc = nullptr;
            if (SUCCEEDED(g_tsfThreadMgr->AssociateFocus(hWnd, nullptr, &cuasDoc)) && cuasDoc) {
                g_tsfThreadMgr->AssociateFocus(hWnd, cuasDoc, &tmpDoc);
                if (tmpDoc) tmpDoc->Release();
                g_tsfThreadMgr->SetFocus(cuasDoc);
                cuasDoc->Release();
            }
        }

        g_imeAttachedOnWndThread = true;
        g_lastAppliedSelfDrawn = useSelfDrawn;
        ::DefWindowProcW(hWnd, WM_IME_SETCONTEXT, TRUE, useSelfDrawn ? 0 : ISC_SHOWUIALL);
        OverlayLog("IME activated on window thread (ue4ImmDisabled=%d, ue4TsfDetached=%d, selfDrawn=%d, fs=%d)",
                   g_ue4HadImeDisabled ? 1 : 0, detachedUe4Tsf ? 1 : 0, useSelfDrawn ? 1 : 0,
                   g_isExclusiveFullscreen.load() ? 1 : 0);
    } else {
        // 防止 UE4 在后台悄悄解绑 HIMC：若发现失效立刻重新关联
        HIMC check = ::ImmGetContext(hWnd);
        if (check) {
            ::ImmReleaseContext(hWnd, check);
        } else {
            ::ImmAssociateContextEx(hWnd, nullptr, IACE_DEFAULT);
        }
        if (modeChanged) {
            g_lastAppliedSelfDrawn = useSelfDrawn;
            ::DefWindowProcW(hWnd, WM_IME_SETCONTEXT, TRUE, useSelfDrawn ? 0 : ISC_SHOWUIALL);
        }
    }

    UpdateImeWindowPosOnWindowThread(hWnd);

    std::lock_guard<std::mutex> lk(g_imeStateMutex);
    g_imeState.active = true;
    g_imeState.useSelfDrawnUi = useSelfDrawn;
    g_imeState.isExclusiveFullscreen = g_isExclusiveFullscreen.load(std::memory_order_relaxed);
    g_imeState.inputPosX = g_imeWantPosX.load(std::memory_order_relaxed);
    g_imeState.inputPosY = g_imeWantPosY.load(std::memory_order_relaxed);
    g_imeState.inputLineHeight = g_imeWantLineH.load(std::memory_order_relaxed);
}

/// 在窗口主线程接管单一系统原生光标与解除鼠标区域锁定（打开 Mod 菜单或 Alt+Tab 切回时调用）。
void AcquireCursorOverrideOnWindowThread(HWND hWnd) {
    if (!hWnd || g_cursorOverrideActive) return;

    // 1. 记录并临时解除 UE4 可能施加的 ClipCursor 窗口锁定（见 Q8）
    RECT curClip{};
    if (::GetClipCursor(&curClip)) {
        const int vLeft = ::GetSystemMetrics(SM_XVIRTUALSCREEN);
        const int vTop = ::GetSystemMetrics(SM_YVIRTUALSCREEN);
        const int vRight = vLeft + ::GetSystemMetrics(SM_CXVIRTUALSCREEN);
        const int vBottom = vTop + ::GetSystemMetrics(SM_CYVIRTUALSCREEN);
        if (curClip.left > vLeft || curClip.top > vTop || curClip.right < vRight || curClip.bottom < vBottom) {
            g_savedClipRect = curClip;
            g_hasSavedClipRect = true;
        } else {
            g_hasSavedClipRect = false;
        }
    }
    ::ClipCursor(nullptr);

    // 2. 平衡 ShowCursor 引用计数（通常 UE4 仅用 SetCursor(NULL)，此处作为计数 <0 时的安全兜底）
    g_showCursorAdded = 0;
    int cnt = ::ShowCursor(TRUE);
    if (cnt > 0) {
        ::ShowCursor(FALSE);
    } else {
        g_showCursorAdded = 1;
        while (cnt < 0 && g_showCursorAdded < 16) {
            cnt = ::ShowCursor(TRUE);
            g_showCursorAdded++;
        }
    }

    g_cursorOverrideActive = true;
    ::SetCursor(::LoadCursorW(nullptr, ImGuiCursorToWin32(g_desiredImGuiCursor.load(std::memory_order_relaxed))));
}

/// 在窗口主线程精确归还系统光标、鼠标锁定范围与输入捕获给 UE4（关闭菜单或 Alt+Tab 切出时调用）。
void ReleaseCursorOverrideOnWindowThread(HWND hWnd, bool notifyOrigCursor) {
    if (!hWnd) return;
    if (::GetCapture() == hWnd) {
        ::ReleaseCapture();
    }

    if (g_cursorOverrideActive) {
        while (g_showCursorAdded > 0) {
            ::ShowCursor(FALSE);
            g_showCursorAdded--;
        }
        if (g_hasSavedClipRect) {
            ::ClipCursor(&g_savedClipRect);
            g_hasSavedClipRect = false;
        }
        g_cursorOverrideActive = false;
    }

    // 立刻派发一次 WM_SETCURSOR 给 UE4 原窗口过程，使游戏即时恢复隐藏光标或原生 UI 光标
    if (notifyOrigCursor && g_origWndProc) {
        ::CallWindowProcW(g_origWndProc, hWnd, WM_SETCURSOR,
                          reinterpret_cast<WPARAM>(hWnd), MAKELPARAM(HTCLIENT, WM_MOUSEMOVE));
    }
}

/// 在菜单从关闭变为打开时触发按需目录软刷新（距上次刷新 >= 5 秒，见 Q9 / ADR-0004）。
void MaybeTriggerMenuSoftRefresh() {
    const unsigned long long now = GetTickCount64();
    const unsigned long long lastCatalog = IpcBridge::Instance().GetLastCatalogUpdateTick();
    const unsigned long long lastTrigger = g_lastSoftRefreshTriggerTick.load(std::memory_order_relaxed);
    if ((now - lastCatalog) >= 5000 && (now - lastTrigger) >= 5000) {
        g_lastSoftRefreshTriggerTick.store(now, std::memory_order_relaxed);
        IpcBridge::Instance().PushAction("refresh_catalog_soft");
    }
}

/// 统一修改菜单开关状态，并异步通知窗口主线程同步光标/IME 与按需目录软刷新。
void ApplyMenuOpenTransition(bool next, const char* source) {
    bool prev = g_menuOpen.exchange(next);
    if (prev == next) return;

    OverlayLog("Menu toggled -> %s (via %s)", next ? "OPEN" : "CLOSED", source);
    if (next) {
        MaybeTriggerMenuSoftRefresh();
    } else {
        g_imeWantVisible.store(false, std::memory_order_relaxed);
        if (g_imguiInitialized) {
            std::lock_guard<std::recursive_mutex> lk(g_imguiInputMutex);
            ImGui::GetIO().ClearInputKeys();
            ImGui::GetIO().ClearInputMouse();
        }
    }

    if (g_gameHwnd) {
        ::PostMessageW(g_gameHwnd, WM_GQOL_SYNC_CURSOR, next ? 1 : 0, 0);
        ::PostMessageW(g_gameHwnd, WM_GQOL_SYNC_IME, 0, 0);
    }
}

/// 带 180ms 防抖的菜单开关切换（防止 WndProc 与 AsyncKey 双通道同帧触发两次导致闪关）。
void ToggleMenuWithDebounce(const char* source) {
    unsigned long long now = GetTickCount64();
    if (now - g_lastToggleTick < 180) return;
    g_lastToggleTick = now;
    ApplyMenuOpenTransition(!g_menuOpen.load(), source);
}

/// 替代 ImGui 默认在渲染线程直接调用 ImmGetContext 的回调：记录光标位置并投递到窗口主线程执行。
void CustomSetImeDataFn(ImGuiContext* /*ctx*/, ImGuiViewport* /*viewport*/, ImGuiPlatformImeData* data) {
    if (!data || g_imeForceTestOverride.load(std::memory_order_relaxed)) return;

    const bool want = data->WantVisible && g_menuOpen.load();
    const float x = data->InputPos.x;
    const float y = data->InputPos.y;
    const float lh = data->InputLineHeight > 1.0f ? data->InputLineHeight : (20.0f * g_uiScale);

    const bool prevWant = g_imeWantVisible.exchange(want, std::memory_order_relaxed);
    const float prevX = g_imeWantPosX.exchange(x, std::memory_order_relaxed);
    const float prevY = g_imeWantPosY.exchange(y, std::memory_order_relaxed);
    g_imeWantLineH.store(lh, std::memory_order_relaxed);

    if (g_gameHwnd && (prevWant != want || (want && (std::abs(prevX - x) > 0.5f || std::abs(prevY - y) > 0.5f)))) {
        ::PostMessageW(g_gameHwnd, WM_GQOL_SYNC_IME, 0, 0);
    }
}

// ==================== DX12 描述符堆与 DX11/DX12 辅助函数 ====================

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

void ReleaseDx11Rtv() {
    if (g_d3d11Rtv) {
        g_d3d11Rtv->Release();
        g_d3d11Rtv = nullptr;
    }
}

void CreateDx11Rtv(IDXGISwapChain* swapChain) {
    ReleaseDx11Rtv();
    ID3D11Texture2D* backBuffer = nullptr;
    if (SUCCEEDED(swapChain->GetBuffer(0, IID_PPV_ARGS(&backBuffer))) && backBuffer) {
        g_d3d11Device->CreateRenderTargetView(backBuffer, nullptr, &g_d3d11Rtv);
        backBuffer->Release();
    }
}

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

void ReleaseDx12BackBuffers() {
    for (auto& f : g_dx12Frames) {
        if (f.backBuffer) {
            f.backBuffer->Release();
            f.backBuffer = nullptr;
        }
    }
}

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

ID3D12CommandQueue* FindDirectQueueForDevice(ID3D12Device* dev) {
    std::lock_guard<std::mutex> lk(g_queueMutex);
    for (const auto& c : g_candidateQueues) {
        if (c.device == dev && c.queue) {
            return c.queue;
        }
    }
    return nullptr;
}

// ==================== WndProc 钩子（窗口主线程） ====================

/// 游戏主窗口消息钩子：严格隔离菜单开关态下的光标、键盘与中文 IME/TSF 消息。
LRESULT CALLBACK HookedWndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (g_shuttingDown.load()) {
        return CallWindowProcW(g_origWndProc, hWnd, msg, wParam, lParam);
    }

    // 1. 处理本插件跨线程投递到窗口主线程的内部同步消息
    if (msg == WM_GQOL_SYNC_IME) {
        SyncImeOnWindowThread(hWnd);
        return 0;
    }
    if (msg == WM_GQOL_SYNC_CURSOR) {
        if (wParam != 0 && g_menuOpen.load()) {
            AcquireCursorOverrideOnWindowThread(hWnd);
        } else {
            ReleaseCursorOverrideOnWindowThread(hWnd, true);
        }
        return 0;
    }
    if (msg == WM_GQOL_SELECT_CANDIDATE) {
        if (g_imeAttachedOnWndThread) {
            int absIdx = 0;
            {
                std::lock_guard<std::mutex> lk(g_imeStateMutex);
                absIdx = g_imeState.pageStart + static_cast<int>(wParam);
            }
            if (HIMC himc = ::ImmGetContext(hWnd)) {
                ::ImmNotifyIME(himc, NI_SELECTCANDIDATESTR, 0, static_cast<DWORD>(absIdx));
                ::ImmReleaseContext(hWnd, himc);
            }
        }
        return 0;
    }

    // 2. 处理全局热键 Insert / F8 与组词保护下的 Esc
    if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) {
        if (wParam == VK_INSERT || wParam == VK_F8) {
            ToggleMenuWithDebounce(wParam == VK_INSERT ? "WndProc:Insert" : "WndProc:F8");
            return 0;
        }
        if (wParam == VK_ESCAPE && g_menuOpen.load()) {
            // 中文拼写组词期间或刚取消组词 120ms 内按 Esc，优先取消组词、不直接关掉 Mod 菜单（见 Q2）
            const bool recentlyEnded = (GetTickCount64() - g_lastImeEndTick.load(std::memory_order_relaxed)) < 120;
            if (g_imeComposing.load(std::memory_order_relaxed) || recentlyEnded) {
                if (g_imeComposing.load(std::memory_order_relaxed)) {
                    if (HIMC himc = ::ImmGetContext(hWnd)) {
                        ::ImmNotifyIME(himc, NI_COMPOSITIONSTR, CPS_CANCEL, 0);
                        ::ImmReleaseContext(hWnd, himc);
                    }
                    g_imeComposing.store(false);
                    g_lastImeEndTick.store(GetTickCount64());
                    std::lock_guard<std::mutex> lk(g_imeStateMutex);
                    g_imeState.composing = false;
                    g_imeState.compositionUtf8.clear();
                    g_imeState.candidates.clear();
                }
                return 0;
            }
            ApplyMenuOpenTransition(false, "WndProc:Esc");
            return 0;
        }
    }

    if (!g_imguiInitialized) {
        return CallWindowProcW(g_origWndProc, hWnd, msg, wParam, lParam);
    }

    // 3. 菜单关闭状态：零干扰直通！绝不调用 ImGui_ImplWin32_WndProcHandler，绝不触碰光标与输入捕获（见 ADR-0004）
    if (!g_menuOpen.load()) {
        if (g_cursorOverrideActive) {
            ReleaseCursorOverrideOnWindowThread(hWnd, false);
        }
        if (g_imeAttachedOnWndThread) {
            DeactivateImeOnWindowThread(hWnd);
        }
        if (HandleMapQuickShortcut(msg, wParam, lParam)) {
            return 0;
        }
        return CallWindowProcW(g_origWndProc, hWnd, msg, wParam, lParam);
    }

    // 4. 菜单打开状态下的窗口焦点切换（Alt+Tab 保持菜单打开但临时让出光标与 IME 控制权，见 Q8）
    if (msg == WM_KILLFOCUS) {
        DeactivateImeOnWindowThread(hWnd);
        ReleaseCursorOverrideOnWindowThread(hWnd, false);
        {
            std::lock_guard<std::recursive_mutex> lk(g_imguiInputMutex);
            ImGui_ImplWin32_WndProcHandler(hWnd, msg, wParam, lParam);
        }
        return CallWindowProcW(g_origWndProc, hWnd, msg, wParam, lParam);
    }
    if (msg == WM_SETFOCUS) {
        LRESULT origRes = CallWindowProcW(g_origWndProc, hWnd, msg, wParam, lParam);
        {
            std::lock_guard<std::recursive_mutex> lk(g_imguiInputMutex);
            ImGui_ImplWin32_WndProcHandler(hWnd, msg, wParam, lParam);
        }
        AcquireCursorOverrideOnWindowThread(hWnd);
        SyncImeOnWindowThread(hWnd);
        return origRes;
    }

    // 5. 菜单打开状态下的 IME / TSF 与输入法切换消息处理（全部交 DefWindowProcW 或自绘消费，绝不落回 UE4 吞掉）
    const bool useSelfDrawn = ComputeUseSelfDrawnIme();
    switch (msg) {
        case WM_INPUTLANGCHANGEREQUEST:
            return DefWindowProcW(hWnd, msg, wParam, lParam);
        case WM_INPUTLANGCHANGE:
            {
                std::lock_guard<std::recursive_mutex> lk(g_imguiInputMutex);
                ImGui_ImplWin32_WndProcHandler(hWnd, msg, wParam, lParam);
            }
            return DefWindowProcW(hWnd, msg, wParam, lParam);
        case WM_IME_SETCONTEXT:
            if (useSelfDrawn) {
                lParam &= ~static_cast<LPARAM>(
                    ISC_SHOWUICOMPOSITIONWINDOW |
                    ISC_SHOWUICANDIDATEWINDOW |
                    (ISC_SHOWUICANDIDATEWINDOW << 1) |
                    (ISC_SHOWUICANDIDATEWINDOW << 2) |
                    (ISC_SHOWUICANDIDATEWINDOW << 3));
            } else {
                lParam |= ISC_SHOWUIALL;
            }
            return DefWindowProcW(hWnd, msg, wParam, lParam);
        case WM_IME_STARTCOMPOSITION:
            g_imeComposing.store(true);
            {
                std::lock_guard<std::mutex> lk(g_imeStateMutex);
                g_imeState.composing = true;
                g_imeState.useSelfDrawnUi = useSelfDrawn;
            }
            UpdateImeWindowPosOnWindowThread(hWnd);
            return useSelfDrawn ? 0 : DefWindowProcW(hWnd, msg, wParam, lParam);
        case WM_IME_COMPOSITION:
            UpdateImeWindowPosOnWindowThread(hWnd);
            ReadImmCompositionOnWindowThread(hWnd, lParam);
            if (useSelfDrawn) {
                if ((lParam & GCS_RESULTSTR) != 0) {
                    if (HIMC himc = ::ImmGetContext(hWnd)) {
                        LONG bytes = ::ImmGetCompositionStringW(himc, GCS_RESULTSTR, nullptr, 0);
                        if (bytes > 0) {
                            std::vector<wchar_t> wbuf(static_cast<size_t>(bytes / sizeof(wchar_t)) + 1, L'\0');
                            LONG got = ::ImmGetCompositionStringW(himc, GCS_RESULTSTR, wbuf.data(), static_cast<DWORD>(bytes));
                            int wlen = static_cast<int>(got / sizeof(wchar_t));
                            std::lock_guard<std::recursive_mutex> lk(g_imguiInputMutex);
                            ImGuiIO& io = ImGui::GetIO();
                            for (int i = 0; i < wlen; ++i) {
                                if (wbuf[i] != 0) {
                                    io.AddInputCharacterUTF16(static_cast<unsigned short>(wbuf[i]));
                                    g_imeCharsCommitted.fetch_add(1, std::memory_order_relaxed);
                                }
                            }
                        }
                        ::ImmReleaseContext(hWnd, himc);
                    }
                    if ((lParam & GCS_COMPSTR) == 0) {
                        std::lock_guard<std::mutex> lk(g_imeStateMutex);
                        g_imeState.compositionUtf8.clear();
                        g_imeState.cursorByteOffset = 0;
                    }
                }
                return 0;
            }
            return DefWindowProcW(hWnd, msg, wParam, lParam);
        case WM_IME_ENDCOMPOSITION:
            g_imeComposing.store(false);
            g_lastImeEndTick.store(GetTickCount64());
            {
                std::lock_guard<std::mutex> lk(g_imeStateMutex);
                g_imeState.composing = false;
                g_imeState.compositionUtf8.clear();
                g_imeState.cursorByteOffset = 0;
                g_imeState.candidates.clear();
                g_imeState.selectedIndex = 0;
                g_imeState.pageStart = 0;
                g_imeState.totalCandidates = 0;
            }
            return useSelfDrawn ? 0 : DefWindowProcW(hWnd, msg, wParam, lParam);
        case WM_IME_NOTIFY:
            if (wParam == IMN_OPENCANDIDATE || wParam == IMN_CHANGECANDIDATE) {
                ReadImmCandidateListOnWindowThread(hWnd);
                if (useSelfDrawn) return 0;
            } else if (wParam == IMN_CLOSECANDIDATE) {
                {
                    std::lock_guard<std::mutex> lk(g_imeStateMutex);
                    g_imeState.candidates.clear();
                    g_imeState.selectedIndex = 0;
                    g_imeState.pageStart = 0;
                    g_imeState.totalCandidates = 0;
                }
                if (useSelfDrawn) return 0;
            }
            return DefWindowProcW(hWnd, msg, wParam, lParam);
        case WM_IME_CHAR:
            // Unicode 窗口下 DefWindowProcW 会把 WM_IME_CHAR 转为 WM_CHAR 送回本 WndProc，绝不能让 UE4 吞掉
            return DefWindowProcW(hWnd, msg, wParam, lParam);
        case WM_IME_REQUEST:
        case WM_IME_SELECT:
        case WM_IME_KEYDOWN:
        case WM_IME_KEYUP:
            return DefWindowProcW(hWnd, msg, wParam, lParam);
        default:
            break;
    }

    // 6. 菜单打开状态下托管单一系统原生光标（仅客户区，不调用 ImGui 自己的 SetCursor）
    if (msg == WM_SETCURSOR) {
        if (LOWORD(lParam) == HTCLIENT) {
            ::SetCursor(::LoadCursorW(nullptr, ImGuiCursorToWin32(g_desiredImGuiCursor.load(std::memory_order_relaxed))));
            return TRUE;
        }
        return DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    // 7. 输入法处理中的虚拟键（VK_PROCESSKEY）交给 DefWindowProcW 保障 IME 正常消费
    if ((msg == WM_KEYDOWN || msg == WM_KEYUP) && wParam == VK_PROCESSKEY) {
        return DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    // 8. 菜单打开期间将键鼠消息线程安全地送入 ImGui，并拦截防止穿透到游戏本体
    //    仅对 ImGui 真正消费的消息调用 ImGui_ImplWin32_WndProcHandler，且使用 recursive_mutex 防止 SetCapture/ReleaseCapture 重入异常
    switch (msg) {
        case WM_MOUSEMOVE:
        case WM_NCMOUSEMOVE:
        case WM_MOUSELEAVE:
        case WM_NCMOUSELEAVE:
        case WM_LBUTTONDOWN:
        case WM_LBUTTONUP:
        case WM_LBUTTONDBLCLK:
        case WM_RBUTTONDOWN:
        case WM_RBUTTONUP:
        case WM_RBUTTONDBLCLK:
        case WM_MBUTTONDOWN:
        case WM_MBUTTONUP:
        case WM_MBUTTONDBLCLK:
        case WM_MOUSEWHEEL:
        case WM_MOUSEHWHEEL:
        case WM_XBUTTONDOWN:
        case WM_XBUTTONUP:
        case WM_XBUTTONDBLCLK:
        case WM_KEYDOWN:
        case WM_KEYUP:
        case WM_SYSKEYDOWN:
        case WM_SYSKEYUP:
        case WM_CHAR:
        case WM_DEVICECHANGE:
            {
                std::lock_guard<std::recursive_mutex> lk(g_imguiInputMutex);
                ImGui_ImplWin32_WndProcHandler(hWnd, msg, wParam, lParam);
            }
            if (msg == WM_CHAR && wParam >= 0x80) {
                g_imeCharsCommitted.fetch_add(1, std::memory_order_relaxed);
            }
            break;
        default:
            break;
    }

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
        case WM_DEADCHAR:
        case WM_SYSCHAR:
        case WM_INPUT:
            return 0;
        default:
            break;
    }

    return CallWindowProcW(g_origWndProc, hWnd, msg, wParam, lParam);
}

// ==================== 初始化逻辑（自动区分 DX12 / DX11） ====================

/// 公共 ImGui 上下文配置（禁用 ImGui 光标篡改与软件光标，挂载窗口线程安全 IME 回调）。
void ConfigureImGuiContextCommon(HWND hwnd, float scale) {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    // 永久禁止 ImGui Win32 后端调用 ::SetCursor，杜绝与 UE4 抢光标导致闪烁（见 ADR-0004）
    io.ConfigFlags |= ImGuiConfigFlags_NoMouseCursorChange;
    io.MouseDrawCursor = false;
    io.IniFilename = nullptr;

    InitOverlayStyleAndFonts(scale);
    ImGui_ImplWin32_Init(hwnd);

    // 覆盖 ImGui 默认渲染线程 IME 回调，改为非阻塞投递到窗口主线程执行（见 ADR-0003）
    ImGui::GetPlatformIO().Platform_SetImeDataFn = CustomSetImeDataFn;
}

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
        g_d3d12Device = d12Dev;
        g_d3d12CommandQueue = queue;
        g_d3d12CommandQueue->AddRef();

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

        ConfigureImGuiContextCommon(g_gameHwnd, g_uiScale);

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
        g_initTick.store(GetTickCount64());
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

        ConfigureImGuiContextCommon(g_gameHwnd, g_uiScale);
        ImGui_ImplDX11_Init(g_d3d11Device, g_d3d11Context);

        g_origWndProc = reinterpret_cast<WNDPROC>(
            SetWindowLongPtrW(g_gameHwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(HookedWndProc)));
        g_activeApi = GraphicsApi::DX11;
        g_imguiInitialized = true;
        g_initTick.store(GetTickCount64());
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

/// 节流检测 SwapChain 是否处于 DXGI 独占全屏（仅菜单打开时每 250ms 查一次，零空闲开销）。
void RefreshFullscreenStateThrottled(IDXGISwapChain* swapChain) {
    unsigned long long now = GetTickCount64();
    if (now - g_lastFullscreenCheckTick < 250) return;
    g_lastFullscreenCheckTick = now;

    BOOL isFs = FALSE;
    if (SUCCEEDED(swapChain->GetFullscreenState(&isFs, nullptr))) {
        const bool nextFs = (isFs != FALSE);
        const bool prevFs = g_isExclusiveFullscreen.exchange(nextFs, std::memory_order_relaxed);
        if (prevFs != nextFs && g_gameHwnd) {
            ::PostMessageW(g_gameHwnd, WM_GQOL_SYNC_IME, 0, 0);
        }
    }
}

/// 绘制启动后前 10 秒的左上角状态提示条，直观反馈插件已成功挂载。
void DrawStartupBanner(unsigned long long elapsedMs, bool menuOpen) {
    if (elapsedMs > 10000 || menuOpen) return;

    float alpha = 1.0f;
    if (elapsedMs > 8000) {
        alpha = std::clamp(1.0f - static_cast<float>(elapsedMs - 8000) / 2000.0f, 0.0f, 1.0f);
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

/// 在单次 Present 周期内执行空闲零开销直通判定，仅在确有绘制内容时提交 DX12/DX11 ImGui 帧。
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

    bool menuOpen = g_menuOpen.load(std::memory_order_relaxed);
    const bool mapOpen = IpcBridge::Instance().IsMapOpenFast();
    const unsigned long long now = GetTickCount64();
    const unsigned long long initTick = g_initTick.load(std::memory_order_relaxed);
    const unsigned long long elapsed = (now >= initTick) ? (now - initTick) : 0;
    const bool bannerVisible = (!menuOpen && elapsed <= 10000);

    // 捕获菜单从打开 -> 关闭的边缘，确保释放光标/IME 并清空残余标点状态
    if (g_prevRenderedMenuOpen && !menuOpen) {
        g_prevRenderedMenuOpen = false;
        if (g_gameHwnd) {
            ::PostMessageW(g_gameHwnd, WM_GQOL_SYNC_CURSOR, 0, 0);
            ::PostMessageW(g_gameHwnd, WM_GQOL_SYNC_IME, 0, 0);
        }
    }

    // 空闲零开销直通路径（见 ADR-0004）：
    // 菜单关闭 + M 地图关闭 + 开场横幅消失 -> 完全跳过 DX12 Fence/Barrier/ExecuteCommandLists 与 ImGui 帧构建
    if (!menuOpen && !mapOpen && !bannerVisible) {
        ResetOverlayIdleState();
        g_lastFrameIdle.store(true, std::memory_order_relaxed);
        g_idleFrameCount.fetch_add(1, std::memory_order_relaxed);
        return;
    }

    g_lastFrameIdle.store(false, std::memory_order_relaxed);
    g_renderedFrameCount.fetch_add(1, std::memory_order_relaxed);
    g_prevRenderedMenuOpen = menuOpen;

    if (menuOpen) {
        RefreshFullscreenStateThrottled(swapChain);
    }

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
        if (frame.fenceValue != 0 && g_d3d12Fence->GetCompletedValue() < frame.fenceValue) {
            g_d3d12Fence->SetEventOnCompletion(frame.fenceValue, g_d3d12FenceEvent);
            WaitForSingleObject(g_d3d12FenceEvent, 500);
        }

        ImGui_ImplDX12_NewFrame();
        {
            std::lock_guard<std::recursive_mutex> lk(g_imguiInputMutex);
            ImGui_ImplWin32_NewFrame();
            ImGui::NewFrame();
        }

        DrawStartupBanner(elapsed, menuOpen);
        RenderOverlayFrame(menuOpen, g_uiScale);
        if (menuOpen != g_menuOpen.load(std::memory_order_relaxed)) {
            ApplyMenuOpenTransition(menuOpen, "UI:CloseButton");
        }
        g_desiredImGuiCursor.store(static_cast<int>(ImGui::GetMouseCursor()), std::memory_order_relaxed);

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
        {
            std::lock_guard<std::recursive_mutex> lk(g_imguiInputMutex);
            ImGui_ImplWin32_NewFrame();
            ImGui::NewFrame();
        }

        DrawStartupBanner(elapsed, menuOpen);
        RenderOverlayFrame(menuOpen, g_uiScale);
        if (menuOpen != g_menuOpen.load(std::memory_order_relaxed)) {
            ApplyMenuOpenTransition(menuOpen, "UI:CloseButton");
        }
        g_desiredImGuiCursor.store(static_cast<int>(ImGui::GetMouseCursor()), std::memory_order_relaxed);

        ImGui::Render();
        if (g_d3d11Rtv) {
            g_d3d11Context->OMSetRenderTargets(1, &g_d3d11Rtv, nullptr);
            ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
        }
    }
}

// ==================== 图形钩子回调 ====================

void STDMETHODCALLTYPE HookedExecuteCommandLists(
    ID3D12CommandQueue* queue, UINT numCommandLists, ID3D12CommandList* const* ppCommandLists) {
    if (!g_shuttingDown.load(std::memory_order_relaxed) && !g_dx12QueueLocked.load(std::memory_order_relaxed) && queue) {
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

HRESULT STDMETHODCALLTYPE HookedPresent(IDXGISwapChain* swapChain, UINT syncInterval, UINT flags) {
    if (!g_shuttingDown.load(std::memory_order_relaxed) && !t_inPresent && swapChain) {
        t_inPresent = true;
        RenderFrameOnSwapChain(swapChain);
        t_inPresent = false;
    }
    return g_origPresent(swapChain, syncInterval, flags);
}

HRESULT STDMETHODCALLTYPE HookedPresent1(
    IDXGISwapChain1* swapChain, UINT syncInterval, UINT presentFlags, const DXGI_PRESENT_PARAMETERS* pPresentParameters) {
    if (!g_shuttingDown.load(std::memory_order_relaxed) && !t_inPresent && swapChain) {
        t_inPresent = true;
        RenderFrameOnSwapChain(swapChain);
        t_inPresent = false;
    }
    return g_origPresent1(swapChain, syncInterval, presentFlags, pPresentParameters);
}

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
        g_lastFullscreenCheckTick = 0; // 分辨率/全屏切换后立刻重新探测独占全屏态
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

bool InstallGraphicsHook() {
    OverlayLog("InstallGraphicsHook() starting...");

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

void UninstallGraphicsHook(bool processTerminating) {
    g_shuttingDown.store(true);
    if (processTerminating) {
        // 进程终止阶段仅快速解除 WndProc 子类化，避免在 Loader Lock 内等待 GPU 围栏或调用 COM 造成退出卡死
        if (g_gameHwnd && g_origWndProc) {
            SetWindowLongPtrW(g_gameHwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(g_origWndProc));
            g_origWndProc = nullptr;
        }
        return;
    }

    if (g_gameHwnd && g_origWndProc) {
        SetWindowLongPtrW(g_gameHwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(g_origWndProc));
        g_origWndProc = nullptr;
    }
    ReleaseTsfSinkOnWindowThread();

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
    return g_menuOpen.load(std::memory_order_relaxed);
}

void SetMenuOpen(bool open) {
    ApplyMenuOpenTransition(open, "API:SetMenuOpen");
}

const char* GetActiveGraphicsBackend() {
    if (g_activeApi == GraphicsApi::DX12) return "DX12";
    if (g_activeApi == GraphicsApi::DX11) return "DX11";
    return "Unknown";
}

HWND GetGameHwnd() {
    return g_gameHwnd;
}

ImeCandidateState GetImeCandidateState() {
    std::lock_guard<std::mutex> lk(g_imeStateMutex);
    ImeCandidateState snap = g_imeState;
    snap.useSelfDrawnUi = ComputeUseSelfDrawnIme();
    snap.isExclusiveFullscreen = g_isExclusiveFullscreen.load(std::memory_order_relaxed);
    return snap;
}

void SelectImeCandidateByPageIndex(int pageIdx) {
    if (g_gameHwnd && pageIdx >= 0) {
        ::PostMessageW(g_gameHwnd, WM_GQOL_SELECT_CANDIDATE, static_cast<WPARAM>(pageIdx), 0);
    }
}

bool WasLastFrameIdlePassThrough() {
    return g_lastFrameIdle.load(std::memory_order_relaxed);
}

void GetTestMetrics(unsigned long long* outIdleFrames,
                    unsigned long long* outRenderedFrames,
                    int* outImeCharCount) {
    if (outIdleFrames) *outIdleFrames = g_idleFrameCount.load(std::memory_order_relaxed);
    if (outRenderedFrames) *outRenderedFrames = g_renderedFrameCount.load(std::memory_order_relaxed);
    if (outImeCharCount) *outImeCharCount = g_imeCharsCommitted.load(std::memory_order_relaxed);
}

void ForceExpireStartupBannerForTest() {
    unsigned long long now = GetTickCount64();
    g_initTick.store((now > 20000) ? (now - 20000) : 0);
}

void ForceWantTextInputForTest(bool want, float x, float y) {
    g_imeForceTestOverride.store(want, std::memory_order_relaxed);
    g_imeWantVisible.store(want, std::memory_order_relaxed);
    g_imeWantPosX.store(x, std::memory_order_relaxed);
    g_imeWantPosY.store(y, std::memory_order_relaxed);
    g_imeWantLineH.store(22.0f, std::memory_order_relaxed);
    if (g_gameHwnd) {
        ::PostMessageW(g_gameHwnd, WM_GQOL_SYNC_IME, 0, 0);
    }
}

} // namespace gqol
