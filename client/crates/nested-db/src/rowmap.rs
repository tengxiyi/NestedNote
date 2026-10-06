//! 行映射辅助：领域类型 ↔ SQLite 列值。
//!
//! ## 为什么返回 `rusqlite::Result` 而不是 `DbError`
//!
//! `rusqlite` 的 `query_row` / `query_map` 要求闭包返回 `rusqlite::Result`。
//! 若映射函数返回自定义错误类型，每个查询点都要写一层 `map_err`，
//! 极易漏掉且噪音大。因此：
//!
//! - 本模块与各仓储的 `map_row` 统一返回 `rusqlite::Result<T>`；
//! - 数据损坏用 [`corrupt`] 构造 `rusqlite::Error::FromSqlConversionFailure`；
//! - 仓储函数在**唯一**的出口处用 `?` 转成 [`crate::DbError`]。
//!
//! 结果：损坏数据仍然变成结构化的 [`crate::DbError::Corrupt`]（铁律 R1：不 panic），
//! 但代码里只有一处转换。

use nested_model::{Id, Timestamp};
use rusqlite::Row;
use rusqlite::types::{Type, ValueRef};

use crate::DbError;

/// 构造"数据损坏"错误（列内容与预期类型不符）。
///
/// 用 `FromSqlConversionFailure` 而不是 `InvalidColumnType`，是为了携带
/// 实体名，便于日志定位（铁律 E3）。
#[must_use]
pub fn corrupt(entity: &'static str) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(0, Type::Null, Box::new(DbError::Corrupt { entity }))
}

/// 读取 UUID 主键（BLOB，16 字节）。
///
/// # Errors
///
/// 列不是 16 字节 BLOB 时返回 `corrupt` 错误。
pub fn id_at(row: &Row<'_>, index: usize, entity: &'static str) -> rusqlite::Result<Id> {
    let raw: Vec<u8> = row.get(index)?;
    Id::from_slice(&raw).map_err(|_| corrupt(entity))
}

/// 读取可空 UUID。
///
/// # Errors
///
/// 值既不是 NULL 也不是 16 字节 BLOB 时返回 `corrupt` 错误。
pub fn optional_id_at(
    row: &Row<'_>,
    index: usize,
    entity: &'static str,
) -> rusqlite::Result<Option<Id>> {
    match row.get_ref(index)? {
        ValueRef::Null => Ok(None),
        ValueRef::Blob(bytes) => Id::from_slice(bytes).map(Some).map_err(|_| corrupt(entity)),
        _ => Err(corrupt(entity)),
    }
}

/// 读取时间戳（UTC 毫秒）。
///
/// # Errors
///
/// 列不是整数时返回错误。
pub fn timestamp_at(row: &Row<'_>, index: usize) -> rusqlite::Result<Timestamp> {
    let raw: i64 = row.get(index)?;
    Ok(Timestamp::from_millis(raw))
}

/// 读取可空时间戳。
///
/// # Errors
///
/// 列既不是 NULL 也不是整数时返回错误。
pub fn optional_timestamp_at(row: &Row<'_>, index: usize) -> rusqlite::Result<Option<Timestamp>> {
    let raw: Option<i64> = row.get(index)?;
    Ok(raw.map(Timestamp::from_millis))
}

/// 读取布尔值（SQLite 用 0/1 整数表示）。
///
/// # Errors
///
/// 列不是整数时返回错误。
pub fn bool_at(row: &Row<'_>, index: usize) -> rusqlite::Result<bool> {
    let raw: i64 = row.get(index)?;
    Ok(raw != 0)
}

/// 把布尔值写成 SQLite 整数。
#[must_use]
pub const fn bool_to_int(value: bool) -> i64 {
    if value { 1 } else { 0 }
}

/// 把 UUID 写成 SQLite BLOB。
#[must_use]
pub fn id_to_blob(id: &Id) -> Vec<u8> {
    id.as_bytes().to_vec()
}

/// 把 `u64`（如文件大小）安全转换为 SQLite 的 `i64`。
///
/// # Errors
///
/// 超过 `i64::MAX` 时返回 [`DbError::Corrupt`]（实际不可能，但禁止静默截断）。
pub fn u64_to_i64(value: u64, entity: &'static str) -> Result<i64, DbError> {
    i64::try_from(value).map_err(|_| DbError::Corrupt { entity })
}

/// 把 SQLite 的 `i64` 还原为 `u64`。
///
/// # Errors
///
/// 负数时返回 [`DbError::Corrupt`]。
pub fn i64_to_u64(value: i64, entity: &'static str) -> Result<u64, DbError> {
    u64::try_from(value).map_err(|_| DbError::Corrupt { entity })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bool_helpers_are_consistent() {
        assert_eq!(bool_to_int(true), 1);
        assert_eq!(bool_to_int(false), 0);
    }

    #[test]
    fn u64_roundtrip_within_range() {
        let value = 1_234_567_u64;
        let encoded = u64_to_i64(value, "attachment").expect("encode");
        assert_eq!(i64_to_u64(encoded, "attachment").expect("decode"), value);
    }

    #[test]
    fn negative_value_is_rejected_as_corrupt() {
        let error = i64_to_u64(-1, "attachment").expect_err("must reject");
        assert!(matches!(
            error,
            DbError::Corrupt {
                entity: "attachment"
            }
        ));
    }

    #[test]
    fn id_blob_roundtrip() {
        let id = Id::new();
        let blob = id_to_blob(&id);
        assert_eq!(blob.len(), 16);
        assert_eq!(Id::from_slice(&blob).expect("decode"), id);
    }

    #[test]
    fn corrupt_error_carries_entity_name() {
        let error = corrupt("note");
        let text = error.to_string();
        assert!(text.contains("note"), "错误信息应包含实体名：{text}");
    }
}
