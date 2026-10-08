// SPDX-License-Identifier: AGPL-3.0-or-later
//! 维护操作 —— 附件清理与完整性核对（FFI 暴露面）。
//!
//! ## 为什么单独一个文件
//!
//! 这两个操作不属于"笔记"，放 `notes.rs` 会让那个文件继续膨胀
//! （它已经 1700+ 行）。按**能力域**分文件，找东西时按目录猜就行。
//!
//! ## 为什么这两件事值得做进界面
//!
//! - **附件清理（GC）**：删除笔记后，附件文件还在磁盘上（宽限期内
//!   不删，防误删）。没有入口的话它们会永远留着，用户只能自己翻目录
//!   手动删——那更危险。内核有 `gc_attachments`，界面上一直没入口，
//!   这是真实能力在浪费。
//! - **完整性核对**：`check_integrity` 跑 SQLite 的 `PRAGMA
//!   integrity_check`。用户怀疑数据出问题时（本项目真发生过：
//!   "回收站删几个目录后目录树不显示"），一个"核对一下"按钮
//!   比让用户去找 CLI 工具友好得多。
//!
//! ## 与铁律的关系
//!
//! GC 是全项目唯一"用户没操作、数据却消失"的路径的近亲（自动清理
//! 回收站是另一个）。因此结果**必须如实报告**——清了什么、留了什么、
//! 有没有断链，一个数字都不能含糊（铁律 T1 的"可追溯"承诺）。

use serde::{Deserialize, Serialize};

use nested_core::NestedCore;

use crate::api::notes::with_core;

/// 维护操作的结果。
///
/// ## 为什么不用 `NoteResult` 的载荷
///
/// `NotePayload` 是为笔记操作设计的（note/notes/revisions…字段），
/// 维护结果塞进去会变成"哪个字段被复用作什么"的猜谜。
/// 独立结构让每个数字有名字，界面与测试都不必猜。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MaintenanceResult {
    /// 是否成功。
    pub ok: bool,
    /// 稳定错误码（失败时）。
    pub code: Option<String>,
    /// 给用户看的一句话提示（失败时说明原因，成功时为 `None`）。
    pub hint: Option<String>,

    // ---- 附件清理的结果 ----
    /// 被删除的孤儿附件文件数。
    pub removed_files: u64,

    /// 因仍在宽限期内而保留的候选文件数。
    ///
    /// 这个数字很重要：用户看到"只删了 3 个"而目录里明明还有一堆
    /// 没被引用的文件时，是**这个数字**在解释"其余的不是丢了，
    /// 是还在保护期里"。
    pub kept_recent: u64,

    /// 释放的磁盘字节数。
    pub freed_bytes: u64,

    /// 元数据指向但文件缺失的**断链**数。
    ///
    /// 正常必须是 0。不为 0 说明违反了附件模块的不变量，
    /// 要如实展示并建议用户核对——静默忽略会掩盖数据损坏。
    pub broken_links: u64,

    // ---- 完整性核对的结果 ----
    /// 核对通过时的一句话描述（如 `integrity_check ok`）。
    pub integrity_detail: Option<String>,
}

/// 运行附件清理，返回报告。
///
/// ## 为什么 `at_ms` 由界面传入
///
/// 与笔记操作同一理由（见 `notes.rs` 的模块文档）：时间权威来源只有
/// 一个（Dart 的系统时钟），避免两端时钟不一致导致宽限期判断错乱——
/// **宽限期判断错了会误删用户的附件**，这里比别处更输不起。
#[must_use]
pub fn maintenance_gc_attachments(at_ms: i64) -> MaintenanceResult {
    match with_core(|core: &NestedCore| core.gc_attachments(at_ms)) {
        Ok(report) => MaintenanceResult {
            ok: true,
            code: None,
            hint: None,
            removed_files: report.removed_files as u64,
            kept_recent: report.kept_recent as u64,
            freed_bytes: report.freed_bytes,
            broken_links: report.broken_links as u64,
            integrity_detail: None,
        },
        Err(failure) => MaintenanceResult {
            ok: false,
            code: failure.code,
            hint: failure.hint,
            removed_files: 0,
            kept_recent: 0,
            freed_bytes: 0,
            broken_links: 0,
            integrity_detail: None,
        },
    }
}

/// 核对数据库完整性（`PRAGMA integrity_check`）。
///
/// 只读操作：核对不修改任何数据，失败也不会让情况变得更糟，
/// 因此可以在任何时候放心点。
#[must_use]
pub fn maintenance_check_integrity() -> MaintenanceResult {
    match with_core(|core: &NestedCore| core.check_integrity()) {
        Ok(()) => MaintenanceResult {
            ok: true,
            code: None,
            hint: None,
            removed_files: 0,
            kept_recent: 0,
            freed_bytes: 0,
            broken_links: 0,
            integrity_detail: Some("数据库完整性核对通过。".to_owned()),
        },
        Err(failure) => MaintenanceResult {
            ok: false,
            code: failure.code,
            hint: failure.hint,
            removed_files: 0,
            kept_recent: 0,
            freed_bytes: 0,
            broken_links: 0,
            integrity_detail: None,
        },
    }
}

/// 一条活动记录（对界面暴露的形态）。
///
/// ## 为什么定义在本模块而不是 core
///
/// 第一版放 core，FFI 的生成代码里它被当成了 **opaque 类型**
///（界面拿到的是不透明句柄，读不到字段）——FRB 只把 **api 模块里
/// 定义的、带完整字段的结构**当镜像类型。与 `MaintenanceResult`
/// 同一个教训：**跨语言契约面只放本 crate 的结构**。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActivityEntry {
    /// 发生时间（UTC 毫秒）。
    pub at_ms: i64,
    /// 事件类型，如 `trash.purge` / `attachments.gc` / `integrity.check`。
    pub kind: String,
    /// 给人看的说明（含关键数字），界面直接展示。
    pub detail: String,
}

/// 最近的活动记录（时间倒序），供"工具 → 活动日志"展示。
///
/// ## 失败时返回空列表的已知妥协
///
/// 与 `attachments_list` 同一个缺口：这一层没有通道区分"没有记录"
/// 与"读取失败"。对日志而言这个妥协可以接受（日志不是业务数据，
/// 丢了不丢用户内容），但空列表的文案必须**两种情况都读得通**——
/// 界面写的是"还没有记录"，而不是"一切正常"。
#[must_use]
pub fn activity_recent(limit: u32) -> Vec<ActivityEntry> {
    match with_core(|core: &NestedCore| core.recent_activity(limit)) {
        Ok(events) => events
            .into_iter()
            .map(|event| ActivityEntry {
                at_ms: event.at_ms,
                kind: event.kind,
                detail: event.detail,
            })
            .collect(),
        Err(_) => Vec::new(),
    }
}
