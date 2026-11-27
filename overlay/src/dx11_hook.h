#pragma once

#include <Windows.h>
#include <string>

namespace gqol {

/// 安装 DX12 / DX11 自适应图形钩子（Present / Present1 / ResizeBuffers / ExecuteCommandLists / WndProc）。
bool InstallGraphicsHook();

/// 卸载钩子并释放 ImGui 与图形渲染资源。
void UninstallGraphicsHook();

/// 查询当前 Mod 菜单是否处于打开状态。
bool IsMenuOpen();

/// 设置 Mod 菜单显示/隐藏状态。
void SetMenuOpen(bool open);

/// 获取当前激活的图形后端名称（"DX12" / "DX11" / "Unknown"）。
const char* GetActiveGraphicsBackend();

/// 获取当前挂钩的游戏主窗口句柄（用于屏幕绝对坐标到客户区坐标的兜底换算）。
HWND GetGameHwnd();

/// 写入悬浮层运行诊断日志到 data/overlay.log。
void OverlayLog(const char* fmt, ...);

} // namespace gqol
