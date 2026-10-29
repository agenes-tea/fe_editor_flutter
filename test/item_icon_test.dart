import 'dart:io';

import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/item_catalog.dart';
import 'package:fe_editor/core/item_icon.dart';
import 'package:fe_editor/core/tile_image.dart';
import 'package:fe_editor/ui/item_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _dir = '/root/workspace/game-rom';

FeRom _open(String keyword) {
  final f = Directory(_dir)
      .listSync()
      .whereType<File>()
      .firstWhere((e) => e.path.contains(keyword));
  final data = f.readAsBytesSync();
  return FeRom(data, FeRom.detectTable(data)!);
}

int _opaque(TileImage img) {
  var n = 0;
  for (var i = 3; i < img.pixels.length; i += 4) {
    if (img.pixels[i] != 0) n++;
  }
  return n;
}

void main() {
  group('道具图标：表定位', () {
    test('五个版本都能定位到图标图集与调色板', () {
      for (final kw in ['0378', '0979', '1235', '1692 -', '自调试']) {
        final rom = _open(kw);
        final icons = ItemIcons(rom);
        expect(icons.available, isTrue, reason: '${rom.table.id} 应有图标槽');
        expect(icons.iconBase, greaterThan(0));
        expect(icons.paletteOffset, greaterThan(0));
        // 原版图标数至少 100（FE6 159 / FE7 172 / FE8 223）
        expect(icons.iconCount, greaterThan(100), reason: rom.table.id);
      }
    });

    test('各版本图标基址与调色板地址符合 FEBuilderGBA 的常量', () {
      expect(ItemIcons(_open('0378')).iconBase, 0xF9D80);
      expect(ItemIcons(_open('0979')).iconBase, 0xC12F4);
      expect(ItemIcons(_open('1235')).iconBase, 0xC5EA4);
      expect(ItemIcons(_open('1692 -')).iconBase, 0x5BA470);
      expect(ItemIcons(_open('自调试')).iconBase, 0x5926F4);
    });
  });

  group('道具图标：解码', () {
    test('铁剑/钢剑/铁枪/钢枪 都能解出非空 16×16 图标', () {
      final rom = _open('1235');
      final icons = ItemIcons(rom);
      for (var id = 0; id < 4; id++) {
        final img = icons.decode(id);
        expect(img, isNotNull, reason: 'icon $id');
        expect(img!.width, 16);
        expect(img.height, 16);
        final opaque = _opaque(img);
        // 稀疏线状图形：5%~45% 不透明
        expect(opaque, greaterThan(10), reason: 'icon $id 应有内容');
        expect(opaque, lessThan(200), reason: 'icon $id 不应是实心块');
      }
    });

    test('相邻图标不是同一张图（间距是 128 而非 64）', () {
      final rom = _open('1235');
      final icons = ItemIcons(rom);
      final a = icons.decode(0)!;
      final b = icons.decode(1)!;
      expect(a.pixels, isNot(equals(b.pixels)),
          reason: '按 64 字节紧排会读到错位的残图，两张会长得像');
    });

    test('越界的 iconId 返回 null 而不是崩', () {
      final rom = _open('1235');
      final icons = ItemIcons(rom);
      expect(icons.decode(-1), isNull);
      expect(icons.decode(999999), isNull);
    });

    test('按道具条目取图标：铁剑(1 号) 与钢剑(2 号) 图标不同', () {
      final rom = _open('1235');
      final catalog = ItemCatalog(rom);
      final icons = ItemIcons(rom);
      final iron = catalog.entryAt(1)!;
      final steel = catalog.entryAt(2)!;
      expect(iron.iconId, 0);
      expect(steel.iconId, 1);
      final a = icons.forItem(iron.id)!;
      final b = icons.forItem(steel.id)!;
      expect(a.pixels, isNot(equals(b.pixels)));
    });

    test('改版 ROM 也能取到图标', () {
      for (final kw in ['1692X', 'The Last Promise']) {
        final rom = _open(kw);
        final icons = ItemIcons(rom);
        final img = icons.decode(0);
        expect(img, isNotNull, reason: kw);
        expect(_opaque(img!), greaterThan(5), reason: kw);
      }
    });
  });

  group('道具页显示图标', () {
    testWidgets('列表每一项都有图标（Image），不再只有 ID 数字', (tester) async {
      final f = Directory(_dir)
          .listSync()
          .whereType<File>()
          .firstWhere((e) => e.path.contains('1235'));
      final data = f.readAsBytesSync();
      final edit = EditableRom.open(data, FeRom.detectTable(data)!);
      await tester.pumpWidget(MaterialApp(home: ItemListPage(edit: edit)));
      await tester.pump(const Duration(milliseconds: 300));
      final tiles = find.byType(ListTile).evaluate().length;
      final images = find.byType(Image).evaluate().length;
      expect(tiles, greaterThan(50));
      expect(images, tiles, reason: '每个列表项都应渲染出图标');
    });

    testWidgets('详情页顶部显示放大图标', (tester) async {
      final f = Directory(_dir)
          .listSync()
          .whereType<File>()
          .firstWhere((e) => e.path.contains('1235'));
      final data = f.readAsBytesSync();
      final edit = EditableRom.open(data, FeRom.detectTable(data)!);
      final catalog = ItemCatalog(edit.rom);
      await tester.pumpWidget(MaterialApp(
        home: ItemDetailPage(
          catalog: catalog,
          entry: catalog.entryAt(1)!,
          edit: edit,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(Image), findsWidgets);
    });
  });
}
