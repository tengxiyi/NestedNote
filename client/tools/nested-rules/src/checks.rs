//! 全部检查实现。
//!
//! 设计原则：**宁可漏报，不可误报**。门禁一旦经常误报，开发者就会开始
//! 绕过它（`--no-verify`、`#[allow]` 泛滥），门禁就名存实亡。
//! 因此每条检查都刻意保守，并在文档里写清它**不**覆盖什么。

use std::path::Path;

use crate::fsutil::{self, is_comment_line, strip_line_comment};
use crate::report::Violation;

/// 产品代码目录（只检查这些路径下的源码）。
const PRODUCTION_ROOTS: &[&str] = &[
    "client/crates",
    "client/cli",
    "client/apps/rust",
    "server",
    "shared",
];

/// 允许出现裸 `DELETE FROM` 的表。
///
/// 这些是**纯关联表**：它们没有独立生命周期，行的存在与否完全由两侧实体决定，
/// 因此物理删除不会造成"数据无法恢复"的问题（铁律 D2 针对的是业务实体）。
/// 反向引用表（`note_attachments`）同理：附件本体在 CAS 中，引用消失只是解除关联。
const DELETE_ALLOWED_TABLES: &[&str] = &["note_tags", "note_attachments"];

/// 允许字符串插值构造 SQL 的已知常量（列清单等）。
const SQL_INTERPOLATION_ALLOWED: &[&str] = &["COLUMNS", "columns"];

/// 单个文件的体积上限（5 MiB，铁律 V6）。
const MAX_FILE_BYTES: u64 = 5 * 1024 * 1024;

/// 判断某个相对路径是否指向**生成代码**。
///
/// 生成代码不是人写的，既不该按手写标准要求，改也改不动（下次生成就覆盖）。
/// 目前唯一的生成物是 flutter_rust_bridge 的 `frb_generated.rs`。
#[must_use]
fn is_generated(relative_path: &str) -> bool {
    let file_name = relative_path.rsplit('/').next().unwrap_or(relative_path);
    file_name.contains("generated")
}

/// R1：产品代码不得出现 `unwrap()` / `expect()` / `panic!` / `todo!` / `unimplemented!`。
///
/// 覆盖范围：`src/` 下的 `.rs` 文件，**排除**：
/// - `#[cfg(test)]` 模块（测试里 panic 是正确做法）；
/// - 生成代码（文件名含 `generated`，如 FRB 产出的 `frb_generated.rs`）。
///
/// 不覆盖：`tests/` 与 `benches/` 目录（测试里 panic 是正确做法）。
#[must_use]
pub fn panic_free_production_code(root: &Path) -> Vec<Violation> {
    let mut violations = Vec::new();

    for production_root in PRODUCTION_ROOTS {
        let dir = root.join(production_root);
        if !dir.is_dir() {
            continue;
        }
        for file in fsutil::collect_files(&dir, "rs") {
            let relative = Violation::relative(root, &file);
            if !relative.contains("/src/") || is_generated(&relative) {
                continue;
            }

            for line in fsutil::read_annotated_lines(&file) {
                if line.in_test_module || is_comment_line(&line.text) {
                    continue;
                }
                let code = strip_line_comment(&line.text);

                for (needle, rule, fix) in [
                    (
                        ".unwrap()",
                        "R1",
                        "改用 `?` 或显式 map 错误；确实不可失败时写注释说明并返回 Result",
                    ),
                    (
                        ".expect(",
                        "R1",
                        "返回结构化错误（thiserror）而不是 panic；库层禁止 expect",
                    ),
                    ("panic!(", "R1", "返回结构化错误，由上层决定如何呈现给用户"),
                    (
                        "todo!(",
                        "E6",
                        "返回明确的 NotImplemented 错误，禁止用 todo! 掩盖未实现",
                    ),
                    ("unimplemented!(", "E6", "返回明确的 NotImplemented 错误"),
                    ("dbg!(", "R13", "删除调试宏；需要日志请用 tracing"),
                ] {
                    if code.contains(needle) {
                        violations.push(Violation::new(
                            rule,
                            relative.clone(),
                            line.number,
                            format!("产品代码中出现 `{needle}`"),
                            fix,
                        ));
                    }
                }
            }
        }
    }

    violations
}

/// D2：`client/` 下不得出现针对业务表的裸 `DELETE FROM`。
///
/// 允许：`note_tags`（关联表）；`src/` 之外的文件（迁移 SQL 与测试）。
/// 物理回收只能出现在未来的 GC 模块中（铁律 D2）。
#[must_use]
pub fn no_raw_delete(root: &Path) -> Vec<Violation> {
    let mut violations = Vec::new();
    let dir = root.join("client");
    if !dir.is_dir() {
        return violations;
    }

    for file in fsutil::collect_files(&dir, "rs") {
        let relative = Violation::relative(root, &file);
        if !relative.contains("/src/") {
            continue;
        }

        for line in fsutil::read_annotated_lines(&file) {
            if line.in_test_module || is_comment_line(&line.text) {
                continue;
            }
            let code = strip_line_comment(&line.text).to_ascii_uppercase();
            let Some(index) = code.find("DELETE FROM ") else {
                continue;
            };
            let rest = &code[index + "DELETE FROM ".len()..];
            let table: String = rest
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                .collect();
            let table_lower = table.to_ascii_lowercase();

            if table.is_empty() || DELETE_ALLOWED_TABLES.contains(&table_lower.as_str()) {
                continue;
            }

            violations.push(Violation::new(
                "D2",
                relative.clone(),
                line.number,
                format!("对表 `{table_lower}` 执行了裸 DELETE"),
                "改用软删除（写 deleted_at_ms）；物理回收只允许出现在 GC 模块并需保留期",
            ));
        }
    }

    violations
}

/// Q4：不得用 `format!` 插值构造 SQL。
///
/// 判定：同一行同时出现 `format!` 与 SQL 关键字，且插值占位符不是白名单常量。
/// 允许：`format!("SELECT {COLUMNS} ...")` 这类由常量拼装的语句（本项目统一用大写常量名）。
#[must_use]
pub fn no_interpolated_sql(root: &Path) -> Vec<Violation> {
    let mut violations = Vec::new();
    let dir = root.join("client");
    if !dir.is_dir() {
        return violations;
    }

    for file in fsutil::collect_files(&dir, "rs") {
        let relative = Violation::relative(root, &file);
        if !relative.contains("/src/") {
            continue;
        }

        for line in fsutil::read_annotated_lines(&file) {
            if line.in_test_module || is_comment_line(&line.text) {
                continue;
            }
            let code = strip_line_comment(&line.text);
            if !code.contains("format!") {
                continue;
            }
            let upper = code.to_ascii_uppercase();
            let has_sql_keyword = upper.contains("SELECT ")
                || upper.contains("INSERT INTO")
                || upper.contains("DELETE FROM")
                || (upper.contains("UPDATE ") && upper.contains(" SET "));
            if !has_sql_keyword {
                continue;
            }

            // 提取所有 {name} 形式的占位符，若全部在白名单内则放行
            let placeholders = extract_placeholders(code);
            if !placeholders.is_empty()
                && placeholders
                    .iter()
                    .all(|name| SQL_INTERPOLATION_ALLOWED.contains(&name.as_str()))
            {
                continue;
            }

            violations.push(Violation::new(
                "Q4",
                relative.clone(),
                line.number,
                format!(
                    "用 format! 插值构造 SQL（占位符：{}）",
                    placeholders.join(", ")
                ),
                "用参数绑定（params!/bind）；表名与排序字段必须来自白名单枚举",
            ));
        }
    }

    violations
}

/// 提取 `format!` 字符串中的 `{name}` 占位符（忽略 `{}` 与 `{0}`）。
fn extract_placeholders(code: &str) -> Vec<String> {
    let mut names = Vec::new();
    let mut chars = code.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '{' {
            continue;
        }
        let mut name = String::new();
        while let Some(&next) = chars.peek() {
            if next == '}' {
                chars.next();
                break;
            }
            name.push(next);
            chars.next();
        }
        let trimmed = name.trim();
        if !trimmed.is_empty()
            && trimmed
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_')
            && !trimmed.chars().next().is_some_and(|c| c.is_ascii_digit())
        {
            names.push(trimmed.to_owned());
        }
    }
    names
}

/// A-ISOLATION：客户端与服务端互为禁区（技术文档 §4.2 硬约束 3）。
///
/// 检查三件事：
/// 1. `client/**/Cargo.toml` 不得依赖 `server-*` 或 sqlx/axum/tokio-postgres；
/// 2. `server/**/Cargo.toml` 不得依赖 `nested-*` 或 rusqlite；
/// 3. `shared/protocol/Cargo.toml` 不得引入 IO/数据库/网络依赖。
#[must_use]
pub fn workspace_isolation(root: &Path) -> Vec<Violation> {
    let mut violations = Vec::new();

    for manifest in fsutil::collect_named(&root.join("client"), "Cargo.toml") {
        let relative = Violation::relative(root, &manifest);
        let Some(text) = fsutil::read_text(&manifest) else {
            continue;
        };
        for (needle, what) in [
            ("server-core", "服务端 crate"),
            ("server-api", "服务端 crate"),
            ("server-auth", "服务端 crate"),
            ("server-sync", "服务端 crate"),
            ("server-storage", "服务端 crate"),
            ("sqlx", "服务端数据库库"),
            ("axum", "服务端 Web 框架"),
            ("tokio-postgres", "服务端数据库驱动"),
        ] {
            if mentions_dependency(&text, needle) {
                violations.push(Violation::new(
                    "A-ISOLATION",
                    relative.clone(),
                    1,
                    format!("客户端依赖了{what} `{needle}`"),
                    "客户端与服务端必须完全隔离（技术文档 §4.2）：删除该依赖",
                ));
            }
        }
    }

    for manifest in fsutil::collect_named(&root.join("server"), "Cargo.toml") {
        let relative = Violation::relative(root, &manifest);
        let Some(text) = fsutil::read_text(&manifest) else {
            continue;
        };
        for needle in [
            "nested-core",
            "nested-model",
            "nested-db",
            "nested-search",
            "nested-attachment",
            "nested-import",
            "nested-export",
            "nested-sync",
            "nested-crypto",
            "rusqlite",
        ] {
            if mentions_dependency(&text, needle) {
                violations.push(Violation::new(
                    "A-ISOLATION",
                    relative.clone(),
                    1,
                    format!("服务端依赖了客户端 crate/库 `{needle}`"),
                    "服务端不得依赖客户端实现；如需共享，只能放进 shared/protocol 的纯数据契约",
                ));
            }
        }
    }

    let protocol_manifest = root.join("shared/protocol/Cargo.toml");
    if let Some(text) = fsutil::read_text(&protocol_manifest) {
        let relative = Violation::relative(root, &protocol_manifest);
        for needle in ["tokio", "sqlx", "axum", "rusqlite", "reqwest", "hyper"] {
            if mentions_dependency(&text, needle) {
                violations.push(Violation::new(
                    "A-ISOLATION",
                    relative.clone(),
                    1,
                    format!("shared/protocol 引入了 IO/数据库/网络依赖 `{needle}`"),
                    "该 crate 必须是纯数据契约（技术文档 §4.2 硬约束 2）",
                ));
            }
        }
    }

    violations
}

/// 判断清单文本是否**声明了**某个依赖（而不是出现在注释或路径里）。
///
/// 逐行扫描 `[dependencies*]` 段，遇到 `needle` 作为依赖名开头即判定命中。
/// 这样可以避免把注释里提到的名字误判为依赖。
fn mentions_dependency(manifest: &str, needle: &str) -> bool {
    let mut in_dependency_section = false;
    for line in manifest.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            in_dependency_section = trimmed.contains("dependencies");
            continue;
        }
        if !in_dependency_section || trimmed.starts_with('#') {
            continue;
        }
        let name = trimmed.split(['=', '.']).next().unwrap_or("").trim();
        if name == needle {
            return true;
        }
    }
    false
}

/// 该文件是否属于"自带密钥检查关键字"的位置，应当跳过 S3 扫描。
///
/// 两类：
/// 1. **检查器自身**（`tools/nested-rules`）：源码里必然写着它要搜索的模式；
/// 2. **仓库脚本**（`scripts/*.ps1`）：脚本里会出现"如何传入令牌"的**用法示例**
///    （例如提示用户设置 `GITHUB_TOKEN` 的那行）。这些是给人看的说明，不是凭据。
///
/// 跳过它们的代价：脚本目录内的**真实**硬编码凭据不会被这条规则拦住。
/// 这是刻意的取舍——门禁一旦经常误报，开发者就会开始绕过它（见本 crate 的设计原则）。
/// 真实凭据的兜底由 `cargo audit` 的依赖审计与提交前检查承担。
#[must_use]
fn skips_secret_scan(relative_path: &str) -> bool {
    relative_path.starts_with("scripts/") || relative_path.contains("tools/nested-rules")
}

/// S3：禁止硬编码凭据。
///
/// 保守判定：形如 `password = "…"`、`api_key: "…"`、内联口令的连接串、私钥块。
/// 显式标注 example/placeholder/dummy 的行放行（样例文件需要）。
///
/// **自身豁免**：见 [`skips_secret_scan`]。
#[must_use]
pub fn no_hardcoded_secrets(root: &Path) -> Vec<Violation> {
    let mut violations = Vec::new();
    let extensions = ["rs", "toml", "dart", "yml", "yaml", "json", "sql", "ps1"];

    for extension in extensions {
        for file in fsutil::collect_files(root, extension) {
            let relative = Violation::relative(root, &file);
            if skips_secret_scan(&relative) {
                continue;
            }
            let Some(text) = fsutil::read_text(&file) else {
                continue;
            };

            for (index, raw) in text.lines().enumerate() {
                if is_comment_line(raw) {
                    continue;
                }
                let lowered = raw.to_ascii_lowercase();
                if [
                    "example",
                    "placeholder",
                    "dummy",
                    "change-me",
                    "xxx",
                    "your-",
                ]
                .iter()
                .any(|marker| lowered.contains(marker))
                {
                    continue;
                }

                if contains_private_key_block(raw) {
                    violations.push(Violation::new(
                        "S3",
                        relative.clone(),
                        index + 1,
                        "文件中出现私钥内容",
                        "私钥绝不允许入库（铁律 S3/B8）；请从仓库移除并轮换密钥",
                    ));
                    continue;
                }

                if let Some(kind) = looks_like_assigned_secret(raw) {
                    violations.push(Violation::new(
                        "S3",
                        relative.clone(),
                        index + 1,
                        format!("疑似硬编码凭据（{kind}）"),
                        "凭据必须来自环境变量或平台安全存储（铁律 S3/D11）",
                    ));
                }
            }
        }
    }

    violations
}

/// 判定一行是否是 PEM 私钥块的起始标记。
///
/// 刻意把标记拆开拼接：检查器自身的源码里不应出现完整的 PEM 头，
/// 否则"检查自己"会永远失败（虽然已按目录豁免，这里再加一层保险）。
fn contains_private_key_block(line: &str) -> bool {
    let begin = concat!("-----BE", "GIN");
    let key_kind = concat!("PRIVATE", " KEY-----");
    line.contains(begin) && line.contains(key_kind)
}

/// 判定一行是否是"把长字符串赋给敏感字段"。
fn looks_like_assigned_secret(line: &str) -> Option<&'static str> {
    let lowered = line.to_ascii_lowercase();
    let sensitive = [
        ("password", "password"),
        ("passwd", "password"),
        ("secret", "secret"),
        ("api_key", "api key"),
        ("apikey", "api key"),
        ("access_key", "access key"),
        ("token", "token"),
        ("private_key", "private key"),
    ];

    let (keyword, kind) = sensitive
        .iter()
        .find(|(keyword, _)| lowered.contains(keyword))?;

    // 必须是"赋值"形式：keyword 后面紧跟 = 或 :
    let after_keyword = &lowered[lowered.find(keyword).unwrap_or(0) + keyword.len()..];
    let after_trimmed = after_keyword.trim_start();
    if !(after_trimmed.starts_with('=') || after_trimmed.starts_with(':')) {
        return None;
    }

    // 且右侧有足够长的字符串字面量（避免把字段名或空值当凭据）
    let value_part = after_trimmed[1..].trim_start();
    let quote = value_part.chars().next()?;
    if quote != '"' && quote != '\'' {
        return None;
    }
    let rest = &value_part[1..];
    let value_len = rest.find(quote).unwrap_or(0);
    if value_len >= 8 { Some(kind) } else { None }
}

/// B1：必需的工具链与锁定文件必须存在。
#[must_use]
pub fn required_files_present(root: &Path) -> Vec<Violation> {
    let required = [
        "client/rust-toolchain.toml",
        "server/rust-toolchain.toml",
        "client/Cargo.lock",
        "server/Cargo.lock",
        ".gitattributes",
        ".gitignore",
        "justfile",
        "docs/02-工程铁律.md",
    ];

    let mut violations = Vec::new();
    for relative in required {
        let path = root.join(relative);
        if !path.exists() {
            violations.push(Violation::new(
                "B1",
                relative,
                0,
                "必需文件缺失",
                "该文件是构建可复现与铁律可执行的前提，必须入库（铁律 B1）",
            ));
        }
    }
    violations
}

/// V6：禁止大文件入库（磁盘上的附件与样本必须可生成）。
#[must_use]
pub fn no_large_files(root: &Path) -> Vec<Violation> {
    let mut violations = Vec::new();
    collect_large(root, &mut violations, root);
    violations
}

fn collect_large(dir: &Path, out: &mut Vec<Violation>, root: &Path) {
    if fsutil::is_skipped(dir) {
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
            collect_large(&path, out, root);
        } else if file_type.is_file()
            && let Ok(metadata) = entry.metadata()
            && metadata.len() > MAX_FILE_BYTES
        {
            out.push(Violation::new(
                "V6",
                Violation::relative(root, &path),
                0,
                format!(
                    "文件体积 {:.1} MB 超过 5 MB 上限",
                    metadata.len() as f64 / 1_048_576.0
                ),
                "大文件不得入库（铁律 V6）；改用脚本生成或外部存储",
            ));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 在临时目录里搭建一个最小仓库骨架。
    fn fixture(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("nested-rules-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("client/crates/nested-db/src")).expect("mkdir");
        std::fs::create_dir_all(dir.join("server/crates/server-api/src")).expect("mkdir");
        std::fs::create_dir_all(dir.join("shared/protocol")).expect("mkdir");
        dir
    }

    fn write(root: &Path, relative: &str, content: &str) {
        let path = root.join(relative);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("mkdir");
        }
        std::fs::write(path, content).expect("write");
    }

    #[test]
    fn unwrap_in_production_code_is_reported() {
        let root = fixture("unwrap");
        write(
            &root,
            "client/crates/nested-db/src/lib.rs",
            "pub fn f() -> u32 {\n    let x = Some(1).unwrap();\n    x\n}\n",
        );
        let violations = panic_free_production_code(&root);
        assert_eq!(violations.len(), 1);
        assert_eq!(violations[0].line, 2);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn unwrap_inside_test_module_is_allowed() {
        let root = fixture("unwrap-test");
        write(
            &root,
            "client/crates/nested-db/src/lib.rs",
            "pub fn f() -> u32 {\n    1\n}\n\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn t() {\n        let x = Some(1).unwrap();\n        assert_eq!(x, 1);\n    }\n}\n",
        );
        let violations = panic_free_production_code(&root);
        assert!(violations.is_empty(), "测试模块内应放行：{violations:?}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn unwrap_in_comment_is_allowed() {
        let root = fixture("unwrap-comment");
        write(
            &root,
            "client/crates/nested-db/src/lib.rs",
            "// 这里刻意不用 .unwrap()\npub fn f() -> u32 {\n    1 // 也不要 .expect()\n}\n",
        );
        assert!(panic_free_production_code(&root).is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn raw_delete_on_business_table_is_reported() {
        let root = fixture("delete");
        write(
            &root,
            "client/crates/nested-db/src/lib.rs",
            "pub fn purge(c: &Connection) {\n    c.execute(\"DELETE FROM notes WHERE id = 1\", []);\n}\n",
        );
        let violations = no_raw_delete(&root);
        assert_eq!(violations.len(), 1);
        assert_eq!(violations[0].rule, "D2");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn raw_delete_on_join_table_is_allowed() {
        let root = fixture("delete-join");
        write(
            &root,
            "client/crates/nested-db/src/lib.rs",
            "pub fn detach(c: &Connection) {\n    c.execute(\"DELETE FROM note_tags WHERE note_id = 1\", []);\n}\n",
        );
        assert!(no_raw_delete(&root).is_empty(), "关联表允许物理删除");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn interpolated_sql_with_lowercase_placeholder_is_reported() {
        let root = fixture("sql");
        write(
            &root,
            "client/crates/nested-db/src/lib.rs",
            "pub fn find(c: &Connection, table: &str) {\n    let sql = format!(\"SELECT * FROM {table}\");\n    let _ = sql;\n}\n",
        );
        let violations = no_interpolated_sql(&root);
        assert_eq!(violations.len(), 1);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn interpolated_sql_with_constant_columns_is_allowed() {
        let root = fixture("sql-const");
        write(
            &root,
            "client/crates/nested-db/src/lib.rs",
            "const COLUMNS: &str = \"a, b\";\npub fn all(c: &Connection) {\n    let sql = format!(\"SELECT {COLUMNS} FROM notes\");\n    let _ = sql;\n}\n",
        );
        assert!(no_interpolated_sql(&root).is_empty(), "常量列清单应放行");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn client_depending_on_server_is_reported() {
        let root = fixture("isolation");
        write(
            &root,
            "client/Cargo.toml",
            "[package]\nname = \"nested-core\"\n\n[dependencies]\nserver-api = { path = \"../server/crates/server-api\" }\n",
        );
        let violations = workspace_isolation(&root);
        assert_eq!(violations.len(), 1);
        assert!(violations[0].message.contains("server-api"));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn client_depending_on_sqlx_is_reported() {
        let root = fixture("isolation-sqlx");
        write(
            &root,
            "client/Cargo.toml",
            "[package]\nname = \"nested-db\"\n\n[dependencies]\nsqlx = \"0.8\"\n",
        );
        assert_eq!(workspace_isolation(&root).len(), 1);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn dependency_name_in_comment_is_not_reported() {
        let root = fixture("isolation-comment");
        write(
            &root,
            "client/Cargo.toml",
            "[package]\nname = \"nested-db\"\n\n[dependencies]\n# sqlx is deliberately NOT used here\nserde = \"1\"\n",
        );
        assert!(
            workspace_isolation(&root).is_empty(),
            "注释中的名字不应误报"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn hardcoded_password_is_reported() {
        let root = fixture("secret");
        write(
            &root,
            "server/app/src/main.rs",
            "fn main() {\n    let db_password = \"hunter2hunter2\";\n}\n",
        );
        let violations = no_hardcoded_secrets(&root);
        assert_eq!(violations.len(), 1);
        assert_eq!(violations[0].rule, "S3");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn placeholder_credentials_are_allowed() {
        let root = fixture("secret-placeholder");
        write(
            &root,
            "server/app/src/main.rs",
            "fn main() {\n    let db_password = \"example-password\";\n}\n",
        );
        assert!(no_hardcoded_secrets(&root).is_empty(), "样例值应放行");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn short_values_are_not_treated_as_secrets() {
        let root = fixture("secret-short");
        write(
            &root,
            "server/app/src/main.rs",
            "fn main() {\n    let token = \"\";\n    let secret = \"ab\";\n}\n",
        );
        assert!(no_hardcoded_secrets(&root).is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn placeholder_extraction_ignores_positional_arguments() {
        let names = extract_placeholders("format!(\"SELECT {} FROM {table} WHERE a = {0}\")");
        assert_eq!(names, vec!["table".to_owned()]);
    }
}
