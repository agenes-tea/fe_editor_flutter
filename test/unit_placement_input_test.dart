import 'dart:io';

import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/unit_placement.dart';
import 'package:fe_editor/ui/unit_placement_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const dir = '/root/workspace/game-rom';
const fe8jp =
    '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

({EditableRom edit, PlacedUnit unit}) openFirstUnit() {
  final data = File(fe8jp).readAsBytesSync();
  final edit = EditableRom.open(data, FeRom.detectTable(data)!);
  final up = UnitPlacement(edit);
  for (var ch = 0; ch < 10; ch++) {
    final slot = up.defaultSlot;
    final units = up.units(ch, slot);
    if (units.isNotEmpty) return (edit: edit, unit: units.first);
  }
  throw StateError('没找到章节单位');
}

void main() {
  testWidgets('道具格显示名字，且点数字能直接手输（不用点加减）', (tester) async {
    final r = openFirstUnit();
    await tester.pumpWidget(MaterialApp(
      home: PlacedUnitEditPage(edit: r.edit, unit: r.unit),
    ));
    await tester.pumpAndSettle();

    // 道具格存在（页面可滚动，先滚动到可见区）
    expect(find.text('道具 1'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('道具 4'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('道具 4'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('道具 2'), -200,
        scrollable: find.byType(Scrollable).first);

    // 点「道具 2」的数字（当前值那格）→ 弹输入框
    final item2Value = r.unit.items[1];
    final row2 = find.ancestor(
      of: find.text('道具 2'),
      matching: find.byType(Column),
    );
    expect(row2, findsWidgets);
    // 直接找道具区里的数字文本并点击（用第 2 个道具的当前值定位）
    final numberFinder = find.descendant(
      of: row2.first,
      matching: find.text('$item2Value'),
    );
    expect(numberFinder, findsWidgets);
    await tester.tap(numberFinder.first);
    await tester.pumpAndSettle();

    // 弹出的对话框里应有可输入的 TextField
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);

    // 输入 147 并确定
    await tester.enterText(find.byType(TextField), '147');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // ROM 里真的写进去了
    final reread = UnitPlacement(r.edit).unitAt(r.unit.addr)!;
    expect(reread.items[1], 147, reason: '手输 147 应直接写入，无需点 100 多次');
  });

  testWidgets('道具清单可按名字搜索并选中', (tester) async {
    final r = openFirstUnit();
    await tester.pumpWidget(MaterialApp(
      home: PlacedUnitEditPage(edit: r.edit, unit: r.unit),
    ));
    await tester.pumpAndSettle();

    // 打开第一个道具格的选择器（职业的 list 图标在道具之前，这里按行定位）
    await tester.scrollUntilVisible(find.text('道具 1'), 200,
        scrollable: find.byType(Scrollable).first);
    final item1Row = find
        .ancestor(of: find.text('道具 1'), matching: find.byType(Row))
        .first;
    await tester.tap(
        find.descendant(of: item1Row, matching: find.byIcon(Icons.list)));
    await tester.pumpAndSettle();
    expect(find.text('选择道具'), findsOneWidget);

    // 搜索框里输个名字片段，列表应缩小
    final names = [
      for (var i = 1; i < r.edit.liveRom.itemCount; i++)
        r.edit.liveRom.itemDisplayName(i).trim(),
    ].where((n) => n.isNotEmpty).toList();
    expect(names, isNotEmpty);
    final probe = names.first.substring(0, 1);
    await tester.enterText(find.byType(TextField), probe);
    await tester.pumpAndSettle();
    expect(find.textContaining(probe), findsWidgets);
  });

  testWidgets('超出范围的手输被拒绝，不写坏 ROM', (tester) async {
    final r = openFirstUnit();
    await tester.pumpWidget(MaterialApp(
      home: PlacedUnitEditPage(edit: r.edit, unit: r.unit),
    ));
    await tester.pumpAndSettle();

    final before = UnitPlacement(r.edit).unitAt(r.unit.addr)!.level;
    // 点等级的数字
    final row = find.ancestor(
      of: find.text('等级'),
      matching: find.byType(Row),
    );
    await tester.tap(
        find.descendant(of: row.first, matching: find.text('$before')).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '99'); // 等级上限 31
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(UnitPlacement(r.edit).unitAt(r.unit.addr)!.level, before,
        reason: '超范围应被拒绝');
  });

  testWidgets('职业清单可以按名字搜索', (tester) async {
    final r = openFirstUnit();
    await tester.pumpWidget(MaterialApp(
      home: PlacedUnitEditPage(edit: r.edit, unit: r.unit),
    ));
    await tester.pumpAndSettle();
    expect(find.text('职业 ID'), findsOneWidget);
    // 打开职业选择器（第 2 个 list 图标：道具 4 个在前？职业在道具之前）
    final lists = find.byIcon(Icons.list);
    expect(lists, findsWidgets);
    await tester.tap(lists.first);
    await tester.pumpAndSettle();
    expect(find.text('选择职业'), findsOneWidget);
  });
}
