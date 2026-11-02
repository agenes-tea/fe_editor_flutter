import 'dart:math' as math;
import 'dart:typed_data';

import 'editable_rom.dart';
import 'fe_rom.dart';
import 'item_catalog.dart';
import 'rom_info.dart';

/// 成长模拟结果：按每级成长率掷骰的期望值。
class GrowthProjection {
  /// 从当前等级长到 [targetLevel] 后的期望属性。
  final Map<String, double> expected;

  /// 最坏情况（一次都不涨）。
  final Map<String, int> worst;

  /// 最好情况（每次都涨）。
  final Map<String, int> best;

  /// 当前基础值。
  final Map<String, int> current;

  final int fromLevel;
  final int targetLevel;

  /// 每一级的期望值：键与 [expected] 相同，值是从 [fromLevel] 起每级一行
  /// （长度 = 级数 + 1，索引 0 即当前等级的期望 = 当前值）。
  final Map<String, List<double>> expectedByLevel;

  /// 每一级的最好值（每次 +1）。
  final Map<String, List<int>> bestByLevel;

  /// 每一级的最坏值（每次不涨，恒等于当前值）。
  final Map<String, List<int>> worstByLevel;

  GrowthProjection({
    required this.expected,
    required this.worst,
    required this.best,
    required this.current,
    required this.fromLevel,
    required this.targetLevel,
    required this.expectedByLevel,
    required this.bestByLevel,
    required this.worstByLevel,
  });

  int get levels => targetLevel - fromLevel;

  /// 该属性「平均涨多少」。
  double gain(String key) =>
      (expected[key] ?? 0) - (current[key] ?? 0).toDouble();
}

/// 一场战斗的推演结果。
class BattleForecast {
  final int damage;
  final int hit;
  final int crit;
  final int attacks;

  /// 被反击时的伤害（不能反击时为 0，[canCounter] 为 false）。
  final int counterDamage;
  final int counterHit;
  final int counterCrit;
  final int counterAttacks;
  final bool canCounter;

  /// 追击关系：'我方追击' / '敌方追击' / '双方都追击' / '无'.
  final String doubling;

  /// 两回合内谁先死（'atk' / 'def' / 'both' / 'none'）。
  final String outcome;

  /// 命中率 × 伤害算出的每回合平均伤害。
  final double expectedDamage;

  const BattleForecast({
    required this.damage,
    required this.hit,
    required this.crit,
    required this.attacks,
    required this.counterDamage,
    required this.counterHit,
    required this.counterCrit,
    required this.counterAttacks,
    required this.canCounter,
    required this.doubling,
    required this.outcome,
    required this.expectedDamage,
  });

  @override
  bool operator ==(Object other) =>
      other is BattleForecast &&
      other.damage == damage &&
      other.hit == hit &&
      other.crit == crit &&
      other.attacks == attacks &&
      other.counterDamage == counterDamage &&
      other.counterHit == counterHit &&
      other.counterCrit == counterCrit &&
      other.counterAttacks == counterAttacks &&
      other.canCounter == canCounter &&
      other.doubling == doubling &&
      other.outcome == outcome &&
      other.expectedDamage == expectedDamage;

  @override
  int get hashCode => Object.hash(
      damage, hit, crit, attacks, counterDamage, counterHit, counterCrit,
      counterAttacks, canCounter, doubling, outcome, expectedDamage);

  /// 结果的人类可读文案（界面与 MCP 共用，避免两套话术）。
  Map<String, String> labels() => {
        '伤害': damage.toString(),
        '命中': '$hit%',
        '必杀': '$crit%',
        '次数': attacks == 2 ? '2（追击）' : '1',
        '每回合期望伤害': expectedDamage.toStringAsFixed(1),
        '反击': canCounter
            ? '可反击 · 伤害 $counterDamage · 命中 $counterHit% · '
                '必杀 $counterCrit% · ${counterAttacks == 2 ? '2（追击）' : '1'} 次'
            : '不能反击（距离超出射程或无法还手）',
        '追击': doubling,
        '一回合结果': switch (outcome) {
          'atk' => '攻方一回合内打死守方',
          'def' => '守方一回合内打死攻方',
          'both' => '双方一回合内同归于尽',
          _ => '一回合内无人阵亡',
        },
      };
}

/// 战斗与成长模拟：纯公式，不写 ROM。
///
/// 公式取自 GBA 火纹的战斗结算（`BattleCalculate`）：
/// - 命中 = 武器命中 + 技巧×2 + 幸运/2（+ 支援/地形之类外部修正，这里不计）
/// - 回避 = 攻速×2 + 幸运（飞行对弓有额外，这里不计）
/// - 最终命中率 = 武器命中 − 对方回避（夹紧到 0..100）
/// - 伤害 = 力量 + 武器威力 −（对方防御 + 地形防御）
/// - 必杀率 = 武器必杀 + 技巧/2 − 对方幸运
/// - 追击：攻速 ≥ 对方攻速 + 4 时打两下
///
/// **可读的近似**：魔防与「用魔防算伤害」的魔法武器、三角武器、
/// 特效武器（对特定职业）都没有完整建模；反击按徒手速度，
/// 守方持有的武器不参与计算。**已建模**：武器自带数值加成表
/// （item 表 +12 的 9×s8）会加到攻方的有效属性上（游戏状态面板
/// 里绿色的 +N 就是它）。
/// 界面里明示「近似值」，避免用户把模拟结果当成游戏内的确定值。
///
/// 数据源有两种：
/// - 默认构造读**实时 buffer**（含当前未导出的改动，「改后」）；
/// - [BattleSimulator.overOriginal] 读**打开时的原始快照**（「改前」），
///   两者同屏即「改前 vs 改后」对比。
class BattleSimulator {
  final EditableRom edit;

  /// 非 null 时所有数值读这份字节（原始快照），几何仍用 [edit.rom]。
  final Uint8List? _original;

  BattleSimulator(this.edit) : _original = null;

  /// 用「打开 ROM 时的原始快照」做模拟（改前）。
  BattleSimulator.overOriginal(this.edit) : _original = edit.original;

  FeRom get rom => edit.liveRom;

  /// 读数值用的字节源。
  Uint8List get _src => _original ?? edit.data;

  int s8(int off) {
    final v = _src[off];
    return v >= 0x80 ? v - 0x100 : v;
  }

  int u8(int off) => _src[off];

  int u32(int off) =>
      _src[off] | (_src[off + 1] << 8) | (_src[off + 2] << 16) | (_src[off + 3] << 24);

  /// 角色默认职业（单位表 +5）。按**当前字节源**读：
  /// 原始快照下的模拟要看原始的职业，不能读实时值。
  int classIdOf(int unitId) {
    final base = rom.unitBase;
    if (base < 0) return -1;
    final at = base + unitId * rom.table.unitDataSize;
    if (at + 6 > _src.length) return -1;
    final cid = u8(at + 5);
    return cid < rom.classCount ? cid : -1;
  }

  /// 角色的基础属性 + 职业基础值。
  ///
  /// FE 的实际属性 = 职业基础值 + 角色个人修正（单位表里的那几项就是修正）。
  /// 所以「等级 1 的属性」是两者相加，之后再按成长率往上长。
  Map<String, int> baseStats(int unitId) {
    final u = rom.unitBase + unitId * rom.table.unitDataSize;
    final cid = classIdOf(unitId);
    final c = cid >= 0 ? rom.classBase + cid * rom.table.classDataSize : -1;
    int unitB(int off) => s8(u + off);
    int classB(int off) => c >= 0 ? s8(c + off) : 0;
    return {
      'HP': math.max(0, classB(ClassOffsets.baseHp) + unitB(UnitOffsets.baseHp)),
      '力量': math.max(0, classB(ClassOffsets.baseStr) + unitB(UnitOffsets.baseStr)),
      '技巧': math.max(
          0, classB(ClassOffsets.baseSkill) + unitB(UnitOffsets.baseSkill)),
      '速度': math.max(
          0, classB(ClassOffsets.baseSpeed) + unitB(UnitOffsets.baseSpeed)),
      '防御': math.max(0, classB(ClassOffsets.baseDef) + unitB(UnitOffsets.baseDef)),
      '魔防': math.max(0, classB(ClassOffsets.baseRes) + unitB(UnitOffsets.baseRes)),
      '幸运': math.max(0, unitB(UnitOffsets.baseLuck)),
    };
  }

  /// 角色的成长率（单位表 +28..+34）。
  Map<String, int> growthRates(int unitId) {
    final u = rom.unitBase + unitId * rom.table.unitDataSize;
    return {
      'HP': s8(u + UnitOffsets.growHp),
      '力量': s8(u + UnitOffsets.growStr),
      '技巧': s8(u + UnitOffsets.growSkill),
      '速度': s8(u + UnitOffsets.growSpeed),
      '防御': s8(u + UnitOffsets.growDef),
      '魔防': s8(u + UnitOffsets.growRes),
      '幸运': s8(u + UnitOffsets.growLuck),
    };
  }

  /// 期望成长：每级按成长率/100 的概率 +1，[levels] 级后的期望值。
  ///
  /// 不模拟「职业上限截断」——上限只影响游戏内，模拟里给的是纯成长曲线；
  /// 想看上限制约时界面上会同时显示职业上限。
  GrowthProjection projectGrowth(
    int unitId, {
    int? fromLevel,
    int targetLevel = 20,
  }) {
    final start = fromLevel ??
        u8(rom.unitBase + unitId * rom.table.unitDataSize + UnitOffsets.level);
    final base = baseStats(unitId);
    final growth = growthRates(unitId);
    final levels = math.max(0, targetLevel - start);
    final expected = <String, double>{};
    final worst = <String, int>{};
    final best = <String, int>{};
    final expectedByLevel = <String, List<double>>{};
    final bestByLevel = <String, List<int>>{};
    final worstByLevel = <String, List<int>>{};
    for (final k in base.keys) {
      final g = (growth[k] ?? 0).clamp(0, 255);
      final b = base[k]!;
      expected[k] = b + levels * g / 100.0;
      worst[k] = b;
      best[k] = b + levels;
      expectedByLevel[k] = [for (var i = 0; i <= levels; i++) b + i * g / 100.0];
      bestByLevel[k] = [for (var i = 0; i <= levels; i++) b + i];
      worstByLevel[k] = [for (var i = 0; i <= levels; i++) b];
    }
    return GrowthProjection(
      expected: expected,
      worst: worst,
      best: best,
      current: base,
      fromLevel: start,
      targetLevel: targetLevel,
      expectedByLevel: expectedByLevel,
      bestByLevel: bestByLevel,
      worstByLevel: worstByLevel,
    );
  }

  /// 职业的能力上限（用于界面同时展示「成长到顶了吗」）。
  Map<String, int> classCaps(int unitId) {
    final cid = classIdOf(unitId);
    if (cid < 0) return const {};
    final c = rom.classBase + cid * rom.table.classDataSize;
    int v(int off) => s8(c + off);
    return {
      'HP': v(ClassOffsets.maxHp),
      '力量': v(ClassOffsets.maxStr),
      '技巧': v(ClassOffsets.maxSkill),
      '速度': v(ClassOffsets.maxSpeed),
      '防御': v(ClassOffsets.maxDef),
      '魔防': v(ClassOffsets.maxRes),
      '体格': v(ClassOffsets.maxCon),
    };
  }

  /// [projection] 里哪些属性按期望值会撞职业上限（`expected ≥ 上限`）。
  ///
  /// 界面与 MCP 共用这一份判断，别各写一遍。
  Map<String, bool> capStatus(int unitId, GrowthProjection p) {
    final caps = classCaps(unitId);
    return {
      for (final k in p.expected.keys)
        if (caps[k] != null) k: p.expected[k]! >= caps[k]!,
    };
  }

  /// 一条武器的战斗相关字段（按当前字节源读；表外返回 null）。
  ///
  /// 表边界靠「ID 连续」判（§3）：越界的槽虽然还有字节，但
  /// ID 字节不再等于下标，不当成有效武器。
  ({int might, int hit, int weight, int crit, ItemRange range})? weaponAt(
      int id) {
    final base = rom.itemBase;
    if (base < 0) return null;
    final size = rom.table.itemDataSize;
    final at = base + id * size;
    if (at + 26 > _src.length) return null;
    if (u8(at + ItemOffsets.itemId) != id) return null;
    return (
      might: u8(at + ItemOffsets.might),
      hit: u8(at + ItemOffsets.hit),
      weight: u8(at + ItemOffsets.weight),
      crit: u8(at + ItemOffsets.crit),
      range: ItemRange.fromRaw(u8(at + ItemOffsets.range)),
    );
  }

  /// 武器自带的数值加成（item 表 +12 指向的 9 × s8：
  /// HP/力量/技巧/速度/防御/魔防/幸运/移动/体格）；指针无效或越界返回全 0。
  ///
  /// 游戏里持有者状态面板上绿色的 +N 就是这张表，战斗结算也用它——
  /// 所以 [forecast] 会把这张表加到**攻方**的有效属性上。
  List<int> weaponBonusAt(int weaponId) {
    const zero = [0, 0, 0, 0, 0, 0, 0, 0, 0];
    final base = rom.itemBase;
    if (base < 0) return zero;
    final size = rom.table.itemDataSize;
    final at = base + weaponId * size;
    if (at + 26 > _src.length) return zero;
    final ptr = u32(at + ItemOffsets.statBonusPointer);
    if (ptr < 0x08000000) return zero;
    final off = ptr & 0x1FFFFFF;
    if (off + 9 > _src.length) return zero;
    return [
      for (var k = 0; k < 9; k++) s8(off + k),
    ];
  }

  /// 推演 A 用武器打 B 的结果（A 的有效属性含该武器的 +12 数值加成表）。
  ///
  /// [aHp] / [bHp] 不给就用各自计算出的 HP；[distance] 决定能否反击。
  BattleForecast forecast(
    int attackerId,
    int weaponId,
    int defenderId, {
    int? attackerHp,
    int? defenderHp,
    int distance = 1,
  }) {
    final stats = baseStats(attackerId);
    final dstats = baseStats(defenderId);
    final w = weaponAt(weaponId);
    if (w == null) {
      return const BattleForecast(
        damage: 0,
        hit: 0,
        crit: 0,
        attacks: 0,
        counterDamage: 0,
        counterHit: 0,
        counterCrit: 0,
        counterAttacks: 0,
        canCounter: false,
        doubling: '无',
        outcome: 'none',
        expectedDamage: 0,
      );
    }

    // 武器自带加成（ItemStatBonuses 9×s8）加到攻方身上：
    // 0=HP 1=力量 2=技巧 3=速度 4=防御 5=魔防 6=幸运 7=移动 8=体格。
    // 守方按「没拿武器」算（反击按徒手），不加。
    final bonus = weaponBonusAt(weaponId);
    int eff(String key, int b) => (stats[key]! + b).clamp(0, 127);
    final as = eff('速度', bonus[3]);
    final aStr = eff('力量', bonus[1]);
    final aSkl = eff('技巧', bonus[2]);
    final aLk = eff('幸运', bonus[6]);
    final aDef = eff('防御', bonus[4]);
    final aHp = eff('HP', bonus[0]);
    final ds = dstats['速度']!;

    // 攻击方（属性已含武器加成）
    final dmg = math.max(0, aStr + w.might - dstats['防御']!);
    final hitRate =
        (w.hit + aSkl * 2 + aLk ~/ 2) - (ds * 2 + dstats['幸运']!);
    final hit = hitRate.clamp(0, 100).toInt();
    final crit =
        (w.crit + aSkl ~/ 2 - dstats['幸运']!).clamp(0, 100).toInt();
    final aAtkSpeed = as - math.max(0, w.weight - aStr);
    final attackerDoubles = aAtkSpeed >= ds + 4;

    // 防守方反击：只有射程覆盖 [distance] 才能反击（反击按徒手速度，
    // 不计对方手里那把武器的重量/威力——这是一个明示的近似）
    final inRange = distance >= w.range.minRange && distance <= w.range.maxRange;
    final bAtkSpeed = ds;
    final counterDoubles = bAtkSpeed >= aAtkSpeed + 4;
    final cDmg = math.max(0, dstats['力量']! - aDef);
    final cHit = (bAtkSpeed + dstats['技巧']! * 2 + dstats['幸运']! ~/ 2) -
            (aAtkSpeed * 2 + aLk)
        ;
    final cHitClamped = cHit.clamp(0, 100).toInt();
    final cCrit = (dstats['技巧']! ~/ 2 - aLk).clamp(0, 100).toInt();

    final attacks = attackerDoubles ? 2 : 1;
    final counterAttacks = inRange ? (counterDoubles ? 2 : 1) : 0;

    final aHpFinal = attackerHp ?? aHp;
    final bHpFinal = defenderHp ?? dstats['HP']!;
    final perRoundOnB = dmg * attacks * (hit / 100);
    final perRoundOnA = inRange ? cDmg * counterAttacks * (cHitClamped / 100) : 0.0;

    final bDies = perRoundOnB >= bHpFinal;
    final aDies = perRoundOnA >= aHpFinal;
    final outcome = bDies && aDies ? 'both' : bDies ? 'atk' : aDies ? 'def' : 'none';

    var doubling = '无';
    if (attackerDoubles) doubling = '我方追击';
    if (counterDoubles) doubling = '敌方追击';
    if (attackerDoubles && counterDoubles) doubling = '双方都追击';

    return BattleForecast(
      damage: dmg,
      hit: hit,
      crit: crit,
      attacks: attacks,
      counterDamage: inRange ? cDmg : 0,
      counterHit: inRange ? cHitClamped : 0,
      counterCrit: inRange ? cCrit : 0,
      counterAttacks: counterAttacks,
      canCounter: inRange,
      doubling: doubling,
      outcome: outcome,
      expectedDamage: perRoundOnB,
    );
  }

  /// 全武器对比：把道具表里**有威力的武器类道具**（剑/枪/斧/弓/杖/理/光/暗）
  /// 逐个用 [forecast] 算一遍对 [defenderId] 的每回合期望伤害，降序排。
  ///
  /// 给「这把武器该给谁 / 谁配什么武器」做决策；与模拟器页同一套公式，
  /// 所以列出的伤害/命中/必杀/次数与战斗推演面板看到的逐项一致。
  ///
  /// **不算职业持枪限制**（模拟本身就是近似）：不用的种类也会列出来，
  /// 看排名时结合角色当前武器的熟练度判断。
  List<WeaponComparisonRow> compareWeapons(
    int attackerId,
    int defenderId, {
    int limit = 30,
    int distance = 1,
    int? attackerHp,
    int? defenderHp,
  }) {
    final base = rom.itemBase;
    if (base < 0) return const [];
    final size = rom.table.itemDataSize;
    final rows = <WeaponComparisonRow>[];
    for (var id = 0; id < rom.itemCount; id++) {
      final at = base + id * size;
      final kind = u8(at + ItemOffsets.kind);
      // 0 剑 1 枪 2 斧 3 弓 4 杖 5 理 6 光 7 闇；其余类（道具/指环/龙石）不算武器
      if (kind > 7) continue;
      final w = weaponAt(id);
      if (w == null || w.might <= 0) continue;
      final f = forecast(attackerId, id, defenderId,
          distance: distance, attackerHp: attackerHp, defenderHp: defenderHp);
      rows.add(WeaponComparisonRow(
        weaponId: id,
        name: rom.itemDisplayName(id).trim(),
        kindLabel: ItemKind.fromRaw(kind).label,
        damage: f.damage,
        hit: f.hit,
        crit: f.crit,
        attacks: f.attacks,
        expectedDamage: f.expectedDamage,
        outcome: f.outcome,
      ));
    }
    rows.sort((a, b) => b.expectedDamage.compareTo(a.expectedDamage));
    if (limit > 0 && rows.length > limit) {
      return rows.sublist(0, limit);
    }
    return rows;
  }
}

/// 一条武器的对比行（公式与 [BattleSimulator.forecast] 完全一致）。
class WeaponComparisonRow {
  final int weaponId;
  final String name;
  final String kindLabel;
  final int damage;
  final int hit;
  final int crit;
  final int attacks;
  final double expectedDamage;
  final String outcome;

  WeaponComparisonRow({
    required this.weaponId,
    required this.name,
    required this.kindLabel,
    required this.damage,
    required this.hit,
    required this.crit,
    required this.attacks,
    required this.expectedDamage,
    required this.outcome,
  });
}
