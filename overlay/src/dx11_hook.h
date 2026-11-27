/*
 * 文件：overlay/src/dx11_hook.h
 * 职责：声明自适应 DirectX 12 / DirectX 11 图形钩子与窗口消息钩子的公共生命周期接口及诊断日志工具。
 * 说明：文件名沿用 dx11_hook.h 历史命名，内部已完整支持 DX12（优先）与 DX11（自动回退）双后端。
 */

#pragma once

#include <Windows.h>
#include <string>

namespace gqol {

/// 安装 DX12 / DX11 自适应图形钩子（Present / Present1 / ResizeBuffers / ExecuteCommandLists / WndProc）。
bool InstallGraphicsHook();

/// 卸载全部钩子、等待 GPU 空闲并释放 ImGui 与 DX12/DX11 图形资源。
void UninstallGraphicsHook();

/// 线程安全查询当前 Mod 悬浮菜单是否处于打开状态。
bool IsMenuOpen();

/// 线程安全设置 Mod 悬浮菜单的显示/隐藏状态。
void SetMenuOpen(bool open);

/// 获取当前激活的图形渲染后端名称（"DX12" / "DX11" / "Unknown"）。
const char* GetActiveGraphicsBackend();

/// 获取当前挂钩的游戏主窗口句柄（用于屏幕绝对坐标到客户区坐标的兜底换算）。
HWND GetGameHwnd();

/// 线程安全写入悬浮层运行诊断日志到 data/overlay.log（printf 风格格式化）。
void OverlayLog(const char* fmt, ...);

} // namespace gqol
