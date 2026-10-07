// SPDX-License-Identifier: AGPL-3.0-or-later
//! 界面状态诊断 —— 把"界面此刻看到了什么"落到一个可被脚本断言的文件。
//!
//! ## 为什么需要它
//!
//! 自动化截屏在远程 / 虚拟化环境可能返回**恒定同一帧**（本项目实测过：
//! 连续多次截屏的文件哈希完全相同，哪怕界面内容已经变了），
//! 因此"截图看起来对"不能作为验收证据。详见 `docs/03-踩坑备忘.md` §7.3。
//!
//! 这个模块把关键状态写成文本，让验证脚本可以直接断言
//! "界面到底拿到了几条笔记本、哪几篇笔记"。
//!
//! ## 为什么放在 `core/` 而不是页面里
//!
//! 1. **分层**：页面是展示层，不该为了"可观测"而多知道一层数据细节；
//!    而且门禁 `A-LAYERING` 禁止 UI 直接接触 FFI——诊断要读
//!    `lib/src/rust/**` 的类型，放页面里会违反它（本项目踩过这个坑）。
//! 2. **位置正确**：诊断是"数据层状态的快照"，本来就属于数据层。
//! 3. **只装一次**：在应用启动时装到 Riverpod 容器上，
//!    而不是每个页面各自装一遍。
//!
//! ## 为什么用 `ref.listen` 而不是帧回调
//!
//! 最初把诊断写在 `WidgetsBinding.addPostFrameCallback` 里，结果**永远不写**：
//! 那个回调只在"页面重建"之后排队，而页面并不随数据变化重建。
//! 表面现象是"诊断文件里没有快照"，我一度据此以为数据没加载出来——
//! 实际上数据是好的，**是我的观测手段本身没被触发**。
//!
//! `ref.listen` 直接挂在 provider 上：数据一变就调用，不依赖重建。
//! 这才是观测该在的位置。

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'notebook_providers.dart';
import 'note_providers.dart';

/// 诊断文件路径（系统临时目录）。
String get uiDiagnosticsPath =>
    '${Directory.systemTemp.path}/nested-ui-diagnostics.txt';

/// 追加一段诊断内容。
///
/// 写入失败**绝不**影响正常流程：诊断是辅助手段，不是功能。
Future<void> writeUiDiagnostics(List<String> lines) async {
  try {
    final String stamp = DateTime.now().toIso8601String();
    await File(
      uiDiagnosticsPath,
    ).writeAsString('[$stamp]\n${lines.join('\n')}\n\n', mode: FileMode.append);
  } catch (_) {
    // 忽略：诊断写入失败不该影响功能
  }
}

/// 清空诊断文件（脚本在启动应用前调用更合适；这里供应用内自测使用）。
Future<void> clearUiDiagnostics() async {
  try {
    final File file = File(uiDiagnosticsPath);
    if (file.existsSync()) {
      await file.delete();
    }
  } catch (_) {
    // 忽略
  }
}

/// 界面诊断器：把三栏数据的变化写成快照。
///
/// 通过 [uiDiagnosticsProvider] 在应用启动时创建一次即可；
/// 它自身不渲染任何东西，只负责观测与落盘。
class UiDiagnostics {
  /// 构造并立即开始观测。
  ///
  /// 注意：`Provider` 只创建一次实例，因此这里的订阅天然是"只装一次"。
  UiDiagnostics(this._ref) {
    _install();
  }

  final Ref _ref;

  /// 上一次写出的快照，用于去重（避免同一状态反复写）。
  String? _last;

  void _install() {
    // 中栏列表：它带笔记本过滤，是"界面看到的笔记"的权威来源
    _ref.listen<AsyncValue<List<NoteItem>>>(
      noteListProvider(const NoteListQuery()),
      (AsyncValue<List<NoteItem>>? previous, AsyncValue<List<NoteItem>> next) {
        if (next.hasValue) {
          unawaited(_writeSnapshot(next.requireValue));
        }
      },
    );

    // 左栏树：任一变化都值得记录
    _ref.listen<AsyncValue<List<NotebookNode>>>(notebooksTreeProvider, (
      AsyncValue<List<NotebookNode>>? previous,
      AsyncValue<List<NotebookNode>> next,
    ) {
      if (next.hasValue) {
        unawaited(
          _writeSnapshot(
            _ref.read(noteListProvider(const NoteListQuery())).value,
          ),
        );
      }
    });
  }

  Future<void> _writeSnapshot(List<NoteItem>? notes) async {
    final AsyncValue<List<NotebookNode>> tree = _ref.read(
      notebooksTreeProvider,
    );
    if (notes == null || !tree.hasValue) {
      return;
    }

    final List<String> lines = <String>[
      'kind=ui-snapshot',
      'selectedNotebook=${_ref.read(selectedNotebookIdProvider) ?? '(全部笔记)'}',
      'notebookCount=${tree.requireValue.length}',
      'notebookTree=${tree.requireValue.map(_describeNotebook).join(' | ')}',
      'noteCount=${notes.length}',
      'noteTitles=${notes.map((NoteItem note) => note.title).join(' | ')}',
    ];

    final String snapshot = lines.join('\n');
    if (snapshot == _last) {
      return;
    }
    _last = snapshot;
    await writeUiDiagnostics(lines);
  }

  /// 把笔记本描述成 `缩进名称(子树笔记数)`，缩进反映层级。
  String _describeNotebook(NotebookNode node) {
    final String indent = '  ' * node.depth;
    return '$indent${node.name}(${node.noteCount})';
  }
}

/// 界面诊断入口。
///
/// 在应用启动时 `ref.watch` 一次即可（见 `main.dart`）。
final Provider<UiDiagnostics> uiDiagnosticsProvider = Provider<UiDiagnostics>(
  UiDiagnostics.new,
);
