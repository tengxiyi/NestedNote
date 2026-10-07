//! 品牌、版本与引擎启动自检 —— P0 阶段的最小可调用面。
//!
//! 这三个函数构成开发计划 P0-5 的验收内容：**从 Dart 调通 Rust 并取回真实数据**。
//! 它们同时也证明了完整链路可用（Dart → FRB → Rust → SQLite 建库/迁移/校验）。

use nested_core::branding;

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
///
/// ## 与 [`crate::api::notes::engine_start`] 的关系
///
/// 本函数现在**委托**给 `notes::engine_start`，后者会把内核装进进程级单例，
/// 从而让界面后续能直接调用笔记操作。
///
/// 之所以做这个委托：两个函数各自持有一个 `NestedCore` 就会对同一个数据库
/// 文件打开**两条连接**——写入时容易撞 `SQLITE_BUSY`，也让"引擎是否已启动"
/// 这一状态出现两个互不相知的副本。统一到一处后，"启动"与"使用"看到的是同一个内核。
#[must_use]
pub fn start_engine(data_dir: &str) -> EngineStatus {
    crate::api::notes::engine_start(data_dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 这些测试会**启动全局引擎**，因此必须与 `notes` 的测试串行执行。
    /// 否则一个测试的 `start_engine` 会把另一个测试正在用的引擎换掉，
    /// 表现为"数据丢失"这类极具误导性的失败（详见 `notes::engine_lock_for_tests`）。
    fn lock() -> std::sync::MutexGuard<'static, ()> {
        crate::api::notes::test_support::engine_lock()
    }

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
        let _guard = lock();
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
        let _guard = lock();
        let dir = tempfile::tempdir().expect("tempdir");
        let first = start_engine(&dir.path().to_string_lossy());
        assert!(first.ready);
        // 第二次打开已存在的库：迁移不应重复执行，也不应报错
        let second = start_engine(&dir.path().to_string_lossy());
        assert!(second.ready, "重复启动应保持就绪：{:?}", second.message);
    }

    #[test]
    fn start_engine_reports_failure_without_panicking() {
        let _guard = lock();
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
        let _guard = lock();
        // Windows 保留字符路径：必然不可创建
        let status = start_engine(r"Z:\definitely\missing\drive\nested");
        assert!(!status.ready);
        assert!(status.message.is_some());
    }

    #[test]
    fn start_engine_shares_one_engine_with_note_operations() {
        // 关键不变量：启动引擎后，笔记 API 必须能**立刻**在同一个内核上工作。
        // 若两者各持一个 NestedCore（曾经如此），就会对同一数据库文件打开两条连接，
        // 而且"启动成功但写不进去"这种故障极难定位。
        let _guard = lock();
        let dir = tempfile::tempdir().expect("tempdir");
        assert!(start_engine(&dir.path().to_string_lossy()).ready);

        let created = crate::api::notes::notes_create(None, "共享引擎", 1_700_000_000_000);
        assert!(
            created.ok,
            "笔记应能在启动后的引擎上创建：{:?}",
            created.hint
        );
        assert_eq!(crate::api::notes::notes_count(), 1);
    }
}
