import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/chapter_events.dart';
import 'package:fe_editor/core/chest_shop.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/core/unit_placement.dart';

import 'rom_paths.dart';

/// 宝箱奖励 / 商店列表（chest_shop）在真实 ROM 上的读写测试。
///
/// 锚点来自探针 `_probe_shop_test.dart` 的实测输出：
/// - FE8J 第 3 章 (6,3) 宝箱 w2=0x14；第 2 章 (5,7) 商店列表 [1,2,20,21,31]
/// - FE7J 第 6 章 (12,6) 宝箱 w2=0x5A；第 3 章 (13,7) 商店列表 [1,20]
/// - FE6  第 3 章 (22,12) 宝箱 w2=0xBB8006F（**高 16 位非 0**，写时必须保留）
const dir = romDir;
const fe7jp =
    '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe8jp =
    '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';
const fe6jp =
    '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';

({int group, ChapterEvent e}) _findEntry(RomSession s, int chapter, int cmd,
    int x, int y) {
  final up = UnitPlacement(s.rom);
  final ev = up.eventGroupOffset(chapter);
  final ce = ChapterEvents(s.liveRom);
  for (final e in ce.all(ev)) {
    if ((e.check & 0xFFFF) == cmd &&
        (e.value & 0xFF) == x &&
        ((e.value >> 8) & 0xFF) == y) {
      return (group: ev, e: e);
    }
  }
  throw StateError('ch$chapter ($x,$y) 类型 $cmd 条目找不到');
}

void main() {
  test('FE8J：宝箱奖励读出与写回（第 2 字低 16 位）', () {
    final s = RomSession.open(File(fe8jp).readAsBytesSync(), 'fe8.gba')!;
    final cs = ChestShop(s.rom);
    final found = _findEntry(s, 3, 7, 6, 3);
    final e = found.e;
    expect(cs.chestItemOf(e), 0x14, reason: '探针锚点：w2=0x14');
    expect(cs.chestExtraOf(e), 0, reason: 'FE8 原版高 16 位为 0');

    expect(cs.setChestItem(e, 0x4B), 2);
    expect(cs.chestItemNow(e), 0x4B);
    expect(s.rom.changedByteCount, greaterThan(0));

    s.rom.revertAll();
    expect(cs.chestItemNow(e), 0x14);
    expect(s.rom.hasChanges, isFalse);
  });

  test('FE6：高 16 位附加字段原样保留（0xBB8 不能被抹掉）', () {
    final s = RomSession.open(File(fe6jp).readAsBytesSync(), 'fe6.gba')!;
    final cs = ChestShop(s.rom);
    final e = _findEntry(s, 3, 7, 22, 12).e;
    expect(e.script, 0xBB8006F, reason: '探针锚点：低 16=0x6F 高 16=0xBB8');

    expect(cs.setChestItem(e, 0x21), 2);
    expect(cs.chestItemNow(e), 0x21);
    // 直接读 buffer：高 16 位必须保留 0xBB8（整字覆盖会把它抹成 0）
    final word = s.rom.buffer.u32(e.addr + 4);
    expect((word >> 16) & 0xFFFF, 0xBB8);
    expect(word & 0xFFFF, 0x21);
  });

  test('FE7J：商店列表读出（u16 数组，0 结尾）与原地替换', () {
    final s = RomSession.open(File(fe7jp).readAsBytesSync(), 'fe7.gba')!;
    final cs = ChestShop(s.rom);
    final e = _findEntry(s, 3, 10, 13, 7).e;
    final items = cs.shopItemsOf(e);
    expect(items, [1, 20], reason: '探针锚点');

    expect(cs.setShopItem(e, 0, 45), 2);
    expect(cs.shopItemsOf(e), [45, 20]);
    expect(cs.setShopItem(e, items.length, 1), -1,
        reason: '超出 0 结尾的范围必须拒绝（不能扩容）');
    s.rom.revertAll();
    expect(cs.shopItemsOf(e), [1, 20]);
  });

  test('FE8J：商店原地替换', () {
    final s = RomSession.open(File(fe8jp).readAsBytesSync(), 'fe8.gba')!;
    final cs = ChestShop(s.rom);
    final e = _findEntry(s, 2, 10, 5, 7).e;
    expect(cs.shopItemsOf(e), [1, 2, 20, 21, 31], reason: '探针锚点');

    expect(cs.setShopItem(e, 3, 45), 2);
    expect(cs.shopItemsOf(e)[3], 45);
    s.rom.revertAll();
    expect(cs.shopItemsOf(e), [1, 2, 20, 21, 31]);
  });

  test('同值写入返回 0（不记编辑）', () {
    final s = RomSession.open(File(fe8jp).readAsBytesSync(), 'fe8.gba')!;
    final cs = ChestShop(s.rom);
    final e = _findEntry(s, 3, 7, 6, 3).e;
    expect(cs.setChestItem(e, cs.chestItemOf(e)), 0);
    expect(s.rom.changedByteCount, 0);
  });
}
