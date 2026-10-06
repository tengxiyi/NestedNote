# CI 状态检查：用本机已有的 GitHub 凭据读取 Actions 结果，并翻译成可读报告。
#
# 用法（仓库根目录）：
#   powershell -NoProfile -File scripts/check-ci.ps1
#   powershell -NoProfile -File scripts/check-ci.ps1 -Repo tengxiyi/NestedNote -Runs 5
#   powershell -NoProfile -File scripts/check-ci.ps1 -Token "<个人访问令牌>"
#
# 为什么需要它：仓库是私有的，GitHub 的 Actions 接口需要认证。
# 本脚本复用 git 凭据管理器里已有的令牌，避免每次手工去网页翻日志。
#
# 安全说明：脚本**不会**打印令牌内容，只把它用在 Authorization 头上。
# 本文件带 UTF-8 BOM，因此在 Windows PowerShell 5.1 下也能正确处理中文（见 ADR 0004）。

[CmdletBinding()]
param(
    [string]$Repo = 'tengxiyi/NestedNote',
    [int]$Runs = 3,
    # 可显式传入令牌，优先于环境变量与凭据管理器
    [string]$Token
)

$ErrorActionPreference = 'Stop'

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host "== $Text =="
}

# 把异常转成"HTTP 状态 + 响应体"，避免只看到"远程服务器返回错误"这种无用信息
function Get-FailureDetail {
    param($ErrorRecord)
    $resp = $ErrorRecord.Exception.Response
    if (-not $resp) { return $ErrorRecord.Exception.Message }
    $code = $resp.StatusCode.value__
    $body = ''
    try {
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $reader.ReadToEnd()
    }
    catch { }
    return "HTTP $code - $body"
}

# ---------------------------------------------------------------- 取令牌
function Get-GitHubToken {
    param([string]$Explicit)

    if ($Explicit) { return $Explicit }
    if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN }
    if ($env:GH_TOKEN) { return $env:GH_TOKEN }

    $gcm = 'C:\Program Files\Git\mingw64\bin\git-credential-manager.exe'
    if (-not (Test-Path -LiteralPath $gcm)) { return $null }

    # 注意：刻意不用 `$input` 作为变量名 —— 它是 PowerShell 的自动变量，
    # 复用它会与管道输入冲突（这是本脚本早期版本的踩坑点）。
    $credentialRequest = "protocol=https`nhost=github.com`n`n"
    $credentialOutput = $credentialRequest | & $gcm get 2>$null
    foreach ($line in $credentialOutput) {
        if ($line -like 'password=*') { return $line.Substring('password='.Length) }
    }
    return $null
}

Write-Head "认证"
$tokenValue = Get-GitHubToken -Explicit $Token
if (-not $tokenValue) {
    Write-Host "未取得 GitHub 令牌，无法查询私有仓库。"
    Write-Host ""
    Write-Host "可选做法："
    Write-Host "  1) 设置环境变量后重跑："
    Write-Host '     $env:GITHUB_TOKEN = "<个人访问令牌>"'
    Write-Host "  2) 或把令牌作为参数传入："
    Write-Host '     powershell -NoProfile -File scripts/check-ci.ps1 -Token "<个人访问令牌>"'
    Write-Host "  3) 或者直接在浏览器里查看："
    Write-Host "     https://github.com/$Repo/actions"
    exit 1
}
Write-Host "已取得令牌（长度 $($tokenValue.Length)，内容不显示）"
if (-not $Repo) {
    Write-Host "内部错误：仓库名称为空，无法继续。"
    exit 1
}
Write-Host "目标仓库：$Repo"

$headers = @{
    'Authorization' = "Bearer $tokenValue"
    'Accept'        = 'application/vnd.github+json'
    'User-Agent'    = 'nested-ci-check'
}

# ---------------------------------------------------------------- 仓库信息
Write-Head "仓库"
try {
    $repoInfo = Invoke-RestMethod "https://api.github.com/repos/$Repo" -Headers $headers -TimeoutSec 30
    Write-Host "名称     : $($repoInfo.full_name)"
    Write-Host "可见性   : $($repoInfo.visibility)"
    Write-Host "默认分支 : $($repoInfo.default_branch)"
    Write-Host "最近推送 : $($repoInfo.pushed_at)"
}
catch {
    Write-Host "读取仓库失败：$(Get-FailureDetail -ErrorRecord $_)"
    Write-Host "（401/403 通常是令牌过期或无权限；404 通常是该令牌看不到这个私有仓库）"
    exit 1
}

# ---------------------------------------------------------------- 工作流
Write-Head "工作流"
try {
    $workflows = Invoke-RestMethod "https://api.github.com/repos/$Repo/actions/workflows" -Headers $headers -TimeoutSec 30
    if ($workflows.total_count -eq 0) {
        Write-Host "该仓库还没有任何工作流 —— 可能是 .github/workflows/ci.yml 尚未到达默认分支。"
    }
    foreach ($wf in $workflows.workflows) {
        Write-Host ("- {0}  [{1}]  {2}" -f $wf.name, $wf.state, $wf.path)
    }
}
catch { Write-Host "读取工作流失败：$(Get-FailureDetail -ErrorRecord $_)" }

# ---------------------------------------------------------------- 最近运行
Write-Head "最近 $Runs 次运行"
$runsList = @()
try {
    $runsResponse = Invoke-RestMethod "https://api.github.com/repos/$Repo/actions/runs?per_page=$Runs" -Headers $headers -TimeoutSec 30
    $runsList = @($runsResponse.workflow_runs)
}
catch { Write-Host "读取运行记录失败：$(Get-FailureDetail -ErrorRecord $_)" }

if ($runsList.Count -eq 0) {
    Write-Host "没有运行记录。"
    Write-Host ""
    Write-Host "如果刚刚推送过，请等 1-2 分钟后重跑（GitHub 入队有时会延迟）。"
    Write-Host "也可以直接在浏览器里查看：https://github.com/$Repo/actions"
    exit 0
}

$latest = $runsList[0]
foreach ($run in $runsList) {
    $mark = switch ($run.conclusion) {
        'success'   { '通过' }
        'failure'   { '失败' }
        'cancelled' { '取消' }
        default     { if ($run.status -eq 'in_progress') { '运行中' } else { '等待' } }
    }
    Write-Host ("[{0,-6}] {1}  第 {2} 次  {3}" -f $mark, $run.created_at, $run.run_number, $run.head_sha.Substring(0, 7))
    Write-Host ("         {0}" -f $run.display_title)
    Write-Host ("         {0}" -f $run.html_url)
}

# ---------------------------------------------------------------- 作业明细
if ($latest.status -ne 'completed') {
    Write-Head "结论"
    Write-Host "最新一次仍在进行中（状态：$($latest.status)）。"
    Write-Host "稍等片刻后重跑本脚本，或打开："
    Write-Host "  $($latest.html_url)"
    exit 0
}

Write-Head "最新运行的作业明细"
$jobsResponse = Invoke-RestMethod "https://api.github.com/repos/$Repo/actions/runs/$($latest.id)/jobs" -Headers $headers -TimeoutSec 30
$failedJobs = @()
foreach ($job in $jobsResponse.jobs) {
    $mark = switch ($job.conclusion) {
        'success'   { '通过' }
        'failure'   { '失败' }
        'skipped'   { '跳过' }
        'cancelled' { '取消' }
        default     { '?' }
    }
    Write-Host ("[{0,-6}] {1}" -f $mark, $job.name)
    if ($job.conclusion -eq 'failure') { $failedJobs += $job }
}

# ---------------------------------------------------------------- 结论
if ($failedJobs.Count -eq 0) {
    Write-Head "结论"
    if ($latest.conclusion -eq 'success') {
        Write-Host "全绿：所有作业都通过了。"
        Write-Host "可以进行下一步（覆盖率基线 / 详细设计文档 / P1）。"
    }
    else {
        Write-Host "失败作业数为 0，但总体结论是 $($latest.conclusion)，请核对上面的列表。"
    }
    exit 0
}

Write-Head "失败步骤与日志尾部"
Write-Host "共 $($failedJobs.Count) 个作业失败。"
foreach ($job in $failedJobs) {
    Write-Host ''
    Write-Host "---- 作业：$($job.name) ----"
    Write-Host "  页面：$($job.html_url)"
    foreach ($step in $job.steps) {
        if ($step.conclusion -eq 'failure') {
            Write-Host "  失败步骤：$($step.name)"
        }
    }

    try {
        $log = Invoke-RestMethod "https://api.github.com/repos/$Repo/actions/jobs/$($job.id)/logs" -Headers $headers -TimeoutSec 60
        $lines = @($log -split "`n")
        Write-Host "  日志末尾 40 行："
        foreach ($line in ($lines | Select-Object -Last 40)) { Write-Host "    $line" }
    }
    catch {
        Write-Host "  无法自动读取日志（$(Get-FailureDetail -ErrorRecord $_)）。"
        Write-Host "  请打开上面的页面，点失败步骤左侧箭头展开日志，把红色部分发给我。"
    }
}

Write-Head "结论"
Write-Host "CI 未通过。把上面的失败步骤与日志尾部发给我，我来定位并修复。"
exit 1
