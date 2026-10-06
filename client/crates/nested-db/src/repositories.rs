//! Repository 层：**唯一**允许编写 SQL 的地方（铁律 A7）。
//!
//! 规则：
//! - 所有 SQL **必须**参数化（铁律 Q4），禁止字符串拼接；
//! - 涉及多表的业务操作**必须**由调用方放进同一个事务（铁律 D1）；
//! - 删除一律软删除（铁律 T7 / D2），物理删除只允许出现在 GC 模块（尚未实现）。

pub mod attachments;
pub mod notebooks;
pub mod notes;
pub mod revisions;
pub mod sync_operations;
pub mod tags;
