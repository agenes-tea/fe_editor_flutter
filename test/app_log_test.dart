import 'dart:io';

import 'package:fe_editor/core/app_log.dart';
import 'package:flutter_test/flutter_test.dart';

/// AppLog：内存日志 / 文件日志 / 清空 / 容量上限。
void main() {
  test('内存日志：记录、快照、文本导出', () {
    AppLog.instance.log('info', '你好');
    AppLog.instance.log('error', '出事了');
    final snap = AppLog.instance.snapshot();
    expect(snap, isNotEmpty);
    expect(snap.first.level, 'info');
    expect(AppLog.instance.allText(), contains('[INFO] 你好'));
    expect(AppLog.instance.allText(), contains('[ERROR] 出事了'));
  });

  test('超过内存上限后只保留最近条目', () {
    for (var i = 0; i < 420; i++) {
      AppLog.instance.log('info', 'n$i');
    }
    final snap = AppLog.instance.snapshot();
    expect(snap.length, lessThanOrEqualTo(400));
    expect(snap.last.message, 'n419');
  });

  test('文件日志：attachFileAt 落盘、flush、清空', () async {
    final tmp = await Directory.systemTemp.createTemp('applog_test');
    try {
      await AppLog.instance.attachFileAt(tmp.path);
      expect(AppLog.instance.hasFile, isTrue);
      AppLog.instance.log('info', '落盘条目');
      await AppLog.instance.flush();
      final content =
          await File('${tmp.path}/fe_editor.log').readAsString();
      expect(content, contains('落盘条目'));

      await AppLog.instance.clear();
      await AppLog.instance.flush();
      final after = await File('${tmp.path}/fe_editor.log').readAsString();
      expect(after, contains('日志已清空'));
      expect(after, isNot(contains('落盘条目')));
      expect(AppLog.instance.snapshot().last.message, '日志已清空');
    } finally {
      await tmp.delete(recursive: true);
    }
  });
}
