# 拾光笔记 / NestedNote —— 项目实施技术文档

> **项目名**：**拾光笔记 / NestedNote**（详见 [docs/00-项目章程.md](docs/00-项目章程.md)）  
> **项目定位**：Windows / macOS / iOS / Android 全平台、本地优先（Local-First）、高性能、低内存占用的现代笔记应用。  
> **核心技术路线**：Flutter UI + Rust Core（`nested-*` crates）+ SQLite/FTS5 + Rust Sync Server。  
> **目标**：实现 Evernote 类核心能力，同时在架构、性能、数据可控性和跨平台一致性上采用现代方案。  
>
> **配套文档**：[开发计划](docs/01-开发计划.md) ｜ [工程铁律（最高优先级）](docs/02-工程铁律.md)

---

## 1. 项目目标

### 1.1 产品目标

构建一款具备以下能力的跨平台笔记软件：

- 笔记本 / 笔记 / 标签三级组织体系
- 富文本编辑
- 图片、附件、文件、表格
- 全文搜索
- 收藏 / 归档 / 回收站
- Markdown 导入导出
- HTML / PDF / ENEX 等格式导入
- 本地离线使用
- 多设备同步
- 附件同步
- 数据库备份与恢复
- Windows、macOS、iOS、Android 原生平台体验
- 后期支持 OCR、AI、WebDAV、自托管和协作编辑

### 1.2 非目标

第一阶段不实现：

- 实时多人协同编辑
- 完整 Evernote UI 1:1 克隆
- 自研富文本排版引擎
- 自研同步协议
- 自研数据库
- 复杂企业权限系统

原则：

> **先把单机 Local-First 做扎实，再做同步；先解决数据模型，再解决 UI。**

---

# 2. 总体技术架构

```text
┌─────────────────────────────────────────────────────────────┐
│                    Flutter Application                     │
│                                                             │
│  Windows / macOS / iOS / Android                           │
│                                                             │
│  ┌────────────┐ ┌────────────┐ ┌────────────────────────┐ │
│  │ UI Layer   │ │ Editor     │ │ Platform Adapter        │ │
│  │            │ │            │ │ File / Share / Camera   │ │
│  └─────┬──────┘ └─────┬──────┘ └───────────┬────────────┘ │
│        └───────────────┼────────────────────┘              │
│                        │ FFI                                │
└────────────────────────┼────────────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                       Rust Core                            │
│                                                             │
│  Document Model                                             │
│  Repository                                                 │
│  Search                                                     │
│  Attachment                                                 │
│  Import / Export                                            │
│  Encryption                                                 │
│  Sync Engine                                                │
│  Cache                                                      │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                     SQLite + FTS5                     │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
│  Local File / Blob Store                                    │
└──────────────────────────────┬──────────────────────────────┘
                               │ HTTPS
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                    Rust Sync Server                         │
│                                                             │
│ Axum + Tokio + SQLx                                        │
│                                                             │
│ PostgreSQL                                                  │
│ Object Storage (S3-compatible)                              │
└─────────────────────────────────────────────────────────────┘
```

---

# 3. 技术栈

| 层 | 技术 | 用途 |
|---|---|---|
| UI | Flutter / Dart | 四平台 UI |
| Core | Rust | 核心业务逻辑 |
| FFI | flutter_rust_bridge | Flutter ↔ Rust |
| Database | SQLite | 本地数据库 |
| Search | SQLite FTS5 | 全文搜索 |
| Server | Rust + Axum | 同步 API |
| Async | Tokio | Rust 异步运行时 |
| Server DB | PostgreSQL | 云端元数据 |
| Object Storage | S3-compatible | 图片/附件 |
| Serialization | serde | Rust 数据序列化 |
| DB Access | SQLx | 数据库访问 |
| Crypto | RustCrypto / 平台安全存储 | 加密 |
| Build | Cargo + Flutter | 构建 |
| CI | GitHub Actions | 自动测试和发布 |

---

# 4. Repository 结构

采用 Monorepo，**顶层按交付边界分为 `client/` 与 `server/` 两个互相隔离的工作区**：

```text
nested/
├── client/                       ← 客户端（Flutter UI + Rust Core + CLI）
│   ├── Cargo.toml                客户端独立 workspace（自带 Cargo.lock）
│   ├── rust-toolchain.toml
│   ├── apps/
│   │   └── flutter/              Flutter 应用
│   │       ├── lib/
│   │       │   ├── app/          应用启动、主题、路由
│   │       │   ├── core/         FFI 封装、平台适配、错误映射
│   │       │   ├── features/     业务页面
│   │       │   ├── editor/       编辑器与 Document Model Adapter
│   │       │   ├── search/       搜索页
│   │       │   ├── settings/     设置
│   │       │   └── sync/         同步状态与冲突 UI
│   │       ├── android/
│   │       ├── ios/
│   │       ├── macos/
│   │       └── windows/
│   ├── crates/                   Rust Core
│   │   ├── nested-core/
│   │   ├── nested-model/
│   │   ├── nested-db/
│   │   ├── nested-search/
│   │   ├── nested-attachment/
│   │   ├── nested-import/
│   │   ├── nested-export/
│   │   ├── nested-sync/
│   │   └── nested-crypto/
│   ├── migrations/               本地 SQLite 迁移（客户端独占）
│   └── cli/                      nested-cli：无 UI 的内核验证与运维工具
│
├── server/                       ← 服务端（Rust Sync Server）
│   ├── Cargo.toml                服务端独立 workspace（自带 Cargo.lock）
│   ├── rust-toolchain.toml
│   ├── crates/
│   │   ├── server-api/           HTTP 层（Axum 路由、中间件）
│   │   ├── server-auth/          认证与设备
│   │   ├── server-sync/          同步逻辑
│   │   ├── server-storage/       PostgreSQL / 对象存储
│   │   └── server-core/          服务端配置、错误、可观测性
│   ├── migrations/               服务端 PostgreSQL 迁移
│   └── docker/                   docker-compose（api + postgres + minio）
│
├── shared/                       跨端只共享**契约**，不共享实现
│   └── protocol/                 同步协议 / API DTO（纯数据定义，无 IO）
│
├── docs/
│   ├── adr/
│   ├── design/
│   └── reports/
│
├── scripts/                      构建、基准、数据生成、铁律检查脚本
└── README.md
```

### 4.1 为什么客户端与服务端必须是两个独立 workspace

| 理由 | 说明 |
|---|---|
| 依赖永不互串 | 客户端绝不编译 `axum`/`sqlx`/`tokio-postgres`；服务端绝不编译 `rusqlite`/Flutter 绑定 |
| 构建速度 | 改服务端不会触发客户端全量重编译，反之亦然 |
| 发布节奏独立 | 客户端随商店审核发布，服务端随部署发布；版本号与 lock 文件各自演进 |
| 安全边界 | 服务端不可能"顺手"引用客户端加密实现，避免把密钥逻辑带上云 |
| CI 可分流 | 只改 `client/**` 时只跑客户端流水线（反之亦然） |

**代价**：无法用根 `Cargo.toml` 一次性 `cargo test --workspace` 覆盖两端 → 用 `just` 与 CI 的**两套作业**补齐（见 §4.2）。

### 4.2 隔离硬约束（违反即视为架构缺陷）

1. `client/**` **禁止**依赖 `server/**` 或 `shared/protocol`以外的服务端实现；`server/**` 同理。
2. 两端**唯一**允许共享的是 `shared/protocol` 中的**纯数据契约**（serde DTO、常量、版本号），且该 crate **禁止**引入任何 IO / 数据库 / 网络依赖。
3. 客户端**禁止**依赖任何服务端 crate；服务端**禁止**依赖任何客户端 crate。此约束由 `scripts/check-rules.ps1` 自动检查。
4. 数据库迁移目录本身就分两处：`client/migrations/`（SQLite）与 `server/migrations/`（PostgreSQL），**禁止**混放。

---

# 5. Rust Core 设计

Rust Core 是整个项目的核心。

Flutter 不直接操作 SQLite，也不直接实现复杂的数据逻辑。

推荐：

```text
Flutter
   ↓
Rust API
   ↓
Domain Service
   ↓
Repository
   ↓
SQLite
```

### Rust Core 负责

- 笔记 CRUD
- 文档解析
- Document Model
- 标签
- 笔记本
- 搜索
- 附件
- 缓存
- 导入导出
- 数据迁移
- 同步
- 加密
- 数据校验

### Flutter 负责

- UI
- 用户输入
- 页面导航
- 动画
- 手势
- 平台交互
- UI 状态

原则：

> Flutter 不应该成为业务数据的最终事实来源。

---

# 6. Document Model

不要把 HTML 直接作为核心数据格式。

推荐使用自己的结构化文档模型。

```text
Document
 ├── metadata
 └── blocks[]
```

Block 类型：

```text
Paragraph
Heading
List
ListItem
Checklist
Quote
Code
Image
File
Table
Divider
Link
Embed
```

示例：

```json
{
  "version": 1,
  "blocks": [
    {
      "type": "heading",
      "level": 1,
      "text": "项目计划"
    },
    {
      "type": "paragraph",
      "text": "这是第一段内容。"
    },
    {
      "type": "checklist",
      "checked": false,
      "text": "完成数据库设计"
    }
  ]
}
```

---

# 7. 为什么采用 Block Model

相比直接保存 HTML：

### 优点

- 易于跨平台
- 易于版本迁移
- 易于同步
- 易于 Markdown 导出
- 易于 AI 处理
- 易于搜索
- 易于实现局部更新
- 易于未来转换成 CRDT

HTML 可以作为：

```text
Document Model
      ↓
HTML Renderer
```

而不是：

```text
HTML = Database Format
```

---

# 8. SQLite 数据库设计

核心表：

```text
notebooks
notes
tags
note_tags
attachments
note_attachments
documents
revisions
sync_operations
settings
```

---

## 8.1 notebooks

```sql
CREATE TABLE notebooks (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    parent_id TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
);
```

---

## 8.2 notes

```sql
CREATE TABLE notes (
    id TEXT PRIMARY KEY,
    notebook_id TEXT,
    title TEXT NOT NULL,
    summary TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    accessed_at INTEGER,
    is_pinned INTEGER DEFAULT 0,
    is_archived INTEGER DEFAULT 0,
    is_deleted INTEGER DEFAULT 0,
    version INTEGER NOT NULL DEFAULT 1
);
```

---

## 8.3 documents

```sql
CREATE TABLE documents (
    note_id TEXT PRIMARY KEY,
    format TEXT NOT NULL,
    content BLOB NOT NULL,
    version INTEGER NOT NULL
);
```

建议：

- 普通笔记直接保存压缩后的结构化数据
- 超大文档可以拆分
- 图片和附件不进入数据库 BLOB

---

# 9. 附件系统

附件采用：

> Content Addressable Storage

文件名不作为唯一标识。

计算：

```text
SHA-256(file)
```

得到：

```text
8f14e45fceea167a5a36dedd4bea2543...
```

存储：

```text
attachments/
└── 8f/
    └── 14/
        └── 8f14e45fceea167a5a36dedd4bea2543...
```

数据库：

```text
attachments
 ├── id
 ├── sha256
 ├── mime_type
 ├── size
 ├── filename
 └── created_at
```

优点：

- 自动去重
- 适合同步
- 适合缓存
- 防止重复保存相同文件
- 云端对象存储天然兼容

---

# 10. 全文搜索

使用：

```text
SQLite FTS5
```

搜索索引：

```text
note_id
title
content
tags
```

逻辑：

```text
用户输入
   ↓
FTS5
   ↓
note_id
   ↓
notes
   ↓
UI
```

搜索不能扫描所有 notes。

目标：

```text
100,000 notes
普通搜索 < 300ms
```

---

# 11. 编辑器架构

不要第一阶段自研编辑器。

采用成熟 Flutter 编辑器基础设施，然后增加自己的 Document Model Adapter。

结构：

```text
Document Model
      ↓
Editor Adapter
      ↓
Flutter Editor
      ↓
User Input
      ↓
Document Delta
      ↓
Rust Core
```

编辑器必须支持：

- 输入法
- 中文
- Emoji
- 复制粘贴
- 图片
- 撤销/重做
- 快捷键
- Markdown 快捷输入
- 手机触摸
- 桌面鼠标
- 键盘导航

---

# 12. 大文档性能

不要一次性加载整个文档的全部资源。

采用：

```text
Document
   ↓
Block metadata
   ↓
Viewport
   ↓
Visible blocks
   ↓
Load content
```

图片：

```text
Thumbnail
    ↓
Visible
    ↓
Original
```

原则：

> 看不到的内容，不应该占用大量内存。

---

# 13. 内存优化

核心策略：

### 13.1 Lazy Loading

笔记列表：

```text
只加载当前屏幕附近的数据
```

附件：

```text
只加载缩略图
```

编辑器：

```text
只加载当前文档
```

---

### 13.2 避免 Flutter 保存大型对象

不要：

```text
10MB image
 ↓
Dart Uint8List
 ↓
多个 Widget
```

而应该：

```text
File
 ↓
Thumbnail
 ↓
Image Provider
```

---

### 13.3 Rust 管理大型数据

适合放在 Rust：

- 搜索索引
- 数据压缩
- 文件 Hash
- 数据库查询
- 导入
- 导出
- 大型文本处理

---

# 14. Local-First 数据原则

所有核心操作必须：

```text
先写本地
↓
立即更新 UI
↓
后台同步
```

而不是：

```text
UI
 ↓
服务器
 ↓
服务器成功
 ↓
本地更新
```

这样即使：

- 没有网络
- Wi-Fi 中断
- 服务器宕机
- 手机进入飞行模式

依然可以正常使用。

---

# 15. Revision 系统

每一次修改产生 revision：

```text
note_id
revision_id
parent_revision
timestamp
device_id
operation
```

例如：

```text
R100
 ↓
R101
 ↓
R102
```

同步：

```text
Device A
R100 → R101 → R102

Device B
R100 → R103
```

发现：

```text
R102
R103
```

产生冲突。

---

# 16. 第一阶段同步方案

第一版不直接上 CRDT。

采用：

```text
Revision + Operation Log
```

流程：

```text
Local Change
    ↓
SQLite
    ↓
sync_operations
    ↓
Background Sync
    ↓
Server
```

服务器保存：

```text
note_id
device_id
revision
operation
timestamp
```

---

# 17. 第二阶段：CRDT

如果以后支持：

- 多人同时编辑
- 实时协作
- 多设备同时修改同一笔记

再引入：

```text
CRDT
```

可以考虑：

```text
Yrs / Yjs-compatible architecture
```

但不要让 CRDT 从第一天就增加系统复杂度。

---

# 18. 同步服务器

技术栈：

```text
Rust
├── Axum
├── Tokio
├── SQLx
└── Serde
```

数据库：

```text
PostgreSQL
```

文件：

```text
S3-compatible Object Storage
```

结构：

```text
Client
   │
 HTTPS
   │
   ▼
Axum API
   │
 ┌─┴───────────────┐
 ▼                 ▼
PostgreSQL       Object Storage
```

---

# 19. API 设计

基础 API：

```text
POST   /api/v1/auth/login
POST   /api/v1/auth/refresh

GET    /api/v1/notebooks
POST   /api/v1/notebooks

GET    /api/v1/notes
POST   /api/v1/notes
GET    /api/v1/notes/:id
PUT    /api/v1/notes/:id
DELETE /api/v1/notes/:id

POST   /api/v1/sync/push
GET    /api/v1/sync/pull

POST   /api/v1/attachments/upload
GET    /api/v1/attachments/:id
```

API 必须版本化：

```text
/api/v1/
```

---

# 20. 删除机制

不要直接：

```sql
DELETE FROM notes;
```

使用：

```text
soft delete
```

例如：

```text
is_deleted = 1
deleted_at = timestamp
```

同步完成后再进行垃圾回收。

---

# 21. 回收站

回收站本质：

```text
is_deleted = 1
```

恢复：

```text
is_deleted = 0
```

超过保留时间：

```text
Garbage Collection
```

永久删除。

---

# 22. 数据安全

建议：

```text
TLS
+
本地数据库加密
+
附件加密
+
平台 Keychain / KeyStore
```

密钥不要：

```text
明文保存 SQLite
```

而应使用：

- Windows Credential Manager
- macOS Keychain
- iOS Keychain
- Android Keystore

---

# 23. 数据导入导出

第一阶段：

```text
Markdown
HTML
TXT
ENEX
```

第二阶段：

```text
PDF
DOCX
图片 OCR
```

导出：

```text
Markdown
HTML
PDF
JSON
```

必须提供：

```text
完整数据备份
```

格式：

```text
backup/
├── manifest.json
├── notes/
├── attachments/
└── metadata/
```

---

# 24. 平台 UI

## Windows / macOS

采用三栏结构：

```text
┌──────────┬────────────────┬─────────────────────┐
│ Sidebar  │ Note List      │ Editor              │
│          │                │                     │
│ Inbox    │ Note A         │ Title               │
│ Notes    │ Note B         │                     │
│ Tags     │ Note C         │ Content             │
│ Notebook │                │                     │
└──────────┴────────────────┴─────────────────────┘
```

支持：

- Ctrl/Cmd + P
- Ctrl/Cmd + K
- Ctrl/Cmd + F
- Ctrl/Cmd + N
- Ctrl/Cmd + S
- 快捷键导航

---

# 25. Android / iOS

移动端不要机械复制桌面三栏。

采用：

```text
Navigation
    ↓
Note List
    ↓
Editor
```

底部导航：

```text
Notes
Search
Favorites
Settings
```

编辑器：

```text
Title
Content
Toolbar
Attachments
```

重点处理：

- 中文输入法
- 键盘弹出
- 光标定位
- 图片插入
- 长按
- 手势
- 分享
- 相机
- 文件选择

---

# 26. Flutter 与 Rust 通信

推荐使用：

```text
flutter_rust_bridge
```

原则：

### Rust API 尽量业务化

不要暴露：

```text
sqlite_execute_sql()
```

而暴露：

```text
create_note()
update_note()
search_notes()
get_note()
list_notebooks()
```

这样 Flutter 不依赖具体数据库实现。

---

# 27. 状态管理

Flutter 层建议使用：

```text
Riverpod
```

状态分层：

```text
UI State
   ↓
Feature State
   ↓
Rust Repository
```

不要让全局状态无限增长。

---

# 28. 缓存策略

三级缓存：

```text
L1：当前 UI 数据
L2：Rust 内存缓存
L3：SQLite
```

附件：

```text
Memory
 ↓
Disk Cache
 ↓
Object Storage
```

缓存必须存在上限。

---

# 29. 性能指标

第一阶段目标：

| 指标 | 目标 |
|---|---:|
| 冷启动 | < 1.5s |
| 普通启动 | < 1s |
| 空闲内存 Windows | 50–100MB |
| 普通编辑 | 100–200MB |
| 普通移动端 | < 100MB |
| 10万笔记搜索 | < 300ms |
| 本地打开笔记 | < 100ms |
| 数据库查询 | < 20ms |
| 图片缩略图 | < 100ms |
| UI 目标帧率 | 60 FPS |

这些是工程目标，不应在早期为了数字牺牲稳定性。

---

# 30. 大数据压力测试

必须建立测试数据生成器。

生成：

```text
1,000 notes
10,000 notes
100,000 notes
1,000,000 notes
```

附件：

```text
100MB
1GB
10GB
```

测试：

- 搜索
- 启动
- 笔记列表
- 标签
- 导入
- 删除
- 同步
- 数据库 VACUUM
- 缓存
- 内存峰值

---

# 31. 数据库迁移

所有数据库结构修改必须：

```text
Migration 001
Migration 002
Migration 003
...
```

禁止：

```text
直接修改 production schema
```

启动：

```text
检查 DB version
 ↓
执行 migration
 ↓
验证 schema
 ↓
启动应用
```

---

# 32. 日志系统

分级：

```text
ERROR
WARN
INFO
DEBUG
TRACE
```

Release 默认：

```text
INFO
```

敏感数据禁止进入日志：

```text
密码
Token
完整笔记正文
附件内容
加密密钥
```

---

# 33. 错误处理

Rust：

```text
thiserror
```

Application boundary：

```text
anyhow
```

对 Flutter 暴露结构化错误：

```text
DatabaseError
NetworkError
ValidationError
SyncConflict
PermissionError
AttachmentError
ImportError
```

不要向 UI 直接抛出 Rust stack trace。

---

# 34. 自动保存

编辑器采用：

```text
User Input
 ↓
Debounce 300–1000ms
 ↓
Rust Core
 ↓
SQLite Transaction
```

关键操作立即保存：

- 切换笔记
- 关闭编辑器
- 应用进入后台
- 应用退出

---

# 35. Undo / Redo

第一阶段：

```text
Editor-level Undo/Redo
```

第二阶段：

```text
Document Revision History
```

最终可以实现：

```text
查看历史版本
恢复历史版本
比较两个版本
```

---

# 36. AI 能力预留

Document Model 从第一天就要适合 AI。

AI API 不直接操作 UI。

结构：

```text
Document
 ↓
Text Extraction
 ↓
AI Service
 ↓
Structured Result
 ↓
Document Update
```

未来可以支持：

- 摘要
- 改写
- 翻译
- 标签推荐
- 自动分类
- OCR
- 语义搜索
- 问答
- 笔记关联

---

# 37. 语义搜索

第一阶段：

```text
FTS5
```

第二阶段：

```text
Embedding
```

架构：

```text
Keyword Search
       +
Vector Search
       ↓
Hybrid Search
```

不要第一版直接引入向量数据库。

---

# 38. OCR

图片：

```text
Image
 ↓
OCR
 ↓
Extracted Text
 ↓
FTS5
```

OCR 文本不必覆盖原始图片。

数据库增加：

```text
attachment_ocr
```

这样用户可以：

> 搜索图片中的文字。

---

# 39. WebDAV / 自托管

后期可以增加：

```text
WebDAV
```

或者：

```text
Self-hosted Server
```

自托管服务器：

```text
Docker
 ↓
Rust Server
 ↓
PostgreSQL
 ↓
S3 / Local Storage
```

---

# 40. 开发阶段

> **阶段编号对照**：本节使用 Phase 0–5 的粗粒度划分；[《开发计划》](docs/01-开发计划.md) 采用更细的 P0–P7，并附带任务卡、DoD 与 Gate 晋级标准。
>
> | 本节 | 开发计划 | 说明 |
> |---|---|---|
> | Phase 0 | **P0** | 技术验证 → 工程基座 |
> | Phase 1 | **P1** | Local Core |
> | Phase 2 | **P2 + P3 + P4** | 桌面 MVP → 桌面完整版 → 压测优化 |
> | Phase 3 | **P5** | Mobile |
> | Phase 4 | **P6** | Sync |
> | Phase 5 | **P7** | 高级功能 |
>
> **执行以《开发计划》为准**（含 Gate 与验收标准）。

## Phase 0：技术验证

目标：

```text
Flutter ↔ Rust
Rust ↔ SQLite
```

完成：

- Flutter 页面
- Rust FFI
- SQLite
- 创建笔记
- 查询笔记
- 修改笔记

---

## Phase 1：Local Core

实现：

- Notebook
- Note
- Tag
- Document Model
- SQLite
- FTS5
- Attachment
- Import / Export

此阶段不做云同步。

---

## Phase 2：Desktop

实现：

- Windows
- macOS
- 三栏 UI
- 编辑器
- 搜索
- 快捷键
- 拖拽
- 文件附件

---

## Phase 3：Mobile

实现：

- Android
- iOS
- 移动编辑器
- 图片
- 相机
- 文件
- 分享
- 后台任务

---

## Phase 4：Sync

实现：

- Account
- Device ID
- Revision
- Operation Log
- Push
- Pull
- Attachment Sync
- Conflict Handling

---

## Phase 5：高级功能

实现：

- OCR
- AI
- Semantic Search
- Version History
- WebDAV
- Self-hosting
- CRDT

---

# 41. MVP 范围

第一版必须控制在：

```text
Notebook
Note
Tag
Rich Text
Image
Attachment
Search
Import
Export
Local Storage
```

暂时不要：

```text
AI
OCR
协作
CRDT
WebDAV
复杂权限
插件系统
```

---

# 42. 第一版功能优先级

### P0

```text
SQLite
Document Model
Note CRUD
Notebook
Editor
Attachment
Search
Auto Save
Backup
```

### P1

```text
Tags
Favorites
Trash
Markdown
HTML
ENEX Import
Keyboard Shortcut
Dark Mode
```

### P2

```text
Cloud Sync
OCR
AI
Version History
WebDAV
```

### P3

```text
Collaboration
CRDT
Plugin System
Enterprise
```

---

# 43. 第一阶段验收标准

必须做到：

1. 创建笔记
2. 修改笔记
3. 自动保存
4. 关闭程序后数据不丢失
5. 重启程序数据正确
6. 创建 Notebook
7. 标签管理
8. 图片插入
9. 文件附件
10. 全文搜索
11. 删除和恢复
12. 数据导出
13. 数据备份
14. 数据恢复

---

# 44. 核心工程原则

## 原则 1：Local First

本地数据永远优先。

## 原则 2：Rust Core

核心业务逻辑尽量不依赖 Flutter。

## 原则 3：SQLite First

不要过早引入复杂数据库。

## 原则 4：FTS5 First

不要一开始就上向量数据库。

## 原则 5：Revision First

先做可追踪的数据变更，再做 CRDT。

## 原则 6：Lazy Everything

大型内容全部按需加载。

## 原则 7：Files Outside Database

图片和附件原则上不直接塞进 SQLite。

## 原则 8：Document Model First

UI、HTML、Markdown 都应该围绕统一的数据模型。

---

# 45. 最终架构

```text
                 ┌─────────────────────┐
                 │ Flutter UI          │
                 │ Windows/macOS       │
                 │ iOS/Android         │
                 └─────────┬───────────┘
                           │ FFI
                           ▼
                 ┌─────────────────────┐
                 │ Rust Core           │
                 │                     │
                 │ Document            │
                 │ Repository          │
                 │ Search              │
                 │ Attachment          │
                 │ Import/Export       │
                 │ Sync                │
                 └─────────┬───────────┘
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
      ┌──────────────┐          ┌──────────────┐
      │ SQLite/FTS5  │          │ File Storage │
      └──────────────┘          └──────────────┘
                           │
                         HTTPS
                           │
                           ▼
                 ┌─────────────────────┐
                 │ Rust Sync Server    │
                 │ Axum + Tokio        │
                 └─────────┬───────────┘
                           │
                 ┌─────────┴─────────┐
                 ▼                   ▼
           PostgreSQL          S3 Object Store
```

---

# 46. 推荐实施顺序

不要同时开发所有模块。

严格按照：

```text
① Rust Core
        ↓
② SQLite
        ↓
③ Document Model
        ↓
④ Flutter ↔ Rust
        ↓
⑤ Windows/macOS UI
        ↓
⑥ Editor
        ↓
⑦ Attachment
        ↓
⑧ Search
        ↓
⑨ Android/iOS
        ↓
⑩ Sync Server
        ↓
⑪ Multi-device Sync
        ↓
⑫ OCR / AI
        ↓
⑬ CRDT / Collaboration
```

---

# 47. 项目第一阶段最终交付物

完成后应该得到：

```text
nested/
├── Flutter Application
├── Rust Core
├── SQLite Database
├── Document Model
├── FTS5 Search
├── Attachment Store
├── Import/Export
├── Automated Tests
├── Benchmark Suite
└── Technical Documentation
```

第一阶段最重要的不是做出“像 Evernote 的界面”，而是建立一个：

> **数据模型稳定、Local-First、跨平台、可扩展、低内存、能够长期演进的 Rust 核心。**

后续所有功能——同步、AI、OCR、版本历史、协作、自托管——都建立在这个核心之上。

---

# 48. 建议的下一份技术文档

本文件完成项目总体实施规划后，下一步应单独编写（统一放 `docs/design/`）：

```text
03-项目总体架构.md
04-Rust-Core架构设计.md
05-SQLite数据库设计.md
06-Document-Model设计.md
07-Flutter项目架构.md
08-编辑器技术方案.md
09-附件与资源管理.md
10-全文搜索设计.md
11-同步协议设计.md
12-服务端架构设计.md
13-数据加密与安全.md
14-性能与内存优化.md
15-测试方案.md
16-版本发布与CI-CD.md
17-开发任务拆解.md
```

其中 **《Document Model + SQLite 数据库设计 + Rust Core API》** 应作为真正开始编码前的第一批详细设计文档。

> 编号说明：`00-项目章程`、`01-开发计划`、`02-工程铁律` 已建立于 `docs/`，因此模块设计文档从 `03` 起编号。
> 各模块的**具体任务拆解**见 [docs/01-开发计划.md](docs/01-开发计划.md) §10（任务卡规范）。
