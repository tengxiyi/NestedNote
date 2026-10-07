# 把迁移与源码文件统一为 LF 行尾（幂等）。
#
# 依据：.gitattributes 规定迁移文件必须是 LF。
# 迁移文件的哈希被 client/crates/nested-db/tests/migration_guard.rs 校验，
# 行尾漂移会导致 CI 误报"迁移被篡改"。
#
# 用法：pwsh scripts/normalize-line-endings.ps1 [-Check]
#   -Check  只报告，不修改（供 CI 使用，发现非 LF 即失败）
#
# 注意：脚本内的用户可见输出一律使用 ASCII。
# 原因：Windows PowerShell 5.1 会把无 BOM 的 UTF-8 脚本按 ANSI 解码，
# 中文会变成乱码并导致解析错误。注释保留中文（在 ps7 下正常）。

[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$patterns = @(
    'client/migrations/*.sql',
    'client/**/*.rs',
    'server/**/*.rs',
    'shared/**/*.rs',
    '*.md',
    'docs/**/*.md',
    # 脚本本身也纳入：.gitattributes 曾把 *.ps1 声明为 CRLF 而实际全是 LF，
    # 因为那时没人检查 .ps1，声明与事实不一致却无人发现（见 .gitattributes 注释）
    'scripts/*.ps1',
    'client/**/*.dart',
    'client/**/*.yaml',
    'client/**/*.yml',
    '*.gitattributes',
    'justfile'
)

$targets = foreach ($pattern in $patterns) {
    Get-ChildItem -Path (Join-Path $root $pattern) -File -Recurse -ErrorAction SilentlyContinue
}

$targets = $targets |
    Where-Object { $_ -and $_.FullName -notmatch '[\\/](target|node_modules|\.git)[\\/]' } |
    Sort-Object FullName -Unique

$fixed = 0
$offenders = @()

foreach ($file in $targets) {
    # 按字节读入，避免 PowerShell 自己做的换行归一化
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasCr = $false
    foreach ($b in $bytes) {
        if ($b -eq 13) { $hasCr = $true; break }
    }
    if (-not $hasCr) { continue }

    if ($Check) {
        $offenders += $file.FullName.Substring($root.Length + 1)
        continue
    }

    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    [System.IO.File]::WriteAllText($file.FullName, $text, (New-Object System.Text.UTF8Encoding($false)))
    $fixed++
    Write-Host ("normalized to LF: " + $file.FullName.Substring($root.Length + 1))
}

if ($Check) {
    if ($offenders.Count -gt 0) {
        Write-Host "FAIL: these files are not LF-terminated (breaks migration hash guard):"
        $offenders | ForEach-Object { Write-Host ("  - " + $_) }
        exit 1
    }
    Write-Host ("OK: all " + $targets.Count + " files use LF")
    exit 0
}

Write-Host ("done: fixed " + $fixed + " of " + $targets.Count + " files")
