//! 品牌信息**唯一来源**（项目章程 §1.0）。
//!
//! ## 为什么单独一个模块
//!
//! 品牌名可能因商标或市场原因调整，而工程标识（crate 名、包名、数据目录、协议字段）
//! 一旦落地改动代价极高。因此：
//!
//! - **业务代码禁止**硬编码 "拾光笔记" / "NestedNote" 等品牌字符串；
//! - 一律引用本模块常量；
//! - 未来的客户端配置也应从这里读取应用显示名。

/// 中文品牌名（zh-CN 界面显示）。
pub const BRAND_NAME_ZH: &str = "拾光笔记";

/// 英文品牌名（其他语言界面显示）。
pub const BRAND_NAME_EN: &str = "NestedNote";

/// 品牌 slug：用于数据目录名、安装包名、日志标识。
pub const BRAND_SLUG: &str = "NestedNote";

/// 工程标识：用于仓库、crate、包名、数据库文件名与环境变量。
pub const ENGINEERING_ID: &str = "nested";

/// 本地数据库文件名。
pub const DATABASE_FILE: &str = "nested.db";

/// 应用版本（跟随 Cargo 包版本）。
pub const APP_VERSION: &str = env!("CARGO_PKG_VERSION");

/// 一句话定位（可用于关于页）。
pub const TAGLINE_ZH: &str = "拾起每一段时光，层层收好";

/// 按语言返回显示名。
///
/// `language_tag` 采用 BCP-47 形式（如 `"zh-CN"`、`"en"`）；匹配前缀 `zh` 即用中文名。
#[must_use]
pub fn display_name(language_tag: &str) -> &'static str {
    if language_tag.to_ascii_lowercase().starts_with("zh") {
        BRAND_NAME_ZH
    } else {
        BRAND_NAME_EN
    }
}

/// 版本字符串，形如 `"NestedNote 0.1.0"`。
#[must_use]
pub fn version_string() -> String {
    format!("{BRAND_NAME_EN} {APP_VERSION}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chinese_locales_get_chinese_name() {
        assert_eq!(display_name("zh-CN"), BRAND_NAME_ZH);
        assert_eq!(display_name("zh-Hans-CN"), BRAND_NAME_ZH);
        assert_eq!(display_name("zh"), BRAND_NAME_ZH);
    }

    #[test]
    fn other_locales_get_english_name() {
        assert_eq!(display_name("en-US"), BRAND_NAME_EN);
        assert_eq!(display_name("ja"), BRAND_NAME_EN);
        assert_eq!(display_name(""), BRAND_NAME_EN);
    }

    #[test]
    fn version_string_contains_app_version() {
        assert!(version_string().contains(env!("CARGO_PKG_VERSION")));
        assert!(version_string().starts_with(BRAND_NAME_EN));
    }

    #[test]
    fn engineering_id_stays_neutral() {
        // 工程标识必须与品牌解耦，否则改名会波及 crate / 数据库 / 数据目录
        assert_eq!(ENGINEERING_ID, "nested");
        assert_ne!(BRAND_SLUG, ENGINEERING_ID);
    }
}
