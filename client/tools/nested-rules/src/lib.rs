//! # nested-rules —— 铁律自动检查器（库）
//!
//! 把《工程铁律》里**可机械检查**的条款变成可执行门禁。设计要点：
//!
//! 1. **零依赖**：只用标准库。门禁工具本身绝不能成为 CI 里最脆弱的一环。
//! 2. **只查产品代码**：`src/` 下的文件，且跳过 `#[cfg(test)]` 模块。
//!    测试里出现 `expect()` 是正确做法，不该被拦。
//! 3. **错误信息可执行**：每条违规都给出文件、行号、违反了哪条铁律、怎么改。
//! 4. **宁可漏报，不可误报**：门禁一旦经常误报，开发者就会开始绕过它。
//!
//! ## 为什么不用 PowerShell 实现
//!
//! 最初的版本是 `scripts/check-rules.ps1`。它有两个问题：
//! - Windows PowerShell 5.1 会把无 BOM 的 UTF-8 脚本按 ANSI 解码，中文直接乱码；
//! - 它的错误定位只能给到"脚本第几行"，排查成本高。
//!
//! 因此权威实现改为 Rust（跨平台、可测试、编码无关），PowerShell 脚本保留
//! 供本地快速自检。

#![forbid(unsafe_code)]
// 检查器是命令行工具：它的产物就是给人看的文本报告，
// 因此这里是仓库中**唯一**允许直接写标准输出的库（铁律 E4 约束的是业务日志）。
#![allow(clippy::print_stdout)]

pub mod checks;
pub mod fsutil;
pub mod report;
pub mod rules;

use std::path::PathBuf;

pub use report::{Report, Violation};

/// 检查器选项。
#[derive(Debug, Clone)]
pub struct Options {
    /// 仓库根目录。
    pub root: PathBuf,
    /// 是否在检查前输出进度标题。
    pub verbose: bool,
}

impl Options {
    /// 构造默认选项（输出进度）。
    #[must_use]
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            verbose: true,
        }
    }
}

/// 从当前目录向上查找仓库根（同时含 `client` 与 `server` 子目录）。
#[must_use]
pub fn find_repo_root() -> Option<PathBuf> {
    let mut current = std::env::current_dir().ok()?;
    loop {
        if current.join("client").is_dir() && current.join("server").is_dir() {
            return Some(current);
        }
        if !current.pop() {
            return None;
        }
    }
}

/// 执行全部检查。
#[must_use]
pub fn run(options: &Options) -> Report {
    let mut report = Report::default();

    for rule in rules::ALL {
        if options.verbose {
            println!("== {} ==", rule.title);
        }
        let violations = (rule.run)(&options.root);
        report.extend(rule.id, violations);
    }

    report
}
