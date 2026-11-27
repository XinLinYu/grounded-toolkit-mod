cmake_minimum_required(VERSION 3.20)
project(GroundedQoLOverlay LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 静态链接 MSVC 运行时，便于直接分发给联机队友无需额外装 VC++ 运行库
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

set(TP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../third_party")
set(IMGUI_DIR "${TP_DIR}/imgui")
set(MINHOOK_DIR "${TP_DIR}/minhook")

# MinHook 源文件（x64 架构使用 hde64）
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
    target_compile_options(GroundedQoLOverlay PRIVATE /utf-8 /W3)
endif()

target_link_libraries(GroundedQoLOverlay PRIVATE
    d3d12
    d3d11
    dxgi
    user32
    gdi32
)

# DX12/DX11 自动化回归测试宿主程序（真实创建 DX12 与 DX11 SwapChain 并加载本 DLL 验证渲染与快捷键）
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
)
