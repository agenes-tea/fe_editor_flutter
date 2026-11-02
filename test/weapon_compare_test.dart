import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/battle_sim.dart';
import 'package:fe_editor/core/rom_session.dart';

/// 全武器对比（BattleSimulator.compareWeapons）：
/// 排序、与 forecast 一致性、limit。
const dir = '/root/workspace/game-rom';
const fe7jp =
    '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe8jp =
    '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

void main() {
  test('FE7J：按每回合期望伤害降序，且与 forecast 逐项一致', () {
    final s = RomSession.open(File(fe7jp).readAsBytesSync(), 'fe7.gba')!;
    final sim = BattleSimulator(s.rom);
    final rows = sim.compareWeapons(0, 1, limit: 30);

    expect(rows, isNotEmpty, reason: '道具表里一定有带威力的武器');
    expect(rows.length, lessThanOrEqualTo(30));

    for (var i = 1; i < rows.length; i++) {
      expect(rows[i - 1].expectedDamage,
          greaterThanOrEqualTo(rows[i].expectedDamage),
          reason: '必须按期望伤害降序');
    }

    // 榜首与 forecast 单项推演完全一致（同一套公式，不许两套数值）
    final top = rows.first;
    final ref = sim.forecast(0, top.weaponId, 1);
    expect(top.expectedDamage, ref.expectedDamage);
    expect(top.damage, ref.damage);
    expect(top.hit, ref.hit);
    expect(top.crit, ref.crit);
    expect(top.attacks, ref.attacks);

    // 榜首名字可读（FE7J 是 Huffman+SJIS，日版原文能解出来）
    expect(s.liveRom.itemDisplayName(top.weaponId).trim(), isNotEmpty);
  });

  test('FE8J：limit=0 取全部；无威力/非武器类被过滤', () {
    final s = RomSession.open(File(fe8jp).readAsBytesSync(), 'fe8.gba')!;
    final sim = BattleSimulator(s.rom);
    final all = sim.compareWeapons(0, 1, limit: 0);
    expect(all, isNotEmpty);
    for (final r in all) {
      expect(r.kindLabel, isNot(isEmpty));
      expect(r.expectedDamage, greaterThanOrEqualTo(0));
    }
    // 默认 limit 截断
    final capped = sim.compareWeapons(0, 1, limit: 10);
    expect(capped.length, lessThanOrEqualTo(10));
  });
}
