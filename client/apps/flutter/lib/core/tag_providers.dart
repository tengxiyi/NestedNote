// SPDX-License-Identifier: AGPL-3.0-or-later
//! 标签的**数据层**。
//!
//! ## 覆盖语义
//!
//! 设置笔记标签用的是**整体覆盖**而不是增量的 attach/detach：
//! 界面上的标签编辑器是"勾选完点确定"，覆盖语义与它一一对应，
//! 既幂等又可重放，也不会因为漏掉一次 detach 而残留一个
//! 用户以为已取消的标签。
//!
//! ## 同名标签的"复活"
//!
//! `idx_tags_name_unique` 是 `name COLLATE NOCASE` 上的唯一索引，
//! **不含 `deleted_at_ms`**——墓碑仍占着索引位。因此删掉"工作"后再建"工作"
//! 不会报重名，而是**复活原来那一行**并复用它的 id。
//!
//! 这意味着 [TagActions.create] 返回的 id **不一定**是新建的：
//! **调用方必须用返回值，不要自己拼一个**。技术债 #13 由此偿还。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/notes.dart' as rust;
import 'note_providers.dart';

/// 从 core 层转出 FFI 的标签类型（界面不直接依赖生成绑定，铁律 A2 / F1）。
typedef TagEntry = rust.TagEntry;

/// 标签列表（全部，不含已删除的）。
///
/// 失败时抛出而不是返回空列表：空列表会让界面显示"还没有标签"，
/// 而真实原因可能是数据库出错。
final tagsProvider = FutureProvider<List<rust.TagEntry>>((Ref ref) async {
  final rust.NoteResult result = await rust.tagsList();
  if (!result.ok) {
    throw NoteFailure(
      code: result.code ?? 'UNKNOWN',
      hint: result.hint ?? '读取标签失败。',
    );
  }
  return result.value?.tags ?? const <rust.TagEntry>[];
});

/// 某篇笔记的标签。
final noteTagsProvider = FutureProvider.family<List<rust.TagEntry>, String>((
  Ref ref,
  String noteId,
) async {
  final rust.NoteResult result = await rust.notesListTags(id: noteId);
  if (!result.ok) {
    throw NoteFailure(
      code: result.code ?? 'UNKNOWN',
      hint: result.hint ?? '读取笔记标签失败。',
    );
  }
  return result.value?.tags ?? const <rust.TagEntry>[];
});

/// 标签写操作。
class TagActions {
  /// 构造。
  const TagActions(this._ref);

  final Ref _ref;

  /// 创建标签，返回**实际生效的**标签（可能是复活后的既有行）。
  ///
  /// 返回完整的 [TagEntry] 而不是只返回 id，是因为调用方几乎总是要
  /// "创建后立刻勾选它"——把 id 与名称一起给出来，省掉一次查找，
  /// 也避免调用方拿错 id（复活时 id 与它以为的不同）。
  Future<rust.TagEntry> create(String name) async {
    final rust.NoteResult result = await rust.tagsCreate(
      name: name,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (!result.ok) {
      throw NoteFailure(
        code: result.code ?? 'UNKNOWN',
        hint: result.hint ?? '创建标签失败。',
      );
    }
    final List<rust.TagEntry> tags =
        result.value?.tags ?? const <rust.TagEntry>[];
    if (tags.isEmpty) {
      throw const NoteFailure(code: 'EMPTY_PAYLOAD', hint: '内核未返回标签。');
    }
    _ref.invalidate(tagsProvider);
    return tags.first;
  }

  /// 设置一篇笔记的标签集合（整体覆盖）。
  Future<void> setForNote(String noteId, List<String> tagIds) async {
    final rust.NoteResult result = await rust.notesSetTags(
      id: noteId,
      tagIds: tagIds,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (!result.ok) {
      throw NoteFailure(
        code: result.code ?? 'UNKNOWN',
        hint: result.hint ?? '设置标签失败。',
      );
    }
    _ref.invalidate(noteTagsProvider(noteId));
    _ref.invalidate(tagsProvider);
  }
}

/// 标签写操作入口。
final tagActionsProvider = Provider<TagActions>(TagActions.new);
