//! 时间类型与取值规则（铁律 D8）。

use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

/// UTC Unix 毫秒时间戳。
///
/// **禁止**在存储层保存本地时间或格式化字符串（铁律 D8）；
/// 时区换算与人类可读格式化只允许发生在 UI 层。
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Timestamp(i64);

impl Timestamp {
    /// 从 UTC 毫秒构造。
    #[must_use]
    pub const fn from_millis(millis: i64) -> Self {
        Self(millis)
    }

    /// 取 UTC 毫秒。
    #[must_use]
    pub const fn as_millis(&self) -> i64 {
        self.0
    }

    /// 转为 `time::OffsetDateTime`（用于格式化或与 `time` 生态互操作）。
    ///
    /// # Errors
    ///
    /// 数值超出 `OffsetDateTime` 可表示范围时返回 [`crate::ModelError::InvalidTimestamp`]。
    pub fn to_offset_date_time(self) -> crate::Result<OffsetDateTime> {
        OffsetDateTime::from_unix_timestamp_nanos(i128::from(self.0) * 1_000_000)
            .map_err(|_| crate::ModelError::InvalidTimestamp)
    }
}

impl std::fmt::Display for Timestamp {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// 当前时间（UTC 毫秒）。
///
/// 这是本 crate 中**唯一**读取系统时钟的函数；业务逻辑应通过参数接收时间，
/// 以便测试注入固定时刻（铁律 R10）。
#[must_use]
pub fn now_ms() -> i64 {
    let now = OffsetDateTime::now_utc();
    let millis = now.unix_timestamp_nanos() / 1_000_000;
    i64::try_from(millis).unwrap_or(i64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn now_is_after_2020_and_before_2100() {
        let now = now_ms();
        assert!(now > 1_577_836_800_000, "应晚于 2020-01-01：{now}");
        assert!(now < 4_102_444_800_000, "应早于 2100-01-01：{now}");
    }

    #[test]
    fn timestamp_converts_to_utc() {
        let ts = Timestamp::from_millis(0);
        let dt = ts.to_offset_date_time().expect("epoch is representable");
        assert_eq!(dt.unix_timestamp(), 0);
    }

    #[test]
    fn ordering_follows_millis() {
        assert!(Timestamp::from_millis(1) < Timestamp::from_millis(2));
    }
}
