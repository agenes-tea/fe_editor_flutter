import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/ui/battle_anim_page.dart';
import 'package:fe_editor/ui/chapter_page.dart';
import 'package:fe_editor/ui/unit_page.dart';

const dir = '/root/workspace/game-rom';

const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';
const fe6jp = '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';

void main() {
  testWidgets('角色列表与详情页能渲染', (tester) async {
    final data = File(fe7jp).readAsBytesSync();
    final edit = EditableRom.open(data, FeRom.detectTable(data)!);
    await tester.pumpWidget(MaterialApp(home: UnitListPage(edit: edit)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('エリウッド'), findsWidgets);
    // 点第一个角色
    await tester.tap(find.text('エリウッド').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('基础数值 / 成长率'), findsOneWidget);
    expect(find.text('查看职业'), findsOneWidget);
    // 熟练度区在下方，滚动后应出现
    final detailList = find.descendant(
      of: find.byType(UnitEditPage),
      matching: find.byType(ListView),
    );
    await tester.drag(detailList, const Offset(0, -1600));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('武器熟练度'), findsOneWidget);
  });

  testWidgets('职业详情页能渲染（含地图头像/职业卡）', (tester) async {
    final data = File(fe7jp).readAsBytesSync();
    final edit = EditableRom.open(data, FeRom.detectTable(data)!);
    await tester.pumpWidget(MaterialApp(home: ClassEditPage(edit: edit, index: 1)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('移动力'), findsOneWidget);
    expect(find.text('体格'), findsOneWidget);
    // 顶部图区：地图头像 / 职业卡 / 占位三者必居其一（先于滚动检查）
    final mapFound = find.text('地图头像').evaluate().isNotEmpty;
    final cardFound = find.text('职业卡').evaluate().isNotEmpty;
    final noneFound = find.textContaining('没有地图头像').evaluate().isNotEmpty;
    expect(mapFound || cardFound || noneFound, isTrue,
        reason: '职业详情页应展示地图头像/职业卡或占位提示');
    // CA_* 特性位区在页面下方，滚动到可见（84 字节条目版本才开放）
    await tester.dragUntilVisible(
      find.text('特性（CA_* 标志位）'),
      find.byType(ListView),
      const Offset(0, -1200),
    );
    expect(find.textContaining('CA_PROMOTED'), findsOneWidget);
  });

  testWidgets('职业列表页能渲染地图头像缩略图', (tester) async {
    final data = File(fe8jp).readAsBytesSync();
    final edit = EditableRom.open(data, FeRom.detectTable(data)!);
    await tester.pumpWidget(MaterialApp(home: ClassListPage(edit: edit)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ListView), findsOneWidget);
    expect(find.textContaining('职业 ('), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('战斗动画列表与详情页能渲染', (tester) async {
    final data = File(fe7jp).readAsBytesSync();
    final edit = EditableRom.open(data, FeRom.detectTable(data)!);
    await tester.pumpWidget(MaterialApp(home: BattleAnimListPage(edit: edit)));
    await tester.pump(const Duration(milliseconds: 100));
    // 条目标题里带缩写，取首条点进去
    expect(find.textContaining('erlm_sw1'), findsWidgets);
    await tester.tap(find.textContaining('erlm_sw1').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // 模式选择（可见区）与调色板组应出现
    expect(find.textContaining('待机'), findsWidgets);
    expect(find.text('自军'), findsOneWidget);
    expect(find.text('敌军'), findsOneWidget);
  });

  testWidgets('章节页：地图与单位合并在一屏', (tester) async {
    final data = File(fe8jp).readAsBytesSync();
    final edit = EditableRom.open(data, FeRom.detectTable(data)!);
    await tester.pumpWidget(MaterialApp(home: ChapterPage(edit: edit)));
    await tester.pump(const Duration(milliseconds: 300));

    // 标题带章节号；工具栏显示格数与单位数
    expect(find.text('第 0 章'), findsOneWidget);
    expect(find.textContaining('格'), findsWidgets);
    // 单位列表同时存在（不再需要另一个页面）
    expect(find.textContaining('Lv'), findsWidgets);
    expect(find.text('我方（普通）'), findsOneWidget);
    // FE8 有遭遇战 6 槽（敌方就配在遭遇敌方槽里）
    expect(find.text('遭遇敌方 1'), findsOneWidget);
    // 陷阱开关按钮（FE8 记录可解码）
    expect(find.byIcon(Icons.warning_amber), findsOneWidget);
  });

  testWidgets('章节页 FE6 红/蓝两路单位能渲染', (tester) async {
    final data = File(fe6jp).readAsBytesSync();
    final edit = EditableRom.open(data, FeRom.detectTable(data)!);
    await tester.pumpWidget(MaterialApp(home: ChapterPage(edit: edit)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('第 0 章'), findsOneWidget);
    expect(find.text('蓝方（我军）'), findsOneWidget);
    expect(find.text('红方（敌军）'), findsOneWidget);
    expect(find.textContaining('Lv'), findsWidgets);
  });

  testWidgets('章节页：事件动态单位并入列表（只读、标事件）', (tester) async {
    // 列表区默认只有一百多像素高，ListView 只构建可见行；测试里拉高画布
    // 才能数清全部行。
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = File(fe7jp).readAsBytesSync();
    final edit = EditableRom.open(data, FeRom.detectTable(data)!);
    await tester.pumpWidget(MaterialApp(home: ChapterPage(edit: edit)));
    await tester.pump(const Duration(milliseconds: 300));

    // 烈火第 0 章：静态只有琳 1 人（带编辑笔），事件增援 3 人里
    // 琳(14,9) 与静态重复被跳过 → 列表 3 行、2 个「事件」徽标、1 个可编辑。
    expect(find.byIcon(Icons.edit), findsOneWidget);
    expect(find.text('事件'), findsNWidgets(2));
    // 营地山贼的坐标来自事件脚本
    expect(find.textContaining('(3, 2)'), findsOneWidget);
    expect(find.textContaining('敌方'), findsWidgets);
    // 动态行不弹编辑页（无可点入口）：点它不应报错
    await tester.tap(find.text('事件').first);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('第 0 章'), findsOneWidget);
  });

  testWidgets('章节页 FE6：红/蓝列表也并入事件单位（静态 1 人 + 动态 7 人）',
      (tester) async {
    final data = File(fe6jp).readAsBytesSync();
    final edit = EditableRom.open(data, FeRom.detectTable(data)!);
    await tester.pumpWidget(MaterialApp(home: ChapterPage(edit: edit)));
    await tester.pump(const Duration(milliseconds: 300));

    // 蓝方：静态罗伊(0,0) + 事件加载的敌人与队友
    expect(find.byIcon(Icons.edit), findsOneWidget);
    expect(find.text('事件'), findsWidgets);
    expect(find.textContaining('敌方'), findsWidgets);

    // 红方：静态为空，全是事件加载的
    await tester.tap(find.text('红方（敌军）'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.edit), findsNothing);
    expect(find.text('事件'), findsWidgets);
  });

  testWidgets('章节页 FE8：遭遇战槽不混入事件单位', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = File(fe8jp).readAsBytesSync();
    final edit = EditableRom.open(data, FeRom.detectTable(data)!);
    await tester.pumpWidget(MaterialApp(home: ChapterPage(edit: edit)));
    await tester.pump(const Duration(milliseconds: 300));

    // 我方（普通）：静态 2 人 + 事件 3 人（全是敌方）
    expect(find.byIcon(Icons.edit), findsNWidgets(2));
    expect(find.text('事件'), findsNWidgets(3));

    // 遭遇战槽是「遭遇战配置」，不并事件单位
    await tester.tap(find.text('遭遇我方 1'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('事件'), findsNothing);
  });
}
