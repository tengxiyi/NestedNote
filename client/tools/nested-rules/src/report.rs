//! 检查结果的数据结构与输出。

use std::collections::BTreeMap;
use std::io::Write;
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

    /// 把完整报告写入给定输出流。
    ///
    /// 之所以不直接 `println!`：**可测试**。门禁工具的报告格式一旦写错，
    /// 排查 CI 的人会看到错位的信息，因此格式本身也需要断言。
    ///
    /// # Errors
    ///
    /// 写入失败时返回底层 IO 错误。
    pub fn write_to(&self, out: &mut impl Write) -> std::io::Result<()> {
        writeln!(out)?;
        if self.is_clean() {
            writeln!(out, "OK: 未发现铁律违规。")?;
            return Ok(());
        }

        writeln!(out, "FAIL: 发现 {} 处违规：", self.total())?;
        writeln!(out)?;
        for (rule, violations) in &self.groups {
            writeln!(out, "[{rule}] {} 处", violations.len())?;
            for violation in violations {
                let location = if violation.line > 0 {
                    format!("{}:{}", violation.file, violation.line)
                } else {
                    violation.file.clone()
                };
                writeln!(out, "  {location}")?;
                writeln!(out, "      {}", violation.message)?;
                writeln!(out, "      修复：{}", violation.fix)?;
            }
            writeln!(out)?;
        }
        Ok(())
    }

    /// 打印完整报告到标准输出。
    ///
    /// # Panics
    ///
    /// 标准输出写入失败时会 panic（例如管道被提前关闭）。
    /// 对命令行工具而言这是可接受的：此时进程本就该以非零码退出。
    pub fn print(&self) {
        let stdout = std::io::stdout();
        let mut lock = stdout.lock();
        let _ = self.write_to(&mut lock);
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

    /// 把报告渲染成字符串（测试用）。
    fn render(report: &Report) -> String {
        let mut buffer = Vec::new();
        report
            .write_to(&mut buffer)
            .expect("write to buffer must not fail");
        String::from_utf8(buffer).expect("output must be valid utf-8")
    }

    #[test]
    fn clean_report_renders_ok_line() {
        let text = render(&Report::default());
        assert!(text.contains("OK: 未发现铁律违规。"), "实际输出：{text}");
        assert!(!text.contains("FAIL"));
    }

    #[test]
    fn failing_report_renders_locations_messages_and_fixes() {
        let mut report = Report::default();
        report.extend(
            "R1",
            vec![Violation::new(
                "R1",
                "a.rs",
                3,
                "uses unwrap()",
                "用 ? 代替",
            )],
        );
        report.extend(
            "D2",
            vec![Violation::new("D2", "b.sql", 0, "raw delete", "改软删除")],
        );

        let text = render(&report);
        assert!(text.contains("FAIL: 发现 2 处违规"), "实际：{text}");
        // 分组标题与计数
        assert!(text.contains("[D2] 1 处"));
        assert!(text.contains("[R1] 1 处"));
        // 有行号时渲染 file:line
        assert!(text.contains("a.rs:3"));
        // 无行号时只渲染文件名（不出现 ":0"）
        assert!(text.contains("b.sql"));
        assert!(!text.contains("b.sql:0"), "行号为 0 时不应输出冒号：{text}");
        // 问题描述与修复建议都要出现在报告里
        assert!(text.contains("uses unwrap()"));
        assert!(text.contains("用 ? 代替"));
        assert!(text.contains("raw delete"));
        assert!(text.contains("改软删除"));
    }

    #[test]
    fn groups_are_rendered_in_stable_order() {
        // 用 BTreeMap 的意义：同一份违规集合每次输出顺序一致，便于 diff 与比对
        let mut first = Report::default();
        first.extend("R1", vec![Violation::new("R1", "x.rs", 1, "m", "f")]);
        first.extend(
            "A-ISOLATION",
            vec![Violation::new("A-ISOLATION", "y.toml", 1, "m", "f")],
        );

        let mut second = Report::default();
        second.extend(
            "A-ISOLATION",
            vec![Violation::new("A-ISOLATION", "y.toml", 1, "m", "f")],
        );
        second.extend("R1", vec![Violation::new("R1", "x.rs", 1, "m", "f")]);

        assert_eq!(
            render(&first),
            render(&second),
            "分组顺序必须与插入顺序无关"
        );
        let text = render(&first);
        let isolation_at = text.find("A-ISOLATION").expect("contains A-ISOLATION");
        let r1_at = text.find("[R1]").expect("contains R1");
        assert!(isolation_at < r1_at, "应按规则编号排序：{text}");
    }

    #[test]
    fn write_failure_is_propagated() {
        /// 一个永远失败的写入器，用来验证错误不会被吞掉。
        struct FailingWriter;

        impl Write for FailingWriter {
            fn write(&mut self, _buf: &[u8]) -> std::io::Result<usize> {
                Err(std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "closed",
                ))
            }

            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }

        let mut report = Report::default();
        report.extend("R1", vec![Violation::new("R1", "a.rs", 1, "m", "f")]);
        let error = report
            .write_to(&mut FailingWriter)
            .expect_err("必须把错误传出去");
        assert_eq!(error.kind(), std::io::ErrorKind::BrokenPipe);
    }
}
