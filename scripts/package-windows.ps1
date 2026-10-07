# SPDX-License-Identifier: AGPL-3.0-or-later
# 把 Windows 桌面应用打成一个"解压即用"的绿色包。
#
# 用法（仓库根目录）：
#   powershell -NoProfile -File scripts/package-windows.ps1
#   powershell -NoProfile -File scripts/package-windows.ps1 -SkipBuild
#
# 产物：
#   dist/NestedNote-<版本>-windows-x64.zip
#
# ## 为什么必须是"整个目录"而不是单个 exe
#
# Windows 上的 Flutter 应用无法自包含成单体 exe：
#   nested.exe        启动器，极小
#   nested_app.dll    我们的 Rust 内核（业务逻辑都在这里）
#   flutter_windows.dll  Flutter 引擎
#   data/             引擎资源与字体
# 缺任何一个都起不来。想做成单体 exe 需要额外的打包器
# （如 Enigma Virtual Box），那会引入"运行时释放到临时目录"的问题，
# 并且让杀毒软件更容易误报——对笔记软件来说不值得。
#
# ## 为什么包内要放一份中文说明
#
# 拿到 zip 的人未必知道"解压后要运行哪个文件"，也不知道数据存在哪里。
# 这两件事必须写在包里，而不是只在提交信息里。

[CmdletBinding()]
param(
    # 跳过构建，直接打包现有产物（本地快速重打时用）
    [switch]$SkipBuild,
    # 版本号；默认读 client/apps/flutter/pubspec.yaml
    [string]$Version = ''
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$releaseDir = Join-Path $repoRoot 'client\apps\flutter\build\windows\x64\runner\Release'
$distDir = Join-Path $repoRoot 'dist'

if (-not $SkipBuild) {
    Write-Host '== 构建 Windows 桌面应用 ==' -ForegroundColor Cyan
    Push-Location (Join-Path $repoRoot 'client\apps\flutter')
    try {
        & flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build 失败（退出码 $LASTEXITCODE）" }
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path $releaseDir)) {
    throw "找不到构建产物目录：$releaseDir`n先运行不带 -SkipBuild 的本脚本。"
}

# 必需文件清单：缺任何一个都说明构建不完整，必须直接失败，
# 而不是打出一个"能下能解压但一运行就报错"的包。
$required = @(
    'nested.exe',
    'nested_app.dll',
    'flutter_windows.dll',
    'data\app.so',
    'data\icudtl.dat'
)
$missing = @($required | Where-Object { -not (Test-Path (Join-Path $releaseDir $_)) })
if ($missing.Count -gt 0) {
    throw "构建产物缺少必需文件：$($missing -join ', ')`n产物目录：$releaseDir"
}

# 版本号
if ([string]::IsNullOrWhiteSpace($Version)) {
    $pubspec = Join-Path $repoRoot 'client\apps\flutter\pubspec.yaml'
    $m = [regex]::Match((Get-Content $pubspec -Raw -Encoding UTF8), '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)')
    if (-not $m.Success) { throw "无法从 pubspec.yaml 读出版本号，请用 -Version 指定" }
    $Version = $m.Groups[1].Value
}

# 打包到临时暂存目录：这样可以精确控制包内结构，
# 也能顺手放说明文件而不污染 build 目录
$stamp = Join-Path ([System.IO.Path]::GetTempPath()) ("nested-pkg-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$stageName = "NestedNote-$Version-windows-x64"
$stage = Join-Path $stamp $stageName
New-Item -ItemType Directory -Path $stage -Force | Out-Null

try {
    Write-Host '== 复制产物 ==' -ForegroundColor Cyan
    Copy-Item -Path (Join-Path $releaseDir '*') -Destination $stage -Recurse -Force

    # 包内说明。用 .NET 写入并**带 UTF-8 BOM**：
    # 记事本在旧版 Windows 上对无 BOM 的 UTF-8 会按 ANSI 解码，中文变乱码。
    $readme = @"
拾光笔记 / NestedNote  v$Version  (Windows x64)
====================================================

怎么用
------
1. 把整个文件夹解压到任意位置（例如 D:\NestedNote）
   ⚠ 不要只把 nested.exe 单独拖出来——它单独存在时无法启动。
2. 双击 nested.exe。

不需要安装 .NET、Rust 或 Flutter，也不需要联网。


我的笔记存在哪里
----------------
    %APPDATA%\app.nestednote\nested\nested.db

在资源管理器地址栏粘贴上面这行即可打开该目录。

⚠ 备份时请连 nested.db-wal 一起复制（如果它存在）。
   数据库用了 WAL 模式，最近写入的内容可能还在 -wal 文件里；
   只复制 nested.db 有可能丢掉最后几条修改。

想换个位置存（比如放到 U 盘或同步盘）：目前版本还不支持自定义数据目录，
见"已知限制"。


当前版本能做什么
----------------
· 三栏界面：左栏笔记本树 / 中栏笔记列表 / 右栏阅读编辑区
· 笔记本支持多层嵌套（实测 6 层以上没问题），
  也可以在任意一层直接放笔记
· 选中上层笔记本时，列表会包含其下所有层级的笔记
· 三栏宽度都可以拖动调整
· 笔记自动保存（停止输入约 1.2 秒后保存）
· 每次保存都留修订记录，可回溯
· 删除是"移入回收站"，可恢复
· 引擎自检：右上角心跳图标，可查看数据库状态


已知限制（这一版还没做）
------------------------
· 右栏是纯文本编辑器：标题、列表、引用、代码块等格式**暂时不保留**，
  存下来的是纯文本。块模型已经能存这些结构，但编辑器还没接上。
· 没有全文搜索
· 没有附件插图界面（内核已支持内容寻址存储，界面未接）
· 笔记本不能重命名（内核已支持，界面未接）
· 数据目录暂时固定在 %APPDATA%，不能改


出问题怎么办
------------
· 启动后界面空白 / 只有一句错误提示：
  看 %TEMP%\nested-ui-diagnostics.txt，里面有引擎状态与数据库路径。
· 想确认数据没坏：右上角心跳图标 → 引擎自检，
  应显示 database_open / schema_current / integrity 三项均为 true。
· 数据库损坏时不要手删文件，先把整个目录复制一份留证。


许可证
------
AGPL-3.0-or-later。源码：https://github.com/tengxiyi/NestedNote
"@
    # UTF-8 **带 BOM**
    [System.IO.File]::WriteAllText(
        (Join-Path $stage '使用说明.txt'),
        $readme,
        (New-Object System.Text.UTF8Encoding($true))
    )

    # 许可证随包分发（AGPL 要求）
    $license = Join-Path $repoRoot 'LICENSE'
    if (Test-Path $license) {
        Copy-Item $license (Join-Path $stage 'LICENSE') -Force
    }

    # 校验和：铁律 B6 要求产物可校验
    Write-Host '== 计算校验和 ==' -ForegroundColor Cyan
    $hashes = Get-ChildItem $stage -Recurse -File |
        Sort-Object FullName |
        ForEach-Object {
            $rel = $_.FullName.Substring($stage.Length + 1) -replace '\\', '/'
            $h = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            "$h  $rel"
        }
    [System.IO.File]::WriteAllLines(
        (Join-Path $stage 'SHA256SUMS.txt'),
        $hashes,
        (New-Object System.Text.UTF8Encoding($false))
    )

    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
    $zipPath = Join-Path $distDir "$stageName.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    Write-Host '== 压缩 ==' -ForegroundColor Cyan
    Compress-Archive -Path $stage -DestinationPath $zipPath -CompressionLevel Optimal

    $zip = Get-Item $zipPath
    $zipHash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $fileCount = (Get-ChildItem $stage -Recurse -File).Count

    Write-Host ''
    Write-Host '完成。' -ForegroundColor Green
    Write-Host "  压缩包：$($zip.FullName)"
    Write-Host "  大小：  $('{0:N1} MB' -f ($zip.Length / 1MB))  （含 $fileCount 个文件）"
    Write-Host "  SHA256：$zipHash"
    Write-Host ''
    Write-Host '把这个 zip 发给别人，对方解压后双击 nested.exe 即可，无需任何依赖。'
}
finally {
    if (Test-Path $stamp) { Remove-Item $stamp -Recurse -Force -ErrorAction SilentlyContinue }
}
