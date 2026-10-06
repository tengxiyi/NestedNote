-- =============================================================================
-- 拾光笔记 / NestedNote —— 本地 SQLite 迁移 0002
-- 修正 sync_operations 的外键设计
--
-- 背景（技术债 #12 的连带发现）：
--   0001 里 sync_operations.note_id 是 `REFERENCES notes (id)`。但同步队列并不只
--   承载笔记——铁律 T3 要求**任何**本地写操作都入队，其中包括笔记本（notebook）
--   与标签（tag）的创建/重命名/删除。把这些实体的 id 写进 note_id 列会立刻
--   触发外键失败（实测 787: FOREIGN KEY constraint failed）。
--
--   换言之：这张表在语义上一直是"通用实体变更队列"，只是 0001 把它写成了笔记专用。
--   本迁移把外键去掉，并把列名改为语义正确的 entity_id。
--
-- 铁律约束：
--   Q2：已发布的 0001 不可修改，因此这里新建一条迁移来纠正。
--   D6：本文件一旦发布同样不可再修改。
--   D9：不存在的实体引用置为 NULL（而不是删除行）——队列记录本身是同步所需的信息，
--       不能因为外部引用失效就丢弃。
-- =============================================================================

CREATE TABLE sync_operations_new (
    id            BLOB PRIMARY KEY,
    -- 本次操作针对的实体（笔记 / 笔记本 / 标签）。
    -- **刻意不加外键**：这些实体分散在多张表里，SQLite 无法表达"多态外键"。
    -- 引用完整性由写入路径保证（见 repositories/sync_operations.rs 的文档）。
    entity_id     BLOB,
    device_id     TEXT    NOT NULL,
    operation     TEXT    NOT NULL,
    payload       BLOB,
    created_at_ms INTEGER NOT NULL,
    pushed_at_ms  INTEGER
);

-- 迁移既有数据：把原先指向已删除笔记（软删不影响外键，因此理论上不会出现）
-- 的悬空引用置空，避免把坏引用带进新表。
INSERT INTO sync_operations_new (id, entity_id, device_id, operation, payload,
                                 created_at_ms, pushed_at_ms)
SELECT s.id,
       CASE WHEN s.note_id IS NULL OR n.id IS NOT NULL THEN s.note_id ELSE NULL END,
       s.device_id,
       s.operation,
       s.payload,
       s.created_at_ms,
       s.pushed_at_ms
FROM sync_operations s
LEFT JOIN notes n ON n.id = s.note_id;

DROP TABLE sync_operations;

ALTER TABLE sync_operations_new RENAME TO sync_operations;

-- 待推送队列的主要访问模式：找 pushed_at_ms IS NULL 的行（见 list_pending）
CREATE INDEX idx_sync_operations_pending ON sync_operations (pushed_at_ms);
