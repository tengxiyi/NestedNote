//! 文件系统遍历与源码预处理（零依赖）。

use std::path::{Path, PathBuf};

/// 遍历时**必须**跳过的目录名。
///
/// 这些是构建产物、依赖与版本库元数据：扫描它们既慢又会误报。
/// 特别注意 `ephemeral` 与 `build`：Flutter 生成的目录里含有大量第三方代码。
const SKIP_DIRS: &[&str] = &[
    "target",
    "node_modules",
    ".git",
    ".probe",
    "ephemeral",
    "build",
    "Pods",
    ".dart_tool",
    ".gradle",
    ".idea",
    ".vs",
];

/// 判断路径是否位于需跳过的目录内。
#[must_use]
pub fn is_skipped(path: &Path) -> bool {
    path.components().any(|component| {
        component
            .as_os_str()
            .to_str()
            .is_some_and(|name| SKIP_DIRS.contains(&name))
    })
}

/// 递归收集匹配扩展名的文件。
///
/// # Errors
///
/// 目录不可读时跳过该分支（不中断整次检查）；根目录本身不存在时返回空列表。
#[must_use]
pub fn collect_files(root: &Path, extension: &str) -> Vec<PathBuf> {
    let mut files = Vec::new();
    walk(root, extension, &mut files);
    files.sort();
    files
}

fn walk(dir: &Path, extension: &str, out: &mut Vec<PathBuf>) {
    if is_skipped(dir) {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() {
            walk(&path, extension, out);
        } else if file_type.is_file()
            && path
                .extension()
                .and_then(|ext| ext.to_str())
                .is_some_and(|ext| ext.eq_ignore_ascii_case(extension))
        {
            out.push(path);
        }
    }
}

/// 按文件名递归收集文件。
#[must_use]
pub fn collect_named(root: &Path, file_name: &str) -> Vec<PathBuf> {
    let mut files = Vec::new();
    walk_named(root, file_name, &mut files);
    files.sort();
    files
}

fn walk_named(dir: &Path, file_name: &str, out: &mut Vec<PathBuf>) {
    if is_skipped(dir) {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() {
            walk_named(&path, file_name, out);
        } else if file_type.is_file()
            && path.file_name().and_then(|name| name.to_str()) == Some(file_name)
        {
            out.push(path);
        }
    }
}

/// 读取文本文件（UTF-8，允许有 BOM）。
#[must_use]
pub fn read_text(path: &Path) -> Option<String> {
    let bytes = std::fs::read(path).ok()?;
    let bytes = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(&bytes);
    String::from_utf8(bytes.to_vec()).ok()
}

/// 源码行及其原始行号。
#[derive(Debug, Clone)]
pub struct SourceLine {
    /// 1 起的行号。
    pub number: usize,
    /// 行内容。
    pub text: String,
    /// 该行是否位于 `#[cfg(test)]` 模块内。
    pub in_test_module: bool,
}

/// 读取源码并标注每行是否属于测试模块。
///
/// 判定方式：遇到 `#[cfg(test)]` 后开始计数花括号，归零时认为测试模块结束。
/// 这对本项目的代码风格足够可靠（测试模块总是文件末尾的一个 `mod tests { ... }`）。
#[must_use]
pub fn read_annotated_lines(path: &Path) -> Vec<SourceLine> {
    let Some(text) = read_text(path) else {
        return Vec::new();
    };

    let mut lines = Vec::new();
    let mut in_test_module = false;
    let mut depth: i64 = 0;

    for (index, raw) in text.lines().enumerate() {
        let trimmed = raw.trim_start();

        if trimmed.starts_with("#[cfg(test)]") {
            in_test_module = true;
            depth = 0;
            lines.push(SourceLine {
                number: index + 1,
                text: raw.to_owned(),
                in_test_module: true,
            });
            continue;
        }

        if in_test_module {
            depth += count_char(raw, '{') - count_char(raw, '}');
            if depth <= 0 && raw.contains('}') {
                in_test_module = false;
            }
            lines.push(SourceLine {
                number: index + 1,
                text: raw.to_owned(),
                in_test_module: true,
            });
            continue;
        }

        lines.push(SourceLine {
            number: index + 1,
            text: raw.to_owned(),
            in_test_module: false,
        });
    }

    lines
}

fn count_char(text: &str, needle: char) -> i64 {
    i64::try_from(text.chars().filter(|c| *c == needle).count()).unwrap_or(0)
}

/// 去掉行内的注释部分（`//` 起始）。
///
/// 刻意**不**处理块注释与字符串字面量中的 `//`（例如 URL）：本项目里
/// 这类情况极少，而为此写一个完整词法分析器不值得。若将来误报变多，
/// 再引入真正的词法分析（铁律 P2：先测量再优化）。
#[must_use]
pub fn strip_line_comment(line: &str) -> &str {
    match line.find("//") {
        Some(index) => &line[..index],
        None => line,
    }
}

/// 判断一行是否为纯注释行。
#[must_use]
pub fn is_comment_line(line: &str) -> bool {
    let trimmed = line.trim_start();
    trimmed.starts_with("//") || trimmed.starts_with('#') || trimmed.is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skip_dirs_are_detected_anywhere_in_path() {
        assert!(is_skipped(Path::new("/repo/client/target/debug/foo.rs")));
        assert!(is_skipped(Path::new("/repo/.git/config")));
        assert!(!is_skipped(Path::new("/repo/client/src/main.rs")));
    }

    #[test]
    fn line_comments_are_stripped() {
        assert_eq!(strip_line_comment("let x = 1; // unwrap()"), "let x = 1; ");
        assert_eq!(strip_line_comment("let x = 1;"), "let x = 1;");
    }

    #[test]
    fn comment_lines_are_recognized() {
        assert!(is_comment_line("// 说明"));
        assert!(is_comment_line("   // 缩进注释"));
        assert!(is_comment_line(""));
        assert!(!is_comment_line("let x = 1;"));
    }

    #[test]
    fn test_module_detection_marks_following_lines() {
        let dir = std::env::temp_dir().join("nested-rules-test-annotate");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("sample.rs");
        let content = "fn prod() {}\n\n#[cfg(test)]\nmod tests {\n    fn helper() {\n        let x = 1;\n    }\n}\n\nfn after() {}\n";
        std::fs::write(&path, content).expect("write sample");

        let lines = read_annotated_lines(&path);
        let prod_line = lines
            .iter()
            .find(|l| l.text.contains("fn prod"))
            .expect("prod line");
        assert!(!prod_line.in_test_module, "产品代码不应被标为测试模块");

        let helper = lines
            .iter()
            .find(|l| l.text.contains("let x = 1"))
            .expect("helper line");
        assert!(helper.in_test_module, "测试模块内的行必须被标注");

        let after = lines
            .iter()
            .find(|l| l.text.contains("fn after"))
            .expect("after line");
        assert!(!after.in_test_module, "测试模块结束后应恢复");

        let _ = std::fs::remove_file(&path);
    }
}
