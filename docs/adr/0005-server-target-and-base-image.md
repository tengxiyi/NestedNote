# ADR 0005：不锁定 musl 目标，服务端镜像用 Debian 基础

- **状态**：已接受
- **日期**：项目 P0 阶段
- **决策者**：项目负责人
- **相关**：`server/rust-toolchain.toml`、`server/docker/Dockerfile`

## 背景

规划服务端容器化时，一个常见做法是"静态链接 + Alpine 镜像"：
Alpine 基础镜像只有约 5 MB，配合 musl 静态二进制可以得到极小的最终镜像。
因此最初的 `server/rust-toolchain.toml` 里写了：

```toml
targets = ["x86_64-unknown-linux-musl"]
```

这带来两个问题：

1. **工具链漂移**：在 Windows 开发机上，`rustup` 会因为这个声明去安装
   musl 目标。P0 首次构建时，`cargo` 花了 15 分钟同步并下载工具链组件，
   表现为"命令卡住"，排查成本很高。
2. **实际并未使用**：项目当前没有任何构建流程在编译 musl 目标——
   Dockerfile 用的是 `cargo build --release` 的默认目标。
   一个**声明了却没人用**的目标，只会在每次工具链操作时增加下载与失败面。

## 决策

1. 移除 `server/rust-toolchain.toml` 中的 `targets` 声明，只锁定 `channel`。
   需要交叉编译特定目标时，用一次性命令 `cargo build --target ...` 或
   在 CI 作业里显式 `rustup target add`。
2. 服务端运行镜像使用 **`debian:bookworm-slim`（glibc）**，而不是 Alpine。
   构建阶段用 `rust:1.92-slim`，与开发机工具链同版本。
3. 镜像体积优化推迟到有基准数据之后（铁律 P2：先测量再优化）。
   届时的正确做法是引入 `cargo-chef` 做依赖层缓存，再评估 distroless/musl。

## 备选方案

| 方案 | 优点 | 为什么不选 |
|---|---|---|
| 保留 musl 目标 + Alpine 运行时 | 镜像小（~20 MB 级）、无 glibc 依赖 | 需要额外的 musl 交叉编译工具链；当前阶段收益（镜像体积）远小于成本（构建复杂度与失败面） |
| 保留 musl 声明但不使用 | 未来"想用就用" | 让每次工具链操作都多下载一个组件，且掩盖了"声明即承诺"的原则 |
| 用 `scratch` 基础镜像 + 完全静态二进制 | 最小 | 需要 musl 静态链接，且丢失 CA 证书与调试工具，排查线上问题更难 |

## 后果

**变好了**：

- 工具链安装更快、失败面更小（这是 P0 实测踩到的坑）；
- 构建与开发环境同版本、同 libc，避免"本地能跑容器里不能跑"；
- Dockerfile 简单到一眼能读懂。

**变坏了 / 成本**：

- 镜像体积比 Alpine 方案大约 60–80 MB（含 CA 证书与基础系统）；
- 依赖 glibc，不能在 musl-only 环境运行（当前无此需求）。

**后续要做的**：

- P6 部署阶段做一次镜像体积基准，若确有必要再评估 musl 或 distroless；
- 若引入 musl，必须在 Dockerfile 内完成工具链安装，**不得**写回
  `rust-toolchain.toml`（避免再次拖慢本地工具链操作）。
