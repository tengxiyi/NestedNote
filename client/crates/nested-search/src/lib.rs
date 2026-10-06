//! # nested-search —— 全文搜索（SQLite FTS5）
//!
//! **状态**：P0 仅建立 crate 边界与接口草案；实际实现属于 P1（开发计划 §2.1.3）。
//!
//! ## 预留决策点（实现前必须先用基准数据回答）
//!
//! FTS5 默认分词器 `unicode61` 对中文不友好（整段中文会被当成一个 token）。
//! 候选方案：
//!
//! 1. `unicode61` + 应用层**二元切分**（bigram）：写入时把中文切成相邻两字组合；
//! 2. `trigram` 分词器（SQLite 3.34+）：召回好、体积大；
//! 3. 外部分词（jieba 类）：效果好但引入较大依赖与词典维护成本。
//!
//! 选择必须由 [开发计划 P1-13](docs/01-开发计划.md) 的对比基准决定，
//! 并记录在 `docs/adr/` 中（铁律 M2）。**禁止**未经验证直接选定。

#![forbid(unsafe_code)]

use nested_model::Id;

/// 搜索查询。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchQuery {
    /// 用户输入的原始查询串（**禁止**直接拼进 SQL，必须参数化，铁律 Q4）。
    pub text: String,
    /// 限定笔记本。
    pub notebook_id: Option<Id>,
    /// 是否包含回收站中的笔记。
    pub include_deleted: bool,
    /// 分页偏移。
    pub offset: u32,
    /// 分页大小上限。
    pub limit: u32,
}

/// 命中结果。
///
/// 不派生 `Eq`：相关度是浮点数（BM25），浮点不满足 `Eq` 的全部语义。
#[derive(Debug, Clone, PartialEq)]
pub struct SearchHit {
    /// 命中的笔记。
    pub note_id: Id,
    /// 标题。
    pub title: String,
    /// 高亮片段（由 FTS5 `snippet()` 产出）。
    pub snippet: String,
    /// 相关度（BM25，越小越相关）。
    pub rank: f64,
}

/// 搜索错误。
#[derive(Debug, thiserror::Error)]
pub enum SearchError {
    /// 存储层错误。
    #[error("搜索依赖的存储层出错：{0}")]
    Storage(#[from] nested_db::DbError),

    /// 查询语法非法（用户输入了 FTS5 不接受的表达式）。
    #[error("搜索表达式非法")]
    InvalidQuery,
}

/// 搜索结果别名。
pub type SearchResult<T> = std::result::Result<T, SearchError>;
