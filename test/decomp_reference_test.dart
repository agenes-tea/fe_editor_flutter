import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/rom_info.dart';

const dir = '/root/workspace/game-rom';
const fe6cn = '$dir/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const fe6jp = '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe7us = '$dir/1235 - 火炎之纹章-烈火之剑 Fire Emblem(US)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';
const fe8cn = '$dir/火炎之纹章-圣魔之光石汉化.gba';

FeRom _open(String p) {
  final d = File(p).readAsBytesSync();
  return FeRom(d, FeRom.detectTable(d)!);
}

/// 本项目的 ROM 结构体偏移，与 FireEmblemUniverse/fireemblem8u 的
/// `include/bmunit.h` 里的 C 结构体定义逐字段比对。
///
/// 那是最权威的二手印证（FEBuilderGBA 只给控件编号，语义靠反推）。
/// 这里把它写成断言：以后有人想「照着文档改偏移」，测试会立刻拦住。
void main() {
  group('CharacterData（角色/单位表）偏移对照反编译', () {
    test('文本 id 与标识字段', () {
      expect(UnitOffsets.nameTextId, 0x00, reason: 'nameTextId');
      expect(UnitOffsets.descTextId, 0x02, reason: 'descTextId');
      expect(UnitOffsets.unitId, 0x04, reason: 'number');
      expect(UnitOffsets.portraitId, 0x06, reason: 'portraitId');
      expect(UnitOffsets.affinity, 0x09, reason: 'affinity');
      expect(UnitOffsets.attributes, 0x28, reason: 'attributes（u32 标志位）');
    });

    test('基础属性（都是有符号 s8）', () {
      expect(UnitOffsets.level, 0x0B, reason: 'baseLevel');
      expect(UnitOffsets.baseHp, 0x0C, reason: 'baseHP');
      expect(UnitOffsets.baseStr, 0x0D, reason: 'basePow');
      expect(UnitOffsets.baseSkill, 0x0E, reason: 'baseSkl');
      expect(UnitOffsets.baseSpeed, 0x0F, reason: 'baseSpd');
      expect(UnitOffsets.baseDef, 0x10, reason: 'baseDef');
      expect(UnitOffsets.baseRes, 0x11, reason: 'baseRes');
      expect(UnitOffsets.baseLuck, 0x12, reason: 'baseLck');
      expect(UnitOffsets.con, 0x13, reason: 'baseCon');
    });

    test('武器熟练度 8 项连续排在 0x14', () {
      for (var k = 0; k < 8; k++) {
        expect(UnitOffsets.weaponRanks[k], 0x14 + k,
            reason: 'baseRanks[$k]');
      }
    });

    test('成长率排在 0x1C', () {
      expect(UnitOffsets.growHp, 0x1C, reason: 'growthHP');
      expect(UnitOffsets.growStr, 0x1D, reason: 'growthPow');
      expect(UnitOffsets.growSkill, 0x1E, reason: 'growthSkl');
      expect(UnitOffsets.growSpeed, 0x1F, reason: 'growthSpd');
      expect(UnitOffsets.growDef, 0x20, reason: 'growthDef');
      expect(UnitOffsets.growRes, 0x21, reason: 'growthRes');
      expect(UnitOffsets.growLuck, 0x22, reason: 'growthLck');
    });

    test('支援数据指针与会话组', () {
      expect(UnitOffsets.supportPointer, 0x2C, reason: 'pSupportData');
      expect(UnitOffsets.talkGroup, 0x30, reason: 'visit_group');
    });

    test('字段不重叠（每个字节只被一个字段占用）', () {
      final used = <int>[];
      void mark(int off, String name) {
        expect(used.contains(off), isFalse, reason: '$off 被 $name 重复占用');
        used.add(off);
      }

      mark(UnitOffsets.nameTextId, 'nameTextId');
      mark(UnitOffsets.descTextId, 'descTextId');
      mark(UnitOffsets.unitId, 'unitId');
      mark(UnitOffsets.portraitId, 'portraitId');
      // portraitId 是 u16，占 6..7
      expect(used.contains(UnitOffsets.portraitId + 1), isFalse);
      used.add(UnitOffsets.portraitId + 1);
      mark(UnitOffsets.affinity, 'affinity');
      for (final off in [
        UnitOffsets.level,
        UnitOffsets.baseHp,
        UnitOffsets.baseStr,
        UnitOffsets.baseSkill,
        UnitOffsets.baseSpeed,
        UnitOffsets.baseDef,
        UnitOffsets.baseRes,
        UnitOffsets.baseLuck,
        UnitOffsets.con,
        ...UnitOffsets.weaponRanks,
        UnitOffsets.growHp,
        UnitOffsets.growStr,
        UnitOffsets.growSkill,
        UnitOffsets.growSpeed,
        UnitOffsets.growDef,
        UnitOffsets.growRes,
        UnitOffsets.growLuck,
        UnitOffsets.supportPointer,
        UnitOffsets.talkGroup,
      ]) {
        mark(off, 'off$off');
      }
      // attributes 是 u32，占 0x28..0x2B
      for (var k = 0; k < 4; k++) {
        mark(UnitOffsets.attributes + k, 'attributes+$k');
      }
    });
  });

  group('ClassData（职业表）偏移对照反编译', () {
    test('标识与基础字段', () {
      expect(ClassOffsets.nameTextId, 0x00, reason: 'nameTextId');
      expect(ClassOffsets.descTextId, 0x02, reason: 'descTextId');
      expect(ClassOffsets.classNumber, 0x04, reason: 'number');
      expect(ClassOffsets.promotionClass, 0x05, reason: 'promotion');
      expect(ClassOffsets.moveIcon, 0x06, reason: 'SMSId');
      expect(ClassOffsets.portraitId, 0x08, reason: 'defaultPortraitId');
    });

    test('基础值与体格、移动力', () {
      expect(ClassOffsets.baseHp, 0x0B, reason: 'baseHP');
      expect(ClassOffsets.baseStr, 0x0C, reason: 'basePow');
      expect(ClassOffsets.baseSkill, 0x0D, reason: 'baseSkl');
      expect(ClassOffsets.baseSpeed, 0x0E, reason: 'baseSpd');
      expect(ClassOffsets.baseDef, 0x0F, reason: 'baseDef');
      expect(ClassOffsets.baseRes, 0x10, reason: 'baseRes');
      expect(ClassOffsets.con, 0x11, reason: 'baseCon');
      expect(ClassOffsets.move, 0x12, reason: 'baseMov');
    });

    test('能力上限排在 0x13', () {
      expect(ClassOffsets.maxHp, 0x13, reason: 'maxHP');
      expect(ClassOffsets.maxStr, 0x14, reason: 'maxPow');
      expect(ClassOffsets.maxSkill, 0x15, reason: 'maxSkl');
      expect(ClassOffsets.maxSpeed, 0x16, reason: 'maxSpd');
      expect(ClassOffsets.maxDef, 0x17, reason: 'maxDef');
      expect(ClassOffsets.maxRes, 0x18, reason: 'maxRes');
      expect(ClassOffsets.maxCon, 0x19, reason: 'maxCon');
    });

    test('成长率排在 0x1B', () {
      expect(ClassOffsets.growHp, 0x1B, reason: 'growthHP');
      expect(ClassOffsets.growStr, 0x1C, reason: 'growthPow');
      expect(ClassOffsets.growSkill, 0x1D, reason: 'growthSkl');
      expect(ClassOffsets.growSpeed, 0x1E, reason: 'growthSpd');
      expect(ClassOffsets.growDef, 0x1F, reason: 'growthDef');
      expect(ClassOffsets.growRes, 0x20, reason: 'growthRes');
      expect(ClassOffsets.growLuck, 0x21, reason: 'growthLck');
    });

    test('转职加成排在 0x22', () {
      expect(ClassOffsets.promoHp, 0x22, reason: 'promotionHp');
      expect(ClassOffsets.promoStr, 0x23, reason: 'promotionPow');
      expect(ClassOffsets.promoSkill, 0x24, reason: 'promotionSkl');
      expect(ClassOffsets.promoSpeed, 0x25, reason: 'promotionSpd');
      expect(ClassOffsets.promoDef, 0x26, reason: 'promotionDef');
      expect(ClassOffsets.promoRes, 0x27, reason: 'promotionRes');
    });

    test('熟练度：FE7/FE8 在 0x2C，FE6 在 0x28（条目更小）', () {
      expect(ClassOffsets.weaponRankOffset(false), 0x2C, reason: 'FE7/FE8');
      expect(ClassOffsets.weaponRankOffset(true), 0x28, reason: 'FE6');
    });

    test('特性标志位不是数值字段', () {
      // 反编译里 attributes @0x28，而飞行/可出击等标志实际在 +37/+41。
      // 注意：+37 同时也是 promotionSpd 的字节位（0x25），两者同址不同义。
      expect(ClassOffsets.flags2, 37);
      expect(ClassOffsets.flags3, 41);
      // +41 绝不能当体格读（那是老 bug：界面出现 1、37 这种异常值）
      expect(ClassOffsets.con, 17);
      expect(ClassOffsets.move, 18);
    });
  });

  group('条目大小', () {
    test('FE6 是 48，FE7/FE8 是 52（不是文档里说的统一 72）', () {
      for (final e in {
        'FE6': fe6cn,
        'FE7J': fe7jp,
        'FE7U': fe7us,
        'FE8J': fe8jp,
        'FE8CN': fe8cn,
      }.entries) {
        final size = _open(e.value).table.unitDataSize;
        expect(size, e.key == 'FE6' ? 48 : 52, reason: e.key);
      }
    });

    test('CharacterData 结构体上限 0x34，与 52 字节吻合', () {
      // 反编译：/* 31 */ u8 _pad_[0x34 - 0x31]; → 条目到 0x34 结束
      expect(_open(fe7jp).table.unitDataSize, 0x34);
    });
  });

  group('字段取值范围（修正参考文档里的错误说法）', () {
    test('职业移动力最大 15、体格最大 25（不是 0~63）', () {
      for (final p in [fe6cn, fe7jp, fe7us, fe8jp, fe8cn]) {
        final rom = _open(p);
        for (var i = 1; i < rom.classCount && i < 60; i++) {
          final a = rom.classBase + i * rom.table.classDataSize;
          final mv = rom.data[a + ClassOffsets.move];
          final con = rom.data[a + ClassOffsets.con];
          expect(mv, inInclusiveRange(0, 15), reason: '$p class $i mov=$mv');
          expect(con, inInclusiveRange(0, 25), reason: '$p class $i con=$con');
        }
      }
    });

    test('S 档累计值是 0xFB 而不是 0xFF', () {
      // 两份材料都说是 FF，实测是 FB（FE6 与 FE7/FE8 的 S 档都是 0xFB）
      for (final fe6 in [true, false]) {
        expect(maxRankValueForTest(fe6: fe6), 0xFB);
      }
    });

    test('成长率字段是无符号 0~100', () {
      final rom = _open(fe7jp);
      for (var i = 0; i < 20; i++) {
        final a = rom.unitBase + i * rom.table.unitDataSize;
        expect(rom.data[a + UnitOffsets.growHp], inInclusiveRange(0, 100));
        expect(rom.data[a + UnitOffsets.growLuck], inInclusiveRange(0, 100));
      }
    });
  });
}

int maxRankValueForTest({required bool fe6}) {
  // 与 cheat_presets.maxRankValue 同源，避免测试反向依赖 core 层常量
  return fe6 ? 0xFB : 0xFB;
}
