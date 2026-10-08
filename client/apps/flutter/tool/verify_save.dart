import 'dart:io';
import 'package:nestednote/src/rust/api/notes.dart';
import 'package:nestednote/src/rust/frb_generated.dart';
import 'app_paths.dart';

Future<void> main() async {
  final dir = resolveAppDataDirForTools();
  await RustLib.init();

  // 第一次：创建并保存
  var status = await engineStart(dataDir: dir.path);
  stdout.writeln('引擎1 ready=${status.ready}');
  final now = DateTime.now().millisecondsSinceEpoch;
  final created = await notesCreate(title: '[验证保存]', atMs: now);
  final id = created.value!.note!.id;
  stdout.writeln('创建 version=${created.value!.note!.version.toInt()}');

  final saved = await notesSave(
    id: id,
    title: null,
    text: '这段文字必须能被读回',
    atMs: now + 1,
  );
  stdout.writeln(
    '保存 ok=${saved.ok} version=${saved.value?.note?.version.toInt()}',
  );
  final readBack = await notesRead(id: id);
  stdout.writeln('同进程读回: ${readBack.value?.text}');

  // 关键一步：**关掉引擎**（模拟切出去 / 重启），再重新打开
  await engineClose();
  status = await engineStart(dataDir: dir.path);
  stdout.writeln('引擎2 ready=${status.ready}（模拟重启）');
  final after = await notesRead(id: id);
  stdout.writeln('重启后读回: ${after.value?.text}');
  stdout.writeln(
    after.value?.text == '这段文字必须能被读回' ? '结论：持久化正确' : '结论：**数据丢了**',
  );

  // 清理
  await notesDelete(id: id, atMs: now + 2);
  await notesPurge(id: id);
  await engineClose();
}
