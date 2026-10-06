# 拾光笔记 / NestedNote —— 统一任务入口
#
# 用法：
#   just                列出全部任务
#   just check          提交前必跑：格式 + lint + 测试 + 铁律检查
#   just check-client   只跑客户端
#   just check-server   只跑服务端
#
# 为什么用 justfile：铁律 B4（构建必须可复现）要求"同一 commit 在任何机器上
# 得到相同结果"，因此把命令固定在这里，而不是散落在各人的终端历史里。
#
# 为什么 shell 用 powershell 而不是 pwsh：PowerShell 7 并非所有开发机都装了，
# 而 Windows 自带 powershell.exe。scripts/*.ps1 刻意只用两者都支持的语法，
# 且用户可见输出使用 ASCII（Windows PowerShell 5.1 会把无 BOM 的 UTF-8 脚本
# 按 ANSI 解码，中文会乱码）。

set shell := ["powershell", "-NoProfile", "-Command"]
set windows-shell := ["powershell", "-NoProfile", "-Command"]

client_dir := "client"
server_dir := "server"

# 列出全部任务
default:
    @just --list

# ---------------------------------------------------------------- 全量检查

# 提交前必跑（等价于 CI 的主干门禁）
check: check-format check-lint check-rules test
    @echo "全部检查通过。"

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

# 铁律自动检查（分层、裸 SQL、产品代码 panic 等）
check-rules:
    powershell -NoProfile -File scripts/check-rules.ps1

# ---------------------------------------------------------------- 测试

# 两端全量测试
test: test-client test-server
    @echo "两端测试通过。"

test-client:
    @echo "== test: client =="
    cd {{client_dir}} && cargo test --workspace

test-server:
    @echo "== test: server =="
    cd {{server_dir}} && cargo test --workspace

# 覆盖率（铁律 Z1：核心 crate ≥ 80%）
coverage:
    cd {{client_dir}} && cargo llvm-cov --workspace --summary-only

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

# ---------------------------------------------------------------- 格式化

fmt:
    cd {{client_dir}} && cargo fmt --all
    cd {{server_dir}} && cargo fmt --all

# 规范化行尾（迁移文件必须 LF）
fix-eol:
    powershell -NoProfile -File scripts/normalize-line-endings.ps1

# ---------------------------------------------------------------- 依赖

# 审计依赖漏洞（铁律 S11）
audit:
    cd {{client_dir}} && cargo audit
    cd {{server_dir}} && cargo audit

# 本地基础设施：开发用 PostgreSQL + MinIO
infra-up:
    docker compose -f {{server_dir}}/docker/docker-compose.yml up -d

infra-down:
    docker compose -f {{server_dir}}/docker/docker-compose.yml down

infra-logs:
    docker compose -f {{server_dir}}/docker/docker-compose.yml logs -f
