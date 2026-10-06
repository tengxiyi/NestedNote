# 验证打包后的桌面应用是否真的能用（笔记闭环 + 数据持久化）。
#
# 用法（仓库根目录）：
#   powershell -NoProfile -File scripts/verify-app.ps1
#
# 它在**应用真实数据目录**（%APPDATA%\app.nestednote\nested）上执行：
#   启动引擎 → 建笔记 → 写正文 → 读回 → 关闭 → 重开 → 确认内容仍在 → 收尾
#
# 只软删除自己创建的验证笔记，不动你已有的数据。
# 因此可以安全地反复运行。

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$clientDir = Join-Path $root 'client'
$flutterApp = Join-Path $clientDir 'apps\flutter'

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    # Flutter 可能装在默认位置但不在 PATH 里
    $candidate = 'C:\src\flutter\bin'
    if (Test-Path (Join-Path $candidate 'flutter.bat')) {
        $env:Path = "$env:Path;$candidate"
    }
    else {
        Write-Host 'FAIL: 找不到 flutter 命令，也没有 C:\src\flutter。'
        Write-Host '提示：运行 scripts/install-flutter.ps1 安装工具链。'
        exit 1
    }
}

Write-Host '== 1/3 构建 Rust 动态库（release）=='
Push-Location $clientDir
try {
    # cargo 的 deprecation 提示走 stderr；PS 5.1 会把它包装成 ErrorRecord，
    # 因此在调用期间临时放宽错误偏好（见 scripts/coverage-gate.ps1 的同类说明）。
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    cargo build --release -p nested_app
    $code = $LASTEXITCODE
    $ErrorActionPreference = $saved
    if ($code -ne 0) {
        Write-Host "FAIL: cargo build 失败（退出码 $code）"
        exit 1
    }
}
finally {
    Pop-Location
}

Write-Host ''
Write-Host '== 2/3 运行端到端验证 =='
$env:FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR = Join-Path $clientDir 'target\release'
Push-Location $flutterApp
try {
    dart run tool/verify_app.dart
    $code = $LASTEXITCODE
}
finally {
    Pop-Location
}

Write-Host ''
Write-Host '== 3/3 产物位置 =='
$release = Join-Path $flutterApp 'build\windows\x64\runner\Release'
if (Test-Path (Join-Path $release 'nested.exe')) {
    Write-Host "已打包的 exe：$(Join-Path $release 'nested.exe')"
    Write-Host '（双击即可运行；若尚未打包，执行：just app-build）'
}
else {
    Write-Host '尚未打包 exe。执行以下命令打包：'
    Write-Host '  cd client/apps/flutter'
    Write-Host '  flutter build windows --release'
}

if ($code -ne 0) {
    Write-Host ''
    Write-Host "结论：验证未通过（退出码 $code）"
    exit $code
}
Write-Host ''
Write-Host '结论：验证通过。'
exit 0
