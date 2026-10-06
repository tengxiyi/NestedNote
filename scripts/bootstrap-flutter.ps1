# 一次性引导脚本：生成 Flutter 平台工程目录
#
# 为什么需要它：
#   Flutter 的平台目录（windows/ macos/ ios/ android/）体量大且由工具生成，
#   不适合手工维护。本脚本在**首次**配置环境时运行一次，之后这些目录随仓库提交。
#
# 用法（在仓库根目录）：
#   pwsh scripts/bootstrap-flutter.ps1
#   pwsh scripts/bootstrap-flutter.ps1 -Check   只检查环境，不生成
#
# 输出使用 ASCII，避免 Windows PowerShell 5.1 的编码问题。

[CmdletBinding()]
param(
    [switch]$Check,
    # 组织标识反域名（决定 iOS/macOS bundle id 与 Android applicationId）
    [string]$Organization = 'app.nestednote'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$flutterApp = Join-Path $root 'client/apps/flutter'

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

Write-Host "== 1/4 checking Flutter toolchain =="
if (-not (Test-Command 'flutter')) {
    Write-Host "FAIL: flutter is not installed or not on PATH."
    Write-Host ""
    Write-Host "Install Flutter (stable channel), then re-run this script:"
    Write-Host "  https://docs.flutter.dev/get-started/install/windows"
    Write-Host ""
    Write-Host "After install, run:"
    Write-Host "  flutter --version"
    Write-Host "  flutter doctor -v"
    exit 1
}

$flutterVersion = (& flutter --version 2>&1 | Select-Object -First 1)
Write-Host "flutter: $flutterVersion"

Write-Host "== 2/4 checking desktop/mobile targets =="
if (-not $Check) {
    & flutter config --enable-windows-desktop | Out-Null
    & flutter config --enable-macos-desktop | Out-Null
}

if ($Check) {
    Write-Host "check-only mode: nothing generated."
    exit 0
}

Write-Host "== 3/4 generating platform projects =="
if (-not (Test-Path $flutterApp)) {
    Write-Host "FAIL: $flutterApp not found."
    exit 1
}

# 说明：
#   - 用 `flutter create` 补齐平台目录；已存在的文件不会被覆盖
#   - --project-name 必须是合法的 Dart 包名（小写下划线），品牌名放显示名
& flutter create `
    --org $Organization `
    --project-name nested `
    --platforms windows,macos,ios,android `
    --description "拾光笔记 / NestedNote - local-first cross-platform notes" `
    $flutterApp

if ($LASTEXITCODE -ne 0) {
    Write-Host "FAIL: flutter create returned $LASTEXITCODE"
    exit 1
}

Write-Host "== 4/4 fetching Dart dependencies =="
Push-Location $flutterApp
try {
    & flutter pub get
    if ($LASTEXITCODE -ne 0) {
        Write-Host "WARN: flutter pub get failed (flutter_rust_bridge may not be published/available yet)."
    }
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "done. platform directories are ready under client/apps/flutter/"
Write-Host "next: pwsh scripts/build-rust-for-flutter.ps1 -Platform windows"
