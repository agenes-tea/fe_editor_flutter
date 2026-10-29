import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/rom_info.dart';

const dir = '/root/workspace/game-rom';
const fe6cn = '$dir/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe7cn = '$dir/火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba';
const fe7us = '$dir/1235 - 火炎之纹章-烈火之剑 Fire Emblem(US)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

FeRom _open(String p) {
  final d = File(p).readAsBytesSync();
  return FeRom(d, FeRom.detectTable(d)!);
}

int _classAddr(FeRom rom, int i) =>
    rom.classBase + i * rom.table.classDataSize;

int _unitAddr(FeRom rom, int i) => rom.unitBase + i * rom.table.unitDataSize;

void main() {
  group('职业表：移动力与体格', () {
    test('FE7J 领主：移动 5 / 体格 7', () {
      final rom = _open(fe7jp);
      final a = _classAddr(rom, 1);
      expect(rom.className(1), 'ロード');
      expect(rom.data[a + ClassOffsets.move], 5);
      expect(rom.data[a + ClassOffsets.con], 7);
    });

    test('FE7J 骑兵移动 7、重甲移动 4（游戏内已知值）', () {
      final rom = _open(fe7jp);
      // 利基亚骑士（骑兵）、利基亚重骑士（重甲）
      expect(rom.className(4), 'リキア騎士');
      expect(rom.data[_classAddr(rom, 4) + ClassOffsets.move], 7);
      expect(rom.className(6), 'リキア重騎士');
      expect(rom.data[_classAddr(rom, 6) + ClassOffsets.move], 4);
      // 重甲体格明显高于剑士
      expect(rom.data[_classAddr(rom, 6) + ClassOffsets.con], 13);
      expect(rom.data[_classAddr(rom, 5) + ClassOffsets.con], 5);
    });

    test('FE7J 全职业的移动力都在 0~15，体格都在 0~25', () {
      final rom = _open(fe7jp);
      for (var i = 1; i < rom.classCount; i++) {
        final a = _classAddr(rom, i);
        final mv = rom.data[a + ClassOffsets.move];
        final con = rom.data[a + ClassOffsets.con];
        expect(mv, inInclusiveRange(0, 15), reason: 'class $i 移动力=$mv');
        expect(con, inInclusiveRange(0, 25), reason: 'class $i 体格=$con');
      }
    });

    test('+37 / +41 是特性标志位，不能当数值读', () {
      final rom = _open(fe7jp);
      // +41 在真实数据里会出现 32 / 37 / 64 这类位组合，远超体格上限
      var sawFlag = false;
      for (var i = 1; i < rom.classCount; i++) {
        final v = rom.data[_classAddr(rom, i) + ClassOffsets.flags3];
        if (v > 25) sawFlag = true;
      }
      expect(sawFlag, isTrue, reason: '+41 应能读到超过 25 的位组合');
      // 而 +17 体格不会超过 25
      for (var i = 1; i < rom.classCount; i++) {
        expect(rom.data[_classAddr(rom, i) + ClassOffsets.con],
            lessThanOrEqualTo(25));
      }
    });

    test('FE7 简中版（Superxyj）：领主移动 5 / 体格 7，不再是异常值', () {
      // 用户截图里「锐利的领主」显示移动 0 / 体格 1、「领主骑士」体格 37 的那个 ROM
      final rom = _open(fe7cn);
      final a = _classAddr(rom, 1);
      expect(rom.className(1), '领主');
      expect(rom.data[a + ClassOffsets.move], 5);
      expect(rom.data[a + ClassOffsets.con], 7);
      // 领主骑士（ロードナイト）：移动 7 / 体格 9
      final a7 = _classAddr(rom, 7);
      expect(rom.data[a7 + ClassOffsets.move], 7);
      expect(rom.data[a7 + ClassOffsets.con], 9);
    });

    test('FE8J / FE7U / FE6 的移动力同样落在合理区间', () {
      for (final p in [fe8jp, fe7us, fe6cn]) {
        final rom = _open(p);
        final offset = ClassOffsets.move;
        for (var i = 1; i < rom.classCount && i < 40; i++) {
          final v = rom.data[_classAddr(rom, i) + offset];
          expect(v, inInclusiveRange(0, 15), reason: '$p class $i 移动力=$v');
        }
      }
    });
  });

  group('单位表：体格与有符号属性', () {
    test('单位体格在 +19，且不是 255', () {
      final rom = _open(fe7jp);
      final field = unitEditableFieldsFor(fe6: false)
          .firstWhere((f) => f.label == '体格');
      expect(field.offset, UnitOffsets.con);
      expect(field.offset, 19);
      // 罗伊 / 艾利乌德这类主角体格是 0（相对职业的增减量）
      final addr = _unitAddr(rom, 0);
      expect(EditableRom.open(File(fe7jp).readAsBytesSync(),
              FeRom.detectTable(File(fe7jp).readAsBytesSync())!)
          .readField(addr, field), rom.data[addr + 19]);
    });

    test('属性按有符号读：0xFF 显示 -1 而不是 255', () {
      final data = File(fe7jp).readAsBytesSync();
      final edit = EditableRom.open(data, FeRom.detectTable(data)!);
      final fields = unitEditableFieldsFor(fe6: false);
      final spd = fields.firstWhere((f) => f.label == '速度');
      final def = fields.firstWhere((f) => f.label == '防御');
      expect(spd.signed, isTrue);
      expect(def.signed, isTrue);

      // 巴亚特尔（u8）的 +15 速度原始字节是 255
      final addr = _unitAddr(edit.rom, 8);
      expect(edit.data[addr + UnitOffsets.baseSpeed], 0xFF);
      expect(edit.readField(addr, spd), -1);
    });

    test('写入 -1 后底层字节是 0xFF，读回仍是 -1', () {
      final data = File(fe7jp).readAsBytesSync();
      final edit = EditableRom.open(data, FeRom.detectTable(data)!);
      final lck = unitEditableFieldsFor(fe6: false)
          .firstWhere((f) => f.label == '幸运');
      final addr = _unitAddr(edit.rom, 4); // 盖茨
      expect(edit.writeField(addr, lck, -1), isTrue);
      expect(edit.data[addr + UnitOffsets.baseLuck], 0xFF);
      expect(edit.readField(addr, lck), -1);
      edit.revertAll();
      expect(edit.readField(addr, lck), greaterThanOrEqualTo(0));
    });

    test('成长率仍是无符号（上限 255，支持 200% 预设）', () {
      final fields = unitEditableFieldsFor(fe6: false);
      for (final label in ['HP成长', '力量成长', '魔防成长']) {
        final f = fields.firstWhere((x) => x.label == label);
        expect(f.signed, isFalse, reason: label);
        expect(f.min, 0);
        expect(f.max, 255, reason: '$label 上限应放宽到 255');
      }
    });

    test('职业基础属性也是有符号', () {
      final cls = classEditableFieldsFor(fe6: false);
      for (final label in ['HP', '力量', '技巧', '速度', '防御', '魔防']) {
        expect(cls.firstWhere((x) => x.label == label).signed, isTrue,
            reason: label);
      }
      // 移动力 / 体格不是有符号语义（都是正数）
      expect(cls.firstWhere((x) => x.label == '移动力').signed, isFalse);
      expect(cls.firstWhere((x) => x.label == '体格').signed, isFalse);
    });
  });
}
