<#
.SYNOPSIS
  EyeGuard (SedentaryReminder) Microsoft Store 上架打包脚本
.DESCRIPTION
  完整流程: 版本号同步 → MSBuild 编译 (x86/x64) → msixpublish 后处理 →
  makeappx pack → bundle → 产物校验。
  适用于 Microsoft Store 上传 (无需本地签名, Store 自行签名)。

  ★ Store 硬性约束: Package Identity Version 第四段必须为 0 (X.X.X.0)。
    脚本读取 VERSION 文件 (完整四段, 如 1.1.9.93), 自动派生 Store Identity = 前三段.0。
  ★ FileVersion 自动生成为 yyyy.MMdd.HHmm (编译时刻), 写入 csproj 的 FileVersion,
    同时用于 bundle 文件名和 git tag。可通过 -FileVersion 显式覆盖。

.NOTES
  依赖:
    - Visual Studio 2026 (MSBuild 18.10+)
    - .NET 8 SDK
    - Windows 10/11 SDK (makeappx.exe)
    - 路径已硬编码为本机实际位置

.PARAMETER Version
  完整应用版本号, 四段数字 (如 1.1.9.93, REVISION 可非零)。默认读取 VERSION 文件。
  Store Identity Version (前三段.0) 由脚本自动派生, 无需手动指定。
  例: -Version 1.1.9.93

.PARAMETER FileVersion
  内部版本号, 格式 yyyy.MMdd.HHmm (如 2026.0923.1530)。
  默认自动取当前本地时间生成; 显式传入则覆盖 (用于重打历史包)。
  用途: csproj FileVersion / bundle 文件名 / git tag。
  注意: Store Identity Version (第四段必须为 0) 由 VERSION 前三段派生,
        FileVersion 不影响 Store 校验。

.PARAMETER Channel
  发布渠道标识, 注入到程序集元数据, UI 显示为 "版本号-渠道" (如 1.1.9.93-dev)。
  默认 dev (本地调试)。可选值: dev / gitee / github / autoupdate / store 等。
  Store 包运行时自动识别 (WindowsApps 路径) 并强制显示纯净版本号。

.PARAMETER Clean
  编译前清理 bin/obj 目录 (解决 msixpublish 缓存旧版本号问题)。默认 $true。

.EXAMPLE
  # 最简: VERSION 文件作版本源, FileVersion 自动取当前时间, Channel=dev
  .\build_multiarch.ps1

.EXAMPLE
  # 指定 Store Identity Version (覆盖 VERSION 文件)
  .\build_multiarch.ps1 -Version 1.1.9.93

.EXAMPLE
  # 显式指定 FileVersion 和渠道 (gitee 渠道包)
  .\build_multiarch.ps1 -FileVersion 2026.0923.1530 -Channel gitee
#>

param(
    [string]$Version,
    [string]$FileVersion,
    [string]$Channel = 'dev',
    [bool]$Clean = $true
)

$ErrorActionPreference = 'Stop'

# ============================================================
# 路径配置 (本机实际位置)
# ============================================================
$root       = 'e:\zws2025\EyeGuard-master'
$wapproj    = Join-Path $root 'WapProjTemplate1\WapProjTemplate1.wapproj'
$csproj     = Join-Path $root 'SedentaryReminder\SedentaryReminder.csproj'
$srcManifest = Join-Path $root 'WapProjTemplate1\Package.appxmanifest'
$srcImages   = Join-Path $root 'WapProjTemplate1\Images'
$versionFile = Join-Path $root 'VERSION'
$buildNumFile = Join-Path $root 'BUILDNUM'
$outputRoot  = Join-Path $root 'WapProjTemplate1\AppPackages'
$logsDir     = Join-Path $root 'logs'

$msbuild  = 'F:\Visual Studio Community 2026\MSBuild\Current\Bin\MSBuild.exe'
$makeappx = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\makeappx.exe'

$platforms = @('x86', 'x64')

# ============================================================
# 辅助函数
# ============================================================
function Write-Step {
    param([string]$msg, [string]$color = 'Yellow')
    Write-Host ''
    Write-Host ('>>> ' + $msg) -ForegroundColor $color
}

function Invoke-Checked {
    param([string]$label, [scriptblock]$action)
    Write-Host ('    ' + $label) -ForegroundColor Gray
    & $action
    if ($LASTEXITCODE -ne 0) {
        throw ('[错误] ' + $label + ' 失败, 退出码 ' + $LASTEXITCODE)
    }
}

# UTF-8 读写 (PowerShell 5.1 的 Get-Content/Set-Content 对 BOM 处理不可靠, 用 .NET API 确保正确)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Read-Utf8 {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, $utf8NoBom)
}
function Write-Utf8Bom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8Bom)
}
function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# ============================================================
# 0. 前置校验
# ============================================================
if (-not (Test-Path $wapproj))    { throw '找不到 wapproj: ' + $wapproj }
if (-not (Test-Path $csproj))     { throw '找不到 csproj: ' + $csproj }
if (-not (Test-Path $msbuild))    { throw '找不到 MSBuild: ' + $msbuild }
if (-not (Test-Path $makeappx))   { throw '找不到 makeappx: ' + $makeappx }
if (-not (Test-Path $srcManifest)){ throw '找不到 Package.appxmanifest: ' + $srcManifest }
if (-not (Test-Path $srcImages))  { throw '找不到 Images 目录: ' + $srcImages }

if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
}
if (-not (Test-Path $outputRoot)) {
    New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
}

# ============================================================
# 1. 版本号处理
# ============================================================
Write-Step '1/6 版本号处理'

# 读取 VERSION 文件 = 完整四段版本号 (如 1.1.9.93, REVISION 可非零)
if (-not $Version) {
    $Version = (Read-Utf8 $versionFile).Trim()
    Write-Host ('    从 VERSION 文件读取版本: ' + $Version) -ForegroundColor Cyan
}

# 校验 VERSION 为四段数字 (REVISION 可非零, 仅 Store Identity 要求第四段为 0)
$verParts = $Version.Split('.')
if ($verParts.Count -ne 4) {
    throw ('[错误] VERSION 必须为四段数字 (如 1.1.9.93), 当前: ' + $Version)
}
foreach ($p in $verParts) {
    if (-not ($p -match '^\d+$')) {
        throw ('[错误] VERSION 各段必须为数字, 当前: ' + $Version)
    }
}

# Store Identity Version = 前三段 + ".0" (Store 硬性约束: 第四段必须为 0)
$storeVersion = $verParts[0] + '.' + $verParts[1] + '.' + $verParts[2] + '.0'

# FileVersion: 默认自动生成为 yyyy.MMdd.HHmm (编译时刻), 用于 csproj FileVersion / 文件名 / tag
if (-not $FileVersion) {
    $FileVersion = Get-Date -Format 'yyyy.MMdd.HHmm'
    Write-Host ('    自动生成 FileVersion (当前时间): ' + $FileVersion) -ForegroundColor Cyan
}

# 校验 FileVersion 格式 (三段: yyyy.MMdd.HHmm)
$fvParts = $FileVersion.Split('.')
if ($fvParts.Count -ne 3) {
    throw ('[错误] FileVersion 必须为三段格式 yyyy.MMdd.HHmm (如 2026.0923.1530), 当前: ' + $FileVersion)
}
foreach ($p in $fvParts) {
    if (-not ($p -match '^\d+$')) {
        throw ('[错误] FileVersion 各段必须为数字, 当前: ' + $FileVersion)
    }
}

# BUILDNUM: 打包次数计数, 每次打包 +1, 写入独立文件
$buildNum = 1
if (Test-Path $buildNumFile) {
    $oldNum = (Read-Utf8 $buildNumFile).Trim()
    if ($oldNum -match '^\d+$') { $buildNum = [int]$oldNum + 1 }
}
Write-Utf8Bom $buildNumFile $buildNum.ToString()

Write-Host ('    App Version      : ' + $Version) -ForegroundColor Green
Write-Host ('    Store Identity   : ' + $storeVersion) -ForegroundColor Green
Write-Host ('    File Version     : ' + $FileVersion) -ForegroundColor Green
Write-Host ('    Channel          : ' + $Channel) -ForegroundColor Green
Write-Host ('    Build Count      : ' + $buildNum) -ForegroundColor Green

# csproj 版本字段由 csproj 自身从 VERSION 文件动态读取, 这里不覆盖.
# 仅同步 Package.appxmanifest 的 Identity Version = StoreIdentityVersion (前三段.0)
$manifestContent = Read-Utf8 $srcManifest
$manifestContent = $manifestContent -replace '(<Identity[^>]*?)Version="[^"]+"', ('$1Version="' + $storeVersion + '"')
Write-Utf8Bom $srcManifest $manifestContent

Write-Host '    已同步: Package.appxmanifest Identity Version -> ' -NoNewline -ForegroundColor Green
Write-Host $storeVersion -ForegroundColor Cyan

# ============================================================
# 2. 清理 (可选)
# ============================================================
if ($Clean) {
    Write-Step '2/6 清理 bin/obj'
    Remove-Item (Join-Path $root 'SedentaryReminder\bin') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $root 'SedentaryReminder\obj') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $root 'WapProjTemplate1\bin') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $root 'WapProjTemplate1\obj') -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '    已清理' -ForegroundColor Green
}

# ============================================================
# 3. 逐架构编译 + msixpublish 后处理
# ============================================================
Write-Step '3/6 编译 + 后处理 (x86/x64)'

$stagingDir = Join-Path $env:TEMP 'EyeGuard_appx_staging'
if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null

foreach ($plat in $platforms) {
    Write-Host ''
    Write-Host ('  --- ' + $plat + ' ---') -ForegroundColor Cyan

    # 3a. restore
    $restoreLog = Join-Path $logsDir ('restore_' + $plat + '.log')
    Invoke-Checked ('dotnet restore ' + $plat) {
        & dotnet restore $csproj /p:Platform=$plat *> $restoreLog
    }

    # 3b. MSBuild 编译
    # ★ 必须 /p:PublishReadyToRun=false, 否则 CrossGen 加载 WinRT.Runtime 失败
    # ★ /p:FileVersion=yyyy.MMdd.HHmm 覆盖 csproj 的 FileVersion (保持文件名与 csproj 一致)
    # ★ /p:Channel=<channel> 注入渠道, UI 显示 "版本号-渠道"
    $buildLog = Join-Path $logsDir ('build_' + $plat + '.log')
    Invoke-Checked ('MSBuild ' + $plat) {
        & $msbuild $wapproj /t:Rebuild /p:Configuration=Release /p:Platform=$plat `
            /p:AppxBundle=Never /p:GenerateAppxPackageOnBuild=true `
            /p:PublishReadyToRun=false `
            /p:FileVersion=$FileVersion /p:Channel=$Channel `
            /verbosity:minimal *> $buildLog
    }

    # 3c. msixpublish 目录
    $pubDir = Join-Path $root ("SedentaryReminder\bin\" + $plat + "\Release\net8.0-windows10.0.26100.0\win-" + $plat + "\msixpublish")
    if (-not (Test-Path $pubDir)) {
        throw ('[错误] msixpublish 目录不存在: ' + $pubDir)
    }

    # 3c-bis. 补拷 msixpublish 缺失的 DLL (WinRT.Runtime.dll 等)
    # MSBuild GenerateAppxPackageOnBuild 不总是包含所有发布输出 DLL
    $pubParent = Split-Path $pubDir -Parent
    $copiedDll = 0
    Get-ChildItem $pubParent -Filter '*.dll' | Where-Object { $_.Name -ne 'SedentaryReminder.dll' } | ForEach-Object {
        $dest = Join-Path $pubDir $_.Name
        if (-not (Test-Path $dest)) {
            Copy-Item $_.FullName $dest -Force
            $copiedDll++
            Write-Host ('    补拷: ' + $_.Name) -ForegroundColor Yellow
        }
    }
    # 同样检查子目录 (runtimes/ 等)
    Get-ChildItem $pubParent -Directory | Where-Object { $_.Name -ne 'msixpublish' } | ForEach-Object {
        $destSub = Join-Path $pubDir $_.Name
        if (-not (Test-Path $destSub)) {
            Copy-Item $_.FullName $destSub -Recurse -Force
            Write-Host ('    补拷目录: ' + $_.Name) -ForegroundColor Yellow
        }
    }
    if ($copiedDll -gt 0) {
        Write-Host ('    补拷 ' + $copiedDll + ' 个缺失 DLL') -ForegroundColor Green
    }

    # 3d. 替换 manifest: Package.appxmanifest → AppxManifest.xml
    $destManifest = Join-Path $pubDir 'AppxManifest.xml'
    Copy-Item $srcManifest $destManifest -Force

    # 替换 token
    # ★ 桌面桥接(Desktop Bridge) WPF 应用的 EntryPoint 必须是 Windows.FullTrustApplication,
    #   不能用 UWP 式的 SedentaryReminder.App, 否则 WAM 会按 UWP 生命周期等待初始化完成,
    #   导致 60s 后触发 Application Hang / MoAppHang.
    $mContent = Read-Utf8 $destManifest
    $mContent = $mContent -replace '\$targetnametoken\$\.exe', 'SedentaryReminder.exe'
    $mContent = $mContent -replace '\$targetentrypoint\$', 'Windows.FullTrustApplication'
    # 加 ProcessorArchitecture 到 Identity
    $mContent = $mContent -replace '(<Identity[^>]*?)(/?>)', ('$1 ProcessorArchitecture="' + $plat + '"$2')
    Write-Utf8NoBom $destManifest $mContent

    # 3e. 复制 Images (含 .scale-200 → 基础名)
    $destImages = Join-Path $pubDir 'Images'
    Copy-Item $srcImages $destImages -Recurse -Force
    Get-ChildItem $destImages -Filter '*.scale-200.png' | ForEach-Object {
        $baseName = $_.Name -replace '\.scale-200\.png$', '.png'
        $basePath = Join-Path $destImages $baseName
        if (-not (Test-Path $basePath)) {
            Copy-Item $_.FullName $basePath -Force
        }
    }

    # 3f. makeappx pack
    $appxPath = Join-Path $stagingDir ('SedentaryReminder_' + $plat + '.appx')
    $packLog = Join-Path $logsDir ('makeappx_pack_' + $plat + '.log')
    Invoke-Checked ('makeappx pack ' + $plat) {
        & $makeappx pack /d $pubDir /p $appxPath /o *> $packLog
    }

    $sizeMB = [math]::Round((Get-Item $appxPath).Length / 1MB, 2)
    Write-Host ('    ' + $plat + ' appx: ' + $sizeMB + ' MB') -ForegroundColor Green
}

# ============================================================
# 4. makeappx bundle
# ============================================================
Write-Step '4/6 makeappx bundle'

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
# bundle 文件名用应用版本号 (VERSION 文件) 而非 FileVersion (编译时间戳), 例: SedentaryReminder_1.1.10.94_20260923_133934.appxbundle
$bundleName = 'SedentaryReminder_' + $Version + '_' + $timestamp + '.appxbundle'
$bundlePath = Join-Path $outputRoot $bundleName

$bundleLog = Join-Path $logsDir 'makeappx_bundle.log'
Invoke-Checked 'makeappx bundle' {
    & $makeappx bundle /d $stagingDir /p $bundlePath /o *> $bundleLog
}

Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue

$bundleMB = [math]::Round((Get-Item $bundlePath).Length / 1MB, 2)
Write-Host ('    Bundle: ' + $bundleName + ' (' + $bundleMB + ' MB)') -ForegroundColor Green

# ============================================================
# 5. 产物校验 (unbundle + unpack 检查 Version + Architecture)
# ============================================================
Write-Step '5/6 产物校验'

$verifyDir = Join-Path $env:TEMP 'EyeGuard_verify'
if (Test-Path $verifyDir) { Remove-Item $verifyDir -Recurse -Force }

& $makeappx unbundle /p $bundlePath /d $verifyDir /o *> (Join-Path $logsDir 'makeappx_unbundle.log')

$verifyOk = $true
foreach ($plat in $platforms) {
    $appx = Join-Path $verifyDir ('SedentaryReminder_' + $plat + '.appx')
    $udir = Join-Path $verifyDir ($plat + '_u')
    & $makeappx unpack /p $appx /d $udir /o *> (Join-Path $logsDir ('makeappx_unpack_' + $plat + '.log'))

    [xml]$m = Read-Utf8 (Join-Path $udir 'AppxManifest.xml')
    $actualVer = $m.Package.Identity.Version
    $actualArch = $m.Package.Identity.ProcessorArchitecture

    # 检查关键 DLL 是否在包内 (WinRT.Runtime.dll 缺失会导致 AppCenter 崩溃)
    $criticalDlls = @('WinRT.Runtime.dll', 'SedentaryReminder.dll', 'SedentaryReminder.exe')
    $missingDlls = @()
    foreach ($dll in $criticalDlls) {
        if (-not (Test-Path (Join-Path $udir $dll))) {
            $missingDlls += $dll
        }
    }

    # AppxManifest Identity Version = storeVersion (前三段.0), 不是完整四段 Version
    $ok = ($actualVer -eq $storeVersion) -and ($actualArch -eq $plat) -and ($missingDlls.Count -eq 0)
    $status = if ($ok) { 'OK' } else { 'FAIL' }
    Write-Host ('    ' + $plat + ': Version=' + $actualVer + ' Arch=' + $actualArch + ' [' + $status + ']') -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
    if ($missingDlls.Count -gt 0) {
        Write-Host ('    缺失关键文件: ' + ($missingDlls -join ', ')) -ForegroundColor Red
    }
    if (-not $ok) { $verifyOk = $false }
}

Remove-Item $verifyDir -Recurse -Force -ErrorAction SilentlyContinue

if (-not $verifyOk) {
    throw '[错误] 产物校验失败, 请检查日志'
}

# ============================================================
# 6. 完成
# ============================================================
Write-Step '6/6 完成' 'Green'
Write-Host ''
Write-Host '========================================' -ForegroundColor Green
Write-Host '  打包成功!' -ForegroundColor Green
Write-Host ('  产物: ' + $bundlePath) -ForegroundColor Green
Write-Host ('  App Version     : ' + $Version) -ForegroundColor Green
Write-Host ('  Store Identity  : ' + $storeVersion + ' (合规, 第四段=0)') -ForegroundColor Green
Write-Host ('  File Version    : ' + $FileVersion) -ForegroundColor Green
Write-Host ('  Channel         : ' + $Channel) -ForegroundColor Green
Write-Host ('  Build Count     : ' + $buildNum) -ForegroundColor Green
Write-Host '  上传到 Partner Center 即可' -ForegroundColor Green
Write-Host '========================================' -ForegroundColor Green
