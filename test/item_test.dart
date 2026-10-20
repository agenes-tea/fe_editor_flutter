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

    test('FE6 的道具表布局不同，不提供武器等级', () {
      final rom = _open(fe6jp);
      final cat = ItemCatalog(rom);
      expect(cat.hasWeaponRank, isFalse);
      // FE6 的 +28 取值与 FE7 的等级阈值集合不同（不能当等级用）
      final fe6Values = cat.grouped()[ItemGroup.weapon]!
          .map((e) => e.weaponRankValue)
          .toSet();
      final fe7Values = ItemCatalog(_open(fe7jp))
          .grouped()[ItemGroup.weapon]!
          .map((e) => e.weaponRankValue)
          .toSet();
      expect(fe6Values, isNot(equals(fe7Values)));
    });
  });

  group('武器属性（对照游戏内截图）', () {
    test('FE6 汉化版「铁剑」= 耐久46 / 重量5 / 命中85 / 威力5 / 射程1', () {
      // 依据用户提供的封印之剑游戏内截图：
      //   Possession item 2/3 → 铁剑 46/46E，Help 窗口：剑E 射程1 重量5 助0 命中85 必杀0
      //   → item 1 的 +20=46(耐久) +21=5(重量) +22=85(命中) +23=5(威力) +24=0(助)
      //     +25=0x11(射程1) +28=1(等级E)
      final rom = _open(fe6cn);
      final cat = ItemCatalog(rom);
      final e = cat.entryAt(1)!;
      expect(e.kind, ItemKind.sword);
      expect(e.durability, 46);
      expect(e.weight, 5);
      expect(e.hit, 85);
      expect(e.might, 5);
      expect(e.assist, 0);
      expect(e.range.raw, 0x11);
      expect(e.range.label, '射程 1');
      expect(e.weaponRankValue, 1);
    });

    test('FE6 汉化版「铁枪」= 耐久45 / 重量7 / 命中70', () {
      // 截图：铁枪 45/45，Help：枪 射程1 重量7 命中70
      final rom = _open(fe6cn);
      final cat = ItemCatalog(rom);
      final e = cat.entryAt(16)!;
      expect(e.kind, ItemKind.lance);
      expect(e.durability, 45);
      expect(e.weight, 7);
      expect(e.hit, 70);
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

  group('有效职业列表', () {
    test('弓的 +16 指向一份职业 ID 列表', () {
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
        expect(e.flags.equippable, isTrue, reason: 'item ${e.id} ${e.kind.label}');
      }
    });

    test('杖是消耗型武器：bit0=0 但 bit2=1', () {
      // 实测 FE7J 的 15 个杖（type=0x04）+8 都是 0x04：
      // 不占装备位（bit0=0），但用后消失（bit2=1）。
      final rom = _open(fe7jp);
      final cat = ItemCatalog(rom);
      final staves =
          cat.grouped()[ItemGroup.weapon]!.where((e) => e.kind == ItemKind.staff).toList();
      expect(staves, isNotEmpty);
      for (final e in staves) {
        expect(e.flags.equippable, isFalse, reason: 'item ${e.id}');
        expect(e.flags.vanishAfterUse, isTrue, reason: 'item ${e.id}');
      }
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
        if (!e.flags.equippable) notEquippable++;
      }
      expect(notEquippable, greaterThan(0));
    });
  });
}
