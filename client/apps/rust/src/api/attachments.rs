// SPDX-License-Identifier: AGPL-3.0-or-later
//! 附件操作 —— 附加、列出、读出（FFI 暴露面）。
//!
//! ## 为什么这些能力现在才出现
//!
//! 内核的 `attach_file_to_note` / `list_attachments_for_note` /
//! `read_attachment` 在 P1 就已实现并测试（nested-attachment 覆盖率
//! 94.9%），但 **FFI 与界面一直没有入口**——能力在内核里睡觉。
//! 这是规划（design/20）里"内核有、FFI 没有"清单的最大一块。
//!
//! ## MIME 必须嗅探，不能只信扩展名（铁律 S6）
//!
//! 扩展名是用户可控的字符串；把 `virus.exe` 改名成 `照片.png`
//! 就能让它以图片身份入库。因此 [`sniff_mime`] 按**文件头魔数**判断，
//! 认不出的类型一律落到 `application/octet-stream`（安全的通用二进制），
//! 绝不根据扩展名猜测。
//!
//! 嗅探表刻意保持很小（PNG/JPEG/GIF/WEBP/PDF/ZIP/GZIP/MP4）。
//! 它们覆盖笔记场景的绝大多数附件；认不出的落到 octet-stream
//! 依然能正常存储与读回——损失的只是"预览类型"这一个提示。

use std::path::Path;

use serde::{Deserialize, Serialize};

use nested_core::NestedCore;
use nested_model::Id;

use crate::api::notes::with_core;

/// 附加成功后返回的附件摘要。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttachmentInfo {
    /// 是否成功。
    pub ok: bool,
    /// 稳定错误码（失败时）。
    pub code: Option<String>,
    /// 给用户看的一句话（失败时）。
    pub hint: Option<String>,

    /// 附件标识（内容寻址存储中的记录 id）。
    pub attachment_id: String,
    /// 内容 SHA-256（十六进制小写）。
    pub sha256: String,
    /// MIME 类型（由内容嗅探得出）。
    pub mime_type: String,
    /// 字节大小。
    pub size_bytes: u64,
    /// 用户可见的原始文件名。
    pub filename: String,
}

impl AttachmentInfo {
    fn failure(code: &str, hint: &str) -> Self {
        Self {
            ok: false,
            code: Some(code.to_owned()),
            hint: Some(hint.to_owned()),
            ..Self::default()
        }
    }
}

/// 附加一个文件到笔记。
///
/// 内核会完成**全部三步**：把文件复制进内容寻址存储、登记元数据、
/// 把对应的块（图片用 `Image`、其余用 `File`）追加进文档并保存。
/// 因此调用方**不需要**再改正文——界面侧要做的是保存当前编辑、
/// 调用本函数、然后**重新加载正文**（文档在内核侧变了）。
///
/// `mime_type` 由 [`sniff_mime`] 从文件内容得出，扩展名只用来给
/// `filename` 兜底。
#[must_use]
pub fn attachments_attach(note_id: &str, source_path: &str, at_ms: i64) -> AttachmentInfo {
    let parsed = match Id::parse(note_id) {
        Ok(parsed) => parsed,
        Err(_) => {
            return AttachmentInfo::failure("INVALID_ID", "笔记标识无效。");
        }
    };
    let path = Path::new(source_path);
    // 文件必须先存在且可读：嗅探要读文件头，内核存储也要复制它。
    // 在这里给出明确提示，比让内核深处报一个泛化的 IO 错误友好。
    if !path.is_file() {
        return AttachmentInfo::failure("FILE_NOT_FOUND", "找不到这个文件，或它不是一个普通文件。");
    }
    let Some(filename) = path.file_name().and_then(|n| n.to_str()) else {
        return AttachmentInfo::failure("INVALID_FILENAME", "文件名无法识别。");
    };
    let mime_type = sniff_mime(path);

    match with_core(
        |core: &NestedCore| -> Result<nested_model::Attachment, nested_core::CoreError> {
            let device_id = core.device_id()?;
            core.attach_file_to_note(&parsed, path, &mime_type, filename, &device_id, at_ms)
        },
    ) {
        Ok(attachment) => AttachmentInfo {
            ok: true,
            code: None,
            hint: None,
            attachment_id: attachment.id.to_string(),
            sha256: attachment.sha256,
            mime_type: attachment.mime_type,
            size_bytes: attachment.size_bytes,
            filename: attachment.filename,
        },
        Err(failure) => AttachmentInfo {
            ok: false,
            code: failure.code,
            hint: failure.hint,
            attachment_id: String::new(),
            sha256: String::new(),
            mime_type: String::new(),
            size_bytes: 0,
            filename: String::new(),
        },
    }
}

/// 列出一篇笔记的全部附件（含已删除的，由界面决定展示方式）。
#[must_use]
pub fn attachments_list(note_id: &str) -> Vec<AttachmentInfo> {
    let parsed = match Id::parse(note_id) {
        Ok(parsed) => parsed,
        Err(_) => return Vec::new(),
    };
    match with_core(|core: &NestedCore| core.list_attachments_for_note(&parsed)) {
        Ok(list) => list
            .iter()
            .map(|a| AttachmentInfo {
                ok: true,
                code: None,
                hint: None,
                attachment_id: a.id.to_string(),
                sha256: a.sha256.clone(),
                mime_type: a.mime_type.clone(),
                size_bytes: a.size_bytes,
                filename: a.filename.clone(),
            })
            .collect(),
        // 列表失败时返回空：调用方（附件对话框）应当显示"读取失败"
        // 而不是"没有附件"——但 FFI 这一层没有通道表达这个差别，
        // 因此列表为空的语义在 Dart 侧用"对话框自己的错误状态"兜住。
        Err(_) => Vec::new(),
    }
}

/// 读取一个附件的完整内容。
///
/// ## 为什么按字节返回而不是给路径
///
/// 附件存在内容寻址存储里（`objects/ab/cd...`），文件名是哈希，
/// 对用户没有意义。"另存为"的语义是：把内容写到**用户选的路径**。
/// 让 Dart 拿到字节自己写，路径选择（file_selector）与写盘都在
/// 界面侧完成，Rust 侧不必知道任何 UI 概念。
///
/// 内核在读取时会**校验哈希**（铁律 D4）：文件损坏时这里会失败，
/// 而不是把坏文件存出去。
#[must_use]
pub fn attachments_read_bytes(attachment_id: &str) -> Result<Vec<u8>, String> {
    let parsed = match Id::parse(attachment_id) {
        Ok(parsed) => parsed,
        Err(_) => return Err("附件标识无效。".to_owned()),
    };
    match with_core(|core: &NestedCore| {
        let attachment = core.get_attachment(&parsed)?;
        core.read_attachment(&attachment.sha256)
    }) {
        Ok(bytes) => Ok(bytes),
        // with_core 的错误是 NoteResult；hint 已是给人看的一句话
        Err(failure) => Err(failure.hint.unwrap_or_else(|| "读取附件失败。".to_owned())),
    }
}

/// 按文件头魔数判断 MIME 类型（铁律 S6）。
///
/// **这是内容嗅探，不是扩展名映射**——函数签名里没有扩展名参数，
/// 想作弊都难。认不出的类型落到 `application/octet-stream`：
/// 它的含义是"二进制，类型未知"，存储与读回不受影响。
fn sniff_mime(path: &Path) -> String {
    use std::io::Read;

    let Ok(mut file) = std::fs::File::open(path) else {
        return "application/octet-stream".to_owned();
    };
    let mut head = [0u8; 16];
    // 读不满 16 字节不是错误：小文件按已读到的部分判断
    let Ok(n) = file.read(&mut head) else {
        return "application/octet-stream".to_owned();
    };
    let b = &head[..n];

    // 魔数来源：各格式规范定义的文件头（PNG/JPEG/GIF 是规范写死的）
    const PNG: &[u8] = &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
    const JPEG: &[u8] = &[0xFF, 0xD8, 0xFF];
    const GIF87A: &[u8] = b"GIF87a";
    const GIF89A: &[u8] = b"GIF89a";
    const PDF: &[u8] = b"%PDF-";
    const ZIP: &[u8] = &[0x50, 0x4B, 0x03, 0x04]; // zip/docx/xlsx 的容器
    const GZIP: &[u8] = &[0x1F, 0x8B];

    if b.starts_with(PNG) {
        "image/png".to_owned()
    } else if b.starts_with(JPEG) {
        "image/jpeg".to_owned()
    } else if b.starts_with(GIF87A) || b.starts_with(GIF89A) {
        "image/gif".to_owned()
    } else if b.len() >= 12 && &b[8..12] == b"WEBP" {
        "image/webp".to_owned()
    } else if b.starts_with(PDF) {
        "application/pdf".to_owned()
    } else if b.starts_with(ZIP) {
        // zip 容器：也可能是 docx/xlsx，但没有进一步解包的必要——
        // 存储按字节走，类型只影响展示
        "application/zip".to_owned()
    } else if b.starts_with(GZIP) {
        "application/gzip".to_owned()
    } else if b.len() >= 8 && &b[4..8] == b"ftyp" {
        "video/mp4".to_owned()
    } else {
        "application/octet-stream".to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::sniff_mime;
    use std::io::Write;
    use std::path::Path;

    fn write_temp(name: &str, bytes: &[u8]) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("nested-sniff-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("建临时目录");
        let p = dir.join(name);
        let mut f = std::fs::File::create(&p).expect("建临时文件");
        f.write_all(bytes).expect("写入");
        p
    }

    #[test]
    fn png_is_detected_by_magic_bytes_not_extension() {
        // 扩展名是 .txt，但内容是 PNG —— 必须**按内容**认成 PNG。
        // 这一条就是铁律 S6 的具体化：改名的文件骗不过嗅探。
        let p = write_temp(
            "renamed.txt",
            &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0],
        );
        assert_eq!(sniff_mime(&p), "image/png");
    }

    #[test]
    fn exe_renamed_to_png_falls_to_octet_stream() {
        // 反向验证：把可执行文件改名成 .png，也骗不成图片
        let p = write_temp("evil.png", b"MZ\x90\x00\x03\x00\x00\x00");
        assert_eq!(sniff_mime(&p), "application/octet-stream");
    }

    #[test]
    fn jpeg_and_pdf_are_detected() {
        let jpg = write_temp("a.jpg", &[0xFF, 0xD8, 0xFF, 0xE0]);
        assert_eq!(sniff_mime(&jpg), "image/jpeg");
        let pdf = write_temp("a.pdf", b"%PDF-1.7\n");
        assert_eq!(sniff_mime(&pdf), "application/pdf");
    }

    #[test]
    fn unknown_content_falls_to_octet_stream() {
        let p = write_temp("plain.bin", b"just some text bytes");
        assert_eq!(sniff_mime(&p), "application/octet-stream");
    }

    #[test]
    fn missing_file_falls_to_octet_stream() {
        assert_eq!(
            sniff_mime(Path::new("Z:/definitely/not/here.bin")),
            "application/octet-stream"
        );
    }
}
