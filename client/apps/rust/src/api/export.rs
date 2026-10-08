// SPDX-License-Identifier: AGPL-3.0-or-later
//! 导出与备份的 FFI 暴露面。
//!
//! 渲染在 `nested-export`（纯函数），库遍历在 `nested-core`；
//! 本层只做"取结果 + 错误翻译"。文件写入在 Dart 侧完成
//! （路径选择 + 临时文件 → rename，铁律 D3）。

use nested_core::NestedCore;

use crate::api::notes::with_core;

/// 导出一篇笔记为 Markdown。
///
/// # Errors
///
/// 笔记不存在或读取失败 → 结构化错误（hint 可直接展示）。
pub fn export_note_markdown(id: &str) -> Result<String, String> {
    let parsed = parse_note_id(id)?;
    with_core(|core: &NestedCore| core.export_note_markdown(&parsed))
        .map_err(|failure| failure.hint.unwrap_or_else(|| "导出失败。".to_owned()))
}

/// 导出一篇笔记为自包含 HTML（图片内联 base64）。
///
/// # Errors
///
/// 笔记不存在或读取失败 → 结构化错误。
pub fn export_note_html(id: &str) -> Result<String, String> {
    let parsed = parse_note_id(id)?;
    with_core(|core: &NestedCore| core.export_note_html(&parsed))
        .map_err(|failure| failure.hint.unwrap_or_else(|| "导出失败。".to_owned()))
}

/// 导出整库为 JSON 备份。
///
/// **不含附件二进制内容**（CAS 目录需随备份一并拷贝）——
/// 这一限制由界面在菜单文案上明示。
///
/// # Errors
///
/// 读取或序列化失败 → 结构化错误。
pub fn export_database_json() -> Result<String, String> {
    with_core(|core: &NestedCore| core.export_database_json())
        .map_err(|failure| failure.hint.unwrap_or_else(|| "备份失败。".to_owned()))
}

fn parse_note_id(id: &str) -> Result<nested_model::Id, String> {
    nested_model::Id::parse(id).map_err(|_| "笔记标识无效。".to_owned())
}

#[cfg(test)]
mod tests {
    use nested_core::NestedCore;
    use nested_model::Note;

    const NOW: i64 = 1_700_000_000_000;

    /// 直接用内核句柄：导出逻辑在 core，FFI 只是薄包装；
    /// 且 core 错误的 Display 带内部信息，失败时能直接看到是哪一步。
    #[test]
    fn export_round_trips_the_three_formats() {
        let dir = tempfile::tempdir().expect("tempdir");
        let core = NestedCore::open(dir.path()).expect("open");

        let note = core.create_note(None, "导出样例", NOW).expect("create");
        // 与 FFI notes_save 相同的保存路径：文本 → 投影 → save_note
        let save_text = |core: &NestedCore, note: Note, text: &str, at: i64| {
            let document =
                nested_model::Document::from_blocks(nested_model::text_to_blocks(text), at);
            core.save_note(note, document, "test-device", at)
        };
        let note = save_text(&core, note, "第一版", NOW).expect("save v1");
        let note = save_text(&core, note, "# 大标题\n- 甲\n- 乙", NOW + 1).expect("save v2");

        // Markdown：块渲染为外部可读的 Markdown
        let markdown = core.export_note_markdown(&note.id).expect("markdown");
        assert!(markdown.contains("# 大标题"), "markdown: {markdown}");
        assert!(markdown.contains("- 甲"), "markdown: {markdown}");

        // HTML：自包含文档，块渲染为标签且文本转义
        let html = core.export_note_html(&note.id).expect("html");
        assert!(html.contains("<h1>大标题</h1>"), "html: {html}");
        assert!(html.contains("<li>甲</li>"), "html: {html}");
        assert!(html.contains("<!DOCTYPE html>"));

        // 整库备份：包含笔记标题与结构版本
        let backup = core.export_database_json().expect("backup");
        assert!(
            backup.contains("导出样例"),
            "backup: {}",
            &backup[..backup.len().min(2000)]
        );
        assert!(backup.contains("nestednote-backup"));
    }
}
