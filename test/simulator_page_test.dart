import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/ui/simulator_page.dart';

/// 模拟器页面（战斗/成长模拟器）的 widget 测试。
///
/// 覆盖：两个 tab、角色/武器选择器、改前 vs 改后对比模式的三种状态
/// （未改动 / 已改动 / 战斗双卡片）。
const dir = '/root/workspace/game-rom';
const fe8jp =
    '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

/// 同步开 ROM（FakeAsync 测试体里别用 `Future(() => ...)`：
/// 事件定时器只有 `binding.pump` 推进假时钟才跑，await 它永远不完成）。
RomSession _open() => RomSession.open(File(fe8jp).readAsBytesSync(), 'fe8jp.gba')!;

Future<void> _pump(SimulatorPage page, WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(home: page));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('成长模拟：角色行 / 目标等级 / 属性表 / 曲线图例', (tester) async {
    final s = _open();
    await _pump(SimulatorPage(edit: s.rom), tester);

    expect(find.text('模拟器'), findsOneWidget);
    expect(find.text('成长模拟'), findsWidgets); // tab 标题
    final name = s.liveRom.unitDisplayName(0).trim();
    expect(name, isNotEmpty);
    expect(find.textContaining(name), findsWidgets);
    // 属性表表头 + 曲线图例（同名文案各一处）
    expect(find.text('期望'), findsWidgets);
    expect(find.text('最坏'), findsWidgets);
    expect(find.text('最好'), findsWidgets);
    expect(find.text('上限'), findsOneWidget, reason: '只有表头一处');
    // 目标等级默认 20
    expect(find.text('20'), findsWidgets);
    // 曲线与图例在视口外（ListView 懒加载），滚下去再看
    await tester.scrollUntilVisible(
        find.textContaining('职业上限'),
        300,
        scrollable: find.byType(Scrollable).at(1));
    // 注：at(0) 是 TabBarView(PageView) 的横向 Scrollable，面板的 ListView 恒为 at(1)
    expect(find.textContaining('职业上限'), findsOneWidget, reason: '图例里带数值');
    expect(find.text('期望'), findsWidgets, reason: '表头 + 图例各一处');
    expect(find.text('改前 vs 改后'), findsNothing,
        reason: '未开对比模式时不出现对比区块');
  });

  testWidgets('战斗模拟：默认选择出结果卡片与关键行', (tester) async {
    final s = _open();
    await _pump(SimulatorPage(edit: s.rom), tester);

    await tester.tap(find.text('战斗模拟').first);
    await tester.pumpAndSettle();

    expect(find.text('攻方'), findsOneWidget);
    expect(find.text('守方'), findsOneWidget);
    expect(find.text('距离'), findsOneWidget);
    // 结果卡片
    expect(find.text('模拟结果'), findsOneWidget);
    expect(find.text('伤害'), findsWidgets);
    expect(find.text('命中'), findsWidgets);
    expect(find.text('每回合期望伤害'), findsOneWidget);
    expect(find.text('一回合结果'), findsOneWidget);
    // 近似值提示
    expect(find.textContaining('不计地形'), findsOneWidget);
  });

  testWidgets('角色选择器：整行可点，搜索后点选改变攻方', (tester) async {
    final s = _open();
    await _pump(SimulatorPage(edit: s.rom), tester);
    await tester.tap(find.text('战斗模拟').first);
    await tester.pumpAndSettle();

    // 点「攻方」行开选择器
    await tester.tap(find.text('攻方'));
    await tester.pumpAndSettle();
    expect(find.textContaining('选择角色'), findsOneWidget);

    // 按编号搜（日版名字里没有数字，匹配唯一）
    await tester.enterText(find.byType(TextField).last, '1');
    await tester.pumpAndSettle();
    await tester.tap(find.text('#1').first);
    await tester.pumpAndSettle();
    expect(s.rom.hasChanges, isFalse, reason: '模拟不改 ROM');
  });

  testWidgets('对比模式：未改动时两个 tab 都提示「还没有改动」',
      (tester) async {
    final s = _open();
    await _pump(SimulatorPage(edit: s.rom), tester);

    await tester.tap(find.text('对比改前/改后'));
    await tester.pumpAndSettle();
    // 提示卡在视口外，滚到再断言
    await tester.scrollUntilVisible(
        find.textContaining('还没有改动'),
        300,
        scrollable: find.byType(Scrollable).at(1));
    // 成长与战斗两个面板（TabBarView 预建相邻 tab）各一张提示卡
    expect(find.textContaining('还没有改动'), findsWidgets);
  });

  testWidgets('对比模式：改字段后成长页出对比表、战斗页出双卡片',
      (tester) async {
    final s = _open();
    await _pump(SimulatorPage(edit: s.rom), tester);
    await tester.tap(find.text('对比改前/改后'));
    await tester.pumpAndSettle();

    // 改一个数值字段（力量 +1）
    final f = unitEditableFields.firstWhere((f) => f.label == '力量');
    final addr = s.rom.unitAddress(0);
    final cur = s.rom.readField(addr, f);
    expect(
        s.rom.writeField(addr, f, cur >= 127 ? cur - 1 : cur + 1), isTrue);

    // 重新挂载页面（模拟从修改器返回）
    await _pump(SimulatorPage(edit: s.rom), tester);
    await tester.tap(find.text('对比改前/改后'));
    await tester.pumpAndSettle();

    expect(find.text('还没有改动'), findsNothing);

    // 战斗页：改前/改后两张卡片（成长页此时显示对比表，没有同名标题）
    await tester.tap(find.text('战斗模拟').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('改后（当前）'),
        300,
        scrollable: find.byType(Scrollable).at(1));
    expect(find.text('改前（原始快照）'), findsOneWidget);
    expect(find.text('改后（当前）'), findsOneWidget);
    expect(find.text('模拟结果'), findsNothing,
        reason: '对比模式下不再用单卡片');
    // 成长页对比表列出了有差异的属性
    await tester.tap(find.text('成长模拟').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.textContaining('改前 vs 改后（期望值'),
        300,
        scrollable: find.byType(Scrollable).at(1));
    expect(find.textContaining('改前 vs 改后（期望值'), findsOneWidget);
    expect(find.textContaining('力量'), findsWidgets);
  });

  testWidgets('撤销全部改动后对比模式回到「还没有改动」', (tester) async {
    final s = _open();
    final f = unitEditableFields.firstWhere((f) => f.label == '力量');
    final addr = s.rom.unitAddress(0);
    final cur = s.rom.readField(addr, f);
    expect(s.rom.writeField(addr, f, cur >= 127 ? cur - 1 : cur + 1), isTrue);

    await _pump(SimulatorPage(edit: s.rom), tester);
    await tester.tap(find.text('对比改前/改后'));
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有改动'), findsNothing);

    s.rom.revertAll();
    await _pump(SimulatorPage(edit: s.rom), tester);
    await tester.tap(find.text('对比改前/改后'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.textContaining('还没有改动'),
        300,
        scrollable: find.byType(Scrollable).at(1));
    expect(find.textContaining('还没有改动'), findsWidgets);
  });
}
