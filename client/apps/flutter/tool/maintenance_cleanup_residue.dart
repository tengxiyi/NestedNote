// SPDX-License-Identifier: AGPL-3.0-or-later
// 一次性维护脚本：清掉回收站里累积的**脚本残留**，并核对示例数据完好。
//
// ## 为什么需要它
//
// 我在排查过程中反复运行核对脚本（`audit_*` / `verify_*`），
// 每个脚本都建目录、建笔记，跑完删掉——但旧版本的清理有两个漏洞：
//
// 1. 有些脚本**只软删目录、不做彻底删除**，于是它们堆在回收站里；
// 2. 就算想彻底删也**删不掉**：旧的清理逻辑跳过"有子节点的笔记本"，
//    于是父目录永久滞留（这是本次修的缺陷之一）。
//
// 结果：回收站里积了 49 个笔记本，而界面上**看不到它们**
//（回收站只列笔记），用户看到的徽标数字还对不上。
//
// 这个脚本把那些残留清掉，并顺手核对示例笔记是否完好。
//
// 用法（client/apps/flutter 目录下）：
//   dart run tool/maintenance_cleanup_residue.dart           # 只看不删
//   dart run tool/maintenance_cleanup_residue.dart --apply   # 真的删

import 'dart:io';

import 'package:nestednote/src/rust/api/notes.dart';
import 'package:nestednote/src/rust/frb_generated.dart';

import 'app_paths.dart';

/// 我的核对脚本用过的名称前缀。**只清理这些**，绝不碰用户数据。
const List<String> kResiduePrefixes = <String>[
  '[核对归属]',
  '[核对回收站]',
  '[核对目录回收]',
  '[排序核对]',
  '[验证S2]',
  '[验证保存]',
  '[验证]',
];

bool _isResidue(String name) =>
    kResiduePrefixes.any((String prefix) => name.startsWith(prefix));

/// 父目录是脚本残留时，它自己也算残留——即使名称里没有前缀。
///
/// ## 为什么需要这一条
///
/// `[排序核对]父` 下面的子目录叫 `甲` / `乙` / `丙`（那是为了验证中文
/// 排序规则造的，故意用单字）。只按名称前缀判断的话它们不会被清掉，
/// 而它们的父目录已经没了——于是变成一堆**谁也说不清来历**的孤儿，
/// 用户还得自己判断"这三个单字目录是什么，能不能删"。
///
/// 判断依据是"祖先里有残留"。这与"名称像残留"是两件事：
/// 后者会误伤用户，前者不会。
bool _isResidueOrUnderResidue(
  String name,
  String? parentId,
  Map<String, (String, String?)> byId,
) {
  if (_isResidue(name)) {
    return true;
  }
  // 沿父链往上找。64 层上限是防环（损坏数据理论上可能成环，
  // 而这里一旦转圈就是死循环 → 脚本卡住）。
  var current = parentId;
  for (var depth = 0; depth < 64 && current != null; depth++) {
    final (String parentName, String? grandParent) =
        byId[current] ?? ('', null);
    if (parentName.isEmpty) {
      return false;
    }
    if (_isResidue(parentName)) {
      return true;
    }
    current = grandParent;
  }
  return false;
}

Future<void> main(List<String> args) async {
  final bool apply = args.contains('--apply');
  final dir = resolveAppDataDirForTools();
  await RustLib.init();
  final status = await engineStart(dataDir: dir.path);
  if (!status.ready) {
    stderr.writeln('引擎启动失败：${status.message}');
    exit(1);
  }

  stdout.writeln(apply ? '模式：**真的删除**' : '模式：只看不删（加 --apply 才真删）');
  stdout.writeln('');

  final now = DateTime.now().millisecondsSinceEpoch;

  // ---------------------------------------------------------- 1. 示例笔记
  stdout.writeln('=== 1. 示例数据（绝不能碰）===');
  final allNotes = await notesList(
    notebookId: null,
    includeDescendants: true,
    includeDeleted: true,
    limit: 0,
  );
  final demoNotes = (allNotes.value?.notes ?? const <NoteSummary>[])
      .where((NoteSummary n) => n.title.startsWith('[示例]'))
      .toList();
  final demoLive = demoNotes.where((NoteSummary n) => !n.deleted).length;
  final demoTrashed = demoNotes.length - demoLive;
  stdout.writeln(
    '  [示例] 开头：共 ${demoNotes.length} 篇'
    '（存活 $demoLive、在回收站 $demoTrashed）',
  );

  // ---------------------------------------------------------- 2. 脚本残留笔记
  stdout.writeln('');
  stdout.writeln('=== 2. 脚本残留的笔记 ===');
  final residueNotes = (allNotes.value?.notes ?? const <NoteSummary>[])
      .where((NoteSummary n) => _isResidue(n.title))
      .toList();
  stdout.writeln('  共 ${residueNotes.length} 篇');
  for (final n in residueNotes.take(20)) {
    stdout.writeln('    ${n.deleted ? "回收站" : "存活  "}  ${n.title}');
  }
  if (residueNotes.length > 20) {
    stdout.writeln('    …还有 ${residueNotes.length - 20} 篇');
  }
  if (apply) {
    for (final n in residueNotes) {
      // 顺序：恢复 → 删除 → 彻底删除。
      // 直接 purge 会因为"不在回收站中"被拒（那是刻意的护栏）。
      if (!n.deleted) {
        await notesDelete(id: n.id, atMs: now);
      }
      await notesPurge(id: n.id);
    }
    stdout.writeln('  已清理 ${residueNotes.length} 篇');
  }

  // ---------------------------------------------------------- 3. 脚本残留目录
  stdout.writeln('');
  stdout.writeln('=== 3. 脚本残留的目录 ===');
  // 判断依据是"**名称带我的脚本前缀**，或父链上有一个带的"。
  //
  // ## 两个血的教训写在这里
  //
  // 1. **只顾活着的那棵树会漏掉回收站里的父子关系**：
  //    `[排序核对]父` 与它的子目录 `甲/乙/丙` 都在回收站里，
  //    只看活树就查不到父链，于是 `甲` 被判成"不是残留"。
  //    第一版就是这样漏了 3 个。
  // 2. **快照会过期**：`trashed` 是在删除之前取的列表，某轮删掉父节点后，
  //    子节点的父指针就指向一个不在任何快照里的 id——查不到，
  //    于是又漏一轮。
  //
  // 因此这里**每次循环都重新取一次**列表与父链映射，而不是复用最初那份。
  // 多花几次查询换取"不漏"，对一个一次性维护脚本是划算的。
  var liveTree = await notebooksTree();
  var trashed = await notebooksTrashed();
  Map<String, (String, String?)> buildIndex() => <String, (String, String?)>{
    for (final NotebookNode n in liveTree.value!.notebooks)
      n.id: (n.name, n.parentId),
    for (final TrashedNotebook n in trashed.value!.trashedNotebooks)
      n.id: (n.name, n.parentId),
  };
  var byId = buildIndex();
  final residueTrashed =
      (trashed.value?.trashedNotebooks ?? const <TrashedNotebook>[])
          .where(
            (TrashedNotebook n) =>
                _isResidueOrUnderResidue(n.name, n.parentId, byId),
          )
          .toList();
  final residueLive = (liveTree.value?.notebooks ?? const <NotebookNode>[])
      .where(
        (NotebookNode n) => _isResidueOrUnderResidue(n.name, n.parentId, byId),
      )
      .toList();
  stdout.writeln(
    '  回收站里 ${residueTrashed.length} 个、还活着 ${residueLive.length} 个',
  );

  if (apply) {
    // 先处理活着的：整棵子树进回收站（自底向上地删才符合外键约束）
    for (final book
        in residueLive.toList()..sort(
          (NotebookNode a, NotebookNode b) => b.depth.compareTo(a.depth),
        )) {
      await notebooksDeleteSubtree(id: book.id, atMs: now);
    }

    var purged = 0;
    var refused = 0;
    // 反复扫几轮，**每轮都重新取列表与父链**。
    //
    // 一轮删掉子目录后父目录才满足条件，所以本来就要多轮；
    // 而"重新取"是必须的：快照里的父指针会指向已经删掉的节点，
    // 复用旧快照就会把子节点判成"不是残留"而漏掉（踩过两次）。
    for (var pass = 0; pass < 8; pass++) {
      liveTree = await notebooksTree();
      trashed = await notebooksTrashed();
      byId = buildIndex();
      final batch =
          (trashed.value?.trashedNotebooks ?? const <TrashedNotebook>[])
              .where(
                (TrashedNotebook n) =>
                    _isResidueOrUnderResidue(n.name, n.parentId, byId),
              )
              .toList()
            ..sort(
              (TrashedNotebook a, TrashedNotebook b) =>
                  b.name.split('/').length.compareTo(a.name.split('/').length),
            );
      if (batch.isEmpty) {
        break;
      }
      var changedThisPass = false;
      for (final book in batch) {
        final result = await notebooksPurge(id: book.id);
        if (result.ok) {
          purged++;
          changedThisPass = true;
        } else {
          refused++;
        }
      }
      if (!changedThisPass) {
        // 一轮下来一个都没删掉，说明剩下的都仍挂着子目录。
        // 再扫也没用，如实报告而不是空转。
        break;
      }
    }
    stdout.writeln('  已彻底删除 $purged 个，剩余 $refused 次尝试被拒（通常是因为仍挂着子目录）');
  }

  // ---------------------------------------------------------- 4. 小结
  stdout.writeln('');
  stdout.writeln('=== 小结 ===');
  final finalTrashed = await notebooksTrashed();
  final finalTrashedResidue =
      (finalTrashed.value?.trashedNotebooks ?? const <TrashedNotebook>[])
          .where((TrashedNotebook n) => _isResidue(n.name))
          .length;
  final finalTree = await notebooksTree();
  stdout.writeln('  左栏目录数：${finalTree.value!.notebooks.length}');
  stdout.writeln(
    '  回收站目录数：${finalTrashed.value!.trashedNotebooks.length}'
    '（其中脚本残留 $finalTrashedResidue）',
  );

  if (!apply) {
    stdout.writeln('');
    stdout.writeln('（这是预览。确认无误后加 --apply 真的清理。）');
  }

  await engineClose();
  exit(0);
}
