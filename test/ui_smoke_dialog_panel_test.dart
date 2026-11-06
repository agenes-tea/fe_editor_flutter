import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/ui/chapter_page.dart';

import 'rom_paths.dart';

const dir = romDir;
const fe7jp =
    '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';

/// 章节页「本章对话」面板：入口条 + 列出本章引用的对话条目。
///
/// 从 ui_smoke_test 拆出（大文件 import 多页面易触发常驻编译器 OOM）。
///
/// 只断言到「面板列出条目 + 行是带 #ID Chip 的可点 ListTile」为止：
/// 再往下「点行打开编辑框」在测试环境里不可靠——面板是 DraggableScrollableSheet
/// （0.6 高贴底，前几行在视口外要靠拖拽/滚动定位），且编辑框 autofocus
/// 的光标闪烁是周期定时器（AGENTS 坑②），交互步一多就挂测试。
/// 编辑框本身的读写通道有 text_edit_dialog 的测试覆盖，这里不重复。
void main() {
  testWidgets('章节页：本章对话面板（列条目）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = File(fe7jp).readAsBytesSync();
    final edit = EditableRom.open(data, FeRom.detectTable(data)!);
    await tester.pumpWidget(MaterialApp(home: ChapterPage(edit: edit)));
    await tester.pump(const Duration(milliseconds: 300));

    // 入口条：对话数 > 0（烈火第 0 章有琳的开场白）
    expect(find.textContaining('本章对话'), findsOneWidget);
    await tester.tap(find.textContaining('本章对话'));
    // 固定时长 pump：面板动画给足即可（不用 pumpAndSettle，
    // 下面任何 autofocus 输入框的周期定时器会让 settle 永不收敛）
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('#2101'), findsOneWidget, reason: '琳的开场白应在列表里');

    // 行结构：对话条目是带 #文本ID Chip 头的 ListTile（点它开编辑框）
    final row =
        find.byWidgetPredicate((w) => w is ListTile && w.leading is Chip);
    expect(row, findsWidgets, reason: '对话条目应是可点的 ListTile');
  });
}
