# 变更日志

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与 [语义化版本](https://semver.org/lang/zh-CN/)。

> 依据《工程铁律》B6：每次发布必须有 tag、版本号、变更日志与产物校验和。
> 数据格式或数据库结构有破坏性变更时，必须在对应版本中写明**是否可回退**（铁律 B9/B10）。

## [Unreleased]

### 新增（三栏宽度可拖动 + 图标体系）

**三栏宽度均可拖动调整**

| 栏位 | 默认 | 范围 |
|---|---|---|
| 左栏（笔记本树） | 232 | 150 – 420 |
| 中栏（笔记列表） | 300 | 200 – 480 |
| 右栏（阅读/编辑） | 剩余空间 | 至少保底 260 |

- 两条分隔条（左\|中、中\|右）都可拖动
- **命中区域 8 逻辑像素**，视觉上只有 1–3 像素：1 像素的线用鼠标几乎抓不住
- 悬停/拖动时变粗并高亮；光标为系统的左右调整形状
- **右栏有保底宽度**：否则用户能把内容区挤到 0 宽，然后以为"笔记打开是空白的"
- 窗口过窄时按**比例**压缩左栏与中栏，保持两栏的相对关系，
  而不是把某一栏直接压到最小

**图标体系集中到 `lib/app/icons.dart`（单一来源 + 四条规则）**

修掉了两个真实缺陷：

- **差异性缺失**：所有笔记本不论层级都用 `folder_outlined`，
  第 1 层与第 5 层长得一样 —— "多层级"在视觉上等于没做
- **一致性缺失**：定义了 `kNoteIcon` 却从未使用（笔记列表行根本没有图标），
  "同一概念同形"这条规则实际上没被验证过

四条规则（写在 `icons.dart` 头部）：

1. **按概念定形** —— 形状只表达"这是什么"，同一概念在任何位置必须同形
2. **按层级定变体** —— 同一概念的不同层级用同一套图标的变体，
   既区分又可辨认出"它们是同类"
3. **状态用颜色** —— 选中/回收站等状态只改颜色，不改形状
4. **颜色只表达状态** —— 结构性图标用 `outline` 色，不与选中态抢注意力

具体映射（已核实所有字形互不重复）：

| 概念 | 图标 |
|---|---|
| 文件夹 · 第 1 层 | `folder`（实心，最"重"） |
| 文件夹 · 第 2 层 | `folder_open` |
| 文件夹 · 第 3 层及更深 | `folder_outlined`（最"轻"） |
| 笔记（任何位置） | `description_outlined` |
| 笔记 · 在回收站中 | 同一形状，只改颜色 + `delete_sweep_outlined` 状态标记 |
| 回收站开关 | `delete_outline` ↔ `delete`（两态用变体区分） |

### 测试
- Flutter 18 → 27：新增分栏拖动 4 个、图标体系 3 个
- 图标测试断言"第 1/2/3 层必须是三个不同图标"、
  "中栏每行笔记都带笔记图标且回收站中形状不变"——
  把差异性与一致性从肉眼评审变成可执行约束
- 分栏测试覆盖：分隔条数量、拖宽、拖窄、上下限、右栏不被挤掉

### 三栏主界面 + 多层级笔记本（上一轮）

**三栏布局（`lib/app/notes_page.dart` 重写）**

```text
┌────────────┬──────────────────┬──────────────────────────┐
│ 左栏        │ 中栏              │ 右栏                      │
│ 笔记本树     │ 笔记列表           │ 阅读 / 编辑区              │
└────────────┴──────────────────┴──────────────────────────┘
```

- **左栏**：多层级笔记本树（按深度缩进）、每个节点显示**子树笔记总数**、
  长按可新建子笔记本 / 移入回收站、可折叠给内容让位
- **中栏**：当前笔记本的笔记列表（标题 / 摘要 / 时间 / 修订号），
  在此新建笔记（直接建在当前笔记本下）、长按可移动或删除
- **右栏**：占位提示或编辑区（复用 `NoteEditorPane`）

**笔记本层级：数据层早就支持，这次补上三处缺口**

| 已有（P0） | 本次补齐 |
|---|---|
| `parent_id` 自引用外键 + `idx_notebooks_parent` | — |
| `list_children(parent_id)` | `list_notebook_tree()`（深度优先 + 深度 + 孤儿兜底） |
| `NoteQuery.notebook_id` | `NoteQuery.include_descendants`（递归 CTE 一次查完） |
| — | `rename_notebook` / `delete_notebook` / `restore_notebook` |
| — | FFI：`notebooks_tree` / `notebooks_create` / `notebooks_delete` / `notebooks_restore` / `notes_move` |

**"父级包含子孙笔记"的实现取舍**

用 `WITH RECURSIVE` 一条查询解决，而不是"先取子树再拼 `IN (...)`"：
拼接大量 id 既慢又容易踩注入（铁律 Q4），且两次往返会带来不一致窗口。
附 5 个测试覆盖：多层级、中间层、叶子层、软删子笔记、孤儿节点。

**孤儿节点不丢**

若某笔记本的 `parent_id` 指向不存在的节点（同步场景下对端可能先发子节点），
它在树里被当作**顶层**处理而不是消失。测试通过绕过外键注入坏数据来验证
——注意正常写入路径造不出这种数据（外键会直接拦下，这本身也值得记一笔）。

### 修复（本轮踩到并修掉的三个问题）

**1. `notebooks_tree` 把失败静默转成空列表 —— 我自己制造的错误设计**

第一版 FFI 签名是 `-> Vec<NotebookNode>`，失败时返回空 `Vec`。
于是"查询失败"与"确实没有笔记本"在界面上**长得一模一样**，
界面显示"还没有笔记本"，而用户会以为数据丢了。
改成返回 `NoteResult`（与其它 API 一致）后，问题立刻可见并被修掉。

**2. `notes_list` 没接笔记本过滤参数**：FFI 只透传 `include_deleted`，
面板按笔记本过滤时参数被静默忽略。已补 `notebook_id` / `include_descendants`。

**3. 界面诊断钩子挂错了生命周期**：最初用
`WidgetsBinding.addPostFrameCallback`，而它只在"页面重建"后排队——
`NotesPage.build` 当时只 watch 了 `engineProvider`，数据变化不触发重建，
于是**诊断永远不写**。表面现象是"诊断文件里没有三栏快照"，
我一度据此以为数据没加载出来；实际数据是好的、**只是观测手段没被触发**。
现改为 `ref.listen` 直接挂在 provider 上（见 `core/ui_diagnostics.dart`）。

### 变更
- 新增 `lib/core/notebook_providers.dart`（笔记本树 + 选中状态 + 写操作）
- 新增 `lib/core/ui_diagnostics.dart`：把"界面看到了什么"落盘为可断言的文件。
  放在 `core/` 而非页面里，因为①页面是展示层，不该为了可观测多知道一层数据细节；
  ②诊断要读 `lib/src/rust/**` 的类型，放页面会违反门禁 A-LAYERING
- `NoteListQuery` 取代原来的 `bool` 作为列表 provider 的参数（值对象，支持多条件）
- `StateProvider` → `NotifierProvider`（Riverpod 3 已移除前者的导出）
- `NoteEditorPage` 拆成"栏内面板 `NoteEditorPane` + 整页包装 `NoteEditorPage`"
- `seed_demo_notes.dart` 改为造**带层级的示例数据**（3 层笔记本 + 7 篇笔记）
- 新增 `tool/diag_notebooks.dart`（打印树与按笔记本过滤的结果）

### 测试
- Rust 263 个（+13：树形过滤 5 个、笔记本树 8 个）
- Flutter 15 个（+8：三栏部件、折叠、缩进、回收站切换、时间格式）
- Widget 测试改为**注入假数据**：直接 pump 只能测到"加载中"，
  注入后才能确定性地验证渲染结果，且不依赖文件系统与平台通道

### 修复（三项高危技术债 #8 / #10 / #12）

**#8 连接锁死锁陷阱 —— 现在会报错而不是静默挂起**
- `Database` 增加 `AtomicBool` 重入检测：持有连接时再次获取立即返回
  `DbError::ReentrantLock`，不再"卡住不动"（此前测试真实挂死过一次）
- 新增 `Database::with_connection(|c| ...)` 闭包式 API 作为推荐用法；
  `connection()` 保留（测试与 CLI 仍需要），另返回带 RAII 复位的 `ConnectionGuard`
- 区分了新的错误语义：`ReentrantLock`（开发期错误）、`LockPoisoned`（持锁线程 panic）、
  `Closed`（句柄已关闭），此前这些都被折叠成 `InvalidQuery`
- 6 个回归测试，逐条证明"误用报错而非挂起"

**#10 事务行为统一为 IMMEDIATE，嵌套在编译期不可能**
- 新增 `db::begin_write_transaction()`，所有写入口统一 `IMMEDIATE`：
  一开始就取写锁，冲突由 `busy_timeout` 排队，而不是"先读后写"到中途升级锁并随机失败
- 仓储写入口签名由 `&Connection` 改为 `&mut Connection`。
  这不只是风格问题：**`&mut` 使嵌套事务在类型层面不可能**，
  同时消除了 `unchecked_transaction()` 允许的静默嵌套
- 附两个不变量测试（`IMMEDIATE` 确实取到写锁、回滚确实撤销事务内建表）

**#12 同步入队缺口（最严重的一项）**
- 此前**只有** `save_with_document` 入队；现在改为全部本地写在同一事务内入队：
  笔记创建 / 软删 / 恢复、笔记本创建 / 重命名 / 软删 / 恢复、
  标签创建 / 删除、笔记标签设置
- 操作类型可区分：`note.create` / `note.update` / `note.delete` / `note.restore` /
  `note.tag` / `notebook.create` / `notebook.update` / `notebook.delete` /
  `notebook.restore` / `tag.create` / `tag.delete`
- `mark_accessed` **刻意不入队**并写明理由："最近查看"是本机习惯的副产品，
  同步它只会制造无意义流量
- 新增 `NestedCore::device_id()`：从 `settings` 解析并缓存设备标识，
  未注册时用 `UNKNOWN_DEVICE_ID` 兜底且**不擅自落库**（生成设备标识属于启动流程职责）

### 迁移 0002：修正 `sync_operations` 的外键设计（#12 的连带发现）
- **真实缺陷**：`0001` 里 `sync_operations.note_id` 是 `REFERENCES notes (id)`，
  但这张表在语义上是"通用实体变更队列"（铁律 T3 要求任何本地写都入队）。
  把笔记本/标签 id 写进这一列会直接触发 `787 FOREIGN KEY constraint failed`。
  该缺陷一直存在，只因"此前只有笔记更新入队"而从未暴露
- 迁移 0002 把列改名为多态 `entity_id` 并去掉外键（SQLite 无法表达多态外键），
  引用完整性改由写入路径保证；存量数据用 `LEFT JOIN notes` 清洗悬空引用后原样保留
- 按铁律 Q2 新增迁移而非修改已发布的 0001；哈希护栏与 `LATEST_VERSION` 同步更新
- **升级路径已实测**：构造 v1 库（含 1 笔记本 + 1 笔记 + 1 条旧队列记录）后用新代码打开，
  日志 `from=1 to=2 count=1`；升级后 `user_version=2`、数据完整保留、
  `foreign_key_check` 无违规、`integrity_check` = ok

### 变更
- 客户端测试用例数 204 → **218**
- 覆盖率：nested-db 94.8%（1921/2026 行）、nested-core 95.1%，6 项门禁全部达标

## [P1 准备] —— 覆盖率基线 + 详细设计文档

**测试覆盖率（铁律 Z1）**
- 新增 `scripts/coverage-gate.ps1` 并接入 CI：只对**已实现**的 crate 卡 80%，
  占位 crate 单独列出并写明"实现后必须并入清单"的原因，避免一刀切产生自欺指标
- 实测：nested-model 95.9%、nested-db 94.4%、nested-core 93.9%、
  nested-attachment 94.9%、nested-sync 100%、nested-rules 88.7%
- 客户端用例数由 149 增至 **204**

**详细设计文档（铁律 M1，共约 3100 行）**
- `docs/design/07-Document-Model设计.md` —— 13 种块类型逐字段、JSON 表示、
  行内标记的字节偏移取舍、格式版本演进规则、持久化与派生能力
- `docs/design/06-SQLite数据库设计.md` —— PRAGMA 基线逐项、10 张表逐列、
  22 条索引与查询路径对应、事务边界、迁移体系、损坏容错
- `docs/design/05-Rust-Core架构设计.md` —— 分层、12 个 crate 状态、
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
- 技术债登记表由 7 条扩至 **22 条**：设计文档审出的实现问题全部登记，
  其中 #8 / #10 / #12 三项高危已在同一轮内偿还（见上），
  #21 是修复 #12 时连带发现的真实架构缺陷（`sync_operations` 外键）
- 剩余待还：#11（`save_note` 无条件 touch 且父链恒空）、#13（软删标签无法复用同名）、
  #14（`Conflict` 语义混淆）、#16（首屏跑全库 integrity_check）、
  #17/#22（附件插入主路径与附件同步）、#18（分页上限未覆盖全部列表）

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
