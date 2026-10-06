//! # server-migration 0001 —— 初始结构
//!
//! ⚠️ **已发布的迁移文件禁止修改**（铁律 Q2）。
//! 修正必须新增 `000N_*.sql`。改动本文件会导致老部署与新部署结构分叉。

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 用户
CREATE TABLE IF NOT EXISTS users (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    email         TEXT        NOT NULL,
    password_hash TEXT        NOT NULL,
    created_at_ms BIGINT      NOT NULL,
    disabled_at_ms BIGINT
);

-- 邮箱大小写不敏感唯一（避免同一邮箱注册出两个账号）
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email_unique ON users (lower(email));

-- 设备（同一账号可有多台设备；设备标识由客户端生成，用于冲突归因）
CREATE TABLE IF NOT EXISTS devices (
    id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    client_device_id TEXT      NOT NULL,
    name           TEXT        NOT NULL DEFAULT '',
    platform       TEXT        NOT NULL DEFAULT '',
    created_at_ms  BIGINT      NOT NULL,
    last_seen_at_ms BIGINT,
    revoked_at_ms  BIGINT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_devices_user_client
    ON devices (user_id, client_device_id);

-- 会话（refresh token 只存哈希；明文绝不入库，铁律 S3）
CREATE TABLE IF NOT EXISTS sessions (
    id                UUID   PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           UUID   NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    device_id         UUID   REFERENCES devices (id) ON DELETE SET NULL,
    refresh_token_hash TEXT  NOT NULL,
    created_at_ms     BIGINT NOT NULL,
    expires_at_ms     BIGINT NOT NULL,
    revoked_at_ms     BIGINT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_token ON sessions (refresh_token_hash);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions (user_id, expires_at_ms);

-- 笔记元数据（正文与附件走各自通道；服务端只保存同步所需的元数据与修订）
CREATE TABLE IF NOT EXISTS notes (
    user_id        UUID   NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    note_id        UUID   NOT NULL,
    latest_version BIGINT NOT NULL DEFAULT 0,
    updated_at_ms  BIGINT NOT NULL,
    deleted_at_ms  BIGINT,
    PRIMARY KEY (user_id, note_id)
);

-- 修订（同步的基本单位；服务端只追加，不修改，铁律 T6）
CREATE TABLE IF NOT EXISTS revisions (
    user_id            UUID   NOT NULL,
    note_id            UUID   NOT NULL,
    revision_id        UUID   NOT NULL,
    version            BIGINT NOT NULL,
    parent_revision_id UUID,
    device_id          TEXT   NOT NULL,
    operation          TEXT   NOT NULL,
    payload            BYTEA,
    created_at_ms      BIGINT NOT NULL,
    PRIMARY KEY (user_id, revision_id),
    FOREIGN KEY (user_id, note_id) REFERENCES notes (user_id, note_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_revisions_note_version
    ON revisions (user_id, note_id, version DESC);

-- 附件元数据（对象本体在 S3 兼容存储中，键为内容哈希，铁律 T8）
CREATE TABLE IF NOT EXISTS attachments (
    user_id       UUID   NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    sha256        TEXT   NOT NULL,
    size_bytes    BIGINT NOT NULL,
    mime_type     TEXT   NOT NULL,
    created_at_ms BIGINT NOT NULL,
    PRIMARY KEY (user_id, sha256)
);

-- 每设备的拉取游标（增量同步的起点）
CREATE TABLE IF NOT EXISTS sync_cursors (
    device_id      UUID   PRIMARY KEY REFERENCES devices (id) ON DELETE CASCADE,
    last_pulled_ms BIGINT NOT NULL DEFAULT 0
);
