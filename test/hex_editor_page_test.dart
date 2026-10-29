import 'dart:io';

import 'package:fe_editor/core/app_settings.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const dir = '/root/workspace/game-rom';
const fe7jp =
    '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';

void main() {
  testWidgets('十六进制编辑器：点选字节 + 数字键盘写入', (tester) async {
    final data = File(fe7jp).readAsBytesSync();
    final edit = EditableRom.open(data, FeRom.detectTable(data)!);
    await tester.pumpWidget(MaterialApp(home: HexEditorPage(edit: edit)));
    await tester.pump(const Duration(milliseconds: 100));

    final original = data[0];
    final h = original.toRadixString(16).padLeft(2, '0').toUpperCase();
    // 点第一个字节（偏移 0）使其选中，底部键盘随之启用
    await tester.tap(find.text(h).first);
    await tester.pump();

    // 键盘输入 5A（先高位后低位），凑满两位自动写回
    await tester.tap(find.text('5'));
    await tester.pump();
    await tester.tap(find.text('A'));
    await tester.pump();

    expect(edit.buffer.u8(0), 0x5A, reason: '键盘 5A 应写入偏移 0');
    expect(edit.edits, isNotEmpty);
    final e = edit.edits.last;
    expect(e.offset, 0);
    expect(e.before, original);
    expect(e.after, 0x5A);
  });

  testWidgets('暗色模式：FeEditorApp 应用 darkTheme', (tester) async {
    AppSettings.instance.themeModeIndex = 2;
    AppSettings.instance.themeNotifier.value = 2;
    await tester.pumpWidget(const FeEditorApp());
    await tester.pump();
    final theme = Theme.of(tester.element(find.byType(HomePage)));
    expect(theme.brightness, Brightness.dark,
        reason: '主题设为暗色时页面应为 dark');
    // 复位，避免污染其它用例
    AppSettings.instance.themeModeIndex = 0;
    AppSettings.instance.themeNotifier.value = 0;
  });
}
