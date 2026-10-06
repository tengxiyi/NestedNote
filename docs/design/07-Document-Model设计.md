# Document Model 设计

> 文档编号 `06`（编号顺序依据 `docs/design/README.md`，本文件是 README「当前优先级」中的第 1 项）。
> 对应实现：`client/crates/nested-model`（类型与纯函数）、`client/crates/nested-db`（持久化）。
> 依据：铁律 T5 / T1 / T6 / T9 / D1 / D6 / D7 / D8 / A10 / Q2 / Q11 / R1 / R9 / S6 / U3 / P2 / Z2 / Z3 / M1 / M3。

## 0. 状态速览（先看这张表）

| 能力 | 状态 | 证据 |
|---|---|---|
| `Block` 13 种变体与 serde 契约 | ✅ 已实现 | `client/crates/nested-model/src/block.rs:113-230` |
| `Document` / `DocumentMetadata` / 格式版本常量 | ✅ 已实现 | `client/crates/nested-model/src/document.rs:17-56` |
| JSON 往返序列化（`to_bytes` / `from_bytes`） | ✅ 已实现 | `client/crates/nested-model/src/document.rs:82-107` |
| 「版本过高必须报错」 | ✅ 已实现 | `client/crates/nested-model/src/document.rs:100-105` |
| 文档持久化（`documents` 表 / upsert / get） | ✅ 已实现 | `client/crates/nested-db/src/repositories/notes.rs:164-210` |
| 写入事务边界（元数据 + 文档 + 附件引用 + 修订 + 同步队列） | ✅ 已实现 | `client/crates/nested-db/src/repositories/notes.rs:223-281` |
| `searchable_text()` / `block_count()` / `attachment_ids()` | ✅ 已实现（`attachment_ids` 已接入写入路径；前两者**暂无生产调用方**） | `client/crates/nested-model/src/document.rs:109-133`、`notes.rs:85`、`notes.rs:257` |
| Markdown / HTML / 纯文本渲染器（投影） | ❌ 未实现（P1-20 / P1-21 / P1-24） | `client/crates/nested-export/src/lib.rs:1-3` 仅 crate 边界 |
| FTS5 索引（`searchable_text()` 的消费者） | ❌ 未实现（P1-12 / P1-15） | `client/migrations/0001_init.sql` 无 FTS 表；`nested-search` 仅接口草案 |
| 块级懒加载 / 局部更新 | ❌ 未实现（P1-31） | 无块级 id，保存为整文档覆盖 |
| 内容压缩 | ❌ 未实现（**已知取舍**，见 §8） | 全仓库无压缩依赖与调用 |
| 块级嵌套深度、单文档块数上限校验 | ❌ 未实现（P1-4 只完成了文本长度部分） | `client/crates/nested-model/src/entity.rs:325-345` 只有文本长度校验 |

---

## 1. 设计目标与约束

### 1.1 为什么不用 HTML / Markdown 作为核心存储格式

铁律 **T5（文档模型优先）** 原文：

> **禁止**把 HTML/Markdown 当作核心持久化格式。
> 核心格式**必须**是结构化 Block Model（`Document { version, blocks[] }`），HTML/Markdown/纯文本都是**投影（renderer）**，不是真相。

代码层面的落实（已实现）：

- `nested-model` 的 crate 文档注释直接写明该约束与「HTML / Markdown / 纯文本都只是本模型的投影」：`client/crates/nested-model/src/block.rs:1-10`。
- `nested-model` 只依赖 `serde` / `serde_json` / `thiserror` / `uuid` / `time`，不依赖任何 HTML/Markdown 解析或渲染库：`client/crates/nested-model/Cargo.toml:10-15`。
- 领域模型 crate 不含任何 IO（不碰数据库、文件、网络）：`client/crates/nested-model/src/lib.rs:1-13`。

不用 HTML/Markdown 当核心格式的具体代价（每条都是「若反过来选」会发生的事）：

| 方案 | 直接后果 | 违反的铁律 |
|---|---|---|
| HTML 当真相 | 样式与内容耦合，`<span style>` 成为数据；跨端渲染差异变成数据差异；同步要按 DOM 树做 diff；无法可靠地按块做懒加载 | T5、T9、A10 |
| Markdown 当真相 | 方言不统一（CommonMark / GFM / 各家扩展）；表达力不足以承载表格表头、附件引用、链接卡片；往返必然有损 | T5、T1（有损即数据丢失） |
| 纯文本当真相 | 结构完全丢失，标题/列表/待办无法区分 | T5、T9 |

反过来说，投影是允许且必要的（**未实现**）：技术文档 §7 给出的方向是 `Document Model → HTML Renderer`，而不是 `HTML = Database Format`；落点任务是 P1-20（Markdown 双向）、P1-21（HTML）、P1-24（JSON 归档导出），当前 `nested-export` 只有 `ExportFormat` 枚举与错误类型（`client/crates/nested-export/src/lib.rs:14-41`）。

### 1.2 Block Model 带来什么

技术文档 §7 列出八条优点。逐条对照本仓库的**已实现依据**与**待完成部分**：

| 技术文档 §7 的优点 | 本仓库的落实 | 状态 |
|---|---|---|
| 易于跨平台 | 模型是纯 Rust 数据结构 + JSON，不含平台相关类型；`#![forbid(unsafe_code)]`（`nested-model/src/lib.rs:13`） | ✅ |
| 易于版本迁移 | `DOCUMENT_FORMAT_VERSION` + `DocumentMetadata::format` 双标识（`document.rs:17`、`document.rs:45`）；版本规则写在模块头（`document.rs:6-10`） | ✅ 机制已就位，迁移函数**未实现**（当前只有 v1） |
| 易于同步 | 每次保存追加 `revisions` 并入队 `sync_operations`（`notes.rs:260-277`，同一事务） | ✅ 写入侧；传输协议属 P6 |
| 易于 Markdown 导出 | `ExportFormat::Markdown` 已定义 | ❌ 渲染器未实现（P1-20） |
| 易于 AI 处理 | 结构化块是技术文档 §7 的既有前提；AI 能力阶段为 P7，且必须走 `Document → Text Extraction → AI Service → Structured Result → Document Update`（开发计划 §8） | ❌ 未实现（P7） |
| 易于搜索 | `Document::searchable_text()` / `Block::searchable_text()`（`document.rs:111-117`、`block.rs:330-358`） | ✅ 取文本能力；FTS5 索引未实现（P1-12） |
| 易于实现局部更新 | 模型本身按块组织，`Vec<Block>` 可按下标替换单块 | ❌ 持久化层仍是整文档覆盖（见 §9），且块无稳定 id |
| 易于将来转换成 CRDT | 块枚举 + 「只能新增变体、禁止改语义」的演进规则（`block.rs:112`） | ❌ 未实现，且必须**先 ADR**（铁律 A9、开发计划 §8） |

数据流（规划形态，虚线为未实现部分）：

```text
                ┌──────────────────────────────┐
                │  Document { metadata, blocks }│   ← 唯一真相（T5，已实现）
                └──────────────┬───────────────┘
        ┌──────────────┬───────┴────────┬──────────────┬─────────────┐
        ▼              ▼                ▼              ▼             ▼
  JSON 存储字节    Markdown/HTML    编辑器 Adapter   FTS5 索引    AI/导出
  （已实现）        投影（P1）       （P3-9）        （P1-12）    （P7）
```

### 1.3 硬约束（不可协商）

| 约束 | 内容 | 本文档的落实点 |
|---|---|---|
| T4 / A1 | Rust Core 是唯一事实来源，Flutter 不得实现业务规则 | 类型只定义在 `nested-model`；FFI 面当前只暴露 branding（`client/apps/rust/src/api/mod.rs:17`） |
| T1 / D1 | 写操作必须原子 | 文档写入永远在调用方事务内（§6.5） |
| D6 / Q2 | 已发布 migration 不可变 | `documents` 表结构只能新增 migration 修改（§6.7） |
| D7 | 标识必须是 UUIDv7 | `Id(Uuid)`，`Uuid::now_v7()`（`id.rs:12-21`） |
| D8 | 时间必须是 UTC 毫秒整数 | `DocumentMetadata` 的 `*_at_ms: i64`、`Timestamp(i64)`（`time.rs:10-12`） |
| A10 | 接口/格式改动必须评估影响面 | 版本演进判定规则（§5.3） |
| U3 | 必须按字素簇处理 Unicode | 行内标记的偏移边界规则（§4.3） |
| S6 | 外部输入必须在 Rust 层校验 | ⚠️ **部分缺失**：反序列化路径没有语义校验（§11 H7） |
| R1 / R2 | 产品代码禁止 panic、禁止 `unsafe` | `#![forbid(unsafe_code)]`；切片一律要求先做边界校验（§4.3） |

---

## 2. 类型清单

全部类型与导出面（`client/crates/nested-model/src/lib.rs:22-30`）：

```rust
pub use block::{Block, BlockKind, InlineMark, ListItem, TableCell, TableRow};
pub use document::{DOCUMENT_FORMAT_VERSION, Document, DocumentMetadata};
pub use entity::{Attachment, MAX_FILENAME_CHARS, MAX_NOTEBOOK_NAME_CHARS, MAX_SUMMARY_CHARS,
                 MAX_TAG_NAME_CHARS, MAX_TITLE_CHARS, Note, Notebook, Revision, Tag};
pub use error::{ModelError, Result};
pub use id::Id;
pub use time::{Timestamp, now_ms};
```

> 注意：`InlineMarkKind` 是 `pub` 的，但**没有**从 `lib.rs` 重导出。外部 crate 只能通过 `InlineMark.kind` 字段访问它，无法直接 `use nested_model::InlineMarkKind`。这是一处导出面遗漏（见 §11 H13）。

### 2.1 `Block` 的 13 个变体（完整字段表）

枚举定义与 serde 属性（`client/crates/nested-model/src/block.rs:113-230`）：

```rust
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "type")]
pub enum Block { ... }
```

列语义：
- **可缺失** = 反序列化时该键可以不在 JSON 里（有 `#[serde(default)]` / `#[serde(default = "...")]`）。
- **默认值** = 键缺失时的取值。
- **序列化省略** = 什么时候写出时省略该键（`skip_serializing_if`）。

| # | 变体 | 判别值 | 字段 | 类型 | 可缺失 | 默认值 | 序列化省略 | 精确 serde 属性 |
|---|---|---|---|---|---|---|---|---|
| 1 | `Paragraph` | `paragraph` | `text` | `String` | ✅ | `""` | 否 | `#[serde(default)]` |
| | | | `marks` | `Vec<InlineMark>` | ✅ | `[]` | 空数组时 | `#[serde(default, skip_serializing_if = "Vec::is_empty")]` |
| 2 | `Heading` | `heading` | `level` | `u8` | ❌ | — | 否 | 无 |
| | | | `text` | `String` | ✅ | `""` | 否 | `#[serde(default)]` |
| | | | `marks` | `Vec<InlineMark>` | ✅ | `[]` | 空数组时 | `#[serde(default, skip_serializing_if = "Vec::is_empty")]` |
| 3 | `List` | `list` | `ordered` | `bool` | ✅ | `false` | 否（`false` 仍写出） | `#[serde(default)]` |
| | | | `start` | `u32` | ✅ | `1` | 等于 1 时 | `#[serde(default = "default_list_start", skip_serializing_if = "is_default_list_start")]` |
| | | | `items` | `Vec<ListItem>` | ✅ | `[]` | 否 | `#[serde(default)]` |
| 4 | `ListItem` | `list_item` | `text` | `String` | ✅ | `""` | 否 | `#[serde(default)]` |
| | | | `children` | `Vec<Block>` | ✅ | `[]` | 空数组时 | `#[serde(default, skip_serializing_if = "Vec::is_empty")]` |
| 5 | `Checklist` | `checklist` | `checked` | `bool` | ✅ | `false` | 否（`false` 仍写出） | `#[serde(default)]` |
| | | | `text` | `String` | ✅ | `""` | 否 | `#[serde(default)]` |
| 6 | `Quote` | `quote` | `text` | `String` | ✅ | `""` | 否 | `#[serde(default)]` |
| | | | `cite` | `Option<String>` | ✅ | `None` | `None` 时 | `#[serde(default, skip_serializing_if = "Option::is_none")]` |
| 7 | `Code` | `code` | `language` | `Option<String>` | ✅ | `None` | `None` 时 | `#[serde(default, skip_serializing_if = "Option::is_none")]` |
| | | | `code` | `String` | ✅ | `""` | 否 | `#[serde(default)]` |
| 8 | `Image` | `image` | `attachment_id` | `Id` | ❌ | — | 否 | 无 |
| | | | `alt` | `Option<String>` | ✅ | `None` | `None` 时 | `#[serde(default, skip_serializing_if = "Option::is_none")]` |
| | | | `width` | `Option<u32>` | ✅ | `None` | `None` 时 | `#[serde(default, skip_serializing_if = "Option::is_none")]` |
| | | | `height` | `Option<u32>` | ✅ | `None` | `None` 时 | `#[serde(default, skip_serializing_if = "Option::is_none")]` |
| 9 | `File` | `file` | `attachment_id` | `Id` | ❌ | — | 否 | 无 |
| | | | `filename` | `String` | ❌ | — | 否 | 无 |
| 10 | `Table` | `table` | `rows` | `Vec<TableRow>` | ✅ | `[]` | 否 | `#[serde(default)]` |
| 11 | `Divider` | `divider` | （无字段） | — | — | — | — | 单元变体 |
| 12 | `Link` | `link` | `text` | `String` | ❌ | — | 否 | 无 |
| | | | `href` | `String` | ❌ | — | 否 | 无 |
| 13 | `Embed` | `embed` | `provider` | `String` | ❌ | — | 否 | 无 |
| | | | `reference` | `String` | ❌ | — | 否 | 无 |

要点（每条都能在源码中直接核对）：

1. **只有 5 类字段**带 `skip_serializing_if`：`marks`（空省略）、`start`（=1 省略）、`children`（空省略）、`Option<_>`（`None` 省略）、`TableCell::header`（`false` 省略）。
2. `ordered` 与 `checked` 虽然是 `bool` 且有 `default`，但**没有** `skip_serializing_if`，所以 `false` 会被写出来（`block.rs:137-150`、`block.rs:161-168`）。这解释了测试里 `{"type":"checklist","checked":false,...}` 保留 `checked` 的现象。
3. 只有 `Paragraph` 与 `Heading` 有 `marks`。**列表项、待办、引用、代码、表格单元格都不支持行内标记**——这是当前的表达力缺口（见 §9）。
4. `Image` / `File` **必须**带 `attachment_id`：附件引用不能丢，缺失即反序列化失败（符合 T8「文件不进数据库，只存元数据与引用」）。
5. `Link` / `Embed` 的所有字段都必需：避免出现「空链接」「无 provider 的嵌入」这类半成品数据。
6. `Embed` 是 P7 的能力预留（`block.rs:44`、`block.rs:223`），当前只有序列化形状，没有任何渲染或解析实现。

### 2.2 `Block` 的辅助方法（已实现）

| 方法 | 签名 | 行为 | 位置 |
|---|---|---|---|
| `Block::paragraph` | `fn(text: impl Into<String>) -> Self` | 构造段落，`marks` 为空 | `block.rs:261-266` |
| `Block::heading` | `fn(level: u8, text) -> Result<Self>` | `level` 不在 `1..=6` → `ModelError::Validation { field: "heading.level" }` | `block.rs:273-285` |
| `Block::checklist` | `fn(text, checked: bool) -> Self` | 构造待办 | `block.rs:289-294` |
| `Block::code` | `fn(language: Option<impl Into<String>>, code) -> Self` | 构造代码块 | `block.rs:298-303` |
| `Block::kind` | `const fn(&self) -> BlockKind` | 判别值，13 个分支全覆盖 | `block.rs:307-323` |
| `Block::searchable_text` | `fn(&self) -> String` | 见 §7.1 | `block.rs:330-358` |
| `Block::attachment_id` | `const fn(&self) -> Option<Id>` | 仅 `Image` / `File` 返回 `Some` | `block.rs:362-369` |

> **校验只发生在构造器里，不在反序列化里**：`{"type":"heading","level":99,...}` 能通过 `from_bytes`（serde 不做范围检查）。详见 §11 H7。

### 2.3 其它块内类型

**`InlineMark`**（`block.rs:52-60`）：

| 字段 | 类型 | 可缺失 | 默认值 | serde 属性 |
|---|---|---|---|---|
| `start` | `usize` | ❌ | — | 无（JSON 数字） |
| `end` | `usize` | ❌ | — | 无（JSON 数字） |
| `kind` | `InlineMarkKind` | ❌ | — | 无 |

**`InlineMarkKind`**（`block.rs:63-79`，内部标签 `tag = "type"`）：

| 变体 | 判别值 | 字段 | 类型 | 可缺失 |
|---|---|---|---|---|
| `Bold` | `bold` | （无） | — | — |
| `Italic` | `italic` | （无） | — | — |
| `Strike` | `strike` | （无） | — | — |
| `Code` | `code` | （无） | — | — |
| `Link` | `link` | `href` | `String` | ❌ |

**`TableCell` / `TableRow`**（`block.rs:82-108`）：

| 类型 | 字段 | 类型 | 可缺失 | 默认值 | serde 属性 |
|---|---|---|---|---|---|
| `TableCell` | `text` | `String` | ❌ | — | 无 |
| `TableCell` | `header` | `bool` | ✅ | `false` | `#[serde(default, skip_serializing_if = "is_false")]` |
| `TableRow` | `cells` | `Vec<TableCell>` | ✅ | `[]` | `#[serde(default)]`（`false`/空**不**省略） |

`TableCell::new(text)` 构造普通单元（`header = false`，`block.rs:94-99`）。`TableCell` / `TableRow` 都派生了 `Default`（`block.rs:82`、`block.rs:103`）。

**`ListItem`（结构体，用于 `Block::List.items`）**（`block.rs:233-241`）：

| 字段 | 类型 | 可缺失 | 默认值 | serde 属性 |
|---|---|---|---|---|
| `text` | `String` | ✅ | `""` | `#[serde(default)]` |
| `children` | `Vec<Block>` | ✅ | `[]` | `#[serde(default, skip_serializing_if = "Vec::is_empty")]` |

> ⚠️ **设计观察**：列表项有两种表示 —— 结构体 `ListItem`（`List.items` 的元素）与枚举变体 `Block::ListItem { text, children }`。两者字段形状完全相同，导致 `collect_text` / `count_blocks` / `collect_attachment_ids` 各自都要写两个分支（`document.rs:147-163`、`document.rs:171-182`、`document.rs:194-208`）。新增块能力时两处都要改，是长期维护成本（见 §11 H14）。

**`BlockKind`**（`block.rs:17-46`）：13 个变体，与 `Block` 一一对应，`#[serde(rename_all = "snake_case")]`。文档注释称它「仅用于过滤、统计与 UI 图标映射，不参与序列化」——它确实不出现在 `documents.content` 的 JSON 里（文档 JSON 用的是 `Block` 自己的 `type` 标签），但类型本身派生了 `Serialize/Deserialize`，可跨 FFI/UI 传递。

### 2.4 `Document` 顶层类型

```rust
pub const DOCUMENT_FORMAT_VERSION: u32 = 1;              // document.rs:17

pub struct DocumentMetadata {                            // document.rs:20-30
    pub format: String,      // 固定 "nested.blocks"
    pub version: u32,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
}

pub struct Document {                                    // document.rs:49-56
    pub metadata: DocumentMetadata,
    #[serde(default)]
    pub blocks: Vec<Block>,
}
```

| 类型 | 字段 | 类型 | 可缺失 | serde 属性 |
|---|---|---|---|---|
| `DocumentMetadata` | `format` | `String` | ❌ | 无 |
| | `version` | `u32` | ❌ | 无 |
| | `created_at_ms` | `i64` | ❌ | 无 |
| | `updated_at_ms` | `i64` | ❌ | 无 |
| `Document` | `metadata` | `DocumentMetadata` | ❌ | 无（整块必需） |
| | `blocks` | `Vec<Block>` | ✅ | `#[serde(default)]`（空数组仍写出） |

常量与方法：

| 项 | 值 / 签名 | 位置 |
|---|---|---|
| `DOCUMENT_FORMAT_VERSION` | `1` | `document.rs:17` |
| `DocumentMetadata::FORMAT` | `"nested.blocks"` | `document.rs:45` |
| `DocumentMetadata::new(created_at_ms, updated_at_ms)` | 用当前版本与固定 format 构造 | `document.rs:35-42` |
| `Document::empty(at_ms)` | `metadata = new(at_ms, at_ms)`，`blocks` 为空 | `document.rs:61-66` |
| `Document::from_blocks(blocks, at_ms)` | `metadata = new(at_ms, at_ms)` | `document.rs:70-75` |
| `Document::to_bytes()` | `serde_json::to_vec` → `Vec<u8>` | `document.rs:82-87` |
| `Document::from_bytes(bytes)` | 反序列化 + 版本检查 | `document.rs:95-107` |
| `Document::searchable_text()` | 递归拼接可见文本 | `document.rs:111-117` |
| `Document::block_count()` | 递归计数（含列表项） | `document.rs:121-123` |
| `Document::attachment_ids()` | 去重后的附件 id 列表 | `document.rs:127-133` |
| `Document::touch(at_ms)` | 只改 `metadata.updated_at_ms` | `document.rs:136-138` |

`Document` 与 `Block` 都派生了 `PartialEq, Eq`，因此整文档相等性比较可用于脏检查（测试即以 `assert_eq!(get_document(..), document)` 验证往返，`notes.rs:367`）。

### 2.5 依赖的标识与时间类型

| 类型 | 定义 | 序列化形状 | 依据 |
|---|---|---|---|
| `Id` | `pub struct Id(Uuid)`，`#[serde(transparent)]`，`Id::new() = Uuid::now_v7()` | JSON 字符串（标准 UUID 连字符小写形式） | D7，`id.rs:12-21` |
| `Timestamp` | `pub struct Timestamp(i64)`，`#[serde(transparent)]` | JSON 数字（UTC 毫秒） | D8，`time.rs:10-12` |
| `now_ms()` | `OffsetDateTime::now_utc()` → 毫秒；溢出时取 `i64::MAX` | — | `time.rs:49-53`，注释声明这是 crate 内**唯一**读系统时钟的函数（R10） |

`Timestamp` 只用于需要类型化的场景（如 `nested-db` 的行映射，`notes.rs:13`）；`DocumentMetadata` 的时间字段直接用 `i64`，两者语义一致（UTC 毫秒）。

---

## 3. JSON 表示

### 3.1 为什么用内部标签（internally tagged）

`Block` 与 `InlineMarkKind` 都使用 `#[serde(rename_all = "snake_case", tag = "type")]`（`block.rs:114`、`block.rs:64`）。选择理由：

1. **与《技术文档》§6 的示例一致**：`{ "type": "heading", "level": 1, "text": "项目计划" }`——块自身字段与判别值在同一层，形如 HTML 的标签但语义更严格（`block.rs:6-10` 明示这一点）。
2. **自描述、可读、可手写**：导出的 JSON 归档（P1-24）与人工排查都不需要额外文档就能读懂；`documents.content` 是 BLOB，但内容是文本 JSON，`SELECT content` 出来就能看。
3. **前向兼容**：serde 的未知字段默认被**忽略**（未使用 `deny_unknown_fields`），因此新版本程序新增可选字段后，旧程序仍能读；而未知的 `type` 值**必须**被拒绝（`block.rs:392-395` 的测试 `unknown_block_type_is_rejected` 固定了这一行为）——「未知字段忽略、未知类型拒绝」正是 §5.3 版本规则的实现基础。
4. **代价（必须知道）**：内部标签要求内容必须能看成 map，因此 `Block` 不能从 bincode 之类的非自描述格式反序列化；serde 需要先把内容缓冲成中间表示，反序列化开销与错误定位精度都略差于外部标签。当前存储是 JSON（`documents.content`），不存在该限制。

### 3.2 测试逐字断言的真实样例

`block.rs` 的测试断定了精确的 JSON 字符串，这些是**规范级**证据（可直接复制为兼容性基线）：

| 样例 | 精确 JSON | 出处 |
|---|---|---|
| 待办块（逐字断言） | `{"type":"checklist","checked":false,"text":"完成数据库设计"}` | `block.rs:398-407` |
| 标题块（字段级断言） | `{"type":"heading","level":1,"text":"项目计划"}` | `block.rs:377-383` |
| 未知块类型（必须失败） | `{"type":"holo_projection","text":"hi"}` → `Err` | `block.rs:392-395` |
| 默认 `start` 必须省略 | `Block::List { ordered: true, start: 1, items: [] }` 序列化结果**不含** `"start"` | `block.rs:424-432` |

### 3.3 完整 `Document` 示例

下面这份 JSON 对应 `document.rs:216-239` 的 `sample_document()`（含 4 个块），字段顺序按结构体/变体声明序，为便于阅读加了缩进；**`to_bytes()` 实际产出的是同一内容的紧凑形式（无空格换行）**，因为用的是 `serde_json::to_vec`（`document.rs:83`）：

```json
{
  "metadata": {
    "format": "nested.blocks",
    "version": 1,
    "created_at_ms": 1700000000000,
    "updated_at_ms": 1700000000000
  },
  "blocks": [
    { "type": "heading", "level": 1, "text": "项目计划" },
    { "type": "paragraph", "text": "这是第一段内容。" },
    { "type": "checklist", "checked": false, "text": "完成数据库设计" },
    {
      "type": "list",
      "ordered": false,
      "items": [{ "text": "第一项" }, { "text": "第二项" }]
    }
  ]
}
```

其它变体的形状（按 §2.1 的属性推导，字段顺序=声明序）：

```json
{ "type": "divider" }
{ "type": "quote", "text": "被引用的话", "cite": "某本书" }
{ "type": "code", "language": "rust", "code": "fn main() {}" }
{ "type": "image", "attachment_id": "0190f3a1-8b2c-7d4e-9f01-2a3b4c5d6e7f", "alt": "截图" }
{ "type": "file", "attachment_id": "0190f3a1-8b2c-7d4e-9f01-2a3b4c5d6e7f", "filename": "a.pdf" }
{ "type": "table", "rows": [{ "cells": [{ "text": "单元格" }, { "text": "表头", "header": true }] }] }
{ "type": "link", "text": "官网", "href": "https://example.com" }
{ "type": "embed", "provider": "youtube", "reference": "dQw4w9WgXcQ" }
{ "type": "paragraph", "text": "带标记的段落", "marks": [
    { "start": 0, "end": 6, "kind": { "type": "bold" } },
    { "start": 0, "end": 6, "kind": { "type": "link", "href": "https://example.com" } }
] }
```

编码细节（对存储体积与检索有直接影响）：

- `serde_json::to_vec` 输出 UTF-8，**不转义非 ASCII**，因此中文在 `documents.content` 里就是 UTF-8 字节（1 个汉字 3 字节），不是 `\uXXXX`。
- 键顺序 = 声明顺序，同一版本程序对同一文档产出**确定性**的字节；但**禁止**把它当作格式承诺用于内容哈希——新增一个字段就会改变字节（见 §5.3、§11 H11）。
- `Id` 以字符串写入（36 字符），不是 16 字节 BLOB；只有数据库列 `notes.id` / `note_attachments.attachment_id` 等用 BLOB（`0001_init.sql:27`、`0001_init.sql:83-86`）。

### 3.4 与技术文档 §6 示例的差异（必须记录）

《技术文档》§6 的示例把版本放在**根级**：

```json
{ "version": 1, "blocks": [ ... ] }
```

实现是嵌套的 `metadata` 对象（`metadata.format` / `metadata.version`）。两者不等价：

- 技术文档的写法无法表达 `format`（多格式并存的前提）；
- 实现在 `lib.rs:23` 与 `document.rs:50-56` 是权威形状，**文档需按实现更新**（M3：行为变更必须同 PR 更新文档）。技术文档与实现不一致已在 §11 H8 登记。

---

## 4. 行内标记（InlineMark）

### 4.1 字节偏移的取舍

`InlineMark { start, end, kind }` 用 UTF-8 **字节**偏移 `[start, end)` 标注 `text` 的一个子区间（`block.rs:48-60`）。收益：

| 收益 | 说明 |
|---|---|
| 零拷贝切片 | `&text[start..end]` 直接得到 `&str`，渲染器不需要为每个标记分配新 `String` |
| 与 Rust 字符串模型一致 | Rust 的 `str` 索引本来就是字节偏移，模型与语言零阻抗 |
| 存储紧凑 | 两个整数 + 一个判别值，比「嵌套样式节点」小得多 |

代价（必须在解析器与渲染器两端承担）：

| 代价 | 具体要求 |
|---|---|
| 偏移合法性完全依赖写入方 | 模型不做校验（§11 H7）；越界或非字符边界会导致切片 panic（违反 R1） |
| 跨语言需要转换 | Dart 字符串是 UTF-16 code unit 索引，编辑器 Adapter（P3-9）必须做字节 ↔ code unit 双向换算 |
| 插入/删除会漂移 | 文本前插一个字符，后续所有标记的 `start/end` 都必须同量平移；这是编辑器 Adapter 的职责，模型不提供自动调整 |

### 4.2 为什么不用 UTF-16 code unit

铁律 **U3**：光标移动、删除、字数统计**必须**按字素簇处理，**禁止**按 UTF-16 code unit 粗暴切割导致乱码。

若用 UTF-16 偏移：

- 与 Rust 的 `str` 天然不匹配，每次渲染都要做一次全量 `char_indices` 换算（O(n) 且需要缓存），反而更贵；
- 与存储字节不一致，`documents.content` 是 UTF-8；UTF-16 偏移是「面向某一个 API 的实现细节」，不是数据的属性（A4：FFI 边界只传明确的数据结构，不传平台内存布局语义）；
- 中文与 Emoji 的编码长度差异会让「偏移」在不同平台上失去可比性。

字节偏移**不是**放松 Unicode 要求：字节边界是**下限**，字素簇边界才是目标（§4.3）。

### 4.3 解析器必须保证的边界条件

以下不变量**模型不强制**（`InlineMark` 无构造函数、无校验），由解析器（Markdown/HTML 导入，P1-20/P1-21）与编辑器 Adapter（P3-9）负责——本文档把它们定为契约，实现时必须逐条写测试：

| ID | 不变量 | 违反后果 | 依据 |
|---|---|---|---|
| B1 | `start <= end` | 空区间或反向区间，渲染逻辑出现负长度 | R1（不 panic 的前提） |
| B2 | `end <= text.len()`（字节长度） | 切片越界 panic | R1 |
| B3 | `start` 与 `end` 都落在**字符边界**上（`text.is_char_boundary(i)`） | `&text[start..end]` panic | R1 + U3 |
| B4 | 标记边界应落在**字素簇边界**上（例如不在 Emoji ZWJ 序列或组合音标中间切开） | 渲染出乱码/半截 Emoji，直接违反 U3 | U3 |
| B5 | 同一块内的标记按 `start` 升序、允许嵌套、禁止部分重叠（A 的 `end` 落在 B 的内部既不包含也不被包含） | 渲染器无法用单一栈处理，必须退化成区间图 | 可渲染性 |
| B6 | 空标记（`start == end`）不写入 | 无意义数据，增大体积、干扰相等性比较 | 数据整洁（T1 不冲突） |
| B7 | 渲染时用 `text.get(start..end)`（返回 `Option`）而不是直接切片 | 直接切片在数据损坏时 panic | R1、E6（失败必须可见） |

补充：`marks` 只存在于 `Paragraph` 与 `Heading`（§2.1 要点 3），因此「列表项里的加粗」在当前模型里**无法表达**；导入 Markdown 时遇到 `- **粗体**` 只能降级为纯文本或提升为段落——这是导入器必须显式处理的决策点（P1-20）。

---

## 5. 文档元信息与版本演进

### 5.1 `DocumentMetadata`

| 字段 | 类型 | 含义 | 依据 |
|---|---|---|---|
| `format` | `String` | 格式标识，固定 `"nested.blocks"`（`DocumentMetadata::FORMAT`），为将来「多格式并存」预留 | `document.rs:22`、`document.rs:45` |
| `version` | `u32` | 结构版本，新建文档取 `DOCUMENT_FORMAT_VERSION` | `document.rs:24`、`document.rs:38` |
| `created_at_ms` | `i64` | 创建时间（UTC 毫秒） | D8 |
| `updated_at_ms` | `i64` | 最近修改时间（UTC 毫秒），由 `Document::touch()` 维护 | `document.rs:136-138` |

注意：`created_at_ms` / `updated_at_ms` 是**文档自身**的时间，与 `notes.created_at_ms` / `notes.updated_at_ms` 是两组独立值（§11 H6 说明了它们当前会漂移）。

### 5.2 当前版本

| 常量 | 值 | 位置 |
|---|---|---|
| `DOCUMENT_FORMAT_VERSION` | `1` | `document.rs:17` |
| `DocumentMetadata::FORMAT` | `"nested.blocks"` | `document.rs:45` |
| 数据库 `documents.format_version` 列的值 | 写入 `document.metadata.version`（当前恒为 1） | `notes.rs:183` |

### 5.3 版本演进判定规则

规则原文写在模块头（`document.rs:6-10`），此处补上判定表与理由：

| 变更类型 | 是否升 `DOCUMENT_FORMAT_VERSION` | 是否需迁移函数 | 理由 |
|---|---|---|---|
| 新增块**变体**（如将来加 `Toggle`） | ❌ 不升 | ❌ | 旧程序读到未知 `type` 会报错，而不是误解数据（`block.rs:392-395`）——但需在 A10 评估中说明「旧版本无法打开含新块的文档」这一影响 |
| 新增**可选**字段（带 `#[serde(default)]`） | ❌ 不升 | ❌ | 旧文档缺该键 → 取默认值；新文档多该键 → 旧程序忽略。**代价见下方警告** |
| 删除字段 | ✅ 必须升 | ✅ 必须 | 旧文档里有该字段，新程序读到的语义已变 |
| 改变字段含义 / 单位 / 编码 | ✅ 必须升 | ✅ 必须 | 静默错读＝静默数据损坏（T1） |
| 改变必需性（可选 → 必需，或反之） | ✅ 必须升 | ✅ 必须 | 旧文档可能缺键而无法反序列化，属于破坏性 |
| 改变已有变体的判别值字符串 | ✅ 必须升 | ✅ 必须 | 判别值是持久化数据的一部分 |
| 仅调整结构体文档注释 / Rust 内部重构 | ❌ | ❌ | 不影响字节 |

> ⚠️ **「新增可选字段不升版本」的隐性代价（必须评估）**：旧版本程序读入含新字段的文档后再保存，会把不认识的字段**静默丢弃**（serde 忽略未知字段，回写时自然不带）。若该字段承载用户数据，这就是一次静默的数据丢失路径（T1 / D10）。因此建议细化为：
> - **派生/缓存类**字段（可重算）→ 不升版本；
> - **用户数据类**字段 → **升版本**（旧程序将明确拒绝读取并提示升级，而不是悄悄丢字段）。
> 该细化属于策略决定，落地前需走 ADR（M2）。

### 5.4 `from_bytes` 对「版本过高」的处理

```rust
pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
    let document: Self = serde_json::from_slice(bytes)
        .map_err(|_| ModelError::Validation { field: "document", reason: "文档字节不是合法的块模型 JSON" })?;
    if document.metadata.version > DOCUMENT_FORMAT_VERSION {
        return Err(ModelError::UnsupportedDocumentVersion {
            found: document.metadata.version,
            supported: DOCUMENT_FORMAT_VERSION,
        });
    }
    Ok(document)
}
```

（`document.rs:95-107`；错误定义见 `error.rs:18-23`，展示为「不支持的文档格式版本：{found}（当前支持到 {supported}）」）

**为什么必须报错而不是尽力解析**：

1. 高版本文档可能删除了字段、改变了字段含义——旧程序按旧结构解析会得到「结构合法但语义错误」的对象，随后一次保存就会把错误语义写回库，属于**静默数据损坏**（T1 数据不可丢；D10 禁止静默覆盖）。
2. 「尽力解析」让错误延后暴露：可能在导出、同步或 GC 时才炸，届时原始字节可能已被覆盖。
3. 明确报错给用户的是可操作结论（升级应用），符合 E2/E3 与 B9（回退必须说明数据兼容性）。
4. 测试固定了这一行为：`future_version_is_rejected_not_silently_parsed`（`document.rs:257-263`）。

配套的「降级回退」语义（B9）：本程序**只读不写**不可读版本的文档——但它当前做不到「只读」，因为 `get_document` 直接把错误折叠成 `Corrupt`（§11 H3）。

### 5.5 目前**没有**做的版本相关检查

| 缺口 | 现状 | 影响 |
|---|---|---|
| `metadata.format` 未校验 | `from_bytes` 完全不看 `format`；`format` 为 `"html"`、`version` 为 1 的 JSON 会被当作合法块文档接受 | 多格式并存时无法区分，属 S6/A10 缺口 |
| 版本**下界**未校验 | 判断是 `>`，`version = 0` 会被接受；无「低于最低支持版本」的概念 | 当前只有 v1，暂无实际风险；引入 v2 时必须同时定义下界 |
| 无迁移分派函数 | 只有常量 `DOCUMENT_FORMAT_VERSION`，不存在 `migrate(from, document)` 之类的入口 | 升到 v2 时**必须**新增并配套迁移测试（Z2/Q10 精神） |
| 写入路径不做版本校验 | `upsert_document` 只序列化不校验（`notes.rs:164-189`） | 可以写进一个随后永远读不出来的「毒文档」（§11 H4） |

---

## 6. 持久化表示

### 6.1 表结构（`client/migrations/0001_init.sql:91-98`）

```sql
-- 结构化文档内容（块模型；JSON 字节）
CREATE TABLE documents (
    note_id       BLOB PRIMARY KEY REFERENCES notes (id),
    format        TEXT    NOT NULL,
    format_version INTEGER NOT NULL,
    content       BLOB    NOT NULL,
    updated_at_ms INTEGER NOT NULL
);
```

| 列 | 类型 | 语义 | 写入来源 | 读取方 |
|---|---|---|---|---|
| `note_id` | `BLOB` PK，外键 → `notes(id)` | 一篇笔记最多一份文档（1:1） | `note.id.as_bytes()`（16 字节 UUIDv7） | 查询条件 |
| `format` | `TEXT NOT NULL` | 格式标识 | `document.metadata.format` | ⚠️ **无任何读取方**（§11 H1） |
| `format_version` | `INTEGER NOT NULL` | 版本号 | `document.metadata.version` | ⚠️ **无任何读取方**（§11 H1） |
| `content` | `BLOB NOT NULL` | 文档 JSON 字节 | `document.to_bytes()` | `Document::from_bytes` |
| `updated_at_ms` | `INTEGER NOT NULL` | UTC 毫秒 | `document.metadata.updated_at_ms` | 无（暂未用于排序/增量同步） |

**权威来源**：`content` 内的 `metadata` 是唯一权威；`format` / `format_version` 两列是为「不解 JSON 就能判断格式与版本」预留的冗余列，但当前读路径只 `SELECT content`（`notes.rs:197-203`），因此这两列与 JSON 内容**可能漂移**且无人发现。

### 6.2 写入路径：`upsert_document`

```rust
pub fn upsert_document(connection: &Connection, note_id: &Id, document: &Document) -> Result<(), DbError> {
    let bytes = document.to_bytes().map_err(|_| DbError::Corrupt { entity: "document" })?;
    connection.execute(
        "INSERT INTO documents (note_id, format, format_version, content, updated_at_ms)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT (note_id) DO UPDATE SET
             format = excluded.format,
             format_version = excluded.format_version,
             content = excluded.content,
             updated_at_ms = excluded.updated_at_ms",
        params![note_id.as_bytes(), document.metadata.format, document.metadata.version,
                bytes, document.metadata.updated_at_ms],
    )?;
    Ok(())
}
```

（`notes.rs:164-189`；为排版压缩了 `params!` 的换行，SQL 字符串与参数值均与源码逐字一致）

要点：

- 使用参数绑定（Q4 / R6），无字符串拼接。
- `ON CONFLICT (note_id) DO UPDATE`：**整文档覆盖**，不做块级合并、不比较差异。若两份不同的文档先后写入，后者完全胜利（并发场景需靠 `revisions` + P6 冲突检测兜底）。
- 序列化失败被映射为 `DbError::Corrupt { entity: "document" }`；`Document::to_bytes` 本身在结构合法时不会失败（只有 serde 内部错误，例如 JSON 容器无法表示），属防御性分支。
- **写入不做版本/格式校验**，也不验证文档是否可被本程序读回（§11 H4）。
- `updated_at_ms` 取自 `document.metadata.updated_at_ms`，不是调用时刻——调用方必须在保存前调用 `Document::touch()`（见 §11 H6）。

### 6.3 读取路径：`get_document`

```sql
SELECT content FROM documents WHERE note_id = ?1
```

（`notes.rs:197-203`）

| 情况 | 行为 | 依据 |
|---|---|---|
| 行存在且字节合法 | `Document::from_bytes` → 返回文档 | `notes.rs:205-207` |
| 行不存在 | `Ok(Document::empty(nested_model::now_ms()))` —— **不报错**，返回空文档 | `notes.rs:208`；测试 `document_for_missing_note_is_empty_not_error`（`notes.rs:504-510`） |
| 字节非法 JSON / 结构不匹配 | `DbError::Corrupt { entity: "document" }` | `notes.rs:206`；测试 `corrupted_document_bytes_are_reported`（`notes.rs:512-526`） |
| 文档版本高于本程序 | 同上 → 也被折叠为 `Corrupt` | `notes.rs:206`；⚠️ 丢失了 `UnsupportedDocumentVersion` 的可操作语义（§11 H3） |

「缺失即空文档」的设计理由：新建笔记时文档可能尚未落行（或调用方只关心内容）、读取路径不应把「还没写」当成错误（A3：暴露业务语义，不暴露存储细节）。代价是空文档的 `metadata.created_at_ms/updated_at_ms` 用的是**读取瞬间的系统时钟**（`now_ms()`），与 `notes` 行上的时间无关（§11 H9）。

### 6.4 事务边界

文档写入**从不**单独提交，永远由业务级入口包裹（铁律 D1，且 `notes.rs:1-7` 模块头明确说明为什么文档读写放在笔记仓储里）。

**创建**（`create_with_document`，`notes.rs:73-101`），单个事务内按序执行：

1. `INSERT INTO notes`（元数据）
2. `upsert_document`（文档）
3. `attachments::sync_note_links(.., &document.attachment_ids(), ..)`（附件引用，见 §7.3）
4. `revisions::insert(Revision::new(note.id, note.version, None, device_id, "note.create", ..))`
5. `commit()`

**保存**（`save_with_document`，`notes.rs:223-281`）：

```text
BEGIN（connection.unchecked_transaction()）
 ① UPDATE notes SET title, summary, notebook_id, updated_at_ms,
                   is_pinned, is_archived, deleted_at_ms, version
    WHERE id = ?1        ← 影响行数为 0 → DbError::NotFound("note")，整个事务回滚
 ② upsert_document       ← 覆盖 documents 行
 ③ sync_note_links       ← 按 document.attachment_ids() 增删 note_attachments 并刷新 ref_count
 ④ revisions::insert     ← Revision::new(note_id, note.version, parent_revision_id, device_id,
                                          "note.update", note.updated_at_ms)
 ⑤ sync_operations::enqueue(note_id, device_id, "note.update", note.updated_at_ms)
COMMIT
```

失败即整体回滚的测试证据：`create_is_rolled_back_when_document_is_invalid` 断言失败后 `documents` 只有 1 行（`notes.rs:378-400`），`save_missing_note_is_not_found` 断言笔记不存在时返回 `NotFound`（`notes.rs:450-458`）；同步入队的测试证据是 `save_enqueues_sync_operation`（`notes.rs:431-448`，对应铁律 T3）。

**删除**走 `notes.soft_delete`（只写 `deleted_at_ms`），文档行**保留不动**（`notes.rs:288-298`）。这与 T7/D2「附件与回收站保留、物理回收只由显式 GC 执行」一致：文档内容在回收站期间必须可恢复。

内核层的调用面（`client/crates/nested-core/src/api.rs`）：

| 内核方法 | 事务入口 | 位置 |
|---|---|---|
| `create_note` | `notes::create_with_document`，空文档 | `api.rs:145-158` |
| `create_note_with_document` | `notes::create_with_document` | `api.rs:167-179` |
| `get_note_document` | `notes::get_document` | `api.rs:196-199` |
| `save_note` | `note.touch(at_ms)` 后 `notes::save_with_document` | `api.rs:217-230` |
| `delete_note` / `restore_note` | `notes::soft_delete` / `restore` | `api.rs:237-252` |

> FFI 现状：`nested-app` 的导出面当前只有 `branding`（`client/apps/rust/src/api/mod.rs:17`，实际函数在 `api/branding.rs`），**Flutter 还不能读写文档**；文档能力目前仅对 Rust 侧（CLI/测试/Core API）可用。

### 6.5 与「迁移不可变」（D6 / Q2）的关系

`documents` 表是**已发布的结构**，因此：

- 不得直接修改 `0001_init.sql` 中 `documents` 的定义（迁移文件已发布即不可变：`client/crates/nested-db/src/migrations.rs:6-7` 说明 CI 用 `tests/migration_guard.rs` 校验文件哈希清单，铁律附 A 的「Q1 Q2 Q10」为自动门禁）；
- 需要新增列（例如压缩标志、块数缓存、`created_at_ms`）**必须**新增 `0002_*.sql` 并配套升级测试（Q10）；
- 文档**内容格式**的演进则走 §5.3 的 `DOCUMENT_FORMAT_VERSION`，与 schema 版本相互独立（Q12 的精神：两种版本各自演进）。

---

## 7. 派生能力

三项能力都是 `nested-model` 中的**纯函数**（不碰 IO），因此可被任意层复用、可单测。

### 7.1 `Document::searchable_text()` / `Block::searchable_text()`

**单块规则**（`block.rs:330-358`）：

| 变体 | 结果 |
|---|---|
| `Paragraph` / `Heading` / `ListItem` / `Checklist` | `text` |
| `Quote` | `text`（不含 `cite`） |
| `Code` | `code`（不含 `language`） |
| `Link` | `format!("{text} {href}")` —— **href 也进索引** |
| `List` | 各项 `item.text` 以单个空格连接，末尾 `trim_end` |
| `Table` | 所有单元格 `text` 以空格连接 |
| `Image` / `File` / `Divider` / `Embed` | `""` |

**整文档规则**（`document.rs:111-117`，`collect_text` 于 `document.rs:142-165`）：

- 深度优先、按出现顺序遍历，非空片段以单个空格连接；
- 递归进入 `Block::List` 各项的 `children` 与 `Block::ListItem` 的 `children`；
- 附件正文**不**入索引（`block.rs:325-328` 明示「那是 OCR 的职责，P7」），`Embed` 也不产出文本。

**用途**：作为 FTS5 索引的 `content` 来源（开发计划 P1-12 的 `notes_fts(title, content, tags)`），并顺带服务于摘要生成与将来的语义搜索（P7）。

**状态**：能力已实现并有测试（`document.rs:271-286`），但**当前没有任何生产调用方**（仓库内检索 `searchable_text` 只命中定义、内部递归与测试）——因为 FTS5 尚未实现。⚠️ 另有一个实现缺陷：列表项文本会被收集两次（§11 H5）。

### 7.2 `Document::block_count()`

**计数规则**（`document.rs:167-182` 的注释与实现）：

- 普通块算 1；
- `Block::List` 容器本身算 1，**每个列表项也算 1**（列表项是可独立编辑的内容单元），再加上各项的嵌套子块；
- `Block::ListItem` 算 1 加其子块。

测试固定：`List { items: [ ListItem { text: "父项", children: [Paragraph("子块")] } ] }` → `3`（`document.rs:289-302`）。

**用途**：性能统计与预算校验——大文档策略（P1-31）需要「块数」作为分块/懒加载的单位；也是把「文档规模」上报给日志与诊断（E5）的现成指标。**状态**：已实现，当前无生产调用方。

### 7.3 `Document::attachment_ids()`

**规则**（`document.rs:127-133`，`collect_attachment_ids` 于 `document.rs:185-209`）：递归（含列表项子块）收集 `Block::Image` / `Block::File` 的 `attachment_id`，**按首次出现顺序去重**（用 `Vec::contains` 判重）。

**用途与落地（这条是三项里唯一已接入写入路径的）**：

```text
Document::attachment_ids()
        ↓ （同一事务内）
attachments::sync_note_links(note_id, ids, at_ms)     notes.rs:82-87 / notes.rs:254-259
        ↓ 新增缺失、移除多余、对每个受影响的附件
attachments::refresh_ref_count(attachment_id)          attachments.rs:99-110
        ↓
attachments.ref_count   ← 附件 GC 的判据（T7 / T8 / P1-17）
```

测试证据：`attachment_ids_are_collected_and_deduplicated`（`document.rs:305-323`）；`document_attachments_are_linked_through_note_write`（`attachments.rs:310-349`，验证嵌套在列表项里的图片也被递归收集并建立引用）；引用计数随引用增减的测试见 `attachments.rs:265-290`。

**注意**：`sync_note_links` 内有一段 `DELETE FROM note_attachments`（`attachments.rs:156-164`），它删除的是**关系行**而非附件实体（附件本体与 `attachments` 行都不删），符合 D2/T7；GC 候选由 `list_unreferenced` 列出而**不**自动删除（`attachments.rs:177-187`、测试 `attachments.rs:352-363`）。

### 7.4 三项能力汇总

| 能力 | 语义 | 服务对象 | 落地位置 | 状态 |
|---|---|---|---|---|
| `searchable_text()` | 可见文本按序拼接 | FTS5 索引（P1-12）、摘要 | `document.rs:111` | ✅ 实现 / ❌ 无消费者 |
| `block_count()` | 含列表项的块计数 | 大文档策略（P1-31）、性能统计 | `document.rs:121` | ✅ 实现 / ❌ 无消费者 |
| `attachment_ids()` | 去重附件引用 | 引用计数 → 附件 GC（P1-17） | `document.rs:127` → `notes.rs:85,257` | ✅ 实现并接入写入事务 |

---

## 8. 尺寸与性能考虑

### 8.1 当前实现**不做压缩**（明确的已知取舍）

事实核对（可复核）：

- `documents.content` 存的是 `serde_json::to_vec` 的**未压缩 JSON 字节**（`document.rs:82-87`、`notes.rs:169-186`）；
- 仓库内不存在任何压缩依赖或调用（在 `client/` 全量检索 `compress|flate|zstd|deflate|lz4|brotli` **零命中**）；
- `documents` 表也没有「是否压缩」标志位（§6.1）。

这个取舍换来的是：

| 收益 | 说明 |
|---|---|
| 可诊断性 | `SELECT content FROM documents WHERE note_id = ?` 直接得到可读 JSON，不必先解压；故障排查与备份审计成本极低 |
| 少一个依赖与一条失败路径 | 无压缩库 = 无「解压失败」这一损坏模式，符合 A8（不为一个函数引入大依赖） |
| 内容确定（同版本内） | 同结构 → 同字节，便于比较与调试 |

代价与量级（**定性，不做无依据的定量声明**）：

- JSON 的键名重复占用体积（`type`/`text`/`marks` 每块都要写一遍）；
- 中文以 UTF-8 存储（3 字节/汉字），且不转义；
- 长文档的 `content` 是单个 BLOB，整份读入内存——与 T9（按需加载）在超大文档上存在张力，这正是 P1-31 的动机。

### 8.2 什么时候该重新评估压缩

依据铁律 **P2（必须先测量再优化：禁止以「感觉慢」为由重构，必须有 profile / benchmark 数据）**，压缩属于「先测量再决定」的优化项。触发条件：

| 触发条件 | 需要的证据 | 关联任务 |
|---|---|---|
| P4 数据集下 `documents` 表体积或打开大文档的 P95 耗时超出预算 | `docs/reports/perf-<date>.md` 的基线与前后对比（P10：报告必须可复现、记录硬件与数据集） | P4-2「打开大文档」场景 |
| 单文档块数达到 P1-31 的阈值，出现「整份 content 读入内存」的实际问题 | 块数分布统计（可用 `block_count()`）+ 内存剖析（P4-3） | P1-31 大文档策略 |
| 同步（P6）需要上传文档字节，网络体积成为瓶颈 | 上传体积与耗时数据 | P6-13 |
| 备份体积成为用户可见问题 | 备份报告中的 `documents` 占比 | P1-25 |

如果决定引入压缩，必须同时确定：**压缩算法与级别**、`documents` 是否需要新增标志列（→ 新 migration，D6）、**版本如何表达**（压缩属容器层，**不应**改动 `DOCUMENT_FORMAT_VERSION`，否则老程序读不了新文档而实际并没有语义变化——该判断需 ADR 记录）。

### 8.3 其它已知的复杂度特征（登记，不在无基准的情况下优化）

| 位置 | 特征 | 影响面 | 何时处理 |
|---|---|---|---|
| `Document::attachment_ids()` 用 `Vec::contains` 去重（`document.rs:186-190`） | 附件数 n 时为 O(n²) | 单文档附件数通常很小；`attachment_ids()` 每次保存都调用一次 | 若 P4 基准显示大批附件文档（如扫描件集合）受影响，改为 `HashSet` 保序 |
| `sync_note_links` 对每个受影响附件各发 1 次 `COUNT(*)` + 1 次 `UPDATE`（`attachments.rs:99-110`、`attachments.rs:166-168`） | 事务内 N 次往返，Q6/Q7 关注的形态 | 附件数大的文档保存变慢；**但都在本地事务内、无网络**，不违反 Q7「禁止在事务中做长耗时操作」的字面规定 | 同 P4 |
| 每次保存**整文档覆盖**（`upsert_document`） | 写放大与「无法表达块级差异」 | 大文档保存成本随块数线性增长；同步层只能整文档比对（除非将来加块 id） | P1-31 / P6 |
| `searchable_text()` 每次调用都重建 `Vec<String>` 并 `join` | O(总文本长度) 分配 | 若将来在每次保存时同步 FTS（P1-15），需要评估是否缓存 | P1-12/P1-15 实现时一并基准 |
| 深嵌套的递归（`collect_text` / `count_blocks` / `collect_attachment_ids`） | 递归深度 = 嵌套深度 | serde_json 自身有递归深度保护，超深嵌套会在**反序列化**阶段失败；但模型**没有**自己的深度上限（P1-4 待办），程序内构造的深嵌套文档仍会深层递归 | P1-4（加显式深度与块数上限，并写测试） |

预算参照（P3 内存预算：空闲 50–100 MB、编辑态 100–200 MB、移动端 < 100 MB）在本文档**不**给出量化结论——没有基准就不写数字（P2 / T10）。

---

## 9. 未实现部分（诚实清单）

| # | 未实现项 | 现状（可核对） | 计划阶段 | 依据 |
|---|---|---|---|---|
| 1 | **Markdown / HTML / 纯文本渲染器**（投影） | `nested-export` 只有 `ExportFormat`（含 `Markdown`/`Html`/`Text`/`Json`/`Pdf`）与 `extension()`；`nested-import` 只有 `ImportFormat` 与 DTO | P1-20 / P1-21 / P1-22 / P1-24 | `nested-export/src/lib.rs:14-41`、`nested-import/src/lib.rs:19-44` |
| 2 | **Markdown / HTML / TXT / ENEX 解析器**（→ 块模型） | 同上，无任何解析实现 | P1-20 ~ P1-23 | 同上；S5（外部输入必须清洗） |
| 3 | **块级懒加载接口** | 无「取块元数据 / 按需取块内容」的 API；`get_document` 一次性返回全部块 | P1-31 | 开发计划 §2.1.6 |
| 4 | **局部更新** | `upsert_document` 整文档覆盖；块**没有稳定 id**，无法寻址单个块 | P1-31 起；跨端增量需 P6 | `notes.rs:172-187` |
| 5 | **FTS5 索引与增量更新** | 无 FTS 表、无触发器、无 `reindex` 命令；`searchable_text()` 无消费者 | P1-12 / P1-15 | `0001_init.sql` 无 FTS；`nested-search/src/lib.rs:1-15` |
| 6 | **中文分词策略** | 只有候选方案与「必须有对比基准 + ADR」的约束，未选定 | P1-13（须 ADR） | `nested-search/src/lib.rs:5-15`；M2 |
| 7 | **表格仅支持文本单元格** | `TableCell { text, header }` —— 无 `colspan`/`rowspan`、无对齐、**无行内标记**（不是 `Vec<InlineMark>` 而是单个 `String`） | P3-10（块类型 UI） | `block.rs:82-89` |
| 8 | **行内标记的表达力受限** | `marks` 只在 `Paragraph` / `Heading` 上；列表项/待办/引用/代码/表格单元无法承载加粗与链接 | P3-9 / P3-10 | `block.rs:117-135`；§4.3 |
| 9 | **附件正文不入索引（OCR 负责）** | `Image` / `File` 的 `searchable_text()` 返回空串；注释明确「附件正文不入索引，那是 OCR 的职责，P7」 | P7（OCR） | `block.rs:325-328`、`block.rs:354-356`；开发计划 §8 |
| 10 | **嵌入（`Embed`）只有数据形状** | 变体与序列化存在（P7 能力预留），无解析、无渲染、`searchable_text()` 返回空串 | P7 | `block.rs:44`、`block.rs:223-229` |
| 11 | **块级嵌套深度 / 单文档块数上限校验** | `entity.rs` 只实现了文本长度校验（标题 512 等）；`Block` 无任何规模校验 | P1-4 | `entity.rs:325-345`；开发计划 P1-4 原文含「块嵌套深度、单文档块数上限」 |
| 12 | **反序列化的语义校验** | 反序列化绕过构造器：`level = 99` 能被读入；标记偏移无任何范围检查 | P1-4（并入上面的校验任务） | §11 H7 |
| 13 | **文档格式迁移函数** | 只有版本常量与「过高即报错」，不存在 `migrate` 入口（当前只有 v1，尚无迁移对象） | 引入 v2 时随该次变更（A10/B10） | `document.rs:100-105`；§5.5 |
| 14 | **内容压缩** | 未实现，且仓库无压缩依赖 | 无既定阶段，见 §8.2 触发条件 | §8.1 |
| 15 | **CRDT / 协作** | 未实现；且必须先 ADR，仅在有实时协作需求时启动 | P7（须 ADR） | 铁律 T6/A9；开发计划 §8 |
| 16 | **版本历史可恢复内容** | `Revision` 只有 `id/note_id/version/parent_revision_id/created_at_ms/device_id/operation`，**不携带文档负载**；`revisions` 表也没有 payload 列，因此无法从修订恢复历史正文 | P7（版本历史；存储与 GC 策略需先定） | `entity.rs:279-318`、`0001_init.sql:100-111`；开发计划 §8 |
| 17 | **Flutter 侧读写文档** | FFI 只导出 branding/版本/引擎自检，文档 API 尚未过界 | P2-5 / P2-6 | `client/apps/rust/src/api/mod.rs:17` |

---

## 10. 测试覆盖情况

### 10.1 `nested-model`（`#[cfg(test)]` 模块）

**`block.rs:372-441`（7 条）**

| 测试 | 验证的不变量 |
|---|---|
| `heading_serializes_in_documented_shape` | 标题块 JSON 为 `type="heading"`、`level=1`、`text="项目计划"`（与技术文档 §6 示例同形） |
| `heading_level_out_of_range_is_rejected` | `Block::heading(0, _)` 与 `Block::heading(7, _)` 都必须失败（范围 1–6） |
| `unknown_block_type_is_rejected` | 未知 `type` 值必须反序列化失败（前向兼容的边界） |
| `checklist_roundtrips` | 待办块的**精确 JSON 字符串** + 往返相等 |
| `searchable_text_collects_visible_text_only` | 段落取文本；`Divider` 与 `Image` 取空串；`Image::attachment_id()` 有值 |
| `list_start_default_is_omitted_from_json` | `start == 1` 时 JSON 不得出现 `start` 键 |
| `lists_and_chinese_text_block_kinds` | `kind()` 判别值正确（含中文文本与代码块） |

**`document.rs:211-331`（8 条）**

| 测试 | 验证的不变量 |
|---|---|
| `document_roundtrips_through_bytes` | `to_bytes` → `from_bytes` 后整文档相等（含元数据） |
| `new_document_uses_current_version` | 新文档 `version == DOCUMENT_FORMAT_VERSION`、`format == "nested.blocks"` |
| `future_version_is_rejected_not_silently_parsed` | 版本高于支持值 → `ModelError::UnsupportedDocumentVersion`（**禁止**尽力解析） |
| `garbage_bytes_are_rejected` | 非 JSON 字节必须失败 |
| `searchable_text_includes_nested_and_table_content` | 表格单元格与普通段落文本都进入搜索结果 |
| `block_count_includes_children_and_list_items` | `List + ListItem + 子块` = 3（列表项计入） |
| `attachment_ids_are_collected_and_deduplicated` | 同一 `Id` 在 `Image` 与 `File` 中重复出现时只返回一次 |
| `touch_updates_only_updated_at` | `touch` 只改 `updated_at_ms`，不动 `created_at_ms` |

**`entity.rs:347-432`（9 条，与本文档相关者为下列）**

| 测试 | 验证的不变量 |
|---|---|
| `note_title_length_counts_characters_not_bytes` | 200 个汉字（600 字节）必须通过；`MAX_TITLE_CHARS + 1 = 513` 字符必须被拒（阈值 512 的真实依据） |
| `note_creation_sets_defaults` | 新建笔记 `version == 1`、未删除、未置顶、`notebook_id == None` |
| `note_touch_increments_version_monotonically` | 连续 `touch` 使 `version` 单调递增（1 → 3） |
| `soft_delete_then_restore_clears_flag` | 软删后 `is_deleted()`，恢复后清除（T7） |
| `attachment_rejects_malformed_hash` | 非 64 位、含大写十六进制的 SHA-256 必须拒绝 |
| `storage_key_uses_two_level_sharding` | CAS 路径为 `<前2位>/<次2位>/<完整哈希>`（T8） |

**`id.rs:76-98`（3 条）**：`generated_ids_are_unique`、`roundtrip_through_string_and_bytes`（字符串与 16 字节 BLOB 双向往返）、`invalid_text_is_rejected`。

**`time.rs:55-77`（3 条）**：`now_is_after_2020_and_before_2100`、`timestamp_converts_to_utc`、`ordering_follows_millis`。

### 10.2 `nested-db` 中与文档持久化直接相关的测试（`notes.rs:333-565`）

| 测试 | 验证的不变量 |
|---|---|
| `create_with_document_writes_all_tables_atomically` | 创建后 `notes` 可读回、`get_document` 与写入的文档相等、`revisions` 恰好 1 条（T6） |
| `create_is_rolled_back_when_document_is_invalid` | 创建失败后 `documents` 只有 1 行——**失败事务不得留下半截数据**（T1/D1）。⚠️ 见 §11 H4：该测试的实际触发条件是主键冲突，而非文档非法 |
| `save_increments_version_and_appends_revision` | 保存后 `version == 2`、标题更新、文档块数从 1 变 2、`revisions` 变 2 条 |
| `save_enqueues_sync_operation` | 本地写入必须同时入同步队列（T3）：`sync_operations` 中 `pushed_at_ms IS NULL` 的行数 = 1 |
| `save_missing_note_is_not_found` | 笔记不存在 → `DbError::NotFound { entity: "note" }` |
| `document_for_missing_note_is_empty_not_error` | 无文档行 → 返回空文档而非错误 |
| `corrupted_document_bytes_are_reported` | 手工把 `content` 改成非法字节后，读取必须报 `DbError::Corrupt { entity: "document" }` |

### 10.3 附带的间接覆盖

| 测试 | 与文档模型的关系 |
|---|---|
| `attachments.rs::document_attachments_are_linked_through_note_write` | 嵌套在 `List → ListItem.children → Image` 里的附件被 `attachment_ids()` 递归发现并建立引用 |
| `nested-core/src/api.rs::note_lifecycle_end_to_end` | `create_note_with_document` → `get_note_document` → `save_note`（版本 1→2）→ 软删 → 恢复 的端到端链路 |
| `nested-core/src/api.rs::save_increments_version_and_leaves_pending_sync` | 保存后待同步数为 1 |
| `nested-core/src/lib.rs` 文档测试（`lib.rs:21-34`） | 用法示例必须可编译可运行（`create_note` → `get_note_document` → `save_note`） |

### 10.4 覆盖缺口（诚实记录，对应 Z2 / Z3）

| 缺口 | 说明 |
|---|---|
| 无 Emoji / 字素簇样本 | Z3 要求「含中文、Emoji、嵌套列表、表格、图片、超长行」的真实样本往返；当前只有中文与简单嵌套 |
| 无 `marks` 的往返与边界测试 | `InlineMark` 没有任何测试（无越界、无嵌套、无链接标记） |
| 无超长 / 超深文档测试 | 无「上万块」「深嵌套」的失败路径测试（P1-31 的前置） |
| 无格式迁移测试 | 目前只有无法迁移的 v1；引入 v2 时必须补「旧库升级 + 文档迁移」测试（Q10 精神） |
| 无 `format` 字段校验的测试 | 因为实现里也没有校验（§11 H2） |
| 无并发写 / 分叉测试 | D10（禁止静默覆盖）在文档层没有任何测试；`upsert_document` 后写者完全覆盖 |
| 无 JSON 精确形状快照测试（除 checklist） | 其余 12 个变体只有字段级或往返断言，格式回归的护栏偏薄（§11 H15） |

---

## 11. 已知隐患与实现/文档不一致（诚实清单）

> 每条都给出可核对的证据位置，便于开 issue 与补测试（Z10：修复必须回归测试化）。严重度仅为本文档的判断，最终以 ADR/任务卡为准。

| ID | 现象 | 证据 | 影响 | 建议 |
|---|---|---|---|---|
| **H1** | `documents.format` 与 `documents.format_version` 只写不读 | 写：`notes.rs:173-186`；读：`notes.rs:197-203` 只 `SELECT content` | 冗余列与 JSON 内容可能漂移且无人发现；也白白浪费了「不解 JSON 即可判版本」的机会 | 明确两者关系：读取时用列做快速前置检查（版本过高直接拒绝，不必解析），或在 migration 中移除列（D6 走新 migration） |
| **H2** | `from_bytes` 不校验 `metadata.format`，且版本判断只有上界 | `document.rs:100-105` | 声称为 `"html"` 的文档会被当作块文档读取；`version = 0` 也被接受 | 补 `format == FORMAT` 与「下界」检查，并加测试（S6 / A10） |
| **H3** | `get_document` 把所有解析错误折叠为 `DbError::Corrupt`，包括 `UnsupportedDocumentVersion` | `notes.rs:206`；对照存储层同类情形的正确处理：`DbError::SchemaTooNew`「数据库结构版本 {found} 高于本程序支持的 {supported}，请升级应用后再打开」（`nested-db/src/error.rs:33-40`） | 用户看到「数据损坏」而正确结论是「请升级应用」——丢掉了 `error.rs:18-23` 精心区分的可操作信息（E2/E3/B9） | `get_document` 区分两类错误（可参照 `SchemaTooNew` 的先例），向上映射为「需要更高版本」的结构化错误 |
| **H4** | 写入路径不校验文档版本，可写入随后永远读不出的「毒文档」；相关测试名与断言不符 | `upsert_document`（`notes.rs:164-189`）无校验；测试 `create_is_rolled_back_when_document_is_invalid`（`notes.rs:378-400`）的注释自陈「写入本身能成功…因此这里改用约束冲突验证回滚」 | 一次 bug 或降级写入即可让某篇笔记永久 `Corrupt`（T1 风险）；测试名误导读者以为「非法文档会被拒」 | 写入前断言 `document.metadata.version <= DOCUMENT_FORMAT_VERSION`；把回滚测试改名并补一条真正的「拒绝非法文档」测试 |
| **H5** | `Document::searchable_text()` 对列表项文本**重复收集两次** | `Block::List::searchable_text()` 已把 `items[].text` 拼接（`block.rs:333-340`），`collect_text` 又逐项 `out.push(item.text)`（`document.rs:148-157`） | FTS5 索引内容重复（如 `"第一项 第二项 第一项 第二项"`），影响相关度与体积；当前无消费者所以未暴露 | 修正 `collect_text`（列表分支只递归 `children`），并补一条断言精确文本的测试 |
| **H6** | `nested-core::save_note` 不调用 `Document::touch()` | `api.rs:217-230`：`note.touch(at_ms)` 后直接传原 `document` | `documents.updated_at_ms` / `metadata.updated_at_ms` 停留在旧值，与 `notes.updated_at_ms` 长期不一致；将来做「按文档时间增量同步」会漏数据 | 在 `save_note`（或 `save_with_document`）统一时间语义；测试里显式断言两者一致 |
| **H7** | 反序列化绕过构造器校验：`level = 99` 可被读入；标记偏移无任何约束 | 校验只在 `Block::heading`（`block.rs:273-285`）；`Block` 的 `Deserialize` 无校验 | 损坏或恶意 JSON 进入内存后，渲染器切片可能 panic（R1），渲染结果不可信（S6） | 增加 `Document::validate()`（块级不变量：heading level、marks 边界与排序、嵌套深度、块数上限）并在 `from_bytes` 后调用；配套测试 |
| **H8** | 技术文档 §6 的示例 JSON（根级 `"version"`）与实现（嵌套 `metadata`）不一致 | 技术文档 §6 `{"version":1,"blocks":[...]}` 对 `document.rs:49-56` | 读者按文档写出的 JSON 无法被 `from_bytes` 接受 | 按 M3 更新技术文档，或在本设计文档中明确「实现为准」 |
| **H9** | 文档缺失时返回的空文档使用**读取瞬间**的系统时钟 | `notes.rs:208` 调用 `now_ms()` | 读路径依赖系统时钟（R10：时间应可注入）；同一缺失文档两次读取得到不同的元数据，破坏可重现性 | 让 `get_document` 接受时间参数，或返回 `Option<Document>`/由 Core 决定时间语义 |
| **H10** | 块没有稳定 id，无法寻址单个块 | `Block` 13 个变体均无 id 字段（`block.rs:115-230`） | 「局部更新」「块级懒加载」「块级同步合并」「评论/引用块」都无法实现；D10（禁止静默覆盖）在文档层只能整份覆盖 | P1-31 之前先决定块 id 方案（是否引入、如何与 CRDT 兼容），需 ADR |
| **H11** | `revision` 不含文档负载，版本历史无法恢复正文 | `Revision`（`entity.rs:279-295`）与 `revisions` 表（`0001_init.sql:100-111`）都只有元数据 | P7「版本历史：查看/恢复/比较」缺少数据基础 | P7 设计时定：快照（体积）还是操作日志（复杂度），以及 GC 策略 |
| **H12** | 无嵌套深度 / 块数上限 | `entity.rs:325-345` 只有文本长度校验 | 极端文档可造成深层递归与内存压力（T9/P3） | 并入 P1-4，写入与读入两侧都校验 |
| **H13** | `InlineMarkKind` 是 `pub` 但未从 `lib.rs` 重导出 | `block.rs:65` 为 `pub enum`；`lib.rs:22` 只导出 `InlineMark` | 外部 crate 无法直接命名该类型（只能通过字段访问），写 `match` 分支或 FFI 映射时会别扭 | 在 `lib.rs` 补 `InlineMarkKind`（注意 A10：属对外接口面变化，需评估） |
| **H14** | 列表项有两套等价表示：`ListItem` 结构体与 `Block::ListItem` 变体 | `block.rs:152-159` 与 `block.rs:233-241` | 三个递归遍历函数都要写两遍分支；新增列表能力时易漏改一处 | 明确二者分工并在文档中固定；或评估收敛为一种（属格式变更，需 A10 评估与可能的版本升级） |
| **H15** | 除 `checklist` 外没有精确 JSON 快照测试 | `block.rs:398-407` 是唯一逐字断言；其余为字段级/往返断言 | 无意的字段顺序或属性变化不会被测试拦住（A10 的回归护栏偏薄） | 为 13 个变体各加一条精确字符串断言（`insta` 或直接 `assert_eq!`） |
| **H16** | `BlockKind` 注释称「不参与序列化」，但派生了 `Serialize/Deserialize` | 注释 `block.rs:16` 对 `#[derive(..., Serialize, Deserialize)]`（`block.rs:17`） | 表述歧义（它确实不进 `documents.content`），易让读者以为类型不可序列化 | 注释改为「不参与文档 JSON 的序列化」 |

---

## 12. 变更日志

| 版本 | 日期 | 变更 |
|---|---|---|
| 首版 | 建立 `docs/design/06` 时 | 基于 `nested-model` / `nested-db` 当前实现（`DOCUMENT_FORMAT_VERSION = 1`）与 `0001_init.sql` 编写；登记 §11 的 16 条隐患与不一致 |

---

## 参考

以下文件在编写本文档时被实际阅读（行号引用均指向这些文件）：

| 文件 | 用途 |
|---|---|
| `client/crates/nested-model/src/block.rs` | 块模型：`Block` 13 变体、`InlineMark`/`InlineMarkKind`、`TableCell`/`TableRow`、`ListItem`、`BlockKind`、派生方法与全部测试 |
| `client/crates/nested-model/src/document.rs` | `Document`、`DocumentMetadata`、`DOCUMENT_FORMAT_VERSION`、往返序列化、版本检查、三项派生能力与测试 |
| `client/crates/nested-model/src/entity.rs` | 领域实体与字段校验常量（`MAX_TITLE_CHARS = 512` 等）、`validate_text` |
| `client/crates/nested-model/src/id.rs` | `Id`（UUIDv7）与序列化形状 |
| `client/crates/nested-model/src/time.rs` | `Timestamp`（UTC 毫秒）、`now_ms()` |
| `client/crates/nested-model/src/error.rs` | `ModelError`（含 `UnsupportedDocumentVersion`、`Validation`） |
| `client/crates/nested-model/src/lib.rs` | 对外导出面与 crate 级约束 |
| `client/crates/nested-model/Cargo.toml` | 依赖面（无渲染/压缩依赖） |
| `client/crates/nested-db/src/repositories/notes.rs` | 文档持久化：`insert`、`create_with_document`、`upsert_document`、`get_document`、`save_with_document` 与事务测试 |
| `client/crates/nested-db/src/repositories/attachments.rs` | `sync_note_links`、`refresh_ref_count`、`list_unreferenced`（§7.3 的落地路径） |
| `client/crates/nested-db/src/error.rs` | `DbError::Corrupt` / `NotFound` 等映射目标 |
| `client/crates/nested-db/src/migrations.rs` | 迁移执行与 `LATEST_VERSION`（D6 的落实方式） |
| `client/migrations/0001_init.sql` | `documents` 表与相关表的实际列定义 |
| `client/crates/nested-core/src/api.rs` | 内核业务入口（`create_note_with_document` / `get_note_document` / `save_note`） |
| `client/crates/nested-core/src/lib.rs` | 分层说明与再导出面 |
| `client/crates/nested-search/src/lib.rs` | FTS5 现状（未实现）与中文分词待决事项 |
| `client/crates/nested-import/src/lib.rs`、`client/crates/nested-export/src/lib.rs` | 导入/导出（渲染器）未实现的证据 |
| `client/apps/rust/src/api/mod.rs`、`client/apps/rust/src/api/branding.rs` | FFI 导出面现状（尚无文档 API） |
| `docs/02-工程铁律.md` | T5 / T1 / D1 / D6 / D7 / D8 / A9 / A10 / Q4 / Q11 / R1 / R10 / S6 / U3 / P2 / Z2 / Z3 / M3 等条款原文 |
| `docs/01-开发计划.md` | P1-2 ~ P1-4、P1-10、P1-12 ~ P1-15、P1-20 ~ P1-26、P1-31、P3-9/P3-10、P4-2、P7 各阶段任务与约束 |
| `docs/design/README.md` | 编号规范（`06`）与设计文档规则（M1/M2/M3） |
| `跨平台Evernote类笔记应用_项目实施技术文档.md` | §6 Document Model（Block 类型清单与示例 JSON）、§7 为什么采用 Block Model（八条优点） |
| `docs/tech-debt.md` | 债务登记规范（V8），确认本文档 §11 的条目尚未登记 |
