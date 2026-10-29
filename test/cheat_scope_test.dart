import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/cheat_presets.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/playable_units.dart';
import 'package:fe_editor/core/unit_placement.dart';

/// 修改器的「作用范围」判据。
///
/// 背景：单位表里**没有阵营字段**，阵营写在关卡事件 `UnitDefinition.allegiance`。
/// 直接「全表加满」会把敌方也一起加强，所以要有一套判据把玩家角色挑出来。
const dir = '/root/workspace/game-rom';
const fe6cn = '$dir/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe7us = '$dir/1235 - 火炎之纹章-烈火之剑 Fire Emblem(US)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';
const fe8cn = '$dir/火炎之纹章-圣魔之光石汉化.gba';
const fe8hack = '$dir/1692X 火焰之纹章-圣邪的意志.gba';

FeRom _open(String p) {
  final d = File(p).readAsBytesSync();
  return FeRom(d, FeRom.detectTable(d)!);
}

EditableRom _edit(String p) {
  final d = File(p).readAsBytesSync();
  return EditableRom.open(d, FeRom.detectTable(d)!);
}

void main() {
  group('PlayableUnits 判据', () {
    test('有支援数据的单位数（FE8 三个 ROM 一致为 33）', () {
      for (final p in [fe8jp, fe8cn, fe8hack]) {
        final pu = PlayableUnits(_open(p));
        expect(pu.indices().length, 33, reason: p);
      }
    });

    test('sort_order 口径会多算敌方主要角色', () {
      final pu = PlayableUnits(_open(fe8jp));
      final bySup = pu.indices().length;
      final bySort = pu.indices(criterion: PlayableCriterion.sortOrder).length;
      expect(bySort, greaterThan(bySup),
          reason: 'sort_order 应比支援数据宽');
      // FE8 实测 46 vs 33
      expect(bySort, 46);
      expect(pu.ambiguous().length, bySort - bySup);
    });

    test('差异里应该包含敌方角色的名字', () {
      final rom = _open(fe8jp);
      final pu = PlayableUnits(rom);
      final names =
          pu.ambiguous().map((i) => rom.unitName(i).trim()).toSet();
      // 日版下这些是日文名。它们都是敌方/剧情角色，不该被当成我方。
      // リオン 34 / ヴァルター 38 / オルソン 35 均在 34..43 这段
      expect(names.any((n) => n == 'リオン' || n == 'ヴァルター' || n == 'オルソン'),
          isTrue,
          reason: '差异里应出现敌方角色，实际：$names');
      // 差异应该全部落在 34 之后（前 33 条我方都有支援）
      for (final i in pu.ambiguous()) {
        expect(i, greaterThan(33), reason: 'unit $i 不该在差异里');
      }
    });

    test('我方角色全部有支援数据（索引 0..33 内除占位外）', () {
      final rom = _open(fe8jp);
      final pu = PlayableUnits(rom);
      // 艾瑞珂 / 塞思 / 伊弗列姆 等
      for (final i in [0, 1, 14]) {
        expect(pu.hasSupportData(i), isTrue, reason: 'unit $i');
        expect(pu.isPlayable(i), isTrue, reason: 'unit $i');
      }
      // 占位条目与敌方 NPC 不该算
      for (final i in [26, 44, 58, 61, 62]) {
        expect(pu.hasSupportData(i), isFalse, reason: 'unit $i 不该有支援');
      }
    });

    test('五个版本都能算出合理的我方数量', () {
      for (final p in [fe6cn, fe7jp, fe7us, fe8jp]) {
        final pu = PlayableUnits(_open(p));
        final n = pu.indices().length;
        expect(n, greaterThan(20), reason: '$p 我方角色太少');
        expect(n, lessThan(120), reason: '$p 我方角色太多');
      }
    });
  });

  group('敌方嫌疑名单（写入前拦截）', () {
    // 第 5 层保障：`enemySuspects` 列出目标里「有图鉴排序但无支援数据」的
    // 疑似敌方。我方两口径不会命中这批；手动选了图鉴/全表才会非空。
    test('我方口径（reciprocal/supportData）下嫌疑名单为空', () {
      final edit = _edit(fe8jp);
      final pu = PlayableUnits(edit.rom);
      expect(pu.enemySuspects(pu.indices()), isEmpty,
          reason: 'reciprocal 口径不应带入疑似敌方');
      expect(pu.enemySuspects(pu.indices(criterion: PlayableCriterion.supportData)), isEmpty);
    });

    test('图鉴/全表口径下能点名出疑似敌方', () {
      final edit = _edit(fe8jp);
      final pu = PlayableUnits(edit.rom);
      final sortSuspects =
          pu.enemySuspects(pu.indices(criterion: PlayableCriterion.sortOrder));
      // 敌方主要角色（吉利安姆 / 奥尔斯 / 杰斯特 等）被图鉴口径带入
      expect(sortSuspects, isNotEmpty);
      for (final i in sortSuspects) {
        expect(pu.sortOrderOf(i), isNot(0), reason: '嫌疑必须有图鉴排序');
        expect(pu.hasSupportData(i), isFalse, reason: '嫌疑不应有支援数据');
      }
      // 全表口径包含图鉴口径的嫌疑
      final allSuspects =
          pu.enemySuspects(pu.indices(criterion: PlayableCriterion.all));
      expect(allSuspects, containsAll(sortSuspects));
    });
  });

  group('按出场（含事件动态）判据', () {
    PlayableUnits pu(String p) {
      final rom = _open(p);
      return PlayableUnits(rom,
          deployedNumbers: UnitPlacement.deployedNumbersOf(rom));
    }

    test('圣魔：44 条（静态 42 + 事件多出 2），且不含开场山贼', () {
      final rom = _open(fe8jp);
      final units = pu(fe8jp);
      final dep = units.indices(criterion: PlayableCriterion.deployed);
      final both =
          units.indices(criterion: PlayableCriterion.deployedWithEvents);
      expect(dep.length, 42);
      expect(both.length, 44);
      expect(both.toSet(), containsAll(dep), reason: '必须包含静态出场的人');
      final extra = both.where((i) => !dep.contains(i)).toList();
      expect(extra, [191, 203], reason: '多出的是事件里出场的蓝方剧情兵');
      // 第 0 章那三个山贼（104/128/130）是红方，不能被算进来
      final ev = UnitPlacement.eventUnitNumbersOf(rom);
      for (final n in [104, 128, 130]) {
        expect(ev.contains(n), isFalse, reason: '红方 $n 不算我方');
      }
      expect(ev.contains(1), isTrue, reason: 'エイリーク 在事件里以蓝方出场');
    });

    test('烈火日版：把事件里才出场的我方角色补上（52 → 60）', () {
      final units = pu(fe7jp);
      final dep = units.indices(criterion: PlayableCriterion.deployed);
      final both =
          units.indices(criterion: PlayableCriterion.deployedWithEvents);
      expect(dep.length, 52);
      expect(both.length, 60);
      final added = both.toSet().difference(dep.toSet());
      // 琳篇大部分同伴是事件脚本加载的，静态表里没有
      expect(added, containsAll(<int>[12, 23, 27, 28]));
      // 第 0/1 章的山贼（135/136/138/139）是红方，不能进名单
      final ev = UnitPlacement.eventUnitNumbersOf(_open(fe7jp));
      for (final n in [135, 136, 138, 139]) {
        expect(ev.contains(n), isFalse, reason: '红方 $n 不算我方');
      }
    });

    test('封印：静态红/蓝已覆盖，新口径与「按章节出场」一致', () {
      final units = pu(fe6cn);
      expect(
          units
              .indices(criterion: PlayableCriterion.deployedWithEvents)
              .length,
          units.indices(criterion: PlayableCriterion.deployed).length);
    });

    test('新口径下不会把可操控角色点成「敌方嫌疑」', () {
      final units = pu(fe7us);
      final targets =
          units.indices(criterion: PlayableCriterion.deployedWithEvents);
      // 旧写法会把琳/威尔/肯特这批「有图鉴排序、没支援数据」的人点名成敌方
      expect(units.enemySuspects(targets), isEmpty);
      // 图鉴口径下仍然能点出真正的敌方角色
      final sortTargets =
          units.indices(criterion: PlayableCriterion.sortOrder);
      expect(units.enemySuspects(sortTargets), isNotEmpty);
    });

    test('事件名单按 ROM 指纹缓存（重复调用不重扫）', () {
      final rom = _open(fe8jp);
      final a = UnitPlacement.eventUnitNumbersOf(rom);
      final b = UnitPlacement.eventUnitNumbersOf(rom);
      expect(identical(a, b), isTrue);
    });
  });

  group('修改器作用范围', () {
    test('默认口径只改我方，敌方数值不变', () {
      final edit = _edit(fe8jp);
      final preset = cheatPresets.firstWhere((p) => p.id == 'unit_max_growth');
      final pu = PlayableUnits(edit.rom);

      // 找一个敌方角色（有 sort_order 但无支援）
      final enemy = pu.ambiguous().first;
      final enemyAddr = edit.unitAddress(enemy);
      final growField = unitEditableFields.firstWhere((f) => f.label == 'HP成长');
      final enemyBefore = edit.readField(enemyAddr, growField);

      applyCheat(edit, preset);
      expect(edit.readField(enemyAddr, growField), enemyBefore,
          reason: '敌方 unit $enemy 的成长率不该被改');

      // 我方应该被改了
      final allyAddr = edit.unitAddress(0);
      expect(edit.readField(allyAddr, growField), 100);
    });

    test('选「全表」时敌方也会被改（用户明确选择）', () {
      final edit = _edit(fe8jp);
      final preset = cheatPresets.firstWhere((p) => p.id == 'unit_max_growth');
      final pu = PlayableUnits(edit.rom);
      final enemy = pu.ambiguous().first;
      final enemyAddr = edit.unitAddress(enemy);
      final growField = unitEditableFields.firstWhere((f) => f.label == 'HP成长');

      applyCheat(edit, preset, criterion: PlayableCriterion.all);
      expect(edit.readField(enemyAddr, growField), 100,
          reason: '全表口径下敌方也应被改');
    });

    test('作用条目数与 cheatEntryCount 一致', () {
      final edit = _edit(fe8jp);
      final preset = cheatPresets.firstWhere((p) => p.id == 'unit_max_growth');
      expect(
        cheatEntryCount(preset, edit.rom),
        PlayableUnits(edit.rom).indices().length,
      );
      expect(
        cheatEntryCount(preset, edit.rom, criterion: PlayableCriterion.all),
        edit.rom.unitCount,
      );
    });

    test('只改我方时不会碰到占位条目', () {
      final edit = _edit(fe8jp);
      final preset = cheatPresets.firstWhere((p) => p.id == 'unit_max_growth');
      // 占位条目（対戦相手）的等级是 0，改完后仍应为 0
      final lvField = unitEditableFields.firstWhere((f) => f.label == '等级');
      final placeholder = edit.unitAddress(44);
      final before = edit.readField(placeholder, lvField);
      applyCheat(edit, preset);
      expect(edit.readField(placeholder, lvField), before);
    });

    test('职业类预设不受口径影响', () {
      final edit = _edit(fe8jp);
      final classPreset = CheatPreset(
        id: 'test_class',
        title: 't',
        description: 'd',
        target: CheatTarget.classTable,
        values: {'移动力': 9},
        scopeSelectable: false,
      );
      final a = cheatEntryCount(classPreset, edit.rom);
      final b = cheatEntryCount(classPreset, edit.rom,
          criterion: PlayableCriterion.all);
      expect(a, b, reason: '职业表没有阵营概念，口径不该影响它');
      expect(a, edit.rom.classCount);
    });

    test('每个 unit 类预设都允许选口径', () {
      for (final p in cheatPresets.where((p) => p.target == CheatTarget.unit)) {
        expect(p.scopeSelectable, isTrue, reason: p.id);
      }
    });
  });

  group('「按章节出场」判据（改版主线主角没支援数据时用）', () {
    // 背景：TLP v1.5 的主角辛格弗雷德（pid 3）可操控，但作者没给他配支援对话
    // （`+0x2C` 与支援数都是 0），按「支援互惠」判据会漏掉他，
    // 于是「成长率拉满」这类预设对主角无效。
    const tlp =
        '$dir/The Last Promise v1.5汉化版.gba';

    test('TLP 主角有出场记录但没支援数据，deployed 能把他算进来', () {
      final rom = _open(tlp);
      final pu = playableUnitsOf(rom);
      final recip = pu.indices();
      final deployed = pu.indices(criterion: PlayableCriterion.deployed);

      // pid 3 = 表内索引 2 = 辛格弗雷德
      final idx = 2;
      expect(rom.unitName(idx).trim(), isNotEmpty);
      expect(recip, isNot(contains(idx)), reason: '支援判据漏掉主角（这正是要修的）');
      expect(deployed, contains(idx), reason: '出场判据必须包含主角');
      expect(deployed.length, greaterThan(recip.length));
    });

    test('deployed 判据不把对战/试炼塔章当成剧情出场', () {
      // FE8J 的对战章（debug_name 以 T 开头）、试炼塔章（R）、
      // 以及表尾之后的脏条目里，「我方」是对战对手，不是剧情角色。
      // 早期实现会把它们收进名单（实测多出 27 条，包括大量「対戦相手」）。
      // 注意：对战章里也会出现正篇角色（赛斯/艾瑞珂），所以不能逐个断言，
      // 只能断言「专属对战对手」不在名单里。
      final rom = _open(fe8jp);
      final up = UnitPlacement(_edit(fe8jp));
      final deployed = up.deployedUnitNumbers();
      final names = deployed
          .map((n) => rom.unitDisplayName(n - 1).trim())
          .toList();
      final oppCount = names.where((n) => n == '対戦相手').length;
      expect(oppCount, lessThan(3), reason: '对战对手共 100 条，不应被当剧情角色');
      expect(deployed.length, lessThan(90));
      expect(rom.unitCount, greaterThan(deployed.length));
    });

    test('原版四作上 deployed 覆盖住支援判据（不丢人）', () {
      for (final p in [fe7jp, fe7us, fe8jp]) {
        final rom = _open(p);
        final pu = playableUnitsOf(rom);
        final recip = pu.indices().toSet();
        final deployed =
            pu.indices(criterion: PlayableCriterion.deployed).toSet();
        expect(deployed.containsAll(recip), isTrue, reason: p);
      }
    });
  });
}
