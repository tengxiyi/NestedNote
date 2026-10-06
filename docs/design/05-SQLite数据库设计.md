# SQLite 数据库设计

> **本文档的权威来源是代码，不是本文档。**
> 表名、列名、索引名、PRAGMA 值、错误变体一律以
> `client/migrations/0001_init.sql` 与 `client/crates/nested-db/src/**` 为准。
> 本文档与代码冲突时：以代码为准，并且**必须**在同一个 PR 里修正本文档（铁律 M3）。
>
> **撰写基线**：本文档描述的是撰写时刻的工作区状态（表结构与 `nested-db` 为
> 已提交版本；`migrations.rs` 与 `nested-attachment` 含当时未提交的重构与实现）。
> 引用行号可能随重构漂移，**核对时以函数名与 SQL 文本为准**。

## 文档状态（诚实标注）

| 项 | 现状 | 位置 |
|---|---|---|
| 迁移文件 | **只有 1 条**：`0001_init`（`user_version = 1`） | `client/migrations/0001_init.sql` |
| 表 | **10 张**，全部已创建 | 同上 |
| 显式索引 | **11 条**（其中 2 条唯一索引） | 同上 |
| 迁移哈希护栏 | ✅ 已实现（含 LF 校验） | `client/crates/nested-db/tests/migration_guard.rs` |
| `PRAGMA integrity_check` | ✅ 已实现（CLI `doctor` / UI 首屏调用） | `client/crates/nested-db/src/db.rs` |
| FTS5 索引表 | ⬜ **未创建**（属 P1-12/P1-13） | 计划见 `docs/01-开发计划.md` §2.1.3 |
| 附件 CAS 落盘 | ✅ **已实现**：临时文件 → `fsync` → `rename` → 回读校验；`path_for` 对非法哈希返回错误而非 panic | `client/crates/nested-attachment/src/lib.rs` |
| 附件 GC 编排（引用检查 → 保留期 → 物理删除 → 日志/dry-run） | ⚠️ **部分**：`ContentStore::delete` 与 `list_unreferenced` 已就绪，但**没有任何代码把它们串起来**（`delete` 不做引用检查） | 同上（见 §6.4、§11.1、§11.3） |
| GC / 回收站清理（保留期、dry-run、日志） | ⬜ **未实现**（P1-17，且必须在 P6 同步可用之后） | — |
| 备份 / 恢复 | ⬜ **未实现**（P1-25/P1-26，只有常量与契约） | `client/crates/nested-export/src/lib.rs` |
| 连接池 | ⬜ **未引入**（P4 有基准数据后再评估） | — |
| 服务端 schema | ⬜ 与本文档**无关**，两端独立演进（铁律 Q12） | 见 `12-服务端架构设计.md` |

---

## 1. 设计目标与约束

### 1.1 为什么是 SQLite，而不是更复杂的数据库

| 需求（来自铁律） | SQLite 如何满足 | 为什么不上更重的东西 |
|---|---|---|
| T1 数据不可丢、崩溃后可打开 | WAL 日志 + 单文件事务，崩溃恢复由 SQLite 保证 | 引入独立服务进程反而多一个崩溃面 |
| T3 本地优先 | 数据库就是本地文件，无网络往返，写立即生效 | 远程数据库违反"离线可用"（A6） |
| T6 变更可追踪 | 同库内 `revisions` / `sync_operations` 事务写 | 无需额外消息中间件 |
| A6 单机功能不依赖服务端 | `nested.db` 自包含，服务端只在 P6 接入 | — |
| B4 构建可复现 | SQLite 随 `rusqlite` 静态链接，无外部依赖 | — |
| T8 文件不进数据库 | 附件走 CAS 目录，库内只存元数据与引用 | — |

"过早引入复杂数据库"在本项目具体指：为一个**单用户、本地、单进程写**的笔记应用引入
客户端-服务端数据库、ORM 或分布式 KV。当前规模下它们的成本（部署、依赖、调试面）
全部要用户承担，收益为零。**索引与查询设计**才是这一阶段的瓶颈（见 §5、§9）。

### 1.2 单写者模型

SQLite 在 WAL 模式下**同一时刻只允许一个写者**（多写者只会互相 `SQLITE_BUSY`）。
这不是本项目的选择，是 SQLite 的既有事实。因此设计上不做"多写连接并发写"的徒劳优化，
而是：

```text
一个 Database 句柄  →  一个 Connection  →  一把 Mutex  →  串行化的写
```

（`client/crates/nested-db/src/db.rs:60-65`，理由写在 `db.rs` 模块注释里。）

### 1.3 本地优先对写入路径的三条硬要求

| # | 要求 | 落点 |
|---|---|---|
| 1 | 一次业务操作**一个事务**，禁止多事务分步提交（D1） | `notes::create_with_document`、`notes::save_with_document` |
| 2 | 写失败**必须**整体回滚，不得留下半截数据（T1） | `with_transaction` + 仓储内的 `unchecked_transaction` |
| 3 | 写本地后**立即**可用，不等待任何网络结果（T3） | 仓储不发起任何 IO/网络（Q7） |

### 1.4 本文档的边界

- **覆盖**：客户端本地 SQLite（表、索引、约束、事务、迁移、分页、损坏处理）。
- **不覆盖**：服务端 PostgreSQL（Q12，见 `12-服务端架构设计.md`）、
  Document Model 的块结构（见 `06-Document-Model设计.md`）、
  FTS5 中文分词选型（见 `10-全文搜索设计.md`，须先有基准 + ADR）。

---

## 2. 连接与 PRAGMA 基线

实现位置：`client/crates/nested-db/src/db.rs` 的 `configure_pragmas()`（`db.rs:239-264`），
在 `from_connection()`（`db.rs:98-105`）中于**迁移之前**执行——先建立可靠的存储前提，
再改结构。

### 2.1 逐项基线

| PRAGMA | 实际值 | 作用 | 不设会怎样 |
|---|---|---|---|
| `journal_mode` | `WAL`（**仅文件库**；内存库保持 `memory`） | 写不阻塞读；崩溃恢复更快；多进程读友好 | 默认 `delete` 模式：写会阻塞读，`BUSY` 概率高；铁律 D12 明确要求 WAL |
| `synchronous` | `NORMAL`（文件库）/ `OFF`（内存库） | WAL 下 `NORMAL` 是"崩溃不损坏、断电最多丢最后若干次提交"的折中 | 默认 `FULL`：每次提交 fsync，写吞吐显著下降；`OFF` 在文件库上会牺牲崩溃安全，**故只对内存库用** |
| `foreign_keys` | `ON` | 让外键约束真正生效 | SQLite 默认 **OFF**，外键只是注释；软删除链上的悬空引用不会被发现（`db.rs` 测试断言"否则软删除链会写坏数据"） |
| `temp_store` | `MEMORY` | 临时表与排序走内存 | 默认 `FILE`：排序溢出到临时文件，慢且产生磁盘垃圾 |
| `wal_autocheckpoint` | `1000` 页 | WAL 满 1000 页自动做检查点 | 默认值恰好也是 1000；这里**显式写出**，避免"依赖默认值"在 SQLite 版本变更时悄悄漂移 |
| `cache_size` | `-65_536`（负值单位 KiB ⇒ **64 MiB**） | 页缓存上限 | 默认约 2 MiB，遍历索引会反复读页；同时它是**有界**的（R12），不是无上限 |
| `busy_timeout` | `5000` ms（`connection.busy_timeout`） | 锁冲突时等待而不是立刻失败 | 默认 0：任何瞬时写冲突都直接 `SQLITE_BUSY` |

常量定义：

```rust
const WAL_AUTOCHECKPOINT_PAGES: i64 = 1000;   // db.rs:21
const BUSY_TIMEOUT_MS: u64 = 5000;            // db.rs:24
pub const MAX_PAGE_SIZE: u32 = 500;           // db.rs:27
```

### 2.2 内存库与文件库在 WAL 上的差异处理

`PRAGMA journal_mode = WAL` 是**唯一一个会返回结果行**的 PRAGMA，因此这里用
`query_row` 而不是 `pragma_update`——只有读到返回值，才能知道 WAL 到底成没成：

```rust
let persistent = {
    let journal: String =
        connection.query_row("PRAGMA journal_mode = WAL", [], |row| row.get(0))?;
    journal.eq_ignore_ascii_case("wal")
};
connection.pragma_update(None, "synchronous", if persistent { "NORMAL" } else { "OFF" })?;
```

| 场景 | SQLite 行为 | 本项目的处理 |
|---|---|---|
| 文件库 | `journal_mode` 返回 `wal` | `persistent = true` → `synchronous = NORMAL` |
| 内存库（`open_in_memory`，测试与 CLI 快检） | WAL **不适用**，SQLite 静默返回 `memory` | `persistent = false` → `synchronous = OFF`，并打一条 `debug` 日志 |

为什么必须显式区分：如果不判断，内存库会"以为开了 WAL 其实没有"，
并且会误用 `synchronous = NORMAL`（对内存库毫无意义）。测试
`file_database_enables_wal` 专门断言文件库的 `journal_mode` 确实是 `wal`。

### 2.3 打开标志

```rust
const fn open_flags() -> OpenFlags {          // db.rs:228-233
    OpenFlags::SQLITE_OPEN_READ_WRITE
        .union(OpenFlags::SQLITE_OPEN_CREATE)
        .union(OpenFlags::SQLITE_OPEN_NO_MUTEX)
        .union(OpenFlags::SQLITE_OPEN_URI)
}
```

| 标志 | 为什么 |
|---|---|
| `READ_WRITE` + `CREATE` | 首次启动即建库；`Database::open` 还会 `create_dir_all` 父目录（`db.rs:77-82`） |
| `NO_MUTEX` | 多线程模式：连接可被多线程使用，但**不允许并发使用**。本项目用 `Mutex<Connection>` 自己串行化（R11 要求同步原语显式声明）；再叠 SQLite 内部互斥是冗余开销 |
| `URI` | 允许 `file:` URI（未来用于只读打开、共享缓存等诊断场景） |

### 2.4 未设置的 PRAGMA（诚实清单）

| PRAGMA | 现状 | 说明 |
|---|---|---|
| `mmap_size` | ⬜ 未设置 | P4 有基准数据后再评估（铁律 P2：先测量再优化） |
| `optimize` | ⬜ 未调用 | 铁律 Q9 允许空闲时增量优化，属 P1/P4 |
| `auto_vacuum` / `VACUUM` | ⬜ 未启用 | Q9 明确禁止在启动关键路径做全量 `VACUUM` |
| `secure_delete` | ⬜ 未设置 | S10"彻底删除"要求属于 P1 之后，需先定策略（默认值即可不设） |
| `journal_size_limit` | ⬜ 未设置 | `wal_autocheckpoint` 已控制 WAL 增长，暂不额外限制 |

---

## 3. 连接模型

### 3.1 当前：单写入连接 + 互斥锁（已实现）

```rust
pub struct Database {
    connection: Option<Mutex<Connection>>,   // None 仅表示"已关闭"
    path: Option<PathBuf>,                   // 内存库为 None
}
```

（`client/crates/nested-db/src/db.rs:58-65`）

| 事实 | 证据 |
|---|---|
| 每个 `Database` 只有一个 `Connection` | `db.rs:61` |
| 所有访问都先拿锁 | `Database::connection()` 返回 `MutexGuard`（`db.rs:128-135`） |
| 锁竞争时**阻塞等待**，不失败 | `Mutex::lock` + `busy_timeout` 双层等待 |
| 内存库没有路径 | `path()` 返回 `None`；`file_size_bytes()` 返回 `None` |

### 3.2 为什么这样选

`db.rs` 模块注释（`db.rs:1-10`）给出的三条理由，原文照录并补充后果：

1. **SQLite 在 WAL 下同一时刻只允许一个写者**——多写连接只会互相 `SQLITE_BUSY`，
   不会更快。
2. **第一阶段（P1/P2）的瓶颈在索引与查询设计，不在连接数**——先把 §5 的索引和 §9 的
   查询路径做对，收益远大于连接池。
3. **引入连接池属于性能优化，必须有 P4 的基准数据支撑**（铁律 P2：禁止以"感觉慢"为由重构）。

补充一条架构理由：单连接 + 单锁让"一次业务操作 = 一个事务"（D1）天然成立，
不存在"两个线程各自开事务写同一业务对象"的竞态。

### 3.3 多读者优化何时做（P4）

| 项 | 结论 |
|---|---|
| 触发条件 | P4 阶段 `criterion` 基准证明"读等待写锁"是瓶颈（P1/P10 要求报告可复现） |
| 候选方案 | 只读连接池（N 个 reader + 1 个 writer），WAL 下天然支持多读者 |
| 前置约束 | R12：连接数必须有上限；R11：必须显式声明同步原语与不变量 |
| 现状 | **不做**。当前无基准数据，任何连接池设计都是猜（铁律 P2） |

用户视角的一个已知限制：UI 上的长查询会短暂阻塞写操作。当前数据量下不可感知；
P4 会用基准数据回答"是否可感知"。

---

## 4. 表结构总览

全部 10 张表来自**唯一**的迁移文件 `client/migrations/0001_init.sql`。
下文逐列抄录，与文件逐字一致；"领域类型"列是 `nested-model` 中对应的 Rust 类型。

### 4.0 表与关系

```text
notebooks ──parent_id──┐ (自引用，可嵌套成树)
    ▲                  │
    │ notebook_id      │
    │                  │
  notes ──1:1── documents            (note_id 既是主键又是外键)
    │  ▲
    │  └──1:N── revisions            (note_id + version，追加型审计)
    │  ├──N:M── tags      via note_tags
    │  ├──N:M── attachments via note_attachments
    │  └──1:N── sync_operations      (pushed_at_ms IS NULL = 待推送)

settings                              (独立键值表，与业务实体无关)
```

### 4.1 `notebooks` —— 笔记本（可嵌套成树）

```sql
CREATE TABLE notebooks (
    id            BLOB PRIMARY KEY,
    name          TEXT    NOT NULL,
    parent_id     BLOB    REFERENCES notebooks (id),
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);
```

| 列名 | 类型 | 约束 / 默认值 | 领域类型 | 说明 |
|---|---|---|---|---|
| `id` | BLOB | PRIMARY KEY | `Id`（UUIDv7，16 字节） | 时间有序，B-tree 局部性好（D7） |
| `name` | TEXT | NOT NULL | `String` | 长度 1..=256，由 `nested-model` 校验（`MAX_NOTEBOOK_NAME_CHARS`） |
| `parent_id` | BLOB | `REFERENCES notebooks (id)`（可空） | `Option<Id>` | 自引用构成树；`NULL` = 顶层 |
| `created_at_ms` | INTEGER | NOT NULL | `i64` | UTC 毫秒（D8） |
| `updated_at_ms` | INTEGER | NOT NULL | `i64` | 重命名/软删除都会刷新 |
| `deleted_at_ms` | INTEGER | 可空 | `Option<i64>` | `NULL` = 存活；非空 = 在回收站（T7） |

**为什么这样设计**

- 树用**邻接表 + 自引用外键**，不用嵌套集/物化路径：笔记本树的深度与规模都很小，
  邻接表最直观，且移动子树只是一条 `UPDATE`。
- **没有 `is_deleted` 布尔列**：用 `deleted_at_ms IS NULL` 表达存活。两个字段表达同一件事
  必然产生不一致状态（`is_deleted=1` 但 `deleted_at_ms IS NULL`），少一个字段少一类 bug。
- 外键**不带 `ON DELETE`**：物理删除笔记本应当失败（D2/T7），而不是悄悄级联删掉整个子树。

### 4.2 `notes` —— 笔记

```sql
CREATE TABLE notes (
    id             BLOB PRIMARY KEY,
    notebook_id    BLOB    REFERENCES notebooks (id),
    title          TEXT    NOT NULL DEFAULT '',
    summary        TEXT    NOT NULL DEFAULT '',
    created_at_ms  INTEGER NOT NULL,
    updated_at_ms  INTEGER NOT NULL,
    accessed_at_ms INTEGER,
    is_pinned      INTEGER NOT NULL DEFAULT 0,
    is_archived    INTEGER NOT NULL DEFAULT 0,
    deleted_at_ms  INTEGER,
    version        INTEGER NOT NULL DEFAULT 1
);
```

| 列名 | 类型 | 约束 / 默认值 | 领域类型 | 说明 |
|---|---|---|---|---|
| `id` | BLOB | PRIMARY KEY | `Id` | UUIDv7 |
| `notebook_id` | BLOB | `REFERENCES notebooks (id)`（可空） | `Option<Id>` | `NULL` = 未归类 |
| `title` | TEXT | NOT NULL DEFAULT `''` | `String` | **允许空串**（0..=512 字符）：新建笔记时用户还没输入 |
| `summary` | TEXT | NOT NULL DEFAULT `''` | `String` | 0..=512 字符，由内核生成或用户设置 |
| `created_at_ms` | INTEGER | NOT NULL | `i64` | UTC 毫秒 |
| `updated_at_ms` | INTEGER | NOT NULL | `i64` | 列表默认排序键 |
| `accessed_at_ms` | INTEGER | 可空 | `Option<i64>` | "最近查看"；由 `mark_accessed` 单独更新 |
| `is_pinned` | INTEGER | NOT NULL DEFAULT `0` | `bool` | SQLite 无布尔类型，用 0/1（`bool_to_int` / `bool_at`） |
| `is_archived` | INTEGER | NOT NULL DEFAULT `0` | `bool` | 归档，不参与默认列表 |
| `deleted_at_ms` | INTEGER | 可空 | `Option<i64>` | 回收站时间 |
| `version` | INTEGER | NOT NULL DEFAULT `1` | `i64` | 修订号，与 `revisions.version` 对应（T6） |

**为什么这样设计**

- `title`/`summary` 用 `NOT NULL DEFAULT ''` 而不是可空：字符串列上的 `NULL` 与 `''`
  会分裂出两套"空"语义，查询与 UI 都要写两遍判断。
- `accessed_at_ms` 可空且**不**参与 `updated_at_ms`：查看笔记不应把它顶到"最近修改"首位。
- `version` 由调用方递增（`Note::touch()` 用 `saturating_add(1)`），
  **不是**数据库自增列：跨设备同步需要一个可比较的版本号，而不是本地行号。

### 4.3 `tags` —— 标签

```sql
CREATE TABLE tags (
    id            BLOB PRIMARY KEY,
    name          TEXT    NOT NULL,
    created_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);
```

| 列名 | 类型 | 约束 / 默认值 | 领域类型 | 说明 |
|---|---|---|---|---|
| `id` | BLOB | PRIMARY KEY | `Id` | UUIDv7 |
| `name` | TEXT | NOT NULL | `String` | 1..=128 字符；**全局唯一（忽略大小写）**，见 §5 的 `idx_tags_name_unique` |
| `created_at_ms` | INTEGER | NOT NULL | `i64` | UTC 毫秒 |
| `deleted_at_ms` | INTEGER | 可空 | `Option<i64>` | 墓碑 |

**为什么这样设计**

- 标签**没有** `updated_at_ms`：重命名尚未实现；将来若加，必须同时加列（走新迁移）。
- 唯一性靠 **schema 约束**而不是应用层查重（Q11）：并发或崩溃都不会绕过它。
- 忽略大小写用 `COLLATE NOCASE` 建在**索引**上，而不是改列定义——这样列本身仍是
  普通 TEXT，比较语义集中在一处。

### 4.4 `note_tags` —— 笔记 ↔ 标签

```sql
CREATE TABLE note_tags (
    note_id     BLOB    NOT NULL REFERENCES notes (id),
    tag_id      BLOB    NOT NULL REFERENCES tags (id),
    tagged_at_ms INTEGER NOT NULL,
    PRIMARY KEY (note_id, tag_id)
);
```

| 列名 | 类型 | 约束 / 默认值 | 领域类型 | 说明 |
|---|---|---|---|---|
| `note_id` | BLOB | NOT NULL，`REFERENCES notes (id)`，复合主键之一 | `Id` | — |
| `tag_id` | BLOB | NOT NULL，`REFERENCES tags (id)`，复合主键之一 | `Id` | — |
| `tagged_at_ms` | INTEGER | NOT NULL | `i64` | 打标签时间 |

**为什么这样设计**

- 复合主键 `(note_id, tag_id)` 即"同一对关系只能有一行"，幂等由 schema 保证
  （`attach` 里再叠一层 `ON CONFLICT DO NOTHING`，见 `tags.rs:100-105`）。
- 表**没有**自增 id、没有 `deleted_at_ms`：这是一张**纯关联表**，行的存在与否完全由
  两侧实体决定。因此它是允许物理删除的（§6.3）。
- 复合主键列顺序 `(note_id, tag_id)` 决定了它的自动索引服务于"按笔记查标签"；
  反向查询"按标签查笔记"由额外的 `idx_note_tags_tag` 覆盖（§5）。

### 4.5 `attachments` —— 附件元数据

```sql
CREATE TABLE attachments (
    id            BLOB PRIMARY KEY,
    sha256        TEXT    NOT NULL,
    mime_type     TEXT    NOT NULL,
    size_bytes    INTEGER NOT NULL,
    filename      TEXT    NOT NULL,
    ref_count     INTEGER NOT NULL DEFAULT 0,
    created_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);
```

| 列名 | 类型 | 约束 / 默认值 | 领域类型 | 说明 |
|---|---|---|---|---|
| `id` | BLOB | PRIMARY KEY | `Id` | UUIDv7（**不是**哈希，哈希是另一列） |
| `sha256` | TEXT | NOT NULL，**UNIQUE**（见 §5） | `String` | 64 位小写十六进制，由 `Attachment::new` 校验 |
| `mime_type` | TEXT | NOT NULL | `String` | **必须**由内容嗅探得出（S6），不信任扩展名 |
| `size_bytes` | INTEGER | NOT NULL | `u64`（读写经 `u64_to_i64` / `i64_to_u64`） | 负数会被判为 `DbError::Corrupt`（禁止静默截断） |
| `filename` | TEXT | NOT NULL | `String` | 1..=255 字符；**仅用于展示，不参与标识** |
| `ref_count` | INTEGER | NOT NULL DEFAULT `0` | `i64` | 引用计数（推导值，见下） |
| `created_at_ms` | INTEGER | NOT NULL | `i64` | UTC 毫秒 |
| `deleted_at_ms` | INTEGER | 可空 | `Option<i64>` | 墓碑时间，保留期后才可 GC（T7/D9） |

**为什么这样设计**

- **文件本体绝不入库**（T8）：表里只有元数据，字节流在内容寻址存储
  `attachments/<前2位>/<次2位>/<完整 SHA-256>` 中（§5.4）。
- `id` 与 `sha256` 分开：`id` 是稳定引用目标（图/链接指向它），`sha256` 是去重与完整性
  校验依据。二者职责不同，合并会导致"同一内容换一次文件名就换 id"。
- `ref_count` **是从 `note_attachments` 推导出来的缓存**，不是权威来源：
  `refresh_ref_count()` 执行 `SELECT COUNT(*) FROM note_attachments WHERE attachment_id = ?1`
  再写回该列（`attachments.rs:99-110`）。`list_unreferenced()` 同时用
  `ref_count <= 0` **和** `NOT EXISTS(...)` 双重条件（`attachments.rs:177-187`），
  因此即使计数陈旧也不会误判 GC 候选。

### 4.6 `note_attachments` —— 笔记 ↔ 附件引用

```sql
CREATE TABLE note_attachments (
    note_id       BLOB    NOT NULL REFERENCES notes (id),
    attachment_id BLOB    NOT NULL REFERENCES attachments (id),
    linked_at_ms  INTEGER NOT NULL,
    PRIMARY KEY (note_id, attachment_id)
);
```

| 列名 | 类型 | 约束 / 默认值 | 领域类型 | 说明 |
|---|---|---|---|---|
| `note_id` | BLOB | NOT NULL，`REFERENCES notes (id)`，复合主键之一 | `Id` | — |
| `attachment_id` | BLOB | NOT NULL，`REFERENCES attachments (id)`，复合主键之一 | `Id` | — |
| `linked_at_ms` | INTEGER | NOT NULL | `i64` | 建立引用的时间 |

**为什么这样设计**

- 与 `note_tags` 同构：内容寻址存储让"解除引用"不等于"删文件"，因此引用表可以放心
  做物理删除（解除引用只是少一行，文件仍在 CAS 中，D2 白名单据此放行）。
- 复合主键 `(note_id, attachment_id)` 让 `sync_note_links` 的"新增缺失"天然幂等
  （`ON CONFLICT (note_id, attachment_id) DO NOTHING`，`attachments.rs:146-151`）。
- 引用关系**不因笔记软删除而消失**：恢复回收站里的笔记后，图片还在。代价是
  "只被回收站笔记引用的附件"不会进入 GC 候选，这是刻意的（见 §6.4）。

### 4.7 `documents` —— 结构化文档内容

```sql
CREATE TABLE documents (
    note_id       BLOB PRIMARY KEY REFERENCES notes (id),
    format        TEXT    NOT NULL,
    format_version INTEGER NOT NULL,
    content       BLOB    NOT NULL,
    updated_at_ms INTEGER NOT NULL
);
```

| 列名 | 类型 | 约束 / 默认值 | 领域类型 | 说明 |
|---|---|---|---|---|
| `note_id` | BLOB | PRIMARY KEY，`REFERENCES notes (id)` | `Id` | **既是主键又是外键**：一篇笔记最多一份文档 |
| `format` | TEXT | NOT NULL | `String` | 格式标识，当前为 `"nested.blocks"`（`DocumentMetadata::FORMAT`） |
| `format_version` | INTEGER | NOT NULL | `u32` | 当前 `DOCUMENT_FORMAT_VERSION = 1` |
| `content` | BLOB | NOT NULL | `Vec<u8>` | **JSON 字节**（`Document::to_bytes`），不是 HTML/Markdown（T5） |
| `updated_at_ms` | INTEGER | NOT NULL | `i64` | 来自文档元信息 |

**为什么这样设计**

- 文档**单独一张表**而不是塞进 `notes` 的一个 BLOB 列：`notes` 是列表页高频读取的表
  （T9/P4），把可能很大的 JSON 放在同一行会让列表查询顺带读出整篇正文。
- `note_id` 做 PRIMARY KEY 而不是另加 id：一对一关系用共享主键最简单，且自动获得
  "一篇笔记不可能有两份文档"的约束。
- `format` / `format_version` 是**列**而不是只放在 JSON 里：这样即使不解析 JSON
  也能判断"这份文档我能不能读"（未来做惰性加载时尤其重要）。
- 版本演进规则写在 `nested-model/src/document.rs` 模块注释：新增块类型或可选字段**不**升版本；
  删字段/改语义/改必需性**必须**升版本并提供迁移函数。

### 4.8 `revisions` —— 修订记录（追加型审计）

```sql
CREATE TABLE revisions (
    id                 BLOB PRIMARY KEY,
    note_id            BLOB    NOT NULL REFERENCES notes (id),
    version            INTEGER NOT NULL,
    parent_revision_id BLOB    REFERENCES revisions (id),
    created_at_ms      INTEGER NOT NULL,
    device_id          TEXT    NOT NULL,
    operation          TEXT    NOT NULL
);
```

| 列名 | 类型 | 约束 / 默认值 | 领域类型 | 说明 |
|---|---|---|---|---|
| `id` | BLOB | PRIMARY KEY | `Id` | UUIDv7 |
| `note_id` | BLOB | NOT NULL，`REFERENCES notes (id)` | `Id` | 所属笔记 |
| `version` | INTEGER | NOT NULL | `i64` | 与 `notes.version` 对应 |
| `parent_revision_id` | BLOB | `REFERENCES revisions (id)`（可空） | `Option<Id>` | 自引用链；`NULL` = 首版。同步时用于判断分叉 |
| `created_at_ms` | INTEGER | NOT NULL | `i64` | UTC 毫秒 |
| `device_id` | TEXT | NOT NULL | `String` | 产生该变更的设备（冲突归因） |
| `operation` | TEXT | NOT NULL | `String` | 操作类型，如 `"note.create"` / `"note.update"` |

**为什么这样设计**

- 本模块只**追加**，不修改、不删除（`revisions.rs` 模块注释）：修订历史是审计材料，
  任何"更新一条 revision"的操作都意味着审计链被污染。
- `parent_revision_id` 自引用形成**链**，而不是只存版本号：多设备并发时，
  两条 version 相同的修订可以通过父指针判断谁基于谁——这是 D10"禁止静默覆盖"的数据基础。
- 注意：**没有** `deleted_at_ms`。修订不是业务实体，不参与软删除；其生命周期跟随笔记
  （目前也没有删除路径，属 P7 版本历史特性范围）。

### 4.9 `sync_operations` —— 待同步操作队列

```sql
CREATE TABLE sync_operations (
    id            BLOB PRIMARY KEY,
    note_id       BLOB    REFERENCES notes (id),
    device_id     TEXT    NOT NULL,
    operation     TEXT    NOT NULL,
    payload       BLOB,
    created_at_ms INTEGER NOT NULL,
    pushed_at_ms  INTEGER
);
```

| 列名 | 类型 | 约束 / 默认值 | 领域类型 | 说明 |
|---|---|---|---|---|
| `id` | BLOB | PRIMARY KEY | `Id` | 入队时生成（`Id::new()`） |
| `note_id` | BLOB | `REFERENCES notes (id)`（可空） | `Option<Id>` | 关联笔记；可空是为将来的非笔记操作留位 |
| `device_id` | TEXT | NOT NULL | `String` | 产生该操作的设备 |
| `operation` | TEXT | NOT NULL | `String` | 如 `"note.update"` |
| `payload` | BLOB | 可空 | `Option<Vec<u8>>` | 变更负载（JSON 字节） |
| `created_at_ms` | INTEGER | NOT NULL | `i64` | 入队时间，也是消费顺序键 |
| `pushed_at_ms` | INTEGER | 可空 | `Option<i64>` | `NULL` = **待推送**；非空 = 已推送 |

**为什么这样设计**

- 用 `pushed_at_ms IS NULL` 表示"待推送"，而不是布尔列 + 单独的删除：
  推送成功后只更新一列，记录仍在表里（可做审计与重放）。
- 队列与业务写在**同一事务**（`save_with_document` 内调用 `enqueue`），
  因此"本地已保存但没进同步队列"这种状态在提交层面不可能出现（T3）。
- 消费顺序是 `created_at_ms ASC, rowid ASC`：同一毫秒内按插入顺序，避免同毫秒乱序。
- ⚠️ 现状只有 `notes::save_with_document` 会入队，见 §11.2 第 1 条。

### 4.10 `settings` —— 键值设置

```sql
CREATE TABLE settings (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    updated_at_ms INTEGER NOT NULL
);
```

| 列名 | 类型 | 约束 / 默认值 | 领域类型 | 说明 |
|---|---|---|---|---|
| `key` | TEXT | PRIMARY KEY | `String` | 设置项名 |
| `value` | TEXT | NOT NULL | `String` | 值（字符串化） |
| `updated_at_ms` | INTEGER | NOT NULL | `i64` | 最近写入时间 |

**为什么这样设计**

- `key` 直接用 TEXT 主键：设置项数量小、按名访问，无需代理 id。
- 写入用 `INSERT ... ON CONFLICT (key) DO UPDATE`（`db.rs:203-211`），
  一条语句完成"存在则覆盖"，不存在"先查后写"的竞态。
- **禁止**在此存放密钥/token（D11 / S2）：密钥必须进平台安全存储。
  代码注释（`db.rs:198`）明确写了这条禁令。

### 4.11 跨表约定

| 约定 | 内容 | 落地 |
|---|---|---|
| 主键 | 一律 16 字节 BLOB 的 UUIDv7 | 文件头注释 D7；`Id::new()` = `Uuid::now_v7()` |
| 时间 | 一律 INTEGER UTC 毫秒 | 文件头注释 D8；无任何本地时间字符串 |
| 删除 | 一律 `deleted_at_ms` 软删除 | 文件头注释 T7/D2；`notes`/`notebooks`/`tags`/`attachments` 有该列 |
| 约束 | 主键/非空/唯一/外键/默认值写在 schema 里 | 文件头注释 Q11 |
| 表清单 | 由测试强制：10 张表缺一即失败 | `db.rs` 测试 `expected_tables_exist` |

---

## 5. 索引清单

`0001_init.sql` 中**显式创建**的索引共 **11 条**（2 条唯一索引）。

### 5.1 全部显式索引

| # | 索引名 | 定义 | 唯一 | 服务的查询 |
|---|---|---|---|---|
| 1 | `idx_notebooks_parent` | `notebooks (parent_id)` | 否 | `notebooks::list_children`（`WHERE ... parent_id = ?1`）；父行外键检查 |
| 2 | `idx_notes_updated` | `notes (updated_at_ms DESC)` | 否 | `notes::list` 的 `ORDER BY is_pinned DESC, updated_at_ms DESC` 第二键；"最近修改"视图 |
| 3 | `idx_notes_notebook` | `notes (notebook_id, deleted_at_ms)` | 否 | `notes::list` 的笔记本过滤 + 未删除过滤（`deleted_at_ms IS NULL`） |
| 4 | `idx_notes_deleted` | `notes (deleted_at_ms)` | 否 | 回收站视图；`notes::count(include_deleted=false)` 的未删除统计 |
| 5 | `idx_notes_pinned` | `notes (is_pinned, updated_at_ms DESC)` | 否 | `ORDER BY is_pinned DESC, updated_at_ms DESC`；置顶优先的列表 |
| 6 | `idx_tags_name_unique` | `tags (name COLLATE NOCASE)` | **是** | `tags::find_by_name`（`name = ?1 COLLATE NOCASE`）；`tags::insert` 的重名冲突检测 |
| 7 | `idx_note_tags_tag` | `note_tags (tag_id)` | 否 | 反向查询"某标签下的笔记"（查询尚未实现，索引已就位）；`tags` 行删除时的外键检查 |
| 8 | `idx_attachments_sha256` | `attachments (sha256)` | **是** | `attachments::find_by_sha256`；`upsert` 的 `ON CONFLICT (sha256)` 去重；`SELECT id FROM attachments WHERE sha256 = ?1` |
| 9 | `idx_note_attachments_attachment` | `note_attachments (attachment_id)` | 否 | `refresh_ref_count` 的 `COUNT(*)`；`list_unreferenced` 的 `NOT EXISTS`；外键检查 |
| 10 | `idx_revisions_note` | `revisions (note_id, version DESC)` | 否 | `revisions::list_for_note` / `latest_for_note`（`ORDER BY version DESC LIMIT n`） |
| 11 | `idx_sync_operations_pending` | `sync_operations (pushed_at_ms)` | 否 | `sync_operations::list_pending` / `pending_count`（`WHERE pushed_at_ms IS NULL`） |

两条唯一索引的**业务含义**（这是它们与普通索引最大的区别）：

| 唯一索引 | 它保证的业务不变量 | 违反时的错误 |
|---|---|---|
| `idx_tags_name_unique` | 全库不可能出现两个同名标签（忽略大小写），避免"工作"与"工作 "并存 | `DbError::Conflict { entity: "tag" }`（由 `tags::insert` 把 `ConstraintViolation` 翻译而来） |
| `idx_attachments_sha256` | 同一内容在全库只存一条元数据——这是**内容寻址去重的落地方式** | 不去重：`upsert` 命中冲突后刷新文件名并清墓碑，返回既有 id |

### 5.2 隐式索引（SQLite 自动创建）

除上表外，每张表的 `PRIMARY KEY` 在 rowid 表上由 SQLite 建**自动索引**
（命名形如 `sqlite_autoindex_<表名>_1`）。它们不在迁移文件里，也不应在代码中被引用。

| 表 | 主键 | 自动索引服务的访问 |
|---|---|---|
| `notebooks` / `notes` / `tags` / `attachments` / `revisions` | `id` | 所有 `get(id)` 与 `WHERE id = ?1` 更新 |
| `documents` | `note_id` | `get_document` / `upsert_document` 的 `ON CONFLICT (note_id)` |
| `note_tags` | `(note_id, tag_id)` | 按笔记查标签（`list_for_note`）、`attach` 的冲突检测 |
| `note_attachments` | `(note_id, attachment_id)` | `sync_note_links` 读既有引用、`ON CONFLICT` 幂等插入 |
| `settings` | `key` | `setting` / `set_setting` |

> 列顺序很关键：复合主键 `(note_id, tag_id)` 的自动索引只能高效服务"以 `note_id` 为前缀"
> 的查询；"以 `tag_id` 查笔记"必须靠 `idx_note_tags_tag`。`note_attachments` 同理。

### 5.3 索引与查询路径的对应（诚实限定）

上表的对应关系是**按 SQL 形态推导**的。仓库中**尚无** `EXPLAIN QUERY PLAN` 记录——
铁律 Q5 要求"新增列表/搜索/统计查询必须附 `EXPLAIN QUERY PLAN` 结果"，
这属于 P1-8 / P4-5 的待办（`docs/01-开发计划.md`）。

需要在 P1 补做验证的三处（不带结论，只列疑点）：

| 查询 | 疑点 |
|---|---|
| `notes::list` 的 `WHERE (?1 IS NULL OR notebook_id = ?1)` | 参数化 + `OR` 形式可能让优化器放弃 `idx_notes_notebook` |
| `notebooks::list_all` / `tags::list_all` 的 `ORDER BY name ASC` | **没有** `name` 索引 → 排序需临时 B-tree（小表可接受，但要 EXPLAIN 确认） |
| `sync_operations::list_pending` 的 `ORDER BY created_at_ms ASC, rowid ASC` | 只有 `pushed_at_ms` 索引 → 排序需临时 B-tree |

### 5.4 常见混淆：两级分片与索引**无关**

内容寻址存储的路径 `attachments/<前2位>/<次2位>/<完整 SHA-256>`
（例如 `8f/14/8f14e45f…`）是**文件系统**的目录分片：

| 事实 | 位置 |
|---|---|
| 路径由哈希前 4 个字符分两级生成 | `nested_model::Attachment::storage_key()`（`entity.rs:264-275`）；`nested_attachment::ContentStore::path_for()`（返回 `AttachmentResult<PathBuf>`，非法哈希 → `AttachmentError::InvalidHash`） |
| 分片目的 | 避免单个目录下文件过多（**不是**为了查询性能） |
| 数据库侧的去重键 | 是唯一索引 `idx_attachments_sha256`，与目录分片没有关系 |
| 落盘状态 | ✅ 已实现：`ContentStore::put_bytes` / `put_file` 做 **临时文件 → `fsync` → `rename` → 回读校验**（D3/D4），命中已有内容时返回 `deduplicated = true`（T8 去重） |
| 布局一致性 | ✅ 有交叉验证测试：`layout_matches_attachment_storage_key` 断言 `ContentStore::path_for` 与 `Attachment::storage_key` 的路径完全一致——否则库里的 `sha256` 会指向不存在的文件 |

**不要**把 `ab/cd` 当作"两列分片键"或"复合索引"。库中 `sha256` 是**一整列** TEXT，
唯一索引也是**单列**。临时文件也放在**同一目录**下（`.<sha256>.tmp`），
因为 `rename` 只有同一文件系统内才是原子的。

### 5.5 尚缺的索引

| 场景 | 现状 | 计划 |
|---|---|---|
| FTS5 全文索引 | ⬜ 无 `notes_fts`（全仓库搜索无该表） | P1-12 / P1-13 |
| 全文搜索的 tag/notebook 过滤 | ⬜ 无 | P1-14 |
| `notebooks.name` 排序 | ⬜ 无索引 | 待 EXPLAIN 证明需要（Q5/P2） |
| 回收站按删除时间排序 | 有 `idx_notes_deleted`，但查询尚未实现 | P1-11 |

> 新增索引**必须**走新迁移（Q1/Q2）：`0001_init.sql` 已发布，改动它会被
> `tests/migration_guard.rs` 直接拦下。

---

## 6. 数据完整性规则

### 6.1 外键与 `ON DELETE` 策略

`0001_init.sql` 中全部 10 条外键（`notebooks.parent_id`、`notes.notebook_id`、
`note_tags.note_id/tag_id`、`note_attachments.note_id/attachment_id`、
`documents.note_id`、`revisions.note_id/parent_revision_id`、`sync_operations.note_id`）
**都没有写 `ON DELETE` 子句**——即默认 `NO ACTION`。

这是刻意的：文件头注释第 7 行写明"删除一律软删除（`deleted_at_ms`），
**禁止**在此定义级联物理删除"。配合 `PRAGMA foreign_keys = ON`：

| 尝试 | 结果 |
|---|---|
| 物理删除一篇被 `note_tags` 引用的笔记 | 外键失败 → SQLite 报错 → 事务回滚 |
| 物理删除一个被 `notes` 引用的笔记本 | 同上 |
| 软删除（`UPDATE ... SET deleted_at_ms`） | 不受外键影响，永远成功 |

也就是说：**外键在这里的作用不是"维护级联"，而是"让物理删除无法偷偷发生"**。

### 6.2 软删除如何替代物理删除

| 动作 | 已实现的函数 | SQL 形态 |
|---|---|---|
| 笔记入回收站 | `notes::soft_delete` | `UPDATE notes SET deleted_at_ms = ?2, updated_at_ms = ?2 WHERE id = ?1 AND deleted_at_ms IS NULL` |
| 笔记恢复 | `notes::restore` | `UPDATE notes SET deleted_at_ms = NULL, updated_at_ms = ?2 WHERE id = ?1 AND deleted_at_ms IS NOT NULL` |
| 笔记本软删 / 恢复 | `notebooks::soft_delete` / `restore` | 同上形态 |
| 标签软删 | `tags::soft_delete` | `UPDATE tags SET deleted_at_ms = ?2 WHERE id = ?1 AND deleted_at_ms IS NULL` |
| 附件墓碑 | `attachments::upsert` 可清墓碑；无独立软删函数 | `ON CONFLICT (sha256) DO UPDATE SET ..., deleted_at_ms = NULL` |

三个关键细节：

1. **`WHERE ... AND deleted_at_ms IS NULL`**：重复软删除会返回 `changed == 0`，
   进而返回 `DbError::NotFound`。测试 `double_soft_delete_is_reported` 和
   `soft_delete_missing_is_not_found` 断言了这一点——"删除不存在的行"是错误，不是静默成功。
2. **行永远保留**：测试 `row_is_never_physically_removed_by_soft_delete` 断言软删除后
   `SELECT COUNT(*)` 仍为 1，理由是"同步需要墓碑（D9）"。
3. **软删除的读侧过滤**：
   - `notes::list` 默认 `(?2 = 1 OR deleted_at_ms IS NULL)`，`include_deleted` 才能看到回收站；
   - `notes::count(false)` 只数未删除；
   - `notebooks::list_all` / `list_children` 硬编码 `deleted_at_ms IS NULL`；
   - `tags::list_all` / `find_by_name` / `list_for_note` 全部排除墓碑标签
     （`soft_deleted_tag_disappears_from_note_tags` 验证）。

### 6.3 允许物理删除的表（白名单）

`client/tools/nested-rules/src/checks.rs:26`：

```rust
const DELETE_ALLOWED_TABLES: &[&str] = &["note_tags", "note_attachments"];
```

| 表 | 为什么可以物理删除 | 代码位置 |
|---|---|---|
| `note_tags` | **纯关联表**：没有独立生命周期，行的存在与否完全由笔记与标签决定；删除一行只是"取消关联"，两侧实体都还在 | `tags::detach`、`tags::set_note_tags` |
| `note_attachments` | 同理；且附件本体在内容寻址存储中，引用消失只意味着"这篇笔记不再引用它"，文件不会被删 | `attachments::sync_note_links` |

铁律 D2 针对的是**业务实体**（笔记/笔记本/标签/附件元数据），关联表不在其列。
这条白名单由 `nested-rules` 自动检查，除这两张表外的裸 `DELETE FROM` 会让
`cargo run -p nested-rules -- --root ..` 失败。

### 6.4 墓碑与 GC 的关系

```text
活笔记 ──引用──► 附件 ──删除时──► 墓碑（deleted_at_ms） ──保留期后──► GC 物理回收
                    ▲                                     ▲
                    └── ref_count = 0 且 note_attachments 无行 ──┘
```

| 环节 | 现状 | 说明 |
|---|---|---|
| 墓碑写下 | ⚠️ 部分：列已在 schema 中，`attachments::upsert` 会清墓碑 | 把附件标记为墓碑的**业务路径**（删除最后一处引用后过保留期）属 P1-17 |
| GC 候选识别 | ✅ `attachments::list_unreferenced` | `ref_count <= 0 AND NOT EXISTS (...)`，按 `created_at_ms ASC` |
| 物理删除单文件 | ✅ `ContentStore::delete` | 幂等（文件不存在视为成功）；**不做引用检查** |
| GC 编排（候选 → 保留期 → 同步确认 → 删除 → 日志） | ⬜ **未实现** | 属 P1-17，且铁律 T7 要求"GC 必须先确认同步已完成"→ 实际受 P6 约束 |
| 保留期 | ⬜ 未实现 | 计划默认 30 天、可配置（P1-11） |
| dry-run 与日志 | ⬜ 未实现 | D2 对 GC 的硬要求 |

三个必须记住的性质：

1. `list_unreferenced()` **只列出候选，不删除**。测试
   `unreferenced_attachments_are_not_deleted_physically` 明确断言
   "GC 候选不得被自动物理删除（铁律 D2）"。
2. 笔记软删除**不**解除 `note_attachments`，因此只被回收站笔记引用的附件不计入候选——
   这是为了让"恢复笔记"真的能把图片带回来。
3. `ContentStore::delete` **不做引用检查**（引用计数在数据库里，属仓储层职责）：
   调用方必须先确认 `ref_count == 0` 且墓碑期已过，否则会删掉别的笔记正在用的附件
   （见该函数文档注释与 §6.4 的流程图）。

---

## 7. 事务边界

### 7.1 原则

> **一次业务操作 = 一个事务。** 禁止多事务分步提交（铁律 D1）。

在代码里的体现是：**跨表写入的函数自己开事务**，而不是把事务责任推给调用方。
`notes.rs` 模块注释给出了理由："如果把这些拆到多个模块，调用方极易漏掉事务包裹"。

### 7.2 事务落点

| 业务操作 | 函数 | 一个事务里写了什么 | 事务行为 |
|---|---|---|---|
| 创建笔记 | `notes::create_with_document` | ① `notes` ② `documents` ③ `note_attachments`（`sync_note_links`）④ `revisions`（`note.create`） | `connection.unchecked_transaction()` |
| 保存笔记 | `notes::save_with_document` | ① `UPDATE notes`（含 version）② `documents` ③ `note_attachments` ④ `revisions`（`note.update`）⑤ `sync_operations`（入队） | `connection.unchecked_transaction()` |
| 覆盖标签集合 | `tags::set_note_tags` | `DELETE FROM note_tags WHERE note_id = ?1` + 逐条 `attach` | **在调用方的事务内**（函数自身不开事务） |
| 同步附件引用 | `attachments::sync_note_links` | 新增缺失引用 + 删除多余引用 + 刷新 `ref_count` | **必须在调用方事务内**（`create_with_document` / `save_with_document` 内调用） |
| 通用事务包装 | `Database::with_transaction` | 由闭包决定 | `guard.transaction_with_behavior(TransactionBehavior::Immediate)` |
| 迁移 | `migrations::apply` | 全部待执行迁移 + `PRAGMA user_version` | `connection.transaction()` |

`with_transaction` 的实现（`db.rs:144-153`）：

```rust
let mut guard = self.connection()?;
let transaction = guard.transaction_with_behavior(TransactionBehavior::Immediate)?;
let value = f(&transaction)?;      // 闭包返回 Err 时事务未提交 → 自动回滚
transaction.commit()?;
Ok(value)
```

### 7.3 失败回滚行为

| 失败点 | 结果 | 测试证据 |
|---|---|---|
| `insert` 主键冲突 | 整个事务回滚，`documents` 不留下半截数据 | `create_is_rolled_back_when_document_is_invalid` 断言 `documents` 仍只有 1 行 |
| `UPDATE notes` 影响 0 行 | 返回 `DbError::NotFound { entity: "note" }`，事务回滚 | `save_missing_note_is_not_found` |
| 文档序列化失败 | 返回 `DbError::Corrupt { entity: "document" }`，事务回滚 | `upsert_document` 里的 `?` |
| 外键失败（引用不存在的附件/笔记） | 返回 `DbError::Sqlite`，事务回滚 | 依赖 `foreign_keys = ON` |
| 事务未提交就 `?` 提前返回 | rusqlite 的 `Transaction` 在 `Drop` 时回滚 | `transaction_rolls_back_on_error` |

关键点：**"未提交即回滚"由 `Drop` 保证**，不依赖调用方记得写 `rollback()`。
这是选择 RAII 事务对象（而不是手写 `BEGIN` / `COMMIT` / `ROLLBACK` 字符串）的主要原因。

### 7.4 事务内的禁止事项

| 禁止 | 依据 | 现状 |
|---|---|---|
| 网络请求 | Q7 | ✅ 仓储层无任何网络代码 |
| 图片解码、文件哈希 | Q7 | ✅ 仓储层无此类调用 |
| 长耗时计算 | Q7 / P7 | ✅ 文档序列化在内存中完成，量级可控 |
| 事务里再开事务 | 会静默变成嵌套（savepoint），语义易错 | ⚠️ 见 §11.3 第 1 条 |

### 7.5 ⚠️ 一处行为不一致（详见 §11.3）

`Database::with_transaction` 用 `TransactionBehavior::Immediate`，
而两个业务入口用 `unchecked_transaction()`（默认 `Deferred`）。
单写连接下影响有限，但语义上"两条写路径的事务行为不同"是需要收敛的技术债。

---

## 8. 迁移体系

实现位置：`client/crates/nested-db/src/migrations.rs`。

### 8.1 版本机制：`PRAGMA user_version`

| 项 | 值 | 位置 |
|---|---|---|
| 版本存储 | `PRAGMA user_version`（SQLite 文件头里的 32 位整数，无需建表） | `current_version`（`migrations.rs:47-50`） |
| 当前版本 | `1` | `0001_init.sql` 的 `version: 1` |
| 程序支持的最高版本 | `LATEST_VERSION`（由清单最后一条推导，**不是**硬编码常量） | `migrations.rs:37-40` |
| 越界处理 | `u32::try_from(raw)` 失败 → `DbError::VersionOutOfRange { raw }` | `migrations.rs:49` |

`LATEST_VERSION` 从 `MIGRATIONS.last()` 推导的好处：新增迁移时只改一处，
不会出现"清单加了、版本号忘了加"的漂移。

### 8.2 单事务执行

```rust
// apply_manifest 节选（省略 tracing 日志与注释）
let transaction = connection.transaction()?;
for migration in pending {
    transaction
        .execute_batch(migration.sql)
        .map_err(|source| DbError::Migrate {
            version: migration.version,
            name: migration.name,
            source,
        })?;
    transaction.execute_batch(&format!("PRAGMA user_version = {}", migration.version))?;
}
transaction.commit()?;
```

| 性质 | 说明 |
|---|---|
| 原子性 | 要么全部生效，要么原样回滚，**不会出现"迁移到一半"的数据库** |
| 版本与结构同步 | `user_version` 与结构变更在同一事务里写，不存在"结构升了版本没升" |
| 失败即中止 | `DbError::Migrate { version, name, source }` 带上失败的那一条，便于定位（E3） |
| 幂等 | `from == latest_version` 直接返回，不重复执行（测试 `migration_is_idempotent`、`already_current_database_is_left_untouched`） |
| 关于 `format!` | `user_version` **不支持参数绑定**；这里拼的是已校验为 `u32` 的数字，不含任何用户输入，故不违反 Q4（代码注释明确说明） |

**入口分两个**（这是刻意的设计，不是重复代码）：

| 函数 | 清单来源 | 用途 |
|---|---|---|
| `apply(connection)` | 内置 `MIGRATIONS` + `LATEST_VERSION` | **生产唯一入口**：`Database::from_connection` 调用它 |
| `apply_manifest(connection, migrations, latest_version)` | 调用方传入 | **测试入口**：迁移的失败路径（SQL 出错时的回滚、清单不自洽时的拒绝）恰恰最需要测试，注入一条必然失败的迁移就能验证"失败不留半截状态"，而不必破坏内置迁移（见函数文档注释与测试 `failing_migration_rolls_back_entirely`） |

### 8.3 清单自洽校验

`validate_manifest(migrations)` 在**每次** `apply_manifest()` 开头运行
（`apply()` 经由它间接调用）：

| 校验项 | 失败结果 |
|---|---|
| 版本号必须从 1 开始连续递增（第 i 条的 `version` 必须等于 i+1） | `DbError::MigrationManifest { reason: "版本号必须从 1 开始连续递增" }` |
| 迁移 SQL 不得为空（`sql.trim().is_empty()`） | `DbError::MigrationManifest { reason: "迁移 SQL 不得为空" }` |

两项都有独立测试（`manifest_rejects_non_sequential_versions`、`manifest_rejects_empty_sql`）。
"名称必须以 `NNNN_` 开头"这条规范不在 `validate_manifest` 里，而是由
`tests/migration_guard.rs` 的 `migration_names_match_version_numbers` 把关。

### 8.4 哈希护栏（为什么已发布迁移不可修改）

实现：`client/crates/nested-db/tests/migration_guard.rs`（设计决策见
`docs/adr/0003-migration-hash-guard.md`）。

**问题**：用户库已经按旧文件迁移过了，事后改文件 → 老用户永远不会重新执行它，
新用户却按新文件创建。两者 `user_version` 相同、**实际结构不同**——这类问题只在生产爆雷。

四道护栏：

| # | 测试 | 断言 |
|---|---|---|
| 1 | `published_migrations_are_unchanged` | 目录下每个 `.sql` 的 SHA-256 必须与硬编码清单一致；数量也必须一致 |
| 2 | `embedded_migrations_match_files_on_disk` | 磁盘文件内容与 `include_str!` 内嵌的 SQL 必须逐字相同 |
| 3 | `migration_names_match_version_numbers` | 名称必须以 `{:04}_` 开头（如 `0001_`） |
| 4 | `migrations_are_lf_terminated` | 迁移文件不得含 `CR`（否则哈希随平台漂移） |

当前清单（`migration_guard.rs:30-33`）：

```rust
const MIGRATION_HASHES: &[(&str, &str)] = &[(
    "0001_init.sql",
    "4566e916ca98e4d437020b13a79999abaf6fa7639a09146f57b8159125d93341",
)];
```

配套措施：迁移 SQL 通过 `include_str!("../../../migrations/0001_init.sql")` **编译期内嵌**，
发布产物不依赖外部 SQL 文件的部署正确性；`.gitattributes` 强制迁移文件为 LF。

若测试因"仅仅是换行符变了"而失败：`pwsh scripts/normalize-line-endings.ps1`
（`-Check` 只检查不修改）。

### 8.5 如何新增一条迁移（操作步骤）

以"给 `notes` 加一列"为例：

```text
1. 新建文件        client/migrations/0002_<短名>.sql
                   （只写增量 DDL；禁止改动 0001_init.sql）
2. 文件必须 LF     不得含 CR；末尾换行可有可无，但一旦发布就不能再动
3. 登记清单        client/crates/nested-db/src/migrations.rs 的 MIGRATIONS 追加：
                       Migration { version: 2, name: "0002_<短名>",
                                   sql: include_str!("../../../migrations/0002_<短名>.sql") }
                   ★ 只能追加，不得插入或改动已有条目
4. 登记哈希        client/crates/nested-db/tests/migration_guard.rs 的 MIGRATION_HASHES 追加一行
                   （留空哈希先跑一次测试，测试会打印实际值；这是刻意的摩擦）
5. 跑护栏          cd client && cargo test -p nested-db --test migration_guard
6. 补升级测试      P1-36 要求"从上一版本库升到最新"的端到端测试（当前尚未建立，见 §8.7）
7. 同步文档        铁律 M3：行为变更必须在同一个 PR 更新本文档与相关设计文档
```

第 1 条为什么不能改历史文件：ADR 0003 明确把"不得修改历史迁移"从口头约定变成
**机器强制**，并刻意保留"手工更新哈希"这道摩擦——强制作者意识到"这是一次发布"。

### 8.6 版本过高时拒绝启动

```rust
let from = current_version(connection)?;
if from > LATEST_VERSION {
    return Err(DbError::SchemaTooNew { found: from, supported: LATEST_VERSION });
}
```

| 场景 | 行为 |
|---|---|
| 库版本 = 程序版本 | 打一条 `debug` 日志，直接返回（不执行任何 SQL） |
| 库版本 < 程序版本 | 按序执行未应用的迁移 |
| **库版本 > 程序版本** | 返回 `DbError::SchemaTooNew`，**拒绝继续使用** |

错误文案（`error.rs:34`）：`"数据库结构版本 {found} 高于本程序支持的 {supported}，请升级应用后再打开"`。
设计意图：防止旧版本程序打开新版本库后"按旧结构写坏新数据"（降级写坏）。
两个同名测试分别从两侧覆盖它：`db.rs` 的 `schema_too_new_is_refused`（真实文件库，
把 `user_version` 设为 `LATEST_VERSION + 1` 后重新打开被拒）与 `migrations.rs` 的
`schema_too_new_is_refused`（注入清单场景，`LATEST_VERSION + 5`）。

在 CLI 与 UI 上，这个错误会成为 `CoreError::Database` → 错误码 `DATABASE_ERROR`，
用户提示为"请尝试重启应用；若问题持续，请从备份恢复数据。"（`nested-core/src/error.rs:72`）。

### 8.7 迁移测试现状（诚实标注）

| 项 | 现状 |
|---|---|
| 哈希 / 清单 / 命名 / LF 护栏 | ✅ 已实现（4 个测试） |
| 清单自洽单元测试 | ✅ `builtin_manifest_is_consistent`、`builtin_manifest_embeds_real_sql` |
| 清单不合法（版本跳跃 / 空 SQL） | ✅ 分别有独立测试 |
| **迁移执行失败的整体回滚** | ✅ 内存库与文件库各一个测试（`failing_migration_rolls_back_entirely` / `failing_migration_keeps_previous_version_when_upgrading`） |
| 幂等（重复打开不重复迁移） | ✅ `migration_is_idempotent`、`already_current_database_is_left_untouched` |
| 10 张表存在性 | ✅ `expected_tables_exist` |
| **"从上一版本库升级到最新"的端到端测试** | ⬜ **未实现**（P1-36；ADR 0003 已把它列为 P1 后续项） |
| 服务端 PostgreSQL 迁移护栏 | ⬜ 未实现（P6） |

---

## 9. 查询与分页

### 9.1 `NoteQuery` 字段

定义在 `client/crates/nested-db/src/db.rs:32-44`（由 `repositories::notes` 重新导出）：

| 字段 | 类型 | 默认值 | 语义 |
|---|---|---|---|
| `notebook_id` | `Option<&Id>` | `None` | 限定笔记本；`None` = 不限 |
| `include_deleted` | `bool` | `false` | 是否包含回收站中的笔记 |
| `archived` | `Option<bool>` | `None` | `Some(true)` 仅归档、`Some(false)` 仅未归档、`None` 不限 |
| `offset` | `u32` | `0` | 分页偏移 |
| `limit` | `u32` | `0` | `0` 视为默认 **50** |

字段全是**结构化枚举/标量**，而不是 SQL 片段字符串——这是"从设计上杜绝注入"（Q4），
而不是靠运行时过滤。

### 9.2 `MAX_PAGE_SIZE` 硬上限

```rust
pub const MAX_PAGE_SIZE: u32 = 500;   // db.rs:27

pub fn effective_limit(&self) -> u32 {          // db.rs:49-55
    if self.limit == 0 { 50 } else { self.limit.min(MAX_PAGE_SIZE) }
}
```

| 输入 `limit` | 实际 `LIMIT` | 理由 |
|---|---|---|
| `0` | **50** | "没传"用默认值，而不是"取全部" |
| `1..=500` | 原值 | — |
| `> 500`（含 `u32::MAX`） | **500** | 防止 UI 误传巨大 `limit` 把整库读进内存（T9） |

测试 `limit_is_clamped_to_max_page_size` 断言 `u32::MAX → 500`、`0 → 50`。
"取全部"这种 API **不存在**——这是刻意的（T9 按需加载）。

> ⚠️ 这个上限目前只作用于笔记列表。`revisions::list_for_note(limit)` 与
> `sync_operations::list_pending(limit)` 直接使用调用方传入的 `u32`，未做 clamp（§11.3 第 2 条）。

### 9.3 排序键

笔记列表的排序（`notes.rs:123-130`）：

```sql
ORDER BY is_pinned DESC, updated_at_ms DESC
LIMIT ?4 OFFSET ?5
```

| 键 | 方向 | 语义 |
|---|---|---|
| `is_pinned` | DESC | 置顶优先（`1` 在前） |
| `updated_at_ms` | DESC | 最近修改在前；同毫秒时顺序未定义（分页可能重复/漏项，见下） |

其他列表的排序（各自硬编码，不暴露给调用方）：

| 列表 | 排序 | 位置 |
|---|---|---|
| 笔记本全量 | `name ASC` | `notebooks::list_all` |
| 笔记本子节点 | `name ASC` | `notebooks::list_children` |
| 标签全量 | `name ASC` | `tags::list_all` |
| 笔记的标签 | `t.name ASC` | `tags::list_for_note` |
| 修订历史 | `version DESC`（最新在前） | `revisions::list_for_note` / `latest_for_note` |
| 待同步操作 | `created_at_ms ASC, rowid ASC` | `sync_operations::list_pending` |
| 无引用附件 | `created_at_ms ASC` | `attachments::list_unreferenced` |

排序字段**不允许**由调用方指定——若将来需要"按标题排序"，做法是给 `NoteQuery` 加一个
**枚举**（如 `SortKey::Title`）并在实现里 `match` 成白名单 SQL 片段，**禁止**把字符串拼进去
（R6/Q4，且 `nested-rules` 的 Q4 检查只放行 `{COLUMNS}` / `{columns}` 这两种白名单占位符）。

### 9.4 参数化查询与"禁止拼接 SQL"的落实方式

| 层次 | 机制 |
|---|---|
| 统一列清单 | 每张表一个 `const COLUMNS: &str`，所有 SELECT 复用它，避免"某处少读一列"的错位 bug |
| 值绑定 | 一律 `rusqlite::params!`（`?1` / `?2` …），无一处把用户值写进 SQL 文本 |
| 唯一允许的 `format!` | `format!("SELECT {COLUMNS} FROM ...")` —— 插值的只有列清单常量 |
| 自动检查 | `nested-rules` 的 Q4 规则：同一行出现 `format!` + SQL 关键字且占位符不在白名单 → 违规 |
| 检查盲区（诚实） | Q4 **只**检查 `format!`，不检查 `String` 拼接（如 `push_str` 拼 SQL）——这类写法靠 Code Review 拦（铁律附 A 已登记该盲区） |

实际存在的 `format!` 用法全部是 `{COLUMNS}` / `{columns}` 形态，例如
`notes.rs:109`、`notebooks.rs:53`、`tags.rs:55`、`attachments.rs:74`。
唯一一处"拼接数字"是 `migrations.rs:100` 的 `PRAGMA user_version = {}`，已论证不含用户输入。

### 9.5 笔记列表的完整 SQL（唯一带过滤条件的列表查询）

```sql
SELECT id, notebook_id, title, summary, created_at_ms, updated_at_ms,
       accessed_at_ms, is_pinned, is_archived, deleted_at_ms, version
  FROM notes
 WHERE (?1 IS NULL OR notebook_id = ?1)
   AND (?2 = 1 OR deleted_at_ms IS NULL)
   AND (?3 IS NULL OR is_archived = ?3)
 ORDER BY is_pinned DESC, updated_at_ms DESC
 LIMIT ?4 OFFSET ?5
```

参数依次为：`notebook_id`（BLOB 或 NULL）、`include_deleted`（0/1）、
`archived`（0/1 或 NULL）、`effective_limit()`、`offset`。

配套统计：`notes::count(connection, include_deleted)` →
`SELECT COUNT(*) FROM notes WHERE (?1 = 1 OR deleted_at_ms IS NULL)`。

> **分页正确性提醒**：`OFFSET` 分页在"列表内容被并发修改"时会漏项或重复。
> 当前单写连接、单 UI 场景下可接受；P4 若证明有影响，再引入基于 `(is_pinned, updated_at_ms, id)`
> 的游标分页（届时需要新索引，走新迁移）。

---

## 10. 损坏与容错

### 10.1 `DbError` 全部变体

定义在 `client/crates/nested-db/src/error.rs`（9 个变体，R3：库层用具体错误类型，
禁止用 `String` 向上传播）：

| 变体 | 触发条件 | 用户可见性 |
|---|---|---|
| `Sqlite(#[from] rusqlite::Error)` | 任意底层 SQLite 错误（含锁超时、约束、类型转换） | 折叠为 `DATABASE_ERROR` |
| `Migrate { version, name, source }` | 某条迁移执行失败（事务已回滚） | `DATABASE_ERROR`，日志含版本与名称 |
| `MigrationManifest { reason }` | 迁移清单不合法（开发期错误，不应出现在发布版） | `DATABASE_ERROR` |
| `SchemaTooNew { found, supported }` | 库版本高于程序支持 | 文案："请升级应用后再打开" |
| `VersionOutOfRange { raw }` | `user_version` 超出 `u32` 范围 | 文案："数据库版本号异常" |
| `IntegrityCheckFailed { detail }` | `PRAGMA integrity_check` 返回非 `ok` | `DATABASE_ERROR`（含 SQLite 报告细节） |
| `NotFound { entity }` | 目标记录不存在（如 `UPDATE ... WHERE id` 影响 0 行） | 映射为 `NOT_FOUND` |
| `Conflict { entity }` | 唯一约束冲突（标签重名） | `CONFLICT`，提示"标签名称已存在" |
| `Corrupt { entity }` | 存储的字节无法解析为领域模型 | `DATABASE_ERROR` |

> 注意：`DbError` **禁止**原样透传给 Flutter（E1/E2）。`nested-core` 把它映射为
> `CoreError::Database`，UI 只拿到错误码 + 一句可读提示。

### 10.2 `DbError::Corrupt` 的产生条件

核心策略：**列映射失败返回结构化错误，绝不 panic**（R1）。

实现方式见 `client/crates/nested-db/src/rowmap.rs` 的模块注释：由于
`rusqlite::query_row`/`query_map` 要求闭包返回 `rusqlite::Result`，若映射函数返回
自定义错误类型，每个查询点都要写一层 `map_err`（极易漏掉）。因此：

| 环节 | 做法 |
|---|---|
| 映射函数签名 | 统一返回 `rusqlite::Result<T>` |
| 构造损坏错误 | `corrupt(entity)` → `rusqlite::Error::FromSqlConversionFailure(0, Type::Null, Box::new(DbError::Corrupt { entity }))` |
| 为什么不用 `InvalidColumnType` | 为了**携带实体名**，便于日志定位（E3） |
| 唯一转换出口 | 仓储函数在唯一出口处用 `?` 转成 `DbError` |

具体触发点：

| 位置 | 条件 | 结果 |
|---|---|---|
| `rowmap::id_at` | 列不是 16 字节 BLOB（`Id::from_slice` 失败） | `Corrupt { entity }`（如 `"note"`） |
| `rowmap::optional_id_at` | 值既不是 NULL 也不是 BLOB | `Corrupt { entity }` |
| `rowmap::u64_to_i64` / `i64_to_u64` | 超出 `i64` 范围 / 负数 | `Corrupt { entity: "attachment" }`（禁止静默截断） |
| `notes::upsert_document` | `Document::to_bytes()` 失败 | `Corrupt { entity: "document" }` |
| `notes::get_document` | `Document::from_bytes()` 失败（非法 JSON 或版本过新） | `Corrupt { entity: "document" }` |
| `attachments::upsert` | 查回的 id 不是合法 UUID | `Corrupt { entity: "attachment" }` |
| `attachments::sync_note_links` | 既有引用行的 id 非法 | `Corrupt { entity: "attachment" }` |

⚠️ 注意最后两类：`Document::from_bytes` 区分了"JSON 损坏"与"版本过新"
（`ModelError::UnsupportedDocumentVersion`），但 `get_document` 把两者都折叠成
`Corrupt`，丢失了"版本过新"这一可操作信息（§11.3 第 5 条）。

### 10.3 `check_integrity`

```rust
pub fn check_integrity(&self) -> Result<(), DbError> {
    let guard = self.connection()?;
    let result: String = guard.query_row("PRAGMA integrity_check", [], |row| row.get(0))?;
    if result.eq_ignore_ascii_case("ok") { Ok(()) }
    else { Err(DbError::IntegrityCheckFailed { detail: result }) }
}
```

| 项 | 说明 |
|---|---|
| 调用入口 | `Database::check_integrity`（db.rs）、`NestedCore::check_integrity`、`NestedCore::readiness()` 的 `integrity` 项、CLI `doctor` |
| 判定 | 忽略大小写比较 `"ok"` |
| 失败 | 把 SQLite 报告的细节放进 `detail`（不吞错误，R4/E6） |
| ⚠️ 成本 | `integrity_check` 是**全库扫描**，而 `readiness()` 每次调用都会执行它；UI 首屏与 CLI 都会触发。与铁律 P6（首屏前禁止全库统计）存在张力，见 §11.3 第 3 条 |

除 `integrity_check` 外还有更轻的探活：`Database::ping()` 执行 `SELECT 1`，
被 `readiness()` 的 `database_open` 项使用。

### 10.4 尚未实现的容错能力（诚实标注）

| 能力 | 现状 | 计划 |
|---|---|---|
| 自动修复（reindex / rebuild） | ⬜ **不存在**。代码里没有任何"检测到损坏就自动重建"的路径 | 未排期；铁律 T1 优先要求"可恢复"而非"自动猜" |
| `PRAGMA quick_check` 快速自检 | ⬜ 未使用（只有 `integrity_check`） | P4 评估（大库启动时用 quick_check 替代） |
| 损坏后的导出/抢救 | ⬜ 未实现 | 依赖 P1 的导出能力 |
| 从备份恢复 | ⬜ 未实现（P1-25/P1-26） | 恢复**必须**先校验 manifest（D5），禁止未校验直接覆盖 |
| 崩溃注入测试 | ⬜ 未实现（Z5，属 P4） | 计划：写入过程中强杀进程 100 轮，全部 `integrity_check = ok` |
| `PRAGMA optimize` / 定期维护 | ⬜ 未实现（Q9） | P1/P4，且禁止放在启动关键路径 |

当前的容错姿态可以概括为：**宁可拒绝启动、如实报错，也不静默修补**。
`SchemaTooNew` 与 `Corrupt` 都遵循这一姿态。

---

## 11. 未实现部分（诚实清单）

### 11.1 未实现清单（按阶段）

| # | 项 | 现状 | 计划阶段 | 依据 |
|---|---|---|---|---|
| 1 | FTS5 索引表（如 `notes_fts`） | 全仓库无该表 | **P1-12 / P1-13** | 需先做中文分词方案对比基准 + ADR |
| 2 | `reindex` 命令 | CLI 明确以 `NotImplemented` 失败退出 | P1-15 | `client/cli/src/main.rs:198-202` |
| 3 | 备份 / 恢复到文件格式 | 只有常量与契约（`MANIFEST_FILE` 等） | P1-25 / P1-26 | `nested-export` |
| 4 | 附件 GC（含保留期、dry-run、日志） | 只有 `list_unreferenced` 候选查询与不做引用检查的 `ContentStore::delete` | P1-17（且受 P6 约束） | D2 / T7 / D9 |
| 5 | 连接池 / 多读者优化 | 单连接 + Mutex | **P4**（需基准数据） | P2 |
| 6 | 回收站保留期与自动清理 | 未实现 | P1-11（默认 30 天、可配置） | — |
| 7 | 标签重命名 / 合并 | 仓储无对应函数 | P3（U6 要求可撤销或确认） | — |
| 8 | "某标签下的笔记"查询 | 索引 `idx_note_tags_tag` 已就位，查询未写 | P2/P3 | — |
| 9 | 数据库加密（SQLCipher 或字段级） | 未实现 | P1-30（需 ADR） | D11 / S2 |
| 10 | `PRAGMA optimize` / `VACUUM` 维护任务 | 未实现 | P1/P4 | Q9 |
| 11 | 崩溃注入测试 | 未实现 | P4 | Z5 |
| 12 | "从上一版本库升级到最新"的迁移测试 | 未实现 | P1-36 | Q10 / ADR 0003 |
| 13 | 覆盖率门禁（核心 crate ≥ 80%） | 未度量 | P1 必须补齐 | Z1 / gate-p0 §8 |
| 14 | 服务端 schema | 与本文档无关，两端独立演进 | P6 | **Q12**：客户端禁止依赖服务端表结构 |

> 已不在本表的内容：**附件 CAS 落盘（P1-16/P1-19）已实现**——`ContentStore` 提供
> `put_bytes` / `put_file` / `read` / `verify` / `delete` / `contains`，
> 写路径为"临时文件 → `fsync` → `rename` → 回读校验"（D3/D4），
> 且 `path_for` 对非法哈希返回 `AttachmentError::InvalidHash` 而不是 panic。

### 11.2 文档与实现不一致（阅读源码发现，需后续修正）

| # | 位置 | 不一致 |
|---|---|---|
| 1 | `sync_operations.rs` 模块注释 vs 实现 | 注释称"**任何**本地写操作都在**同一个事务**里往这里塞一条待推送记录"；实际只有 `notes::save_with_document` 调用了 `enqueue`。`create_with_document`、`soft_delete`、`restore`、`mark_accessed`、`notebooks::*`、`tags::*`、`attachments::upsert` **都不入队**。测试 `save_enqueues_sync_operation` 也印证：create + save 之后 pending == 1（即 create 没入队） |
| 2 | `docs/01-开发计划.md` P1-8 vs schema | 计划里写 `notes(notebook_id, is_deleted)`，实际索引是 `idx_notes_notebook ON notes (notebook_id, deleted_at_ms)`——`notes` 表**没有** `is_deleted` 列（用 `deleted_at_ms IS NULL` 表达存活）。计划文档应更新为实际列名 |
| 3 | `attachments.rs` 注释 vs 实现 | 注释说"由笔记 ↔ 附件关系表推导，**不维护冗余计数器**"，但 schema 里确实有 `ref_count` 列，`refresh_ref_count` 也确实把计数写回了该列（属于"缓存推导值"）。措辞应为"ref_count 是推导缓存，权威来源是 note_attachments" |
| 4 | 铁律 T7 措辞 vs 实现 | T7 写"必须用 `is_deleted` + `deleted_at`"，实际统一只用 `deleted_at_ms`（**没有**任何 `is_deleted` 列）。建议在铁律词条中把 `is_deleted` 明确为"语义等价于 deleted_at_ms IS NOT NULL"，避免后来者照字面加冗余列 |

> 已修正项：`validate_manifest` 的文档注释曾写"（版本连续、**名称唯一**、SQL 非空）"
> 而实现未校验名称唯一，现已统一为"（版本从 1 连续递增、SQL 非空）"，
> 名称规范由 `migration_names_match_version_numbers` 单独把关。

### 11.3 实现隐患（建议在 P1 处理）

| # | 隐患 | 影响 | 建议 |
|---|---|---|---|
| 1 | 事务行为不统一：`Database::with_transaction` 用 `TransactionBehavior::Immediate`，业务入口 `create_with_document` / `save_with_document` 用 `connection.unchecked_transaction()`（默认 **Deferred**） | WAL 下 Deferred 事务"先读后写"时，若期间有其他连接写入，会以 `SQLITE_BUSY`（快照冲突）**立即**失败，`busy_timeout` 对快照升级无效；且 `unchecked_transaction` 允许嵌套（静默变成 savepoint），缺少"已在事务内"的护栏 | 统一改为 `Immediate`；或提供一个仓储层的 `with_immediate_transaction` 并禁止直接使用 `unchecked_transaction` |
| 2 | `MAX_PAGE_SIZE = 500` 未覆盖全部列表 | `revisions::list_for_note(limit)`、`sync_operations::list_pending(limit)` 直接接受 `u32` 且不 clamp，UI 误传巨大值会一次读入大量行（T9/R12） | 在这两个函数内做 `.min(MAX_PAGE_SIZE)`，或引入统一的 `Page` 类型 |
| 3 | `readiness()` 每次调用都跑 `PRAGMA integrity_check` | 全库扫描被放在**应用首屏**路径上（gate-p0 记录的真实启动流程会调用它），与 P6"首屏前禁止全库统计/索引重建"存在张力；10 万笔记 / 1 GB 附件时的启动耗时可观 | 把 `integrity` 从首屏 `readiness` 中拆出（改为后台任务或 `doctor` 专用），或大库时降级为 `PRAGMA quick_check` |
| 4 | 软删除标签无法"复活" | `idx_tags_name_unique` 是 `name COLLATE NOCASE` 的全局唯一索引，不考虑 `deleted_at_ms`；`tags::insert` 也不做 tombstone 复活。删除标签"工作"后再建同名标签 → `DbError::Conflict`，用户会认为"删不掉" | 与附件策略对齐（`ON CONFLICT ... DO UPDATE SET deleted_at_ms = NULL`），或在业务层提供"恢复同名标签"路径 |
| 5 | `Corrupt` 吞掉了"文档版本过新" | `Document::from_bytes` 能区分 `UnsupportedDocumentVersion`，但 `notes::get_document` 统一映射为 `Corrupt { entity: "document" }`，用户/日志都无法区分"数据坏了"与"应用太旧" | 增加独立错误变体（如 `DbError::UnsupportedDocumentVersion`），由 `nested-core` 映射为可操作提示 |
| 6 | `Mutex` 中毒与"连接已关闭"都映射为 `InvalidQuery` | `db.rs:132-133` 把锁中毒/已关闭都变成 `DbError::Sqlite(rusqlite::Error::InvalidQuery)`，错误文案会显示成"Query is not read-only"之类的误导信息 | 引入 `DbError::Closed` / `DbError::Poisoned` 变体，或至少加注释说明该映射 |
| 7 | 附件引用必须先存在 | `sync_note_links` 直接 `INSERT INTO note_attachments`，若 `documents.content` 引用了尚未 `upsert` 的附件 id，外键失败会让**整篇笔记的保存回滚**（`DbError::Sqlite`）。行为正确（不写坏数据），但 API 层没有"先写附件元数据再保存笔记"的前置说明 | 在 `nested-core` 的保存路径上明确顺序约束，或提供"批量 upsert 附件元数据 → 保存笔记"的组合 API |
| 8 | 软删除笔记不解除附件引用 | 只被回收站笔记引用的附件永远不进 `list_unreferenced` 候选，长期会积累不会被 GC 的附件 | 这是刻意取舍（恢复笔记要带回图片），但应在 GC 设计（P1-17）中显式处理"随笔记墓碑一起计时" |
| 9 | 文件落盘与元数据写库**尚未被任何函数串起来** | `ContentStore` 会写文件，`attachments::upsert` 会写元数据，但当前**没有任何代码同时调用两者**（`AttachmentError::Storage` 变体只是为将来预留）。一旦将来随手各写一半，就会出现"文件在、库里没有"（永久孤儿文件）或"库里有、文件不在"（附件打不开） | P1-16 收尾时必须提供一个组合入口（如 `store_and_register`），并明确顺序与失败补偿：先落盘（内容寻址，重复落盘无副作用）→ 再写库（事务）→ 失败时文件可留待 GC |

---

## 12. 测试覆盖情况

以下是各仓储 `#[cfg(test)]` 模块中**实际存在**的测试。列出的都是"验证了什么不变量"，
而不是"跑过了什么"。

### 12.1 `db.rs`（连接、PRAGMA、事务、表清单）

| 测试 | 验证的不变量 |
|---|---|
| `in_memory_database_reaches_latest_schema` | 新建内存库的 `schema_version() == LATEST_VERSION` |
| `integrity_check_passes_on_fresh_database` | 新库 `PRAGMA integrity_check = ok` |
| `ping_succeeds` | 连接可用（`SELECT 1`） |
| `file_database_enables_wal` | **文件库**的 `journal_mode` 确实是 `wal`（内存库差异处理的对照） |
| `foreign_keys_are_enforced` | `PRAGMA foreign_keys == 1`，注释写明"否则软删除链会写坏数据" |
| `migration_is_idempotent` | 同一文件库重复打开不重复执行迁移、不报错、完整性仍 ok |
| `schema_too_new_is_refused` | 库版本高于程序 → `DbError::SchemaTooNew` |
| `settings_roundtrip_and_overwrite` | 设置项"存在则覆盖"（`ON CONFLICT DO UPDATE`） |
| `transaction_rolls_back_on_error` | **失败的事务必须整体回滚**（闭包返回 `Err` 后写入的行不存在） |
| `expected_tables_exist` | 10 张表逐一存在于 `sqlite_master` |

### 12.2 `migrations.rs` 与 `tests/migration_guard.rs`

`migrations.rs` 的测试用**注入清单**（`apply_manifest` + 自造的 `OK_SQL` / `BROKEN_SQL`）
覆盖失败路径，因此不需要破坏内置迁移：

| 测试 | 验证的不变量 |
|---|---|
| `builtin_manifest_is_consistent` | 内置清单自洽，且 `LATEST_VERSION == MIGRATIONS.len()` |
| `builtin_manifest_embeds_real_sql` | 内嵌 SQL 确实是 0001 的内容（含 `CREATE TABLE notes`） |
| `manifest_rejects_non_sequential_versions` | 版本跳跃（1 → 3）→ `DbError::MigrationManifest` |
| `manifest_rejects_empty_sql` | 空白 SQL → `DbError::MigrationManifest` |
| `empty_manifest_is_valid_and_noop` | 空清单合法，版本保持 0 |
| `injectable_manifest_is_applied_and_bumps_version` | 注入的迁移确实执行、`user_version` 前进、表被建出 |
| `already_current_database_is_left_untouched` | 已是最新时再次 apply 是 no-op |
| `schema_too_new_is_refused` | 库版本高于清单版本 → `DbError::SchemaTooNew` |
| `failing_migration_rolls_back_entirely` | **第二条迁移失败时第一条一起回滚**：版本保持 0，第一条建的表不存在 |
| `failing_migration_keeps_previous_version_when_upgrading` | 真实文件库上"下一版迁移写错"时版本不前进，且原库 `integrity_check` 仍通过 |
| `migrate_error_carries_version_and_name_for_diagnosis` | `DbError::Migrate` 的文案含迁移名与版本号（可定位，E3） |

`tests/migration_guard.rs`（四道护栏）：

| 测试 | 验证的不变量 |
|---|---|
| `sha256_implementation_is_correct` | 内置 SHA-256 对空串与 `"abc"` 的已知向量正确（护栏自身可信） |
| `published_migrations_are_unchanged` | 已发布迁移的 SHA-256 与清单一致，且文件数量一致 |
| `embedded_migrations_match_files_on_disk` | 磁盘 SQL 与 `include_str!` 内嵌内容逐字相同 |
| `migration_names_match_version_numbers` | 迁移名以 `{:04}_` 开头 |
| `migrations_are_lf_terminated` | 迁移文件不含 `CR`（否则哈希随平台漂移） |

### 12.3 `repositories/notebooks.rs`

| 测试 | 验证的不变量 |
|---|---|
| `insert_then_get_roundtrips` | 写入→读出逐字段相等 |
| `get_missing_returns_none_not_error` | 不存在是 `Ok(None)`，不是错误也不是 panic |
| `list_all_excludes_soft_deleted_and_sorts_by_name` | 软删除的不出现；排序为 `Alpha` < `beta`（按 `name ASC`） |
| `nested_notebooks_are_listed_by_parent` | 树结构按 `parent_id` 正确分层（顶层 vs 子节点） |
| `rename_updates_timestamp` | 重命名同时刷新 `updated_at_ms` |
| `rename_missing_is_not_found` | 重命名不存在的 → `DbError::NotFound { entity: "notebook" }` |
| `soft_delete_then_restore_is_reversible` | 删除→恢复可往返，`is_deleted()` 状态正确翻转 |
| `double_soft_delete_is_reported` | 二次软删除**报错**而不是静默成功（`deleted_at_ms IS NULL` 守卫） |
| `row_is_never_physically_removed_by_soft_delete` | **软删除必须保留行**：`COUNT(*)` 仍为 1，"同步需要墓碑（D9）" |

### 12.4 `repositories/notes.rs`（含文档）

| 测试 | 验证的不变量 |
|---|---|
| `create_with_document_writes_all_tables_atomically` | 一个事务写完 `notes` + `documents` + `revisions`（修订数 == 1，T6） |
| `create_is_rolled_back_when_document_is_invalid` | **失败事务不得留下半截数据**：重复创建失败后 `documents` 仍只有 1 行 |
| `save_increments_version_and_appends_revision` | 保存后 `version == 2`，标题与内容都更新，修订数 == 2 |
| `save_enqueues_sync_operation` | 本地写入同时入同步队列（`pushed_at_ms IS NULL` 的行数为 1，T3） |
| `save_missing_note_is_not_found` | 保存不存在的笔记 → `DbError::NotFound { entity: "note" }` |
| `list_respects_paging_and_excludes_deleted_by_default` | 分页 `limit=3` 生效、默认排除回收站、按修改时间倒序（`page[0].title == "笔记4"`）；`count(false)=5`、`count(true)=6` |
| `limit_is_clamped_to_max_page_size` | `u32::MAX → MAX_PAGE_SIZE(500)`；`0 → 50` |
| `document_for_missing_note_is_empty_not_error` | 无文档返回空文档，**不是**错误 |
| `corrupted_document_bytes_are_reported` | **损坏文档字节必须被报告**：人工写入 `"definitely not json"` 后读取 → `DbError::Corrupt { entity: "document" }` |
| `archived_filter_works` | `archived: Some(true)` 只返回归档笔记 |
| `mark_accessed_records_time` | `accessed_at_ms` 被单独记录，且不影响其他列 |

### 12.5 `repositories/tags.rs`

| 测试 | 验证的不变量 |
|---|---|
| `insert_and_find_case_insensitively` | `"Work"` 写入后能用 `"work"` 查到（`COLLATE NOCASE`） |
| `duplicate_name_is_a_conflict_not_a_panic` | 重名是 `DbError::Conflict { entity: "tag" }`，**不是 panic** |
| `chinese_tags_are_supported` | 中文标签正常写入与列出 |
| `attach_is_idempotent_and_detach_removes` | 重复打标签幂等（关系数仍为 1）；取消后为空 |
| `set_note_tags_replaces_previous_set` | **覆盖语义**：设置新集合后旧标签消失，`list_for_note` 只剩新的 |
| `soft_deleted_tag_disappears_from_note_tags` | 标签软删除后，从笔记的标签列表与全量列表中都消失（但关系行仍在） |
| `soft_delete_missing_is_not_found` | 删不存在的标签 → `DbError::NotFound { entity: "tag" }` |

### 12.6 `repositories/attachments.rs`

| 测试 | 验证的不变量 |
|---|---|
| `same_content_is_deduplicated` | **相同 SHA-256 必须去重为一条记录**；文件名刷新为最新；`COUNT(*) == 1` |
| `ref_count_follows_references` | 引用计数随两篇笔记的挂/摘在 1↔2↔0 之间变化；归零后成为 GC 候选 |
| `sync_note_links_is_idempotent` | 同一集合重复同步，`note_attachments` 仍只有 1 行 |
| `document_attachments_are_linked_through_note_write` | 文档中**嵌套**在列表项里的图片也会被递归收集并建立引用 |
| `unreferenced_attachments_are_not_deleted_physically` | **GC 候选不得被自动物理删除**（铁律 D2）：候选 1 条，表里仍有 1 行 |
| `total_bytes_sums_attachment_sizes` | 只统计未删除附件（`deleted_at_ms IS NULL`）的 `size_bytes` 之和 |

### 12.7 `repositories/revisions.rs`

| 测试 | 验证的不变量 |
|---|---|
| `revisions_form_a_chain` | 修订通过 `parent_revision_id` 连成链；最新在前；`count_for_note` 正确 |
| `limit_is_respected` | `list_for_note(limit=2)` 返回 2 条，而总数为 5 |
| `latest_for_note_without_history_is_none` | 无历史返回 `None`，不是错误 |
| `get_missing_is_none` | 不存在的修订返回 `None` |

### 12.8 `repositories/sync_operations.rs`

| 测试 | 验证的不变量 |
|---|---|
| `enqueue_then_list_pending_in_order` | 待推送按**入队顺序**返回（`note.create` 在 `note.update` 之前） |
| `mark_pushed_removes_from_pending` | 标记已推送后不再出现在待推送列表，计数归零 |
| `payload_is_preserved` | `payload` 字节原样保存与读回 |
| `limit_is_respected` | `list_pending(limit=2)` 返回 2 条，总数为 5 |

### 12.9 `rowmap.rs`（列映射与损坏策略）

| 测试 | 验证的不变量 |
|---|---|
| `bool_helpers_are_consistent` | `bool_to_int(true)=1`、`false=0` |
| `u64_roundtrip_within_range` | `u64 → i64 → u64` 往返一致（文件大小） |
| `negative_value_is_rejected_as_corrupt` | 负数尺寸 → `DbError::Corrupt { entity: "attachment" }`（**不静默截断**） |
| `id_blob_roundtrip` | `Id` 与 16 字节 BLOB 互转一致 |
| `corrupt_error_carries_entity_name` | 损坏错误文本含实体名（可定位，E3） |

### 12.10 `nested-core` 的端到端测试（跨层验证存储约定）

| 测试 | 验证的不变量 |
|---|---|
| `open_in_memory_is_ready` | `readiness()` 三项全绿；`schema_version == LATEST_VERSION` |
| `open_creates_database_file_in_data_dir` | 数据目录下确实生成了 `nested.db`（文件名来自 `branding::DATABASE_FILE`） |
| `note_lifecycle_end_to_end` | 建笔记本→建笔记→保存（version=2）→软删（`note_count=0`，`include_deleted` 可见）→恢复（`note_count=1`） |
| `closing_and_reopening_keeps_data` | 关闭后重新打开同一目录，数据仍在（**持久化闭环**） |
| `save_increments_version_and_leaves_pending_sync` | 保存后待同步数为 1 |
| `duplicate_tag_is_conflict` / `missing_note_is_not_found` / `invalid_title_is_validation_error` | `DbError` 被正确映射为 `CONFLICT` / `NOT_FOUND` / `VALIDATION_ERROR` 错误码 |

### 12.11 覆盖缺口（诚实标注）

| 缺口 | 说明 |
|---|---|
| 迁移升级路径 | 只有护栏，没有"从 v1 升到 v2"的端到端测试（P1-36） |
| `EXPLAIN QUERY PLAN` | 无任何记录（Q5，P1-8 / P4-5） |
| 崩溃注入 | 无（Z5，P4） |
| 并发写竞争 | 单写连接下无并发测试；引入连接池（P4）时必须补 |
| 真实损坏文件 | 只有"写入非法字节"的模拟（`corrupted_document_bytes_are_reported`），没有真实损坏库文件的恢复测试（Z5） |
| "落盘 + 写库"的组合路径 | ⬜ 无测试——因为还没有这样的函数（见 §11.3 第 9 条）。相邻的 CAS 层自身已有 21 个测试（`nested-attachment`：哈希已知向量、两级分片、去重、临时文件不残留、损坏检测、幂等删除、与 `storage_key` 的布局一致性） |

---

## 13. 验证命令（可复制）

> 全部命令在仓库的 `client/` 目录下执行（`justfile` 里的 `client_dir := "client"`）。
> PowerShell 示例；`--data-dir` 也可用 `NESTED_HOME` 环境变量代替。

### 13.1 CLI 自检（建库 + 迁移 + 完整性）

```powershell
cd client
cargo run -p nested-cli -- doctor --data-dir C:\tmp\nested-demo
```

按 `client/cli/src/main.rs` 的打印语句，输出形如：

```text
数据目录：C:\tmp\nested-demo
  [OK  ] database_open
  [OK  ] schema_current
  [OK  ] integrity
  schema 版本：1
  笔记数量：0
  待同步操作：0
结论：一切正常。
```

退出码：`0` 成功、`1` 运行时失败、`2` 用法错误。**再跑一次**同一条命令可验证幂等：
数据仍在、迁移不重复执行。只想建库可用：

```powershell
cargo run -p nested-cli -- init --data-dir C:\tmp\nested-demo
```

### 13.2 数据库级门禁（迁移护栏 + PRAGMA + 事务回滚）

```powershell
cd client
cargo test -p nested-db                 # 全部单测 + 迁移护栏
cargo test -p nested-db --test migration_guard   # 只看迁移护栏
```

护栏失败时的提示会直接告诉你该怎么做："已发布的迁移不可修改（铁律 Q2）。
请新增一条迁移，而不是改这一条。若只是换行符漂移，运行
`pwsh scripts/normalize-line-endings.ps1`"。

### 13.3 手工核验迁移哈希（与护栏清单比对）

```powershell
cd C:\Software\notebook
(Get-FileHash client\migrations\0001_init.sql -Algorithm SHA256).Hash.ToLower()
# 期望：4566e916ca98e4d437020b13a79999abaf6fa7639a09146f57b8159125d93341
# （与 client/crates/nested-db/tests/migration_guard.rs 的 MIGRATION_HASHES 一致）
```

行尾必须为 LF（不含 `CR`）：

```powershell
Select-String -Path client\migrations\*.sql -Pattern "`r"   # 期望：无匹配
```

### 13.4 查看 schema（需要本机装有 `sqlite3` CLI，非仓库依赖）

> ⚠️ **仅在应用已关闭时做只读查看**。铁律 D12 禁止在 WAL 模式下用外部进程随意改写
> 数据库文件；下面的命令全部是只读查询。

```powershell
sqlite3 C:\tmp\nested-demo\nested.db ".schema"                       # 全部 DDL
sqlite3 C:\tmp\nested-demo\nested.db "PRAGMA user_version;"          # 期望 1
sqlite3 C:\tmp\nested-demo\nested.db "PRAGMA journal_mode;"          # 期望 wal
sqlite3 C:\tmp\nested-demo\nested.db "PRAGMA foreign_keys;"         # 本连接默认 0（见下方说明）
sqlite3 C:\tmp\nested-demo\nested.db "PRAGMA integrity_check;"       # 期望 ok
sqlite3 C:\tmp\nested-demo\nested.db ".indexes notes"                # notes 上的全部索引
sqlite3 C:\tmp\nested-demo\nested.db "SELECT name, type FROM sqlite_master ORDER BY name;"
```

两点必须理解：

1. `PRAGMA foreign_keys` 是**每连接**设置，`sqlite3` CLI 自己的连接默认是 `0`；
   应用连接是 `ON`（`db.rs` 里显式设置，且有测试断言）。看到 `0` 不代表库有问题。
2. `journal_mode` 是**持久化在库文件里**的，所以外部连接也能看到 `wal`。

### 13.5 铁律自动检查（裸 DELETE / 拼接 SQL / 产品代码 panic）

```powershell
cd client
cargo run -p nested-rules -- --root ..
```

重点看 D2（裸 `DELETE FROM` 白名单只允许 `note_tags` / `note_attachments`）
与 Q4（`format!` 拼 SQL 只允许 `{COLUMNS}` / `{columns}`）。

---

## 参考

本文档在撰写时**实际读过**的文件（全部内容以这些文件为准）：

| 文件 | 用途 |
|---|---|
| `client/migrations/0001_init.sql` | 唯一的迁移文件：10 张表、11 条显式索引、外键与默认值 |
| `client/crates/nested-db/src/db.rs` | PRAGMA 基线、打开标志、`with_transaction`、`check_integrity`、`NoteQuery`、`MAX_PAGE_SIZE` |
| `client/crates/nested-db/src/migrations.rs` | `Migration` / `MIGRATIONS` / `LATEST_VERSION` / `apply` / `validate_manifest` |
| `client/crates/nested-db/src/error.rs` | `DbError` 全部 9 个变体 |
| `client/crates/nested-db/src/rowmap.rs` | 列映射与 `Corrupt` 策略 |
| `client/crates/nested-db/src/lib.rs` | crate 边界的铁律映射表 |
| `client/crates/nested-db/src/repositories.rs` | Repository 层规则（唯一允许写 SQL 的地方） |
| `client/crates/nested-db/src/repositories/notebooks.rs` | 笔记本仓储与测试 |
| `client/crates/nested-db/src/repositories/notes.rs` | 笔记/文档仓储、事务边界、测试 |
| `client/crates/nested-db/src/repositories/tags.rs` | 标签仓储、`set_note_tags` 覆盖语义、测试 |
| `client/crates/nested-db/src/repositories/attachments.rs` | SHA-256 去重、`sync_note_links`、`refresh_ref_count`、测试 |
| `client/crates/nested-db/src/repositories/revisions.rs` | 追加型修订仓储与测试 |
| `client/crates/nested-db/src/repositories/sync_operations.rs` | 待同步队列仓储与测试 |
| `client/crates/nested-db/tests/migration_guard.rs` | 哈希清单、清单一致性、命名、LF 四道护栏 |
| `client/crates/nested-core/src/api.rs` | `NestedCore` 业务入口、`readiness()`、端到端测试 |
| `client/crates/nested-core/src/error.rs` | `CoreError` → 错误码与用户提示的映射 |
| `client/crates/nested-core/src/branding.rs` | `DATABASE_FILE = "nested.db"` |
| `client/crates/nested-model/src/entity.rs` | 领域类型、长度上限、`Attachment::storage_key` |
| `client/crates/nested-model/src/document.rs` | `DOCUMENT_FORMAT_VERSION`、`to_bytes` / `from_bytes` |
| `client/crates/nested-model/src/id.rs` | UUIDv7 与 16 字节 BLOB |
| `client/crates/nested-attachment/src/lib.rs` | CAS 实现：`hash_bytes` / `hash_file` / `is_valid_hash`、`ContentStore::{path_for, put_bytes, put_file, read, verify, delete}`、两级分片与 `AttachmentError` 变体 |
| `client/crates/nested-search/src/lib.rs` | FTS5 现状（仅 crate 边界）与待决策点 |
| `client/crates/nested-export/src/lib.rs` | 备份 manifest 常量（P1） |
| `client/cli/src/main.rs` | `version` / `doctor` / `init` 命令与输出格式 |
| `client/tools/nested-rules/src/checks.rs` | D2 白名单、Q4 插值检查及其盲区 |
| `justfile` | `cli-doctor` / `cli-init` / `check-rules` 等任务定义 |
| `README.md` | 快速开始命令、仓库结构与数据主权说明 |
| `docs/02-工程铁律.md` | T1–T10、D1–D13、Q1–Q12、P2/P4、R1–R13、Z1–Z10、M1–M4 |
| `docs/01-开发计划.md` | P0–P7 阶段与 P1-5…P1-36 任务号 |
| `docs/adr/0003-migration-hash-guard.md` | 哈希护栏的决策与后果 |
| `docs/design/README.md` | 本文档的编号与写作规范 |
| `docs/tech-debt.md` | 已登记的技术债（用于交叉核对） |
| `docs/reports/gate-p0.md` | P0 实测证据（CLI 与 UI 的真实输出） |
