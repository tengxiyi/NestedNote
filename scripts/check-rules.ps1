# 铁律自动检查（本地快速自检入口）
#
# 权威实现是 Rust 工具 `client/tools/nested-rules`：
#   - 跨平台、可测试、与文件编码无关
#   - 每条规则都有单元测试（见 client/tools/nested-rules/src/checks.rs）
#
# 为什么还保留这个 PowerShell 包装：
#   1. 让不熟悉 cargo 的人也能一条命令跑检查；
#   2. CI 与 justfile 统一走同一入口，未来换实现只改这里。
#
# 用法：powershell -NoProfile -File scripts/check-rules.ps1 [-ReportOnly]
# 退出码：0 = 通过；1 = 有违规
#
# 注意：本脚本的用户可见输出使用 ASCII。
# Windows PowerShell 5.1 会把无 BOM 的 UTF-8 脚本按 ANSI 解码，中文会乱码。

[CmdletBinding()]
param(
    # 仅报告不失败（本地排查用）
    [switch]$ReportOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path -LiteralPath $root)) {
    Write-Error "cannot resolve repository root from $PSScriptRoot"
    exit 1
}

$arguments = @('run', '--quiet', '-p', 'nested-rules', '--', '--root', $root)
if ($ReportOnly) { $arguments += '--report-only' }

Push-Location (Join-Path $root 'client')
try {
    & cargo @arguments
    $code = $LASTEXITCODE
}
finally {
    Pop-Location
}

if ($code -ne 0 -and -not $ReportOnly) {
    Write-Host ""
    Write-Host "rules check FAILED (exit $code)"
    Write-Host "see docs/02-工程铁律.md for the rules themselves"
    exit 1
}

exit 0
