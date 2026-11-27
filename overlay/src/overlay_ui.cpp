/*
 * 文件：overlay/src/overlay_ui.cpp
 * 职责：实现 GroundedQoL 游戏内中文悬浮菜单（倍率/免材/死亡保护与背包找回/M 地图追踪/输入法模式与联机说明）、
 *       独占全屏/手动降级下的 ImGui 内置自绘中文输入法候选条，以及 “M” 大地图零延迟实时标点投影层。
 * 关键技术说明：
 *   - 渲染帧通过 IpcBridge::Get*Snapshot() 零拷贝读取不可变快照，配合无分配子串匹配与 ImGuiListClipper，
 *     显著降低大列表与数百地图标点渲染时的 CPU 开销（见 ADR-0004）。
 *   - 菜单关闭时 M 地图悬停改为被动只读 GetCursorPos + ScreenToClient，完全不依赖 ImGui WndProc 输入接管。
 *   - 当命中自绘候选条模式（独占全屏自动降级或手动指定）且输入法处于组词中时，在聚焦输入框正下方悬浮绘制
 *     拼音组词与横向编号候选字，边缘自动上翻，支持键盘原版选词与可用时的鼠标点击上屏（见 ADR-0003）。
 */

#include "overlay_ui.h"
#include "dx11_hook.h"
#include "ipc.h"

#include <imgui.h>
#include <algorithm>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <string>
#include <string_view>
#include <unordered_set>
#include <vector>

namespace gqol {

namespace {

std::atomic<int> g_lastRenderedPinCount{0};
bool g_prevMapOpenLogged = false;
bool g_loggedNativeTransformForCurrentOpen = false;

// UE 4.27 FGeometry 精确二进制布局（0x38 字节，已通过 Maine-Win64-Shipping.exe 反汇编实机验证）
struct UeFGeometry {
    float sizeX;
    float sizeY;
    float scale;
    float absPosX;
    float absPosY;
    float localPosX;
    float localPosY;
    float m00;
    float m01;
    float m10;
    float m11;
    float transX;
    float transY;
    uint8_t bHasRenderTransform;
    uint8_t pad[3];
};
static_assert(sizeof(UeFGeometry) == 0x38, "UeFGeometry must match UE 4.27 0x38 byte size");

inline bool IsLikelyUserPtr(uintptr_t p) {
    return p >= 0x0000000000010000ULL && p < 0x00007FFFFFFFFFFFULL && ((p & 0x7ULL) == 0);
}

/// 纯 SEH 保护函数：从 UWidget* 内存安全读取对应 SWidget 的 56 字节 FGeometry。
bool CopyUWidgetGeometryRawSEH(uintptr_t uwidgetAddr, UeFGeometry* outGeom) {
    if (!IsLikelyUserPtr(uwidgetAddr) || !outGeom) return false;
    __try {
        const auto* base = reinterpret_cast<const uint8_t*>(uwidgetAddr);
        uintptr_t sw = 0;

        // 路径 1：UWidget::MyWidget (+0xF0 Object, +0xF8 SharedReferenceCount)
        uintptr_t obj1 = *reinterpret_cast<const uintptr_t*>(base + 0xF0);
        uintptr_t ref1 = *reinterpret_cast<const uintptr_t*>(base + 0xF8);
        if (IsLikelyUserPtr(obj1) && IsLikelyUserPtr(ref1)) {
            int32_t strongCount = *reinterpret_cast<const int32_t*>(ref1 + 0x08);
            if (strongCount > 0 && strongCount < 1000000) {
                sw = obj1;
            }
        }

        // 路径 2：UUserWidget::MyGCWidget (+0xE0 Object, +0xE8 SharedReferenceCount)
        if (!sw) {
            uintptr_t obj2 = *reinterpret_cast<const uintptr_t*>(base + 0xE0);
            uintptr_t ref2 = *reinterpret_cast<const uintptr_t*>(base + 0xE8);
            if (IsLikelyUserPtr(obj2) && IsLikelyUserPtr(ref2)) {
                int32_t strongCount = *reinterpret_cast<const int32_t*>(ref2 + 0x08);
                if (strongCount > 0 && strongCount < 1000000) {
                    sw = obj2;
                }
            }
        }

        if (!sw) return false;
        const auto* geomPtr = reinterpret_cast<const UeFGeometry*>(reinterpret_cast<const uint8_t*>(sw) + 0xD0);
        *outGeom = *geomPtr;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool TryReadUWidgetGeometry(uint64_t uwidgetAddr, UeFGeometry& outGeom) {
    if (uwidgetAddr == 0) return false;
    UeFGeometry g{};
    if (!CopyUWidgetGeometryRawSEH(static_cast<uintptr_t>(uwidgetAddr), &g)) {
        return false;
    }
    if (!std::isfinite(g.sizeX) || !std::isfinite(g.sizeY) ||
        !std::isfinite(g.m00) || !std::isfinite(g.m01) ||
        !std::isfinite(g.m10) || !std::isfinite(g.m11) ||
        !std::isfinite(g.transX) || !std::isfinite(g.transY)) {
        return false;
    }
    if (g.sizeX < -1.0f || g.sizeX > 65536.0f || g.sizeY < -1.0f || g.sizeY > 65536.0f) {
        return false;
    }
    const float det = g.m00 * g.m11 - g.m01 * g.m10;
    if (!std::isfinite(det) || std::fabs(det) < 1e-6f || std::fabs(det) > 1e6f) {
        return false;
    }
    outGeom = g;
    return true;
}

bool TryReadMapPanelBoundsSEH(uint64_t panelAddr,
                              float* outMinX, float* outMinY,
                              float* outMaxX, float* outMaxY,
                              float* outTexW, float* outTexH) {
    uintptr_t p = static_cast<uintptr_t>(panelAddr);
    if (!IsLikelyUserPtr(p)) return false;
    __try {
        const auto* base = reinterpret_cast<const uint8_t*>(p);
        *outMaxX = *reinterpret_cast<const float*>(base + 0x3A0);
        *outMaxY = *reinterpret_cast<const float*>(base + 0x3A4);
        *outMinX = *reinterpret_cast<const float*>(base + 0x3A8);
        *outMinY = *reinterpret_cast<const float*>(base + 0x3AC);
        *outTexW = *reinterpret_cast<const float*>(base + 0x3B0);
        *outTexH = *reinterpret_cast<const float*>(base + 0x3B4);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

inline ImVec2 SlateLocalToAbsolute(const UeFGeometry& g, float lx, float ly) {
    return ImVec2(lx * g.m00 + ly * g.m10 + g.transX,
                  lx * g.m01 + ly * g.m11 + g.transY);
}

struct ResolvedMapProjection {
    bool valid = false;
    bool usingNativeSlate = false;
    ImVec2 clipMin{0.0f, 0.0f};
    ImVec2 clipMax{0.0f, 0.0f};

    float ax = 0.0f, bx = 0.0f, cx = 0.0f;
    float ay = 0.0f, by = 0.0f, cy = 0.0f;

    UeFGeometry cGeom{};
    ImVec2 vpAbsMin{0.0f, 0.0f};
    ImVec2 vpAbsSize{1.0f, 1.0f};
    bool usedWinGeom = false;

    ImVec2 Project(float wx, float wy) const {
        return ImVec2(ax * wx + bx * wy + cx, ay * wx + by * wy + cy);
    }

    ImVec2 AbsToDisplay(const ImVec2& absPt, const ImVec2& disp) const {
        return ImVec2(((absPt.x - vpAbsMin.x) / vpAbsSize.x) * disp.x,
                      ((absPt.y - vpAbsMin.y) / vpAbsSize.y) * disp.y);
    }
};

ResolvedMapProjection BuildMapProjection(const MapLiveState& m, const ImVec2& disp) {
    ResolvedMapProjection proj;
    proj.clipMin = ImVec2(0.0f, 0.0f);
    proj.clipMax = disp;

    // 路径 A：直接从 Grounded 进程内存读取 CollectibleCanvas / MapBorder / RootWindow 的实时 FGeometry
    if (m.canvasAddr != 0 || m.fallbackCanvasAddr != 0) {
        UeFGeometry cGeom{};
        bool gotCanvas = TryReadUWidgetGeometry(m.canvasAddr, cGeom);
        if (!gotCanvas && m.fallbackCanvasAddr != 0) {
            gotCanvas = TryReadUWidgetGeometry(m.fallbackCanvasAddr, cGeom);
        }

        if (gotCanvas) {
            float minX = m.minBoundsX, minY = m.minBoundsY;
            float maxX = m.maxBoundsX, maxY = m.maxBoundsY;
            float texW = m.texSizeX, texH = m.texSizeY;

            if (std::fabs(maxX - minX) < 1.0f || std::fabs(maxY - minY) < 1.0f || texW < 1.0f || texH < 1.0f) {
                float rMinX = 0, rMinY = 0, rMaxX = 0, rMaxY = 0, rTexW = 0, rTexH = 0;
                if (TryReadMapPanelBoundsSEH(m.panelAddr, &rMinX, &rMinY, &rMaxX, &rMaxY, &rTexW, &rTexH) &&
                    std::isfinite(rMinX) && std::isfinite(rMaxX) && std::isfinite(rTexW)) {
                    minX = rMinX; minY = rMinY;
                    maxX = rMaxX; maxY = rMaxY;
                    texW = rTexW; texH = rTexH;
                }
            }

            const float spanX = maxX - minX;
            const float spanY = maxY - minY;
            if (std::fabs(spanX) > 1.0f && std::fabs(spanY) > 1.0f && texW > 1.0f && texH > 1.0f) {
                bool gotVp = false;
                UeFGeometry winGeom{};
                if (TryReadUWidgetGeometry(m.rootWinAddr, winGeom) && winGeom.sizeX > 50.0f && winGeom.sizeY > 50.0f) {
                    ImVec2 a0 = SlateLocalToAbsolute(winGeom, 0.0f, 0.0f);
                    ImVec2 a1 = SlateLocalToAbsolute(winGeom, winGeom.sizeX, winGeom.sizeY);
                    if ((a1.x - a0.x) > 200.0f && (a1.y - a0.y) > 200.0f) {
                        proj.vpAbsMin = a0;
                        proj.vpAbsSize = ImVec2(a1.x - a0.x, a1.y - a0.y);
                        proj.usedWinGeom = true;
                        gotVp = true;
                    }
                }
                if (!gotVp) {
                    HWND hwnd = GetGameHwnd();
                    RECT rc{};
                    POINT origin{0, 0};
                    if (hwnd && GetClientRect(hwnd, &rc) && ClientToScreen(hwnd, &origin) &&
                        (rc.right - rc.left) > 100 && (rc.bottom - rc.top) > 100) {
                        proj.vpAbsMin = ImVec2(static_cast<float>(origin.x), static_cast<float>(origin.y));
                        proj.vpAbsSize = ImVec2(static_cast<float>(rc.right - rc.left),
                                                static_cast<float>(rc.bottom - rc.top));
                        gotVp = true;
                    } else if (disp.x > 100.0f && disp.y > 100.0f) {
                        proj.vpAbsMin = ImVec2(0.0f, 0.0f);
                        proj.vpAbsSize = disp;
                        gotVp = true;
                    }
                }

                if (gotVp) {
                    const float kx = texW / spanX;
                    const float ky = texH / spanY;
                    const float l0x = cGeom.sizeX * 0.5f - (minX / spanX + 0.5f) * texW;
                    const float l0y = cGeom.sizeY * 0.5f - (minY / spanY + 0.5f) * texH;

                    const float sxScale = disp.x / proj.vpAbsSize.x;
                    const float syScale = disp.y / proj.vpAbsSize.y;

                    const float abs0x = l0x * cGeom.m00 + l0y * cGeom.m10 + cGeom.transX;
                    const float abs0y = l0x * cGeom.m01 + l0y * cGeom.m11 + cGeom.transY;

                    proj.ax = (kx * cGeom.m00) * sxScale;
                    proj.bx = (ky * cGeom.m10) * sxScale;
                    proj.cx = (abs0x - proj.vpAbsMin.x) * sxScale;

                    proj.ay = (kx * cGeom.m01) * syScale;
                    proj.by = (ky * cGeom.m11) * syScale;
                    proj.cy = (abs0y - proj.vpAbsMin.y) * syScale;

                    UeFGeometry bGeom{};
                    if (TryReadUWidgetGeometry(m.borderAddr, bGeom) && bGeom.sizeX > 50.0f && bGeom.sizeY > 50.0f) {
                        ImVec2 corners[4] = {
                            proj.AbsToDisplay(SlateLocalToAbsolute(bGeom, 0.0f, 0.0f), disp),
                            proj.AbsToDisplay(SlateLocalToAbsolute(bGeom, bGeom.sizeX, 0.0f), disp),
                            proj.AbsToDisplay(SlateLocalToAbsolute(bGeom, 0.0f, bGeom.sizeY), disp),
                            proj.AbsToDisplay(SlateLocalToAbsolute(bGeom, bGeom.sizeX, bGeom.sizeY), disp),
                        };
                        float x0 = corners[0].x, x1 = corners[0].x;
                        float y0 = corners[0].y, y1 = corners[0].y;
                        for (int i = 1; i < 4; ++i) {
                            x0 = std::min(x0, corners[i].x);
                            x1 = std::max(x1, corners[i].x);
                            y0 = std::min(y0, corners[i].y);
                            y1 = std::max(y1, corners[i].y);
                        }
                        x0 = std::clamp(x0, 0.0f, disp.x);
                        x1 = std::clamp(x1, 0.0f, disp.x);
                        y0 = std::clamp(y0, 0.0f, disp.y);
                        y1 = std::clamp(y1, 0.0f, disp.y);
                        if ((x1 - x0) > 100.0f && (y1 - y0) > 100.0f) {
                            proj.clipMin = ImVec2(x0, y0);
                            proj.clipMax = ImVec2(x1, y1);
                        }
                    }

                    proj.cGeom = cGeom;
                    proj.valid = true;
                    proj.usingNativeSlate = true;
                    return proj;
                }
            }
        }
    }

    // 路径 B：兜底/回归测试模式（使用 JSON 上报的 3 点仿射投影参数）
    if (m.hasTransform) {
        const float scaleX = (m.vpW > 1.0f) ? (disp.x / m.vpW) : 1.0f;
        const float scaleY = (m.vpH > 1.0f) ? (disp.y / m.vpH) : 1.0f;
        proj.ax = ((m.pxx - m.p0x) / 10000.0f) * scaleX;
        proj.bx = ((m.pyx - m.p0x) / 10000.0f) * scaleX;
        proj.cx = m.p0x * scaleX;
        proj.ay = ((m.pxy - m.p0y) / 10000.0f) * scaleY;
        proj.by = ((m.pyy - m.p0y) / 10000.0f) * scaleY;
        proj.cy = m.p0y * scaleY;

        ImVec2 cMin(m.clipX0 * scaleX, m.clipY0 * scaleY);
        ImVec2 cMax(m.clipX1 * scaleX, m.clipY1 * scaleY);
        if ((cMax.x - cMin.x) > 50.0f && (cMax.y - cMin.y) > 50.0f) {
            proj.clipMin = cMin;
            proj.clipMax = cMax;
        }
        proj.valid = true;
        proj.usingNativeSlate = false;
    }

    return proj;
}

constexpr ImU32 kTrackPalette[12] = {
    IM_COL32(255, 82, 82, 255),
    IM_COL32(76, 235, 120, 255),
    IM_COL32(255, 165, 38, 255),
    IM_COL32(64, 224, 255, 255),
    IM_COL32(255, 105, 210, 255),
    IM_COL32(210, 255, 70, 255),
    IM_COL32(180, 130, 255, 255),
    IM_COL32(255, 235, 120, 255),
    IM_COL32(0, 255, 195, 255),
    IM_COL32(255, 125, 125, 255),
    IM_COL32(120, 185, 255, 255),
    IM_COL32(255, 255, 255, 255),
};

struct HoveredPinState {
    bool valid = false;
    float wx = 0.0f;
    float wy = 0.0f;
    float wz = 0.0f;
    std::string name;
};

std::mutex g_hoverMutex;
HoveredPinState g_hoveredPin;

/// 仅转换单个 ASCII 大写字母为小写，不破坏 UTF-8 多字节中文。
inline char LowerAsciiChar(char c) {
    return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;
}

std::string ToLowerAscii(std::string_view s) {
    std::string out(s);
    for (char& c : out) c = LowerAsciiChar(c);
    return out;
}

/// 零堆分配的 ASCII 大小写不敏感子串匹配（needle 需提前转为 ASCII 小写，UTF-8 中文按字节精确匹配）。
bool ContainsLowerNeedleNoAlloc(std::string_view haystack, std::string_view lowerNeedle) {
    if (lowerNeedle.empty()) return true;
    if (haystack.size() < lowerNeedle.size()) return false;
    const size_t limit = haystack.size() - lowerNeedle.size();
    const char first = lowerNeedle[0];
    for (size_t i = 0; i <= limit; ++i) {
        if (LowerAsciiChar(haystack[i]) != first) continue;
        size_t j = 1;
        for (; j < lowerNeedle.size(); ++j) {
            if (LowerAsciiChar(haystack[i + j]) != lowerNeedle[j]) break;
        }
        if (j == lowerNeedle.size()) return true;
    }
    return false;
}

/// 被动只读当前鼠标在游戏客户区内的坐标（菜单关闭时 M 地图悬停专用，不触碰任何光标状态）。
bool TryGetPassiveMousePos(const ImVec2& disp, ImVec2& outPos) {
    HWND hwnd = GetGameHwnd();
    if (!hwnd) return false;
    POINT pt{};
    RECT rc{};
    if (!::GetCursorPos(&pt) || !::ScreenToClient(hwnd, &pt) || !::GetClientRect(hwnd, &rc)) {
        return false;
    }
    const float cw = static_cast<float>(rc.right - rc.left);
    const float ch = static_cast<float>(rc.bottom - rc.top);
    if (cw > 1.0f && ch > 1.0f) {
        outPos.x = (static_cast<float>(pt.x) / cw) * disp.x;
        outPos.y = (static_cast<float>(pt.y) / ch) * disp.y;
        return true;
    }
    return false;
}

const char* CategoryLabelZh(const std::string& cat) {
    if (cat == "item") return "散落物品";
    if (cat == "node") return "采集点/矿石";
    if (cat == "creature") return "生物/昆虫";
    if (cat == "survey") return "全图资源(扫描仪)";
    if (cat == "special") return "特殊地点/宝箱";
    if (cat == "collectible") return "乳牙/收集品";
    return "其他";
}

void DrawDiamond(ImDrawList* dl, const ImVec2& c, float r, ImU32 fill, ImU32 border, float borderThick) {
    ImVec2 pts[4] = {
        ImVec2(c.x, c.y - r),
        ImVec2(c.x + r, c.y),
        ImVec2(c.x, c.y + r),
        ImVec2(c.x - r, c.y),
    };
    dl->AddConvexPolyFilled(pts, 4, fill);
    dl->AddPolyline(pts, 4, border, ImDrawFlags_Closed, borderThick);
}

/// 渲染 M 地图上的乳牙与自由追踪资源标点层。
void RenderMapOverlay(const ModConfig& cfg, const MapLiveState& mapLive, bool menuOpen, float uiScale) {
    if (!mapLive.mapOpen) {
        g_prevMapOpenLogged = false;
        g_loggedNativeTransformForCurrentOpen = false;
        g_lastRenderedPinCount.store(0);
        std::lock_guard<std::mutex> lk(g_hoverMutex);
        g_hoveredPin.valid = false;
        return;
    }

    ImGuiIO& io = ImGui::GetIO();
    const ImVec2 disp = io.DisplaySize;
    const ResolvedMapProjection proj = BuildMapProjection(mapLive, disp);

    if (!proj.valid) {
        if (!g_prevMapOpenLogged) {
            g_prevMapOpenLogged = true;
            OverlayLog("M-Map opened but projection unresolved! canvas=0x%llX fallback=0x%llX panel=0x%llX pins=%zu",
                       static_cast<unsigned long long>(mapLive.canvasAddr),
                       static_cast<unsigned long long>(mapLive.fallbackCanvasAddr),
                       static_cast<unsigned long long>(mapLive.panelAddr),
                       mapLive.pins.size());
        }
        g_lastRenderedPinCount.store(0);
        std::lock_guard<std::mutex> lk(g_hoverMutex);
        g_hoveredPin.valid = false;
        return;
    }

    if (!g_loggedNativeTransformForCurrentOpen) {
        g_loggedNativeTransformForCurrentOpen = true;
        g_prevMapOpenLogged = true;
        ImVec2 samplePin = mapLive.pins.empty() ? ImVec2(0, 0) : proj.Project(mapLive.pins[0].wx, mapLive.pins[0].wy);
        float playerErrPx = -1.0f;
        ImVec2 projPl{}, nativePl{};
        if (proj.usingNativeSlate && mapLive.hasPlayerPos && mapLive.playerIconAddr != 0) {
            UeFGeometry pGeom{};
            if (TryReadUWidgetGeometry(mapLive.playerIconAddr, pGeom)) {
                projPl = proj.Project(mapLive.playerX, mapLive.playerY);
                nativePl = proj.AbsToDisplay(
                    SlateLocalToAbsolute(pGeom, pGeom.sizeX * 0.5f, pGeom.sizeY * 0.5f), disp);
                float dx = projPl.x - nativePl.x;
                float dy = projPl.y - nativePl.y;
                playerErrPx = std::sqrt(dx * dx + dy * dy);
            }
        }
        OverlayLog("M-Map projection ACTIVE (%s)! disp=%.0fx%.0f clip=(%.0f,%.0f..%.0f,%.0f) cSize=%.0fx%.0f M=(%.3f,%.3f,%.3f,%.3f) T=(%.1f,%.1f) vpAbs=(%.0f,%.0f %.0fx%.0f win=%d) pins=%zu samplePin=(%.1f,%.1f) playerErr=%.2fpx (proj=%.1f,%.1f native=%.1f,%.1f)",
                   proj.usingNativeSlate ? "NativeSlateFGeometry" : "AffineFallback",
                   disp.x, disp.y,
                   proj.clipMin.x, proj.clipMin.y, proj.clipMax.x, proj.clipMax.y,
                   proj.cGeom.sizeX, proj.cGeom.sizeY,
                   proj.cGeom.m00, proj.cGeom.m01, proj.cGeom.m10, proj.cGeom.m11,
                   proj.cGeom.transX, proj.cGeom.transY,
                   proj.vpAbsMin.x, proj.vpAbsMin.y, proj.vpAbsSize.x, proj.vpAbsSize.y,
                   proj.usedWinGeom ? 1 : 0,
                   mapLive.pins.size(), samplePin.x, samplePin.y,
                   playerErrPx, projPl.x, projPl.y, nativePl.x, nativePl.y);
    }

    const ImVec2 clipMin = proj.clipMin;
    const ImVec2 clipMax = proj.clipMax;

    ImDrawList* dl = ImGui::GetForegroundDrawList();
    dl->PushClipRect(clipMin, clipMax, true);

    const float baseR = 6.5f * uiScale * std::clamp(cfg.mapIconScale, 0.5f, 2.0f);
    const float borderT = std::max(1.6f, 1.5f * uiScale);

    // 菜单关闭时通过只读 GetCursorPos 获取鼠标位置，彻底与 ImGui WndProc 解耦（见 ADR-0004）
    ImVec2 mouse = io.MousePos;
    if (!menuOpen) {
        ImVec2 passivePos{};
        if (TryGetPassiveMousePos(disp, passivePos)) {
            mouse = passivePos;
        }
    }
    const bool mouseInMap = (!menuOpen) &&
        mouse.x >= clipMin.x && mouse.x <= clipMax.x &&
        mouse.y >= clipMin.y && mouse.y <= clipMax.y;

    float bestDistSq = (baseR + 11.0f * uiScale) * (baseR + 11.0f * uiScale);
    const MapPin* hovered = nullptr;
    ImVec2 hoveredScreen{};
    int drawnCount = 0;

    // 复用静态图例缓冲区，避免每帧构造 unordered_map 与频繁 string 堆分配
    struct LegendStat {
        std::string_view key;
        const char* label;
        ImU32 color;
        bool isDiamond;
        int count;
    };
    static std::vector<LegendStat> s_legendOrder;
    s_legendOrder.clear();

    auto addLegend = [&](std::string_view key, const char* label, ImU32 color, bool isDiamond) {
        for (auto& lg : s_legendOrder) {
            if (lg.key == key) {
                lg.count++;
                return;
            }
        }
        s_legendOrder.push_back({key, label, color, isDiamond, 1});
    };

    for (const auto& pin : mapLive.pins) {
        ImVec2 sp = proj.Project(pin.wx, pin.wy);

        ImU32 fillCol = IM_COL32(255, 255, 255, 255);
        ImU32 borderCol = IM_COL32(15, 20, 28, 235);
        bool diamond = false;
        float r = baseR;

        if (pin.colorIndex == -1) {
            fillCol = IM_COL32(56, 220, 255, 250);
            borderCol = IM_COL32(255, 255, 255, 255);
            r = baseR * 1.15f;
            addLegend("__molar", "普通乳牙", fillCol, false);
        } else if (pin.colorIndex == -2) {
            fillCol = IM_COL32(255, 212, 38, 255);
            borderCol = IM_COL32(255, 255, 255, 255);
            diamond = true;
            r = baseR * 1.48f;
            addLegend("__megamolar", "高级乳牙", fillCol, true);
        } else if (pin.colorIndex == -3) {
            fillCol = IM_COL32(204, 110, 255, 245);
            borderCol = IM_COL32(255, 255, 255, 245);
            diamond = true;
            r = baseR * 1.12f;
            addLegend("__scab", "SCA.B 配色", fillCol, true);
        } else if (pin.colorIndex == -4) {
            fillCol = IM_COL32(150, 155, 165, 130);
            borderCol = IM_COL32(40, 45, 50, 160);
            r = baseR * 0.85f;
            addLegend("__collected", "已采集乳牙", fillCol, false);
        } else {
            fillCol = kTrackPalette[pin.colorIndex % 12];
            borderCol = IM_COL32(10, 12, 16, 245);
            addLegend(pin.id, pin.name.c_str(), fillCol, false);
        }

        if (sp.x < clipMin.x - 40.0f || sp.x > clipMax.x + 40.0f ||
            sp.y < clipMin.y - 40.0f || sp.y > clipMax.y + 40.0f) {
            continue;
        }
        drawnCount++;

        if (diamond) {
            DrawDiamond(dl, ImVec2(sp.x, sp.y + 1.2f * uiScale), r + 1.4f * uiScale, IM_COL32(0, 0, 0, 170), IM_COL32(0, 0, 0, 0), 0.0f);
            DrawDiamond(dl, sp, r, fillCol, borderCol, borderT);
        } else {
            dl->AddCircleFilled(ImVec2(sp.x, sp.y + 1.2f * uiScale), r + 1.4f * uiScale, IM_COL32(0, 0, 0, 170));
            dl->AddCircleFilled(sp, r, fillCol);
            dl->AddCircle(sp, r, borderCol, 0, borderT);
        }

        if (cfg.showMapLabels && !pin.name.empty()) {
            ImVec2 textPos(sp.x + r + 3.0f * uiScale, sp.y - ImGui::GetFontSize() * 0.5f);
            dl->AddText(ImVec2(textPos.x + 1.0f, textPos.y + 1.0f), IM_COL32(0, 0, 0, 210), pin.name.c_str());
            dl->AddText(textPos, IM_COL32(250, 252, 255, 240), pin.name.c_str());
        }

        if (mouseInMap) {
            float dx = mouse.x - sp.x;
            float dy = mouse.y - sp.y;
            float d2 = dx * dx + dy * dy;
            if (d2 < bestDistSq) {
                bestDistSq = d2;
                hovered = &pin;
                hoveredScreen = sp;
            }
        }
    }

    g_lastRenderedPinCount.store(drawnCount);

    if (hovered) {
        dl->AddCircle(hoveredScreen, baseR * 1.95f, IM_COL32(255, 255, 255, 255), 0, 2.2f * uiScale);
    }

    if (cfg.showMapLegend && !s_legendOrder.empty()) {
        const float pad = 10.0f * uiScale;
        const float lineH = ImGui::GetFontSize() + 5.0f * uiScale;
        float maxW = 155.0f * uiScale;
        for (const auto& lg : s_legendOrder) {
            char buf[192];
            std::snprintf(buf, sizeof(buf), "%s (%d)", lg.label, lg.count);
            float w = ImGui::CalcTextSize(buf).x + 28.0f * uiScale;
            if (w > maxW) maxW = w;
        }
        const int maxItems = std::min<int>(static_cast<int>(s_legendOrder.size()), 12);
        const float boxW = maxW + pad * 2.0f;
        const float boxH = (maxItems + 1) * lineH + pad * 1.8f;
        float boxY = std::min(clipMin.y + 215.0f * uiScale, std::max(clipMin.y + 14.0f * uiScale, clipMax.y - boxH - 120.0f * uiScale));
        ImVec2 bMin(clipMax.x - boxW - 14.0f * uiScale, boxY);
        ImVec2 bMax(bMin.x + boxW, bMin.y + boxH);

        dl->AddRectFilled(bMin, bMax, IM_COL32(14, 20, 28, 215), 6.0f * uiScale);
        dl->AddRect(bMin, bMax, IM_COL32(95, 195, 235, 185), 6.0f * uiScale, 0, 1.2f * uiScale);

        ImVec2 cur(bMin.x + pad, bMin.y + pad * 0.7f);
        dl->AddText(cur, IM_COL32(140, 225, 255, 255), "QoL 地图追踪 [Insert/F8]");
        cur.y += lineH;

        for (int i = 0; i < maxItems; ++i) {
            const auto& lg = s_legendOrder[i];
            ImVec2 iconC(cur.x + 6.0f * uiScale, cur.y + ImGui::GetFontSize() * 0.5f);
            if (lg.isDiamond) {
                DrawDiamond(dl, iconC, 5.5f * uiScale, lg.color, IM_COL32(255, 255, 255, 220), 1.0f * uiScale);
            } else {
                dl->AddCircleFilled(iconC, 4.8f * uiScale, lg.color);
                dl->AddCircle(iconC, 4.8f * uiScale, IM_COL32(255, 255, 255, 220), 0, 1.0f * uiScale);
            }
            char buf[192];
            std::snprintf(buf, sizeof(buf), "%s (%d)", lg.label, lg.count);
            dl->AddText(ImVec2(cur.x + 18.0f * uiScale, cur.y), IM_COL32(238, 244, 250, 255), buf);
            cur.y += lineH;
        }
    }

    dl->PopClipRect();

    if (hovered) {
        {
            std::lock_guard<std::mutex> lk(g_hoverMutex);
            g_hoveredPin.valid = true;
            g_hoveredPin.wx = hovered->wx;
            g_hoveredPin.wy = hovered->wy;
            g_hoveredPin.wz = hovered->wz;
            g_hoveredPin.name = hovered->name;
        }

        char line1[192];
        std::snprintf(line1, sizeof(line1), "%s", hovered->name.c_str());

        char line2[192] = "";
        if (mapLive.hasPlayerPos) {
            float dx = (hovered->wx - mapLive.playerX) / 100.0f;
            float dy = (hovered->wy - mapLive.playerY) / 100.0f;
            float dz = (hovered->wz - mapLive.playerZ) / 100.0f;
            float dist2D = std::sqrt(dx * dx + dy * dy);
            const char* elev = (dz > 2.0f) ? "↑ 上方" : ((dz < -2.0f) ? "↓ 地下/下方" : "≈ 同高度");
            std::snprintf(line2, sizeof(line2), "距离: %.0f cm (%.1f m) | %s %.1f m",
                          dist2D * 100.0f, dist2D, elev, std::fabs(dz));
        }
        const char* line3 = "按 G 键 或 Ctrl+左键：在此放置原版路标（全队可见）";

        ImVec2 s1 = ImGui::CalcTextSize(line1);
        ImVec2 s2 = ImGui::CalcTextSize(line2);
        ImVec2 s3 = ImGui::CalcTextSize(line3);
        float w = std::max({s1.x, s2.x, s3.x}) + 22.0f * uiScale;
        float lineH = ImGui::GetFontSize() + 4.0f * uiScale;
        float h = (line2[0] ? 3.0f : 2.0f) * lineH + 16.0f * uiScale;

        ImVec2 tipMin(mouse.x + 18.0f * uiScale, mouse.y + 18.0f * uiScale);
        if (tipMin.x + w > disp.x - 10.0f) tipMin.x = mouse.x - w - 14.0f * uiScale;
        if (tipMin.y + h > disp.y - 10.0f) tipMin.y = mouse.y - h - 14.0f * uiScale;
        ImVec2 tipMax(tipMin.x + w, tipMin.y + h);

        dl->AddRectFilled(tipMin, tipMax, IM_COL32(12, 17, 24, 240), 6.0f * uiScale);
        dl->AddRect(tipMin, tipMax, IM_COL32(100, 215, 255, 220), 6.0f * uiScale, 0, 1.4f * uiScale);

        ImVec2 p(tipMin.x + 11.0f * uiScale, tipMin.y + 8.0f * uiScale);
        dl->AddText(p, IM_COL32(255, 232, 130, 255), line1);
        p.y += lineH;
        if (line2[0]) {
            dl->AddText(p, IM_COL32(225, 238, 250, 255), line2);
            p.y += lineH;
        }
        dl->AddText(p, IM_COL32(130, 220, 165, 255), line3);
    } else {
        std::lock_guard<std::mutex> lk(g_hoverMutex);
        g_hoveredPin.valid = false;
    }
}

/// 渲染内置自绘输入法候选条（ADR-0003）：
/// 直接绘制在 ImGui::GetForegroundDrawList() 最顶层前景，彻底杜绝因点击 Mod 主菜单导致普通窗口被压在背后看不见的 Z 轴遮挡，
/// 并向 WndProc 上报每枚候选按钮矩形实现零抢焦鼠标点选上屏（绝不令 InputText 失焦取消组词）。
void RenderImeCandidateBar(float uiScale) {
    const ImeCandidateState ime = GetImeCandidateState();
    if (!ime.useSelfDrawnUi || (!ime.composing && ime.compositionUtf8.empty() && ime.candidates.empty())) {
        UpdateImeCandidateHitRects(false, {}, {});
        return;
    }

    ImGuiIO& io = ImGui::GetIO();
    const ImVec2 disp = io.DisplaySize;
    if (disp.x < 100.0f || disp.y < 100.0f) {
        UpdateImeCandidateHitRects(false, {}, {});
        return;
    }

    const float padX = 11.0f * uiScale;
    const float padY = 8.0f * uiScale;
    const float fontH = ImGui::GetFontSize();
    const float chipPadX = 7.0f * uiScale;
    const float chipPadY = 3.0f * uiScale;
    const float chipGap = 6.0f * uiScale;
    const float sepGap = 6.0f * uiScale;

    std::string displayComp;
    if (!ime.compositionUtf8.empty()) {
        const size_t split = std::min(static_cast<size_t>(std::max(0, ime.cursorByteOffset)), ime.compositionUtf8.size());
        displayComp = ime.compositionUtf8.substr(0, split) + "|" + ime.compositionUtf8.substr(split);
    } else {
        displayComp = "中文组词中...";
    }
    const char* hintText = "空格/1~9/点选 | Esc取消";

    const ImVec2 compSz = ImGui::CalcTextSize(displayComp.c_str());
    const ImVec2 hintSz = ImGui::CalcTextSize(hintText);
    const float row1W = compSz.x + 16.0f * uiScale + hintSz.x;
    const float row1H = std::max(compSz.y, hintSz.y);

    std::vector<std::string> chipLabels;
    std::vector<float> chipWidths;
    float row2W = 0.0f;
    float row2H = 0.0f;
    std::string pageInfo;
    if (!ime.candidates.empty()) {
        chipLabels.reserve(ime.candidates.size());
        chipWidths.reserve(ime.candidates.size());
        for (size_t i = 0; i < ime.candidates.size(); ++i) {
            char buf[160];
            std::snprintf(buf, sizeof(buf), "%d.%s", static_cast<int>(i + 1), ime.candidates[i].c_str());
            chipLabels.emplace_back(buf);
            const float w = ImGui::CalcTextSize(buf).x + chipPadX * 2.0f;
            chipWidths.push_back(w);
            if (i > 0) row2W += chipGap;
            row2W += w;
        }
        if (ime.totalCandidates > static_cast<int>(ime.candidates.size())) {
            char pbuf[48];
            std::snprintf(pbuf, sizeof(pbuf), "(%d/%d)", ime.pageStart + ime.selectedIndex + 1, ime.totalCandidates);
            pageInfo = pbuf;
            row2W += 10.0f * uiScale + ImGui::CalcTextSize(pbuf).x;
        }
        row2H = fontH + chipPadY * 2.0f;
    }

    const float barW = std::max(row1W, row2W) + padX * 2.0f;
    const float barH = padY * 2.0f + row1H + (ime.candidates.empty() ? 0.0f : (sepGap * 2.0f + 1.0f + row2H));

    // 当尚未收到有效输入框光标坐标时，默认锚定在屏幕上中偏上可见位置，避免躲到角落
    float anchorX = (ime.inputPosX > 1.0f || ime.inputPosY > 1.0f) ? ime.inputPosX : (disp.x * 0.5f - barW * 0.5f);
    float anchorY = (ime.inputPosX > 1.0f || ime.inputPosY > 1.0f) ? ime.inputPosY : (disp.y * 0.35f);
    float lineH = (ime.inputLineHeight > 1.0f) ? ime.inputLineHeight : (20.0f * uiScale);

    float posX = std::clamp(anchorX, 8.0f * uiScale, std::max(8.0f * uiScale, disp.x - barW - 8.0f * uiScale));
    float posY = anchorY + lineH + 6.0f * uiScale;
    if (posY + barH > disp.y - 8.0f * uiScale) {
        // 靠近屏幕底边时自动上翻到输入框上方防裁切
        posY = std::max(8.0f * uiScale, anchorY - barH - 6.0f * uiScale);
    }

    ImDrawList* dl = ImGui::GetForegroundDrawList();
    const ImVec2 bMin(posX, posY);
    const ImVec2 bMax(posX + barW, posY + barH);
    const float round = 6.0f * uiScale;

    // 柔和阴影 + 顶层高亮边框背景卡片
    dl->AddRectFilled(ImVec2(bMin.x + 2.0f * uiScale, bMin.y + 3.0f * uiScale),
                      ImVec2(bMax.x + 2.0f * uiScale, bMax.y + 3.0f * uiScale),
                      IM_COL32(0, 0, 0, 145), round);
    dl->AddRectFilled(bMin, bMax, IM_COL32(14, 21, 32, 248), round);
    dl->AddRect(bMin, bMax, IM_COL32(82, 200, 250, 238), round, 0, 1.5f * uiScale);

    // 上行：当前拼音组词串 + 快捷键提示
    const float yRow1 = posY + padY;
    dl->AddText(ImVec2(posX + padX, yRow1), IM_COL32(115, 230, 255, 255), displayComp.c_str());
    dl->AddText(ImVec2(posX + padX + compSz.x + 16.0f * uiScale, yRow1), IM_COL32(150, 168, 186, 225), hintText);

    // 下行：横向编号候选字按钮（支持悬停高亮 + WndProc 零抢焦点击上屏）
    std::vector<ImeCandidateHitRect> hitRects;
    if (!chipLabels.empty()) {
        const float ySep = yRow1 + row1H + sepGap;
        dl->AddLine(ImVec2(posX + padX, ySep), ImVec2(bMax.x - padX, ySep), IM_COL32(72, 130, 165, 135), 1.0f);

        const float yRow2 = ySep + sepGap + 1.0f;
        float curX = posX + padX;
        const ImVec2 mouse = io.MousePos;
        hitRects.reserve(chipLabels.size());

        for (size_t i = 0; i < chipLabels.size(); ++i) {
            const float w = chipWidths[i];
            const ImVec2 cMin(curX, yRow2);
            const ImVec2 cMax(curX + w, yRow2 + row2H);
            const bool isSel = (static_cast<int>(i) == ime.selectedIndex);
            const bool isHov = (mouse.x >= cMin.x && mouse.x <= cMax.x && mouse.y >= cMin.y && mouse.y <= cMax.y);

            ImU32 fillCol = IM_COL32(30, 41, 56, 230);
            ImU32 textCol = IM_COL32(235, 243, 250, 255);
            if (isSel) {
                fillCol = isHov ? IM_COL32(56, 148, 204, 255) : IM_COL32(41, 122, 173, 255);
                textCol = IM_COL32(255, 245, 184, 255);
            } else if (isHov) {
                fillCol = IM_COL32(46, 76, 108, 245);
                textCol = IM_COL32(255, 255, 255, 255);
            }
            dl->AddRectFilled(cMin, cMax, fillCol, 4.0f * uiScale);
            dl->AddText(ImVec2(cMin.x + chipPadX, cMin.y + chipPadY), textCol, chipLabels[i].c_str());

            hitRects.push_back({cMin.x, cMin.y, cMax.x, cMax.y});
            curX += w + chipGap;
        }
        if (!pageInfo.empty()) {
            dl->AddText(ImVec2(curX + 4.0f * uiScale, yRow2 + chipPadY), IM_COL32(150, 168, 186, 225), pageInfo.c_str());
        }
    }

    UpdateImeCandidateHitRects(true, {bMin.x, bMin.y, bMax.x, bMax.y}, hitRects);
}

/// 渲染游戏内 Mod 主配置菜单。
void RenderModMenuWindow(const ModConfig& immutableCfg, ModConfig& cfg, bool& cfgDirty, bool& menuOpen, float uiScale) {
    const auto statusPtr = IpcBridge::Instance().GetStatusSnapshot();
    const auto catalogPtr = IpcBridge::Instance().GetCatalogSnapshot();
    const RuntimeStatus& status = *statusPtr;
    const auto& catalog = *catalogPtr;

    ImGui::SetNextWindowSize(ImVec2(800.0f * uiScale, 700.0f * uiScale), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(
        ImVec2(ImGui::GetIO().DisplaySize.x * 0.5f, ImGui::GetIO().DisplaySize.y * 0.5f),
        ImGuiCond_FirstUseEver, ImVec2(0.5f, 0.5f));

    ImGuiWindowFlags flags = ImGuiWindowFlags_NoCollapse;
    if (!ImGui::Begin("禁闭求生 体验增强工具箱 (GroundedQoL)  |  Insert / F8 开关", &menuOpen, flags)) {
        ImGui::End();
        return;
    }

    // 顶部状态条
    if (status.inWorld) {
        ImGui::TextColored(
            ImVec4(0.45f, 0.95f, 0.62f, 1.0f),
            "状态: 已进入存档 (%s) | 难度: %s | 乳牙剩余: 普通 %d/%d  高级 %d/%d",
            status.isHost ? "房主" : "客机",
            status.difficulty.c_str(),
            status.uncollectedMilkMolars, status.totalMilkMolars,
            status.uncollectedMegaMolars, status.totalMegaMolars);
    } else {
        ImGui::TextColored(ImVec4(1.0f, 0.80f, 0.35f, 1.0f),
                           "状态: 等待进入游戏存档（进入存档后各项倍率与全图资源列表将自动就绪）");
    }
    if (!status.lastMessage.empty()) {
        ImGui::TextColored(ImVec4(0.65f, 0.86f, 1.0f, 1.0f), "提示: %s", status.lastMessage.c_str());
    }
    ImGui::Separator();

    if (ImGui::BeginTabBar("MainTabs")) {
        // ============================================================
        // Tab 1: 堆叠 / 伤害 / 采集倍率 / 无材料 / 死亡保护
        // ============================================================
        if (ImGui::BeginTabItem("核心倍率与免材设置")) {
            ImGui::BeginChild("CoreSettingsScroll", ImVec2(0, 0), false);
            ImGui::Spacing();

            // 1. 物品堆叠倍率
            ImGui::TextColored(ImVec4(0.45f, 0.88f, 1.0f, 1.0f), "1. 物品堆叠上限倍率（背包与箱子通用）");
            if (ImGui::Checkbox("启用物品堆叠倍率##stack", &cfg.stackEnabled)) cfgDirty = true;
            ImGui::BeginDisabled(!cfg.stackEnabled);
            if (ImGui::SliderInt("堆叠倍率 (x)##stackMult", &cfg.stackMultiplier, 1, 50, "%d 倍")) cfgDirty = true;
            ImGui::SameLine();
            for (int preset : {1, 5, 10, 20, 50}) {
                char btn[32];
                std::snprintf(btn, sizeof(btn), "%dx##st%d", preset, preset);
                if (ImGui::SmallButton(btn)) {
                    cfg.stackMultiplier = preset;
                    cfgDirty = true;
                }
                ImGui::SameLine();
            }
            ImGui::NewLine();
            ImGui::EndDisabled();
            if (!status.stackSummary.empty()) {
                ImGui::TextWrapped("当前生效堆叠: %s", status.stackSummary.c_str());
            } else {
                ImGui::TextDisabled("自动跳过武器/防具/工具等单件装备(基础堆叠=1)，防止耐久或强化异常合并。");
            }

            ImGui::Spacing();
            ImGui::Separator();
            ImGui::Spacing();

            // 2. 玩家伤害倍率
            ImGui::TextColored(ImVec4(1.0f, 0.78f, 0.35f, 1.0f), "2. 战斗伤害倍率（房主设置全队生效，不影响成就）");
            if (ImGui::Checkbox("启用伤害倍率调整##dmg", &cfg.damageEnabled)) cfgDirty = true;
            ImGui::BeginDisabled(!cfg.damageEnabled);
            if (ImGui::SliderFloat("玩家伤害倍率##pdmg", &cfg.playerDamageMultiplier, 0.5f, 10.0f, "%.2f 倍")) {
                cfgDirty = true;
            }
            for (float p : {1.0f, 1.25f, 1.5f, 2.0f, 3.0f, 5.0f}) {
                char btn[32];
                std::snprintf(btn, sizeof(btn), "%.2gx##pd%.2f", p, p);
                if (ImGui::SmallButton(btn)) {
                    cfg.playerDamageMultiplier = p;
                    cfgDirty = true;
                }
                ImGui::SameLine();
            }
            ImGui::NewLine();

            if (ImGui::SliderFloat("怪物伤害倍率（可选微调难度）##edmg", &cfg.enemyDamageMultiplier, 0.2f, 3.0f, "%.2f 倍")) {
                cfgDirty = true;
            }
            ImGui::EndDisabled();
            ImGui::TextDisabled("当前游戏实时数值：玩家伤害 %.2fx | 怪物伤害 %.2fx",
                                status.livePlayerDamage, status.liveEnemyDamage);

            ImGui::Spacing();
            ImGui::Separator();
            ImGui::Spacing();

            // 3. 采集入包与搬运倍率（ADR-0005：普通物品 1 倍爆出、入包统一乘倍率；仅搬运物砍倒瞬时缩放）
            ImGui::TextColored(ImVec4(0.55f, 0.96f, 0.55f, 1.0f), "3. 采集入包与搬运数量倍率（房主设置全队生效，地上仅爆 1 倍防卡顿）");
            if (ImGui::Checkbox("启用采集入包倍率（砍/锤/挖/杀爆出保持 1 倍，拾取入包与摸尸走倍率）##harv", &cfg.harvestEnabled)) cfgDirty = true;
            ImGui::BeginDisabled(!cfg.harvestEnabled);
            if (ImGui::SliderInt("采集倍率 (x)##harvMult", &cfg.harvestMultiplier, 1, 20, "%d 倍")) cfgDirty = true;
            ImGui::SameLine();
            for (int preset : {1, 2, 3, 5, 10}) {
                char btn[32];
                std::snprintf(btn, sizeof(btn), "%dx##hv%d", preset, preset);
                if (ImGui::SmallButton(btn)) {
                    cfg.harvestMultiplier = preset;
                    cfgDirty = true;
                }
                ImGui::SameLine();
            }
            ImGui::NewLine();
            if (ImGui::Checkbox("同时对草板/杂草茎等肩扛搬运物生效（砍倒瞬间缩放并还原，单棵封顶 12 根）", &cfg.harvestAffectHauling)) {
                cfgDirty = true;
            }
            if (ImGui::Checkbox("同时对地面天然散落物直拾生效（树枝/植物纤维/鹅卵石/小蘑菇等）", &cfg.harvestAffectPickup)) {
                cfgDirty = true;
            }
            ImGui::EndDisabled();
            ImGui::TextDisabled("零模板污染架构：严格排除玩家丢弃物、投掷物、拆建返还物、容器转移与单件装备 | 本次已生效: %d 次",
                                status.lootCompCount);

            ImGui::Spacing();
            ImGui::Separator();
            ImGui::Spacing();

            // 4. 工作台建设、合成与制作无需材料立刻完成
            ImGui::TextColored(ImVec4(0.95f, 0.65f, 1.0f, 1.0f), "4. 无材料秒建与免费合成（工作台/建筑/工具制作，不影响成就）");
            if (ImGui::Checkbox("建造无需材料立刻建成（含工作台等全部建筑蓝图）##instbuild", &cfg.instantBuildEnabled)) {
                cfgDirty = true;
            }
            if (ImGui::Checkbox("工作台/背包合成制作工具无需材料立刻完成##freecraft", &cfg.freeCraftEnabled)) {
                cfgDirty = true;
            }
            if (ImGui::Checkbox("同时解锁全部制作与建筑配方（可选）##unlockall", &cfg.unlockAllRecipes)) {
                cfgDirty = true;
            }
            if (ImGui::Button("一键全开（秒建 + 免费制作）")) {
                cfg.instantBuildEnabled = true;
                cfg.freeCraftEnabled = true;
                cfgDirty = true;
            }
            ImGui::SameLine();
            if (ImGui::Button("一键关闭无材料模式")) {
                cfg.instantBuildEnabled = false;
                cfg.freeCraftEnabled = false;
                cfg.unlockAllRecipes = false;
                cfgDirty = true;
            }
            ImGui::SameLine();
            if (ImGui::Button("一键建成已放置的未完工蓝图")) {
                IpcBridge::Instance().PushAction("build_all_blueprints");
            }
            ImGui::TextDisabled("说明：秒建对全队放置的蓝图即时生效；无材料制作在房主端立刻生效，队友安装分享包后亦可同步使用。");

            ImGui::Spacing();
            ImGui::Separator();
            ImGui::Spacing();

            // 5. 死亡背包保留、耐久保护与一键找回背包
            ImGui::TextColored(ImVec4(0.45f, 0.92f, 0.78f, 1.0f), "5. 死亡保护与一键找回背包（房主设置全队生效，不影响成就）");
            const bool isClientBlocked = status.inWorld && !status.isHost;
            ImGui::BeginDisabled(isClientBlocked);
            if (ImGui::Checkbox("死亡时保留背包内全部物品（不生成掉落背包）##keepinv", &cfg.keepInventoryOnDeath)) {
                cfgDirty = true;
            }
            if (ImGui::Checkbox("同时免除死亡装备耐久度惩罚（独立可选）##nodurpen", &cfg.noDeathDurabilityPenalty)) {
                cfgDirty = true;
            }
            if (ImGui::Button("一键找回我的背包（瞬移到脚边）")) {
                IpcBridge::Instance().PushAction("recover_my_backpacks");
            }
            ImGui::SameLine();
            if (ImGui::Button("找回全队背包（各回本人脚边）")) {
                IpcBridge::Instance().PushAction("recover_all_backpacks");
            }
            ImGui::EndDisabled();

            if (isClientBlocked) {
                ImGui::TextColored(
                    ImVec4(1.0f, 0.72f, 0.32f, 1.0f),
                    "当前为联机客机，仅房主可操作：由房主开启死亡保留或点击“找回全队背包”即可生效。");
            } else {
                ImGui::TextDisabled(
                    "当前游戏实时状态：死亡背包保留 [%s] | 死亡装备耐久惩罚 [%s]",
                    status.liveKeepInventoryOnDeath ? "已开启" : "原版掉落",
                    status.liveNoDeathDurabilityPenalty ? "已免除" : "原版惩罚");
                ImGui::TextDisabled(
                    "说明：仅瞬移玩家死亡掉落的非空背包（排除建筑战利品袋），自动唤醒远距背包并在前方扇形错开摆放。");
            }

            ImGui::EndChild();
            ImGui::EndTabItem();
        }

        // ============================================================
        // Tab 2: “M” 地图追踪（乳牙 + 全资源自由追踪）
        // ============================================================
        if (ImGui::BeginTabItem("“M” 地图追踪（乳牙 & 全资源）")) {
            ImGui::Spacing();
            ImGui::TextColored(ImVec4(0.45f, 0.88f, 1.0f, 1.0f), "乳牙与固定收集品（按 M 打开地图直接显示）");

            if (ImGui::Checkbox("显示未采集 普通乳牙（蓝圆点）", &cfg.showMilkMolars)) cfgDirty = true;
            ImGui::SameLine();
            if (ImGui::Checkbox("显示未采集 高级乳牙（金菱形）", &cfg.showMegaMilkMolars)) cfgDirty = true;

            if (ImGui::Checkbox("显示未采集 SCA.B 配色（紫菱形）", &cfg.showScabColors)) cfgDirty = true;
            ImGui::SameLine();
            if (ImGui::Checkbox("同时灰显已采集的乳牙", &cfg.showCollectedMolars)) cfgDirty = true;

            if (ImGui::Checkbox("在地图标点旁常驻文字标签", &cfg.showMapLabels)) cfgDirty = true;
            ImGui::SameLine();
            if (ImGui::Checkbox("显示地图右上角图例", &cfg.showMapLegend)) cfgDirty = true;

            ImGui::SetNextItemWidth(220.0f * uiScale);
            if (ImGui::SliderFloat("地图图标大小", &cfg.mapIconScale, 0.6f, 2.0f, "%.1fx")) cfgDirty = true;
            ImGui::SameLine();
            if (ImGui::Button("一键解锁全图原版资源扫描仪")) {
                IpcBridge::Instance().PushAction("activate_surveyors");
            }
            ImGui::SameLine();
            if (ImGui::Button("立即刷新世界资源")) {
                IpcBridge::Instance().PushAction("refresh_catalog");
            }

            if (!status.surveyedItemName.empty()) {
                ImGui::TextColored(ImVec4(1.0f, 0.55f, 0.55f, 1.0f),
                                   "当前原版红热区扫描中（全队可见）: %s", status.surveyedItemName.c_str());
            }

            ImGui::Separator();
            if (status.inWorld && !status.isHost) {
                ImGui::TextColored(ImVec4(0.45f, 0.90f, 1.0f, 1.0f),
                                   "客机独立追踪模式：乳牙/SCA.B 与全图植被已同步，采集点/生物/宝箱自动追踪客机周边已加载范围（主客机勾选互不共享）。");
            }
            ImGui::TextColored(ImVec4(0.55f, 0.96f, 0.55f, 1.0f),
                               "自由追踪全游戏物品 / 道具 / 资源 / 采集点 / 生物（仅本机可见、可多选，共 %d 项）",
                               static_cast<int>(catalog.size()));

            static char searchBuf[128] = "";
            static int catFilter = 0;

            ImGui::SetNextItemWidth(280.0f * uiScale);
            ImGui::InputTextWithHint("##search", "搜索中文或英文名（支持中文输入法：薄荷 / 狼蛛 / 橡果）", searchBuf, sizeof(searchBuf));
            ImGui::SameLine();
            const char* catNames[] = {"全部", "仅看已追踪", "采集点/矿石", "散落物品", "生物/昆虫", "全图可扫描物品", "特殊/宝箱"};
            ImGui::SetNextItemWidth(160.0f * uiScale);
            ImGui::Combo("##cat", &catFilter, catNames, IM_ARRAYSIZE(catNames));
            ImGui::SameLine();
            if (ImGui::Button("清空全部追踪")) {
                cfg.trackedIds.clear();
                cfgDirty = true;
            }

            // 预构建已追踪集合（视图指向本帧不可变的 immutableCfg.trackedIds，绝不会因勾选修改 cfg.trackedIds 而悬空）
            static std::vector<size_t> s_filteredIndices;
            s_filteredIndices.clear();
            std::unordered_set<std::string_view> trackedSet;
            trackedSet.reserve(immutableCfg.trackedIds.size() * 2 + 4);
            for (const auto& tid : immutableCfg.trackedIds) {
                trackedSet.insert(tid);
            }
            const std::string lowerQuery = ToLowerAscii(searchBuf);

            for (size_t i = 0; i < catalog.size(); ++i) {
                const auto& e = catalog[i];
                const bool isTracked = trackedSet.count(e.id) > 0;
                if (catFilter == 1 && !isTracked) continue;
                if (catFilter == 2 && e.category != "node") continue;
                if (catFilter == 3 && e.category != "item") continue;
                if (catFilter == 4 && e.category != "creature") continue;
                if (catFilter == 5 && !e.surveyable) continue;
                if (catFilter == 6 && e.category != "special") continue;

                if (!lowerQuery.empty() &&
                    !ContainsLowerNeedleNoAlloc(e.name, lowerQuery) &&
                    !ContainsLowerNeedleNoAlloc(e.rawName, lowerQuery) &&
                    !ContainsLowerNeedleNoAlloc(e.rowName, lowerQuery)) {
                    continue;
                }
                s_filteredIndices.push_back(i);
            }

            ImGui::BeginChild("CatalogScroll", ImVec2(0, 0), true);
            if (catalog.empty()) {
                ImGui::TextDisabled("尚未获取到世界资源目录。请先进入游戏存档，或点击上方“立即刷新世界资源”。");
            } else if (s_filteredIndices.empty()) {
                ImGui::TextDisabled("没有匹配当前搜索条件或分类的资源。");
            } else {
                ImGuiListClipper clipper;
                clipper.Begin(static_cast<int>(s_filteredIndices.size()));
                while (clipper.Step()) {
                    for (int row = clipper.DisplayStart; row < clipper.DisplayEnd; ++row) {
                        const size_t i = s_filteredIndices[static_cast<size_t>(row)];
                        const auto& e = catalog[i];
                        bool checked = trackedSet.count(e.id) > 0;

                        ImGui::PushID(static_cast<int>(i));

                        char label[256];
                        if (e.count > 0) {
                            std::snprintf(label, sizeof(label), "%s  [%s | %d处]",
                                          e.name.c_str(), CategoryLabelZh(e.category), e.count);
                        } else {
                            std::snprintf(label, sizeof(label), "%s  [%s]",
                                          e.name.c_str(), CategoryLabelZh(e.category));
                        }

                        if (ImGui::Checkbox(label, &checked)) {
                            if (checked) {
                                if (trackedSet.count(e.id) == 0) {
                                    cfg.trackedIds.push_back(e.id);
                                    cfgDirty = true;
                                }
                            } else {
                                cfg.trackedIds.erase(
                                    std::remove(cfg.trackedIds.begin(), cfg.trackedIds.end(), e.id),
                                    cfg.trackedIds.end());
                                cfgDirty = true;
                            }
                        }

                        if (e.surveyable && !e.rowName.empty()) {
                            ImGui::SameLine();
                            if (ImGui::SmallButton("原版热区(全队)")) {
                                IpcBridge::Instance().PushAction("survey_item", e.rowName);
                            }
                        }

                        ImGui::PopID();
                    }
                }
            }
            ImGui::EndChild();

            ImGui::EndTabItem();
        }

        // ============================================================
        // Tab 3: 使用说明、输入法模式设置与多人联机提示
        // ============================================================
        if (ImGui::BeginTabItem("快捷键与联机说明")) {
            ImGui::Spacing();
            ImGui::BulletText("按 Insert 或 F8：随时打开 / 关闭本 Mod 菜单（Esc 也可关闭，中文组词期间按 Esc 优先取消拼音组词）。");
            ImGui::BulletText("按 M 打开游戏原生大地图后，所有乳牙、高级乳牙与已勾选的追踪资源将自动显示在地图内，支持拖动与缩放。");
            ImGui::BulletText("在 M 地图上将鼠标移到任意标点上，可查看中文名称、直线距离与上下高度差（寻找地下洞穴乳牙非常实用）。");
            ImGui::BulletText("在 M 地图上悬停任意标点时，按 G 键或 Ctrl+左键，可一键放置游戏原版路标（3D 导航且联机队友可见）。");
            ImGui::BulletText("勾选列表右侧的 [原版热区(全队)] 按钮可直接调用游戏原版资源扫描仪，把该物品的全图红热区同步给联机队友。");

            ImGui::Separator();
            ImGui::TextColored(ImVec4(0.45f, 0.88f, 1.0f, 1.0f), "中文输入法候选框显示设置：");
            const char* imeModes[] = {
                "自动（推荐：无边框走系统原生，独占全屏切内置自绘）",
                "强制使用系统原生候选框",
                "强制使用内置自绘候选条（顶层防遮挡，支持键鼠双选词）",
            };
            int imeMode = std::clamp(cfg.imeCandidateMode, 0, 2);
            ImGui::SetNextItemWidth(440.0f * uiScale);
            if (ImGui::Combo("输入法候选框模式##imemode", &imeMode, imeModes, IM_ARRAYSIZE(imeModes))) {
                cfg.imeCandidateMode = imeMode;
                cfgDirty = true;
            }
            const ImeCandidateState imeInfo = GetImeCandidateState();
            const char* candSrcText = (imeInfo.candidateSource == 2) ? "TSF" :
                                      ((imeInfo.candidateSource == 1) ? "IMM32" : "待组词");
            ImGui::TextDisabled("当前检测：%s | 实际方式：%s | 候选源：%s（切换立即生效）",
                                imeInfo.isExclusiveFullscreen ? "独占全屏模式" : "无边框/窗口模式",
                                imeInfo.useSelfDrawnUi ? "ImGui 顶层自绘候选条" : "Windows 系统原生候选框",
                                candSrcText);

            ImGui::Separator();
            ImGui::TextColored(ImVec4(1.0f, 0.82f, 0.40f, 1.0f), "多人联机（房主 / 客机）说明：");
            ImGui::BulletText("玩家伤害倍率、怪物伤害倍率、采集入包与搬运倍率、原版路标与原版热区扫描：仅房主安装即可全队生效。");
            ImGui::BulletText("M 地图自由勾选追踪：主机与客机各自独立保存、互不共享（客机可独立追踪全图植被与周边同步范围内的采集点/生物/宝箱）；乳牙与高级乳牙全队共享同步。");
            ImGui::BulletText("列表右侧的 [原版热区(全队)] 与悬停按 G/Ctrl+左键 放置的原版路标调用游戏原版联机机制，会对全队生效。");
            ImGui::BulletText("死亡背包保留、免除死亡耐久惩罚与一键找回背包：仅限房主操作，开启死亡保留后全队共享；房主点击“找回全队背包”可将在线队友的掉落背包送至各自脚边（离线玩家背包送至房主脚边）。");
            ImGui::BulletText("物品堆叠上限倍率：房主可直接享受大堆叠；队友安装绿色分享包后可同步享受大堆叠、免费制作与客机独立 M 地图追踪。");
            ImGui::BulletText("本插件不会将存档切换为“自定义模式”，不影响 Steam 成就解锁。");
            ImGui::EndTabItem();
        }

        ImGui::EndTabBar();
    }

    ImGui::End();
}

} // namespace

void InitOverlayStyleAndFonts(float uiScale) {
    ImGuiStyle& style = ImGui::GetStyle();
    ImGui::StyleColorsDark(&style);
    style.WindowRounding = 8.0f;
    style.FrameRounding = 5.0f;
    style.GrabRounding = 4.0f;
    style.TabRounding = 5.0f;
    style.ChildRounding = 5.0f;
    style.WindowBorderSize = 1.2f;
    style.Colors[ImGuiCol_WindowBg] = ImVec4(0.07f, 0.09f, 0.12f, 0.94f);
    style.Colors[ImGuiCol_TitleBgActive] = ImVec4(0.11f, 0.30f, 0.42f, 0.98f);
    style.Colors[ImGuiCol_TabActive] = ImVec4(0.16f, 0.45f, 0.62f, 1.00f);
    style.Colors[ImGuiCol_TabHovered] = ImVec4(0.22f, 0.56f, 0.75f, 1.00f);
    style.Colors[ImGuiCol_CheckMark] = ImVec4(0.40f, 0.92f, 0.65f, 1.00f);
    style.Colors[ImGuiCol_SliderGrab] = ImVec4(0.35f, 0.78f, 0.98f, 1.00f);
    style.ScaleAllSizes(uiScale);

    ImGuiIO& io = ImGui::GetIO();
    const float fontPx = std::round(17.5f * uiScale);
    const char* fontCandidates[] = {
        "C:\\Windows\\Fonts\\msyh.ttc",
        "C:\\Windows\\Fonts\\msyh.ttf",
        "C:\\Windows\\Fonts\\simhei.ttf",
        "C:\\Windows\\Fonts\\simsun.ttc",
    };

    // 保留完整中文字库（覆盖蚜/蛹/螯/藓等冷门昆虫植物字），将采样从 2x2 降至 1x1 像素对齐，减少 75% 显存与首帧烘焙耗时
    ImFontConfig fc;
    fc.OversampleH = 1;
    fc.OversampleV = 1;
    fc.PixelSnapH = true;

    bool loaded = false;
    for (const char* fp : fontCandidates) {
        if (GetFileAttributesA(fp) != INVALID_FILE_ATTRIBUTES) {
            if (io.Fonts->AddFontFromFileTTF(fp, fontPx, &fc, io.Fonts->GetGlyphRangesChineseFull()) != nullptr) {
                loaded = true;
                break;
            }
        }
    }
    if (!loaded) {
        io.Fonts->AddFontDefault();
    }
}

void ResetOverlayIdleState() {
    g_prevMapOpenLogged = false;
    g_loggedNativeTransformForCurrentOpen = false;
    g_lastRenderedPinCount.store(0, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lk(g_hoverMutex);
    g_hoveredPin.valid = false;
}

void RenderOverlayFrame(bool& menuOpen, float uiScale) {
    const auto cfgSnap = IpcBridge::Instance().GetConfigSnapshot();
    const auto mapSnap = IpcBridge::Instance().GetMapLiveSnapshot();

    // 1. M 地图追踪标点层（M 地图打开时渲染）
    RenderMapOverlay(*cfgSnap, *mapSnap, menuOpen, uiScale);

    // 2. 游戏内 Mod 配置菜单（按 Insert / F8 呼出）与内置自绘中文候选条
    if (menuOpen) {
        ModConfig editableCfg = *cfgSnap;
        const int prevImeMode = editableCfg.imeCandidateMode;
        bool dirty = false;
        RenderModMenuWindow(*cfgSnap, editableCfg, dirty, menuOpen, uiScale);
        if (dirty) {
            IpcBridge::Instance().UpdateConfigAndSave(editableCfg);
            if (editableCfg.imeCandidateMode != prevImeMode) {
                NotifyImeModeChanged();
            }
        }
        RenderImeCandidateBar(uiScale);
    } else {
        UpdateImeCandidateHitRects(false, {}, {});
    }
}

bool HandleMapQuickShortcut(UINT msg, WPARAM wParam, LPARAM /*lParam*/) {
    bool trigger = false;
    if (msg == WM_KEYDOWN && wParam == 'G') {
        trigger = true;
    } else if (msg == WM_LBUTTONDOWN && (GetKeyState(VK_CONTROL) & 0x8000)) {
        trigger = true;
    }
    if (!trigger) return false;

    HoveredPinState hp;
    {
        std::lock_guard<std::mutex> lk(g_hoverMutex);
        hp = g_hoveredPin;
    }
    if (!hp.valid) return false;

    IpcBridge::Instance().PushAction("place_waypoint", hp.name, hp.wx, hp.wy, hp.wz);
    return true;
}

int GetLastRenderedMapPinCount() {
    return g_lastRenderedPinCount.load(std::memory_order_relaxed);
}

} // namespace gqol
