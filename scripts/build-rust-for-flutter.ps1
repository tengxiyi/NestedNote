# 构建 Rust 内核并放到 Flutter 平台工程可链接的位置。
#
# 为什么需要它：
#   flutter_rust_bridge 生成的绑定需要一个本地动态/静态库。
#   `cargo build` 的产物在 client/target/ 下，Flutter 的平台构建器看不到，
#   因此需要一个显式的"摆放"步骤（而不是让 CMake 去猜路径）。
#
# 用法（仓库根目录）：
#   pwsh scripts/build-rust-for-flutter.ps1 -Platform windows
#   pwsh scripts/build-rust-for-flutter.ps1 -Platform windows -Release
#
# 输出使用 ASCII，避免 Windows PowerShell 5.1 的编码问题。

[CmdletBinding()]
param(
    [ValidateSet('windows', 'macos', 'linux', 'android', 'ios')]
    [string]$Platform = 'windows',
    [switch]$Release
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$rustDir = Join-Path $root 'client/apps/rust'
$flutterDir = Join-Path $root 'client/apps/flutter'

if (-not (Test-Path -LiteralPath (Join-Path $rustDir 'Cargo.toml'))) {
    Write-Host "FAIL: Rust bridge crate not found at $rustDir"
    exit 1
}

$profileArgs = @()
$profileName = 'debug'
if ($Release) {
    $profileArgs = @('--release')
    $profileName = 'release'
}

Write-Host "== building nested-app ($profileName) for $Platform =="
Push-Location $rustDir
try {
    & cargo build @profileArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL: cargo build returned $LASTEXITCODE"
        exit 1
    }
}
finally {
    Pop-Location
}

# 产物路径与目标文件名
$targetDir = Join-Path $root "client/target/$profileName"
$artifacts = @{
    'windows' = @{ Source = 'nested_app.dll'; Destination = 'windows/runner/nested_app.dll' }
    'macos'   = @{ Source = 'libnested_app.dylib'; Destination = 'macos/Frameworks/libnested_app.dylib' }
    'linux'   = @{ Source = 'libnested_app.so'; Destination = 'linux/lib/libnested_app.so' }
}

Write-Host "== placing artifacts =="
if ($artifacts.ContainsKey($Platform)) {
    $source = Join-Path $targetDir $artifacts[$Platform].Source
    $destination = Join-Path $flutterDir $artifacts[$Platform].Destination
    $destinationDir = Split-Path -Parent $destination

    if (-not (Test-Path -LiteralPath $source)) {
        Write-Host "WARN: artifact not found: $source"
        Write-Host "      (the library name may differ; check client/target/$profileName)"
        Get-ChildItem -LiteralPath $targetDir -Filter 'nested_app*' -ErrorAction SilentlyContinue |
            Select-Object -First 5 Name, Length | Format-Table -AutoSize
    }
    else {
        if (-not (Test-Path -LiteralPath $destinationDir)) {
            New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $source -Destination $destination -Force
        Write-Host "copied: $source"
        Write-Host "     -> $destination"
    }
}
else {
    Write-Host "platform '$Platform' uses the build system's own linking step (no manual copy needed)."
    Write-Host "for android/ios, build the corresponding target with cargo-ndk / xcodebuild."
}

Write-Host ""
Write-Host "done."
Write-Host "next: cd client/apps/flutter && flutter run -d $Platform"
