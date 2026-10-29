import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/item_catalog.dart';
import 'package:fe_editor/core/support.dart';
import 'package:fe_editor/core/text_codec.dart';

/// 狼组 & 火花天龙剑 以 FE8 为蓝本做的改版（约 2004 年）。
///
/// 实测：BE8J、所有 FE8J 指针槽有效，unit/class/item 表与 FE8J 逐字节同址同值，
/// 支援数据同样 33/255 条。**但文本引擎被改写**（Huffman 树重建、字符码重编号），
/// 因此 `textEncoding` 为 unknown，中文名解不出来——与 FE8 汉化版同一类问题。
const hack = '/root/workspace/game-rom/1692X 火焰之纹章-圣邪的意志.gba';
const fe8jp =
    '/root/workspace/game-rom/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

void main() {
  group('圣邪的意志（FE8 改版）', () {
    test('识别为 FE8J 且三个表基址与日版相同', () {
      final data = File(hack).readAsBytesSync();
      final table = FeRom.detectTable(data)!;
      expect(table.id, 'FE8J');
      final rom = FeRom(data, table);
      final jp = FeRom(File(fe8jp).readAsBytesSync(),
          FeRom.detectTable(File(fe8jp).readAsBytesSync())!);
      expect(rom.unitBase, jp.unitBase);
      expect(rom.classBase, jp.classBase);
      expect(rom.itemBase, jp.itemBase);
      expect(rom.unitCount, jp.unitCount);
      expect(rom.classCount, jp.classCount);
      expect(rom.itemCount, jp.itemCount);
    });

    test('文本引擎被改写，不能按 SJIS 解', () {
      // 与 FE8 汉化版同因：Huffman 树重建 + 字符码重编号。
      // 这里只锁定「识别不出」这个事实，防止以后误判成 huffmanSjis 而显示乱码。
      final data = File(hack).readAsBytesSync();
      final rom = FeRom(data, FeRom.detectTable(data)!);
      expect(rom.textEncoding, isNot(FeTextEncoding.huffmanSjis));
    });

    test('单位表结构与 FE8J 一致（数值/职业可能被改版调过）', () {
      // 改版会调数值、甚至换默认职业（实测 unit1 职业从 7 变 40），
      // 所以只断言真正结构性的字段：unit ID(@4) 与支援指针(@0x2C)。
      // 前者决定「列表 ID 恒等于表内偏移」这个改版兼容基础，
      // 后者决定支援编辑能否工作。
      final h = File(hack).readAsBytesSync();
      final j = File(fe8jp).readAsBytesSync();
      final th = FeRom.detectTable(h)!;
      final rjp = FeRom(j, FeRom.detectTable(j)!);
      final base = rjp.unitBase;
      for (var i = 0; i < 12; i++) {
        final a = base + i * th.unitDataSize;
        expect(h[a + 4], j[a + 4], reason: 'unit$i 的 unit ID');
        expect(h[a + 0x2C], j[a + 0x2C], reason: 'unit$i 的支援指针');
      }
    });

    test('道具表数值与 FE8J 一致（铁剑 46/5/90/5、单价 u16 能读）', () {
      final data = File(hack).readAsBytesSync();
      final cat = ItemCatalog(FeRom(data, FeRom.detectTable(data)!));
      final e = cat.entryAt(1)!;
      expect(e.durability, 46);
      expect(e.might, 5);
      expect(e.hit, 90);
      expect(e.weight, 5);
      expect(e.unitPrice, greaterThan(0));
    });

    test('角色/职业/道具/支援字段都能编辑并撤销', () {
      final data = File(hack).readAsBytesSync();
      final edit = EditableRom.open(data, FeRom.detectTable(data)!);

      final lv = unitEditableFields.firstWhere((f) => f.label == '等级');
      final uAddr = edit.unitAddress(0);
      edit.writeField(uAddr, lv, 15);
      expect(edit.readField(uAddr, lv), 15);

      final price = itemEditableFields.firstWhere((f) => f.label == '单价');
      final iAddr = edit.itemAddress(1);
      edit.writeField(iAddr, price, 4242);
      expect(edit.readField(iAddr, price), 4242);

      final st = SupportTable(edit.rom);
      final withSup = List.generate(edit.rom.unitCount, (i) => i)
          .firstWhere((i) => st.addressOf(i) >= 0);
      final orig = edit.readSupport(withSup, 0, SupportPart.base);
      edit.writeSupport(withSup, 0, SupportPart.base, 200);
      expect(edit.readSupport(withSup, 0, SupportPart.base), 200);

      edit.revertAll();
      expect(edit.readField(uAddr, lv), isNot(15));
      expect(edit.readField(iAddr, price), isNot(4242));
      expect(edit.readSupport(withSup, 0, SupportPart.base), orig);
      expect(edit.hasChanges, isFalse);
    });

    test('支援数据与 FE8J 一致（33 条有支援）', () {
      final data = File(hack).readAsBytesSync();
      final st = SupportTable(FeRom(data, FeRom.detectTable(data)!));
      var n = 0;
      for (var i = 0; i < 255; i++) {
        if (st.addressOf(i) >= 0) n++;
      }
      expect(n, 33);
    });
  });
}
