import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/portrait.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/ui/portrait_port_page.dart';

import 'rom_paths.dart';

const dir = romDir;
const fe6jp = '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

RomSession _session(String path, String name) =>
    RomSession.open(File(path).readAsBytesSync(), name)!;

void main() {
  testWidgets('列出源/目标 ROM，默认取另一个会话作目标', (tester) async {
    final s6 = _session(fe6jp, '封印.gba');
    final s8 = _session(fe8jp, '圣魔.gba');

    await tester.pumpWidget(MaterialApp(
      home: PortraitPortPage(sessions: [s6, s8], current: s6),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('肖像移植'), findsOneWidget);
    expect(find.text('源 ROM（取图）'), findsOneWidget);
    expect(find.text('目标 ROM（写入）'), findsOneWidget);
    // 两个 ROM 都列出来了
    expect(find.text('FE6'), findsWidgets);
    expect(find.text('FE8J'), findsWidgets);
  });

  testWidgets('只有一个 ROM 时提示不能移植', (tester) async {
    final s6 = _session(fe6jp, '封印.gba');
    await tester.pumpWidget(MaterialApp(
      home: PortraitPortPage(sessions: [s6], current: s6),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('同一份 ROM'), findsOneWidget);
    // FilledButton.icon 生成的是私有子类，按类型取不到；这里按文案定位那个按钮，
    // 再取它自己的 ButtonStyleButton 祖先（SegmentedButton 也是同类控件，不能滥取）。
    final btn = tester.widget<ButtonStyleButton>(find
        .ancestor(
          of: find.text('追加'),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        )
        .first);
    expect(btn.onPressed, isNull, reason: '同源同目标时禁止移植');
  });

  testWidgets('移植后目标 ROM 多出一条肖像', (tester) async {
    final s6 = _session(fe6jp, '封印.gba');
    final s8 = _session(fe8jp, '圣魔.gba');
    final before = PortraitReader(s8.rom.rom).entryCount;

    await tester.pumpWidget(MaterialApp(
      home: PortraitPortPage(sessions: [s6, s8], current: s6),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('追加'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('已写入目标 ROM'), findsOneWidget);
    expect(s8.rom.hasChanges, isTrue);
    final after = PortraitReader(s8.rom.liveRom).entryCount;
    expect(after, greaterThan(before));
  });

  testWidgets('切换到替换模式后显示目标 ID 与影响面', (tester) async {
    final s6 = _session(fe6jp, '封印.gba');
    final s8 = _session(fe8jp, '圣魔.gba');
    await tester.pumpWidget(MaterialApp(
      home: PortraitPortPage(sessions: [s6, s8], current: s6),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('写入方式'), findsOneWidget);
    expect(find.text('追加'), findsOneWidget);

    await tester.tap(find.text('替换已有'));
    await tester.pump();

    expect(find.text('目标肖像 ID'), findsOneWidget);
    // 会显示「目标第 N 条当前用于：…」或「没有角色或职业使用它」
    expect(find.textContaining('目标第 1 条'), findsOneWidget);

    // 按钮文案跟着变成「替换」
    expect(find.text('替换'), findsOneWidget);
  });

  testWidgets('替换模式真的覆盖目标条目（条目数不变）', (tester) async {
    final s6 = _session(fe6jp, '封印.gba');
    final s8 = _session(fe8jp, '圣魔.gba');
    final before = PortraitReader(s8.rom.rom).entryCount;

    await tester.pumpWidget(MaterialApp(
      home: PortraitPortPage(sessions: [s6, s8], current: s6),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('替换已有'));
    await tester.pump();
    await tester.tap(find.text('替换'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('已替换目标 ROM 的第 #1 条'), findsOneWidget);
    expect(s8.rom.hasChanges, isTrue);
    expect(PortraitReader(s8.rom.liveRom).entryCount, before,
        reason: '替换不新增条目');
  });

  testWidgets('预览显示源肖像', (tester) async {
    final s6 = _session(fe6jp, '封印.gba');
    final s8 = _session(fe8jp, '圣魔.gba');
    await tester.pumpWidget(MaterialApp(
      home: PortraitPortPage(sessions: [s6, s8], current: s6),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('源肖像 #1 预览'), findsOneWidget);
    expect(find.byType(Image), findsWidgets);
  });
}
