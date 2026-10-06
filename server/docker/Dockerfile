# 拾光笔记 / NestedNote —— 服务端镜像
#
# 构建（在**仓库根目录**执行，因为需要同时复制 client 之外的 shared/protocol）：
#   docker build -f server/docker/Dockerfile -t nested-server:dev .
#
# 为什么用 debian 而不是 alpine：
#   alpine 是 musl libc，需要额外的 musl 目标与交叉编译工具链；
#   本项目当前只锁定 windows-msvc 目标，用 debian-slim 可以保持"构建即部署"的简单性。
#   切换到 alpine 属于镜像体积优化，应在有基准数据后再做（铁律 P2）。

# ------------------------------------------------------------------ 构建阶段
FROM rust:1.92-slim AS builder

WORKDIR /build

# 先装编译期依赖（保持分层缓存：依赖不变时不会重新安装）
RUN apt-get update \
    && apt-get install -y --no-install-recommends pkg-config libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# 复制 workspace 清单（利用 Docker 层缓存：只改源码时不必重装依赖）
COPY server/Cargo.toml server/Cargo.lock ./server/
COPY shared/protocol/Cargo.toml ./shared/protocol/

# 创建占位源码，先编译依赖（这一层的缓存命中最有价值）
RUN mkdir -p server/app/src server/crates/server-core/src server/crates/server-api/src \
             server/crates/server-auth/src server/crates/server-sync/src \
             server/crates/server-storage/src server/migrations shared/protocol/src \
    && echo 'fn main() {}' > server/app/src/main.rs \
    && for crate in server-core server-api server-auth server-sync server-storage; do \
         echo '' > "server/crates/$crate/src/lib.rs"; \
       done \
    && echo '' > shared/protocol/src/lib.rs \
    && echo '-- placeholder' > server/migrations/0001_init.sql \
    && cd server && cargo build --release -p server || true

# 复制真实源码并正式构建
COPY shared/ ./shared/
COPY server/ ./server/
# 触摸源码，确保 cargo 重新编译（占位文件时间戳可能更新）
RUN find server/app/src server/crates shared/protocol/src -name '*.rs' -exec touch {} + \
    && find server/migrations -name '*.sql' -exec touch {} + \
    && cd server && cargo build --release -p server

# ------------------------------------------------------------------ 运行阶段
FROM debian:bookworm-slim AS runtime

# 运行时依赖：CA 证书（HTTPS 出站）、curl（容器健康检查）
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# 非 root 运行（铁律 S4：最小权限）
RUN useradd --system --create-home --uid 10001 nested

COPY --from=builder /build/server/target/release/nested-server /usr/local/bin/nested-server

USER nested
WORKDIR /home/nested

# 默认监听 8080（可用 NESTED_BIND_ADDR 覆盖）
ENV NESTED_BIND_ADDR=0.0.0.0:8080
ENV NESTED_LOG=info
EXPOSE 8080

# 健康检查指向 /healthz（存活）而不是 /readyz（就绪）：
# 依赖故障时不应让编排系统反复重启进程。
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl --fail --silent http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/nested-server"]
