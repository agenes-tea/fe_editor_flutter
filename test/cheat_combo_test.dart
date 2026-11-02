import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/cheat_presets.dart';
import 'package:fe_editor/core/custom_roster.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/item_catalog.dart';
import 'package:fe_editor/core/playable_units.dart';
import 'package:fe_editor/core/rom_session.dart';

/// 组合预设（CheatPreset.combo）测试：
/// 「单角色全套强化」= 成长率拉满 + 熟练度 S + 职业上限 50 + 三倍经验，
/// 用自定义名单勾一个角色时，角色字段只改那一个、职业表改全表。
const dir = '/root/workspace/game-rom';
const fe7jp =
    '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';

int _read(EditableRom edit, int baseAddr, String label, {bool fe6 = false}) {
  final fields =
      label.contains('上限') || label.contains('分母')
          ? classEditableFieldsFor(fe6: fe6)
          : unitEditableFieldsFor(fe6: fe6);
  final f = fields.where((x) => x.label == label).first;
  return edit.readField(baseAddr, f);
}

void main() {
  late RomSession s;
  late EditableRom edit;

  setUpAll(() {
    s = RomSession.open(File(fe7jp).readAsBytesSync(), 'fe7.gba')!;
    edit = s.rom;
  });

  final preset =
      cheatPresets.firstWhere((p) => p.id == 'unit_full_suite');

  test('combo 预设按序应用子项，角色字段只改名单内 1 人', () {
    expect(preset.combo, isNotEmpty);
    final unit1 = edit.unitAddress(1);
    final unit2 = edit.unitAddress(2);
    final beforeGrow1 = _read(edit, unit1, 'HP成长');
    final beforeGrow2 = _read(edit, unit2, 'HP成长');
    final class0 = edit.classAddress(0);
    final beforeExp = _read(edit, class0, '经验分母');
    final beforeCap = _read(edit, class0, '力量上限');

    final r = applyCheat(
      edit,
      preset,
      criterion: PlayableCriterion.custom,
      custom: CustomRoster({1}),
    );
    expect(r.skipped, isEmpty, reason: r.skipped.join('；'));
    expect(r.changedEntries, greaterThan(0));

    // 名单内角色 1：成长 100、剑熟练度 S（FE7 阈值 0xFB）
    expect(_read(edit, unit1, 'HP成长'), 100);
    expect(_read(edit, unit1, '剑熟练度'),
        WeaponRank.s.valueFor(fe6: false));
    // 名单外角色 2 不受角色字段影响
    expect(_read(edit, unit2, 'HP成长'), beforeGrow2);

    // 职业表（全表）：经验分母 1、力量上限 50
    expect(_read(edit, class0, '经验分母'), 1);
    expect(_read(edit, class0, '力量上限'), 50);

    edit.revertAll();
    expect(_read(edit, unit1, 'HP成长'), beforeGrow1);
    expect(_read(edit, class0, '经验分母'), beforeExp);
    expect(_read(edit, class0, '力量上限'), beforeCap);
  });

  test('组合项 id 不存在时记入 skipped，不影响其它子项', () {
    final fake = CheatPreset(
      id: 'x',
      title: 'x',
      description: '',
      target: CheatTarget.unit,
      values: {},
      combo: ['no_such_preset', 'unit_max_growth'],
    );
    final r = applyCheat(
      edit,
      fake,
      criterion: PlayableCriterion.custom,
      custom: CustomRoster({1}),
    );
    expect(r.skipped, contains('组合项「no_such_preset」不存在'));
    expect(r.changedEntries, greaterThan(0),
        reason: '合法子项仍然应用');
    edit.revertAll();
  });

  test('cheatEntryCount：组合取子项最大值（职业全表）', () {
    final n = cheatEntryCount(
      preset,
      s.liveRom,
      criterion: PlayableCriterion.custom,
      custom: CustomRoster({1}),
    );
    expect(n, s.liveRom.classCount,
        reason: '角色侧 1 条 < 职业表全表，预览数取最大');
  });
}
