//! # nested-app —— Flutter ↔ Rust 桥接层
//!
//! **状态**：P0 提供最小可调用面（品牌、版本、就绪自检）。
//! 完整的 `flutter_rust_bridge` 绑定生成将在 Flutter 工具链就绪后接入
//! （见开发计划 P0-5）。
//!
//! ## 契约要求（铁律 A3 / A4）
//!
//! - 只暴露**业务语义**函数，不暴露 `execute_sql` 之类的实现细节；
//! - 跨边界只传可序列化的简单结构，不传裸指针、不传数据库句柄；
//! - 所有函数**禁止** panic：错误一律以结构化结果返回（铁律 E1）。

#![forbid(unsafe_code)]

use nested_core::{NestedCore, branding};

/// 版本信息（键值对，便于跨 FFI 传递）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VersionInfo {
    /// 中文品牌名。
    pub name_zh: String,
    /// 英文品牌名。
    pub name_en: String,
    /// 应用版本。
    pub version: String,
}

/// 返回品牌与版本信息。
#[must_use]
pub fn version_info() -> VersionInfo {
    VersionInfo {
        name_zh: branding::BRAND_NAME_ZH.to_owned(),
        name_en: branding::BRAND_NAME_EN.to_owned(),
        version: branding::APP_VERSION.to_owned(),
    }
}

/// 返回操作界面显示名（按 BCP-47 语言标签）。
#[must_use]
pub fn display_name(language_tag: &str) -> String {
    branding::display_name(language_tag).to_owned()
}

/// 引擎启动自检结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineStatus {
    /// 是否全部检查通过。
    pub ready: bool,
    /// 逐项检查结果（名称，是否通过）。
    pub checks: Vec<(String, bool)>,
    /// 出错时的可读信息（**不含**内部细节，铁律 E2）。
    pub message: Option<String>,
}

/// 在给定数据目录启动内核并执行就绪自检。
///
/// FFI 边界**不允许** panic：任何失败都转成 [`EngineStatus`] 返回。
#[must_use]
pub fn start_engine(data_dir: &str) -> EngineStatus {
    match NestedCore::open(data_dir) {
        Ok(core) => {
            let checks: Vec<(String, bool)> = core
                .readiness()
                .into_iter()
                .map(|(name, ok)| (name.to_owned(), ok))
                .collect();
            let ready = checks.iter().all(|(_, ok)| *ok);
            EngineStatus {
                ready,
                checks,
                message: None,
            }
        }
        Err(error) => EngineStatus {
            ready: false,
            checks: Vec::new(),
            message: Some(error.user_hint().to_owned()),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_info_is_non_empty() {
        let info = version_info();
        assert!(!info.name_zh.is_empty());
        assert!(!info.name_en.is_empty());
        assert!(!info.version.is_empty());
    }

    #[test]
    fn display_name_follows_language() {
        assert_eq!(display_name("zh-CN"), branding::BRAND_NAME_ZH);
        assert_eq!(display_name("en"), branding::BRAND_NAME_EN);
    }

    #[test]
    fn start_engine_reports_ready_on_writable_dir() {
        let dir = tempfile::tempdir().expect("tempdir");
        let status = start_engine(&dir.path().to_string_lossy());
        assert!(status.ready, "空目录应能正常启动：{:?}", status.message);
        assert!(!status.checks.is_empty());
    }

    #[test]
    fn start_engine_reports_failure_without_panicking() {
        // 用一个"父路径是文件"的非法目录触发失败
        let dir = tempfile::tempdir().expect("tempdir");
        let file_path = dir.path().join("not-a-dir");
        std::fs::write(&file_path, b"x").expect("write file");
        let status = start_engine(&file_path.join("sub").to_string_lossy());
        assert!(!status.ready);
        assert!(
            status.message.is_some(),
            "失败必须给出可读信息，而不是 panic"
        );
    }
}
