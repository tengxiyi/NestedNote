-- =============================================================================
-- 拾光笔记 / NestedNote —— 本地 SQLite 迁移 0001
-- 初始结构（技术文档 §8）
--
-- 铁律约束：
--   D6/Q2：本文件一旦发布**不可修改**，修正必须新增 migration。
--   T7/D2：删除一律软删除（deleted_at_ms），禁止在此定义级联物理删除。
--   D8：所有时间列一律 INTEGER UTC 毫秒。
--   D7：所有主键一律 UUIDv7 的 16 字节 BLOB。
--   Q11：结构约束（主键/非空/唯一/外键/默认值）必须写在 schema 里。
-- =============================================================================

-- 笔记本（可嵌套成树）
CREATE TABLE notebooks (
    id            BLOB PRIMARY KEY,
    name          TEXT    NOT NULL,
    parent_id     BLOB    REFERENCES notebooks (id),
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);

CREATE INDEX idx_notebooks_parent ON notebooks (parent_id);

-- 笔记
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

CREATE INDEX idx_notes_updated ON notes (updated_at_ms DESC);
CREATE INDEX idx_notes_notebook ON notes (notebook_id, deleted_at_ms);
CREATE INDEX idx_notes_deleted ON notes (deleted_at_ms);
CREATE INDEX idx_notes_pinned ON notes (is_pinned, updated_at_ms DESC);

-- 标签
CREATE TABLE tags (
    id            BLOB PRIMARY KEY,
    name          TEXT    NOT NULL,
    created_at_ms INTEGER NOT NULL,
    deleted_at_ms INTEGER
);

-- 标签名全局唯一（忽略大小写），避免"工作"与"工作 "并存
CREATE UNIQUE INDEX idx_tags_name_unique ON tags (name COLLATE NOCASE);

-- 笔记 ↔ 标签
CREATE TABLE note_tags (
    note_id     BLOB    NOT NULL REFERENCES notes (id),
    tag_id      BLOB    NOT NULL REFERENCES tags (id),
    tagged_at_ms INTEGER NOT NULL,
    PRIMARY KEY (note_id, tag_id)
);

CREATE INDEX idx_note_tags_tag ON note_tags (tag_id);

-- 附件元数据（文件本体在内容寻址存储中，绝不入库，铁律 T8）
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

-- 同一内容只存一份：SHA-256 唯一（内容寻址去重，技术文档 §9）
CREATE UNIQUE INDEX idx_attachments_sha256 ON attachments (sha256);

-- 笔记 ↔ 附件引用
CREATE TABLE note_attachments (
    note_id       BLOB    NOT NULL REFERENCES notes (id),
    attachment_id BLOB    NOT NULL REFERENCES attachments (id),
    linked_at_ms  INTEGER NOT NULL,
    PRIMARY KEY (note_id, attachment_id)
);

CREATE INDEX idx_note_attachments_attachment ON note_attachments (attachment_id);

-- 结构化文档内容（块模型；JSON 字节）
CREATE TABLE documents (
    note_id       BLOB PRIMARY KEY REFERENCES notes (id),
    format        TEXT    NOT NULL,
    format_version INTEGER NOT NULL,
    content       BLOB    NOT NULL,
    updated_at_ms INTEGER NOT NULL
);

-- 修订记录（铁律 T6：变更必须可追踪）
CREATE TABLE revisions (
    id                 BLOB PRIMARY KEY,
    note_id            BLOB    NOT NULL REFERENCES notes (id),
    version            INTEGER NOT NULL,
    parent_revision_id BLOB    REFERENCES revisions (id),
    created_at_ms      INTEGER NOT NULL,
    device_id          TEXT    NOT NULL,
    operation          TEXT    NOT NULL
);

CREATE INDEX idx_revisions_note ON revisions (note_id, version DESC);

-- 待同步操作队列（P6 使用；本地优先的写队列，铁律 T3）
CREATE TABLE sync_operations (
    id            BLOB PRIMARY KEY,
    note_id       BLOB    REFERENCES notes (id),
    device_id     TEXT    NOT NULL,
    operation     TEXT    NOT NULL,
    payload       BLOB,
    created_at_ms INTEGER NOT NULL,
    pushed_at_ms  INTEGER
);

CREATE INDEX idx_sync_operations_pending ON sync_operations (pushed_at_ms);

-- 键值设置（UI 偏好、窗口状态等；敏感密钥禁止放这里，铁律 D11）
CREATE TABLE settings (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    updated_at_ms INTEGER NOT NULL
);
