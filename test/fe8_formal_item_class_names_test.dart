import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe8_formal_item_class_names.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/item_catalog.dart';
import 'package:fe_editor/core/zh_table.dart';
import 'package:fe_editor/core/zh_tables_data.dart';

/// 汉化版职业名 / 道具名的正式译名处理。
///
/// 与角色名同因：汉化组按读音抓同音字，「铁剑」显示成「条健」、
/// 「领主」显示成「凌诸」、「圣骑士」显示成「盛齐始」。
/// 这里验证 `classDisplayName` / `itemDisplayName` 只在挂了码表的
/// 汉化版上替换，且不影响日版与原始解码。
const fe8cn = '/root/workspace/game-rom/火炎之纹章-圣魔之光石汉化.gba';
const fe8jp =
    '/root/workspace/game-rom/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

FeRom _openCn() {
  final data = File(fe8cn).readAsBytesSync();
  final rom = FeRom(data, FeRom.detectTable(data)!);
  rom.zhTable = ZhTable(Map<int, String>.from(zhTblFE8));
  return rom;
}

FeRom _openJp() {
  final data = File(fe8jp).readAsBytesSync();
  return FeRom(data, FeRom.detectTable(data)!);
}

void main() {
  group('FE8 汉化版职业名/道具名正式译名', () {
    test('原始解码是同音字', () {
      final rom = _openCn();
      expect(rom.className(1).trim(), '凌诸', reason: 'ロード→凌诸');
      expect(rom.itemName(1).trim(), '条健', reason: 'てつの剣→条健');
      expect(rom.className(7).trim(), '盛齐始', reason: 'パラディン→盛齐始');
    });

    test('显示名是正式译名', () {
      final rom = _openCn();
      expect(rom.classDisplayName(1).trim(), '领主');
      expect(rom.itemDisplayName(1).trim(), '铁剑');
      expect(rom.classDisplayName(7).trim(), '圣骑士');
      expect(rom.itemDisplayName(4).trim(), '银剑');
      expect(rom.itemDisplayName(17).trim(), '符文剑');
      expect(rom.itemDisplayName(75).trim(), '治愈');
    });

    test('日版不受影响', () {
      final rom = _openJp();
      expect(rom.classDisplayName(1), 'ロード');
      expect(rom.itemDisplayName(1), 'てつの剣');
    });

    test('没挂码表时不替换', () {
      final data = File(fe8cn).readAsBytesSync();
      final rom = FeRom(data, FeRom.detectTable(data)!);
      expect(rom.classDisplayName(1), rom.className(1));
      expect(rom.itemDisplayName(1), rom.itemName(1));
    });

    test('译名表规模与覆盖', () {
      expect(fe8FormalClassNames.length, 63);
      expect(fe8FormalItemNames.length, 163);
      // 抽查
      expect(fe8FormalClassNameFor(582), '领主');
      expect(fe8FormalItemNameFor(731), '铁剑');
      expect(fe8FormalClassNameFor(99999), isNull);
      expect(fe8FormalItemNameFor(99999), isNull);
    });

    test('职业与道具的 nameTextId 不重叠', () {
      final overlap = fe8FormalClassNames.keys
          .toSet()
          .intersection(fe8FormalItemNames.keys.toSet());
      expect(overlap, isEmpty);
    });

    test('ItemCatalog.nameOf 走显示名', () {
      final rom = _openCn();
      final cat = ItemCatalog(rom);
      expect(cat.nameOf(1), '铁剑');
      expect(cat.nameOf(4), '银剑');
    });

    test('未登记的条目退回原文（ダミー 空槽、乱码占位符）', () {
      final rom = _openCn();
      // 道具 10 是 ダミー，没登记译名
      final tid = rom.itemNameTextId(10);
      expect(fe8FormalItemNames.containsKey(tid), isFalse);
      expect(rom.itemDisplayName(10), rom.itemName(10));
    });

    test('武器数值与日版一致（确认条目对应没错位）', () {
      final cn = ItemCatalog(_openCn());
      final jp = ItemCatalog(_openJp());
      for (final id in [1, 3, 4, 20, 31, 45, 56]) {
        final a = cn.entryAt(id)!;
        final b = jp.entryAt(id)!;
        expect(a.durability, b.durability, reason: 'item $id 耐久');
        expect(a.might, b.might, reason: 'item $id 威力');
        expect(a.hit, b.hit, reason: 'item $id 命中');
        expect(a.weight, b.weight, reason: 'item $id 重量');
      }
    });
  });
}
