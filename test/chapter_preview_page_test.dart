import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/ui/chapter_preview_page.dart';

import 'rom_paths.dart';

const _dir = romDir;
const _gbk = '火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba';

/// 同步打开 ROM 会话（widget 测试里不能 await 同步构造，见 AGENTS 的 FakeAsync 坑）。
RomSession _session(String name) =>
    RomSession.open(File('$_dir/$name').readAsBytesSync(), name)!;

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('预览页固定显示「不是游戏画面」的界线说明', (tester) async {
    final s = _session(_gbk);
    await tester.pumpWidget(_wrap(ChapterPreviewPage(
      edit: s.rom,
      chapter: 0,
      chapterTitle: '草原的少女',
    )));
    await tester.pump();

    // 这条不能折叠、不能藏起来：用户必须一眼看到
    final text = tester.widget<Text>(
      find.textContaining('不是游戏实际运行画面').first,
    );
    expect(text.data, contains('这是工具根据 ROM 数据渲染的预览'));
    expect(text.data, contains('不校验游戏行为'));
    expect(text.data, contains('模拟器'));

  });

  testWidgets('两个视图的 Tab 都在，且对话视图渲染出台词', (tester) async {
    final s = _session(_gbk);
    await tester.pumpWidget(_wrap(ChapterPreviewPage(
      edit: s.rom,
      chapter: 0,
      chapterTitle: '草原的少女',
    )));
    await tester.pump();

    expect(find.text('对话时间线'), findsOneWidget);
    expect(find.text('事件触发'), findsOneWidget);
    // 对话时间线默认视图应能读到原版台词
    expect(find.textContaining('我叫琳'), findsWidgets);

  });

  testWidgets('切到事件视图能看到自然语言句子', (tester) async {
    final s = _session(_gbk);
    await tester.pumpWidget(_wrap(ChapterPreviewPage(
      edit: s.rom,
      chapter: 0,
      chapterTitle: '草原的少女',
    )));
    await tester.pump();

    await tester.tap(find.text('事件触发'));
    await tester.pumpAndSettle();

    expect(find.textContaining('生成'), findsWidgets);
    expect(find.textContaining('回合'), findsWidgets);

  });
}
