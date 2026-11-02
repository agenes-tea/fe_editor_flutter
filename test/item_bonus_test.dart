import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/battle_sim.dart';
import 'package:fe_editor/core/item_catalog.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/ui/item_page.dart';

/// 道具介绍 / 数值加成（9×s8）/ 专用锁定位（IA_LOCK ↔ CA_LOCK）测试。
///
/// 数据依据：反编译 fireemblem6j `item.h`/`item.c`（ItemStatBonuses、
/// CanUnitUseWeapon）与 FE8U `bmitem.h`（IA_LOCK_0..7），锚点全部来自
/// 真实 ROM 实测（封印之剑 = Excalibur = def+5 res+5，仅 Phegas 系可用）。
const dir = '/root/workspace/game-rom';
const fe6jp =
    '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const fe7jp =
    '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe8jp =
    '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

void main() {
  test('FE6 封印之剑（Excalibur）：双防+5 与 LOCK_ROY 位', () {
    final s = RomSession.open(File(fe6jp).readAsBytesSync(), 'fe6jp.gba')!;
    final rom = s.liveRom;
    final catalog = ItemCatalog(rom);
    final e = catalog.entryAt(15)!;

    // Excalibur 的锚点：威力18 命中95 必杀10 重量8（与游戏内 Help 一致）
    expect(e.might, 18);
    expect(e.hit, 95);
    expect(e.crit, 10);
    expect(e.weight, 8);

    // 数值加成表：def+5 res+5（两防+5），全部 s8 读
    final b = catalog.statBonuses(e);
    expect(b.def, 5);
    expect(b.res, 5);
    expect(b.hp, 0);
    expect(b.str, 0);
    expect(b.summaryText, '防御+5 魔防+5');

    // 专用锁定：LOCK_ROY（bit11，主角 King 系），单位表侧对应 bit16
    final locks = catalog.lockInfo(e);
    expect(locks, hasLength(1));
    expect(locks.first.bit, 11);
    expect(locks.first.label, contains('Roy'));
    expect(locks.first.unitBit, 16);
    // 静态表里 Zephia（bit19）是唯一带 LOCK 位的主角条，但那是 ZEPHIEL 位，
    // 不是 ROY 位——ROY 的位由游戏事件授予
    expect(locks.first.holders, isEmpty,
        reason: 'FE6 原版静态表没有角色带 ROY 位（游戏内授予）');

    // Zephia 的 CA_LOCK_ZEPHIEL（bit19）实测存在，反向验证扫描逻辑
    final data = rom.data;
    var zephiaIdx = -1;
    for (var i = 0; i < rom.unitCount; i++) {
      final at = rom.unitBase + i * rom.table.unitDataSize + 0x28;
      final v = data[at] |
          (data[at + 1] << 8) |
          (data[at + 2] << 16) |
          (data[at + 3] << 24);
      if ((v & (1 << 19)) != 0) zephiaIdx = i;
    }
    expect(zephiaIdx, greaterThanOrEqualTo(0), reason: 'Zephia 应在单位表里');
    expect(rom.unitDisplayName(zephiaIdx).trim(), 'ゼフィール');
  });

  test('FE8：命名武器加成与 LOCK 位', () {
    final s = RomSession.open(File(fe8jp).readAsBytesSync(), 'fe8jp.gba')!;
    final rom = s.liveRom;
    final catalog = ItemCatalog(rom);

    // Excalibur（62）：速+5，无 LOCK 位（FE8 里谁拿谁享受）
    final exc = catalog.entryAt(62)!;
    expect(catalog.statBonuses(exc).speed, 5);
    expect(catalog.lockInfo(exc), isEmpty);

    // 沙姆希尔（12）：LOCK_2（bit12）；竜石（170）：LOCK_3（bit10，龙/魔物专用）。
    // 注意：ルナ 的 bit17 是 NEGATE_DEFENSE、守护戒指的 bit14/15 是
    // NEGATE_FLYING/NEGATE_CRIT，**不是** LOCK 位（别按名字猜位号）。
    final shams = catalog.entryAt(12)!;
    final shamsLocks = catalog.lockInfo(shams);
    expect(shamsLocks, hasLength(1));
    expect(shamsLocks.first.bit, 12, reason: 'IA_LOCK_2 = bit12');
    expect(shamsLocks.first.label, 'LOCK_2 专用');

    final dragon = catalog.entryAt(170)!;
    final dLocks = catalog.lockInfo(dragon);
    expect(dLocks.first.bit, 10, reason: 'IA_LOCK_3（龙/魔物）= bit10');
    expect(dLocks.first.label, '龙/魔物专用');

    // ルナ 只带 NEGATE_DEFENSE（bit17），没有 LOCK 位
    expect(catalog.lockInfo(catalog.entryAt(70)!), isEmpty);
  });

  test('FE7：Durandal（アールスピア）与 Freyur 的加成', () {
    final s = RomSession.open(File(fe7jp).readAsBytesSync(), 'fe7jp.gba')!;
    final rom = s.liveRom;
    final catalog = ItemCatalog(rom);

    expect(catalog.statBonuses(catalog.entryAt(132)!).str, 5,
        reason: 'Durandal 攻+5');
    expect(catalog.statBonuses(catalog.entryAt(60)!).luck, 5,
        reason: 'Freyur 幸运+5');
  });

  test('s8 语义：负值加成不会被读成 251', () {
    const b = ItemStatBonuses(0, 0, 0, 0, -5, 0, 0, 0, 0);
    expect(b.def, -5);
    expect(b.entries, contains(('防御', -5)));
    expect(b.summaryText, '防御-5');
    expect(b.values, [0, 0, 0, 0, -5, 0, 0, 0, 0]);
  });

  test('介绍文本：FE7/FE8 能解出非空 desc', () {
    for (final (path, tag, itemId, unitIdx) in [
      (fe7jp, 'FE7J', 60, 0),
      (fe8jp, 'FE8J', 62, 0),
    ]) {
      final s = RomSession.open(File(path).readAsBytesSync(), '$tag.gba')!;
      final rom = s.liveRom;
      expect(rom.itemDescription(itemId).trim(), isNotEmpty,
          reason: '$tag 道具 $itemId 的介绍');
      expect(rom.unitDescription(unitIdx).trim(), isNotEmpty,
          reason: '$tag 角色 $unitIdx 的介绍');
    }
  });

  test('战斗模拟：武器加成进攻方属性，改前快照不受影响', () {
    final s = RomSession.open(File(fe8jp).readAsBytesSync(), 'fe8jp.gba')!;
    final edit = s.rom;
    final rom = s.liveRom;
    final sim = BattleSimulator(edit);
    final orig = BattleSimulator.overOriginal(edit);

    // Excalibur（62）的加成表指针
    final catalog = ItemCatalog(rom);
    final p = catalog.entryAt(62)!.statBonusPointer;
    expect(p, greaterThan(0), reason: 'Excalibur 应有加成表');
    final bonusOff = p & 0x1FFFFFF;
    expect(sim.weaponBonusAt(62), [0, 0, 0, 5, 0, 0, 0, 0, 0]);

    // 攻方有效速度 = 基础 + 5：手动重算追击判定（含反击侧）
    final att = 0;
    final baseSpd = sim.baseStats(att)['速度']!;
    final effSpd = baseSpd + 5;
    final dSpd = sim.baseStats(1)['速度']!;
    final w = sim.weaponAt(62)!;
    final effStr = sim.baseStats(att)['力量']!; // Excalibur 无攻加成
    final atkSpd = effSpd - (w.weight - effStr).clamp(0, 255);
    final attackerDoubles = atkSpd >= dSpd + 4;
    final counterDoubles = dSpd >= atkSpd + 4;
    String expectDoubling = '无';
    if (attackerDoubles) expectDoubling = '我方追击';
    if (counterDoubles) expectDoubling = '敌方追击';
    if (attackerDoubles && counterDoubles) expectDoubling = '双方都追击';

    final f = sim.forecast(att, 62, 1);
    expect(f.doubling, expectDoubling);
    expect(f.attacks, attackerDoubles ? 2 : 1);

    // 把加成表清零：只有非 0 的字节会被写，返回「实际改动数」>0
    expect(edit.writeInstruction(bonusOff, List.filled(9, 0)), greaterThan(0));
    expect(sim.weaponBonusAt(62), List.filled(9, 0));
    expect(orig.weaponBonusAt(62), [0, 0, 0, 5, 0, 0, 0, 0, 0]);
    edit.revertAll();
    expect(sim.weaponBonusAt(62), [0, 0, 0, 5, 0, 0, 0, 0, 0]);
  });

  testWidgets('道具详情页：加成与锁定卡片（FE7 Durandal）', (tester) async {
    final s = RomSession.open(File(fe7jp).readAsBytesSync(), 'fe7jp.gba')!;
    final rom = s.liveRom;
    final catalog = ItemCatalog(rom);
    final entry = catalog.entryAt(132)!;

    await tester.pumpWidget(
      MaterialApp(
        home: ItemDetailPage(catalog: catalog, entry: entry, edit: s.rom),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // 下面几块都在首屏视口外（ListView 懒加载），先滚到位再断言
    await tester.scrollUntilVisible(
      find.text('数值加成（只读，加到持有者身上）'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    // 加成卡片（带符号读）：标签与值是两列
    expect(find.text('数值加成（只读，加到持有者身上）'), findsOneWidget);
    expect(find.text('攻击'), findsOneWidget);
    expect(find.text('+5'), findsOneWidget);

    // 锁定卡片：Durandal attrs=0x40011 → bit18 = LOCK_4
    expect(find.text('专用限制（LOCK，只读）'), findsOneWidget);
    expect(find.textContaining('LOCK_4'), findsOneWidget);

    // 介绍段：FE7 是 huffmanSjis，描述文本可解
    expect(find.text('介绍'), findsOneWidget);
  });
}
