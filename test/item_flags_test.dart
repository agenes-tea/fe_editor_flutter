import 'dart:io';
import 'dart:typed_data';

import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/item_catalog.dart';
import 'package:fe_editor/core/item_flags.dart';
import 'package:fe_editor/core/rom_info.dart';
import 'package:fe_editor/ui/item_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Directory get _romDir => Directory('${Platform.environment['HOME']}/workspace/game-rom');

File _romByKeyword(String keyword) {
  for (final f in _romDir.listSync()) {
    if (f is File && f.path.contains(keyword)) return f;
  }
  throw StateError('找不到文件名包含 $keyword 的 ROM');
}

EditableRom _open(String keyword) {
  final data = Uint8List.fromList(_romByKeyword(keyword).readAsBytesSync());
  return EditableRom.open(data, FeRom.detectTable(data)!);
}

int _attrs(EditableRom edit, int itemIndex) =>
    edit.buffer.u32(edit.itemAddress(itemIndex) + ItemOffsets.attributes);

Set<int> get _toggledBits => {for (final (b, _, _) in ItemFlagToggles.toggles) b};

void main() {
  group('IA_* 特性位定义', () {
    test('开放的是战斗相关位，无限耐久排第一', () {
      final bits = _toggledBits;
      expect(bits, containsAll([3, 4, 5, 6, 7, 8, 14, 15, 17]));
      expect(ItemFlagToggles.toggles.first.$1, 3, reason: '无限耐久最常用，放最前');
      expect(ItemFlagToggles.toggles.length, 9);
    });

    test('不开放类型位（bit0/1/2）与不能使用（bit16）', () {
      // bit0/1/2 是武器/魔法/杖类型位，改它们等于把剑变成杖；bit16 会让道具不能用。
      for (final b in [0, 1, 2, 16]) {
        expect(_toggledBits, isNot(contains(b)), reason: 'bit$b 不应开放');
      }
    });
  });

  group('ItemFlagToggles.current / bit', () {
    test('真实 ROM：勇者剑已有连击（bit5），铁剑没有', () {
      final edit = _open('0979');
      expect(ItemFlagToggles.bit(edit, edit.itemAddress(11), 5), isTrue,
          reason: 'FE7J 勇者剑 bit5 IA_BRAVE');
      expect(ItemFlagToggles.bit(edit, edit.itemAddress(1), 5), isFalse,
          reason: '铁剑不是勇者系');
      // current() 与 toggles 一一对应，bit5 那一项为 true
      final state = ItemFlagToggles.current(edit, edit.itemAddress(11));
      final idx = ItemFlagToggles.toggles.indexWhere((t) => t.$1 == 5);
      expect(state[idx], isTrue);
    });
  });

  group('单道具改无限耐久（bit3）', () {
    test('writeFlagBit 只置 bit3，其余位与耐久不变', () {
      final edit = _open('0979');
      final addr = edit.itemAddress(1) + ItemOffsets.attributes;
      final beforeAttrs = _attrs(edit, 1);
      final beforeDur = edit.buffer.u8(edit.itemAddress(1) + ItemOffsets.durability);
      expect(ItemFlagToggles.bit(edit, edit.itemAddress(1), 3), isFalse,
          reason: '铁剑原版不是无限的');

      expect(edit.writeFlagBit(addr, 3, true), isTrue);
      expect(ItemFlagToggles.bit(edit, edit.itemAddress(1), 3), isTrue);
      expect(_attrs(edit, 1), beforeAttrs | 0x08);
      // 其余位一个不动：bit0 武器位仍在
      expect(_attrs(edit, 1) & beforeAttrs, beforeAttrs);
      // 耐久字段（+20）不受影响——无限耐久靠的是 attributes，不是把耐久写 0
      expect(edit.buffer.u8(edit.itemAddress(1) + ItemOffsets.durability), beforeDur);
    });

    test('逐件改：只动本道具，别的道具不受影响', () {
      final edit = _open('0979');
      final otherBefore = _attrs(edit, 2); // 钢剑
      expect(edit.writeFlagBit(edit.itemAddress(1) + ItemOffsets.attributes, 3, true),
          isTrue);
      expect(_attrs(edit, 2), otherBefore, reason: '钢剑不应被连带改');
      expect(ItemFlagToggles.bit(edit, edit.itemAddress(2), 3), isFalse);
    });

    test('可撤销，回到原始 attributes', () {
      final edit = _open('0979');
      final before = _attrs(edit, 1);
      edit.writeFlagBit(edit.itemAddress(1) + ItemOffsets.attributes, 3, true);
      edit.revertAll();
      expect(_attrs(edit, 1), before);
      expect(edit.hasChanges, isFalse);
    });

    test('关闭已置位的无限耐久（位清除）', () {
      // 原版某些道具本身就无限（火龙石等）；找一个已置 bit3 的来验证能取消
      final edit = _open('0979');
      final rom = edit.rom;
      int? target;
      for (var i = 1; i < rom.itemCount; i++) {
        if (ItemFlagToggles.bit(edit, edit.itemAddress(i), 3)) {
          target = i;
          break;
        }
      }
      expect(target, isNotNull, reason: 'FE7J 应有原版无限耐久道具');
      final addr = edit.itemAddress(target!) + ItemOffsets.attributes;
      expect(edit.writeFlagBit(addr, 3, false), isTrue);
      expect(ItemFlagToggles.bit(edit, edit.itemAddress(target), 3), isFalse);
    });
  });

  group('从别的武器复制特性', () {
    test('把勇者剑的 bit5 连击复制给铁剑', () {
      final edit = _open('0979');
      final braveBefore = _attrs(edit, 11);
      expect(ItemFlagToggles.bit(edit, edit.itemAddress(11), 5), isTrue);
      expect(ItemFlagToggles.bit(edit, edit.itemAddress(1), 5), isFalse);

      // 勾选铁剑的「连击两次」
      expect(
          edit.writeFlagBit(edit.itemAddress(1) + ItemOffsets.attributes, 5, true),
          isTrue);
      expect(ItemFlagToggles.bit(edit, edit.itemAddress(1), 5), isTrue);
      // 勇者剑原值不变
      expect(_attrs(edit, 11), braveBefore);
    });
  });

  group('道具详情页特性区（UI）', () {
    // 详情页很长，默认 800×600 视口下特地区在屏幕外、ListView 懒加载不会构建。
    // 把视口拉高到整页可见，让特性区进入控件树。
    Future<void> pumpDetail(WidgetTester tester, EditableRom edit) async {
      tester.view.physicalSize = const Size(1000, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final catalog = ItemCatalog(edit.rom);
      await tester.pumpWidget(MaterialApp(
        home: ItemDetailPage(
          catalog: catalog,
          entry: catalog.entryAt(1)!,
          edit: edit,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('渲染「特性（IA_* 标志位）」区并列出 9 个勾选项', (tester) async {
      final edit = _open('0979');
      await pumpDetail(tester, edit);

      expect(find.text('特性（IA_* 标志位）'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNWidgets(9));
      expect(find.text('无限耐久  (IA_UNBREAKABLE)'), findsOneWidget);
    });

    testWidgets('点「无限耐久」勾选后写回 bit3', (tester) async {
      final edit = _open('0979');
      await pumpDetail(tester, edit);

      final label = find.text('无限耐久  (IA_UNBREAKABLE)');
      await tester.tap(label);
      await tester.pumpAndSettle();

      expect(ItemFlagToggles.bit(edit, edit.itemAddress(1), 3), isTrue);
    });
  });
}
