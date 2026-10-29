import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/rom_info.dart';
import 'package:fe_editor/core/support.dart';

const dir = '/root/workspace/game-rom';
const fe6jp = '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe7us = '$dir/1235 - 火炎之纹章-烈火之剑 Fire Emblem(US)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

FeRom _open(String p) {
  final d = File(p).readAsBytesSync();
  return FeRom(d, FeRom.detectTable(d)!);
}

void main() {
  group('属性（Affinity）在 +9', () {
    test('+0x28 是 attributes 标志位，不是属性', () {
      expect(UnitOffsets.affinity, 0x09);
      // 4 字节 attributes 的起点；按单字节读永远是 0（FE7J 全 253 条实测）
      final rom = _open(fe7jp);
      for (var i = 0; i < rom.unitCount; i++) {
        final at = rom.unitBase + i * rom.table.unitDataSize + UnitOffsets.attributes;
        expect(rom.data[at], 0, reason: 'unit $i 的 +0x28 首字节');
      }
    });

    test('FE8J 艾瑞珂是光（0x06）、塞斯是理（0x07）', () {
      final t = SupportTable(_open(fe8jp));
      expect(t.affinityOf(0), Affinity.light);
      expect(t.affinityOf(1), Affinity.anima);
    });

    test('全部角色都能解析出合法属性（0..7）', () {
      for (final p in [fe6jp, fe7jp, fe7us, fe8jp]) {
        final rom = _open(p);
        final t = SupportTable(rom);
        for (var i = 0; i < rom.unitCount; i++) {
          final a = t.affinityOf(i);
          expect(a.raw, inInclusiveRange(0, 7), reason: '$p unit $i');
        }
      }
    });
  });

  group('支援数据（角色表 +0x2C）', () {
    test('结构是 7+7+7+1 字节，与 SupportData 定义一致', () {
      expect(SupportTable.entrySize, 0x16);
      expect(SupportTable.maxPartners, 7);
    });

    test('FE8J 艾瑞珂的 7 个支援对象', () {
      // fireemblem8u src/data_supports.c：SupportData_Eirika
      //   characters = EPHRAIM(0x0F), SETH(0x02), SALEH(0x17), LARACHEL(0x19),
      //                TANA(0x22), INNES(0x0B), FORDE(0x10)
      //   supportExpBase = 30, 25, 5, 10, 20, 10, 20
      //   supportExpGrowth = 4, 3, 2, 2, 2, 2, 2
      final t = SupportTable(_open(fe8jp));
      final r = t.relationsOf(0);
      expect(r.length, 7);
      expect(r.map((e) => e.charId).toList(), [0x0F, 0x02, 0x17, 0x19, 0x22, 0x0B, 0x10]);
      expect(r.map((e) => e.baseExp).toList(), [30, 25, 5, 10, 20, 10, 20]);
      expect(r.map((e) => e.growth).toList(), [4, 3, 2, 2, 2, 2, 2]);
    });

    test('支援对象 ID 都能反查回角色', () {
      final rom = _open(fe8jp);
      final t = SupportTable(rom);
      for (final id in t.relationsOf(0).map((e) => e.charId)) {
        expect(t.nameOf(id), isNot(startsWith('角色 $id')));
      }
    });

    test('没有支援数据的条目返回空表而不抛异常', () {
      final rom = _open(fe7jp);
      final t = SupportTable(rom);
      var empty = 0;
      for (var i = 0; i < rom.unitCount; i++) {
        final r = t.relationsOf(i);
        if (r.isEmpty) empty++;
        for (final e in r) {
          expect(e.charId, inInclusiveRange(1, rom.unitCount));
        }
      }
      expect(empty, greaterThan(0));
    });
  });
}
