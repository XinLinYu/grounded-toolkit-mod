# ==============================================================================
# 文件：deploy.ps1
# 职责：GroundedQoL 一键编译 Release x64 悬浮菜单 DLL、部署到本机 Steam 游戏目录，
#       并打包可直接分发给联机队友的绿色安装包（dist/GroundedQoL_Steam_v1.4.7.zip）。
# 使用示例：
#   powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -GameDir "G:\SteamLibrary\steamapps\common\Grounded"
# ==============================================================================
param(
    [string]$GameDir = 'G:\SteamLibrary\steamapps\common\Grounded'
)

$ErrorActionPreference = 'Stop'

# 计算仓库根目录与目标游戏 UE4SS Mod 部署路径
$projRoot = $PSScriptRoot
$win64Dir = Join-Path $GameDir 'Maine\Binaries\Win64'
$ue4ssDir = Join-Path $win64Dir 'ue4ss'
$modDest  = Join-Path $ue4ssDir 'Mods\GroundedQoL'

# 0. 自动探测本机 CMake（按 PATH -> vswhere 定位 VS 内置 CMake -> 兜底路径顺序查找）
$cmake = (Get-Command cmake -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
if (-not $cmake) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsInst = & $vswhere -latest -products * -property installationPath
        if ($vsInst) {
            $cand = Join-Path $vsInst 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
            if (Test-Path $cand) { $cmake = $cand }
        }
    }
}
if (-not $cmake) {
    $fallback = 'F:\Program Files\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    if (Test-Path $fallback) { $cmake = $fallback }
}
if (-not $cmake) {
    Write-Error '未找到 cmake.exe，请安装 CMake 或 Visual Studio C++ 构建工具。'
    exit 1
}

# 1. 安全拦截：若游戏进程正在运行，DLL 文件会被锁定导致覆写失败
$proc = Get-Process -Name 'Maine-Win64-Shipping','Grounded' -ErrorAction SilentlyContinue
if ($proc) {
    Write-Error "检测到《Grounded》正在运行 (PID: $($proc.Id -join ', '))，请先关闭游戏再部署！"
    exit 1
}

# 2. 编译 DX12 / DX11 中文悬浮菜单 DLL（Release x64，静态链接 /MT）
Write-Output '=== [1/4] 编译 GroundedQoLOverlay.dll (Release x64) ==='
$overlaySrc = Join-Path $projRoot 'overlay'
$overlayBld = Join-Path $overlaySrc 'build'
if (-not (Test-Path (Join-Path $overlayBld 'CMakeCache.txt'))) {
    & $cmake -S $overlaySrc -B $overlayBld -A x64
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
& $cmake --build $overlayBld --config Release --parallel
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$dllFile = Join-Path $overlayBld 'Release\GroundedQoLOverlay.dll'
if (-not (Test-Path $dllFile)) {
    Write-Error "未找到编译产物: $dllFile"
    exit 1
}

# 3. 部署 Lua 脚本与编译后的悬浮层 DLL 到本机游戏目录（保留已有 data/config.json 用户配置）
Write-Output "=== [2/4] 部署 GroundedQoL 到 $modDest ==="
New-Item -ItemType Directory -Force -Path (Join-Path $modDest 'Scripts') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $modDest 'data') | Out-Null

Copy-Item -Path (Join-Path $projRoot 'lua\GroundedQoL\Scripts\*') -Destination (Join-Path $modDest 'Scripts') -Force
Copy-Item -Path $dllFile -Destination (Join-Path $modDest 'GroundedQoLOverlay.dll') -Force

# 4. 更新 UE4SS mods.txt（禁用临时 SDK 探测脚本，仅启用 GroundedQoL 与内置 Keybinds）
Write-Output '=== [3/4] 更新 UE4SS mods.txt ==='
$modsTxt = @"
CheatManagerEnablerMod : 0
ConsoleCommandsMod : 0
ConsoleEnablerMod : 0
SplitScreenMod : 0
LineTraceMod : 0
BPML_GenericFunctions : 0
BPModLoaderMod : 0
GroundedSDKProbe : 0
GroundedQoL : 1

; Built-in keybinds, do not move up!
Keybinds : 1
"@
Set-Content -Path (Join-Path $ue4ssDir 'Mods\mods.txt') -Value $modsTxt -Encoding UTF8

# 5. 生成联机队友一键绿色分享包（整合 dwmapi.dll + UE4SS 核心 + GroundedQoL，不含本机个人配置）
Write-Output '=== [4/4] 生成联机队友分享绿色包 ==='
$distDir = Join-Path $projRoot 'dist'
$stageDir = Join-Path $distDir 'GroundedQoL_Package'
$zipPath = Join-Path $distDir 'GroundedQoL_Steam_v1.4.7.zip'
if (Test-Path $stageDir) { Remove-Item -Recurse -Force $stageDir }
New-Item -ItemType Directory -Force -Path (Join-Path $stageDir 'ue4ss\Mods\GroundedQoL\Scripts') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stageDir 'ue4ss\Mods\GroundedQoL\data') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stageDir 'ue4ss\Mods\shared') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stageDir 'ue4ss\Mods\Keybinds') | Out-Null

Copy-Item (Join-Path $win64Dir 'dwmapi.dll') (Join-Path $stageDir 'dwmapi.dll') -Force
foreach ($f in @('UE4SS.dll','UE4SS-settings.ini','MemberVariableLayout.ini','VTableLayout.ini','LICENSE')) {
    Copy-Item (Join-Path $ue4ssDir $f) (Join-Path $stageDir "ue4ss\$f") -Force
}
Copy-Item (Join-Path $ue4ssDir 'Mods\mods.txt') (Join-Path $stageDir 'ue4ss\Mods\mods.txt') -Force
Copy-Item (Join-Path $ue4ssDir 'Mods\shared\*') (Join-Path $stageDir 'ue4ss\Mods\shared') -Recurse -Force
Copy-Item (Join-Path $ue4ssDir 'Mods\Keybinds\*') (Join-Path $stageDir 'ue4ss\Mods\Keybinds') -Recurse -Force
Copy-Item (Join-Path $modDest 'Scripts\*') (Join-Path $stageDir 'ue4ss\Mods\GroundedQoL\Scripts') -Force
Copy-Item (Join-Path $modDest 'GroundedQoLOverlay.dll') (Join-Path $stageDir 'ue4ss\Mods\GroundedQoL\GroundedQoLOverlay.dll') -Force

# 生成随包附带的中文安装与联机快速说明
$readme = @"
《禁闭求生 (Grounded)》体验增强工具箱 (GroundedQoL) 安装说明
============================================================

1. 解压本压缩包内全部文件（dwmapi.dll 和 ue4ss 文件夹）到你的 Steam 游戏目录：
   ...\steamapps\common\Grounded\Maine\Binaries\Win64\
   （与 Maine-Win64-Shipping.exe 放在同一目录）

2. 正常从 Steam 启动游戏即可。
   - 按 Insert 或 F8 打开 / 关闭中文 Mod 菜单
   - 菜单第一页支持调节堆叠/伤害/采集倍率、无材料建造与制作，以及死亡背包保留、免除死亡耐久惩罚与一键找回掉落背包
   - 按 M 打开游戏大地图自动显示乳牙、高级乳牙和追踪资源
   - 悬停 M 地图标点后按 G 键或 Ctrl+左键，放置原版路标

3. 联机提示：
   - 房主设置伤害倍率、采集倍率、无材料秒建、死亡背包保留、免除死亡耐久惩罚、一键找回全队背包、原版路标与原版扫描热区时全队生效。
   - 队友安装本包后，可与房主同步享受大堆叠背包/箱子整理、免费制作与大地图实时标点，且不影响 Steam 成就。

4. 卸载方法：删除 Win64 目录下的 dwmapi.dll 与 ue4ss 文件夹即可完全还原。
"@
Set-Content -Path (Join-Path $stageDir '安装说明.txt') -Value $readme -Encoding UTF8

# 打包为 zip 并清理临时暂存目录
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $zipPath -Force
Remove-Item -Recurse -Force $stageDir

Write-Output "部署完成！"
Write-Output "  游戏内 Mod 目录: $modDest"
Write-Output "  联机分享绿色包 : $zipPath ($([math]::Round((Get-Item $zipPath).Length / 1MB, 2)) MB)"
