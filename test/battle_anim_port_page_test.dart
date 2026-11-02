import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/battle_anim.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/ui/battle_anim_port_page.dart';

const dir = '/root/workspace/game-rom';
const fe6jp = '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

RomSession _session(String path, String name) =>
    RomSession.open(File(path).readAsBytesSync(), name)!;

void main() {
  testWidgets('列出源/目标 ROM，默认替换模式', (tester) async {
    final s6 = _session(fe6jp, '封印.gba');
    final s8 = _session(fe8jp, '圣魔.gba');
    await tester.pumpWidget(MaterialApp(
      home: BattleAnimPortPage(sessions: [s6, s8], current: s6),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('战斗动画移植'), findsOneWidget);
    expect(find.text('源动画 ID'), findsOneWidget);
    expect(find.text('目标动画 ID'), findsOneWidget, reason: '默认是替换模式');
    expect(find.text('替换'), findsOneWidget);
  });

  testWidgets('只有一个 ROM 时按钮禁用', (tester) async {
    final s6 = _session(fe6jp, '封印.gba');
    await tester.pumpWidget(MaterialApp(
      home: BattleAnimPortPage(sessions: [s6], current: s6),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    final btn = tester.widget<ButtonStyleButton>(find
        .ancestor(
          of: find.text('替换'),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        )
        .first);
    expect(btn.onPressed, isNull);
  });

  testWidgets('替换后目标动画被覆盖（条目数不变）', (tester) async {
    final s6 = _session(fe6jp, '封印.gba');
    final s8 = _session(fe8jp, '圣魔.gba');
    final before = BattleAnimReader(s8.rom.rom).count;
    final abbrBefore = BattleAnimReader(s8.rom.rom).entry(0)!.abbr;
    final srcAbbr = BattleAnimReader(s6.rom.rom).entry(0)!.abbr;

    await tester.pumpWidget(MaterialApp(
      home: BattleAnimPortPage(sessions: [s6, s8], current: s6),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('替换'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.textContaining('已写入目标 ROM 第 #0 条动画'), findsOneWidget);
    final after = BattleAnimReader(s8.rom.liveRom);
    expect(after.count, before, reason: '替换不改条目数');
    // 缩写沿用源端的，说明确实是源那条搬过去了
    expect(after.entry(0)!.abbr, srcAbbr);
    expect(s8.rom.hasChanges, isTrue);
    // 至少证明原来那条的缩写被换掉了（除非本来同名）
    if (abbrBefore != srcAbbr) {
      expect(after.entry(0)!.abbr, isNot(abbrBefore));
    }
  });

  testWidgets('目标条目的现状会显示出来', (tester) async {
    final s6 = _session(fe6jp, '封印.gba');
    final s8 = _session(fe8jp, '圣魔.gba');
    await tester.pumpWidget(MaterialApp(
      home: BattleAnimPortPage(sessions: [s6, s8], current: s6),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('目标第 0 条现在是'), findsOneWidget);
  });

  testWidgets('切到追加模式后目标 ID 输入框消失', (tester) async {
    final s6 = _session(fe6jp, '封印.gba');
    final s8 = _session(fe8jp, '圣魔.gba');
    await tester.pumpWidget(MaterialApp(
      home: BattleAnimPortPage(sessions: [s6, s8], current: s6),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('追加'));
    await tester.pump();

    expect(find.text('目标动画 ID'), findsNothing);
    expect(find.text('追加'), findsWidgets);
  });
}
