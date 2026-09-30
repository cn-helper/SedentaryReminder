# EyeGuard / SedentaryReminder 项目修改记录

本文档记录项目（打包、上架、版本管理、配置等）开发过程中遇到的问题、根因、修改方案。
**目的**：让任何 AI 模型（无论高低端）或新成员都能快速复用经验，避免重复踩坑。

---

## 目录

1. [打包上架 (Microsoft Store / .appxbundle)](#1-打包上架-microsoft-store--appxbundle)
2. [版本号管理](#2-版本号管理)
3. [构建编译 (MSBuild / .NET SDK)](#3-构建编译-msbuild--net-sdk)
4. [项目配置 (csproj / wapproj / manifest)](#4-项目配置-csproj--wapproj--manifest)
5. [依赖与三方库](#5-依赖与三方库)
6. [国际化 / 多语言](#6-国际化--多语言)
7. [设备系列与上架可见性](#7-设备系列与上架可见性)
8. [Store 健康报告与故障分析](#8-store-健康报告与故障分析)
9. [下个工作规划](#9-下个工作规划)
10. [历史变更记录](#10-历史变更记录)

---

## 1. 打包上架 (Microsoft Store / .appxbundle)

### 1.1 [2026-09-21] Store 拒绝 Package Version 第四段非零

- **现象**: 上传 `.appxbundle` 后 Partner Center 报错:
  > `Apps are not allowed to have a Version with a revision number other than zero specified in the app manifest. The package SedentaryReminder_x86.appx specifies 1.1.8.92.`
- **根因**: Microsoft Store **硬性约束**: Package Identity Version 的第四段 (Revision) 必须为 0。即格式必须为 `X.X.X.0`。
- **修改**: 三处版本字段全部统一为 `1.1.8.0`:
  - `WapProjTemplate1/Package.appxmanifest` 的 `<Identity Version="...">`
  - `SedentaryReminder/SedentaryReminder.csproj` 的 `AssemblyVersion / Version / FileVersion / AssemblyInformationalVersion`
  - `VERSION` 文件
- **坑点**:
  - 文件名（如 `_1.1.8.92_20260921_230743.appxbundle`）可以保留全四段——Store 只解析 Package 内部 manifest，不读文件名。
  - csproj 注释里已写明约束，给以后所有自动化脚本/AI 参考。
  - **不要用 `1.1.8.92`、`1.1.8.1`、`2.0.0.5` 等任何非零第四段**。

### 1.2 [2026-09-21] 必须取消勾选 Mobile/Xbox/Mixed Reality 设备系列

- **现象**: Partner Center 报错:
  > `You must provide a package that supports each selected device family (or uncheck the box for unsupported device families)`
- **根因**: 项目只打 x86 + x64 包，没有 ARM64/中性资源包。勾选了 Mobile/Xbox/Mixed Reality 后，这些设备系列找不到对应架构的包。
- **修改**: 在 Partner Center 后台 **Device family availability** 里:
  - 取消勾选: Windows 10/11 Mobile / Windows 10 Mobile / Windows 10 Xbox / Windows 10 Mixed Reality
  - 只保留: **Windows 10/11 Desktop**
- **坑点**:
  - 这跟 manifest 里的 `<TargetDeviceFamily>` 是两回事。manifest 声明的是"应用支持的最低系统"，后台勾选决定"上架可见性"。
  - 久坐提醒本来就是桌面应用，没必要支持其他设备系列。

### 1.3 [2026-09-21] Language="x-generate" 被 Store 拒绝

- **现象**: Partner Center 报错:
  > `The package ... specifies an unsupported default language: x-generate`
- **根因**: `Package.appxmanifest` 里 `<Resources><Resource Language="x-generate"/></Resources>` 是开发占位值，Store 不接受。
- **修改**: 改成 `<Resource Language="zh-CN"/>`。
- **坑点**:
  - 不能加 `<DefaultLanguage>` 到 `<Properties>` 下——makeappx 的 schema 不允许，会报 C00CE014。
  - 必须改三处: `WapProjTemplate1/Package.appxmanifest`、`SedentaryReminder/Appx.xml`、msixpublish 里的 AppxManifest.xml。

### 1.4 [2026-09-21] Package full name 冲突 (历史包重复)

- **现象**: Partner Center 报错:
  > `Package full name in conflict: zws.3486119DFBD35_1.0.90.0_x86__...`
- **根因**: 重复上传了 Identity Version 相同的包。Partner Center 不接受 full name 重复。
- **修改**: 每次发布必须递增 Identity Version (Major/Minor/Patch 任一)，不能原地重发。
- **坑点**:
  - Store 上的 full name 是 `<Name>_<Version>_<Architecture>__<PublisherHash>`，Version 必须不同才能上传成功。
  - **VERSION 文件和 manifest 必须先改 Version，再打包上传**。

### 1.5 [2026-09-21] wapproj Build 不会自动产出 .appx

- **现象**: `msbuild WapProjTemplate1.wapproj /t:Build` 成功，但 `WapProjTemplate1\bin\x86\Release` 下没有 `.appx`，只有 dll。
- **根因**: VS 2026 的 `Microsoft.AppxPackage.Targets` 在 wapproj 的 Build 链里没被自动触发，Build → CoreBuild → PrepareForRun 链不包含 `_GenerateAppxPackage`。
- **当前绕过方案**: build 脚本跑 MSBuild 拿到 `bin\<plat>\Release\net8.0-windows10.0.26100.0\win-<plat>\msixpublish\` 输出，**手动用 makeappx pack 产生 .appx**。
- **坑点**:
  - msixpublish 里**没有 Images 目录**，必须从 `WapProjTemplate1\Images\` 复制。
  - msixpublish 里只有 `.scale-200.png`，Store manifest 需要的是基础名 PNG（如 `Square150x150Logo.png`）。必须把 .scale-200.png 复制一份为基础名。
  - msixpublish 里 `Appx.xml` 是占位 manifest (`Contoso.AssetTracker`)，必须替换成真正的 `AppxManifest.xml`。
  - manifest 里的 `$targetnametoken$.exe` / `$targetentrypoint$` 必须替换成实际值（`SedentaryReminder.exe` / `SedentaryReminder.App`）。

### 1.6 [2026-09-21] bundle 报中性包冲突

- **现象**: `makeappx bundle` 报:
  > `The package with file name "SedentaryReminder_x64.appx" ... targets the same device family. Bundles can't contain multiple neutral app packages with the same target device family value.`
- **根因**: 两个 appx 的 Identity 都没有 ProcessorArchitecture，被认为都是中性包，冲突。
- **修改**: 给两个 appx 的 `<Identity>` 加 `ProcessorArchitecture="x86"` / `"x64"`。
- **坑点**: 这个属性必须加在 `<Identity>` 里，不能加在 `<Application>` 里（schema 不允许，会报 C00CE015）。

### 1.7 [2026-09-21] MakeAppx.exe 找不到 manifest 声明的图片/可执行文件

- **现象**: makeappx pack 报:
  > `Manifest validation error: ... file name "Images\StoreLogo.png" ... doesn't exist in the package`
- **根因**: msixpublish 缺少 manifest 引用的资源文件。
- **修改**: 手动复制完整 `Images\` 目录（含基础名和 .scale-200 版本）到 msixpublish。
- **坑点**: 复制了 .scale-200.png 后还要再复制一份为基础名（`Square150x150Logo.png` 等）。

### 1.8 [2026-09-21] 打包文件名加时间戳
- **现象**: 多次重打包文件名冲突，不知道哪个是最新。
- **修改**: bundle 文件名格式 `SedentaryReminder_<Version>_<yyyyMMdd>_<HHmmss>.appxbundle`。
- **坑点**:
  - PowerShell: `Get-Date -Format 'yyyyMMdd_HHmmss'`
  - 时间戳只用于文件名，不影响 Package Identity Version（Store 解析的是 manifest，不是文件名）。
  - 旧包不要直接删，加时间戳后会自动区分。

### 1.9 [2026-09-23] 固化 Store 打包流程 (build_multiarch.ps1 自动化)

- **背景**: 之前 Store 打包需要手动执行 4 步 (MSBuild → msixpublish 后处理 → makeappx pack → bundle)，版本号要手动改三处 (VERSION / Package.appxmanifest / csproj)，容易遗漏出错。
- **方案**: 重写 `build_multiarch.ps1`，一键完成全流程。
- **脚本完整流程**:
  1. **版本号处理**: 读取 `VERSION` 文件作为 Store Identity Version，校验第四段必须为 0；`-FileVersion` 必填 (内部 REVISION 号，仅用于文件名/tag)。
  2. **同步版本**: 自动写入 csproj 的 `AssemblyVersion/Version/FileVersion/AssemblyInformationalVersion` 和 `Package.appxmanifest` 的 `<Identity Version>`。
  3. **清理**: 可选清理 bin/obj (默认开启，解决 msixpublish 缓存旧版本号问题)。
  4. **逐架构编译**: x86 + x64，先 `dotnet restore` 再 MSBuild (`/p:PublishReadyToRun=false` 解决 CrossGen 加载 WinRT.Runtime 失败)。
  5. **msixpublish 后处理**:
     - 复制 `Package.appxmanifest` → `AppxManifest.xml`
     - 替换 token: `$targetnametoken$.exe` → `SedentaryReminder.exe`，`$targetentrypoint$` → `SedentaryReminder.App`
     - 注入 `ProcessorArchitecture="x86"/"x64"` 到 `<Identity>`
     - 复制 `Images/` 目录，`.scale-200.png` 另存为基础名
  6. **makeappx pack**: 每架构单独打包为 `.appx`。
  7. **makeappx bundle**: 合并为 `.appxbundle`，文件名带时间戳。
  8. **产物校验**: unbundle + unpack 检查 `Identity Version` 和 `ProcessorArchitecture` 是否正确。
- **关键参数**:
  - `-Version`: Store Identity Version (X.X.X.0)，默认读 VERSION 文件
  - `-FileVersion`: 内部版本号 (如 1.1.9.93)，**必填**，用于 bundle 文件名和 git tag
  - `-Clean`: 是否清理 bin/obj，默认 `$true`
- **使用示例**:
  ```powershell
  # 最简 (读 VERSION 文件)
  .\build_multiarch.ps1 -FileVersion 1.1.9.93

  # 指定 Identity Version
  .\build_multiarch.ps1 -Version 1.1.10.0 -FileVersion 1.1.10.94
  ```
- **编码注意事项**:
  - csproj / Package.appxmanifest / VERSION 用 **UTF-8 with BOM** 保存 (避免 MSBuild 解析中文乱码)
  - AppxManifest.xml (msixpublish 内) 用 **UTF-8 without BOM** 保存 (makeappx 不接受 BOM)
  - PowerShell 5.1 的 `Get-Content/Set-Content` 对 BOM 处理不可靠，脚本统一用 `[System.IO.File]::ReadAllText/WriteAllText` + 显式 Encoding
- **坑点**:
  - `PublishReadyToRun=true` 会导致 CrossGen 加载 WinRT.Runtime 失败，必须传 `/p:PublishReadyToRun=false`
  - `<Identity>` 的 Version 替换正则必须限定为 `(<Identity[^>]*?)Version="[^"]+"`，不能用全局 `Version="..."` 否则会误伤 XML 声明
  - `makeappx` 要求 AppxManifest.xml **不能有 BOM**，但 csproj/manifest 源文件**必须有 BOM** (中文注释需要)
  - 日志统一输出到 `logs/` 目录，`.gitignore` 已配置 `logs/*.log` 但保留 `logs/.gitkeep`

### 1.10 [2026-09-23] EntryPoint 错误导致 MSIX 激活 60s 后 Application Hang

- **现象**: 打包安装后启动，主窗口迟迟不出现，约 60s 后应用被系统终止。事件查看器报:
  > `Application Hang / Event ID 1002` (MoAppHang 或 WAM 超时)
- **根因**: `build_multiarch.ps1` 后处理把 `AppxManifest.xml` 的 `EntryPoint` 错误地替换成了 UWP 式的 `SedentaryReminder.App`。
  - WPF + MSIX **桌面桥接 (Desktop Bridge)** 应用的正确 `EntryPoint` 必须是 `Windows.FullTrustApplication`。
  - 使用 `SedentaryReminder.App` 时，Windows Activation Manager (WAM) 会按 UWP 生命周期等待该 EntryPoint 完成初始化；但 WPF 不会调用 UWP 初始化完成信号，于是 60s 后触发 Application Hang。
- **修改**: `build_multiarch.ps1` 中 `$targetentrypoint$` 替换为 `Windows.FullTrustApplication`:
  ```powershell
  $mContent = $mContent -replace '\$targetentrypoint\$', 'Windows.FullTrustApplication'
  ```
- **验证**:
  - 1.1.10.103 手动修改已生成 manifest 后，运行 70s+ 未出现 Hang。
  - 1.1.10.104 重新打包后本地测试 75s+ 正常，`Application Hang` 事件未再出现。
- **坑点**:
  - 这个 token 以前常被误写成 `.App` 类名，**桌面桥 WPF 必须写死 `Windows.FullTrustApplication`**。
  - 诊断时容易误以为是 SplashScreen 或 WPF 首帧问题，需要用事件查看器区分 Hang 来源。

### 1.11 [2026-09-23] SplashScreen 图片尺寸不合法导致 1.1.10.102 完全无法启动

- **现象**: 1.1.10.102 打包后点击启动，应用直接失败，无任何主窗口。事件日志出现:
  > `.NET Runtime 1023: Failed to resolve full path of the current executable`
- **根因**: `Package.appxmanifest` 中添加了 `<uap:SplashScreen Image="Images\Square44x44Logo.png" ... />`。
  - MSIX `SplashScreen` 图片在 100% scale 下**必须**是 **620x300** 像素。
  - 44x44 的图标不满足要求，导致 MSIX 激活阶段直接失败，WAM 无法进入应用主流程。
- **修改**:
  1. 移除 `Package.appxmanifest` 中的 `<uap:SplashScreen>` 元素。
  2. 为避开 MSIX 默认的 60s Extended Splash，将 `MainWindow` 背景从完全透明 `Transparent` 改为几乎透明的 `#01000000` (Alpha=1)，让 WAM 能识别到首帧:
     ```xml
     AllowsTransparency="True"
     Background="#01000000"
     ```
- **验证**: 1.1.10.103 / 1.1.10.104 打包后启动正常，不再报 SplashScreen 相关激活失败。
- **坑点**:
  - 不能把现有 44x44 / 150x150 图标临时改个名字当 SplashScreen 用，尺寸不合规会当场失败。
  - 去掉 SplashScreen 后，如果主窗口 `Background="Transparent"` 且 `AllowsTransparency="True"`，WAM 可能看不到首帧而再次触发 60s Extended Splash；保留 Alpha=1 是稳妥折中。

---

## 2. 版本号管理

### 2.1 [2026-09-21] 三处版本必须一致

- **现象**: Store 上传冲突、csproj 显示版本和 manifest 版本不一致。
- **根因**: VERSION 文件、Package.appxmanifest、SedentaryReminder.csproj 三处版本字段没有同步管理。
- **修改方案**: 三处统一为同一版本号，且遵循 Store 约束（第四段为 0）:
  | 文件 | 字段 |
  |------|------|
  | `VERSION` | 单值 |
  | `WapProjTemplate1/Package.appxmanifest` | `<Identity Version="...">` |
  | `SedentaryReminder/SedentaryReminder.csproj` | `AssemblyVersion` / `Version` / `FileVersion` / `AssemblyInformationalVersion` |
- **坑点**:
  - 三处必须同步改，build 脚本要自动化（手动改极易遗漏）。
  - **`FileVersion` 也接受 4 段式版本，但 Store 只看 Identity Version**。

### 2.2 [2026-09-21] Store 硬性约束: Package Version 第四段必须为 0

- **根因**: Microsoft Store 政策。
- **约束**: Identity Version 必须是 `X.X.X.0` 形式。
- **验证**: 上传时 Partner Center 会自动检查。
- **本项目当前约定**: `1.1.8.0`（而不是 `1.1.8.92`），`.92` 这种迭代编号仅用于内部文件名。

### 2.3 [2026-09-27] VERSION 文件第四段 (REVISION) 必须保留

- **规则**: `VERSION` 文件**必须始终为四段式** `MAJOR.MINOR.PATCH.REVISION`，即使 Store Identity Version 只用前三段 + `.0`。
- **原因**:
  - REVISION 是内部版本追踪号，用于 bundle 文件名、git tag、UI 显示版本号区分不同构建。
  - `build_multiarch.ps1` 从 VERSION 取前三段派生 Store Identity（第四段强制为 0），REVISION 不影响 Store 校验，但参与产物命名和版本识别。
  - 若 REVISION 写 0，会导致同一 PATCH 下多个构建无法通过版本号区分（文件名、UI 显示都一样），测试/排查时无法分辨。
- **约定**:
  - VERSION 文件格式: `MAJOR.MINOR.PATCH.REVISION`（REVISION 一般为非零递增数字）。
  - Store Identity = `MAJOR.MINOR.PATCH.0`（由脚本自动派生，不要手动改第四段为 0 写到 VERSION 文件）。
  - 例: VERSION = `1.1.12.96` → Store Identity = `1.1.12.0`，bundle 文件名 = `SedentaryReminder_1.1.12.96_<timestamp>.appxbundle`。
- **开发调试 vs 正式包区分（通过第四段 REVISION 是否为 0）**:
  | 类型 | VERSION 示例 | REVISION | Store Identity | 说明 |
  |------|-------------|----------|----------------|------|
  | 开发调试包 | `1.1.12.0` | **0** | `1.1.12.0` | 本地 dev 构建，REVISION=0 表示开发调试版 |
  | 正式发布包 | `1.1.12.96` | **非 0** | `1.1.12.0` | 上架 Store 的正式包，REVISION 必须非 0 |
  - **核心规则**: 正式包的 REVISION 不能为 0，否则与开发调试包混淆，无法区分；开发调试包 REVISION 可以为 0。
  - 测试/排查时看 UI 显示的版本号：`1.1.12.0` = 开发调试版，`1.1.12.96` = 正式版。
- **坑点**:
  - 不要为了"Store 第四段必须为 0"就把 VERSION 文件的第四段也写成 0——Store Identity 由脚本自动派生，VERSION 的第四段是 REVISION 追踪号，两者职责不同。
  - 每次正式发布递增 PATCH（第三段），REVISION 可保留或重置；每次内部/测试构建递增 REVISION（第四段）。
  - **正式包 REVISION 必须非 0**，否则版本号和开发调试包一样，测试人员无法区分自己装的是哪个包。

---

## 3. 构建编译 (MSBuild / .NET SDK)

### 3.1 [2026-09-21] 找不到 obj/project.assets.json (NETSDK1004)

- **现象**: 第一次构建某个平台时报错:
  > `error NETSDK1004: 找不到资产文件 "...\obj\project.assets.json"`
- **根因**: 清理 `obj\` 后没重新 restore NuGet。
- **修改**: 每次清理 obj 后，必须先 `dotnet restore SedentaryReminder.csproj /p:Platform=<plat>`。
- **坑点**: x86 和 x64 要分别 restore 一次。Restore 是幂等的，已有的会跳过。

### 3.2 [2026-09-21] msbuild 重复导入 targets 警告 (MSB4011)

- **现象**: 构建日志有警告:
  > `MSB4011: 无法再次导入 "Microsoft.AppXPackage.Targets"...可能已在 wapproj (73,3) 处导入过它。`
- **根因**: VS 2026 的 wapproj 默认会导入一次 DesktopBridge.targets，但 targets 内部又自动 import Microsoft.AppxPackage.Targets。手动再 import 就重复了。
- **当前状态**: wapproj 已经手动 import 了一次（带守卫属性 `_EyeGuardAppxPackageTargetsImported`），所以这次警告是 VS 自己二次导入导致的。无害。
- **坑点**: 不要再去 wapproj 里加/删 `<Import>`，除非准备大改 targets 链。

### 3.3 [2026-09-21] MSBuild 进程残留导致 build 失败

- **现象**: 多次重试 build 时偶发失败、文件锁错误。
- **修改**: build 前先 `Get-Process msbuild,dotnet | Stop-Process -Force`。
- **坑点**: PowerShell 7/5 行为略有不同。Windows PowerShell 推荐用 `taskkill /F /IM msbuild.exe /T`。

---

## 4. 项目配置 (csproj / wapproj / manifest)

### 4.1 [2026-09-21] CommunityToolkit.Mvvm 包必须显式引用

- **现象**: 编译报错 CS0246 找不到 `[ObservableProperty]` / `[RelayCommand]`。
- **根因**: MVVM 重构后源码用了源生成器，但 csproj 没加 PackageReference。
- **修改**: csproj 添加:
  ```xml
  <PackageReference Include="CommunityToolkit.Mvvm" Version="8.3.2" />
  ```
- **坑点**: 这是源码必需的，不是可选优化。

### 4.2 [2026-09-21] wapproj 的 csproj 引用必须保留

- **现象**: 如果误删 `<ProjectReference Include="..\SedentaryReminder\SedentaryReminder.csproj" />`，wapproj 编译找不到入口。
- **约束**: 这条引用必须保留，否则 `EntryPointProjectUniqueName` 失效。

---

## 5. 依赖与三方库

### 5.1 [2026-09-21] NuGet 还原后必须确认 .NET SDK 版本

- **当前**: 项目用 .NET 8 SDK (`net8.0-windows10.0.26100.0`)。
- **坑点**: 本机同时装了 .NET 10 SDK (`C:\Program Files\dotnet\sdk\10.0.401`)。MSBuild 18.10.135+ 会优先用最新 SDK，但 csproj 锁定了 net8.0，应该不会冲突。

---

## 6. 国际化 / 多语言

### 6.1 [2026-09-21] Store Language 必须是 BCP-47 代码

- **当前**: `zh-CN`
- **坑点**: 不要用 `x-generate`、`default`、`zh` 这些非标准值。

---

## 7. 设备系列与上架可见性

### 7.1 [2026-09-21] 当前上架范围

- **当前**: Windows 10/11 Desktop
- **未上架**: Mobile / Xbox / Mixed Reality
- **原因**: 项目只打 x86 + x64 包，没有 ARM64。

---

## 8. Store 健康报告与故障分析

### 8.1 [2026-09-24] 48h 故障概览（1.1.8.0 ~ 1.1.10.0）

- **数据来源**: Microsoft Partner Center → Insights → Failures（48小时窗口）
- **总故障命中**: 650（崩溃 343 + 卡死 306 + 内存 1）

**故障类型分布**:

| 故障签名 | 命中 | 占比 | 说明 |
|---|---|---|---|
| `moapplication_hang_cffffff_...hang_activation` | 280 | 42.88% | App 激活时挂起（WPF + MSIX 经典问题） |
| `gdiobjectleak_dc_...wpfgfx_cor3.dll` | 2 | 0.31% | GDI 对象泄漏（WPF 渲染 DC） |
| `gdiobjectleak_surf_...cd3dswapchainwithswdc::init` | 1 | 0.15% | D3D 交换链初始化泄漏 |
| `clr_exception_80131509_...unknown_function` | 2 | 0.31% | .NET CLR 通用异常 |
| `bitness_mismatch_x86_clr_exception` | 2 | 0.31% | x86 位数不匹配 |
| Uncategorized | 366 | 56.05% | 未分类 |

**按版本分布**:

| Package version | Hits | 说明 |
|---|---|---|
| 1.1.8.0 | 280 | 全部是 hang_activation，该版本引入激活卡死 |
| 1.1.9.0 | 258 | hang_activation 已修复，但引入新故障 |
| 1.1.7.0 | 75 | 旧版本残留 |
| 1.1.10.0 | 26 | 大幅下降，仍有少量残留 |
| 1.0.83.0 | 12 | 很旧版本 |
| 1.1.9.70 | 2 | 中间版本 |

### 8.2 [2026-09-24] 排查结论：LockScreen 激活路径无明显同步 IO

排查范围：`SedentaryReminder/UI/LockScreen.xaml.cs`、`BLL/LockScreenManager.cs`、`SedentaryReminder.xaml.cs`

- **窗口激活路径**（构造函数 / `Window_Loaded` / `Show()`）：仅做 UI 属性设置、资源读取、屏幕定位，**未发现同步文件/网络/数据库 IO**。
- **锁屏倒计时主循环**（`LockScreen.xaml.cs` L283-L320）：每秒调用 `Bll.GetLastInputTime()` 判断用户活动。若该方法内部有系统调用阻塞，是锁屏窗口内最接近"影响 UI 响应"的周期性逻辑。
- **锁屏弹出路径**（`SedentaryReminder.xaml.cs` L610-L627）：停止音频 → 设 `md.State=1` → `new LockScreen()` → `Show()`，无同步 IO。
- **多屏锁屏**：主屏 + 副屏同时 `Show()`，多窗口同时创建可能造成 UI 线程瞬时压力。

**初步判断**：`hang_activation` 不完全是同步 IO 导致，更可能是 WPF 多窗口激活渲染阻塞或 `GetLastInputTime()` 系统调用。需等待 1.1.10.94 上架后的新数据再定位。

---

## 9. 下个工作规划

### 9.1 [2026-09-24] 待 1.1.10.94 上架反馈后

1. **监控 1.1.10.0 的 26 次残留故障**：提取未分类 crash dump，确认是否仍是 hang_activation 或新类型。
2. **如果 hang_activation 仍存在**：
   - 审计 `Bll.GetLastInputTime()` 实现，确认是否有阻塞式系统调用
   - 将锁屏窗口内的周期性检测（鼠标/键盘活动检测）移到后台 Task，结果通过 Dispatcher 回传 UI
   - 多屏锁屏窗口改为错峰 Show（主屏先 Show，副屏延迟 100-200ms），降低 UI 线程瞬时压力
3. **GDI 泄漏排查**（低优先级，仅 3 次）：
   - 长时间运行测试（>4小时），任务管理器监控 GDI 句柄数趋势
   - 检查锁屏窗口的 DrawingContext / Bitmap / Brush 是否显式 Dispose
4. **bitness_mismatch_x86**（低优先级，仅 2 次）：
   - 确认 x86 包在 x64 系统上的运行时初始化是否有问题
5. **版本策略评估**：
   - 1.1.8.0 → 1.1.9.0 的迭代显示"修一个引入一个"的模式，后续需加强回归测试
   - 考虑用 Store 包航班（Package Flights）做小范围灰度验证

### 9.2 [2026-09-24] 图表化功能（参考 Catrace）

**目标**：参考 Catrace（https://lanxiuyuno.github.io/Catrace/）实现久坐数据统计图表。

**设计参考**（Catrace 实际界面）：
- 左侧导航：概览 / 设置 / 调试
- 今日统计：4 个卡片（活跃时长、休息时长、活跃占比、活跃时段数）
- 今日活动：左侧"进行中"活动时段 + 右侧 24 小时分布条形图
- 配色：紫色=#7C3AED（活跃）、绿色=#10B981（休息）

**数据方案**：
- 每分钟采样一次用户状态：0=活跃（1秒内有输入）、1=休息（md.State=休息）、2=暂离（超5分钟无操作）
- 存储：`%LocalAppData%/SedentaryReminder/stats/yyyy-MM-dd.json`
- 数据结构：`{ date, samples: int[1440], updatedAt }`

**已完成的代码（待编译验证）**：
| 文件 | 说明 |
|---|---|
| `BLL/StatsManager.cs` | 数据采集 + 存储（每分钟采样，按日存 JSON） |
| `SedentaryReminder.xaml.cs` | 构造函数启动采样、Closed 停止采样 |
| `src/UI/Menu/MainMenuViewModel.cs` | 托盘菜单新增"今日统计"入口 |

**待完成**：
1. 编译验证（dotnet build），确保不影响现有久坐提醒逻辑
2. 本地运行测试：打开统计窗口、确认数据采集正常写入 JSON
3. 确认 24 小时条形图渲染正确
4. 考虑是否需要增加"近 7 天"热力图（Catrace 的分钟级热力图）

**注意事项**：
- 采样间隔 1 分钟，不影响现有 1 秒级计时逻辑
- 数据写入用 `lock` + 单文件，避免并发问题
- 采样失败不影响主程序（try-catch 包裹）

### 9.3 [2026-09-24] 用户反馈 BUG 与优化建议（来自 Store 评价）

#### BUG 清单

| # | 问题 | 反馈人数 | 严重度 | 现象 |
|---|---|---|---|---|
| B1 | **桌面快捷方式无法打开** | 3人 | 🔴 高 | 强制创建的快捷方式点击报错"Windows 无法访问指定设备、路径或文件。你可能没有适当的权限访问该项目" |
| B2 | **托盘显示时间错误** | 1人 | 🟡 中 | 点击托盘图标显示"已工作19分钟，2681分钟后进入休息"，实际设置45分钟（数值溢出/单位错误） |
| B3 | **后台运行无提醒** | 1人 | 🔴 高 | 后台运行时完全不提醒，1点坐到6点没反应 |
| B4 | **保存设置卡死** | 1人 | 🟡 中 | 一保存设置就卡死，没法用 |
| B5 | **新版本无智能计时** | 1人 | 🟡 中 | 新版本找不到智能计时模式入口 |

#### 优化建议

| # | 建议 | 说明 |
|---|---|---|
| O1 | **增加消息弹出提醒方式** | 很多情况不带耳机/不开外放，需要系统通知（Toast）弹窗提醒休息 |

#### 待排查方向

- **B1 快捷方式**：MSIX 应用快捷方式路径/权限问题，检查 `Package.appxmanifest` 的 `Extensions` 中快捷方式声明
- **B2 时间错误**：检查托盘提示文字的时间计算逻辑，是否有 `int` 溢出或分钟/秒单位混淆
- **B3 后台无提醒**：检查窗口最小化/隐藏后 `timer` 是否停止，或锁屏窗口是否被抑制
- **B4 保存卡死**：检查 `Dal.SetData` / 配置保存是否有同步 IO 阻塞主线程
- **B5 智能计时**：检查 `IsIntelligent` 字段在设置 UI 中是否有对应入口

#### 已修复（2026-09-24）

**B1 桌面快捷方式无法打开** ✅
- **根因**：MSIX 应用用 `Process.GetCurrentProcess().MainModule.FileName` 获取的路径是 `C:\Program Files\WindowsApps\...`，用户无权限直接访问，创建的 `.lnk` 点击报"无法访问指定设备、路径或文件"。
- **修复**：`App.xaml.cs` `CreateAllShortcuts()` 中用 `EnvironmentDetector.IsStoreInstallation()` 检测 Store 环境，Store 包跳过桌面/任务栏快捷方式创建（Store 应用会自动在开始菜单创建入口）。

**B2 托盘显示时间错误** ✅
- **根因**：`md.Work` 存储单位是**秒**（`SetUp.xaml.cs:277` `md.Work = workMinutes * 60 + workSeconds`），但托盘提示代码 `md.Work - (Count / 60)` 把秒当成分钟减。
- **验证**：设 45 分钟 → `md.Work = 2700`（秒），已工作 19 分钟 → `2700 - 19 = 2681` 分钟（与用户反馈完全吻合）。
- **修复**：`SedentaryReminder.xaml.cs` 提取 `ShowWorkTimeTip()` 方法，统一用 `(md.Work - Count) / 60` 计算剩余分钟。同时上报 `md.Work`、`Count` 到 Sentry breadcrumb 便于排查。

**日志上报增强**：
- 托盘提示时上报 `worked/remain/Work/Count` 到 Sentry（breadcrumb，category=tray_tip）
- Store 环境跳过快捷方式时上报 breadcrumb（category=shortcut）

---

## 10. 历史变更记录

| 日期 | 变更 |
|------|------|
| 2026-09-21 | 完成 v1.1.8.0 Store 上架。整理本文档。 |
| 2026-09-21 | MVVM 重构 + About → Support Us 合并进 SetUp。 |
| v1.1.7 (tag) | 历史版本，仅作配置对比参考。 |

---

## 9. 主窗口生命周期 / DispatcherTimer 关闭后抛 InvalidOperationException

### 9.1 [2026-09-21] MainWindow.timer_Tick 关闭后访问 UI 抛异常 (Sentry 1.1.7.91)

- **现象**: Sentry 报:
  > `MainWindow.timer_Tick → System.InvalidOperationException: 关闭窗口后...`
- **根因**:
  1. `MainWindow` 构造函数启动 `DispatcherTimer timer`（每秒），但 `MainWindow_Closed` **从未 stop 它**。
  2. 窗口 Unload → Closed 过程中/之后, `timer_Tick` 仍会触发一次, 访问 `this.Visibility` / `Time.Text` 抛异常.
  3. **用户反馈**: 子窗口 (`SetUp` / `LockScreen` / `About`) 在主窗口关闭时未主动释放, 可能继续触发自己的计时器/钩子.
- **修改** (`SedentaryReminder/SedentaryReminder.xaml.cs`):
  1. `timer_Tick` 顶部加 `if (!IsLoaded) { timer.Stop(); return; }` — 窗口 Unload 后立刻退出, 不再触碰 UI.
  2. `MainWindow_Closed` 末尾依次尝试关闭子窗口: `LockScreen.GetLockScreen`、`sp` (SetUp)、`aboutWin` (About), 然后 `timer.Stop()` 兜底.
  3. 新增 `internal About aboutWin = null;` 字段 + 在 `about_Click` 里赋值, 让退出时能 Close.
- **坑点**:
  - `MyNotifyIcon.Visibility = Visibility.Collapsed;` 这一行本身在 Closed 处理器里也有同类风险, 但目前未触发, **不要轻易挪到 OnClosing**, 除非确认有同样的崩溃.
  - 子窗口自己的 timer 也可能抛错 (如 `LockScreen.timer1_Tick` / `secondaryTimer`), 但它们各自的 Closed 处理器已经 stop, **不需要在这里统一管**.
  - `IsLoaded` 在 WPF 中由 FrameworkElement 管理, Closed 触发时通常已是 `false`, 比 `IsVisible` 更可靠.
  - **不要把 try-catch 简单吞掉**, 必须从源头 stop timer, 否则 Sentry 一直报警.

### 9.2 [2026-09-21] Tips 浮窗成孤儿窗口 (右键设置开机启动后立即退出)

- **现象**: 用户右键设置开机启动, "已经设置开机自启~" Tips 浮窗还没消失时就退出应用, 浮窗留在桌面上变成孤儿窗口.
- **根因**: Tips 没有公开的关闭入口. `static bool Function` 只能说明"是否打开", 但 MainWindow 退出时没有主动关闭它.
- **修改**:
  1. `UI/Tips.xaml.cs` 新增 `public static bool IsOpen => Function;` 和 `public static void CloseIfOpen()` (遍历 `Application.Current.Windows` 找到 Tips 实例并 Close).
  2. `MainWindow_Closed` 末尾追加 `SedentaryReminder.UI.Tips.CloseIfOpen();`, 与 LockScreen / SetUp / About 一起被统一释放.
- **坑点**:
  - 遍历 `Application.Current.Windows` 时不能用 `as Tips`, 必须用 `is Tips tp && tp.IsLoaded` 模式匹配, 否则遇到其他 Window 类型会 null 警告.
  - Tips 关闭后自己的 `Tips_Closed` 会把 `Function` 重置回 `false`, 下次 `CloseIfOpen()` 是幂等的.
  - 任何新增子窗口 (未来 PR 扩展) 都应同时接入 `MainWindow_Closed` 的统一释放列表, **不要让用户在窗口关闭后看到残留**.

### 9.3 [2026-09-22] 右键退出后僵尸进程 (Hardcodet.NotifyIcon.Wpf TaskbarIcon + Mutex 重复启动)

- **现象**: 用户右键"退出"几次后, 任务管理器里堆积 4+ 个 SedentaryReminder.exe 进程, 都没有 UI 但一直占着内存 (50-60 MB/个).
- **根因 (二)**:
  1. **TaskbarIcon 隐藏窗口**: `tb:TaskbarIcon` (Hardcodet.NotifyIcon.Wpf) 在系统托盘注册了一个**非托管的 message-only 窗口**, 这个窗口不属于 `Application.Current.Windows`, WPF 的 `ShutdownMode=OnLastWindowClose` 检测不到. `MyNotifyIcon.Visibility = Visibility.Collapsed` 只隐藏视觉图标, 没释放隐藏窗口 → 进程挂着不死.
  2. **Mutex 失败不退出**: `App_Startup` 里 Mutex 检测到重复实例时, `HandleRunningInstance` 把旧窗口拉到前台, 但**新进程不退出**, 变成无 UI 僵尸.
- **修改**:
  1. `MainWindow_Closed` 里 `MyNotifyIcon.Visibility = Collapsed` 改成 `MyNotifyIcon.Dispose();` —— 释放 TaskbarIcon 的隐藏窗口.
  2. 显式取消 `SystemEvents.SessionSwitch` 订阅 (finalizer 不保证跑).
  3. 末尾加 `Application.Current.Shutdown();` 兜底, 强制走 Exit 流程, 触发 `App.OnExit` 释放 Sentry/SilentHeartbeat.
  4. `App.xaml.cs` `App_Startup` 的 Mutex 失败分支追加 `this.Shutdown(); return;`.
- **坑点**:
  - TaskbarIcon 实现 `IDisposable`, **必须 Dispose 才能真正退出**, 单靠 Collapsed/Hidden 不行. 这是 Hardcodet.NotifyIcon.Wpf 的"经典坑".
  - `Application.Current.Shutdown()` 在 Closed 事件里调用是安全的, WPF 内部会处理重入.
  - 不要把 Shutdown 模式改成 `OnExplicitShutdown` 来"绕过"——会让主窗口关闭真的退不掉.
  - **最终验收**: 多次右键退出后, 任务管理器只剩系统进程, SedentaryReminder.exe 数量稳定为 0.

---

## 11. WPF UI 定制踩坑

### 11.1 [2026-09-29] 自定义 ComboBox ControlTemplate 导致下拉框点击无反应

- **现象**: 设置页三个下拉框（计时模式/锁屏风格/语言）点击完全无反应，IsDropDownOpen 始终为 false，PopUp 从未创建。同一页面的输入框和开关正常。
- **根因**:
  1. **自定义 ToggleButton 模板丢失 WPF 默认行为**: 原始 InputCombo 模板把 ToggleButton 的 ControlTemplate 写成了 Border Background="{TemplateBinding Background}" CornerRadius="3"/>，看似简单，实则丢了 WPF 默认 ToggleButton 模板里的隐式 HitTest 区域分配、Click 路由等内部处理。点击事件落到了 ToggleButton Border **之外**的 Grid 空白区，ToggleButton 的 Click 事件没触发，IsChecked 不会被置 true，Popup 打不开。
  2. **窗口级 DragMove 抢鼠标捕获**: MainPanelWindow.xaml 把 MouseLeftButtonDown="TitleBar_MouseLeftButtonDown" 挂在整个 Window 上，handler 无条件 	his.DragMove()。DragMove() 进入 Windows 原生模态移动循环并抢占鼠标捕获，会让 ComboBox 刚展开的 Popup 因"失捕"被立即回滚关闭。即使模板修好，这个也会让下拉框表现为"点了没反应"。两个 bug **叠加**让问题更隐蔽。
- **修改**:
  1. **InputCombo Style 删除整个 Setter Property="Template"** — 放弃自定义 ControlTemplate，只用 Style Setter 改外观（Height=30、背景灰#F3F4F6、字号14 等），ToggleButton + Popup 全部交给 WPF 默认实现。
  2. **DragMove 限定在顶部 48 DIP 标题栏 + 排除 ButtonBase** — if (e.GetPosition(this).Y > 48) return; if (e.OriginalSource is ButtonBase) return; this.DragMove();
- **坑点**:
  - **Style Setter 改属性比重写 ControlTemplate 安全得多**。WPF 控件的默认 ControlTemplate 里有大量看不到但必需的隐式行为，自定义模板很容易丢。
  - **二分法最靠谱**: 先确认 WPF 原生默认控件能正常工作，再逐块加自定义代码，每步都实机验证。不要一次写 40 行模板再整体测试。
  - **窗口级 MouseLeftButtonDown 慎用**: 如果要实现自定义标题栏拖拽，必须限定区域 + 排除 ButtonBase 等可交互控件。

### 11.2 [2026-09-29] 右键菜单自动关闭逻辑引发调试干扰

- **现象**: 托盘菜单自动关闭的 hook（HookAutoCloseOnCursorOutside）挂在 SharedTrayMenu_Opened 里，在调试其他下拉框问题时频繁触发，干扰排查。
- **修改**: 回滚 SharedTrayMenu_Opened 里的 hook 调用，托盘菜单改回默认行为（点空白/Esc 关闭）。
- **坑点**: 临时诊断/调试用的 hook 要记得及时清理，长期运行会干扰正常交互。

### 11.3 [2026-09-29] WPF 代码改完不重编译/不重启进程 = 白改

- **现象**: 多次改完 XAML/C# 后直接运行，发现下拉框还是旧状态。
- **根因**: WPF 改 XAML 后必须完整重编译 + 彻底退出进程再启动（托盘右键 → 退出，不要只关窗口），否则运行的还是旧 DLL。
- **坑点**: 调试 WPF UI 时，**每次改完代码 → 编译 → 彻底退出进程 → 重启 → 再测试**。偷懒不重启 = 浪费时间。

---

## 给以后 AI 模型的提示

1. **改 VERSION 文件前先看本文档 §1.1**——99% 的 Store 上架错误都是第四段非零。
2. **Store 打包直接运行 `build_multiarch.ps1`** (§1.9)，不要再手动执行 MSBuild/makeappx 步骤；脚本已自动处理版本同步、token 替换、ProcessorArchitecture 注入、产物校验。
3. **VERSION 文件必须保留第四段 REVISION**（§2.3）——即使 Store 不用，REVISION 用于内部版本追踪和产物命名；Store Identity 由脚本自动派生为前三段 + `.0`，不要把 VERSION 第四段手动写成 0。
4. **csproj 的版本字段必须和 manifest 同步改**（§2.1）——脚本已自动化，但手动改时别忘了。
5. **任何修改前先看本文档**，避免重复踩坑。
6. **PROJECT_FIXLOG.md 应该每次解决新问题后立即追加新条目**（用高端模型分析问题，把解决方案固化到此处）。