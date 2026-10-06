# Rust Core 架构设计

> 本文件是《模块详细设计文档》的第 `04` 篇（顺序见 [design/README](README.md)），
> 描述客户端的 Rust 内核：分层、依赖方向、`nested-core` 公开 API、错误模型、FFI 契约、
> 约束的强制方式、API 演进规则与验证命令。
>
> **本文件的事实来源是代码本身**。文中每一个 crate 名、函数签名、错误码、常量与测试名，
> 都可以在下表列出的源文件中找到；凡"尚未实现"的部分都在第 10 章单独列出。

| 项 | 内容 |
|---|---|
| 适用范围 | `client/`（客户端独立 workspace），不含 `server/` 与 `shared/protocol` 的服务端侧用法 |
| 当前阶段 | **P0 已过 Gate**（见 [gate-p0 评审记录](../reports/gate-p0.md)）；P1 Rust Core 数据内核进行中 |
| 权威实现 | `client/crates/nested-core`、`client/crates/nested-*`、`client/apps/rust` |
| 强制条款 | [铁律](../02-工程铁律.md) T4 / T7 / T8、A1–A10、D1–D12、Q1–Q12、R1–R13、E1–E8、Z1–Z7、B1/B5 |
| 相关 ADR | [0002 客户端与服务端两个 workspace](../adr/0002-split-client-server-workspaces.md)、[0003 迁移哈希护栏](../adr/0003-migration-hash-guard.md)、[0004 铁律检查器用 Rust](../adr/0004-rules-checker-in-rust.md) |
| 关联设计文档 | `03-项目总体架构.md`、`06-SQLite数据库设计.md`（本文只描述"如何用"，不重复表结构） |

---

## 1. 架构总览

### 1.1 分层图

```text
┌──────────────────────────────────────────────────────────────────────┐
│ Flutter UI（client/apps/flutter/lib/app/**）                          │
│   EngineStatusPage 等页面：只渲染状态，不做数据判定                      │
└───────────────────────────┬──────────────────────────────────────────┘
                            │ 只能经 core/engine_providers.dart（唯一 FFI 接触点）
┌───────────────────────────▼──────────────────────────────────────────┐
│ FFI 边界                                                              │
│   生成侧：lib/src/rust/**  ⇄  client/apps/rust/src/frb_generated.rs    │
│   手写侧：client/apps/rust/src/api/**（唯一的跨语言契约面）             │
│     version_info() / display_name(language_tag) / start_engine(dir)    │
└───────────────────────────┬──────────────────────────────────────────┘
                            │ 普通 Rust 调用（同一进程、同一地址空间）
┌───────────────────────────▼──────────────────────────────────────────┐
│ nested-core —— Domain Service（业务语义的唯一入口）                     │
│   NestedCore：24 个公开方法（本文第 3 章逐个列出）                       │
│   错误：CoreError（8 个变体 + 稳定 code()）                             │
└───┬────────────┬────────────┬───────────┬────────────┬───────────────┘
    │            │            │           │            │
┌───▼────┐ ┌─────▼─────┐ ┌────▼─────┐ ┌───▼──────┐ ┌───▼──────────┐
│nested- │ │ nested-db │ │nested-   │ │nested-   │ │nested-sync   │
│model   │ │（唯一 SQL）│ │search    │ │attachment│ │nested-crypto │
│纯数据  │ │迁移/仓储  │ │FTS5 占位 │ │CAS 实现  │ │占位          │
└────────┘ └─────┬─────┘ └──────────┘ └──────────┘ └──────────────┘
                 │            （nested-import / nested-export 同属占位层）
┌────────────────▼─────────────────────────────────────────────────────┐
│ SQLite（`nested.db`，WAL + foreign_keys + busy_timeout）              │
│ 本地文件（`attachments/**`，P1 起；附件本体绝不进数据库，铁律 T8）      │
└──────────────────────────────────────────────────────────────────────┘

旁路（不在运行期调用链上）：
  client/cli（nested-cli）—— 直接依赖 nested-core，无 UI 的验收与运维入口
  client/tools/nested-rules —— 仓库级门禁，扫描源码与 Cargo.toml
```

> `nested-core/src/lib.rs` 的分层注释与上图一致：Flutter 通过 FFI 只与本 crate 对话，
> "上层看不到 SQL、表结构、文件布局或加密细节"。

### 1.2 依赖方向是单向的

允许的依赖（铁律 A1：`Flutter UI → FFI → Rust API → Domain Service → Repository → SQLite`）：

| 从 | 到 | 依据（代码事实） |
|---|---|---|
| Flutter (`lib/app`) | `lib/core/engine_providers.dart` | `app.dart` 只 `import '../core/engine.dart'` 与 `engine_providers.dart` |
| `engine_providers.dart` | 生成绑定 `lib/src/rust/**` | 该文件的头注释要求"除本文件外任何地方都不得 import（否则分层就失效了）"。**当前唯一例外**是 `test/ffi_integration_test.dart`（测试需要 `RustLib.init()`，见 §10.3 #13） |
| FFI 桥（`nested_app`） | `nested-core` | `client/apps/rust/Cargo.toml` 的 `nested-core.workspace = true` |
| `nested-core` | `nested-db` / `nested-model` | `api.rs` 中的 `use nested_db::…`、`use nested_model::…` |
| `nested-core` | `nested-search` / `-attachment` / `-import` / `-export` / `-sync` / `-crypto` / `protocol` | 仅存在于 `client/crates/nested-core/Cargo.toml` 的依赖声明（**尚无语代码引用**，见 §10） |
| `nested-db` | `nested-model` + `rusqlite` | `nested-db` 的仓储函数签名里只出现 `nested_model` 的类型 |

被禁止且**当前确实不存在**的反向依赖：

| 禁止 | 现状 |
|---|---|
| `nested-db` → `nested-core`（下层不能反向依赖上层） | `nested-db/Cargo.toml` 无 `nested-core` |
| 任何 `nested-*` → Flutter / 平台 UI | 各 `nested-*` 的 `Cargo.toml` 依赖只有内部 crate、`protocol` 与 `serde`/`serde_json`/`thiserror`/`tracing`/`rusqlite`/`uuid`/`time`/`sha2`——没有任何 Flutter、平台 UI 或窗口系统依赖（`nested-crypto` 目前甚至只有 `thiserror` + `tracing`）（铁律 A5） |
| 客户端 → 服务端（`server-*` / `sqlx` / `axum` / `tokio-postgres`） | `client/Cargo.toml` 的依赖清单中不存在；由 `nested-rules` 的 `A-ISOLATION` 检查强制（见 §7） |
| `shared/protocol` → IO / 数据库 / 网络 | 由 `A-ISOLATION` 检查 `shared/protocol/Cargo.toml`（禁止 `tokio`/`sqlx`/`axum`/`rusqlite`/`reqwest`/`hyper`） |

### 1.3 为什么 Flutter 不直接操作存储

引铁律 **T4**（Rust Core 是唯一事实来源：禁止 Flutter 直接访问 SQLite、直接读写数据文件、或实现业务规则）、
**A1**（依赖方向单向，禁止跨层调用）、**A2**（Flutter 禁止 import SQLite/文件路径/加密原语，禁止缓存权威数据）、
**A3**（FFI 只暴露业务语义）。落到本仓库，这条约束不是口号，而是四条可验证的事实：

1. **Flutter 侧没有存储依赖**。`client/apps/flutter/pubspec.yaml` 的依赖只有
   `flutter_rust_bridge` / `flutter_riverpod` / `path_provider` / `logging`——
   没有 `sqflite`、`drift`、`sqlite3` 之类的库，因此"直连数据库"在依赖层面就不可用。
2. **Flutter 只传目录字符串，不碰文件**。`engine_providers.dart` 用 `path_provider` 解析出应用专属目录后，
   把它作为 `String` 交给 `start_engine(data_dir)`；建库、迁移、PRAGMA、完整性校验全部发生在 Rust 侧。
3. **跨语言边界只有业务结构**（A4）。生成绑定的输入输出都是 `VersionInfo` / `EngineStatus` / `EngineCheck`，
   没有连接句柄、没有裸指针、没有 SQL 字符串（见 §5）。
4. **内核可以在没有 UI 的前提下被验证**。开发计划 P1 的 Gate 明确要求"在**没有任何 Flutter 代码**的前提下，
   用 CLI 完成一次完整生命周期"；`nested-cli` 直接依赖 `nested-core`，与 FFI 层平行，这只有在
   "业务事实集中在 `nested-core`" 时才成立。

一次"保存笔记"的完整数据流（同时体现 D1 原子写与 T6 变更可追踪）：

```text
UI：用户停止输入（debounce）
 → engine_providers → Rust FFI → NestedCore::save_note(note, document, device_id, at_ms)
   → Note::set_title / set_summary（校验）→ Note::touch(at_ms)（version += 1）
   → nested_db::repositories::notes::save_with_document
        ├─ 一个事务内：UPDATE notes / UPSERT documents / 同步 note_attachments
        ├─ INSERT revisions（version、device_id、"note.update"）
        └─ INSERT sync_operations（待推送，铁律 T3/T6）
 → 返回更新后的 Note（version 已递增）→ UI 显示新状态（本地优先，不等待网络）
```

---

## 2. crate 清单与职责边界

`client/` 是**独立的 Cargo workspace**（`client/Cargo.toml` 自带 `Cargo.lock`，仓库根目录**没有** `Cargo.toml`，
理由见 ADR 0002）。`[workspace] members` 当前列出 **12** 项：
`apps/rust`、`cli`、`tools/nested-rules` 与 `crates/nested-{core,model,db,search,attachment,import,export,sync,crypto}`。

> 说明：`README.md`「当前状态」与 `gate-p0.md` 写的是"客户端 11 个 crate"，
> 与 `members` 的 12 项不一致（差额是 `tools/nested-rules`）。**以 `client/Cargo.toml` 为准**，
> 该不一致已登记在 §10.3。

### 2.1 全部 crate

| crate（包名） | 位置 | 分层位置 | 职责 | 当前状态 |
|---|---|---|---|---|
| `nested-model` | `crates/nested-model` | 领域模型（最底层，纯数据） | 实体（`Notebook`/`Note`/`Tag`/`Attachment`/`Revision`）、块模型（`Block`/`Document`）、`Id`（UUIDv7）、`Timestamp`、校验与 `ModelError`。不碰库、不碰文件、不碰网络 | **已实现**（`#![forbid(unsafe_code)]`，模块 `block/document/entity/error/id/time` 齐备，含单元测试） |
| `nested-db` | `crates/nested-db` | Repository / 存储层 | **唯一允许写 SQL 的地方**（A7）：`Database`（打开、PRAGMA 基线、事务、`integrity_check`、`ping`、settings）、`migrations`（内嵌 SQL、版本连续性校验、**可注入清单**的 `apply_manifest`）、`repositories/*`（notebooks / notes / tags / attachments / revisions / sync_operations）、`rowmap`、`NoteQuery` | **已实现**（P1-5 ~ P1-11 的主体已落地：10 张表、迁移 `0001_init`、参数化查询、软删除；`db.rs` 10 个测试 + `migrations.rs` 11 个测试覆盖迁移回滚与拒载。FTS5 索引、GC、连接池仍缺） |
| `nested-core` | `crates/nested-core` | Domain Service（业务 API 入口） | 组合下层的 `NestedCore`、`CoreError`、`branding`（品牌唯一来源）；向 FFI/CLI 提供业务语义 API | **部分实现**：打开/自检/笔记本/笔记/标签/统计共 24 个方法已实现；搜索、附件、导入导出、同步、加密的业务 API **尚未暴露**（§10） |
| `nested-search` | `crates/nested-search` | 领域服务（FTS5） | `SearchQuery` / `SearchHit` / `SearchError` 类型定义 | **仅接口占位**：无任何查询实现。计划 **P1**（计划 P1-12 ~ P1-15，含 P1-13 中文分词方案对比基准 + ADR） |
| `nested-attachment` | `crates/nested-attachment` | 领域服务（CAS 附件） | 内容寻址存储：`hash_bytes` / `hash_file`（流式）/ `is_valid_hash`、`ContentStore::{new, root, path_for, contains, put_bytes, put_file, read, verify, delete}`、`StoredBlob`、`AttachmentError`、`ATTACHMENTS_DIR` / `THUMBNAILS_DIR` / `SHA256_HEX_LEN` | **crate 内已实现**（21 个测试：已知哈希向量、流式哈希、两级分片、去重、写后回读校验、损坏检测、幂等删除、与 `Attachment::storage_key` 布局交叉验证）；**但尚未被 `nested-core` 暴露**，因此 FFI/CLI/Flutter 现在还用不到（§10.1）。缩略图管线（P1-18）与引用计数 GC（P1-17）仍未实现 |
| `nested-import` | `crates/nested-import` | 领域服务（导入） | `ImportFormat`（含 `from_extension`）、`ImportedNote` / `ImportedAttachment`、`ImportError` | **仅接口占位**：无解析器。计划 **P1**（P1-20 ~ P1-23；Markdown/HTML/TXT/ENEX 与往返测试） |
| `nested-export` | `crates/nested-export` | 领域服务（导出/备份） | `ExportFormat`（含 `extension`）、`MANIFEST_FILE` / `BACKUP_DIRS`、`ManifestEntry` / `BackupManifest`（serde）、`ExportError` | **仅接口占位**：无导出与备份实现。计划 **P1**（P1-20 ~ P1-26）；`ExportFormat::Pdf` 的注释写明"P3 视依赖风险决定是否实现"（对应计划 P3-18） |
| `nested-sync` | `crates/nested-sync` | 领域服务（同步，客户端侧） | 常量 `DEVICE_ID_SETTING_KEY` / `PULL_CURSOR_KEY_PREFIX`、`SyncPhase` / `SyncReport` / `Conflict`、`SyncError`（含 `is_retryable`）、`client_protocol_version()` | **仅接口占位**：无 push/pull/冲突处理实现。计划 **P6**（计划 §7.2 P6-9 ~ P6-20） |
| `nested-crypto` | `crates/nested-crypto` | 领域服务（密钥与加密） | `KEYCHAIN_SERVICE` / `MASTER_KEY_ACCOUNT`、`SecretStore` trait（get/set/delete）、`CryptoError`（含 `NotImplemented`） | **空壳 + trait 定义**：无平台实现、无加密算法；方案（SQLCipher / 字段级 / 不加密）**待 ADR**。计划 **P1**（P1-30），移动端密钥存储随 **P5**（P5-9） |
| `nested_app` | `apps/rust` | FFI 桥接层 | 手写导出面 `src/api/**`（当前只有 `branding` 模块）与生成物 `src/frb_generated.rs`；`crate-type = ["cdylib","staticlib","lib"]` | **已实现最小面**：3 个函数 + 3 个结构体（§5）。随着 P2/P3 的业务 UI 展开而扩展 |
| `nested-cli`（bin：`nested`） | `cli` | 应用边界（非分层内，直连 `nested-core`） | `version` / `doctor` / `init` / `help`；P1 的验收主力；未实现子命令显式失败 | **部分实现**：`version`、`doctor`、`init`、`help` 可用；`seed/search/import/export/backup/restore/reindex/bench` 以明确错误退出（计划 **P1**，计划 §2.2 DoD 要求全部可用） |
| `nested-rules` | `tools/nested-rules` | 仓库门禁（不在运行期调用链） | 7 条铁律自动检查（R1/D2/Q4/A-ISOLATION/S3/B1/V6），lib + bin，零第三方依赖 | **已实现**（22 个单元测试；权威实现，`scripts/check-rules.ps1` 只是包装。B1/V6 目前无用例，见 §10.3 #12） |

### 2.2 依赖边与"声明了但没用"的部分（诚实记录）

`nested-core/Cargo.toml` 声明了对 `nested-search`、`nested-attachment`、`nested-import`、`nested-export`、
`nested-sync`、`nested-crypto`、`protocol` 的依赖，但 `nested-core/src/**` 当前**只真正使用** `nested-db` 与 `nested-model`
（`nested_sync::DEVICE_ID_SETTING_KEY` 只出现在 `api.rs` 的文档注释里）。同理 `apps/rust/Cargo.toml` 声明了
`serde` / `serde_json` / `thiserror` / `tracing` / `uuid` / `time`，而 `src/api/**` 目前只用到 `nested_core` 与 `protocol`。

这不是错误，而是"先把分层骨架立起来、再逐阶段填充"的刻意选择（依赖只在需要时才会被代码引用）；
但它意味着**"crate 已建好" ≠ "能力已存在"**，第 10 章因此逐条列出真实缺口。

---

## 3. nested-core 公开 API 清单

来源：`client/crates/nested-core/src/api.rs`（`impl NestedCore`），共 **24** 个 `pub fn`/`pub const fn`。
另有 `pub const UNKNOWN_DEVICE_ID: &str = "unknown-device"`（`api.rs`）与 `branding` 模块的
`display_name()` / `version_string()` 及 7 个 `pub const`（`branding.rs`），在 §3.7 与 §5 一并说明。
所有方法的错误类型都是 `CoreResult<T>`（即 `Result<T, CoreError>`），错误码见第 4 章。

### 3.1 生命周期与句柄

| 方法 | 签名 | 用途 | 参数含义 | 返回 | 可能的错误变体（code） |
|---|---|---|---|---|---|
| `open` | `fn open(data_dir: impl AsRef<Path>) -> CoreResult<Self>` | 在数据目录打开（或创建）内核：`create_dir_all` → 打开 `<dir>/nested.db` → 应用 PRAGMA 基线 → 执行迁移 | `data_dir`：数据目录；库文件名固定为 `branding::DATABASE_FILE`（`"nested.db"`） | `NestedCore` | `Config`（CONFIG_ERROR，目录不可创建）；`Database`（DATABASE_ERROR，打开或迁移失败，含 `SchemaTooNew` 等） |
| `open_in_memory` | `fn open_in_memory() -> CoreResult<Self>` | 内存库，用于测试与 CLI 快速验证（无文件、无 WAL） | — | `NestedCore` | `Database`（DATABASE_ERROR，迁移失败） |
| `database` | `pub const fn database(&self) -> &Database` | 暴露底层句柄，**仅供 CLI 与诊断**；文档注释明确"UI 层禁止直接使用（铁律 A2）" | — | `&Database` | 不会失败（`#[must_use]`） |
| `database_path` | `fn database_path(&self) -> Option<PathBuf>` | 数据库文件路径（界面/日志定位数据用） | — | `Some(PathBuf)`；内存库为 `None` | 不会失败（`#[must_use]`） |

### 3.2 诊断与自检

| 方法 | 签名 | 用途 | 参数含义 | 返回 | 可能的错误变体（code） |
|---|---|---|---|---|---|
| `schema_version` | `fn schema_version(&self) -> CoreResult<u32>` | 读取 `PRAGMA user_version` | — | `u32` | `Database`（DATABASE_ERROR） |
| `check_integrity` | `fn check_integrity(&self) -> CoreResult<()>` | 执行 `PRAGMA integrity_check` | — | `()` | `Database`（DATABASE_ERROR；非 ok 时为 `DbError::IntegrityCheckFailed`，细节在错误内部） |
| `readiness` | `fn readiness(&self) -> Vec<(&'static str, bool)>` | 逐项就绪自检，供 CLI `doctor` 与 UI 首屏使用 | — | 固定三项：`("database_open", ping 成功)`、`("schema_current", 版本可读)`、`("integrity", integrity_check 通过)` | 不会失败：每一项用自己的 `bool` 表达结果 |

### 3.3 笔记本

| 方法 | 签名 | 用途 | 参数含义 | 返回 | 可能的错误变体（code） |
|---|---|---|---|---|---|
| `create_notebook` | `fn create_notebook(&self, name: impl Into<String>, parent_id: Option<Id>, at_ms: i64) -> CoreResult<Notebook>` | 创建笔记本（可嵌套成树） | `name`：1 ~ `MAX_NOTEBOOK_NAME_CHARS`（256）字符；`parent_id`：`None` = 顶层；`at_ms`：UTC 毫秒 | `Notebook` | `Validation`（VALIDATION_ERROR，名称为空或超长）；`Database`（DATABASE_ERROR） |
| `get_notebook` | `fn get_notebook(&self, id: &Id) -> CoreResult<Notebook>` | 按标识读取笔记本 | `id`：UUIDv7 | `Notebook` | `NotFound { entity: "notebook" }`（NOT_FOUND）；`Database` |
| `list_notebooks` | `fn list_notebooks(&self) -> CoreResult<Vec<Notebook>>` | 列出全部未删除笔记本（`notebooks::list_all`） | — | `Vec<Notebook>` | `Database` |

### 3.4 笔记

| 方法 | 签名 | 用途 | 参数含义 | 返回 | 可能的错误变体（code） |
|---|---|---|---|---|---|
| `create_note` | `fn create_note(&self, notebook_id: Option<Id>, title: impl Into<String>, at_ms: i64) -> CoreResult<Note>` | 创建笔记，内容为空文档；内部转调 `create_note_with_document(…, Document::empty(at_ms), UNKNOWN_DEVICE_ID, at_ms)` | `notebook_id`：可为 `None`（未归类）；`title`：0 ~ `MAX_TITLE_CHARS`（512）字符，允许空串 | `Note`（`version = 1`） | `Validation`（标题超长）；`Database` |
| `create_note_with_document` | `fn create_note_with_document(&self, notebook_id: Option<Id>, title: impl Into<String>, document: Document, device_id: &str, at_ms: i64) -> CoreResult<Note>` | 创建笔记并指定初始内容；元数据 + 文档 + 附件引用 + 修订记录在**同一事务**写入（铁律 D1） | `document`：初始块模型；`device_id`：写入 `revisions.device_id`（`create_note` 会传 `UNKNOWN_DEVICE_ID`） | `Note` | `Validation`（标题超长）；`Database` |
| `get_note` | `fn get_note(&self, id: &Id) -> CoreResult<Note>` | 读取笔记元数据 | `id` | `Note` | `NotFound { entity: "note" }`（NOT_FOUND）；`Database` |
| `get_note_document` | `fn get_note_document(&self, id: &Id) -> CoreResult<Document>` | 读取笔记内容（块模型） | `id` | `Document` | `Database`（DATABASE_ERROR，含 `DbError::Corrupt`：内容无法解析为块模型）。**注意：目标笔记不存在时不返回 `NotFound`，而是返回空文档**（`notes::get_document` 的 `None` 分支为 `Document::empty(now_ms())`） |
| `list_notes` | `fn list_notes(&self, query: &NoteQuery<'_>) -> CoreResult<Vec<Note>>` | 按条件分页列出笔记，排序 `is_pinned DESC, updated_at_ms DESC` | `NoteQuery { notebook_id, include_deleted, archived, offset, limit }`：`notebook_id: Option<&Id>` 限定笔记本；`include_deleted` 是否含回收站；`archived: Option<bool>` 归档过滤；`limit == 0` 视为 50，且**永不超过** `MAX_PAGE_SIZE = 500`（`effective_limit()`） | `Vec<Note>` | `Database` |
| `save_note` | `fn save_note(&self, note: Note, document: Document, device_id: &str, at_ms: i64) -> CoreResult<Note>` | 保存元数据 + 内容；校验标题与摘要 → `touch(at_ms)`（`updated_at_ms = at_ms`、`version += 1`）→ 单事务写 `notes`/`documents`/`note_attachments`/`revisions`/`sync_operations`（铁律 D1/T6） | `note`：通常是 `get_note` 的返回值（`version` 以传入值为基础递增）；`document`：新内容；`device_id`：写入 revision 与同步队列 | 更新后的 `Note`（`version` 已 +1） | `Validation`（VALIDATION_ERROR：标题或摘要超长）；`Database`（DATABASE_ERROR，笔记已不存在时为 `DbError::NotFound`）。文档注释写作"笔记本标题/摘要非法"，实际校验的是**笔记**（`Note::set_title`/`set_summary`），属文案笔误（§10.3） |
| `delete_note` | `fn delete_note(&self, id: &Id, at_ms: i64) -> CoreResult<()>` | 移入回收站（软删除，写 `deleted_at_ms`，铁律 T7） | `id`；`at_ms` 同时作为 `updated_at_ms` | `()` | `NotFound`（NOT_FOUND：笔记不存在**或已在回收站**）；`Database` |
| `restore_note` | `fn restore_note(&self, id: &Id, at_ms: i64) -> CoreResult<()>` | 从回收站恢复（清空 `deleted_at_ms`） | 同上 | `()` | `NotFound`（NOT_FOUND：笔记不在回收站中）；`Database` |

### 3.5 标签

| 方法 | 签名 | 用途 | 参数含义 | 返回 | 可能的错误变体（code） |
|---|---|---|---|---|---|
| `create_tag` | `fn create_tag(&self, name: impl Into<String>, at_ms: i64) -> CoreResult<Tag>` | 创建标签；`tags::insert` 把 SQLite 约束冲突（`ConstraintViolation`）映射为 `DbError::Conflict`，再由本方法转成 `CoreError::Conflict("标签名称已存在")` | `name`：1 ~ `MAX_TAG_NAME_CHARS`（128）字符，全局唯一（忽略大小写） | `Tag` | `Validation`（名称为空/超长）；`Conflict`（CONFLICT：重名）；`Database` |
| `list_tags` | `fn list_tags(&self) -> CoreResult<Vec<Tag>>` | 列出全部标签（`tags::list_all`） | — | `Vec<Tag>` | `Database` |
| `list_note_tags` | `fn list_note_tags(&self, note_id: &Id) -> CoreResult<Vec<Tag>>` | 列出某篇笔记的标签（`tags::list_for_note`：`JOIN note_tags`，过滤已软删标签，按名称升序） | `note_id` | `Vec<Tag>` | `Database`（**不为 `note_id` 做存在性校验**，因此笔记不存在时返回空列表而不是 `NotFound`） |

### 3.6 统计

| 方法 | 签名 | 用途 | 参数含义 | 返回 | 可能的错误变体（code） |
|---|---|---|---|---|---|
| `note_count` | `fn note_count(&self) -> CoreResult<i64>` | 未删除笔记数量（`notes::count(&conn, false)`，即 `deleted_at_ms IS NULL`） | — | `i64` | `Database` |
| `notebook_count` | `fn notebook_count(&self) -> CoreResult<i64>` | 未删除笔记本数量（`notebooks::count`） | — | `i64` | `Database` |
| `pending_sync_count` | `fn pending_sync_count(&self) -> CoreResult<i64>` | 待同步操作数量（UI 同步状态用；`sync_operations::pending_count` = `COUNT(*) WHERE pushed_at_ms IS NULL`） | — | `i64` | `Database` |

### 3.7 相关但不属于 `NestedCore` 的公开项

| 项 | 位置 | 说明 |
|---|---|---|
| `UNKNOWN_DEVICE_ID: &str = "unknown-device"` | `api.rs` | 设备标识兜底值，供 CLI 与测试使用，避免必须先走设备注册流程（真实设备 ID 见 `nested_sync::DEVICE_ID_SETTING_KEY`，P6 落地） |
| `branding::display_name(language_tag) -> &'static str` | `branding.rs` | 按 BCP-47 前缀（`zh`）返回中文名，否则英文名 |
| `branding::version_string() -> String` | `branding.rs` | 形如 `"NestedNote 0.1.0"` |
| `branding` 的 7 个常量 | `branding.rs` | `BRAND_NAME_ZH`（`"拾光笔记"`）、`BRAND_NAME_EN`（`"NestedNote"`）、`BRAND_SLUG`（`"NestedNote"`）、`ENGINEERING_ID`（`"nested"`）、`DATABASE_FILE`（`"nested.db"`）、`APP_VERSION`（`env!("CARGO_PKG_VERSION")`）、`TAGLINE_ZH`（`"拾起每一段时光，层层收好"`） |
| `pub use` 面 | `nested-core/src/lib.rs` | 重新导出 `NestedCore` / `UNKNOWN_DEVICE_ID` / `CoreError` / `CoreResult`，以及 `nested_db::{Database, NoteQuery}` 与 `nested_model` 的实体与 `Document` 类型——目的是"使 Flutter 只需依赖本 crate" |

### 3.8 品牌名唯一来源（为什么业务代码禁止硬编码品牌字符串）

`nested-core/src/branding.rs` 的模块文档给出了设计理由：**品牌名可能因商标或市场原因调整，
而工程标识（crate 名、包名、数据目录、协议字段）一旦落地改动代价极高**。因此：

- 业务代码**禁止**硬编码 `"拾光笔记"` / `"NestedNote"`，一律引用 `branding` 常量；
- 品牌层与工程层刻意分离，并由测试固定：`engineering_id_stays_neutral()` 断言
  `ENGINEERING_ID == "nested"` 且 `BRAND_SLUG != ENGINEERING_ID`；
- 跨到 Dart 侧后这条约定依然成立：`apps/rust/src/api/branding.rs` 的 `display_name()`
  文档写明"Dart 侧不得硬编码品牌字符串"，`engine_providers.dart` 也确实是向 Rust 要显示名。

> 当前唯一的例外是 `client/apps/flutter/lib/app/app.dart` 的 `kBrandNameZh = '拾光笔记'`，
> 注释说明它只用于"引擎尚未就绪时的首屏占位"。这是一处**已知的品牌字符串副本**（§10.3）。

---

## 4. 错误模型

### 4.1 `CoreError` 的全部变体

来源：`client/crates/nested-core/src/error.rs`。变体定义（8 个）、`code()`、`is_retryable()`、`user_hint()`
三张表全部逐字对应源码：

| 变体 | 含义 | `code()`（稳定字符串） | `user_hint()`（面向用户，不含内部细节） | `is_retryable()` | 当前是否由 `nested-core` 产生 |
|---|---|---|---|---|---|
| `Database(DbError)` | 数据库错误（`#[from] nested_db::DbError`） | `DATABASE_ERROR` | 请尝试重启应用；若问题持续，请从备份恢复数据。 | ✗ | **是**（所有仓储调用） |
| `Validation(ModelError)` | 领域模型校验错误（`#[from] nested_model::ModelError`） | `VALIDATION_ERROR` | 请检查输入内容后重试。 | ✗ | **是**（`Notebook::new` / `Note::new` / `set_title` / `set_summary` / `Tag::new`） |
| `NotFound { entity: &'static str }` | 请求的数据不存在 | `NOT_FOUND` | 该内容可能已被删除或移动。 | ✗ | **是**（`entity` 实际取值只有 `"note"` 与 `"notebook"`） |
| `Config(String)` | 配置错误（数据目录不可用、参数非法等） | `CONFIG_ERROR` | 请检查设置中的数据目录是否可写。 | ✗ | **是**（`open` 中 `create_dir_all` 失败，消息为 `"无法创建数据目录：{error}"`） |
| `Conflict(String)` | 冲突（唯一约束、并发修改） | `CONFLICT` | 内容已被其他设备修改，请查看冲突副本。 | **✓** | **是**（目前唯一来源：标签重名，消息 `"标签名称已存在"`） |
| `Permission(String)` | 权限不足（文件系统或平台权限） | `PERMISSION_ERROR` | 请授予所需权限后重试。 | ✗ | ✗ **尚无产生点** |
| `Network(String)` | 网络错误（同步相关） | `NETWORK_ERROR` | 请检查网络连接后重试。 | **✓** | ✗ **尚无产生点**（属 P6） |
| `NotImplemented(&'static str)` | 功能尚未实现（P0 阶段的明确占位） | `NOT_IMPLEMENTED` | 该功能将在后续版本提供。 | ✗ | ✗ **尚无产生点**（CLI 的未实现子命令走 `eprintln!` + 退出码，未构造该变体） |

`is_retryable()` 的判定依据是源码中的 `matches!(self, Self::Network(_) | Self::Conflict(_))`——
**刻意保守**：只有"网络类"与"冲突类"被视为值得自动重试，其余（校验、找不到、配置、权限、未实现）
都属于"重试也不会变好"的错误。`error.rs` 的测试 `retryability_is_conservative()` 固定了这条边界
（`Network` 可重试；`NotImplemented` 与 `Validation` 不可重试）。

`code()` 的稳定性由测试 `codes_are_stable_and_unique()` 保护：8 个变体逐个取样，编码后去重计数必须等于总数
（"错误码必须互不重复"）。

### 4.2 为什么底层 `rusqlite` 错误不会直接透传给 UI

铁律 **E1**（内核错误必须是枚举类型，禁止把底层错误原样抛给 UI）、**E2**（UI 只显示可读信息 + 可操作建议 + 可选错误码；
禁止显示 stack trace、SQL 语句、内部路径）、**E3**（用户可见错误必须携带可在日志中检索的错误码）。
本仓库用**两级错误类型 + 一次显式映射**实现这三条：

```text
rusqlite::Error
   │  DbError 的 #[from]（nested-db/src/error.rs）
   ▼
DbError（9 个变体：Sqlite / Migrate / MigrationManifest / SchemaTooNew /
         VersionOutOfRange / IntegrityCheckFailed / NotFound / Conflict / Corrupt）
   │  CoreError::Database 的 #[from]（nested-core/src/error.rs）
   ▼
CoreError（8 个变体）── code() ──▶ UI 分支与日志检索（E3）
                     └─ user_hint() ─▶ 界面上的可读建议（E2）
```

- **技术细节留在 Rust 侧**：`DbError::Sqlite(rusqlite::Error)` 的 `Display` 才会带 SQL 相关细节，
  而 `CoreError::Database` 的 `user_hint()` 是一句固定文案，**不含**内部术语。
  这一点由测试 `hints_never_leak_internals()` 断言：构造 `DbError::Sqlite(rusqlite::Error::InvalidQuery)`
  对应的 `CoreError`，断言提示里既不出现 `"SQL"`，也不出现 `"rusqlite"`。
- **错误语义在上浮过程中被"翻译"**：底层只说"约束冲突"，`nested-core` 才说"标签名称已存在"（业务语言）；
  底层只说 `NotFound { entity }`，业务层才映射为 `CoreError::NotFound`。
- **UI 只拿到两样东西**：可读提示与（理论上）错误码。当前 FFI 只传了前者，见 §6.3。

### 4.3 已知偏差（需要修，不要照抄）

| # | 事实 | 影响 | 依据 |
|---|---|---|---|
| 1 | `CoreError::Conflict` 同时承担"标签重名"（本地、确定性失败）与"多设备并发修改"（可重试）两种语义，但 `user_hint()` 只写了后者 | 用户看到"内容已被其他设备修改，请查看冲突副本"，而真实原因是"标签名重复" | `api.rs` `create_tag` 与 `error.rs` `user_hint()` |
| 2 | `is_retryable()` 对 `Conflict` 返回 `true` | 若 UI 按 `is_retryable()` 自动重试，一次注定失败的"标签重名"会被反复重试 | `error.rs` 的 `matches!` 与 `duplicate_tag_is_conflict` 测试 |
| 3 | `Permission` / `Network` / `NotImplemented` 已定义但无产生点 | 这三条 `code()` 目前只在测试与文档中出现；一旦 P6/P1 接入需要保证码值不变（已是稳定契约） | 全仓检索 `CoreError::` |

---

## 5. FFI 契约

`client/apps/rust` 是 `nested_app`（`crate-type = ["cdylib","staticlib","lib"]`），
`flutter_rust_bridge = "=2.13.0"`（与 `pubspec.yaml` 的 `flutter_rust_bridge: ^2.13.0` 严格对应）。

### 5.1 桥接层的三部分与导出面的三条规则

`apps/rust/src/lib.rs` 用一张表划清了归属：

| 文件 | 归属 | 说明 |
|---|---|---|
| `src/api/*.rs` | **手写（入库）** | 导出的业务 API，是唯一的跨语言契约面 |
| `src/frb_generated.rs` | 生成（不入库） | codegen 产出的桥接样板 |
| `lib/src/rust/**`（Flutter 侧） | 生成（不入库） | codegen 产出的 Dart 绑定 |

导出面必须遵守的三条规则（`lib.rs`「契约要求（铁律 A3 / A4）」与 `api/mod.rs` 逐字一致）：

1. **只暴露业务语义**：不暴露 `execute_sql` 之类的实现细节，不暴露表结构与行 ID（铁律 A3）。
2. **跨边界只传可序列化的简单结构**：不传裸指针、不传数据库句柄、不让 Dart 长期持有事务（铁律 A4）。
3. **所有函数禁止 panic**：错误一律以结构化结果返回（铁律 E1）。`start_engine` 的注释即"FFI 边界**不允许** panic：
   任何失败都转成 `EngineStatus` 返回"；实现上也确实只有 `match`，没有 `unwrap`/`expect`（受 R1 门禁约束）。

### 5.2 当前导出面（`client/apps/rust/src/api/`）

| 项 | 签名 | 说明 |
|---|---|---|
| `version_info` | `pub fn version_info() -> VersionInfo` | 返回品牌与版本：`name_zh` / `name_en` / `version`（来自 `branding::APP_VERSION`）/ `protocol_version`（来自 `protocol::PROTOCOL_VERSION`，当前为 `1`） |
| `display_name` | `pub fn display_name(language_tag: &str) -> String` | 按 BCP-47 语言标签返回界面显示名（`"zh-CN"` → 拾光笔记）；品牌名的唯一来源仍是 Rust |
| `start_engine` | `pub fn start_engine(data_dir: &str) -> EngineStatus` | 在指定目录启动内核并执行就绪自检；成功则返回逐项检查与数据库路径，失败则返回可读提示 |
| `VersionInfo` | 结构体：`name_zh` / `name_en` / `version` / `protocol_version: u32`（均 `pub`） | 字段用 `String` 而非 `&'static str`：FRB 会把返回值转成 Dart 对象，`String` 映射最直接，也避免把借用语义带过语言边界 |
| `EngineStatus` | 结构体：`ready` / `checks` / `database_path` / `message` | 见 §5.3 |
| `EngineCheck` | 结构体：`name: String` / `passed: bool` | 单项自检结果，`name` 如 `"database_open"` |

### 5.3 `EngineStatus` 的四个字段（语义逐条）

| 字段 | 类型 | 语义 | 何时为空/假 |
|---|---|---|---|
| `ready` | `bool` | 是否**全部**检查通过（`checks.iter().all(|c| c.passed)`） | 打开内核失败时为 `false`，且 `checks` 为空 |
| `checks` | `Vec<EngineCheck>` | 逐项检查结果，来自 `NestedCore::readiness()` 的三项：`database_open` / `schema_current` / `integrity` | 打开失败时为**空 vec**（不是"三项全 false"） |
| `database_path` | `Option<String>` | 数据库文件绝对路径（`core.database_path().map(|p| p.display().to_string())`），便于在界面与日志中定位数据 | 打开失败时为 `None` |
| `message` | `Option<String>` | 出错时的**可读提示**，内容为 `CoreError::user_hint()`（不含内部细节，铁律 E2） | 打开成功时为 `None`——**即使 `ready == false`（某项自检失败）也不会填 `message`**，见 §10.3 |

> 注：`start_engine` 用 `user_hint()` 而非 `Display`，是有意的 E2 取舍：界面拿到的是"请检查设置中的数据目录是否可写"
> 这类可操作建议；代价是内部细节（真实 `CoreError` 与 `code()`）不出现在 Dart 侧，现场定位依赖诊断文件（§6）。

### 5.4 codegen 配置与生成物

`client/apps/flutter/flutter_rust_bridge.yaml`（全文 3 行，逐行说明）：

| 配置项 | 值 | 含义 |
|---|---|---|
| `rust_input` | `crate::api` | **只有 `crate::api` 下的条目会被导出到 Dart**。这是"导出面可控"的机制：顺手 `pub` 出来的内部函数不会被意外暴露（铁律 A3），所有跨语言边界的东西集中在一处，便于审计参数与返回值 |
| `rust_root` | `../rust/` | Rust crate 根目录（相对 yaml 所在目录），即 `client/apps/rust` |
| `dart_output` | `lib/src/rust` | Dart 绑定输出目录，已列入 `.gitignore` |

**为什么生成物不入库**（`apps/rust/src/lib.rs` 的理由，`.gitignore` 落地）：

- 它们**完全由** `flutter_rust_bridge.yaml` 与 `src/api/` 决定——提交它们只会制造无意义的 diff 与合并冲突；
- 对应的忽略项是 `client/apps/rust/src/frb_generated.rs` 与 `client/apps/flutter/lib/src/rust/`
  （两者在本机已存在，因为跑过 codegen；但它们不在版本控制里）；
- 重建命令：在 `client/apps/flutter` 下执行 `flutter_rust_bridge_codegen generate`，
  或使用仓库脚本 `scripts/generate-ffi-bindings.ps1`（额外做版本校验与格式规范化）。

**代价（刻意保留）**：新 clone 的仓库里没有 `src/frb_generated.rs`，而 `lib.rs` 是**无条件**声明
`mod frb_generated;`，因此任何 `cargo` 命令（fmt / clippy / test）都会以
`failed to resolve mod 'frb_generated'` 直接失败。这是刻意行为而非缺陷：

- CI 在质量门禁之前先执行 codegen（`.github/workflows/ci.yml` 客户端的「生成 FFI 绑定」步骤），
  因此 CI 永远是带着真实绑定做检查；
- 本地若忘记生成，得到的是一个**明确的**错误信息与修复命令，而不是"悄悄用了旧绑定"或"悄悄跳过了 FFI 层"。

**为什么 `mod frb_generated;` 必须是第一个 item**（`lib.rs` 注释给出的原因）：
该声明由 codegen 自动注入，并且**必须保持为第一个 item**——生成文件顶部带有 `#![allow(...)]` 内部属性，
而 Rust 只允许内部属性出现在文件/模块的最前面，手工把它移到别处会导致编译失败。
实测生成物印证了这一点：`frb_generated.rs` 的前两行是生成器注释，紧接着第 4–26 行就是
`#![allow(non_camel_case_types, unused, …)]` 这个内部属性块。

**为什么这个 crate 没有 `#![forbid(unsafe_code)]`**：生成代码里包含 FFI 必需的 `unsafe` 块（跨语言指针转换）。
因此 `lib.rs` 用的是 `#![allow(unsafe_code, unreachable_pub, clippy::all, clippy::pedantic)]`
（豁免整个 crate，因为 `frb_generated.rs` 每次重新生成，逐个 `#[allow]` 会被覆盖），
并对**手写代码**改用两条更强的约束：`nested-rules` 的 R1（禁止 panic 类调用）与 A-ISOLATION（不得越界依赖服务端）。
换言之：不用 crate 级 `forbid` 一刀切，是因为它会把生成代码一起拦下，而真正需要约束的是手写的 `src/api/`。

**版本一致性与格式**（`scripts/generate-ffi-bindings.ps1`）：

- 脚本先从 `pubspec.yaml` 提取 `flutter_rust_bridge: ^X.Y.Z`，再要求 PATH 上的
  `flutter_rust_bridge_codegen --version` 与之匹配，否则以明确信息失败
  （`cargo install flutter_rust_bridge_codegen --version <pinned> --locked`）——版本不一致会导致
  生成的桥接代码与 Dart 侧运行库不匹配；
- 随后生成绑定，并**用 `cargo fmt` 规范化生成物**（codegen 产出的 import 顺序不符合 rustfmt，
  不规范化会让 `cargo fmt --check` 每次都在同一处假失败）；脚本注释记录了三选一的取舍：
  rustfmt 的 `ignore`（需要 nightly，已实测在 stable 上被忽略）、`#[rustfmt::skip]`（下次生成被覆盖）、
  用格式化器规范化（采用）；
- `-Check` 模式只校验"生成物已存在且 rustfmt 干净"，供 CI 使用。

---

## 6. 错误在跨语言边界的行为

### 6.1 职责划分

| 层 | 负责 | 不负责 |
|---|---|---|
| `nested-core` | 把一切失败转成 `CoreError`（枚举 + 稳定 `code()` + 脱敏 `user_hint()`）；永不 panic（R1 门禁） | 面向用户的措辞选择、重试策略 |
| `nested_app::api`（FFI 手写面） | 把 `Err(CoreError)` **转成结构化返回值**（`start_engine` 的 `message = user_hint()`），保证边界不 panic | 把内部细节（SQL、路径、栈）送过边界（E2） |
| 生成的 FRB 绑定 | 序列化/反序列化 `VersionInfo` / `EngineStatus` / `EngineCheck` | 业务判定 |
| Dart `core/engine_providers.dart` | 初始化 FRB 运行时、解析数据目录、调用 Rust、把生成类型映射为纯 Dart 类型；**对意外异常兜底** | 实现业务规则（F1） |
| Dart `app/app.dart` | 三态渲染（loading / data / error），错误视图**不显示堆栈**（E2） | 解析 Rust 错误内部结构 |

### 6.2 Rust 侧：失败 → 结构化结果，不 panic

`start_engine` 的实现只有两条路径：

```text
NestedCore::open(data_dir)
 ├─ Ok(core)  → checks = core.readiness() 逐项映射为 EngineCheck
 │              ready = 全部通过
 │              database_path = Some(路径)
 │              message = None
 └─ Err(err)  → ready = false, checks = [], database_path = None,
                message = Some(err.user_hint())
```

测试从两个方向固定了这个契约：

| 测试 | 输入 | 断言 |
|---|---|---|
| `start_engine_reports_failure_without_panicking` | 父路径是**文件**的非法目录 | `!ready` 且 `message.is_some()`——"失败必须给出可读信息，而不是 panic" |
| `start_engine_rejects_unwritable_path_without_panicking` | Windows 保留字符路径 `Z:\definitely\missing\drive\nested` | `!ready` 且 `message.is_some()` |

### 6.3 Dart 侧：兜底 try/catch 的职责

`engine_providers.dart` 的注释把分工写得很清楚："FFI 边界本不该抛异常（Rust 侧把失败都转成了结构化结果），
但动态库加载失败等情况仍可能抛出，因此这里兜底而不是让它冒到 UI（铁律 E6）"。具体做法：

1. `RustLib.init()`：初始化 FRB 运行时（幂等，重复调用安全）；
2. `resolveDataDir()`：用 `path_provider` 拿应用专属目录（平台差异由插件负责，业务代码不关心）；
3. 先取 `versionInfo()` 与 `displayName(languageTag: 'zh-CN')`——顺带验证"显示名也来自 Rust"这条契约；
4. `try { startEngine(dataDir) } catch { 构造 ready=false 的 EngineStatus，message = '无法启动内核：$error' }`；
5. `_writeDiagnostics()` 把结果写入 `%TEMP%/engine-status.txt`（`dataDir`/`ready`/`displayName`/`version`/
   `protocolVersion`/`databasePath`/`message`/逐项 check），写入失败被静默忽略（"诊断写入失败绝不能影响正常流程"）。

这样做的代价与收益都明确：收益是**界面永远有东西可显示**（不会因动态库加载失败而白屏或崩溃）；
代价是诊断信息落在未托管的临时文件里，已登记为技术债 #3（计划 P1 改为结构化日志）。

### 6.4 当前跨边界信息的真实范围（诚实说明）

| 信息 | 是否跨过 FFI | 说明 |
|---|---|---|
| 用户可读提示 | ✅ | `EngineStatus.message`（内容为 `user_hint()`） |
| 逐项自检结果 | ✅ | `EngineStatus.checks` |
| 数据库路径 | ✅ | `EngineStatus.database_path` |
| 品牌名 / 版本 / 协议版本 | ✅ | `VersionInfo` / `display_name()` |
| **稳定错误码 `CoreError::code()`** | ❌ | `EngineStatus` 没有 code 字段，Dart 侧拿不到 `DATABASE_ERROR` 之类可检索的错误码（E3 在 UI 路径上尚未满足；CLI 满足，见 §9 的 `doctor` 输出） |
| 内部细节（SQL、栈、rusqlite 错误） | ❌（刻意） | E2 要求不得暴露；`hints_never_leak_internals` 测试固定这条边界 |

---

## 7. 分层约束的强制方式

按"约束 → 谁来保证"分四档，并诚实标注盲区（参考铁律附 A「已知的检查盲区」与
[ADR 0004](../adr/0004-rules-checker-in-rust.md) 的"后续要做的"）。

| 档 | 约束 | 强制手段 | 位置/证据 | 盲区与说明 |
|---|---|---|---|---|
| **编译器** | R2 库层禁止 `unsafe` | `[workspace.lints.rust] unsafe_code = "deny"` + 各 crate 的 `#![forbid(unsafe_code)]` | `client/Cargo.toml`、`nested-core/src/lib.rs`、`nested-model` / `nested-db` / `nested-search` / `nested-attachment` / `nested-import` / `nested-export` / `nested-sync` / `nested-crypto` / `cli/src/main.rs` / `tools/nested-rules/src/main.rs` | `nested_app` 例外（生成代码需要 `unsafe`），已在 `lib.rs` 顶部说明理由 |
| **编译器** | A5 核心与平台解耦 | 依赖图本身：`nested-*` 的 `Cargo.toml` 里没有任何 Flutter/平台依赖 | 11 个清单文件 | 只能保证"不能调用你没依赖的东西"，无法保证"没有用 `cfg!(target_os)` 分支" |
| **编译器** | 生成绑定缺失必须显式失败 | `mod frb_generated;` 无条件声明 | `apps/rust/src/lib.rs` | 这是刻意的"明确失败优于悄悄降级" |
| **测试（本地可发现）** | Q2/D6 历史迁移不可变；Q3 迁移必须在事务里且失败即中止 | `nested-db/tests/migration_guard.rs` 四道护栏（哈希清单 / 清单一致性 / 命名规范 / 无 CR）+ `include_str!` 内嵌 SQL；`migrations.rs` 11 个测试（含"失败迁移整体回滚且版本不前进"、"升级失败保留旧版本"、"版本过高拒载"），可注入清单的 `apply_manifest` 让这些失败路径可测 | [ADR 0003](../adr/0003-migration-hash-guard.md)、`nested-db/src/migrations.rs` | 需要手工维护哈希（刻意的摩擦） |
| **测试** | D1 原子写 | 仓储内部 `unchecked_transaction()`（notes.rs）与 `Database::with_transaction`；`transaction_rolls_back_on_error` 等测试 | `nested-db/src/db.rs`、`repositories/notes.rs` | 没有"每个业务写是否都进了事务"的自动检查，靠 Review |
| **nested-rules** | A-ISOLATION：客户端与服务端互为禁区 | `checks::workspace_isolation`：① `client/**/Cargo.toml` 不得依赖 `server-core`/`server-api`/`server-auth`/`server-sync`/`server-storage`/`sqlx`/`axum`/`tokio-postgres`；② `server/**/Cargo.toml` 不得依赖 `nested-*` 与 `rusqlite`；③ `shared/protocol/Cargo.toml` 不得依赖 `tokio`/`sqlx`/`axum`/`rusqlite`/`reqwest`/`hyper` | `tools/nested-rules/src/checks.rs`（`rules.rs` 注册为第 4 条规则，id `A-ISOLATION`）；测试 `client_depending_on_server_is_reported`、`client_depending_on_sqlx_is_reported`、`dependency_name_in_comment_is_not_reported` | **只做清单级文本扫描**：`mentions_dependency` 逐行扫 `[*dependencies*]` 段（注释不误报），不解析 Rust 源码的 `use`；巡检名单是硬编码的，新增服务端 crate 名字需同步补 |
| **nested-rules** | R1 产品代码禁止 `unwrap()/.expect(/panic!`；E6 禁止 `todo!`/`unimplemented!`；R13 禁止 `dbg!` | `checks::panic_free_production_code`：只扫 `PRODUCTION_ROOTS`（`client/crates`、`client/cli`、`client/apps/rust`、`server`、`shared`）下 `src/` 里的 `.rs`，跳过 `#[cfg(test)]` 模块（`read_annotated_lines`）与文件名含 `generated` 的生成物、跳过整行注释 | 同上；测试 `unwrap_in_production_code_is_reported` / `unwrap_inside_test_module_is_allowed` / `unwrap_in_comment_is_allowed` | 铁律附 A 明列：只识别字面量，不识别通过 trait 间接 panic；注释剥离不处理块注释与字符串里的 `//`；技术债 #1：clippy 侧 `unwrap_used`/`expect_used` 仍是 `allow`，绕过 `just check-rules` 只跑 clippy 拦不住 |
| **nested-rules** | D2/T7 禁止裸 `DELETE` | `checks::no_raw_delete`：扫 `client/` 下 `src/`，允许 `note_tags` / `note_attachments`（纯关联表） | 同上；测试 `raw_delete_on_business_table_is_reported` / `raw_delete_on_join_table_is_allowed` | 只识别 `DELETE FROM <表>` 字面量 |
| **nested-rules** | Q4 禁止插值构造 SQL | `checks::no_interpolated_sql`：同一行同时出现 `format!` 与 SQL 关键字，且插值占位符不在白名单 `["COLUMNS","columns"]` 内 | 同上；测试 `interpolated_sql_with_lowercase_placeholder_is_reported` / `interpolated_sql_with_constant_columns_is_allowed` | 铁律附 A：不检查 `String` 拼接（如 `push_str` 拼 SQL） |
| **nested-rules** | S3 禁止硬编码凭据 / B1 锁定文件齐备 / V6 禁止大文件（> 5 MiB） | `no_hardcoded_secrets`（启发式：敏感字段名 + 引号内 ≥ 8 字符，放行 example/placeholder/dummy 等标记；豁免 `scripts/` 与 `tools/nested-rules`）、`required_files_present`（含 `client/rust-toolchain.toml`、`client/Cargo.lock`、`justfile`、`docs/02-工程铁律.md` 等 8 项）、`no_large_files` | 同上 | S3 是启发式而非熵检测；脚本目录内的真实凭据不会被这条规则拦住（脚本注释明确记录了这个取舍） |
| **CI** | R7/R8/F2/F12、Z7 | `cargo fmt --all -- --check`、`cargo clippy --workspace --all-targets -- -D warnings`、`cargo test --workspace`、`flutter analyze`、`flutter test` | `.github/workflows/ci.yml`（客户端作业先跑「生成 FFI 绑定」） | — |
| **仅 Review（盲区）** | A1/A2 的 Dart 侧分层（"UI 不得直接调 Repository/生成绑定"） | **无自动检查** | 铁律附 A 明确写："分层约束（A1/A2 …）**没有**自动检查，因为 Dart 侧尚无代码；Flutter 接入后必须补"。ADR 0004「后续要做的」也列了"补充 Dart 侧的分层检查" | ⚠️ **Flutter 已接入但检查仍未补**：目前只有 `engine_providers.dart` 的文件头注释与 Review 在约束"只有这个文件可以 import `src/rust/`" |
| **仅 Review（盲区）** | A7 的"`nested-core` 里禁止写 SQL、`nested-db` 里禁止写业务规则" | 无专门规则 | `nested-rules` 的 7 条规则中没有任何一条检查它 | `NestedCore::database()` 是 `pub` 且返回 `&Database`，而 `Database::connection()` 也是 `pub`，因此 `nested-core` 在类型上**可以**写 SQL 而不被任何门禁发现（Q4 只能拦 `format!` 拼接，拦不住常量 SQL 字符串）。`database()` 的文档注释声明"仅供 CLI 与诊断；**UI 层禁止**直接使用（铁律 A2）"——这是约定，不是强制 |
| **仅 Review（盲区）** | M1/M2（设计文档与 ADR 是否存在） | 无自动检查（铁律附 A：❌ 靠 Review） | 本文档即是 M1 的产物；`docs/adr/` 现有 0001–0005 | — |

---

## 8. 公共 API 演进规则

### 8.1 新增或修改 `nested-core` 方法

| 步骤 | 要求 | 依据 |
|---|---|---|
| 1 | 先有设计文档（新模块/新数据格式必须），本文件与相关 `docs/design/NN-*.md` 同步更新；**禁止**"边写边想"地实现架构级功能 | M1、M3 |
| 2 | 若涉及换库、换协议、改数据格式、偏离铁律：**必须**先写 ADR | M2、A9 |
| 3 | 若改动已发布的接口/HTTP API/数据库结构/文档格式：**必须**给出兼容性结论（兼容 / 需迁移 / 破坏性）与用户数据迁移路径 | **A10** |
| 4 | 公开项**必须**有 `///` 文档注释，并说明错误条件与副作用（是否写库、是否发网络请求）；本文 §3 的"错误变体"列即由此而来 | R9 |
| 5 | 至少覆盖 正常 / 边界（空、超长、重复）/ 失败（权限、损坏、中断）三条路径 | Z2、Z1（核心 crate 行覆盖率 ≥ 80%） |
| 6 | 数据访问**必须**参数化，排序与过滤字段来自白名单结构体（参考 `NoteQuery`） | Q4、R6 |
| 7 | 新增写路径**必须**在单事务内完成，并明确是否入 `sync_operations` 队列 | D1、T6 |
| 8 | 合并前：`cargo fmt --check`、`cargo clippy --all-targets -- -D warnings`、`cargo test --workspace`、`cargo run -p nested-rules -- --root ..` 全绿 | R7、R8、Z7 |

### 8.2 修改 FFI 接口（`apps/rust/src/api/**`）时必须做什么

| 步骤 | 动作 | 依据 |
|---|---|---|
| 1 | 兼容性结论（兼容 / 需迁移 / 破坏性）+ 用户数据迁移路径，写进 PR 与设计文档 | **A10** |
| 2 | 破坏性变更或数据格式变更 → ADR；涉及库结构或数据格式的变更还必须**自动迁移 + 用户可见说明 + 备份建议** | M2、B10 |
| 3 | 只改 `src/api/**`（FRB 的 `rust_input: crate::api` 决定导出面），不为了让 Dart 方便而扩大导出范围 | A3、A4 |
| 4 | **重新生成绑定**：`powershell -NoProfile -File scripts/generate-ffi-bindings.ps1`；**禁止**手工编辑 `frb_generated.rs` 与 `lib/src/rust/**` | **B5** |
| 5 | 同步更新手写 Dart 封装（如 `lib/core/engine.dart` 的字段拷贝、`engine_providers.dart` 的映射）与相关测试 | M3、Z1 |
| 6 | 若新接口会失败：定义新的错误语义时**必须**同时给出稳定 `code()`（E3），并考虑 `user_hint()`（E2） | E3、E2 |
| 7 | 与代码同 PR 更新本文件、README（如命令或版本变化）、必要时更新 `docs/01-开发计划.md` | M3、M5 |

### 8.3 兼容性判定的经验规则（基于当前契约形状）

| 改动 | 结论 | 原因 |
|---|---|---|
| 新增一个 `nested-core` 方法 | 兼容（对 Rust 调用方） | 除非改变已有语义 |
| 给跨 FFI 结构**新增字段** | **兼容但需同步改动** | FRB 会重新生成 Dart 类，`engine.dart` 的字段拷贝与测试也必须更新；只读的调用方不受影响 |
| 重命名/删除字段、改字段类型、改枚举取值 | **破坏性** | Dart 侧编译期即失败；若已发布必须走 ADR + 版本迁移说明（A10/B10） |
| 改变已有方法的错误变体（例如把"重名"从 `Conflict` 改成 `Validation`） | 破坏性 | 错误码是 UI 分支与日志检索的契约（E3） |
| 修改 `branding` 常量值 | 兼容（工程标识除外） | 品牌名可改；`ENGINEERING_ID` / `DATABASE_FILE` 被测试固定，改动会波及数据目录与文件名（§3.8） |
| 修改 `protocol::PROTOCOL_VERSION` | **必须 ADR** | `shared/protocol` 是两端唯一共享契合物，改动要两端同步（P6 范围） |
| 修改数据库结构 | **只能追加 migration** | Q1/Q2：禁止改历史文件；需更新 `migration_guard.rs` 的哈希清单并补"从上一版本升级到最新"的测试（Q10） |

---

## 9. 构建与验证命令

> 全部命令与仓库中的 `justfile`、`README.md`、`scripts/*.ps1`、`.github/workflows/ci.yml` 一致。
> 除特别说明外，命令都在 Windows PowerShell 下执行。

### 9.1 一次性前置（每个新 clone 必须做）

```powershell
# 仓库根目录：生成 FFI 绑定（并规范化生成物格式、校验 codegen 版本与 pubspec 一致）
powershell -NoProfile -File scripts/generate-ffi-bindings.ps1

# 只校验生成物存在且 rustfmt 干净（不改文件，CI 用）
powershell -NoProfile -File scripts/generate-ffi-bindings.ps1 -Check

# 生成器本体的安装（版本必须与 pubspec 的 flutter_rust_bridge 一致）
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
```

> 不生成就构建会失败，且失败信息是明确的 `failed to resolve mod 'frb_generated'`（见 §5.4）。

### 9.2 客户端 Rust 侧

| 目的 | 命令 | 预期 |
|---|---|---|
| 全量门禁（推荐） | `just check` | 行尾 + 两端 fmt + 两端 clippy + 铁律检查 + 两端测试全绿 |
| 只跑客户端测试 | `just test-client`（= `cd client; cargo test --workspace`） | 全绿。注：`justfile` 目前**只**定义了 `check`、`test-client`、`test-server`；头部注释里提到的 `just check-client` / `just check-server` 并不存在（§10.3 #11） |
| 格式检查 | `cd client; cargo fmt --all -- --check` | 无输出 |
| Lint | `cd client; cargo clippy --workspace --all-targets -- -D warnings` | 0 警告（铁律 R7） |
| 测试 | `cd client; cargo test --workspace` | 全绿（P0 时点：149 个用例，见 gate-p0） |
| 铁律检查 | `cd client; cargo run -p nested-rules -- --root ..` | `0 违规`；退出码 0=通过 / 1=有违规 / 2=用法错误 |
| 只报告不失败 | `cd client; cargo run -p nested-rules -- --root .. --report-only` | 本地排查用 |
| 检查器自身测试 | `cd client; cargo test -p nested-rules` | 22 个用例通过（覆盖 R1 / D2 / Q4 / A-ISOLATION / S3；B1 与 V6 目前无用例，见 §10.3 #12） |
| 迁移护栏 | `cd client; cargo test -p nested-db --test migration_guard` | 哈希清单 / 清单一致性 / 命名 / 行尾四道护栏通过 |
| 覆盖率（Z1 ≥ 80%） | `just coverage`（= `cd client; cargo llvm-cov --workspace --summary-only`） | 阈值接入 CI 属 **P1**（尚未度量，见 gate-p0 §6） |
| 依赖审计 | `just audit` / `cd client; cargo audit` | 无高危漏洞（铁律 S11） |
| 行尾规范 | `powershell -NoProfile -File scripts/normalize-line-endings.ps1 -Check` | 迁移与共享文件均为 LF |

### 9.3 内核验收（CLI，无 UI）

```powershell
cd client
cargo run -p nested-cli -- version                       # 品牌、工程标识、数据库名、协议版本
cargo run -p nested-cli -- init  --data-dir C:\tmp\nested  # 建目录 + 建库 + 迁移
cargo run -p nested-cli -- doctor --data-dir C:\tmp\nested # 就绪自检 + 完整性 + 统计，退出码反映结论
cargo run -p nested-cli -- seed                          # 未实现：必须失败（退出码 1）并指向 P1
```

`doctor` 的输出形如（`run_doctor` 逐项打印）：

```text
数据目录：C:\tmp\nested
  [OK  ] database_open
  [OK  ] schema_current
  [OK  ] integrity
  schema 版本：1
  笔记数量：0
  待同步操作：0
结论：一切正常。
```

退出码约定（`cli/src/main.rs` 的 `exit_code`）：`0` 成功、`1` 运行时失败（含未实现）、`2` 用法错误；
数据目录解析优先级：`--data-dir`（`--data-dir=DIR` 亦可） > `NESTED_HOME` > 用户主目录下的 `NestedNote`；
日志级别由 `NESTED_LOG` 控制（默认 `info`）。

### 9.4 Flutter 侧

```powershell
# 1) 先构建 Rust 动态库（flutter test 需要它；真实应用由 Cargokit 自动构建打包）
cd client
cargo build -p nested_app --release

# 2) 静态检查与测试
cd apps/flutter
flutter analyze
$env:FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR = "$PWD/../../target/release"
flutter test                      # 3 个用例：2 个 Widget 冒烟 + 1 个真实 FFI 集成

# 3) 运行桌面应用
flutter run -d windows
```

> `FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR` 只在 `flutter test` 下需要：
> FRB 默认按相对路径 `../rust/target/release/` 查找动态库，测试运行时该相对路径不可靠，
> 因此显式给绝对路径（`client/target/release`）。真实应用走平台 DLL 搜索顺序，不依赖它。

### 9.5 CI 对应关系

| CI 作业 | 关键命令 | 对应铁律 |
|---|---|---|
| 变更检测 | `dorny/paths-filter`（client / server 两条路径规则） | — |
| 铁律检查 | `cargo test -p nested-rules` + `cargo run --quiet -p nested-rules -- --root ..` | 附 A 全部自动项 |
| 行尾规范（LF） | `grep -rIl $'\r' client/migrations server/migrations shared` | D6 / ADR 0003 |
| 客户端 | 「生成 FFI 绑定」→ `cargo fmt --check` → `clippy -D warnings` → `cargo test --workspace` | R7/R8/Z7/B5 |
| 服务端 | `cargo fmt --check` / `clippy` / `cargo test --workspace` | 同上 |
| 依赖审计 | `cargo audit`（两端）+ 校验服务端豁免前提 | S11 |

---

## 10. 未实现部分（诚实清单）

### 10.1 能力缺口（有分层位置，但还没有实现）

| 能力 | 现状（可验证的事实） | 计划阶段 | 依据 |
|---|---|---|---|
| 全文搜索（FTS5） | `nested-search` 只有 `SearchQuery` / `SearchHit` / `SearchError` 类型；`nested-core` 没有 `search_notes` 之类的方法 | **P1** | 计划 §2.1.3（P1-12 ~ P1-15）；P1-13 要求先用基准对比 `unicode61`+bigram / `trigram` / 外部分词，并写 ADR |
| 附件 CAS 落盘 | `nested-attachment` 的 CAS 读写**已实现**（`put_bytes` / `put_file` / `read` / `verify` / `delete`，临时文件 → fsync → rename，写后回读校验，内容去重），但 **`nested-core` 尚未暴露任何附件方法**，因此从 FFI/CLI/Flutter 仍不可达 | 暴露接口属 **P1**；缩略图管线 P1-18、引用计数与 GC P1-17 仍未实现 | 计划 §2.1.4；铁律 T8/D3/D4 |
| 导入（MD/HTML/TXT/ENEX） | `nested-import` 只有 `ImportFormat::from_extension` 与 DTO、错误类型；无解析器、无清洗、无编码识别 | **P1** | 计划 §2.1.5（P1-20 ~ P1-23）；铁律 S5/Z2/Z3 |
| 导出与备份/恢复 | `nested-export` 只有 `ExportFormat::extension`、`MANIFEST_FILE`、`BACKUP_DIRS`、`BackupManifest` 等类型；无写出、无 manifest 校验、无恢复 | **P1**（PDF 导出视依赖风险延后到 **P3**） | 计划 §2.1.5（P1-20 ~ P1-26）；`ExportFormat::Pdf` 注释"P3 视依赖风险决定是否实现"；计划 P3-18 |
| 加密与平台密钥存储 | `nested-crypto` 只有常量、`SecretStore` trait 与 `CryptoError`（含 `NotImplemented`）；无平台实现、无算法；加密方案待 ADR | **P1**（方案落地）；移动端 Keychain/Keystore 随 **P5** | 计划 P1-30、P5-9；铁律 D11/S2 |
| 同步引擎（客户端） | `nested-sync` 只有常量（`DEVICE_ID_SETTING_KEY` / `PULL_CURSOR_KEY_PREFIX`）、`SyncPhase`/`SyncReport`/`Conflict`、`SyncError`；无 push/pull/冲突处理/附件同步 | **P6** | 计划 §7.2（P6-9 ~ P6-20）；铁律 T3/T6/D9/D10 |
| 设备 ID 生成与持久化 | 常量已定义，但 `nested-core` 尚未在首次启动时生成真实设备 ID；`create_note` 只能传 `UNKNOWN_DEVICE_ID` 兜底 | **P6**（P6-9），在此之前 CLI/测试用兜底值 | `api.rs` 对 `UNKNOWN_DEVICE_ID` 的注释；`nested-sync` 的 `DEVICE_ID_SETTING_KEY` |
| 大文档块级懒加载 | `nested-core` 的文档 API 是"整篇读/整篇写"（`get_note_document` / `save_note`） | **P1** | 计划 P1-31（"块级懒加载接口：先取块元数据，再按需取块内容"）；铁律 T9 |
| 多读者/连接池 | `Database` 是"单写入连接 + 互斥锁" | **P4**（需基准数据支撑） | `db.rs` 模块注释："多读者优化留给 P4，届时通过 `criterion` 基准证明必要性"；铁律 P2 |
| CLI 的 P1 子命令 | `seed` / `search` / `import` / `export` / `backup` / `restore` / `reindex` / `bench` 全部走 `run_planned()`，打印"尚未实现（计划阶段：P1…）"并返回失败 | **P1** | 计划 §2.2 DoD；`cli/src/main.rs` 顶部说明与测试 `planned_commands_fail_loudly` |
| GC / 彻底删除 | 仓储层没有物理删除；`repositories.rs` 注明"物理删除只允许出现在 GC 模块（尚未实现）" | **P1**（保留期默认 30 天，见计划 P1-11 / P1-17）；删除同步的 GC 前置条件在 **P6** | 铁律 D2/T7/S10 |
| 崩溃注入 / 性能基准 / 覆盖率门槛 | 无崩溃注入任务；`criterion` 已在 workspace 依赖中但无基准套件；覆盖率未度量 | 崩溃注入 **P4**（Z5 在附 A 中标为 P4）、基准 **P4**、覆盖率 **P1** | 铁律附 A（Z1 ⬜ P1、Z5 ⬜ P4、P1/P10 ⬜ P4）；gate-p0 §6 |
| Dart 侧分层自动检查 | 无任何检查规则约束 "UI 不得直接访问生成绑定/存储"（当前只靠 `engine_providers.dart` 注释与 Review） | **未排期**（铁律附 A 与 ADR 0004 都列为"Flutter 接入后必须补"，而 Flutter 已接入） | 铁律附 A 已知盲区；ADR 0004「后续要做的」 |
| OCR / 版本历史 / 语义搜索 / AI / WebDAV / CRDT | 无代码 | **P7**（各自独立 Gate；CRDT 必须先 ADR） | 计划 §8 |

### 10.2 已定义但当前没有产生点的类型/常量

| 项 | 位置 | 说明 |
|---|---|---|
| `CoreError::{Permission, Network, NotImplemented}` | `nested-core/src/error.rs` | 见 §4.1/§4.3 |
| `nested_search::{SearchQuery, SearchHit}` | `nested-search` | 类型已定契约（含 `rank: f64` 不派生 `Eq` 的理由），无使用方 |
| `nested_attachment::THUMBNAILS_DIR` | `nested-attachment` | 常量已定义，缩略图管线（P1-18）未实现 |
| `nested_import::{ImportedNote, ImportedAttachment}`、`nested_export::{BackupManifest, ManifestEntry}` | 两个 crate | 数据形状已定，无生产者/消费者 |
| `nested_sync::{SyncPhase, SyncReport, Conflict, SyncError}` | `nested-sync` | P6 落地前不会被构造 |
| `nested_crypto::SecretStore` trait | `nested-crypto` | 无任何实现类型 |
| `nested_db::repositories::attachments` / `revisions` / `sync_operations` 的大部分函数 | `nested-db` | 已被 `notes.rs` 内部使用（`sync_note_links`、`revisions::insert`、`sync_operations::enqueue`），但**尚未**从 `nested-core` 暴露为业务 API（例如没有"列出笔记附件"的方法） |

### 10.3 核查中发现的文档不一致与实现隐患

以下条目是本次撰写时**逐文件核对**得到的，建议按 M3/V8 的流程处理（更新文档或登记技术债）：

| # | 位置 | 事实 | 影响 | 建议 |
|---|---|---|---|---|
| 1 | `README.md`「当前状态」、`docs/reports/gate-p0.md` §2 | 均称"客户端 **11** 个 crate"，而 `client/Cargo.toml` 的 `members` 有 **12** 项 | 数字对不上会让读者以为漏了一个 crate | 二者取一改齐（差额是 `tools/nested-rules`） |
| 2 | `client/apps/flutter/test/widget_test.dart` 第 7 行注释 | 称"Rust 侧已有 **147** 个测试"，而 README 与 gate-p0 记录为 **149** | 注释滞后，容易在复查时被当成口径冲突 | 更新注释，或改为不写具体数字 |
| 3 | `nested-core/src/api.rs` `save_note` 的 `# Errors` | 写作"**笔记本**标题/摘要非法 → `Validation`"，实际校验的是 `Note::set_title` / `Note::set_summary`（**笔记**） | 文档笔误 | 改为"笔记标题/摘要非法" |
| 4 | `nested-core/src/error.rs` `Conflict` 的 `user_hint()` 与 `api.rs` `create_tag` | 提示语是"内容已被其他设备修改，请查看冲突副本"，但**当前唯一产生点**是标签重名；且 `is_retryable()` 对 `Conflict` 为 `true` | 用户看到与原因不符的提示；若 UI 依赖 `is_retryable()` 自动重试，会重试一个确定性失败 | 拆分语义（如独立的 `Conflict`/`AlreadyExists` 或按来源区分 `user_hint`），并让"重名"不可重试 |
| 5 | `apps/rust/src/api/branding.rs` `start_engine` | 打开成功但**某项自检失败**时，`message` 仍为 `None`（`Ok` 分支硬编码 `None`），`ready = false` | 界面只能显示失败项名称（如 `integrity`），没有可读建议 | 在 `ready == false` 时填入相应提示（E2/E6） |
| 6 | FFI 契约 | `EngineStatus` 没有错误码字段，Dart 侧拿不到 `CoreError::code()` | E3"用户可见错误必须携带可在日志中检索的错误码"目前只有 CLI 满足 | 后续在 `EngineStatus`/统一的错误 DTO 中补 `code`（属破坏性变更，需按 §8.2 走 A10） |
| 7 | `nested-core/src/api.rs` `save_note` → `notes::save_with_document(..., None)` | `parent_revision_id` 恒为 `None`，即 `revisions` 的父链永不建立 | `Revision.parent_revision_id` 的用途是同步时判断分叉（`nested-sync::Conflict` 的 `common_ancestor_version` 也需要它），P6 前必须补齐 | P6 引入同步时补父链（需与 revision 读取 API 一起设计） |
| 8 | `nested-core/src/api.rs` `save_note` 无条件 `note.touch(at_ms)` | 即使标题、摘要、内容都没变，也会 `version += 1`、插入一条 `revisions`、入队一条 `sync_operations` | 无变更的自动保存会产生无意义的修订与同步流量（U4 的 debounce 保存路径很容易触发） | 保存前比较内容/元数据，或在文档层做"是否有变更"的判定 |
| 9 | `nested-core/src/api.rs` `readiness()` | `schema_current` 只验证"版本可读"（`schema_version().is_ok()`），**不比对** `migrations::LATEST_VERSION` | 实践中等价（`Database::open` 已完成迁移，版本过新会直接打开失败），但检查名容易被读成"已是最新" | 改为与 `LATEST_VERSION` 比对，或在文档中写明语义（本文已写明） |
| 10 | `nested-core/Cargo.toml`、`apps/rust/Cargo.toml` | 声明了 8 个 `nested-*` + `protocol`（core）与 `serde`/`serde_json`/`thiserror`/`tracing`/`uuid`/`time`（app），但 `src/` 未引用 | 读者容易误判"该能力已存在"；clippy 不检查未使用依赖 | 保留（属阶段性预留）但在设计文档与 Review 中明确（本文 §2.2 已写明） |
| 11 | `justfile` 第 4–6 行注释 | 注释宣传 `just check-client` / `just check-server`，但文件中**没有**定义这两个任务（实际只有 `check`、`check-format`、`check-lint`、`check-rules`、`test-client`、`test-server`） | 照注释执行会得到 just 的"未知配方"错误 | 补上两个任务，或修正注释 |
| 12 | `docs/adr/0004-rules-checker-in-rust.md` | 称"每条规则都有单元测试（22 个）"；实测 `nested-rules` 共 22 个真实 `#[test]`（`checks.rs` 14 + `report.rs` 4 + `fsutil.rs` 4），但其中**没有** B1（`required_files_present`）与 V6（`no_large_files`）的用例 | 这两条规则的判定逻辑改动时不会被测试拦住 | 补 B1/V6 的用例，或把 ADR 的措辞改为"多数规则" |
| 13 | `client/apps/flutter/test/ffi_integration_test.dart` | 直接 `import 'package:nested/src/rust/frb_generated.dart'` 并调用 `RustLib.init()`，与 `engine_providers.dart` 头注释"除本文件外任何地方都不得 import"的约定不一致 | 分层约定在测试里出现例外；若将来被当作范例复制到生产代码，A1/A2 就会被绕过（当前没有自动检查，见 §7） | 在注释中显式声明"测试可例外"，或把初始化收敛到一个测试辅助文件 |
| 14 | `client/apps/flutter/lib/app/app.dart` | `kBrandNameZh = '拾光笔记'` 是 Dart 侧唯一硬编码的品牌字符串（注释说明仅用于引擎就绪前的首屏占位） | 与"品牌名只有一个来源"（§3.8）存在一处已知副本；品牌改名时容易漏改 | 改为本地化资源 + 由 Rust 提供默认值，或加注释指向 `branding.rs`（铁律 F8 要求文案走本地化资源） |

---

## 11. 测试覆盖情况

### 11.1 `nested-core/src/api.rs` 的测试模块（9 个用例，逐一对应上文 API）

| 测试名 | 覆盖的 API | 验证的不变量 |
|---|---|---|
| `open_in_memory_is_ready` | `open_in_memory` / `readiness` / `schema_version` | 内存库打开后**三项就绪检查全部为真**；`schema_version() == nested_db::migrations::LATEST_VERSION` |
| `open_creates_database_file_in_data_dir` | `open` / `database_path` | 文件真实存在于数据目录，且路径以 `branding::DATABASE_FILE` 结尾 |
| `note_lifecycle_end_to_end` | `create_notebook` / `create_note_with_document` / `note_count` / `notebook_count` / `get_note` / `get_note_document` / `save_note` / `delete_note` / `list_notes` / `restore_note` | 端到端生命周期：计数正确；内容可读回；`save_note` 后 `saved.version == 2`；软删除后未删除计数为 0 而 `include_deleted: true` 仍能列出 1 条；恢复后计数回到 1 |
| `missing_note_is_not_found` | `get_note` | 不存在的 `Id::new()` 返回 `NotFound`，`error.code() == "NOT_FOUND"` |
| `duplicate_tag_is_conflict` | `create_tag` | 同名第二次创建返回 `CONFLICT`，且 `user_hint()` 含"冲突" |
| `invalid_title_is_validation_error` | `create_note` | 标题为 `MAX_TITLE_CHARS + 1` 个汉字时返回 `VALIDATION_ERROR`（按**字符**而非字节计数，铁律 U3） |
| `save_increments_version_and_leaves_pending_sync` | `save_note` / `pending_sync_count` | 保存一次后待同步操作数为 **1**（`create_note_with_document` 不入队，`save_with_document` 入队，两者边界被固定） |
| `notebooks_and_tags_are_listed` | `create_notebook` / `create_tag` / `list_notebooks` / `list_tags` | 各创建一条后列表长度均为 1 |
| `closing_and_reopening_keeps_data` | `open`（同一目录两次） | 关闭后重开，按 `id` 仍能读到 `title == "持久化"`（持久化不丢数据，T1） |

### 11.2 同一 crate 的其它测试

| 文件 | 用例数 | 测试名 | 验证的不变量 |
|---|---|---|---|
| `nested-core/src/error.rs` | 3 | `codes_are_stable_and_unique` | 8 个变体的 `code()` 互不重复 |
| | | `retryability_is_conservative` | `Network` 可重试；`NotImplemented`、`Validation` 不可重试 |
| | | `hints_never_leak_internals` | `user_hint()` 不含 `"SQL"`、`"rusqlite"` |
| `nested-core/src/branding.rs` | 4 | `chinese_locales_get_chinese_name` | `zh-CN` / `zh-Hans-CN` / `zh` → `BRAND_NAME_ZH` |
| | | `other_locales_get_english_name` | `en-US` / `ja` / `""` → `BRAND_NAME_EN` |
| | | `version_string_contains_app_version` | 版本串含 `CARGO_PKG_VERSION` 且以英文品牌名开头 |
| | | `engineering_id_stays_neutral` | `ENGINEERING_ID == "nested"` 且 `BRAND_SLUG != ENGINEERING_ID`（品牌与工程标识解耦） |

（`nested-core` 合计 16 个单元测试；另有 `lib.rs` 的文档示例（doctest）走完整流程：
`open_in_memory` → `create_note` → `get_note_document` → `save_note`，断言 `version == 2` 且
`branding::display_name("zh-CN") == "拾光笔记"`。）

### 11.3 FFI 桥接层（`client/apps/rust/src/api/branding.rs`，6 个用例）

| 测试名 | 验证的不变量 |
|---|---|
| `version_info_is_non_empty_and_exposes_protocol` | 四个字段非空，`protocol_version >= 1` |
| `display_name_follows_language` | `zh-CN` / `zh-Hans-CN` → 中文名；`en` → 英文名 |
| `start_engine_reports_ready_and_creates_database` | 空目录下 `ready == true`，`checks` 非空且全部通过，`database_path` 指向真实存在的文件 |
| `start_engine_is_idempotent_on_existing_directory` | 对已存在的库重复启动仍 `ready`（迁移不重复执行、不报错） |
| `start_engine_reports_failure_without_panicking` | 非法目录（父路径是文件）→ `!ready` 且 `message.is_some()` |
| `start_engine_rejects_unwritable_path_without_panicking` | Windows 保留字符路径 → `!ready` 且 `message.is_some()` |

### 11.4 相邻层（本文依赖的验证）

| 层 | 覆盖 |
|---|---|
| `nested-db` | `db.rs` 有 10 个测试（内存库到最新 schema、完整性检查、ping、文件库 WAL、外键开启、迁移幂等、`SchemaTooNew` 拒载、settings 往返覆盖、**事务失败整体回滚**、10 张表齐备）；`migrations.rs` 有 11 个测试（内置清单自洽与内嵌真实 SQL、版本跳跃/空 SQL 被拒、空清单 no-op、可注入清单生效并推进版本、已是最新时 no-op、版本过高拒载、**失败迁移整体回滚且版本不前进**、升级失败保留旧版本、迁移错误携带版本与名称）；`repositories/*` 各模块带测试（如 `notes.rs` 11 个）；`tests/migration_guard.rs` 迁移哈希护栏 |
| `nested-attachment` | 21 个测试（SHA-256 已知向量、64 位小写十六进制校验、流式哈希跨缓冲不丢内容、缺失文件报 `Io`、两级分片路径、非法哈希返回 `InvalidHash`、写入后读回、相同内容去重、不同内容不同路径、空内容、成功后无 `.tmp` 残留、`contains`、缺失内容 `NotFound`、篡改内容被 `verify`/`read` 检出 `HashMismatch`、`put_file` 往返与去重、缺失源文件报错、删除幂等、与 `Attachment::storage_key` 的布局交叉验证） |
| `nested-model` | `entity.rs`（9）、`block.rs`（7）、`document.rs`（8）、`id.rs`（3）、`time.rs`（3）均带单元测试（含"标题按字符而非字节计数"、"Attachment 拒绝大写/短哈希"、"storage_key 两级分片"）；`error.rs` 无测试模块 |
| Flutter | 3 个用例：`widget_test.dart` 2 个（外壳启动显示中文品牌名、刷新按钮可点）+ `ffi_integration_test.dart` 1 个（**真实调用 Rust**：加载 dll、临时目录建库、迁移、完整性校验，断言 `displayName == '拾光笔记'`、`databasePath` 真实存在且非空） |
| 门禁工具 | `nested-rules` 共 22 个单元测试（`checks.rs` 14、`report.rs` 4、`fsutil.rs` 4），覆盖 R1 / D2 / Q4 / A-ISOLATION / S3 的正反用例（含"测试模块内 unwrap 放行"、"注释中的依赖名不误报"、"常量列清单放行"、"关联表裸 DELETE 放行"）；**B1 与 V6 没有单元测试**（§10.3 #12） |

### 11.5 覆盖缺口（诚实记录）

- **失败路径不足**：`nested-core` 没有针对 `check_integrity` 失败、`schema_version` 失败、
  `readiness` 部分失败、`database()` / `database_path()`（内存库）的测试；`list_notes` 的分页上限
  （`limit == 0 → 50`、不超过 `MAX_PAGE_SIZE = 500`）在 `nested-db` 侧有断言
  （`notes.rs` 测试断言 `effective_limit()`），但 `nested-core` 层没有覆盖。
- **`list_note_tags` 无测试**：包括"笔记不存在时返回空列表"这一非直觉行为。
- **`delete_note` 的二次删除**（已在回收站再删一次 → `NotFound`）与 **`restore_note` 的非回收站恢复** 未在 `api.rs` 覆盖。
- **覆盖率阈值未度量**：铁律 Z1 要求核心 crate 行覆盖率 ≥ 80%，当前未安装 `cargo-llvm-cov`，
  门槛接入 CI 属 P1（gate-p0 §6 已列为"P1 必须补齐"）。
- **崩溃/损坏注入**（Z5）与**性能基准**（P1/P10）分别为 P4 范围，尚未开始。
- **API 兼容性测试缺失**：FFI 契约的形状（字段名、错误码字符串）没有"契约快照"测试，
  改动字段名只会在 Dart 侧编译期暴露（见 §8.3）。

---

## 参考

本文撰写时实际读取的文件（行号指本文核对时的内容）：

**代码（客户端 workspace）**

- `client/Cargo.toml` —— workspace 成员（12 项）、依赖版本、lint 基线
- `client/crates/nested-core/src/lib.rs`、`api.rs`、`error.rs`、`branding.rs`
- `client/crates/nested-core/Cargo.toml`
- `client/crates/nested-model/src/lib.rs`、`entity.rs`、`error.rs`
- `client/crates/nested-db/src/lib.rs`、`db.rs`、`error.rs`、`migrations.rs`、`repositories.rs`、`repositories/notes.rs`、`repositories/tags.rs`、`repositories/sync_operations.rs`（`repositories/attachments.rs`、`repositories/revisions.rs` 仅核对公开函数签名）
- `client/crates/nested-search/src/lib.rs`、`nested-attachment/src/lib.rs`、`nested-import/src/lib.rs`、`nested-export/src/lib.rs`、`nested-sync/src/lib.rs`、`nested-crypto/src/lib.rs`
- `client/apps/rust/Cargo.toml`、`src/lib.rs`、`src/api/mod.rs`、`src/api/branding.rs`、`src/frb_generated.rs`（仅核对生成物头部与导出符号）
- `client/apps/flutter/flutter_rust_bridge.yaml`、`pubspec.yaml`
- `client/apps/flutter/lib/app/app.dart`、`lib/core/engine.dart`、`lib/core/engine_providers.dart`
- `client/apps/flutter/test/widget_test.dart`、`test/ffi_integration_test.dart`
- `client/cli/src/main.rs`、`client/cli/Cargo.toml`
- `client/tools/nested-rules/src/checks.rs`、`rules.rs`、`main.rs`
- `shared/protocol/src/lib.rs`（仅核对 `PROTOCOL_VERSION`）

**文档与配置**

- `docs/02-工程铁律.md`（T4、A1–A10、D 组、Q 组、R 组、E1–E8、Z 组、B1/B5、M1–M3、附 A「已知的检查盲区」）
- `docs/01-开发计划.md`（P0–P7 任务、DoD、Gate；§2.1.3/2.1.4/2.1.5/2.1.6、§7.2、§8）
- `docs/design/README.md`（写作规范与命名顺序）
- `docs/adr/0002-split-client-server-workspaces.md`、`docs/adr/0003-migration-hash-guard.md`、`docs/adr/0004-rules-checker-in-rust.md`
- `docs/reports/gate-p0.md`、`docs/tech-debt.md`
- `README.md`、`justfile`、`.gitignore`、`.github/workflows/ci.yml`、`scripts/generate-ffi-bindings.ps1`

> **关于版本时效**：撰写期间仓库正处于 P1 实施中——`client/crates/nested-attachment/src/lib.rs`
> （CAS 读写落地）、`client/crates/nested-db/src/migrations.rs`（可注入清单）、`client/Cargo.toml`
> （新增 `sha2` 依赖）在核对过程中发生了变化。本文第 2、10、11 章的状态与测试数量按**最后一次核对**
> 时的代码写成。这些文件继续演进时，请按铁律 M3 在同一个 PR 内更新本文。
