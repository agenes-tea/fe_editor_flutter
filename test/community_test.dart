import 'dart:io';

import 'package:fe_editor/core/app_log.dart';
import 'package:fe_editor/core/cheat_presets.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/feature_flags.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/ui/cheat_page.dart';
import 'package:fe_editor/ui/log_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const dir = '/root/workspace/game-rom';
const fe8jp =
    '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

void main() {
  test('预设全部可见（功能已恢复）', () {
    expect(cheatPresets.every((p) => p.visible), isTrue);
    // 4 个角色数值类 + 2 个职业类（三倍经验、能力上限 50）
    // + 2 个道具类 + 2 个支援类 + 2 个规则类（支援距离）
    expect(cheatPresets.length, 12);
    expect(
        cheatPresets.where((p) => p.target == CheatTarget.classTable).length, 2);
    expect(
        cheatPresets.where((p) => p.target == CheatTarget.support).length, 2);
    expect(
        cheatPresets
            .where((p) => p.target == CheatTarget.battleRule)
            .length,
        2);
  });

  test('功能开关：章节入口开启、调试器关闭', () {
    expect(Features.chapter, isTrue);
    // 调试器补丁会覆盖原版函数入口，装了必然起不来（AGENTS 第 20c 节），
    // 修好前不对外暴露入口。
    expect(Features.gameDebugger, isFalse);
  });

  testWidgets('修改器显示全部预设与职业类分组', (tester) async {
    final d = File(fe8jp).readAsBytesSync();
    final edit = EditableRom.open(d, FeRom.detectTable(d)!);
    await tester.pumpWidget(MaterialApp(home: CheatListPage(edit: edit)));
    await tester.pump(const Duration(milliseconds: 300));

    // 角色类（滚到哪、断言哪，避免分组标题滚出可视区）
    await tester.scrollUntilVisible(find.text('我方角色成长率拉满'), 100);
    expect(find.text('角色类'), findsOneWidget);
    expect(find.text('我方角色成长率拉满'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('我方角色成长率 200%'), 100);
    expect(find.text('我方角色成长率 200%'), findsOneWidget);
    // 职业类分组恢复
    await tester.scrollUntilVisible(find.text('三倍经验（全职业）'), 100);
    expect(find.text('职业类'), findsOneWidget);
    expect(find.text('三倍经验（全职业）'), findsOneWidget);
    // 道具类
    await tester.scrollUntilVisible(find.text('仅武器装备无限耐久'), 100);
    expect(find.text('道具类'), findsOneWidget);
    expect(find.text('仅武器装备无限耐久'), findsOneWidget);
  });

  testWidgets('日志页：条目展示与复制全部', (tester) async {
    // widget 测试里没有真剪贴板：mock 掉平台通道的 Clipboard.setData
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') return null;
        throw MissingPluginException(call.method);
      },
    );
    AppLog.instance.log('info', '测试条目ABC');
    await tester.pumpWidget(MaterialApp(home: const LogViewerPage()));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('测试条目ABC'), findsWidgets);
    await tester.tap(find.byTooltip('复制全部'));
    await tester.pump();
    expect(find.textContaining('已复制全部日志'), findsOneWidget);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
}
