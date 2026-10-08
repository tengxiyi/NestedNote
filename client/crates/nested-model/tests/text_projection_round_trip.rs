// SPDX-License-Identifier: AGPL-3.0-or-later
//! 文本 ↔ 块的往返测试。
//!
//! ## 为什么这组测试是本模块的核心
//!
//! 本模块存在的理由是"修掉往返丢信息"。因此**每一种块类型都必须有
//! 一条 `text_to_blocks(blocks_to_text(x)) == x` 的断言**——
//! 少一条，那种块就可能在某个改动之后悄悄降级成段落，
//! 而用户唯一的感受是"我的格式怎么没了"。

use nested_model::{
    Block, InlineMark, InlineMarkKind, ListItem, TableCell, TableRow, blocks_to_text,
    text_to_blocks,
};

/// 造一个合法的附件标识（内容寻址存储里的记录 id）。
fn attachment_id() -> nested_model::Id {
    nested_model::Id::parse("0190f2a1-1111-7000-8000-000000000001").expect("合法 id")
}

/// 往返一次：块 → 文本 → 块。
fn round_trip(block: Block) -> Block {
    let text = blocks_to_text(std::slice::from_ref(&block));
    let mut back = text_to_blocks(&text);
    assert_eq!(
        back.len(),
        1,
        "往返后块数变了：{block:?} → 文本 {text:?} → {back:?}"
    );
    back.remove(0)
}

/// 造一个空白段落。
fn blank() -> Block {
    Block::Paragraph {
        text: String::new(),
        marks: Vec::new(),
    }
}

#[test]
fn paragraph_round_trips() {
    let block = Block::Paragraph {
        text: "一段中文正文".to_owned(),
        marks: Vec::new(),
    };
    assert_eq!(round_trip(block.clone()), block);
}

#[test]
fn blank_paragraph_is_normalized_not_preserved() {
    // ## 空白段落的往返语义是"归一"，不是"完全相等"
    //
    // 这段取舍值得写清楚，因为它是本模块最容易做错的一处。
    //
    // 块模型允许"文本为空的段落块"，而它在文本投影里对应的就是**空行**。
    // 一道算术题：用户按了**三次**回车，这是几个空白段落？
    //
    // - 若坚持"完全相等"，`blocks_to_text` 就必须输出 `"\n\n\n"`，
    //   再解回三个空段落。看似自洽，但**一篇末尾多按了一次回车的笔记，
    //   它的块数就与用户意图无关了**；而且空笔记会变成
    //   "含一个空段落"而不是"没有内容"。
    // - 现在采用的做法：**中间的空行保留为分隔**（用户用它分段，
    //   这是真实需求），**末尾与连续的空行归一**。
    //
    // 也就是说：**空行是排版工具，不是内容**。用户在意的是"这里空了一行"，
    // 而不是"存了几个空段落"。因此归一不会丢掉任何用户看得见的东西。
    let text = blocks_to_text(&[blank()]);
    assert_eq!(text, "");
    assert!(text_to_blocks(&text).is_empty());
}

#[test]
fn blank_lines_in_the_middle_are_kept_as_one_separator() {
    // 中间的空行保留（用户用它分段）；连续多个归一成一个，
    // 末尾的裁掉（那只是最后一次回车）。
    let back = text_to_blocks("第一段\n\n第二段\n\n\n");
    assert_eq!(
        back,
        vec![
            Block::Paragraph {
                text: "第一段".to_owned(),
                marks: Vec::new()
            },
            blank(),
            Block::Paragraph {
                text: "第二段".to_owned(),
                marks: Vec::new()
            },
        ]
    );
}

#[test]
fn a_note_with_a_blank_line_round_trips_stably() {
    // "归一之后稳定"是真正要保证的性质：再往返一次结果不变。
    // 否则**每次保存都会改动文档**，修订历史会被无意义的差异刷满
    //（铁律 T6 的修订是要给人看的，不能被噪音淹没）。
    let original = vec![
        Block::Paragraph {
            text: "甲".to_owned(),
            marks: Vec::new(),
        },
        blank(),
        Block::Paragraph {
            text: "乙".to_owned(),
            marks: Vec::new(),
        },
    ];
    let once = text_to_blocks(&blocks_to_text(&original));
    let twice = text_to_blocks(&blocks_to_text(&once));
    assert_eq!(once, original, "第一次往返应当稳定");
    assert_eq!(twice, once, "第二次往返不应再变化（否则会持续产生修订）");
}

#[test]
fn heading_round_trips_for_all_six_levels() {
    for level in 1..=6_u8 {
        let block = Block::Heading {
            level,
            text: format!("{level} 级标题"),
            marks: Vec::new(),
        };
        assert_eq!(round_trip(block.clone()), block, "层级 {level} 往返失败");
    }
}

#[test]
fn heading_level_is_clamped_not_dropped() {
    // 字段是 u8，而 Markdown 只有六级。越界时**夹取**而不是丢弃：
    // 丢一个标题比少几个 `#` 严重得多。
    let text = blocks_to_text(&[Block::Heading {
        level: 9,
        text: "超纲标题".to_owned(),
        marks: Vec::new(),
    }]);
    assert_eq!(text, "###### 超纲标题");
    // 反解回来是第 6 级，正文一个字不少
    let back = text_to_blocks(&text);
    assert_eq!(
        back,
        vec![Block::Heading {
            level: 6,
            text: "超纲标题".to_owned(),
            marks: Vec::new(),
        }]
    );
}

#[test]
fn unordered_list_round_trips() {
    let block = Block::List {
        ordered: false,
        start: 1,
        items: vec![ListItem {
            text: "买牛奶".to_owned(),
            children: Vec::new(),
        }],
    };
    assert_eq!(round_trip(block.clone()), block);
}

#[test]
fn ordered_list_round_trips_with_start() {
    let block = Block::List {
        ordered: true,
        start: 3,
        items: vec![ListItem {
            text: "第三项".to_owned(),
            children: Vec::new(),
        }],
    };
    assert_eq!(round_trip(block.clone()), block);
}

#[test]
fn checklist_round_trips_both_states() {
    for checked in [false, true] {
        let block = Block::Checklist {
            checked,
            text: "写测试".to_owned(),
        };
        assert_eq!(
            round_trip(block.clone()),
            block,
            "checked={checked} 往返失败"
        );
    }
}

#[test]
fn quote_round_trips_without_cite() {
    let block = Block::Quote {
        text: "知之为知之".to_owned(),
        cite: None,
    };
    assert_eq!(round_trip(block.clone()), block);
}

#[test]
fn code_block_round_trips_with_language() {
    let block = Block::Code {
        language: Some("rust".to_owned()),
        code: "fn main() {}\nlet x = 1;".to_owned(),
    };
    assert_eq!(round_trip(block.clone()), block);
}

#[test]
fn code_block_round_trips_without_language() {
    let block = Block::Code {
        language: None,
        code: "普通代码".to_owned(),
    };
    assert_eq!(round_trip(block.clone()), block);
}

#[test]
fn code_block_content_is_not_parsed() {
    // 代码块内部**不得**被当作 Markdown 解析：`# 看起来像标题` 必须
    // 原样留在代码里。这是最容易被写错的一处。
    let block = Block::Code {
        language: None,
        code: "# 这不是标题\n- 这不是列表\n> 这不是引用".to_owned(),
    };
    assert_eq!(round_trip(block.clone()), block);
}

#[test]
fn code_block_with_blank_lines_round_trips() {
    // 代码里的空行尤其不能丢（缩进语言靠它分段）
    let block = Block::Code {
        language: Some("python".to_owned()),
        code: "def f():\n    pass\n\ndef g():\n    pass".to_owned(),
    };
    assert_eq!(round_trip(block.clone()), block);
}

#[test]
fn divider_round_trips() {
    assert_eq!(round_trip(Block::Divider), Block::Divider);
}

#[test]
fn link_round_trips() {
    let block = Block::Link {
        text: "文档".to_owned(),
        href: "https://example.com/a?b=1".to_owned(),
    };
    assert_eq!(round_trip(block.clone()), block);
}

#[test]
fn image_round_trips_keeping_attachment_id() {
    let block = Block::Image {
        attachment_id: attachment_id(),
        alt: Some("一张图".to_owned()),
        width: None,
        height: None,
    };
    assert_eq!(round_trip(block.clone()), block);
}

#[test]
fn file_round_trips_keeping_attachment_id() {
    let block = Block::File {
        attachment_id: attachment_id(),
        filename: "报告.pdf".to_owned(),
    };
    assert_eq!(round_trip(block.clone()), block);
}

#[test]
fn table_round_trips() {
    let block = Block::Table {
        rows: vec![
            TableRow {
                cells: vec![
                    TableCell {
                        text: "列一".to_owned(),
                        header: false,
                    },
                    TableCell {
                        text: "列二".to_owned(),
                        header: false,
                    },
                ],
            },
            TableRow {
                cells: vec![
                    TableCell {
                        text: "值一".to_owned(),
                        header: false,
                    },
                    TableCell {
                        text: "值二".to_owned(),
                        header: false,
                    },
                ],
            },
        ],
    };
    assert_eq!(round_trip(block.clone()), block);
}

#[test]
fn table_with_header_round_trips() {
    let block = Block::Table {
        rows: vec![
            TableRow {
                cells: vec![TableCell {
                    text: "表头".to_owned(),
                    header: true,
                }],
            },
            TableRow {
                cells: vec![TableCell {
                    text: "数据".to_owned(),
                    header: false,
                }],
            },
        ],
    };
    assert_eq!(round_trip(block.clone()), block);
}

// ------------------------------------------------------------------ 多块

#[test]
fn a_whole_document_round_trips() {
    // 一份"像真的"的笔记：各种块混在一起，含空行。
    // 单块各自往返成功不代表拼起来也成功（例如代码块的围栏会打乱
    // 后面几行的解析），因此必须有这一条。
    let blocks = vec![
        Block::Heading {
            level: 1,
            text: "会议记录".to_owned(),
            marks: Vec::new(),
        },
        Block::Paragraph {
            text: String::new(),
            marks: Vec::new(),
        },
        Block::Paragraph {
            text: "2026-10-07 与设计组同步。".to_owned(),
            marks: Vec::new(),
        },
        Block::Heading {
            level: 2,
            text: "结论".to_owned(),
            marks: Vec::new(),
        },
        Block::List {
            ordered: false,
            start: 1,
            items: vec![ListItem {
                text: "三栏宽度可拖".to_owned(),
                children: Vec::new(),
            }],
        },
        Block::Checklist {
            checked: true,
            text: "补齐菜单栏".to_owned(),
        },
        Block::Checklist {
            checked: false,
            text: "写导出".to_owned(),
        },
        Block::Quote {
            text: "先做减法".to_owned(),
            cite: None,
        },
        Block::Code {
            language: Some("sql".to_owned()),
            code: "SELECT 1;\n# 注释不是标题".to_owned(),
        },
        Block::Divider,
        Block::Paragraph {
            text: String::new(),
            marks: Vec::new(),
        },
        Block::Paragraph {
            text: "以上。".to_owned(),
            marks: Vec::new(),
        },
    ];

    let text = blocks_to_text(&blocks);
    let back = text_to_blocks(&text);
    assert_eq!(back, blocks, "整篇往返丢信息。文本投影：\n{text}");
}

#[test]
fn text_that_is_not_markdown_stays_plain() {
    // 不能把普通文本误判成结构。这几条都是真实笔记里会出现的写法。
    let cases: [&str; 5] = [
        "#标签不是标题",
        "-不对，减号后面要有空格",
        "[方括号]不是链接",
        "1.不是列表",
        "2026.10.07 发布",
    ];
    for input in cases {
        let back = text_to_blocks(input);
        assert_eq!(
            back,
            vec![Block::Paragraph {
                text: input.to_owned(),
                marks: Vec::new()
            }],
            "「{input}」被误判成了结构块"
        );
    }
}

// ------------------------------------------------------------------ 已知降级

#[test]
fn inline_marks_are_dropped_but_text_survives() {
    // 行内标记（加粗等）是**字节偏移**，在纯文本里没有稳定表示，
    // 因此投影时会丢。这是已知且有意的降级——但文本一个字不能少。
    //
    // 富文本编辑器上线后这一条要改掉，届时它会提醒维护者来更新。
    let block = Block::Paragraph {
        text: "加粗的部分".to_owned(),
        marks: vec![InlineMark {
            start: 0,
            end: 6,
            kind: InlineMarkKind::Bold,
        }],
    };
    let text = blocks_to_text(std::slice::from_ref(&block));
    assert_eq!(text, "加粗的部分", "文本内容必须完整保留");
    let back = text_to_blocks(&text);
    assert_eq!(
        back,
        vec![Block::Paragraph {
            text: "加粗的部分".to_owned(),
            marks: Vec::new(),
        }],
        "标记被丢弃（已知降级）"
    );
}

#[test]
fn image_dimensions_are_dropped_but_id_survives() {
    let block = Block::Image {
        attachment_id: attachment_id(),
        alt: Some("图".to_owned()),
        width: Some(800),
        height: Some(600),
    };
    let back = round_trip(block);
    match back {
        Block::Image {
            width, height, alt, ..
        } => {
            // 尺寸丢失（投影里无处安放），但**附件标识与替代文本必须还在**，
            // 否则图片就变成了一张找不到的图。
            assert_eq!(width, None);
            assert_eq!(height, None);
            assert_eq!(alt.as_deref(), Some("图"));
        }
        other => panic!("应当仍是图片块，实际是 {other:?}"),
    }
}

#[test]
fn embed_degrades_to_paragraph_losslessly() {
    // Embed 是 P7 预留，没有产生路径。反解成段落是**有意的降级**：
    // 文字还在，用户至少能看到这里原本有个嵌入内容。
    let block = Block::Embed {
        provider: "youtube".to_owned(),
        reference: "dQw4w9WgXcQ".to_owned(),
    };
    let text = blocks_to_text(std::slice::from_ref(&block));
    assert_eq!(text, "[embed: youtube/dQw4w9WgXcQ]");
    let back = text_to_blocks(&text);
    assert_eq!(
        back,
        vec![Block::Paragraph {
            text: "[embed: youtube/dQw4w9WgXcQ]".to_owned(),
            marks: Vec::new(),
        }]
    );
}

// ------------------------------------------------------------------ 辅助

#[test]
fn is_blank_agrees_for_every_kind() {
    // 这个函数被字数统计与"空笔记"判断共用。它漏掉一个变体，
    // 就会出现"看起来是空的但算作有内容"这类难查的偏差。
    assert!(nested_model::is_blank(&Block::Paragraph {
        text: String::new(),
        marks: Vec::new()
    }));
    assert!(nested_model::is_blank(&Block::Heading {
        level: 1,
        text: String::new(),
        marks: Vec::new()
    }));
    assert!(nested_model::is_blank(&Block::Checklist {
        checked: false,
        text: String::new()
    }));
    assert!(nested_model::is_blank(&Block::Quote {
        text: String::new(),
        cite: None
    }));
    assert!(nested_model::is_blank(&Block::Code {
        language: None,
        code: String::new()
    }));
    assert!(nested_model::is_blank(&Block::List {
        ordered: false,
        start: 1,
        items: Vec::new()
    }));
    assert!(nested_model::is_blank(&Block::Table { rows: Vec::new() }));

    // 分割线、图片、附件、链接、嵌入内容**都不算空**——
    // 它们本身就是一个可见的东西，即使没有文字。
    assert!(!nested_model::is_blank(&Block::Divider));
    assert!(!nested_model::is_blank(&Block::Image {
        attachment_id: attachment_id(),
        alt: None,
        width: None,
        height: None
    }));
    assert!(!nested_model::is_blank(&Block::File {
        attachment_id: attachment_id(),
        filename: "a.txt".to_owned()
    }));
    assert!(!nested_model::is_blank(&Block::Link {
        text: "a".to_owned(),
        href: "b".to_owned()
    }));
    assert!(!nested_model::is_blank(&Block::Embed {
        provider: "p".to_owned(),
        reference: "r".to_owned()
    }));
}

#[test]
fn every_block_kind_has_a_display_name() {
    // 新增块类型时若忘了这里，界面会显示空白——测试提醒维护者补上。
    for kind in [
        nested_model::BlockKind::Paragraph,
        nested_model::BlockKind::Heading,
        nested_model::BlockKind::List,
        nested_model::BlockKind::ListItem,
        nested_model::BlockKind::Checklist,
        nested_model::BlockKind::Quote,
        nested_model::BlockKind::Code,
        nested_model::BlockKind::Image,
        nested_model::BlockKind::File,
        nested_model::BlockKind::Table,
        nested_model::BlockKind::Divider,
        nested_model::BlockKind::Link,
        nested_model::BlockKind::Embed,
    ] {
        let name = nested_model::kind_display_name(kind);
        assert!(!name.is_empty(), "{kind:?} 没有显示名");
    }
}
