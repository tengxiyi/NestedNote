# 把源码与迁移文件统一为 LF 行尾（幂等）。
#
# 依据：.gitattributes 规定这些文件必须是 LF。
# 迁移文件的哈希被 client/crates/nested-db/tests/migration_guard.rs 校验，
# 行尾漂移会导致 CI 误报"迁移被篡改"。
#
# 用法：pwsh scripts/normalize-line-endings.ps1 [-Check]
#   -Check  只报告，不修改（供 CI 使用，发现非 LF 即失败）
#
# 注意：脚本内的用户可见输出一律使用 ASCII。
# 原因：Windows PowerShell 5.1 会把无 BOM 的 UTF-8 脚本按 ANSI 解码，
# 中文会变成乱码并导致解析错误。注释保留中文（在 ps7 下正常）。

param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# ============================================================================
# 覆盖范围
# ============================================================================
#
# ## 这里曾经有一个严重的门禁缺陷（两个独立原因）
#
# 原先写的是 `Get-ChildItem -Path (Join-Path $root 'client/**/*.rs') -Recurse`。
#
# **原因一：`Get-ChildItem -Path` 不支持 `**`。**
# 那些模式实际匹配到 **0 个文件**。所有 Rust 源码、所有 Dart 源码
# **从未被检查过**，而脚本一直打印 "OK: all 52 files use LF" —— 那个通过是假的。
#
# **原因二：`-Include` 在 Windows PowerShell 5.1 下过滤不可靠。**
# 实测 `-Recurse -Include @('*.rs')` 匹配到 43412 个文件（把 target/、
# build/ 全扫进来了）。它依赖路径里带通配符，语义很脆。
#
# 因此现在**两件都改**：
#   - 目录用 `-LiteralPath` 显式列出（不用任何通配符）；
#   - 扩展名在循环里**自己判断**，不依赖 `-Include`。
#
# 这个缺陷是"故意放一个 CRLF 的 .dart 文件，检查依然报 OK"暴露出来的。
# **教训：门禁自己被验证过吗**？一个永远通过的检查比没有检查更危险，
# 因为它会让人以为这件事有人管。

# 目录 → 该目录下要检查的扩展名
$scan = @()
$scan += , @{ Dir = 'client';  Ext = @('.rs') }
$scan += , @{ Dir = 'server';  Ext = @('.rs') }
$scan += , @{ Dir = 'shared';  Ext = @('.rs') }
$scan += , @{ Dir = 'client';  Ext = @('.dart') }
$scan += , @{ Dir = 'client';  Ext = @('.sql') }
$scan += , @{ Dir = 'client';  Ext = @('.yaml', '.yml') }
$scan += , @{ Dir = 'scripts'; Ext = @('.ps1') }
$scan += , @{ Dir = '.';       Ext = @('.md') }

# 根级单文件（没有扩展名或需要精确指定）
$singleFiles = @()
$singleFiles += 'justfile'
$singleFiles += '.gitattributes'

# 不扫这些子树：生成物或第三方，改了也会被重新生成。
# `target` 与 `build` 必须排除：client/target 下有几十万个构建产物。
# 平台工程目录（ios/macos/linux/windows/web/android）是 Flutter 生成的，
# 与我们的源码无关。
$excludeDir = '[\\/](target|node_modules|\.git|build|\.dart_tool|dist|ephemeral|ios|macos|linux|windows|web|android)[\\/]'

$targets = @()
foreach ($entry in $scan) {
    $dir = Join-Path $root $entry.Dir
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $found = Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue
    foreach ($f in $found) {
        if ($f.FullName -match $excludeDir) { continue }
        # 扩展名**自己判断**，不依赖 -Include（见文件头原因二）
        $ext = $f.Extension.ToLowerInvariant()
        if ($ext -eq '') { continue }
        if ($entry.Ext -contains $ext) { $targets += $f }
    }
}

foreach ($name in $singleFiles) {
    $p = Join-Path $root $name
    if (Test-Path -LiteralPath $p) {
        $targets += Get-Item -LiteralPath $p
    }
}

$targets = $targets | Sort-Object FullName -Unique

# ---------------------------------------------------------------------------
# 自检：覆盖范围必须真的包含源码
# ---------------------------------------------------------------------------
#
# 这一条是为了防"又一次静默失效"：如果哪天有人改了上面的路径或扩展名，
# 让源码重新落到覆盖范围之外，这里会**直接失败**而不是打印一个假 OK。
$required = @()
$required += , @{ Name = 'Rust'; Pattern = '\.rs$' }
$required += , @{ Name = 'Dart'; Pattern = '\.dart$' }
$required += , @{ Name = 'SQL';  Pattern = '\.sql$' }

foreach ($req in $required) {
    $n = ($targets | Where-Object { $_.Name -match $req.Pattern } | Measure-Object).Count
    if ($n -eq 0) {
        Write-Host ("FAIL: no " + $req.Name + " files were scanned - the coverage list is broken.")
        Write-Host "      A gate that silently scans nothing is worse than no gate."
        exit 1
    }
}

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
    $nRust = ($targets | Where-Object { $_.Name -match '\.rs$' } | Measure-Object).Count
    $nDart = ($targets | Where-Object { $_.Name -match '\.dart$' } | Measure-Object).Count
    $nSql = ($targets | Where-Object { $_.Name -match '\.sql$' } | Measure-Object).Count
    Write-Host ("OK: all " + $targets.Count + " files use LF (rust=" + $nRust +
        " dart=" + $nDart + " sql=" + $nSql + ")")
    exit 0
}

Write-Host ("done: fixed " + $fixed + " of " + $targets.Count + " files")
