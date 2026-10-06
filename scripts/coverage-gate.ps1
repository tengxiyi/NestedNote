# 测试覆盖率门禁（铁律 Z1：核心 crate 行覆盖率 ≥ 80%）。
#
# 用法（仓库根目录）：
#   powershell -NoProfile -File scripts/coverage-gate.ps1
#   powershell -NoProfile -File scripts/coverage-gate.ps1 -ReportOnly   # 只报告，不判失败
#
# =============================================================================
# 为什么门禁只覆盖"已实现的 crate"（这是一条显式策略，不是遗漏）
# =============================================================================
#
# 铁律 Z1 说"核心 crate ≥ 80%"。但如果对**全部** crate 一刀切，会产生一个自欺的指标：
# 只有接口与常量、没有实现的 crate（例如 nested-import）会因为"可执行代码只有 8 行"
# 而轻松达标，甚至因为"一行都没跑到"而显示 0%。
# 覆盖率是"已实现代码被验证了多少"的度量，对"尚未实现"的代码没有意义。
#
# 因此策略是：
#   1. **计入门禁**：有实质实现的 crate（见下面的 $gate）。
#      新 crate 一旦落地实现，就必须**同时**加入本清单，否则门禁形同虚设。
#   2. **不计入门禁**：占位 crate（只有类型/常量/接口）、纯 CLI 入口、
#      codegen 生成的代码。每一项都必须在此处写明原因与解除条件。
#   3. 无论是否计入，**全部** crate 的数字都会打印出来，避免"看不见"。
#
# 输出使用 ASCII 之外的说明文字可读；本文件带 UTF-8 BOM，
# 因此在 Windows PowerShell 5.1 下也能正确显示（见 ADR 0004）。

[CmdletBinding()]
param(
    # 只报告，不因未达标而失败
    [switch]$ReportOnly,
    # 阈值（百分比）
    [double]$Threshold = 80.0
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$clientDir = Join-Path $root 'client'

# ---------------------------------------------------------------- 门禁清单
# 计入门禁的 crate（必须是有实质实现的）
$gate = @(
    'nested-model',       # 块模型 / 文档 / 领域实体 / ID / 时间
    'nested-db',          # SQLite 句柄 / 迁移 / 6 个仓储
    'nested-core',        # Domain Service 业务 API
    'nested-attachment',  # 内容寻址存储（CAS）
    'nested-sync',        # 同步错误分类与协议版本（重试策略已被测试覆盖）
    'nested-rules'        # 铁律检查器（库部分）
)

# 不计入门禁的项（原因与解除条件）
$exempt = @(
    @{ Name = 'nested-import'; Reason = '仅类型/常量占位，无可执行实现；P1 实现导入后必须并入 $gate' },
    @{ Name = 'nested-export'; Reason = '仅类型/常量占位；P1 实现导出与备份后必须并入 $gate' },
    @{ Name = 'nested-search'; Reason = '仅接口与常量占位；P1 实现 FTS5 后必须并入 $gate' },
    @{ Name = 'nested-crypto'; Reason = '仅 trait 与错误类型；方案待 ADR 决定后实现' },
    @{ Name = 'cli';           Reason = '进程级二进制，用 std::process::exit；为它写测试需要把 main 重构为库，收益不抵成本' },
    @{ Name = 'FFI';           Reason = '已用 --ignore-filename-regex 排除 codegen 生成的 frb_generated.rs（不入库、覆盖率恒为 0）；其余手写代码计入报告' }
)

Write-Host "== 覆盖率门禁（阈值 $Threshold%）=="
Write-Host ""

if (-not (Test-Path -LiteralPath $clientDir)) {
    Write-Host "FAIL: client workspace not found at $clientDir"
    exit 1
}

# ---------------------------------------------------------------- 采集
Push-Location $clientDir
try {
    $jsonPath = Join-Path $env:TEMP 'nested-coverage.json'
    $errPath = Join-Path $env:TEMP 'nested-coverage-stderr.txt'
    if (Test-Path -LiteralPath $jsonPath) { Remove-Item -LiteralPath $jsonPath -Force }

    # 说明：cargo 会把 deprecation 之类的提示写到 stderr，而 Windows PowerShell 5.1
    # 会把原生命令的 stderr **包装成 ErrorRecord**；在本脚本的
    # $ErrorActionPreference='Stop' 下这会直接变成终止错误——即使已经用 2> 重定向到文件。
    # 因此调用期间临时改为 'Continue'，并显式检查 $LASTEXITCODE（这才是我们关心的）。
    #
    # --ignore-filename-regex 排除 codegen 生成代码：它在仓库中不存在，
    # 覆盖率恒为 0%，会无意义地把 FFI crate 拖到门禁线以下。
    $cargoArgs = @(
        'llvm-cov', '--workspace', '--json', '--summary-only',
        '--ignore-filename-regex', 'frb_generated\.rs$'
    )
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & cargo @cargoArgs 1> $jsonPath 2> $errPath
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }

    if ($code -ne 0) {
        Write-Host "FAIL: cargo llvm-cov 执行失败（退出码 $code）"
        if (Test-Path -LiteralPath $errPath) {
            Write-Host "---- stderr（末尾 20 行）----"
            Get-Content -LiteralPath $errPath -Encoding UTF8 |
                Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" }
        }
        Write-Host "提示：需要先安装工具链组件与工具："
        Write-Host "  rustup component add llvm-tools-preview"
        Write-Host "  cargo install cargo-llvm-cov --locked"
        exit 1
    }
}
finally {
    Pop-Location
}

# ---------------------------------------------------------------- 聚合
# 用 PowerShell 解析（不依赖 Python：CI 的 windows runner 上不保证有 python）
$json = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$byCrate = @{}
foreach ($file in $json.data[0].files) {
    $relative = $file.filename.Replace('\', '/')
    $marker = '/client/'
    $index = $relative.IndexOf($marker)
    if ($index -lt 0) { continue }
    $parts = $relative.Substring($index + $marker.Length).Split('/')

    $key = if ($parts[0] -eq 'crates') { $parts[1] }
    elseif ($parts[0] -eq 'tools') { $parts[1] }
    elseif ($parts[0] -eq 'apps') { 'FFI' }
    else { $parts[0] }

    $lines = $file.summary.lines
    if (-not $byCrate.ContainsKey($key)) {
        $byCrate[$key] = @{ Count = 0; Covered = 0 }
    }
    $byCrate[$key].Count += $lines.count
    $byCrate[$key].Covered += $lines.covered
}

function Get-Percent {
    param($Entry)
    if ($Entry.Count -eq 0) { return [double]::NaN }
    return [math]::Round($Entry.Covered / $Entry.Count * 100, 1)
}

# ---------------------------------------------------------------- 报告
Write-Host "---- 计入门禁 ----"
$failures = @()
foreach ($name in $gate | Sort-Object) {
    if (-not $byCrate.ContainsKey($name)) {
        Write-Host ("  {0,-20} 未采集到（该 crate 可能没有可执行代码）" -f $name)
        $failures += $name
        continue
    }
    $entry = $byCrate[$name]
    $percent = Get-Percent $entry
    $mark = if ($percent -ge $Threshold) { 'OK  ' } else { 'FAIL' }
    Write-Host ("  [{0}] {1,-20} {2,6:N1}%  ({3}/{4} 行)" -f $mark, $name, $percent, $entry.Covered, $entry.Count)
    if ($percent -lt $Threshold) { $failures += $name }
}

Write-Host ""
Write-Host "---- 不计入门禁（原因见脚本头部注释）----"
foreach ($item in $exempt) {
    $percentText = 'n/a'
    if ($byCrate.ContainsKey($item.Name)) {
        $percentText = ('{0:N1}%' -f (Get-Percent $byCrate[$item.Name]))
    }
    Write-Host ("  {0,-18} {1,7}  {2}" -f $item.Name, $percentText, $item.Reason)
}

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "结论：全部计入项达标（≥ $Threshold%）。"
    exit 0
}

Write-Host ("结论：未达标 {0} 项：{1}" -f $failures.Count, ($failures -join ', '))
Write-Host "查看未覆盖行：cd client; cargo llvm-cov --package <crate> --show-missing-lines --text"
if ($ReportOnly) {
    Write-Host "(report-only 模式：不判失败)"
    exit 0
}
exit 1
