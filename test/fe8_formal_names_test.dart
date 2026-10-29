import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe8_formal_names.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/zh_table.dart';
import 'package:fe_editor/core/zh_tables_data.dart';

/// 汉化版（火花天龙剑 & 狼组）的同音替代字处理。
///
/// 当年的汉化组按读音抓同音字塞进码表、没考虑字义，所以游戏里「利昂」显示成
/// 「厉昂」、「塞思」显示成「撒说」。码表本身是好的（匹配率 0.88），
/// 这不是乱码也不是 bug。这里验证两点：
/// 1. `unitName` 仍返回 ROM 原文（同音字），文本查看器等需要原文的地方不受影响；
/// 2. `unitDisplayName` 返回正式译名，只在挂了中文码表的汉化版上生效。
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
  group('FE8 汉化版同音替代处理', () {
    test('码表本身是好的：匹配率超过阈值', () {
      final rom = _openCn();
      expect(rom.zhTableMatchRatio(), greaterThan(0.5));
    });

    test('unitName 返回 ROM 原文（同音字），不是正式译名', () {
      final rom = _openCn();
      // 利昂（单位索引 63）在 ROM 里显示为「厉昂」
      expect(rom.unitName(63).trim(), '厉昂');
      expect(rom.unitName(1).trim(), '撒说', reason: '塞思→撒说');
    });

    test('unitDisplayName 返回正式译名', () {
      final rom = _openCn();
      expect(rom.unitDisplayName(63).trim(), '利昂');
      expect(rom.unitDisplayName(1).trim(), '塞思');
      expect(rom.unitDisplayName(0).trim(), '艾瑞珂');
      expect(rom.unitDisplayName(66).trim(), '沃尔塔', reason: 'ヴァルター');
    });

    test('日版不受影响：仍显示日文名', () {
      final rom = _openJp();
      expect(rom.usesHomophoneSubstitution, isFalse);
      expect(rom.unitDisplayName(0), 'エイリーク');
      expect(rom.unitDisplayName(1), 'ゼト');
    });

    test('没挂码表时不判为同音替代', () {
      final data = File(fe8cn).readAsBytesSync();
      final rom = FeRom(data, FeRom.detectTable(data)!);
      expect(rom.usesHomophoneSubstitution, isFalse);
      // 退回原始解码（此时是空串，因为 unknown 且无码表）
      expect(rom.unitDisplayName(0), rom.unitName(0));
    });

    test('译名表键是 nameTextId，与单位索引不同', () {
      final rom = _openCn();
      final tid = rom.unitNameTextId(63);
      expect(tid, 443, reason: '利昂的 nameTextId');
      expect(tid, isNot(63), reason: '不能拿单位索引当键');
      expect(fe8FormalNames[tid], '利昂');
      expect(fe8FormalNameFor(tid), '利昂');
      expect(fe8FormalNameFor(99999), isNull);
    });

    test('译名表覆盖全部我方角色与主要敌方', () {
      expect(fe8FormalNames.length, 86);
      // 抽查几个用户确认过的
      expect(fe8FormalNames[443], '利昂');
      expect(fe8FormalNames[446], '沃尔塔');
      expect(fe8FormalNames[410], '塞思');
      // 敌方角色
      expect(fe8FormalNames[467], '维加尔德');
      expect(fe8FormalNames[464], '奥尼尔');
    });

    test('译名表覆盖全部有名单位，没有遗漏', () {
      final rom = _openCn();
      var missing = 0;
      for (var i = 0; i < rom.unitCount; i++) {
        final tid = rom.unitNameTextId(i);
        if (tid <= 0) continue;
        if (!fe8FormalNames.containsKey(tid)) missing++;
      }
      expect(missing, 0, reason: '有 $missing 个单位的 nameTextId 没登记译名');
    });

    test('查不到译名时返回 null，调用方退回原文', () {
      expect(fe8FormalNameFor(0), isNull);
      expect(fe8FormalNameFor(99999), isNull);
    });
  });
}
