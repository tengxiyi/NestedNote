# 变更日志

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与 [语义化版本](https://semver.org/lang/zh-CN/)。

> 依据《工程铁律》B6：每次发布必须有 tag、版本号、变更日志与产物校验和。
> 数据格式或数据库结构有破坏性变更时，必须在对应版本中写明**是否可回退**（铁律 B9/B10）。

## [Unreleased]

### 新增（P1 开工准备：覆盖率基线 + 设计文档）

**测试覆盖率（铁律 Z1）**
- 新增 `scripts/coverage-gate.ps1` 并接入 CI：只对**已实现**的 crate 卡 80%，
  占位 crate 单独列出并写明"实现后必须并入清单"的原因，避免一刀切产生自欺指标
- 实测：nested-model 95.9%、nested-db 94.4%、nested-core 93.9%、
  nested-attachment 94.9%、nested-sync 100%、nested-rules 88.7%
- 客户端用例数由 149 增至 **204**

**详细设计文档（铁律 M1，共约 3100 行）**
- `docs/design/06-Document-Model设计.md` —— 13 种块类型逐字段、JSON 表示、
  行内标记的字节偏移取舍、格式版本演进规则、持久化与派生能力
- `docs/design/05-SQLite数据库设计.md` —— PRAGMA 基线逐项、10 张表逐列、
  22 条索引与查询路径对应、事务边界、迁移体系、损坏容错
- `docs/design/04-Rust-Core架构设计.md` —— 分层、12 个 crate 状态、
  `nested-core` 全部 24 个 `pub fn` 的 API 表、错误模型、FFI 契约、演进规则

**附件内容寻址存储（`nested-attachment`，P1 能力提前落地）**
- `ContentStore`：流式 SHA-256、写入去重、原子落盘（临时文件 → fsync → rename）、
  写后回读校验、`verify`/`delete`/`contains`
- 非法哈希返回结构化错误而不是 panic；临时文件与目标同目录以保证 rename 的原子性
- 21 个测试，含"路径布局必须与 `Attachment::storage_key` 一致"的交叉验证

**铁律检查器新增规则：B-ENCODING**
- 检查 `scripts/*.ps1` 是否"含非 ASCII 字符但没有 UTF-8 BOM"。
  Windows PowerShell 5.1 在无 BOM 时按 ANSI 解码，会**直接破坏脚本语法**——
  这个坑在本项目真实发生过三次，因此改由门禁强制

### 修复（设计文档撰写中审出的缺陷）
- `Document::searchable_text()` 把列表项文本收集两遍，导致 FTS5 索引内容重复、
  影响词频与相关度排序；已加回归测试 `searchable_text_collects_list_item_text_exactly_once`
- `nested-db` 迁移框架改为可注入清单（`apply()` + `apply_manifest()`），
  从而能真正测试失败路径：新增 5 个测试覆盖"迁移失败必须整体回滚""版本不得前进"
  "清单不自洽必须拒绝启动"
- 测试死锁：`failing_migration_keeps_previous_version_when_upgrading` 曾因持有连接锁
  再调 `check_integrity` 而挂死（已在 `Database::connection()` 的文档中写明这个陷阱）

### 变更
- `justfile` 补齐并修正：新增 `check-client` / `check-server` / `check-all` /
  `coverage` / `bindings` / `ci`；此前头部注释宣传了 `check-client`、`check-server`
  但并未定义（文档与实现不一致）
- 覆盖率门禁策略写入 `docs/reports/gate-p0.md` §4.1 与脚本头部注释

### 依赖
- 新增 `sha2` 0.10.9（RustCrypto）：附件内容寻址所需，与项目其它加密选型一致

### 数据与文档一致性
- 技术债登记表由 7 条扩至 **20 条**：设计文档审出的实现问题全部登记，
  含 3 项高危（#8 连接锁死锁陷阱、#10 事务行为不统一、#12 同步入队缺口）

## [P0] —— 工程基座（已通过 [Gate 评审](docs/reports/gate-p0.md))

**Flutter ↔ Rust 打通（P0-5）**
- 真实应用启动后由 Rust 建库、执行迁移、返回自检结果：
  `ready=true`、显示名「拾光笔记」（来自 Rust branding）、`schema v1`、`integrity ok`
- `flutter_rust_bridge` 2.13.0 接线完成：`flutter_rust_bridge.yaml`、
  Cargokit 构建插件（`rust_builder/`）、FFI crate 改名 `nested_app`
- 导出面收窄到 `nested_app::api` 一个模块，不会被内部函数意外暴露（铁律 A3）
- FFI 集成测试：`flutter test` 里真实加载动态库并在临时目录建库自检
- 生成物（`frb_generated.rs`、`lib/src/rust/**`）不入库，`.gitignore` 明确

**Flutter 工具链**
- `scripts/install-flutter.ps1`：下载 + SHA-256 校验 + 解压 + 配置 PATH + 启用桌面支持
  （用 `[Environment]::SetEnvironmentVariable` 而非 `setx`，后者会截断长 PATH）
- Flutter 3.47.6 stable / Dart 3.13.5；四平台工程已生成（windows/macos/ios/android）
- `pubspec.lock` 入库（铁律 B1）
- 修正 pubspec 依赖为已核实版本（原约束是凭印象写的，与 pub.dev 不符）
- `flutter analyze` 0 issue；3 个测试通过

**仓库结构**
- 客户端与服务端拆分为**两个独立 Cargo workspace**（`client/`、`server/`），各自持有 `Cargo.lock` 与工具链锁定；`shared/protocol` 作为跨端唯一共享的纯数据契约独立成 crate（[ADR 0002](docs/adr/0002-split-client-server-workspaces.md)）
- 隔离约束自动化：客户端不得依赖服务端 crate/库，反之亦然

**客户端（Rust Core）**
- 11 个 crate：`nested-model`（块模型 + 领域实体）、`nested-db`（SQLite + 迁移 + 6 个仓储）、`nested-core`（Domain Service）、`nested-search`、`nested-attachment`、`nested-import`、`nested-export`、`nested-sync`、`nested-crypto`、`nested_app`（FFI 桥接）
- `nested-cli`：`version` / `doctor` / `init` 可用；未实现命令明确失败（不伪造成功）
- SQLite 基线：WAL、`foreign_keys=ON`、`busy_timeout`、参数化查询、`INTEGER` UTC 毫秒、BLOB UUIDv7
- 迁移体系：`include_str!` 内嵌 + 事务内按 `user_version` 顺序执行 + **哈希护栏**（[ADR 0003](docs/adr/0003-migration-hash-guard.md)）
- 数据完整性：写入原子化（笔记 + 文档 + 附件引用 + 修订 + 同步队列同事务）、软删除、内容寻址附件元数据去重

**服务端（Sync Server）**
- 6 个 crate：`server`（可执行入口）、`server-core`（配置/错误/日志）、`server-api`（Axum 路由）、`server-auth`、`server-sync`、`server-storage`（SQLx + 对象存储抽象）
- HTTP：`/healthz`（存活）、`/readyz`（就绪，依赖不满足时 503）、`/api/v1/version`（协议握手）
- PostgreSQL 初始迁移（users / devices / sessions / notes / revisions / attachments / sync_cursors）
- Dockerfile + docker-compose（PostgreSQL + MinIO），优雅停机

**工程基建**
- `nested-rules`：铁律自动检查器（Rust、零依赖、22 个单元测试）——产品代码 panic、裸 DELETE、插值 SQL、两端隔离、硬编码凭据、锁定文件、大文件（[ADR 0004](docs/adr/0004-rules-checker-in-rust.md)）
- CI（GitHub Actions）：变更检测 + 铁律检查 + 行尾规范 + 客户端/服务端双作业 + 依赖安全审计
- `justfile` 统一任务入口；`.gitattributes` 强制迁移文件 LF；`.env.example`

**文档 / 决策记录**
- ADR：0001 ADR 机制、0002 workspace 拆分、0003 迁移哈希护栏、0004 检查器用 Rust、0005 服务端目标与基础镜像
- Gate P0 评审记录（含证据、偏差、未完成项与 P1 入口条件）

### 变更
- 项目定名 **拾光笔记 / NestedNote**（中文名对标"印象笔记"命名路数；英文名点明"嵌套 + 笔记"）
- 确立**品牌名与工程标识分离**：品牌层用 `拾光笔记 / NestedNote`，工程层（仓库、crate、包名、数据库、环境变量）统一用 `nested`
- 仓库代号由 `note-app` 统一为 `nested`，Rust crate 统一为 `nested-*`
- **数据目录改为交给平台约定**（`path_provider`）：实测 Windows 为
  `%APPDATA%\app.nestednote\nested\`。原章程里手拼品牌子目录的做法已更新（章程 §1.4）
- clippy 策略：`unwrap_used`/`expect_used` 在 clippy 侧不阻断（测试代码必然误报），
  改由 `nested-rules` 的 R1 规则只对**产品代码**强制（[铁律附 A](docs/02-工程铁律.md)）

### 修复
- `Block::count_blocks` 未把列表项计入块数（嵌套列表统计偏小）
- `ReadyResponse.checks` 使用 `Vec<(&'static str, bool)>` 导致无法反序列化，改为 `Vec<(String, bool)>`
- Cargokit 接线：crate 名 `nested-app`（连字符）与 cargo 输出 `nested_app.dll`（下划线）
  错配导致 dll 编译成功但**未被打包**；统一命名为 `nested_app` 修复
- `scripts/*.ps1` 加 UTF-8 BOM：Windows PowerShell 5.1 只在有 BOM 时按 UTF-8 解码，
  否则按 ANSI 解码会**破坏脚本语法**

### 破坏性变更
- 无（尚未有对外数据格式与发布产物）

---

## 版本规划（里程碑，非实际发布）

| 版本 | 对应阶段 | 内容概要 | 是否可回退 |
|---|---|---|---|
| `v0.1.0` | P1 | Rust Core 内核 + CLI（无 UI） | 不适用（未发布给用户） |
| `v0.2.0` | P2 | 桌面 MVP：列表 + 编辑 + 自动保存 | 是 |
| `v1.0.0` | P3+P4 | 桌面完整版，第一阶段验收 14 条通过 | 是 |
| `v1.5.0` | P5 | Android / iOS | 是 |
| `v2.0.0` | P6 | 云同步、多设备 | **需评估**（同步数据不可随意回退） |
| `v2.x` | P7 | OCR / 版本历史 / AI / 语义搜索 / 自托管 | 逐特性评估 |
