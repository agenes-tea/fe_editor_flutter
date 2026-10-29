import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/text_browser.dart';
import 'package:fe_editor/ui/portrait_page.dart';
import 'package:fe_editor/ui/unit_page.dart';

const dir = '/root/workspace/game-rom';

/// 三个重度改版 ROM（2022-10 用户提供），按文件大小定位避免中文文件名进源码：
/// 佣兵公司完全汉化版（FE7U 底，25MB）、黑暗护符（FE8U 底，22.6MB）、HoloEmblem（FE8U 底，33.2MB）。
/// 共同特征：文本表是「UTF-8 中文 + 旧版 SJIS/二进制残留」混合体，
/// 少数条目不是合法 UTF-8——这些条目曾经让整页白屏。
final _sizes = {
  25073560: '佣兵公司完全汉化版',
  22606400: '黑暗护符（三部曲之一）',
  33215492: 'HoloEmblem',
};

List<({File file, String label})> _picks() {
  final out = <({File file, String label})>[];
  for (final f in Directory(dir).listSync().whereType<File>()) {
    final label = _sizes[f.lengthSync()];
    if (label != null) out.add((file: f, label: label));
  }
  return out;
}

void main() {
  test('全量条目名字解码不抛异常（角色/职业/道具）', () {
    for (final p in _picks()) {
      final d = p.file.readAsBytesSync();
      final rom = FeRom(d, FeRom.detectTable(d)!);
      for (var i = 0; i < rom.unitCount; i++) {
        rom.unitName(i);
      }
      for (var i = 0; i < rom.classCount; i++) {
        rom.className(i);
      }
      for (var i = 0; i < rom.itemCount; i++) {
        rom.itemName(i);
      }
      // 名字表里混有旧版残骸，但绝大多数必须是真中文
      final names = [for (var i = 0; i < rom.unitCount; i++) rom.unitName(i)];
      final cn = names.where((n) => n.codeUnits.any((c) => c > 0x4E00)).length;
      expect(cn, greaterThan(names.length ~/ 4), reason: p.label);
    }
  });

  test('文本浏览器全条目渲染不抛异常', () {
    for (final p in _picks()) {
      final d = p.file.readAsBytesSync();
      final rom = FeRom(d, FeRom.detectTable(d)!);
      final tb = TextBrowser(rom);
      final n = tb.maxId;
      for (var id = 0; id < n; id++) {
        tb.render(id);
      }
      expect(n, greaterThan(0), reason: p.label);
    }
  });

  testWidgets('角色/职业/肖像三个页面打开不崩', (tester) async {
    for (final p in _picks()) {
      final d = p.file.readAsBytesSync();
      final edit = EditableRom.open(d, FeRom.detectTable(d)!);

      // 角色页：滚到底把所有行（懒加载名字）都构建一遍
      await tester.pumpWidget(MaterialApp(home: UnitListPage(edit: edit)));
      await tester.pump(const Duration(milliseconds: 300));
      final name0 = edit.rom.unitDisplayName(0);
      if (name0.isNotEmpty) {
        expect(find.text(name0), findsWidgets, reason: '${p.label} 角色首行名字');
      }
      await _scrollToBottom(tester);
      expect(tester.takeException(), isNull, reason: '${p.label} 角色页');

      // 职业页
      await tester.pumpWidget(MaterialApp(home: ClassListPage(edit: edit)));
      await tester.pump(const Duration(milliseconds: 300));
      await _scrollToBottom(tester);
      expect(tester.takeException(), isNull, reason: '${p.label} 职业页');

      // 肖像页：条目分批加载 + 名字反查 + 图像解码，pump 足够多帧让批次跑完
      await tester.pumpWidget(MaterialApp(home: PortraitListPage(edit: edit)));
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.takeException(), isNull, reason: '${p.label} 肖像页');
      expect(find.textContaining('肖像'), findsWidgets, reason: p.label);
      // 肖像表能定位时，列表行必须真实渲染（名字反查已不抛）
      expect(find.byType(ListTile), findsWidgets, reason: '${p.label} 肖像行');
    }
  });
}

Future<void> _scrollToBottom(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable).first;
  for (var i = 0; i < 40; i++) {
    await tester.drag(scrollable, const Offset(0, -1200));
    await tester.pump(const Duration(milliseconds: 100));
  }
}
