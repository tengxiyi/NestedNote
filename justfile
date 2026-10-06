# 拾光笔记 / NestedNote —— 统一任务入口
#
# 用法：
#   just                列出全部任务
#   just check          提交前必跑：格式 + lint + 测试 + 铁律检查
#   just check-all      额外包含覆盖率门禁（CI 的完整等价流程）
#   just check-client   只跑客户端（Rust 侧）
#   just check-server   只跑服务端
#   just coverage       与 CI 相同口径的覆盖率门禁
#   just ci             查看 GitHub Actions 最近结果
#
# 为什么用 justfile：铁律 B4（构建必须可复现）要求"同一 commit 在任何机器上
# 得到相同结果"，因此把命令固定在这里，而不是散落在各人的终端历史里。
#
# 为什么 shell 用 powershell 而不是 pwsh：PowerShell 7 并非所有开发机都装了，
# 而 Windows 自带 powershell.exe。scripts/*.ps1 刻意只用两者都支持的语法
# （脚本含中文时**必须**带 UTF-8 BOM，否则 PS 5.1 会按 ANSI 解码并破坏语法，
#  这条由 nested-rules 的 B-ENCODING 规则自动检查）。

set shell := ["powershell", "-NoProfile", "-Command"]
set windows-shell := ["powershell", "-NoProfile", "-Command"]

client_dir := "client"
server_dir := "server"

# 列出全部任务
default:
    @just --list

# ---------------------------------------------------------------- 全量检查

# 提交前必跑（等价于 CI 的快速门禁，不含覆盖率）
check: check-format check-lint check-rules test
    @echo "全部检查通过。"

# CI 的完整等价流程（多一项覆盖率门禁）
check-all: check coverage
    @echo "全部检查（含覆盖率）通过。"

# 客户端（Rust 侧）单独检查
check-client:
    @echo "== client: fmt / clippy / test =="
    cd {{client_dir}} && cargo fmt --all -- --check
    cd {{client_dir}} && cargo clippy --workspace --all-targets -- -D warnings
    cd {{client_dir}} && cargo test --workspace

# 服务端单独检查
check-server:
    @echo "== server: fmt / clippy / test =="
    cd {{server_dir}} && cargo fmt --all -- --check
    cd {{server_dir}} && cargo clippy --workspace --all-targets -- -D warnings
    cd {{server_dir}} && cargo test --workspace

# 格式检查（铁律 R8 / F12）
check-format:
    @echo "== 行尾规范 =="
    powershell -NoProfile -File scripts/normalize-line-endings.ps1 -Check
    @echo "== Rust 格式 =="
    cd {{client_dir}} && cargo fmt --all -- --check
    cd {{server_dir}} && cargo fmt --all -- --check

# lint（铁律 R7 / F2）
check-lint:
    @echo "== clippy: client =="
    cd {{client_dir}} && cargo clippy --workspace --all-targets -- -D warnings
    @echo "== clippy: server =="
    cd {{server_dir}} && cargo clippy --workspace --all-targets -- -D warnings

# 铁律自动检查（分层、裸 SQL、产品代码 panic、脚本编码等）
check-rules:
    powershell -NoProfile -File scripts/check-rules.ps1

# ---------------------------------------------------------------- 测试与覆盖率

# 两端全量测试
test: test-client test-server
    @echo "两端测试通过。"

test-client:
    @echo "== test: client =="
    cd {{client_dir}} && cargo test --workspace

test-server:
    @echo "== test: server =="
    cd {{server_dir}} && cargo test --workspace

# 覆盖率门禁（铁律 Z1：已实现的 crate 行覆盖率 ≥ 80%）
# 门禁清单与豁免理由见 scripts/coverage-gate.ps1 头部注释
coverage:
    powershell -NoProfile -File scripts/coverage-gate.ps1

# 只报告覆盖率、不判失败（本地排查用）
coverage-report:
    powershell -NoProfile -File scripts/coverage-gate.ps1 -ReportOnly

# ---------------------------------------------------------------- FFI

# 生成 FFI 绑定并规范化格式（改过 apps/rust/src/api 后必须执行）
bindings:
    powershell -NoProfile -File scripts/generate-ffi-bindings.ps1

# ---------------------------------------------------------------- 构建与运行

build:
    cd {{client_dir}} && cargo build --workspace
    cd {{server_dir}} && cargo build --workspace

build-release:
    cd {{client_dir}} && cargo build --release --workspace
    cd {{server_dir}} && cargo build --release --workspace

# 运行服务端（需要 DATABASE_URL 才会就绪）
run-server:
    cd {{server_dir}} && cargo run -p server

# 客户端 CLI：版本信息
cli-version:
    cd {{client_dir}} && cargo run -p nested-cli -- version

# 客户端 CLI：数据目录自检
cli-doctor dir="":
    cd {{client_dir}} && cargo run -p nested-cli -- doctor {{ if dir == "" { "" } else { "--data-dir " + dir } }}

# 客户端 CLI：初始化数据目录
cli-init dir="":
    cd {{client_dir}} && cargo run -p nested-cli -- init {{ if dir == "" { "" } else { "--data-dir " + dir } }}

# ---------------------------------------------------------------- 桌面应用

# 打包 Windows 桌面应用
# 产物：client/apps/flutter/build/windows/x64/runner/Release/nested.exe
# 说明：Cargokit 会在构建过程中自动编译 Rust 内核并打进产物目录，无需先手动 cargo build。
app-build:
    cd {{client_dir}}/apps/flutter && flutter build windows --release
    @echo "完成：{{client_dir}}\apps\flutter\build\windows\x64\runner\Release\nested.exe"

# 直接运行桌面应用（开发模式，支持热重载）
app-run:
    cd {{client_dir}}/apps/flutter && flutter run -d windows

# Flutter 侧静态分析与测试（含真实 FFI 集成测试，需先构建 release 动态库）
check-flutter:
    @echo "== flutter analyze =="
    cd {{client_dir}}/apps/flutter && flutter analyze
    @echo "== 构建 Rust 动态库 =="
    cd {{client_dir}} && cargo build --release -p nested_app
    @echo "== flutter test =="
    cd {{client_dir}}/apps/flutter && flutter test

# ---------------------------------------------------------------- 格式化

fmt:
    cd {{client_dir}} && cargo fmt --all
    cd {{server_dir}} && cargo fmt --all

# 规范化行尾（迁移文件必须 LF）
fix-eol:
    powershell -NoProfile -File scripts/normalize-line-endings.ps1

# ---------------------------------------------------------------- CI 与依赖

# 查看 GitHub Actions 最近结果（失败时带出日志尾部）
ci:
    powershell -NoProfile -File scripts/check-ci.ps1

# 审计依赖漏洞（铁律 S11）
audit:
    cd {{client_dir}} && cargo audit
    cd {{server_dir}} && cargo audit

# ---------------------------------------------------------------- 本地基础设施

# 启动开发用 PostgreSQL + MinIO
infra-up:
    docker compose -f {{server_dir}}/docker/docker-compose.yml up -d

infra-down:
    docker compose -f {{server_dir}}/docker/docker-compose.yml down

infra-logs:
    docker compose -f {{server_dir}}/docker/docker-compose.yml logs -f
