# 安装 Flutter SDK（解压 + 配置 PATH + Windows 桌面支持）。
#
# 前置：已下载 flutter_windows_<version>-stable.zip 并校验 SHA-256。
# 用法（仓库根目录）：powershell -NoProfile -File scripts/install-flutter.ps1
#
# 设计说明：
#   - 安装到 C:\src\flutter（Flutter 官方文档推荐的位置，路径不含空格）
#   - PATH 写入**用户级**环境变量，不需要管理员权限
#   - 不使用 `setx`（它会截断超过 1024 字符的 PATH，是经典踩坑点），
#     改用 [Environment]::SetEnvironmentVariable
#   - 用户可见输出使用 ASCII（Windows PowerShell 5.1 会按 ANSI 解码无 BOM 的 UTF-8 脚本）

[CmdletBinding()]
param(
    [string]$ZipPath = "$env:USERPROFILE\Downloads\flutter_windows_3.47.6-stable.zip",
    [string]$InstallDir = 'C:\src\flutter',
    [string]$ExpectedSha256 = 'a01bb0d26de91bc23c97cd9ccfaad281a612fb8304213fdd5df1119a09404796',
    # 只校验与解压，不修改 PATH
    [switch]$NoPathUpdate
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host "== $Text =="
}

# ---------------------------------------------------------------- 1. 校验下载
Write-Step "1/5 verify downloaded archive"
if (-not (Test-Path -LiteralPath $ZipPath)) {
    Write-Host "FAIL: archive not found: $ZipPath"
    exit 1
}
$sizeMb = (Get-Item -LiteralPath $ZipPath).Length / 1MB
Write-Host ("archive: {0} ({1:N0} MB)" -f $ZipPath, $sizeMb)

$actual = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $ExpectedSha256) {
    Write-Host "FAIL: SHA-256 mismatch"
    Write-Host "  expected: $ExpectedSha256"
    Write-Host "  actual  : $actual"
    Write-Host "the download is corrupt or truncated; delete it and retry"
    exit 1
}
Write-Host "SHA-256 OK"

# ---------------------------------------------------------------- 2. 解压
Write-Step "2/5 extract to $InstallDir"
if (Test-Path -LiteralPath (Join-Path $InstallDir 'bin\flutter.bat')) {
    Write-Host "already present, skipping extraction"
}
else {
    $parent = Split-Path -Parent $InstallDir
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $InstallDir) {
        Write-Host "target directory exists but is incomplete; removing it first"
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "extracting (about 40k files, this takes several minutes)..."
    # 直接解压到父目录：zip 内已有一层 flutter/ 目录
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $parent -Force
    $sw.Stop()
    Write-Host ("extracted in {0:N1} minutes" -f $sw.Elapsed.TotalMinutes)
}

$flutterBat = Join-Path $InstallDir 'bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutterBat)) {
    Write-Host "FAIL: $flutterBat not found after extraction"
    exit 1
}
Write-Host "flutter.bat OK"

# ---------------------------------------------------------------- 3. PATH
Write-Step "3/5 configure PATH (user scope)"
if ($NoPathUpdate) {
    Write-Host "skipped (-NoPathUpdate)"
}
else {
    $binDir = Join-Path $InstallDir 'bin'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrEmpty($userPath)) { $userPath = '' }

    $entries = $userPath -split ';' | Where-Object { $_ -ne '' }
    if ($entries -contains $binDir) {
        Write-Host "already on user PATH: $binDir"
    }
    else {
        # 追加而不是前置：避免遮蔽其它工具
        $newPath = (@($entries) + $binDir) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Host "appended to user PATH: $binDir"
        Write-Host "note: already-open terminals must be restarted to pick this up"
    }

    # 让当前会话立即可用
    $env:Path = "$env:Path;$binDir"
    [Environment]::SetEnvironmentVariable('FLUTTER_ROOT', $InstallDir, 'User')
    $env:FLUTTER_ROOT = $InstallDir
    Write-Host "FLUTTER_ROOT=$InstallDir (user scope)"
}

# ---------------------------------------------------------------- 4. 首次运行
Write-Step "4/5 first run (downloads the bundled Dart SDK)"
$sw = [Diagnostics.Stopwatch]::StartNew()
& $flutterBat --version
$code = $LASTEXITCODE
$sw.Stop()
Write-Host ("flutter --version exited $code in {0:N1} minutes" -f $sw.Elapsed.TotalMinutes)
if ($code -ne 0) {
    Write-Host "FAIL: flutter --version failed"
    exit 1
}

# ---------------------------------------------------------------- 5. 桌面支持
Write-Step "5/5 enable Windows desktop"
& $flutterBat config --enable-windows-desktop
& $flutterBat config --enable-macos-desktop
& $flutterBat config --no-analytics
Write-Host ""
Write-Host "installed. next steps:"
Write-Host "  flutter doctor -v"
Write-Host "  powershell -NoProfile -File scripts/bootstrap-flutter.ps1"
