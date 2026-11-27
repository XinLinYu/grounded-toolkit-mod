#pragma once

#include <Windows.h>

namespace gqol {

/// 配置 ImGui 主题样式并按当前分辨率缩放（自动加载微软雅黑支持简体中文）。
void InitOverlayStyleAndFonts(float uiScale);

/// 在 DX11 Present 回调中渲染 Mod 悬浮菜单与 “M” 地图追踪叠加层。
void RenderOverlayFrame(bool& menuOpen, float uiScale);

/// 在 M 地图打开且菜单关闭时，处理快捷放置原版路标热键（如悬停按 G 键或 Ctrl+左键）。
bool HandleMapQuickShortcut(UINT msg, WPARAM wParam, LPARAM lParam);

/// 返回最近一帧 M 地图层实际绘制到屏幕上的有效标点数量（供回归测试与诊断使用）。
int GetLastRenderedMapPinCount();

} // namespace gqol
