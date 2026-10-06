# 拾光笔记 / NestedNote

> **一款本地优先（Local-First）的跨平台笔记应用。**
> 拾起每一段时光，层层收好——笔记先安家在你的设备上，再谈云端同步。
> Windows ｜ macOS ｜ iOS ｜ Android

```text
Flutter UI  →  FFI  →  Rust Core（nested-*）  →  SQLite + FTS5  →  本地文件（CAS 附件）
                            │
                          HTTPS
                            │
                            ▼
                    Rust Sync Server（Axum + PostgreSQL + S3）
```

> **命名说明**：品牌名 **拾光笔记 / NestedNote**；仓库、crate、包名、数据库、环境变量使用工程标识 **`nested`**。
> 两者刻意分离，改名时通常只需动品牌层（见 [项目章程 §1.0](docs/00-项目章程.md)）。

---

## 当前状态

| 项 | 状态 |
|---|---|
| 阶段 | **P0 工程基座（已完成）** → 下一步 P1 Rust Core 数据内核 |
| 代码 | 客户端 10 个 crate + 服务端 6 个 crate + Flutter 应用源码骨架已建立 |
| 验证 | 客户端 **147** 个测试、服务端 **22** 个测试全部通过；两端 `fmt` 与 `clippy -D warnings` 干净 |
| 铁律门禁 | `nested-rules` 已可执行（7 条规则自动化 + 每条带单元测试） |
| Flutter | 应用源码已就位；平台目录需 Flutter 工具链（本机未安装），见「快速开始」 |
| 文档 | 项目章程 / 开发计划 / 工程铁律 / 总体技术方案 |

> 已实测通过的可运行闭环：`nested init` 建库并迁移 → `nested doctor` 自检 → 数据落盘重启不丢。

---

## 快速开始

### 环境要求

| 组件 | 版本 | 说明 |
|---|---|---|
| Rust | 1.92.0 | 由 `client/rust-toolchain.toml` 与 `server/rust-toolchain.toml` 自动锁定并安装 |
| MSVC 生成工具 | VS 2022/2026 Build Tools | Windows 上 Rust 链接所需（含 C++ 工作负载） |
| Flutter | stable（Dart ≥ 3.6） | **仅客户端 UI 需要**；Rust 内核与 CLI 不需要 |
| Docker | 可选 | 本地 PostgreSQL + MinIO（P6 同步阶段才需要） |

### 验证内核（无需 Flutter）

```powershell
# 1) 全量门禁：格式 + lint + 测试 + 铁律检查
just check                     # 未安装 just 时见下方分步命令

# 2) 分步执行
cd client; cargo test --workspace; cargo clippy --workspace --all-targets -- -D warnings
cd server; cargo test --workspace; cargo clippy --workspace --all-targets -- -D warnings
cargo run -p nested-rules -- --root ..        # 铁律检查（在 client 目录下执行）

# 3) 实测数据闭环
cd client
cargo run -p nested-cli -- version                       # 品牌与版本
cargo run -p nested-cli -- doctor --data-dir C:\tmp\nested   # 建库 + 迁移 + 自检
cargo run -p nested-cli -- doctor --data-dir C:\tmp\nested   # 再跑一次：数据仍在

# 4) 服务端（不需要数据库也能启动，/readyz 会如实报未就绪）
cd server; cargo run -p server               # 监听 127.0.0.1:8080
curl http://127.0.0.1:8080/healthz           # {"status":"ok"}
curl -i http://127.0.0.1:8080/readyz         # 503（未配置 DATABASE_URL）
```

### 生成 Flutter 平台工程（首次配置时执行一次）

```powershell
pwsh scripts/bootstrap-flutter.ps1          # 检查工具链并生成 windows/macos/ios/android
pwsh scripts/build-rust-for-flutter.ps1     # 构建 Rust 静态库并放到平台工程可链接的位置
cd client/apps/flutter; flutter run -d windows
```

> 平台目录（`windows/ macos/ ios/ android/`）由 `flutter create` 生成，生成后随仓库提交。

---

## 文档导航（先读这三份）

| 文档 | 内容 | 什么时候读 |
|---|---|---|
| [00-项目章程](docs/00-项目章程.md) | 项目名与命名规范、目标、非目标、北极星指标、技术基线 | **第一次接触项目时** |
| [01-开发计划](docs/01-开发计划.md) | P0–P7 阶段任务、交付物、DoD、Gate 晋级标准、风险登记册 | **每次开工前** |
| [02-工程铁律](docs/02-工程铁律.md) | 十条总纲 + 14 组强制规则 + 门禁与豁免流程 | **每次提交代码前** |
| [总体技术方案](跨平台Evernote类笔记应用_项目实施技术文档.md) | 架构、Document Model、数据库、搜索、同步、性能的完整设计 | 需要设计细节时 |

**文档优先级（冲突时以左为准）**：

```text
02-工程铁律.md  >  00-项目章程.md  >  总体技术方案  >  docs/design/*  >  代码注释
```

---

## 六条最重要的规则（铁律摘要）

1. **数据不可丢** —— 任何性能与速度理由都不能排在数据完整性之前。
2. **阶段串行** —— 上一个阶段没过 Gate，不写下一个阶段的代码。
3. **本地优先** —— 先写本地、立即更新 UI，后台再同步。
4. **Rust Core 是唯一事实来源** —— Flutter 不碰 SQLite，不碰业务规则。
5. **文档模型优先** —— HTML/Markdown 只是投影，Block Model 才是真相。
6. **全过程可验证** —— 无测试的逻辑不合并，无验收标准的任务不开工。

完整版本见 [工程铁律](docs/02-工程铁律.md)。

---

## 仓库结构（Monorepo，客户端与服务端物理隔离）

```text
nested/
├── client/                       ← 客户端：Flutter UI + Rust Core + CLI
│   ├── Cargo.toml                客户端独立 workspace（自带 Cargo.lock）
│   ├── apps/flutter/             Flutter 应用（windows / macos / ios / android）
│   ├── apps/rust/                FFI 桥接层（nested-app，cdylib/staticlib）
│   ├── crates/
│   │   ├── nested-core/          Domain Service（业务 API 入口）
│   │   ├── nested-model/         领域模型 + Document Model
│   │   ├── nested-db/            SQLite + migration + Repository
│   │   ├── nested-search/        FTS5 全文搜索
│   │   ├── nested-attachment/    内容寻址附件存储
│   │   ├── nested-import/        Markdown / HTML / TXT / ENEX 导入
│   │   ├── nested-export/        Markdown / HTML / JSON 导出 + 备份
│   │   ├── nested-sync/          同步引擎（P6）
│   │   └── nested-crypto/        加密与平台密钥存储
│   ├── cli/                      nested-cli：无 UI 的内核验证与运维工具
│   ├── tools/nested-rules/       铁律自动检查器（零依赖，带单元测试）
│   └── migrations/               本地 SQLite 迁移
│
├── server/                       ← 服务端：Rust Sync Server
│   ├── Cargo.toml                服务端独立 workspace（自带 Cargo.lock）
│   ├── app/                      可执行入口（nested-server）
│   ├── crates/
│   │   ├── server-core/          配置、错误、可观测性
│   │   ├── server-api/           HTTP 层（Axum 路由与中间件）
│   │   ├── server-auth/          认证与设备
│   │   ├── server-sync/          同步逻辑（P6）
│   │   └── server-storage/       PostgreSQL / 对象存储
│   ├── migrations/               服务端 PostgreSQL 迁移
│   └── docker/                   Dockerfile + docker-compose（api + postgres + minio）
│
├── shared/protocol/              跨端**纯数据契约**（无 IO，两端唯一共享物）
├── scripts/                      引导与行尾规范化脚本
├── docs/
│   ├── 00-项目章程.md
│   ├── 01-开发计划.md
│   ├── 02-工程铁律.md
│   ├── tech-debt.md              技术债登记表
│   ├── adr/                      架构决策记录
│   ├── design/                   模块详细设计
│   └── reports/                  Gate 评审 / 性能与内存报告
├── justfile                      统一任务入口
└── CHANGELOG.md
```

> **为什么客户端与服务端是两个独立 Cargo workspace**：依赖永不互串（客户端不编译 axum/sqlx，服务端不编译 rusqlite）、构建互不拖慢、发布节奏独立、安全边界清晰、CI 可分流。
> 代价是无法用一条 `cargo test --workspace` 覆盖两端 → 用 `just check` 与 CI 的两套作业补齐。详见[技术文档 §4.1](跨平台Evernote类笔记应用_项目实施技术文档.md)。
>
> **硬约束**：两端唯一允许共享的是 `shared/protocol` 里的纯数据契约；客户端禁止依赖服务端 crate，反之亦然。该约束由 `nested-rules` 的 A-ISOLATION 检查自动强制（`shared/protocol` 因此不属于任何一侧 workspace）。

---

## 常用任务（justfile）

```bash
just                    # 列出全部任务
just check              # 提交前必跑：格式 + lint + 测试 + 铁律检查
just test-client        # 只跑客户端
just test-server        # 只跑服务端
just cli-version        # 客户端 CLI 版本信息
just cli-doctor DIR     # 数据目录自检
just run-server         # 启动同步服务
just infra-up           # 本地 PostgreSQL + MinIO（P6 需要）
just audit              # 依赖漏洞审计（铁律 S11）
```

> 未安装 `just` 时，直接执行 README「快速开始」中的分步命令即可，二者等价。

---

## 许可与数据主权

- 用户数据存放于本地（`nested.db` + `attachments/`），**默认不上传任何内容**。
- 云同步、AI 等涉及数据离开设备的能力**必须**显式开启（见铁律 S9）。
- 完整备份格式为开放结构：`backup/{manifest.json, notes/, attachments/, metadata/}`，随时可迁移出本应用。
