import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/rom_info.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/ui/rom_session_bar.dart';

const dir = '/root/workspace/game-rom';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

void main() {
  testWidgets('会话栏列出全部已打开 ROM，点击与长按分别回调', (tester) async {
    final s7 = RomSession.open(
        File(fe7jp).readAsBytesSync(), '烈火之剑.gba')!;
    final s8 = RomSession.open(
        File(fe8jp).readAsBytesSync(), '圣魔之光石.gba')!;

    final selected = <int>[];
    final closed = <int>[];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RomSessionBar(
          sessions: [s7, s8],
          activeId: s8.id,
          onSelect: (s) => selected.add(s.id),
          onClose: (s) => closed.add(s.id),
        ),
      ),
    ));

    expect(find.text('FE7J'), findsOneWidget);
    expect(find.text('FE8J'), findsOneWidget);
    expect(find.text('烈火之剑.gba'), findsOneWidget);

    await tester.tap(find.text('FE7J'));
    expect(selected, [s7.id]);

    await tester.longPress(find.text('圣魔之光石.gba'));
    expect(closed, [s8.id]);
  });

  testWidgets('有改动时显示改动字节数', (tester) async {
    final s8 = RomSession.open(File(fe8jp).readAsBytesSync(), 'fe8.gba')!;
    const level = EditField('等级', UnitOffsets.level, min: 1, max: 60);
    s8.rom.writeField(s8.rom.unitAddress(1), level, 20);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RomSessionBar(
          sessions: [s8],
          activeId: s8.id,
          onSelect: (_) {},
          onClose: (_) {},
        ),
      ),
    ));
    expect(find.textContaining('已改'), findsOneWidget);
  });
}
