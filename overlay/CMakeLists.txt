# ==============================================================================
# 文件：overlay/CMakeLists.txt
# 职责：构建 GroundedQoLOverlay.dll（DX12/DX11 双后端 Dear ImGui 中文悬浮层）
#       以及离线真实 SwapChain 自动化回归测试宿主 overlay_regression_test.exe。
# 关键构建约定：
#   - 强制 C++17 与 /utf-8 源码编码，确保中文界面文案与日志不出现代码页乱码。
#   - 静态链接 MSVC 运行时 (/MT)，使联机绿色分享包无需队友额外安装 VC++ Redistributable。
# ==============================================================================

cmake_minimum_required(VERSION 3.20)
project(GroundedQoLOverlay LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 静态链接 MSVC 运行时，便于直接分发给联机队友无需额外装 VC++ 运行库
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

# 第三方开源依赖目录（Dear ImGui / MinHook 子模块与单头文件 nlohmann/json）
set(TP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../third_party")
set(IMGUI_DIR "${TP_DIR}/imgui")
set(MINHOOK_DIR "${TP_DIR}/minhook")

# MinHook 源文件（Grounded 为 64 位进程，使用 hde64 反汇编长度解码器）
set(MINHOOK_SOURCES
    "${MINHOOK_DIR}/src/buffer.c"
    "${MINHOOK_DIR}/src/hook.c"
    "${MINHOOK_DIR}/src/trampoline.c"
    "${MINHOOK_DIR}/src/hde/hde64.c"
)

# Dear ImGui 核心与 Win32 + DX12 + DX11 双后端源文件
set(IMGUI_SOURCES
    "${IMGUI_DIR}/imgui.cpp"
    "${IMGUI_DIR}/imgui_draw.cpp"
    "${IMGUI_DIR}/imgui_tables.cpp"
    "${IMGUI_DIR}/imgui_widgets.cpp"
    "${IMGUI_DIR}/backends/imgui_impl_win32.cpp"
    "${IMGUI_DIR}/backends/imgui_impl_dx11.cpp"
    "${IMGUI_DIR}/backends/imgui_impl_dx12.cpp"
)

# 目标一：游戏内注入的悬浮菜单与 M 地图投影动态库
add_library(GroundedQoLOverlay SHARED
    src/dllmain.cpp
    src/ipc.h
    src/ipc.cpp
    src/dx11_hook.h
    src/dx11_hook.cpp
    src/overlay_ui.h
    src/overlay_ui.cpp
    ${IMGUI_SOURCES}
    ${MINHOOK_SOURCES}
)

target_include_directories(GroundedQoLOverlay PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${IMGUI_DIR}"
    "${IMGUI_DIR}/backends"
    "${MINHOOK_DIR}/include"
    "${TP_DIR}"
)

target_compile_definitions(GroundedQoLOverlay PRIVATE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    UNICODE
    _UNICODE
    IMGUI_DEFINE_MATH_OPERATORS
)

if (MSVC)
    # 强制按 UTF-8 解析源码与执行字符集，保证 Dear ImGui 简体中文文本正确显示
    target_compile_options(GroundedQoLOverlay PRIVATE /utf-8 /W3)
endif()

target_link_libraries(GroundedQoLOverlay PRIVATE
    d3d12
    d3d11
    dxgi
    user32
    gdi32
    imm32
    ole32
)

# 目标二：DX12/DX11 自动化回归测试宿主程序
# 真实创建 DX12 与 DX11 SwapChain 并加载本 DLL，验证图形挂钩、配置持久化、热键与 M 地图零误差投影
add_executable(overlay_regression_test
    tests/overlay_regression_test.cpp
)
target_compile_definitions(overlay_regression_test PRIVATE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    UNICODE
    _UNICODE
)
if (MSVC)
    target_compile_options(overlay_regression_test PRIVATE /utf-8 /W3)
endif()
target_link_libraries(overlay_regression_test PRIVATE
    d3d12
    d3d11
    dxgi
    user32
    gdi32
    imm32
    ole32
)
