/*
 * 文件：overlay/src/overlay_ui.h
 * 职责：声明 Dear ImGui 悬浮层的主题字体初始化、每帧渲染入口、空闲态重置与 M 地图快捷键处理接口。
 */

#pragma once

#include <Windows.h>

namespace gqol {

/// 配置 ImGui 深色主题样式并按当前分辨率缩放（加载系统完整中文字库，1x1 像素对齐采样减少 75% 显存与构建耗时）。
void InitOverlayStyleAndFonts(float uiScale);

/// 在 DX12/DX11 Present 回调中渲染 Mod 中文悬浮菜单、内置自绘输入法候选条与 “M” 地图追踪叠加层。
void RenderOverlayFrame(bool& menuOpen, float uiScale);

/// 空闲零开销直通帧时快速重置 M 地图渲染计数与悬停状态（无堆分配）。
void ResetOverlayIdleState();

/// 在 M 地图打开且菜单关闭时，处理快捷放置原版路标热键（悬停标点按 G 键或 Ctrl+左键）。
bool HandleMapQuickShortcut(UINT msg, WPARAM wParam, LPARAM lParam);

/// 返回最近一帧 M 地图层实际绘制到屏幕上的有效标点数量（供自动化回归测试与诊断使用）。
int GetLastRenderedMapPinCount();

/// 返回最近一帧主菜单窗口在视口内的矩形（用于回归测试验证分辨率缩小后自动回拉防越界）。
void GetLastMenuWindowRect(float* outX, float* outY, float* outW, float* outH);

} // namespace gqol
