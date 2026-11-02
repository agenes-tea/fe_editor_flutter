import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/lz77_compress.dart';
import 'package:fe_editor/core/map_reader.dart';
import 'package:fe_editor/core/map_writer.dart';
import 'package:fe_editor/ui/map_tile_editor_page.dart';

const dir = '/root/workspace/game-rom';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

EditableRom _open() {
  final d = File(fe8jp).readAsBytesSync();
  return EditableRom.open(d, FeRom.detectTable(d)!);
}

/// 找一个「改一格后压缩仍放得下」的章节（原版多数地图已压到上限）。
int _writableChapter(EditableRom edit) {
  final reader = MapReader(edit.rom);
  for (var ch = 0; ch < 40; ch++) {
    final map = reader.chapterMap(ch);
    if (map == null) continue;
    final orig = MapWriter.compressedLengthOf(edit.buffer.data, map.dataOffset);
    final alts = map.tiles.toSet().toList();
    if (alts.length < 2) continue;
    final probe = List<int>.from(map.tiles);
    probe[0] = alts.first == probe[0] ? alts.last : alts.first;
    final raw = Uint8List(2 + probe.length * 2);
    raw[0] = map.width;
    raw[1] = map.height;
    for (var i = 0; i < probe.length; i++) {
      raw[2 + i * 2] = probe[i] & 0xFF;
      raw[2 + i * 2 + 1] = (probe[i] >> 8) & 0xFF;
    }
    if (Lz77Compressor.compress(raw).length <= orig) return ch;
  }
  return 0;
}

/// 点地图左上角第一格：点击落在「地图画布」的 GestureDetector 上，
/// 不是外层 InteractiveViewer 的手势层。
/// 在地图 [x,y] 格上涂抹。
///
/// 这里直接派发 `onTapDown` 而不是 `tester.tapAt`：外层 InteractiveViewer
/// 也带一个铺满全屏的手势识别器，会在竞技场里把点击抢走，
/// 模拟真实点击时打不到地图画布那一层。
Future<void> _paintAt(WidgetTester tester, int x, int y) async {
  final canvas = _canvasDetector(tester);
  canvas.onTapDown!(TapDownDetails(
    localPosition: Offset(x * 16.0 + 8, y * 16.0 + 8),
    globalPosition: Offset.zero,
  ));
  await tester.pump();
}

/// 地图画布那个 GestureDetector（InteractiveViewer 里面的一层）。
GestureDetector _canvasDetector(WidgetTester tester) {
  final viewer = tester.getRect(find.byType(InteractiveViewer));
  for (final e in find.byType(GestureDetector).evaluate()) {
    final r = tester.getRect(find.byWidget(e.widget));
    if (r.width < viewer.width - 1 && r.height > 100) {
      return e.widget as GestureDetector;
    }
  }
  fail('找不到地图画布');
}

/// 在地图上涂抹一格：找出「砖块值与当前笔刷不同」的格子，点它。
///
/// 直接点第一格不行——它的砖块往往就是初始笔刷（初始笔刷取首格的值），
/// 那样点下去等于没改。
Future<void> _paintSomething(WidgetTester tester, EditableRom edit, int ch) async {
  final map = MapReader(edit.rom).chapterMap(ch)!;
  final brush = _currentBrush(tester);
  final at = map.tiles.indexWhere((t) => t != brush);
  expect(at, isNot(-1), reason: '整张地图都是同一个砖块，无法测出差异');
  await _paintAt(tester, at % map.width, at ~/ map.width);
}

/// 从工具栏文本里读出当前笔刷值（`砖块 0xNN`）。
int _currentBrush(WidgetTester tester) {
  final text = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .firstWhere((t) => t.contains('砖块 0x'), orElse: () => '');
  final m = RegExp(r'砖块 0x([0-9A-Fa-f]+)').firstMatch(text);
  expect(m, isNotNull, reason: '工具栏应显示当前笔刷');
  return int.parse(m!.group(1)!, radix: 16);
}

void main() {
  testWidgets('地形编辑页：打开后显示地图与砖块候选', (tester) async {
    final edit = _open();
    await tester.pumpWidget(MaterialApp(
      home: MapTileEditorPage(edit: edit, chapter: 0),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('第 0 章'), findsOneWidget);
    expect(find.textContaining('格 · 砖块'), findsOneWidget);
    expect(find.textContaining('选择砖块'), findsOneWidget);
    // 初始没有改动，保存按钮禁用
    final save = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.save),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('点地图改一格后出现保存按钮', (tester) async {
    final edit = _open();
    final ch = _writableChapter(edit);
    await tester.pumpWidget(MaterialApp(
      home: MapTileEditorPage(edit: edit, chapter: ch),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    final swatches = find.textContaining('0x');
    expect(swatches, findsWidgets);
    await _paintSomething(tester, edit, ch);

    expect(find.textContaining('已改'), findsOneWidget);
    final save = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.save),
    );
    expect(save.onPressed, isNotNull);
    expect(edit.hasChanges, isFalse, reason: '未点保存前不写 ROM');
  });

  testWidgets('保存后写回 ROM 并清空未写入标记', (tester) async {
    final edit = _open();
    final ch = _writableChapter(edit);
    await tester.pumpWidget(MaterialApp(
      home: MapTileEditorPage(edit: edit, chapter: ch),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    final before = MapReader(edit.rom).chapterMap(ch)!;
    await _paintSomething(tester, edit, ch);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(edit.hasChanges, isTrue, reason: '保存后应产生编辑记录');
    expect(find.textContaining('已改'), findsNothing);
    final after = MapReader(edit.liveRom).chapterMap(ch)!;
    expect(after.tiles.length, before.tiles.length);

    edit.revertAll();
    expect(edit.hasChanges, isFalse);
  });

  testWidgets('撤销按钮把本页改动还原为 ROM 里的内容', (tester) async {
    final edit = _open();
    final ch = _writableChapter(edit);
    await tester.pumpWidget(MaterialApp(
      home: MapTileEditorPage(edit: edit, chapter: ch),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    await _paintSomething(tester, edit, ch);
    expect(find.textContaining('已改'), findsOneWidget);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.restart_alt));
    await tester.pump();
    expect(find.textContaining('已改'), findsNothing);
    expect(edit.hasChanges, isFalse);
  });
}
