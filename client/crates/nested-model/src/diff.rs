// SPDX-License-Identifier: AGPL-3.0-or-later
//! 两个修订之间的**行级差异**（"修订对比"的核心算法）。
//!
//! ## 为什么自己做而不是引入 diff 库
//!
//! 需求很窄：把两份**块模型快照**的文本行拉平后做行级对比。
//! 不涉及字符级、语法级或三方合并（三方合并属于 P6 同步冲突处理，
//! 那是另一个问题、另一个时机）。
//!
//! 为此引入一个通用 diff 依赖，代价是长期的升级与安全面
//! （铁律 A8：依赖必须值得）。而 LCS 动态规划本身不到 40 行，
//! 且**完全可测**——本项目选择自己写。
//!
//! ## 算法与复杂度
//!
//! 经典 LCS 动态规划，时间 O(n·m)、空间 O(n·m)。
//! 这里的 n/m 是**行数**，而笔记的行数通常在几十到几百量级，
//! 因此完全够用（铁律 P2：先测量再优化；没有实测瓶颈就不上 Myers 算法）。
//!
//! ## 为什么按"行"而不是按"块"
//!
//! 块是粗粒度：改一个词也会让整个块显示为"整块替换"，
//! 用户看不出到底改了什么。按行展开后，"改了哪一句"是直接可见的。
//! 行数来自块自身的文本按换行拆分，因此多行段落也能逐行对比。

use std::fmt::Write as _;

use crate::document::Document;

/// 一行差异的类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiffKind {
    /// 两版都有（上下文）。
    Unchanged,
    /// 新增（新版本有、旧版本没有）。
    Added,
    /// 删除（旧版本有、新版本没有）。
    Removed,
}

/// 差异中的一行。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffLine {
    /// 该行的类型。
    pub kind: DiffKind,
    /// 行内容（不含换行符）。
    pub text: String,
}

impl DiffLine {
    /// 供界面显示的**前缀标记**。
    ///
    /// 用 ASCII 的 `+` / `-` / 空格而不是漂亮符号：
    /// 这三个字符是 diff 的通用约定，用户（尤其开发者）一眼就懂；
    /// 换成 `＋`／`－` 反而需要重新学习。
    #[must_use]
    pub const fn marker(&self) -> &'static str {
        match self.kind {
            DiffKind::Added => "+",
            DiffKind::Removed => "-",
            DiffKind::Unchanged => " ",
        }
    }
}

/// 一次对比的结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DocumentDiff {
    /// 逐行的差异（按新版本的顺序，删除行紧跟在它原来的位置）。
    pub lines: Vec<DiffLine>,
    /// 新增行数。
    pub added: usize,
    /// 删除行数。
    pub removed: usize,
}

impl DocumentDiff {
    /// 两版是否完全相同。
    #[must_use]
    pub const fn is_identical(&self) -> bool {
        self.added == 0 && self.removed == 0
    }

    /// 渲染成统一的文本形式（便于测试与"复制差异"这类功能）。
    #[must_use]
    pub fn to_unified_text(&self) -> String {
        let mut out = String::new();
        for line in &self.lines {
            let _ = writeln!(out, "{} {}", line.marker(), line.text);
        }
        out
    }
}

/// 把一份文档拉平成"行"列表。
///
/// 每个块贡献自己文本按换行拆分的若干行；空块贡献一个空行
/// （保留它，因为"删掉一个空段落"也是一次真实的修改）。
#[must_use]
pub fn flatten_lines(document: &Document) -> Vec<String> {
    let mut lines = Vec::new();
    for block in &document.blocks {
        let text = block.searchable_text();
        if text.is_empty() {
            lines.push(String::new());
            continue;
        }
        for line in text.split('\n') {
            lines.push(line.to_owned());
        }
    }
    lines
}

/// 计算两份文档的行级差异。
///
/// 参数顺序是"旧 → 新"，与用户的直觉一致（diff 工具都是这个顺序）。
#[must_use]
pub fn diff_documents(old: &Document, new: &Document) -> DocumentDiff {
    diff_lines(&flatten_lines(old), &flatten_lines(new))
}

/// 计算两个行列表的差异（LCS 动态规划）。
///
/// 单独暴露是为了能在不构造 `Document` 的情况下测试算法本身。
#[must_use]
pub fn diff_lines(old: &[String], new: &[String]) -> DocumentDiff {
    let n = old.len();
    let m = new.len();

    // lcs[i][j] = old[i..] 与 new[j..] 的最长公共子序列长度。
    // 反向填表，这样回溯时可以正向走。
    let mut lcs = vec![vec![0_usize; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            lcs[i][j] = if old[i] == new[j] {
                lcs[i + 1][j + 1] + 1
            } else {
                lcs[i + 1][j].max(lcs[i][j + 1])
            };
        }
    }

    let mut lines = Vec::new();
    let mut added = 0_usize;
    let mut removed = 0_usize;
    let (mut i, mut j) = (0_usize, 0_usize);

    while i < n && j < m {
        if old[i] == new[j] {
            lines.push(DiffLine {
                kind: DiffKind::Unchanged,
                text: new[j].clone(),
            });
            i += 1;
            j += 1;
        } else if lcs[i + 1][j] >= lcs[i][j + 1] {
            // 删除旧行
            lines.push(DiffLine {
                kind: DiffKind::Removed,
                text: old[i].clone(),
            });
            removed += 1;
            i += 1;
        } else {
            lines.push(DiffLine {
                kind: DiffKind::Added,
                text: new[j].clone(),
            });
            added += 1;
            j += 1;
        }
    }
    // 收尾：剩余的行分别全部算删除/新增
    while i < n {
        lines.push(DiffLine {
            kind: DiffKind::Removed,
            text: old[i].clone(),
        });
        removed += 1;
        i += 1;
    }
    while j < m {
        lines.push(DiffLine {
            kind: DiffKind::Added,
            text: new[j].clone(),
        });
        added += 1;
        j += 1;
    }

    DocumentDiff {
        lines,
        added,
        removed,
    }
}

/// 两个修订之间的差异（含"缺失快照"的语义）。
///
/// ## 为什么要这个类型而不是直接返回 [`DocumentDiff`]
///
/// 迁移 `0003` 之前的修订**没有内容快照**（见
/// `docs/adr/0001-修订内容用完整快照.md`）。那种情况下**不能**返回
/// "空差异"——那等于告诉用户"这两版一模一样"，而事实是"我们不知道"。
///
/// 把这两种情况做成不同的变体，界面就无法把它们混为一谈。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiffOutcome {
    /// 成功比出差异。
    Diff(DocumentDiff),
    /// 其中一侧没有快照，无法对比。
    MissingSnapshot {
        /// 是"旧版本"还是"新版本"缺快照。
        side: DiffSide,
    },
}

/// 缺快照的是哪一侧。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiffSide {
    /// 旧版本缺快照。
    Old,
    /// 新版本缺快照。
    New,
    /// 两侧都缺。
    Both,
}

impl DiffOutcome {
    /// 从两个可选快照构造结果。
    #[must_use]
    pub fn from_snapshots(old: Option<&Document>, new: Option<&Document>) -> Self {
        match (old, new) {
            (Some(old), Some(new)) => Self::Diff(diff_documents(old, new)),
            (None, Some(_)) => Self::MissingSnapshot {
                side: DiffSide::Old,
            },
            (Some(_), None) => Self::MissingSnapshot {
                side: DiffSide::New,
            },
            (None, None) => Self::MissingSnapshot {
                side: DiffSide::Both,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::block::Block;

    fn lines(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| (*s).to_owned()).collect()
    }

    fn doc(paragraphs: &[&str]) -> Document {
        Document::from_blocks(
            paragraphs
                .iter()
                .map(|text| Block::paragraph(*text))
                .collect(),
            1_700_000_000_000,
        )
    }

    #[test]
    fn identical_input_has_no_changes() {
        let d = diff_lines(&lines(&["a", "b"]), &lines(&["a", "b"]));
        assert!(d.is_identical());
        assert_eq!(d.lines.len(), 2);
        assert!(d.lines.iter().all(|l| l.kind == DiffKind::Unchanged));
    }

    #[test]
    fn added_line_is_detected() {
        let d = diff_lines(&lines(&["a", "c"]), &lines(&["a", "b", "c"]));
        assert_eq!(d.added, 1);
        assert_eq!(d.removed, 0);
        assert_eq!(
            d.lines,
            vec![
                DiffLine {
                    kind: DiffKind::Unchanged,
                    text: "a".to_owned()
                },
                DiffLine {
                    kind: DiffKind::Added,
                    text: "b".to_owned()
                },
                DiffLine {
                    kind: DiffKind::Unchanged,
                    text: "c".to_owned()
                },
            ]
        );
    }

    #[test]
    fn removed_line_is_detected() {
        let d = diff_lines(&lines(&["a", "b", "c"]), &lines(&["a", "c"]));
        assert_eq!(d.removed, 1);
        assert_eq!(d.added, 0);
        assert!(
            d.lines
                .iter()
                .any(|l| l.kind == DiffKind::Removed && l.text == "b")
        );
    }

    #[test]
    fn modified_line_shows_as_remove_plus_add() {
        // 行级 diff 的表达方式：改一行 = 删一行 + 加一行。
        // 这不是缺陷，而是行级对比的固有语义；界面上表现为相邻的 -/+ 对，
        // 用户能直接看出"这一句被换掉了"。
        let d = diff_lines(&lines(&["旧句子"]), &lines(&["新句子"]));
        assert_eq!(d.added, 1);
        assert_eq!(d.removed, 1);
        assert!(!d.is_identical());
    }

    #[test]
    fn empty_to_content_is_all_added() {
        let d = diff_lines(&[], &lines(&["a", "b"]));
        assert_eq!(d.added, 2);
        assert_eq!(d.removed, 0);
    }

    #[test]
    fn content_to_empty_is_all_removed() {
        let d = diff_lines(&lines(&["a", "b"]), &[]);
        assert_eq!(d.removed, 2);
        assert_eq!(d.added, 0);
    }

    #[test]
    fn both_empty_is_identical() {
        assert!(diff_lines(&[], &[]).is_identical());
    }

    #[test]
    fn marker_matches_kind() {
        let d = diff_lines(&lines(&["a"]), &lines(&["b"]));
        let text = d.to_unified_text();
        assert!(text.contains("- a"), "实际：{text}");
        assert!(text.contains("+ b"), "实际：{text}");
    }

    #[test]
    fn flatten_keeps_blank_paragraphs() {
        // 删掉一个空段落也是真实的修改，不能因为"文本为空"就丢掉
        let document = doc(&["第一段", "", "第三段"]);
        assert_eq!(flatten_lines(&document), lines(&["第一段", "", "第三段"]));
    }

    #[test]
    fn diff_documents_compares_paragraph_text() {
        let old = doc(&["第一版", "共有的"]);
        let new = doc(&["第二版", "共有的"]);
        let d = diff_documents(&old, &new);
        assert_eq!(d.removed, 1);
        assert_eq!(d.added, 1);
        // "共有的"应当被识别为未变，而不是整篇重写
        assert!(
            d.lines
                .iter()
                .any(|l| l.kind == DiffKind::Unchanged && l.text == "共有的"),
            "未改动的段落必须保持 Unchanged，否则对比毫无信息量"
        );
    }

    #[test]
    fn missing_snapshot_is_not_reported_as_identical() {
        // 最关键的一条：缺快照与"没有差异"是**两回事**。
        // 若把缺快照当成"相同"，用户会以为这一版内容和另一版一样，
        // 而事实是我们根本不知道。这是会误导人的错误。
        let result = DiffOutcome::from_snapshots(None, Some(&doc(&["x"])));
        assert_eq!(
            result,
            DiffOutcome::MissingSnapshot {
                side: DiffSide::Old
            }
        );
        assert_ne!(
            result,
            DiffOutcome::Diff(diff_lines(&[], &[])),
            "缺快照绝不能等价于'无差异'"
        );
    }

    #[test]
    fn missing_snapshot_side_is_reported_correctly() {
        let d = doc(&["x"]);
        assert_eq!(
            DiffOutcome::from_snapshots(Some(&d), None),
            DiffOutcome::MissingSnapshot {
                side: DiffSide::New
            }
        );
        assert_eq!(
            DiffOutcome::from_snapshots(None, None),
            DiffOutcome::MissingSnapshot {
                side: DiffSide::Both
            }
        );
    }

    #[test]
    fn both_present_gives_a_diff() {
        let result = DiffOutcome::from_snapshots(Some(&doc(&["a"])), Some(&doc(&["b"])));
        assert!(matches!(result, DiffOutcome::Diff(_)));
    }
}
