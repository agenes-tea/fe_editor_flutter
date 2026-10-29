import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/cheat_presets.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/item_catalog.dart';
import 'package:fe_editor/core/playable_units.dart';

const dir = '/root/workspace/game-rom';
const fe6cn = '$dir/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe7us = '$dir/1235 - 火炎之纹章-烈火之剑 Fire Emblem(US)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';
const fe8cn = '$dir/火炎之纹章-圣魔之光石汉化.gba';

EditableRom _edit(String path) {
  final d = File(path).readAsBytesSync();
  return EditableRom.open(d, FeRom.detectTable(d)!);
}

EditField _field(List<EditField> fields, String label) =>
    fields.firstWhere((f) => f.label == label);

void main() {
  final paths = {
    'FE6': fe6cn,
    'FE7J': fe7jp,
    'FE7U': fe7us,
    'FE8J': fe8jp,
    'FE8CN': fe8cn,
  };

  group('预设定义', () {
    test('每个预设引用的字段都真实存在', () {
      for (final preset in cheatPresets) {
        // 道具预设定的是 attributes 的标志位、支援预设走 SupportData，
        // 两者都不靠数值字段
        if (preset.target == CheatTarget.item ||
            preset.target == CheatTarget.support ||
            preset.target == CheatTarget.battleRule) {
          continue;
        }
        final fields = switch (preset.target) {
          CheatTarget.unit => unitEditableFieldsFor(fe6: false),
          CheatTarget.classTable => classEditableFieldsFor(fe6: false),
          CheatTarget.item => const <EditField>[],
          CheatTarget.support => const <EditField>[],
          CheatTarget.battleRule => const <EditField>[],
        };
        final labels = fields.map((f) => f.label).toSet();
        // 熟练度预设的值是运行时解析的，单独检查
        final values = preset.id == 'unit_max_weapon_rank'
            ? resolveValues(preset, fe6: false)
            : preset.values;
        expect(values, isNotEmpty, reason: preset.id);
        for (final label in values.keys) {
          expect(labels, contains(label), reason: '${preset.id} 的字段 $label');
        }
      }
    });

    test('熟练度预设按版本取不同档位', () {
      expect(maxRankValue(fe6: false), 0xFB);
      expect(maxRankValue(fe6: true), 0xFB);
      // 8 项都覆盖到
      final v = resolveValues(
        cheatPresets.firstWhere((p) => p.id == 'unit_max_weapon_rank'),
        fe6: false,
      );
      expect(v.length, WeaponType.values.length);
      for (final value in v.values) {
        expect(value, 0xFB);
      }
    });
  });

  group('批量应用', () {
    // 「我方角色满级」预设已移除（满级实机无用），
    // 此处直接内联构造一个「等级→20」的 unit 预设，保留「只改我方」的行为验证。
    final levelPreset = CheatPreset(
      id: 'test_level_20',
      title: 't',
      description: '',
      target: CheatTarget.unit,
      values: {'等级': 20},
    );

    test('我方角色满级：只改我方，敌方与占位不变', () {
      final edit = _edit(fe7jp);
      final preset = levelPreset;
      final result = applyCheat(edit, preset);

      expect(result.skipped, isEmpty);
      final fields = unitEditableFieldsFor(fe6: false);
      final lv = _field(fields, '等级');
      final pu = PlayableUnits(edit.rom);
      final allies = pu.indices();
      expect(allies.length, greaterThan(20), reason: '我方角色数量');
      // 我方全部变 20
      for (final i in allies) {
        expect(edit.readField(edit.unitAddress(i), lv), 20,
            reason: '我方 unit $i');
      }
      // 敌方保持不变（按字节比对，不按值——那个敌方等级本来就是 20）
      for (final i in pu.ambiguous()) {
        final addr = edit.unitAddress(i) + lv.offset;
        expect(edit.data[addr], edit.original[addr],
            reason: '敌方 unit $i 的等级字节不应被改动');
      }
      // 改变的条目数应等于我方数量
      expect(result.changedEntries, lessThanOrEqualTo(allies.length));
    });

    test('选全表口径时所有条目都被改（旧行为可用）', () {
      final edit = _edit(fe7jp);
      final preset = levelPreset;
      applyCheat(edit, preset, criterion: PlayableCriterion.all);
      final lv = _field(unitEditableFieldsFor(fe6: false), '等级');
      for (var i = 0; i < edit.rom.unitCount; i++) {
        expect(edit.readField(edit.unitAddress(i), lv), 20,
            reason: 'unit $i');
      }
    });

    test('成长率拉满：我方角色 7 项都变 100', () {
      final edit = _edit(fe7jp);
      final preset =
          cheatPresets.firstWhere((p) => p.id == 'unit_max_growth');
      applyCheat(edit, preset);

      final fields = unitEditableFieldsFor(fe6: false);
      const labels = ['HP成长', '力量成长', '技巧成长', '速度成长', '防御成长', '魔防成长', '幸运成长'];
      final allies = PlayableUnits(edit.rom).indices();
      for (final i in allies) {
        for (final l in labels) {
          expect(edit.readField(edit.unitAddress(i), _field(fields, l)), 100,
              reason: '我方 unit $i $l');
        }
      }
      // 前 20 条里确实存在非我方条目（FE7 是 2/9/11/12），它们不该被改
      final nonAlly = [for (var i = 0; i < 20; i++) if (!allies.contains(i)) i];
      expect(nonAlly, isNotEmpty, reason: 'FE7J 前 20 条应有非我方条目');
    });

    test('属性强化：我方角色 8 项属性都为 20', () {
      final edit = _edit(fe8jp);
      final preset =
          cheatPresets.firstWhere((p) => p.id == 'unit_strong_stats');
      applyCheat(edit, preset);

      final fields = unitEditableFieldsFor(fe6: false);
      const labels = ['HP', '力量', '技巧', '速度', '防御', '魔防', '幸运', '体格'];
      for (final i in PlayableUnits(edit.rom).indices()) {
        for (final l in labels) {
          expect(edit.readField(edit.unitAddress(i), _field(fields, l)), 20,
              reason: '我方 unit $i $l');
        }
      }
    });

    test('熟练度 S：8 项都落在 S 档位', () {
      for (final entry in {'FE7J': fe7jp, 'FE6': fe6cn}.entries) {
        final edit = _edit(entry.value);
        final fe6 = edit.rom.isFe6;
        final preset = cheatPresets
            .firstWhere((p) => p.id == 'unit_max_weapon_rank');
        applyCheat(edit, preset);

        final fields = unitEditableFieldsFor(fe6: fe6);
        for (final i in PlayableUnits(edit.rom).indices()) {
          for (var k = 0; k < WeaponType.values.length; k++) {
            final f = fields.firstWhere(
                (x) => x.label == '${WeaponType.values[k].label}熟练度');
            final v = edit.readField(edit.unitAddress(i), f);
            expect(WeaponRank.fromValue(v, fe6: fe6), WeaponRank.s,
                reason: '${entry.key} 我方 unit $i 第$k项 = $v');
          }
        }
      }
    });
  });

  group('可逆性与幂等', () {
    test('所有预设应用后 revertAll 与原始 ROM 逐字节一致', () {
      for (final preset in cheatPresets) {
        final original = File(fe7jp).readAsBytesSync();
        final edit = EditableRom.open(original, FeRom.detectTable(original)!);
        applyCheat(edit, preset);
        expect(edit.hasChanges, isTrue, reason: preset.id);

        edit.revertAll();
        expect(edit.hasChanges, isFalse, reason: preset.id);
        expect(edit.buildOutput(), equals(Uint8List.fromList(original)),
            reason: '${preset.id} 撤销后应与原始 ROM 完全一致');
      }
    });

    test('重复应用同一预设不产生新改动（幂等）', () {
      final edit = _edit(fe7jp);
      final preset =
          cheatPresets.firstWhere((p) => p.id == 'unit_max_growth');
      final first = applyCheat(edit, preset);
      expect(first.changedBytes, greaterThan(0));

      final second = applyCheat(edit, preset);
      expect(second.changedEntries, 0, reason: '第二次不应再改任何条目');
      expect(second.changedBytes, 0);
      // 总改动量不变
      expect(edit.changedByteCount, first.changedBytes);
    });

    test('连续应用多个预设，撤销后仍然完全还原', () {
      final original = File(fe7jp).readAsBytesSync();
      final edit = EditableRom.open(original, FeRom.detectTable(original)!);
      for (final preset in cheatPresets) {
        applyCheat(edit, preset);
      }
      edit.revertAll();
      expect(edit.buildOutput(), equals(Uint8List.fromList(original)));
    });
  });

  group('边界', () {
    test('值被夹紧到字段允许范围', () {
      final edit = _edit(fe7jp);
      // 构造一个超范围的临时预设：成长率设 200 应被夹到 100
      const over = CheatPreset(
        id: 'test_over',
        title: 't',
        description: 't',
        target: CheatTarget.unit,
        values: {'HP成长': 300},
      );
      applyCheat(edit, over);
      final f = _field(unitEditableFieldsFor(fe6: false), 'HP成长');
      // 成长率上限已放宽到 255（支持 200% 预设），300 被夹到 255
      expect(edit.readField(edit.unitAddress(0), f), 255);
    });

    test('找不到字段时记进 skipped 而不是静默跳过', () {
      final edit = _edit(fe7jp);
      const bogus = CheatPreset(
        id: 'test_bogus',
        title: 't',
        description: 't',
        target: CheatTarget.unit,
        values: {'不存在的字段': 1},
      );
      final r = applyCheat(edit, bogus);
      expect(r.skipped, isNotEmpty);
      expect(r.changedBytes, 0);
    });

    test('5 个版本 ROM 都能跑通所有预设', () {
      for (final entry in paths.entries) {
        final edit = _edit(entry.value);
        for (final preset in cheatPresets) {
          final r = applyCheat(edit, preset);
          expect(r.skipped, isEmpty,
              reason: '${entry.key} / ${preset.id} 有字段没匹配上');
        }
        edit.revertAll();
        expect(edit.hasChanges, isFalse, reason: entry.key);
      }
    });

    test('修改器不碰文本区：应用后角色名不变', () {
      final edit = _edit(fe7jp);
      final before = <String>[
        for (var i = 0; i < 5; i++) edit.rom.unitName(i),
      ];
      for (final preset in cheatPresets) {
        applyCheat(edit, preset);
      }
      final rom2 = FeRom(Uint8List.fromList(edit.buildOutput()), edit.rom.table);
      final after = <String>[for (var i = 0; i < 5; i++) rom2.unitName(i)];
      expect(after, before);
    });
  });
}
