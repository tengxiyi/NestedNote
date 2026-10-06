//! 品牌、版本与引擎启动自检 —— P0 阶段的最小可调用面。
//!
//! 这三个函数构成开发计划 P0-5 的验收内容：**从 Dart 调通 Rust 并取回真实数据**。
//! 它们同时也证明了完整链路可用（Dart → FRB → Rust → SQLite 建库/迁移/校验）。

use nested_core::{NestedCore, branding};

/// 版本与品牌信息。
///
/// 字段用 `String` 而非 `&'static str`：`flutter_rust_bridge` 会把返回值转换为
/// Dart 对象，`String` 的映射最直接，也避免把借用语义带过语言边界。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VersionInfo {
    /// 中文品牌名（zh-CN 界面显示）。
    pub name_zh: String,
    /// 英文品牌名（其他语言界面显示）。
    pub name_en: String,
    /// 应用版本（跟随 Cargo 包版本）。
    pub version: String,
    /// 同步协议版本。
    pub protocol_version: u32,
}

/// 返回品牌与版本信息。
#[must_use]
pub fn version_info() -> VersionInfo {
    VersionInfo {
        name_zh: branding::BRAND_NAME_ZH.to_owned(),
        name_en: branding::BRAND_NAME_EN.to_owned(),
        version: branding::APP_VERSION.to_owned(),
        protocol_version: protocol::PROTOCOL_VERSION,
    }
}

/// 按 BCP-47 语言标签返回界面显示名（如 `"zh-CN"` → 拾光笔记）。
///
/// 品牌名只允许有一个来源（项目章程 §1.0）：Dart 侧不得硬编码品牌字符串。
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
    pub checks: Vec<EngineCheck>,
    /// 数据库文件的绝对路径（便于在界面与日志中定位数据）。
    pub database_path: Option<String>,
    /// 出错时的可读提示（**不含**内部细节，铁律 E2）。
    pub message: Option<String>,
}

/// 单项自检结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineCheck {
    /// 检查项名称，如 `"database_open"`。
    pub name: String,
    /// 是否通过。
    pub passed: bool,
}

/// 在指定数据目录启动内核并执行就绪自检。
///
/// FFI 边界**不允许** panic：任何失败都转成 [`EngineStatus`] 返回。
///
/// 这是 P0 阶段最有价值的验收函数：它会在真实目录里建库、执行迁移、
/// 校验完整性，并把结果如实报告给界面。
#[must_use]
pub fn start_engine(data_dir: &str) -> EngineStatus {
    match NestedCore::open(data_dir) {
        Ok(core) => {
            let checks: Vec<EngineCheck> = core
                .readiness()
                .into_iter()
                .map(|(name, passed)| EngineCheck {
                    name: name.to_owned(),
                    passed,
                })
                .collect();
            let ready = checks.iter().all(|check| check.passed);
            EngineStatus {
                ready,
                checks,
                database_path: core.database_path().map(|path| path.display().to_string()),
                message: None,
            }
        }
        Err(error) => EngineStatus {
            ready: false,
            checks: Vec::new(),
            database_path: None,
            message: Some(error.user_hint().to_owned()),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_info_is_non_empty_and_exposes_protocol() {
        let info = version_info();
        assert!(!info.name_zh.is_empty());
        assert!(!info.name_en.is_empty());
        assert!(!info.version.is_empty());
        assert!(info.protocol_version >= 1);
    }

    #[test]
    fn display_name_follows_language() {
        assert_eq!(display_name("zh-CN"), branding::BRAND_NAME_ZH);
        assert_eq!(display_name("zh-Hans-CN"), branding::BRAND_NAME_ZH);
        assert_eq!(display_name("en"), branding::BRAND_NAME_EN);
    }

    #[test]
    fn start_engine_reports_ready_and_creates_database() {
        let dir = tempfile::tempdir().expect("tempdir");
        let status = start_engine(&dir.path().to_string_lossy());

        assert!(status.ready, "空目录应能正常启动：{:?}", status.message);
        assert!(!status.checks.is_empty());
        assert!(
            status.checks.iter().all(|check| check.passed),
            "全部自检项都应通过：{:?}",
            status.checks
        );

        let path = status.database_path.expect("应返回数据库路径");
        assert!(
            std::path::Path::new(&path).exists(),
            "数据库文件应已创建：{path}"
        );
    }

    #[test]
    fn start_engine_is_idempotent_on_existing_directory() {
        let dir = tempfile::tempdir().expect("tempdir");
        let first = start_engine(&dir.path().to_string_lossy());
        assert!(first.ready);
        // 第二次打开已存在的库：迁移不应重复执行，也不应报错
        let second = start_engine(&dir.path().to_string_lossy());
        assert!(second.ready, "重复启动应保持就绪：{:?}", second.message);
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

    #[test]
    fn start_engine_rejects_unwritable_path_without_panicking() {
        // Windows 保留字符路径：必然不可创建
        let status = start_engine(r"Z:\definitely\missing\drive\nested");
        assert!(!status.ready);
        assert!(status.message.is_some());
    }
}
