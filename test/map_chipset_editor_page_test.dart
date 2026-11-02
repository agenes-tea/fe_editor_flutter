import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/map_reader.dart';
import 'package:fe_editor/ui/map_chipset_editor_page.dart';
import 'package:fe_editor/ui/map_tile_editor_page.dart';

const dir = '/root/workspace/game-rom';
const fe8jp =
    '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

EditableRom _open() {
  final d = File(fe8jp).readAsBytesSync();
  return EditableRom.open(d, FeRom.detectTable(d)!);
}

/// chipset 画布的手势层：全页只有一个 GestureDetector 同时带
/// onTapDown 与 onPanUpdate（InkWell 的内部手势识别器只有 tap）。
GestureDetector _canvasDetector(WidgetTester tester) {
  final canvas = find.byWidgetPredicate(
      (w) => w is GestureDetector && w.onTapDown != null && w.onPanUpdate != null);
  expect(canvas, findsOneWidget);
  return tester.widget(canvas);
}

/// 测试视口拉宽，避免工具/色板行被挤出可见区。
void _wideView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 按 label 文本点一个 ChoiceChip（工具行/色板行）。
Future<void> _tapChip(WidgetTester tester, String label) async {
  final chip = find.byWidgetPredicate(
      (w) => w is ChoiceChip && w.label is Text && (w.label as Text).data == label);
  expect(chip, findsOneWidget, reason: '找不到名为「$label」的 chip');
  await tester.tap(chip);
  await tester.pump();
}

void main() {
  testWidgets('chipset 编辑页：打开显示工具与画布', (tester) async {
    final edit = _open();
    await tester.pumpWidget(MaterialApp(
      home: MapChipsetEditorPage(edit: edit, chapter: 0),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('第 0 章 · 砖块图形'), findsOneWidget);
    for (final tool in ['画', '填格', '取色', '复制格', '左右镜像', '上下镜像']) {
      expect(find.text(tool), findsOneWidget, reason: '工具「$tool」应存在');
    }
    // 未改内容时保存禁用
    final save = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.save),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('填格写回：画过的像素落进 ROM，可整体撤销', (tester) async {
    final edit = _open();
    _wideView(tester);
    await tester.pumpWidget(MaterialApp(
      home: MapChipsetEditorPage(edit: edit, chapter: 0),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    // 选颜色 13 → 选「填格」工具 → 点画布左上角（tile (0,0)）
    await _tapChip(tester, '13');
    await _tapChip(tester, '填格');
    _canvasDetector(tester).onTapDown!(TapDownDetails(
      localPosition: const Offset(4, 4),
      globalPosition: Offset.zero,
    ));
    await tester.pump();

    expect(edit.hasChanges, isFalse, reason: '未点保存前不写 ROM');
    final save = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.save),
    );
    expect(save.onPressed, isNotNull, reason: '填过一格后应出现保存按钮');

    await tester.tap(find.widgetWithIcon(IconButton, Icons.save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(edit.hasChanges, isTrue);
    final back = MapReader(edit.liveRom).chipIndices(0)!;
    expect(back[0], 13, reason: 'tile (0,0) 的 (0,0) 像素应变为索引 13');
    expect(find.textContaining('已写回'), findsOneWidget);

    edit.revertAll();
    expect(MapReader(edit.rom).chipIndices(0)![0], isNot(13));
  });

  testWidgets('未改内容点保存 = 无写入', (tester) async {
    final edit = _open();
    _wideView(tester);
    await tester.pumpWidget(MaterialApp(
      home: MapChipsetEditorPage(edit: edit, chapter: 0),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    // 取色不改内容：点一下画布
    await _tapChip(tester, '取色');
    _canvasDetector(tester).onTapDown!(TapDownDetails(
      localPosition: const Offset(4, 4),
      globalPosition: Offset.zero,
    ));
    await tester.pump();
    final save = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.save),
    );
    expect(save.onPressed, isNull, reason: '取色不算内容改动');
  });

  testWidgets('改尺寸对话框：同尺寸确认 = 不写入', (tester) async {
    final edit = _open();
    await tester.pumpWidget(MaterialApp(
      home: MapTileEditorPage(edit: edit, chapter: 0),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('改尺寸'));
    await tester.pump();
    expect(find.textContaining('新宽（格）'), findsOneWidget);
    expect(find.textContaining('行主序'), findsOneWidget);

    // 不动输入框直接确认 = 同尺寸同内容
    await tester.tap(find.text('确认改尺寸'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(edit.hasChanges, isFalse, reason: '同尺寸同内容不应写任何字节');
    expect(find.textContaining('尺寸未变'), findsOneWidget);
  });
}
