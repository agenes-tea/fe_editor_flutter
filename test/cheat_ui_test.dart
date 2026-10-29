import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/playable_units.dart';
import 'package:fe_editor/ui/cheat_page.dart';

const dir = '/root/workspace/game-rom';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';

EditableRom _edit() {
  final d = File(fe7jp).readAsBytesSync();
  return EditableRom.open(d, FeRom.detectTable(d)!);
}

/// 按预设标题找到整张卡片（ListTile 才是命中区，文字行可能出屏）。
Finder _preset(String title) => find.byWidgetPredicate(
      (w) => w is ListTile &&
          w.title is Text &&
          (w.title! as Text).data == title,
      skipOffstage: false,
    );

void main() {
  testWidgets('修改器页面列出可见预设，并默认只作用于我方角色', (tester) async {
    final edit = _edit();
    await tester.pumpWidget(MaterialApp(home: CheatListPage(edit: edit)));
    await tester.pump();

    expect(find.text('作用范围'), findsOneWidget);
    // 角色类预设出现在列表
    await tester.scrollUntilVisible(find.text('我方角色成长率拉满'), 100);
    expect(find.text('我方角色成长率拉满'), findsOneWidget);

    // 作用范围默认「有支援数据」口径，条数应小于全表
    final allies = PlayableUnits(edit.rom).indices().length;
    expect(allies, lessThan(edit.rom.unitCount));
    expect(find.textContaining('$allies 条'), findsWidgets);

    // 下面的预设需要滚动才可见（列表较长）
    await tester.scrollUntilVisible(find.text('我方角色成长率 200%'), 200);
    expect(find.text('我方角色成长率 200%'), findsOneWidget);
  });

  testWidgets('作用范围可选三种口径，并显示各自条数', (tester) async {
    final edit = _edit();
    await tester.pumpWidget(MaterialApp(home: CheatListPage(edit: edit)));
    await tester.pump();

    expect(find.text('作用范围'), findsOneWidget);
    for (final c in PlayableCriterion.values) {
      expect(find.text(c.label), findsOneWidget, reason: c.label);
    }
    // 「我方 + 敌方主要角色」的条数多于仅我方
    final pu = PlayableUnits(edit.rom);
    final bySort = pu.indices(criterion: PlayableCriterion.sortOrder).length;
    final bySup = pu.indices().length;
    expect(bySort, greaterThan(bySup));
    expect(find.textContaining('$bySort 条'), findsWidgets);
  });

  testWidgets('点预设弹确认框，取消则不修改', (tester) async {
    final edit = _edit();
    await tester.pumpWidget(MaterialApp(home: CheatListPage(edit: edit)));
    await tester.pump();

    // 列表较长，用 scrollUntilVisible 滚到卡片（布局变了也不会碰位置）
    await tester.scrollUntilVisible(
      _preset('我方角色属性强化'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(_preset('我方角色属性强化'));
    await tester.pumpAndSettle();
    expect(find.text('应用'), findsOneWidget);
    expect(find.textContaining('HP → 20'), findsOneWidget);
    // 确认框里写明作用范围
    expect(find.textContaining('作用范围：'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(edit.hasChanges, isFalse, reason: '取消不应写入任何字节');
  });

  testWidgets('确认后真的写入，且出现撤销入口', (tester) async {
    final edit = _edit();
    await tester.pumpWidget(MaterialApp(home: CheatListPage(edit: edit)));
    await tester.pump();

    await tester.scrollUntilVisible(
      _preset('我方角色属性强化'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(_preset('我方角色属性强化'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    expect(edit.hasChanges, isTrue);
    expect(find.text('撤销全部'), findsOneWidget);
    expect(find.textContaining('已修改'), findsWidgets);

    await tester.tap(find.text('撤销全部'));
    await tester.pumpAndSettle();
    expect(edit.hasChanges, isFalse);
    expect(find.text('撤销全部'), findsNothing);
  });

  testWidgets('切到「全部单位」口径时确认框给出敌方警告', (tester) async {
    final edit = _edit();
    await tester.pumpWidget(MaterialApp(home: CheatListPage(edit: edit)));
    await tester.pump();

    // 选中第三种口径
    await tester.tap(find.text(PlayableCriterion.all.label));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      _preset('我方角色属性强化'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(_preset('我方角色属性强化'));
    await tester.pumpAndSettle();
    expect(find.textContaining('会连同敌人一起加强'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(edit.hasChanges, isFalse);
  });
}
