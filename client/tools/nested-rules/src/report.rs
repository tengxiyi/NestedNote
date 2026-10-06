//! 检查结果的数据结构与输出。

use std::collections::BTreeMap;
use std::path::Path;

/// 一条违规。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Violation {
    /// 文件路径（相对仓库根，便于在 CI 日志里直接点击）。
    pub file: String,
    /// 1 起的行号；0 表示与具体行无关。
    pub line: usize,
    /// 违反了铁律的哪一条。
    pub rule: &'static str,
    /// 问题描述。
    pub message: String,
    /// 怎么改。
    pub fix: &'static str,
}

impl Violation {
    /// 构造一条违规。
    #[must_use]
    pub fn new(
        rule: &'static str,
        file: impl Into<String>,
        line: usize,
        message: impl Into<String>,
        fix: &'static str,
    ) -> Self {
        Self {
            rule,
            file: file.into(),
            line,
            message: message.into(),
            fix,
        }
    }

    /// 把绝对路径转成相对仓库根的路径。
    #[must_use]
    pub fn relative(root: &Path, path: &Path) -> String {
        path.strip_prefix(root)
            .unwrap_or(path)
            .to_string_lossy()
            .replace('\\', "/")
    }
}

/// 检查报告。
#[derive(Debug, Default)]
pub struct Report {
    /// 按规则分组的违规。
    groups: BTreeMap<&'static str, Vec<Violation>>,
}

impl Report {
    /// 追加某条规则的违规列表。
    pub fn extend(&mut self, rule: &'static str, violations: Vec<Violation>) {
        if violations.is_empty() {
            return;
        }
        self.groups.entry(rule).or_default().extend(violations);
    }

    /// 是否无违规。
    #[must_use]
    pub fn is_clean(&self) -> bool {
        self.groups.values().all(Vec::is_empty)
    }

    /// 违规总数。
    #[must_use]
    pub fn total(&self) -> usize {
        self.groups.values().map(Vec::len).sum()
    }

    /// 一行结论（供脚本消费）。
    #[must_use]
    pub fn summary_line(&self) -> String {
        if self.is_clean() {
            "rules: OK (0 violations)".to_owned()
        } else {
            format!("rules: FAIL ({} violations)", self.total())
        }
    }

    /// 打印完整报告。
    pub fn print(&self) {
        println!();
        if self.is_clean() {
            println!("OK: 未发现铁律违规。");
            return;
        }

        println!("FAIL: 发现 {} 处违规：", self.total());
        println!();
        for (rule, violations) in &self.groups {
            println!("[{rule}] {} 处", violations.len());
            for violation in violations {
                let location = if violation.line > 0 {
                    format!("{}:{}", violation.file, violation.line)
                } else {
                    violation.file.clone()
                };
                println!("  {location}");
                println!("      {}", violation.message);
                println!("      修复：{}", violation.fix);
            }
            println!();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_report_is_clean() {
        let report = Report::default();
        assert!(report.is_clean());
        assert_eq!(report.total(), 0);
        assert!(report.summary_line().contains("OK"));
    }

    #[test]
    fn violations_are_counted_and_grouped() {
        let mut report = Report::default();
        report.extend(
            "R1",
            vec![Violation::new("R1", "a.rs", 3, "uses unwrap()", "use ?")],
        );
        report.extend(
            "R1",
            vec![Violation::new("R1", "b.rs", 9, "uses unwrap()", "use ?")],
        );
        report.extend(
            "D2",
            vec![Violation::new("D2", "c.rs", 1, "raw delete", "soft delete")],
        );

        assert!(!report.is_clean());
        assert_eq!(report.total(), 3);
        assert!(report.summary_line().contains("3 violations"));
    }

    #[test]
    fn relative_paths_are_posix_style() {
        let root = Path::new("/repo");
        let path = Path::new("/repo/client/src/main.rs");
        assert_eq!(Violation::relative(root, path), "client/src/main.rs");
    }

    #[test]
    fn relative_path_outside_root_is_kept() {
        let root = Path::new("/repo");
        let path = Path::new("/elsewhere/file.rs");
        assert_eq!(Violation::relative(root, path), "/elsewhere/file.rs");
    }
}
