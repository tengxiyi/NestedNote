# 生成 FFI 绑定并规范化其格式。
#
# 为什么需要这个脚本（而不是直接在 CI 里写两行命令）：
#
#   `flutter_rust_bridge_codegen` 产出的 `src/frb_generated.rs` 的 import 顺序
#   不符合 rustfmt 的期望。而 CI 的流程是"先 codegen、再 cargo fmt --check"，
#   于是这个差异**每次都会复现**，形成永远修不好的假失败。
#
#   可选做法有三种，本脚本采用第三种：
#     1. rustfmt 的 `ignore = [...]` —— 需要 nightly，stable 上会被忽略（已实测）；
#     2. `#[rustfmt::skip]` —— 生成文件顶部由 codegen 写入 `#![allow(...)]`，
#        手工插入的属性会在下次生成时被覆盖；
#     3. **用 rustfmt 规范化生成物**（本脚本）—— 不手工编辑文件内容，
#        只让样式器统一格式；幂等、可重复，且本地与 CI 走同一条路径。
#
# 用法（仓库根目录）：
#   powershell -NoProfile -File scripts/generate-ffi-bindings.ps1
#   powershell -NoProfile -File scripts/generate-ffi-bindings.ps1 -Check
#
#   -Check  只检查生成物是否已存在且格式正确，不修改文件（CI 用）
#
# 输出使用 ASCII，避免 Windows PowerShell 5.1 的编码问题。

[CmdletBinding()]
param(
    [switch]$Check,
    # 跳过 codegen，只做格式规范化（本地已生成过时用）
    [switch]$SkipCodegen
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$flutterDir = Join-Path $root 'client/apps/flutter'
$rustDir = Join-Path $root 'client/apps/rust'
$generated = Join-Path $rustDir 'src/frb_generated.rs'

if (-not (Test-Path -LiteralPath $flutterDir)) {
    Write-Host "FAIL: flutter app not found at $flutterDir"
    exit 1
}

# ---------------------------------------------------------------- 版本一致性
# codegen 的版本必须与 pubspec 里声明的 flutter_rust_bridge 严格一致，
# 否则生成的桥接代码与 Dart 侧运行库不匹配，会在编译或运行期失败。
Write-Host "== 1/3 check version pin =="
$pubspec = Get-Content -LiteralPath (Join-Path $flutterDir 'pubspec.yaml') -Raw -Encoding UTF8
$match = [regex]::Match($pubspec, 'flutter_rust_bridge:\s*\^([0-9]+\.[0-9]+\.[0-9]+)')
if (-not $match.Success) {
    Write-Host "FAIL: cannot find flutter_rust_bridge version in pubspec.yaml"
    exit 1
}
$pinned = $match.Groups[1].Value
Write-Host "pubspec 声明的版本: $pinned"

$codegen = 'flutter_rust_bridge_codegen'
$codegenCmd = Get-Command $codegen -ErrorAction SilentlyContinue
if (-not $codegenCmd) {
    Write-Host "FAIL: $codegen not found on PATH."
    Write-Host "install it with:"
    Write-Host "  cargo install $codegen --version $pinned --locked"
    exit 1
}
$actual = (& $codegen --version 2>&1 | Select-Object -First 1)
Write-Host "已安装的 codegen   : $actual"
if ($actual -notmatch [regex]::Escape($pinned)) {
    Write-Host "FAIL: version mismatch — pubspec wants $pinned but installed codegen is '$actual'"
    Write-Host "fix: cargo install flutter_rust_bridge_codegen --version $pinned --locked"
    exit 1
}

if ($Check) {
    Write-Host ""
    Write-Host "== 2/3 check generated file exists =="
    if (-not (Test-Path -LiteralPath $generated)) {
        Write-Host "FAIL: $generated does not exist."
        Write-Host "run without -Check to generate it."
        exit 1
    }
    Write-Host "OK: generated file present"
}
else {
    Write-Host ""
    Write-Host "== 2/3 generate bindings =="
    if ($SkipCodegen) {
        Write-Host "skipped (-SkipCodegen)"
    }
    else {
        Push-Location $flutterDir
        try {
            & $codegen generate
            if ($LASTEXITCODE -ne 0) {
                Write-Host "FAIL: codegen returned $LASTEXITCODE"
                exit 1
            }
        }
        finally {
            Pop-Location
        }
    }
    if (-not (Test-Path -LiteralPath $generated)) {
        Write-Host "FAIL: codegen did not produce $generated"
        exit 1
    }
}

# ---------------------------------------------------------------- 规范化格式
Write-Host ""
Write-Host "== 3/3 normalize generated code style =="
Push-Location $rustDir
try {
    if ($Check) {
        & cargo fmt --all -- --check
        if ($LASTEXITCODE -ne 0) {
            Write-Host "FAIL: generated code is not rustfmt-clean."
            Write-Host "fix: run this script without -Check"
            exit 1
        }
        Write-Host "OK: generated code is rustfmt-clean"
    }
    else {
        & cargo fmt --all
        if ($LASTEXITCODE -ne 0) {
            Write-Host "FAIL: cargo fmt returned $LASTEXITCODE"
            exit 1
        }
        # 再次校验，确保幂等（跑一次 fmt 就应当稳定）
        & cargo fmt --all -- --check
        if ($LASTEXITCODE -ne 0) {
            Write-Host "FAIL: cargo fmt is not idempotent on the generated file"
            exit 1
        }
        Write-Host "OK: normalized and verified idempotent"
    }
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "done."
