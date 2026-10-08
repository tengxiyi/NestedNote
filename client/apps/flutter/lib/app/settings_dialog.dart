// SPDX-License-Identifier: AGPL-3.0-or-later
//! 设置与维护对话框。
//!
//! ## 为什么"设置"里放的是维护操作
//!
//! 本应用目前几乎没有可配置项（本地优先、无账户、无同步），
//! 但有两类**用户迟早需要**的能力一直没有入口：
//!
//! - **附件清理**：删掉的笔记留下的附件文件会在宽限期后变成孤儿，
//!   内核的 GC 能清掉它们，但此前界面上没有任何触发方式；
//! - **完整性核对**：用户怀疑数据出问题时（本项目真实发生过），
//!   一个按钮比"去命令行跑 CLI 工具"友好得多。
//!
//! 把它们放进「工具 → 设置」而不是单独的"维护"菜单：
//! 用户不该需要理解"维护"和"设置"的区别——他想的是"这个软件
//! 有没有一个地方能帮我看看数据好不好"。
//!
//! ## 展示数字的原则
//!
//! GC 的每个数字都要**有名有姓地显示**，特别是 `kept_recent`
//! （仍在宽限期内而保留的文件数）。用户看到"只删了 3 个"而目录里
//! 还有一堆没被引用的文件时，是**这个数字**在解释"其余的不是丢了，
//! 是还在保护期里"。少显示一个数字，就会多一次"数据丢了吗"的惊吓。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/engine.dart';
import '../core/engine_providers.dart';
import '../core/trash_providers.dart';
import '../core/maintenance_providers.dart' as maintenance;
import 'typography.dart' show kEmphasisWeight;

/// 打开设置对话框。
Future<void> showSettingsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => const _SettingsDialog(),
  );
}

class _SettingsDialog extends ConsumerStatefulWidget {
  const _SettingsDialog();

  @override
  ConsumerState<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<_SettingsDialog> {
  /// 附件清理正在进行。
  bool _gcRunning = false;

  /// 完整性核对正在进行。
  bool _checkRunning = false;

  /// 最近一次操作的给人看的结论（成功与失败都走这里）。
  String? _lastReport;

  /// 最近一次操作是否出了问题（决定结论的颜色）。
  bool _lastReportIsError = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<EngineStatus> engine = ref.watch(engineProvider);
    final EngineStatus? status = engine.value;
    final String? databasePath = status?.databasePath;
    final AsyncValue<int> retention = ref.watch(trashRetentionDaysProvider);

    return AlertDialog(
      title: const Text('设置'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('存储', style: _sectionStyle(theme)),
              const SizedBox(height: 4),
              _pathRow(context, theme, databasePath),
              const SizedBox(height: 8),
              Text(
                retention.hasValue
                    ? '回收站保留期：${retention.value} 天（到期自动彻底删除，期间可恢复）'
                    : '回收站保留期：读取中…',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),

              Text('维护', style: _sectionStyle(theme)),
              const SizedBox(height: 4),
              Text(
                '这两个操作都直接作用于你的数据，但都不会删除笔记本身。',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  FilledButton.tonal(
                    // 防呆：两个操作都在跑时禁用另一个，避免并发写
                    onPressed: _gcRunning || _checkRunning
                        ? null
                        : () => _runGc(theme),
                    child: _gcRunning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('清理附件缓存'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _gcRunning || _checkRunning
                        ? null
                        : () => _runIntegrityCheck(theme),
                    child: _checkRunning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('核对数据库完整性'),
                  ),
                ],
              ),
              if (_lastReport != null) ...<Widget>[
                const SizedBox(height: 12),
                SelectableText(
                  _lastReport!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _lastReportIsError ? theme.colorScheme.error : null,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  TextStyle? _sectionStyle(ThemeData theme) => theme.textTheme.labelLarge
      ?.copyWith(fontWeight: kEmphasisWeight, color: theme.colorScheme.primary);

  /// 数据库路径 + 复制按钮。
  ///
  /// 报问题时用户最常需要回答的就是"数据在哪"，给一键复制，
  /// 省得他照着屏幕敲。
  Widget _pathRow(BuildContext context, ThemeData theme, String? path) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: SelectableText(
            path ?? '（引擎未就绪，暂时读不到）',
            style: theme.textTheme.bodySmall,
          ),
        ),
        IconButton(
          tooltip: '复制路径',
          visualDensity: VisualDensity.compact,
          onPressed: path == null
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: path));
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('路径已复制。')));
                  }
                },
          icon: const Icon(Icons.copy_all_outlined, size: 16),
        ),
      ],
    );
  }

  /// 运行附件清理。
  ///
  /// ## 为什么报告"清理完成 N 个"而不用 SnackBar
  ///
  /// 结果有四个数字（删除/保留/释放/断链），SnackBar 一行放不下，
  /// 放下也看不清。数字之间有关系（删得少可能是因为保留得多），
  /// 放在对话框里让用户可以对着看。
  Future<void> _runGc(ThemeData theme) async {
    setState(() {
      _gcRunning = true;
      _lastReport = null;
    });
    final maintenance.MaintenanceResult report = await maintenance
        .gcAttachments(DateTime.now().millisecondsSinceEpoch);
    if (!mounted) {
      return;
    }
    setState(() {
      _gcRunning = false;
      if (!report.ok) {
        _lastReportIsError = true;
        _lastReport = '清理失败：${report.hint ?? '未知原因'}';
        return;
      }
      _lastReportIsError = report.brokenLinks.toInt() > 0;
      _lastReport = _gcSummary(report);
    });
  }

  String _gcSummary(maintenance.MaintenanceResult report) {
    final String freed = _formatBytes(report.freedBytes.toInt());
    final String base = '清理完成：删除 ${report.removedFiles.toInt()} 个文件，释放 $freed。';
    if (report.keptRecent.toInt() > 0) {
      // 保留数必须解释，否则"删得少"会让人怀疑没生效
      return '$base\n另有 ${report.keptRecent.toInt()} 个文件仍在删除保护期内，到期后可再清理。';
    }
    if (report.brokenLinks.toInt() > 0) {
      return '$base\n⚠ 发现 ${report.brokenLinks.toInt()} 处断链（记录存在但文件缺失）。'
          '这不是本次清理造成的，建议备份数据目录后核对。';
    }
    return base;
  }

  Future<void> _runIntegrityCheck(ThemeData theme) async {
    setState(() {
      _checkRunning = true;
      _lastReport = null;
    });
    final maintenance.MaintenanceResult report = await maintenance
        .checkIntegrity();
    if (!mounted) {
      return;
    }
    setState(() {
      _checkRunning = false;
      _lastReportIsError = !report.ok;
      _lastReport = report.ok
          ? (report.integrityDetail ?? '数据库完整性核对通过。')
          : '核对未通过：${report.hint ?? '未知原因'}。建议先备份数据目录。';
    });
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    final double kb = bytes / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(1)} KB';
    }
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }
}
