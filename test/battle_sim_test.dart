import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/battle_sim.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/rom_info.dart';
import 'package:fe_editor/core/rom_session.dart';

/// 模拟器核心层测试：公式、逐级曲线、改前快照（overOriginal）。
///
/// 公式取自 GBA 火纹战斗结算（BattleCalculate）——近似值，
/// 不计地形、支援、三角武器与特効。这里用独立重算的公式值核对
/// [BattleSimulator] 的读表接线（偏移、职业回退、武器字段）。
const dir = '/root/workspace/game-rom';
const fe7jp =
    '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe8jp =
    '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

int _s8(Uint8List d, int off) {
  final v = d[off];
  return v >= 0x80 ? v - 0x100 : v;
}

void main() {
  late RomSession s;
  late EditableRom edit;

  setUpAll(() {
    s = RomSession.open(File(fe7jp).readAsBytesSync(), 'fe7jp.gba')!;
    edit = s.rom;
  });

  test('projectGrowth：期望/最坏/最好与逐级曲线', () {
    final rom = s.liveRom;
    final sim = BattleSimulator(edit);
    final p = sim.projectGrowth(0, targetLevel: 20);

    // 单位 0 的名字能读出来即可（FE7J 的 0 是エリウッド，别硬记名字）
    expect(rom.unitDisplayName(0).trim(), isNotEmpty);
    final levels = p.levels;
    expect(levels, greaterThan(0));
    final growth = sim.growthRates(0);

    for (final k in p.current.keys) {
      final g = growth[k]!.clamp(0, 255);
      final base = p.current[k]!;
      // 端点公式
      expect(p.expected[k], closeTo(base + levels * g / 100.0, 1e-9),
          reason: '期望端点 $k');
      expect(p.worst[k], base, reason: '最坏 = 不涨 $k');
      expect(p.best[k], base + levels, reason: '最好 = 每级 +1 $k');
      // 逐级曲线
      expect(p.expectedByLevel[k]!.length, levels + 1);
      expect(p.expectedByLevel[k]![0], closeTo(base.toDouble(), 1e-9));
      expect(p.expectedByLevel[k]![levels],
          closeTo(p.expected[k]!, 1e-9), reason: '曲线终点 = 期望端点 $k');
      expect(p.bestByLevel[k]![levels], p.best[k]);
      expect(p.worstByLevel[k]![levels], p.worst[k]);
      // 曲线单调（成长率非负）
      for (var i = 1; i <= levels; i++) {
        expect(p.expectedByLevel[k]![i], greaterThanOrEqualTo(p.expectedByLevel[k]![i - 1]));
      }
    }

    // 目标等级不高于当前等级：级数 0、曲线只有一格
    final p0 = sim.projectGrowth(0, targetLevel: p.fromLevel);
    expect(p0.levels, 0);
    expect(p0.expected, p0.current.map((k, v) => MapEntry(k, v.toDouble())));
    expect(p0.expectedByLevel['HP']!.length, 1);
  });

  test('overOriginal：无改动时与当前完全一致', () {
    final sim = BattleSimulator(edit);
    final orig = BattleSimulator.overOriginal(edit);
    expect(orig.baseStats(0), sim.baseStats(0));
    expect(orig.growthRates(0), sim.growthRates(0));
    expect(orig.projectGrowth(0, targetLevel: 25).expected,
        sim.projectGrowth(0, targetLevel: 25).expected);
    expect(orig.forecast(0, 1, 1), sim.forecast(0, 1, 1));
    expect(orig.capStatus(0, orig.projectGrowth(0)),
        sim.capStatus(0, sim.projectGrowth(0)));
  });

  test('overOriginal：改字段后保留改前值，当前模拟读到改后值', () {
    final sim = BattleSimulator(edit);
    final orig = BattleSimulator.overOriginal(edit);

    final beforeGrowth = orig.growthRates(0)['HP']!;
    final beforeStr = sim.baseStats(0)['力量']!;
    final targetGrowth = beforeGrowth >= 254 ? beforeGrowth - 1 : beforeGrowth + 1;

    final growField =
        unitEditableFields.firstWhere((f) => f.label == 'HP成长');
    final strField = unitEditableFields.firstWhere((f) => f.label == '力量');
    expect(edit.writeField(edit.unitAddress(0), growField, targetGrowth), isTrue);
    // 力量字段写的是「角色修正」，baseStats = 职业基础 + 修正，
    // 用「当前字节的增量」推算新基础值，不猜职业分量
    final oldUnitStr = edit.readField(edit.unitAddress(0), strField);
    final newUnitStr = oldUnitStr >= 127 ? oldUnitStr - 1 : oldUnitStr + 1;
    final strDelta = newUnitStr - oldUnitStr;
    expect(edit.writeField(edit.unitAddress(0), strField, newUnitStr), isTrue);

    expect(sim.growthRates(0)['HP'], targetGrowth, reason: '当前读到改后成长率');
    expect(sim.baseStats(0)['力量'], beforeStr + strDelta,
        reason: '当前读到改后力量');
    expect(orig.growthRates(0)['HP'], beforeGrowth, reason: '改前保留旧成长率');
    expect(orig.baseStats(0)['力量'], beforeStr, reason: '改前保留旧力量');

    // 成长模拟的分歧：同样到 20 级，改前/改后期望不同
    final pNow = sim.projectGrowth(0, targetLevel: 20);
    final pOld = orig.projectGrowth(0, targetLevel: 20);
    expect(pNow.expected['HP'], isNot(pOld.expected['HP']));
    expect(pNow.current['力量'], isNot(pOld.current['力量']));

    // 撤销后两边再次一致
    edit.revertAll();
    expect(sim.growthRates(0)['HP'], beforeGrowth);
    expect(sim.baseStats(0)['力量'], beforeStr);
    expect(edit.hasChanges, isFalse);
  });
  test('forecast：独立重算核对（单位 0 拿 1 号武器 打 单位 1）', () {
    final rom = s.liveRom;
    final data = edit.data;
    final sim = BattleSimulator(edit);
    final weapon = sim.weaponAt(1)!;

    int clsStat(int cid, int off) {
      final c = rom.classBase + cid * rom.table.classDataSize;
      return _s8(data, c + off);
    }

    final uA = rom.unitBase + 0 * rom.table.unitDataSize;
    final uB = rom.unitBase + 1 * rom.table.unitDataSize;
    final cidA = data[uA + 5];
    final cidB = data[uB + 5];

    int st(int unitOff, int cidOff, {int? cid, int? u}) {
      final ub = u != null ? _s8(data, u + unitOff) : 0;
      final cb = cid != null ? clsStat(cid, cidOff) : 0;
      return (cb + ub).clamp(0, 255);
    }

    final aStr = st(UnitOffsets.baseStr, ClassOffsets.baseStr, cid: cidA, u: uA);
    final aSkill = st(UnitOffsets.baseSkill, ClassOffsets.baseSkill, cid: cidA, u: uA);
    final aSpd = st(UnitOffsets.baseSpeed, ClassOffsets.baseSpeed, cid: cidA, u: uA);
    final aLk = _s8(data, uA + UnitOffsets.baseLuck);
    final dSpd = st(UnitOffsets.baseSpeed, ClassOffsets.baseSpeed, cid: cidB, u: uB);
    final dLk = _s8(data, uB + UnitOffsets.baseLuck);
    final dDef = st(UnitOffsets.baseDef, ClassOffsets.baseDef, cid: cidB, u: uB);

    // 手工按公式结算
    final dmg = (aStr + weapon.might - dDef).clamp(0, 255);
    final hit = (weapon.hit + aSkill * 2 + aLk ~/ 2 - (dSpd * 2 + dLk)).clamp(0, 100);
    final crit = (weapon.crit + aSkill ~/ 2 - dLk).clamp(0, 100);
    final atkSpeed = aSpd - (weapon.weight - aStr).clamp(0, 255);
    final doubles = atkSpeed >= dSpd + 4;

    final f = sim.forecast(0, 1, 1, distance: 1);
    expect(f.damage, dmg);
    expect(f.hit, hit);
    expect(f.crit, crit);
    expect(f.attacks, doubles ? 2 : 1);
    expect(f.doubling, doubles ? '我方追击' : '无');
    // 每回合期望伤害 = 伤害 × 次数 × 命中率
    expect(f.expectedDamage, closeTo(dmg * f.attacks * hit / 100, 1e-9));

    // 文案与数值自洽
    expect(f.labels()['伤害'], dmg.toString());
    expect(f.labels()['命中'], '$hit%');

    // 武器射程不覆盖距离 2 → 不能反击
    if (weapon.range.maxRange < 2) {
      final f2 = sim.forecast(0, 1, 1, distance: 2);
      expect(f2.canCounter, isFalse);
      expect(f2.counterAttacks, 0);
      expect(f2.doubling, '无', reason: '无反击时不应标敌方追击');
    }
  });

  test('weaponAt：改武器威力后 overOriginal 保留旧值', () {
    final rom = s.liveRom;
    final sim = BattleSimulator(edit);
    final orig = BattleSimulator.overOriginal(edit);
    final beforeMight = orig.weaponAt(1)!.might;

    final itemField =
        itemEditableFields.firstWhere((f) => f.label == '威力');
    final newMight = beforeMight >= 254 ? beforeMight - 1 : beforeMight + 1;
    expect(edit.writeField(edit.itemAddress(1), itemField, newMight), isTrue);

    expect(sim.weaponAt(1)!.might, newMight);
    expect(orig.weaponAt(1)!.might, beforeMight);

    // 伤害随威力变化（打同一目标）：独立重算两个字节源的伤害
    final dNow = sim.forecast(0, 1, 1).damage;
    final dOld = orig.forecast(0, 1, 1).damage;
    final str = sim.baseStats(0)['力量']!;
    final ddef = sim.baseStats(1)['防御']!;
    expect(dNow, (str + newMight - ddef).clamp(0, 255));
    expect(dOld, (str + beforeMight - ddef).clamp(0, 255));

    edit.revertAll();
    expect(edit.hasChanges, isFalse);
    expect(rom.itemCount, greaterThan(1));
  });

  test('capStatus：标出会撞职业上限的属性', () {
    final sim = BattleSimulator(edit);
    final p = sim.projectGrowth(0, targetLevel: 60);
    final caps = sim.classCaps(0);
    final status = sim.capStatus(0, p);
    // 幸运没有职业上限字段，不在标记范围
    expect(status.keys.toSet(), p.expected.keys.where(caps.containsKey).toSet());
    for (final k in status.keys) {
      expect(status[k], p.expected[k]! >= caps[k]!);
    }
  });

  test('forecast：道具表外的武器返回全 0 结果', () {
    final sim = BattleSimulator(edit);
    final f = sim.forecast(0, s.liveRom.itemCount + 10, 1);
    expect(f.damage, 0);
    expect(f.attacks, 0);
    expect(f.outcome, 'none');
  });
}
