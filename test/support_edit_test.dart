import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/support.dart';
import 'package:fe_editor/core/patch_format.dart';

const dir = '/root/workspace/game-rom';
const fe6cn = '$dir/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe7us = '$dir/1235 - 火炎之纹章-烈火之剑 Fire Emblem(US)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

EditableRom _open(String path) {
  final data = File(path).readAsBytesSync();
  return EditableRom.open(data, FeRom.detectTable(data)!);
}

void main() {
  group('支援数据读取', () {
    test('SupportPart 的偏移与 SupportData 布局对应', () {
      expect(SupportTable.partnerOffset(0), 0x00);
      expect(SupportTable.partnerOffset(6), 0x06);
      expect(SupportTable.baseOffset(0), 0x07);
      expect(SupportTable.baseOffset(6), 0x0D);
      expect(SupportTable.growthOffset(0), 0x0E);
      expect(SupportTable.growthOffset(6), 0x14);
      // 三组互不重叠，且都落在 0x16 字节内
      expect(SupportTable.entrySize, 0x16);
    });

    test('艾瑞珂的 7 个支援对象可读出', () {
      final edit = _open(fe8jp);
      final base = edit.supportAddress(0);
      expect(base, greaterThan(0));
      expect(edit.readSupport(0, 0, SupportPart.partner), 0x0F);
      expect(edit.readSupport(0, 0, SupportPart.base), 30);
      expect(edit.readSupport(0, 0, SupportPart.growth), 4);
    });

    test('槽位越界返回 -1', () {
      final edit = _open(fe8jp);
      expect(edit.readSupport(0, 7, SupportPart.partner), -1);
      expect(edit.readSupport(0, -1, SupportPart.partner), -1);
    });

    test('没有支援数据的角色返回 -1 且不可写', () {
      final edit = _open(fe7jp);
      // FE7J 的 u2（索引 2）没有支援数据
      expect(edit.supportAddress(2), -1);
      expect(edit.readSupport(2, 0, SupportPart.base), -1);
      expect(edit.writeSupport(2, 0, SupportPart.base, 99), isFalse);
    });
  });

  group('支援数据写入', () {
    test('改初始值/每回合增长可读回', () {
      final edit = _open(fe8jp);
      final origBase = edit.readSupport(0, 0, SupportPart.base);
      final origGrowth = edit.readSupport(0, 0, SupportPart.growth);

      expect(edit.writeSupport(0, 0, SupportPart.base, 200), isTrue);
      expect(edit.readSupport(0, 0, SupportPart.base), 200);
      expect(edit.writeSupport(0, 0, SupportPart.growth, 5), isTrue);
      expect(edit.readSupport(0, 0, SupportPart.growth), 5);

      edit.writeSupport(0, 0, SupportPart.base, origBase);
      edit.writeSupport(0, 0, SupportPart.growth, origGrowth);
      expect(edit.readSupport(0, 0, SupportPart.base), origBase);
      expect(edit.readSupport(0, 0, SupportPart.growth), origGrowth);
    });

    test('只改指定槽位，不影响相邻槽位', () {
      final edit = _open(fe8jp);
      final s1Before = [
        edit.readSupport(0, 1, SupportPart.partner),
        edit.readSupport(0, 1, SupportPart.base),
        edit.readSupport(0, 1, SupportPart.growth),
      ];
      edit.writeSupport(0, 0, SupportPart.base, 111);
      expect(edit.readSupport(0, 1, SupportPart.base), s1Before[1]);
      expect(edit.readSupport(0, 1, SupportPart.growth), s1Before[2]);
    });

    test('改一个角色的支援不影响其它角色', () {
      final edit = _open(fe8jp);
      // u1 与 u0 的支援指针不同（实测无共享）
      final u1Before = edit.readSupport(1, 0, SupportPart.base);
      edit.writeSupport(0, 0, SupportPart.base, 123);
      expect(edit.readSupport(1, 0, SupportPart.base), u1Before);
    });

    test('角色 ID 夹紧到合法范围', () {
      final edit = _open(fe8jp);
      final max = edit.rom.unitCount;
      expect(max, greaterThan(0));
      edit.writeSupport(0, 0, SupportPart.partner, 9999);
      expect(edit.readSupport(0, 0, SupportPart.partner), max);
      // 0 不是合法角色 ID（FE 从 1 起），夹紧到 1
      edit.writeSupport(0, 0, SupportPart.partner, 0);
      expect(edit.readSupport(0, 0, SupportPart.partner), 1);
    });

    test('数值夹紧到 0~255', () {
      final edit = _open(fe8jp);
      edit.writeSupport(0, 0, SupportPart.base, 999);
      expect(edit.readSupport(0, 0, SupportPart.base), 255);
      edit.writeSupport(0, 0, SupportPart.base, -5);
      expect(edit.readSupport(0, 0, SupportPart.base), 0);
    });

    test('支援改动可撤销', () {
      final edit = _open(fe8jp);
      final orig = edit.readSupport(0, 0, SupportPart.base);
      edit.writeSupport(0, 0, SupportPart.base, 77);
      expect(edit.hasChanges, isTrue);
      edit.revertAll();
      expect(edit.hasChanges, isFalse);
      expect(edit.readSupport(0, 0, SupportPart.base), orig);
    });

    test('同值不写', () {
      final edit = _open(fe8jp);
      final orig = edit.readSupport(0, 0, SupportPart.base);
      expect(edit.writeSupport(0, 0, SupportPart.base, orig), isFalse);
      expect(edit.changedByteCount, 0);
    });

    test('支援改动可生成 UPS 并还原', () {
      final edit = _open(fe8jp);
      edit.writeSupport(0, 0, SupportPart.base, 200);
      edit.writeSupport(0, 3, SupportPart.growth, 9);
      final out = edit.buildOutput();
      final patch = UpsPatch.create(edit.original, out);
      final back = UpsPatch.apply(patch, edit.original);
      expect(back, isNotNull);
      expect(back, out);
    });
  });

  group('跨版本', () {
    test('四个版本的支援都能写能读回', () {
      for (final p in [fe6cn, fe7jp, fe7us, fe8jp]) {
        final edit = _open(p);
        // 找到第一个有支援数据的角色
        final idx = List.generate(edit.rom.unitCount, (i) => i)
            .firstWhere((i) => edit.supportAddress(i) >= 0);
        for (final part in SupportPart.values) {
          final orig = edit.readSupport(idx, 0, part);
          expect(orig, greaterThanOrEqualTo(0), reason: '$p unit $idx ${part.label}');
          expect(edit.writeSupport(idx, 0, part, orig), isFalse, reason: '$p 同值不应写');
        }
      }
    });
  });
}
