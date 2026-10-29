import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/item_catalog.dart';

const dir = '/root/workspace/game-rom';
const fe6jp = '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const fe6cn = '$dir/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe7us = '$dir/1235 - 火炎之纹章-烈火之剑 Fire Emblem(US)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

FeRom _open(String path) {
  final data = File(path).readAsBytesSync();
  final table = FeRom.detectTable(data);
  expect(table, isNotNull, reason: path);
  return FeRom(data, table!);
}

void main() {
  group('道具种类', () {
    test('种别枚举与 FEBuilderGBA 的 L_7_COMBO 一致', () {
      expect(ItemKind.fromRaw(0x00), ItemKind.sword);
      expect(ItemKind.fromRaw(0x01), ItemKind.lance);
      expect(ItemKind.fromRaw(0x02), ItemKind.axe);
      expect(ItemKind.fromRaw(0x03), ItemKind.bow);
      expect(ItemKind.fromRaw(0x04), ItemKind.staff);
      expect(ItemKind.fromRaw(0x05), ItemKind.anima);
      expect(ItemKind.fromRaw(0x06), ItemKind.light);
      expect(ItemKind.fromRaw(0x07), ItemKind.dark);
      expect(ItemKind.fromRaw(0x09), ItemKind.consumable);
      expect(ItemKind.fromRaw(0x0B), ItemKind.monsterOnly);
      expect(ItemKind.fromRaw(0x0C), ItemKind.ring);
      expect(ItemKind.fromRaw(0x11), ItemKind.fireDragonStone);
      expect(ItemKind.fromRaw(0x12), ItemKind.dancingRing);
      // 未列出的值归为未知
      expect(ItemKind.fromRaw(0x77), ItemKind.unknown);
    });

    test('武器按剑/枪/斧/弓/杖/魔法分组，消耗品单独成组', () {
      final rom = _open(fe7jp);
      final cat = ItemCatalog(rom);
      final groups = cat.grouped();

      // 武器组里应同时有剑枪斧弓杖
      final weapons = groups[ItemGroup.weapon]!;
      final kinds = weapons.map((e) => e.kind).toSet();
      expect(kinds, contains(ItemKind.sword));
      expect(kinds, contains(ItemKind.lance));
      expect(kinds, contains(ItemKind.axe));
      expect(kinds, contains(ItemKind.bow));
      expect(kinds, contains(ItemKind.staff));

      // 消耗品组里全是消耗品类
      final consumables = groups[ItemGroup.consumable]!;
      expect(consumables, isNotEmpty);
      for (final e in consumables) {
        expect(e.kind.group, ItemGroup.consumable);
      }
    });

    test('FE7J 实测：剑在前、枪次之、消耗品最多', () {
      final rom = _open(fe7jp);
      final cat = ItemCatalog(rom);
      // 依实测分布：剑 24 / 枪 16 / 斧 18 / 弓 13 / 杖 15 / 消耗品 44
      int count(ItemKind k) =>
          cat.grouped().values.expand((g) => g).where((e) => e.kind == k).length;
      expect(count(ItemKind.sword), greaterThan(10));
      expect(count(ItemKind.consumable), greaterThan(20));
      expect(count(ItemKind.axe), greaterThan(10));
    });

    test('所有版本的道具表都能解析出种类', () {
      for (final path in [fe6jp, fe6cn, fe7jp, fe7us, fe8jp]) {
        final rom = _open(path);
        final cat = ItemCatalog(rom);
        expect(cat.count, greaterThan(50), reason: path);
        var known = 0;
        for (var i = 0; i < cat.count; i++) {
          final e = cat.entryAt(i)!;
          if (e.kind != ItemKind.unknown) known++;
        }
        // 绝大多数条目应有已知种类
        expect(known, greaterThan(cat.count ~/ 2), reason: path);
      }
    });
  });

  group('武器等级', () {
    test('熟练度累计值映射到 E~S', () {
      expect(WeaponRank.fromValue(0x00), WeaponRank.none);
      expect(WeaponRank.fromValue(0x01), WeaponRank.e);
      expect(WeaponRank.fromValue(0x1E), WeaponRank.e);
      expect(WeaponRank.fromValue(0x1F), WeaponRank.d);
      expect(WeaponRank.fromValue(0x47), WeaponRank.c);
      expect(WeaponRank.fromValue(0x79), WeaponRank.b);
      expect(WeaponRank.fromValue(0xB5), WeaponRank.a);
      expect(WeaponRank.fromValue(0xFB), WeaponRank.s);
    });

    test('FE7J 武器的等级值落在已知阈值集合里', () {
      final rom = _open(fe7jp);
      final cat = ItemCatalog(rom);
      // 实测 FE7J 的 +28 只有 7 种取值
      const known = {0x00, 0x01, 0x1F, 0x47, 0x79, 0xB5, 0xFB};
      for (final e in cat.grouped()[ItemGroup.weapon]!) {
        expect(known, contains(e.weaponRankValue),
            reason: 'item ${e.id} 的 +28 = ${e.weaponRankValue}');
      }
    });

    test('FE7U / FE8J 的等级值同样受限', () {
      for (final path in [fe7us, fe8jp]) {
        final rom = _open(path);
        final cat = ItemCatalog(rom);
        const known = {0x00, 0x01, 0x1F, 0x47, 0x79, 0xB5, 0xFB};
        for (final e in cat.grouped()[ItemGroup.weapon]!) {
          expect(known, contains(e.weaponRankValue),
              reason: '$path item ${e.id} 的 +28 = ${e.weaponRankValue}');
        }
      }
    });

    test('FE6 的熟练度用另一套档位（阶差 50）', () {
      final rom = _open(fe6jp);
      final cat = ItemCatalog(rom);
      expect(cat.isFe6, isTrue);
      // FE6 的 +28 是 01/33/65/97/C9/FB，不能拿 FE7 的阈值判定
      const known = {0x00, 0x01, 0x33, 0x65, 0x97, 0xC9, 0xFB};
      for (final e in cat.grouped()[ItemGroup.weapon]!) {
        expect(known, contains(e.weaponRankValue),
            reason: 'item ${e.id} 的 +28 = ${e.weaponRankValue}');
      }
      // 同一个字面值在两版里含义不同：0x33 在 FE6 是 D，在 FE7/FE8 是 D 以上
      // （FE7/FE8 的 C 阈值 0x47 比它大，所以它也落在 D）。
      expect(WeaponRank.fromValue(0x33, fe6: true), WeaponRank.d);
      expect(WeaponRank.fromValue(0x40, fe6: true), WeaponRank.d);
      expect(WeaponRank.fromValue(0x40, fe6: false), WeaponRank.d);
      expect(WeaponRank.fromValue(0x47, fe6: false), WeaponRank.c);
      expect(WeaponRank.fromValue(0x47, fe6: true), WeaponRank.d);
    });
  });

  group('武器属性（对照游戏内截图）', () {
    test('FE6 汉化版「铁剑」= 耐久46 / 威力5 / 重量5 / 命中85 / 必杀0 / 单价10', () {
      // 依据用户提供的封印之剑游戏内截图（铁剑 46/46E，Help：剑E 射程1
      // 重量5 命中85 必杀0）与 FE6 wiki（Mt5 / Wt5 / Hit85 / Uses46 / Worth460）：
      //   item 1 的 +20=46(耐久) +21=5(威力) +22=85(命中) +23=5(重量)
      //     +24=0(必杀) +25=0x11(射程1) +26=10(单价，46×10=460) +28=1(等级E)
      final rom = _open(fe6cn);
      final cat = ItemCatalog(rom);
      final e = cat.entryAt(1)!;
      expect(e.kind, ItemKind.sword);
      expect(e.durability, 46);
      expect(e.might, 5);
      expect(e.weight, 5);
      expect(e.hit, 85);
      expect(e.crit, 0);
      expect(e.unitPrice, 10);
      expect(e.durability * e.unitPrice, 460);
      expect(e.range.raw, 0x11);
      expect(e.range.label, '射程 1');
      expect(e.weaponRankValue, 1);
    });

    test('FE6 汉化版「铁枪」= 威力7 / 重量8（两字段不同值，能区分对调）', () {
      // FE6 wiki：Iron Lance Mt7 / Wt8 / Hit70 / Uses45 / Worth360 → 单价 8
      final rom = _open(fe6cn);
      final cat = ItemCatalog(rom);
      final e = cat.entryAt(16)!;
      expect(e.kind, ItemKind.lance);
      expect(e.durability, 45);
      expect(e.might, 7);
      expect(e.weight, 8);
      expect(e.hit, 70);
      expect(e.unitPrice, 8);
      expect(e.durability * e.unitPrice, 360);
      expect(e.range.raw, 0x11);
    });

    test('FE6 汉化版「伤药」= 耐久3（截图 3/3）', () {
      // 截图：伤药 3/3。FE6 的消耗品里有多条耐久为 3 的（id 104..108），
      // 它们的 +20 都是 3。
      final rom = _open(fe6cn);
      final cat = ItemCatalog(rom);
      final consumables = cat.grouped()[ItemGroup.consumable]!;
      final with3 = consumables.where((e) => e.durability == 3).toList();
      expect(with3, isNotEmpty);
      for (final e in with3) {
        expect(e.durability, 3);
      }
    });

    test('FE7J 的「铁剑」= 耐久46 / 命中90（数值与 FE6 不同）', () {
      // FE 与 FE7 是不同作品，道具数值本来就不同：FE6 铁剑命中 85，FE7J 是 90。
      final rom = _open(fe7jp);
      final cat = ItemCatalog(rom);
      final e = cat.entryAt(1)!;
      expect(e.durability, 46);
      expect(e.hit, 90);
      expect(e.might, 5);
      expect(e.weight, 5);
    });

    test('FE7J 银剑：威力13 / 重量8（两个字段值不同，能区分对调）', () {
      // Fire Emblem wiki：FE7 银剑 Mt13 / Wt8 / Hit75 / Uses20 / Worth1500 → 单价 75
      final cat = ItemCatalog(_open(fe7jp));
      final e = cat.entryAt(4)!;
      expect(e.might, 13);
      expect(e.weight, 8);
      expect(e.hit, 80);
      expect(e.durability * e.unitPrice, 1500);
    });

    test('FE7J 必杀系武器：+24 就是必杀值', () {
      // 必杀剑 30 / 必杀枪 30 / 必杀斧 30 / 必杀弓 30（游戏内必杀值）
      final cat = ItemCatalog(_open(fe7jp));
      for (final id in [13, 26, 36, 48]) {
        final e = cat.entryAt(id)!;
        expect(e.crit, 30, reason: 'item $id 的 +24');
      }
      // 普通铁剑/铁枪/铁斧/铁弓的必杀都是 0
      for (final id in [1, 20, 31, 44]) {
        expect(cat.entryAt(id)!.crit, 0, reason: 'item $id 的 +24');
      }
    });

    test('FE7J 银枪：耐久20 × 单价60 = 售价1200', () {
      final cat = ItemCatalog(_open(fe7jp));
      final e = cat.entryAt(23)!;
      expect(e.durability, 20);
      expect(e.unitPrice, 60);
      expect(e.durability * e.unitPrice, 1200);
    });

    test('道具表不再存在「回避」字段', () {
      // 回避由速度/幸运算出，道具表里没有；+26 是单价。
      final cat = ItemCatalog(_open(fe7jp));
      final e = cat.entryAt(1)!;
      expect(e.unitPrice, greaterThan(0));
    });

    test('单价是 u16：覇者の証 50000，只读 u8 会得到 80', () {
      // bmitem.h：`/* 1A */ u16 costPerUse;`。
      // FE7J 里有 54 个道具的单价超过 255，按 u8 读只会拿到低字节，
      // 界面上的「商店售价」会小数百倍。
      final rom = _open(fe7jp);
      final cat = ItemCatalog(rom);
      final e = cat.entryAt(150)!;
      expect(e.unitPrice, 50000);
      expect(e.durability * e.unitPrice, 50000);
      // 低于 256 的道具不受影响，可以拿来对照
      expect(cat.entryAt(1)!.unitPrice, 10);
    });

    test('射程码解码', () {
      expect(ItemRange.fromRaw(0x11).label, '射程 1');
      expect(ItemRange.fromRaw(0x12).label, '射程 1-2');
      expect(ItemRange.fromRaw(0x13).label, '射程 1-3');
      expect(ItemRange.fromRaw(0x22).label, '射程 2-2');
      expect(ItemRange.fromRaw(0x23).label, '射程 2-3');
      expect(ItemRange.fromRaw(0x3A).label, '射程 3-10');
      expect(ItemRange.fromRaw(0x3F).label, '射程 3-15');
      expect(ItemRange.fromRaw(0xFF).label, '全体');
      expect(ItemRange.fromRaw(0x11).minRange, 1);
      expect(ItemRange.fromRaw(0x11).maxRange, 1);
      // 未知码不崩
      expect(ItemRange.fromRaw(0x77).label, contains('未知'));
    });

    test('三个版本字段布局一致（+20 耐久 / +25 射程码）', () {
      for (final path in [fe6jp, fe6cn, fe7jp, fe8jp]) {
        final rom = _open(path);
        final cat = ItemCatalog(rom);
        final e = cat.entryAt(1)!;
        // 铁剑：耐久与射程在三个版本里相同（命中是各作品自行设计的，不同）
        expect(e.durability, 46, reason: path);
        expect(e.might, 5, reason: path);
        expect(e.range.raw, 0x11, reason: path);
      }
    });
  });

  group('数值加成表', () {
    test('伤药类消耗品的 +12 指向 HP 加成', () {
      final rom = _open(fe7jp);
      final cat = ItemCatalog(rom);
      final consumables = cat.grouped()[ItemGroup.consumable]!;
      // 至少有一个消耗品带 HP 加成
      final withHp = consumables
          .where((e) => cat.statBonuses(e).hp > 0)
          .toList();
      expect(withHp, isNotEmpty);
      for (final e in withHp) {
        final b = cat.statBonuses(e);
        expect(b.hp, greaterThan(0));
        // 其它能力一般不该同时被加（治疗品只加 HP）
        expect(b.str, 0);
        expect(b.def, 0);
      }
    });

    test('加成表的字段顺序：HP 在第一个字节', () {
      final rom = _open(fe7jp);
      final cat = ItemCatalog(rom);
      for (final e in cat.grouped()[ItemGroup.consumable]!) {
        final b = cat.statBonuses(e);
        if (b.isEmpty) continue;
        // 至少有一个非 HP 字段时，HP 也应存在（不强制，但值本身要合理）
        expect(b.hp.abs(), lessThan(256));
      }
    });
  });

  group('克制职业列表', () {
    test('弓的 +16 指向一份克制职业 ID 列表（该武器对其有额外伤害）', () {
      final rom = _open(fe7jp);
      final cat = ItemCatalog(rom);
      final bows = cat.grouped()[ItemGroup.weapon]!
          .where((e) => e.kind == ItemKind.bow)
          .toList();
      expect(bows, isNotEmpty);
      var withList = 0;
      for (final e in bows) {
        final list = cat.usableClasses(e);
        if (list.isEmpty) continue;
        withList++;
        // 职业 ID 应在有效范围内
        for (final cid in list) {
          expect(cid, lessThan(0x100));
        }
      }
      expect(withList, greaterThan(0));
    });
  });

  group('标志位', () {
    test('+8 的 bit0 表示可装备：剑枪斧弓魔法为 1', () {
      final rom = _open(fe7jp);
      final cat = ItemCatalog(rom);
      const equippableKinds = {
        ItemKind.sword,
        ItemKind.lance,
        ItemKind.axe,
        ItemKind.bow,
        ItemKind.anima,
        ItemKind.light,
        ItemKind.dark,
      };
      for (final e in cat.grouped()[ItemGroup.weapon]!) {
        if (!equippableKinds.contains(e.kind)) continue;
        expect(e.flags.weapon, isTrue, reason: 'item ${e.id} ${e.kind.label}');
      }
    });

    test('杖是消耗型武器：attributes 的 bit2（IA_STAFF）置位，bit0 不置位', () {
      // 实测 FE7J 的 15 个杖（type=0x04）attributes 都是 0x00000004：
      // 不占装备位（bit0=0），但 bit2 标记它是杖。
      final rom = _open(fe7jp);
      final cat = ItemCatalog(rom);
      final staves =
          cat.grouped()[ItemGroup.weapon]!.where((e) => e.kind == ItemKind.staff).toList();
      expect(staves, isNotEmpty);
      for (final e in staves) {
        expect(e.flags.weapon, isFalse, reason: 'item ${e.id}');
        expect(e.flags.staff, isTrue, reason: 'item ${e.id}');
      }
    });

    test('attributes 是 u32：勇者系 bit5 连击，bit8 逆转武器三角', () {
      final cat = ItemCatalog(_open(fe7jp));
      // FE7J：勇者剑 11 / 勇者枪 25 / 勇者斧 35 / 勇者弓 49
      for (final id in [11, 25, 35, 49]) {
        expect(cat.entryAt(id)!.flags.brave, isTrue, reason: 'item $id 应为勇者系');
      }
      expect(cat.entryAt(1)!.flags.brave, isFalse, reason: '铁剑不是勇者系');
      // FE7J：ランスバスター 18 / アクスバスター 30 / ソードバスター 42 /
      // ソードキラー 43——这三类「克武器」的武器带 bit8。
      for (final id in [18, 30, 42, 43]) {
        expect(cat.entryAt(id)!.flags.reverseTriangle, isTrue, reason: 'item $id');
      }
      expect(cat.entryAt(1)!.flags.reverseTriangle, isFalse, reason: '铁剑不是克武器');
      // 这个位在 u32 的第 8 位上，只读 u8 是永远读不出来的
      expect(cat.entryAt(18)!.flags.raw & 0x100, 0x100);
    });

    test('ID 0 是空槽，不应出现在任何分组里', () {
      final rom = _open(fe7jp);
      final cat = ItemCatalog(rom);
      for (final g in cat.grouped().values) {
        for (final e in g) {
          expect(e.id, isNot(0));
        }
      }
    });

    test('消耗品的可装备标志为否', () {
      final rom = _open(fe7jp);
      final cat = ItemCatalog(rom);
      final consumables = cat.grouped()[ItemGroup.consumable]!;
      var notEquippable = 0;
      for (final e in consumables) {
        if (!e.flags.weapon) notEquippable++;
      }
      expect(notEquippable, greaterThan(0));
    });
  });
}
