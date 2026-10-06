# ADR 0002：客户端与服务端使用两个独立 Cargo workspace

- **状态**：已接受
- **日期**：项目 P0 阶段
- **决策者**：项目负责人
- **相关**：[技术文档 §4.1](../../跨平台Evernote类笔记应用_项目实施技术文档.md)、铁律 A-ISOLATION

## 背景

项目是 Monorepo，同时包含客户端（Flutter UI + Rust Core + CLI）与服务端（Axum + SQLx）。
仓库需要一个物理结构来回答几个问题：

1. 如何保证"客户端不依赖服务端库、服务端不依赖客户端实现"这条硬约束？
2. 如何让两端的依赖与发布节奏互不干扰？
3. CI 如何避免"改一行客户端代码却要编译 SQLx"？

这些不是纯洁癖问题。在 P0 探测依赖版本时就真实撞上了：当客户端与服务端的依赖放在
同一个 Cargo 依赖图里解析时，`rusqlite` 被 `sqlx` 携带的 `libsqlite3-sys` 版本约束
**压回了旧版本 0.32.1**（最新为 0.40.2）。也就是说，两端共用一个 workspace 会让
"服务端引入一个间接依赖"直接改变"客户端使用的 SQLite 版本"——这是不可接受的耦合。

## 决策

仓库顶层按交付边界分为两个**互相隔离**的 workspace，各自持有 `Cargo.lock`：

```text
client/Cargo.toml    客户端 workspace（apps/rust、cli、tools/nested-rules、crates/nested-*）
server/Cargo.toml    服务端 workspace（app、crates/server-*）
shared/protocol/     独立 crate，不属于任何一侧
```

配套约定：

1. **根目录不放 `Cargo.toml`**（否则会变成第三个 workspace，产生歧义）。
2. `shared/protocol` 是**唯一**允许跨端共享的代码，且必须是纯数据契约
   （禁止 IO/数据库/网络依赖）；它刻意独立成 crate，不属于任何一侧 workspace。
3. 两端各自锁定 Rust 工具链版本（`rust-toolchain.toml`），可独立升级。
4. 隔离约束由 `client/tools/nested-rules` 的 `A-ISOLATION` 检查自动强制。
5. CI 用两个作业分别检查两端，并通过 `paths-filter` 做变更检测。

## 备选方案

| 方案 | 优点 | 为什么不选 |
|---|---|---|
| 单一根 workspace 包含全部 crate | 一条 `cargo test --workspace` 覆盖全部；依赖版本绝对一致；CI 更简单 | 依赖互相污染（实测 rusqlite 被降级）；客户端改动触发服务端重编译；安全边界模糊；违反"服务端不得成为单机功能依赖"的设计意图 |
| 两个 workspace + 共享 crate 放进某一侧 | 少一个独立 crate 的维护成本 | 另一侧引用它就会跨越 workspace 边界，隔离形同虚设 |
| 拆成两个 Git 仓库 | 隔离最彻底 | 破坏 Monorepo 的原子提交（协议与两端改动无法一起评审），且发布仍需人工对齐版本 |
| 两个 workspace，但共享 crate 用 git 子模块 | 独立版本管理 | 子模块的开发者体验差，且对单人项目是过度工程 |

## 后果

**变好了**：

- 依赖永不互串：客户端不编译 axum/sqlx，服务端不编译 rusqlite（0.40.2 保住了）；
- 构建更快：只改一端时另一端不进编译图；
- 发布节奏独立：客户端随商店审核，服务端随部署；
- 安全边界清晰：服务端不可能"顺手"引用客户端的加密实现；
- 隔离是**可检查**的（A-ISOLATION），不靠自觉。

**变坏了 / 成本**：

- 根目录没有 `Cargo.toml`，不能用一条 `cargo test --workspace` 覆盖全仓 →
  用 `just check` 与 CI 的 `client`/`server` 双作业补齐；
- `shared/protocol` 不能使用 `workspace = true` 继承，依赖版本需在三处保持一致 →
  由 A-ISOLATION 检查与 Review 兜底（未来可考虑脚本校验版本一致）；
- 两份 `Cargo.lock` 需要分别做依赖升级（这其实是优点，但确实增加了操作步骤）。

**后续要做的**：

- 若将来出现第三个交付物（例如 Web 版），沿用同一模式新增顶层目录；
- 在 P6 引入协议字段时，确保改动只落在 `shared/protocol` 与两端各自的适配层。
