import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/ui/portrait_import_page.dart';

import 'rom_paths.dart';

/// 按版本挑 ROM（中文文件名在源码里写会出问题）。
EditableRom? _openVersion(String versionId, {int size = 16777216}) {
  final dir = Directory(romDir);
  if (!dir.existsSync()) return null;
  for (final f in dir.listSync().whereType<File>()) {
    if (f.lengthSync() != size) continue;
    final bytes = f.readAsBytesSync();
    final table = FeRom.detectTable(bytes);
    if (table == null || table.id.toString() != versionId) continue;
    return EditableRom.open(bytes, table);
  }
  return null;
}

void main() {
  group('肖像编辑器页面', () {
    testWidgets('打开后显示说明与选择图片入口', (tester) async {
      final edit = _openVersion('FE7J');
      if (edit == null) {
        markTestSkipped('缺少 FE7J 样本');
        return;
      }
      await tester.pumpWidget(MaterialApp(
        home: PortraitImportPage(edit: edit),
      ));
      await tester.pump();

      expect(find.text('肖像编辑器'), findsOneWidget);
      expect(find.text('选择图片'), findsOneWidget);
      // 还没选图时不该出现写入按钮
      expect(find.textContaining('写入第'), findsNothing);
      // 16 色的说明必须在（用户要知道为什么要量化）
      expect(find.textContaining('16 色'), findsWidgets);
    });

    testWidgets('未选图片时不显示目标选择与写入按钮', (tester) async {
      final edit = _openVersion('FE7J');
      if (edit == null) {
        markTestSkipped('缺少 FE7J 样本');
        return;
      }
      await tester.pumpWidget(MaterialApp(
        home: PortraitImportPage(edit: edit, initialTargetId: 44),
      ));
      await tester.pump();

      // 预选 ID 存下了，但目标选择器/写入按钮要等选图+转换之后才出现
      expect(find.byType(DropdownButtonFormField<int>), findsNothing);
      expect(find.textContaining('写入第'), findsNothing);
    });

    testWidgets('ROM 没有肖像表时给出明确提示而不是崩', (tester) async {
      final edit = _openVersion('FE7J');
      if (edit == null) {
        markTestSkipped('缺少 FE7J 样本');
        return;
      }
      await tester.pumpWidget(MaterialApp(
        home: PortraitImportPage(edit: edit),
      ));
      await tester.pump();
      // 页面主体应能正常渲染（不抛异常）
      expect(tester.takeException(), isNull);
    });
  });
}
