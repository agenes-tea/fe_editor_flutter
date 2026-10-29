import 'dart:io';
import 'dart:typed_data';

import 'package:fe_editor/core/cheat_presets.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/playable_units.dart';
import 'package:fe_editor/core/rom_info.dart';
import 'package:flutter_test/flutter_test.dart';

Directory get _romDir => Directory('${Platform.environment['HOME']}/workspace/game-rom');

File _romByKeyword(String keyword) {
  for (final f in _romDir.listSync()) {
    if (f is File && f.path.contains(keyword)) return f;
  }
  throw StateError('找不到文件名包含 $keyword 的 ROM');
}

EditableRom _open(String keyword) {
  final data = Uint8List.fromList(_romByKeyword(keyword).readAsBytesSync());
  return EditableRom.open(data, FeRom.detectTable(data)!);
}

void main() {
  group('职业经验分母（classRelativePower）', () {
    test('三个版本的字段都在 +0x1A，原版值以 3 居多', () {
      for (final keyword in ['0979', '0378', '1692 -']) {
        final edit = _open(keyword);
        final rom = edit.rom;
        final addr = edit.classAddress(1) + ClassOffsets.classRelativePower;
        final v = rom.data[addr];
        expect(v, inInclusiveRange(1, 5), reason: '$keyword 职业 1 的经验分母');
      }
    });

    test('应用「三倍经验」后全职业分母为 1', () {
      final edit = _open('1692 -');
      final preset =
          cheatPresets.firstWhere((p) => p.id == 'class_exp_denominator_1');
      final result = applyCheat(edit, preset);
      expect(result.changedEntries, greaterThan(50));

      for (var i = 1; i < edit.rom.classCount; i++) {
        final addr = edit.classAddress(i) + ClassOffsets.classRelativePower;
        expect(edit.buffer.u8(addr), 1, reason: '职业 $i 的经验分母');
      }
      // 撤销恢复
      edit.revertAll();
      final rom = edit.rom;
      expect(rom.data[edit.classAddress(1) + ClassOffsets.classRelativePower],
          3, reason: '撤销后应恢复原版值 3');
    });

    test('五个版本都能应用经验分母预设', () {
      for (final keyword in ['0378', '0979', '1235', '1692 -', '铠甲']) {
        final edit = _open(keyword);
        final preset =
            cheatPresets.firstWhere((p) => p.id == 'class_exp_denominator_1');
        final result = applyCheat(edit, preset);
        expect(result.changedEntries, greaterThan(30), reason: keyword);
      }
    });
  });

  group('成长率 200%', () {
    test('字段上限已放宽到 255，200% 能写入', () {
      final edit = _open('1692 -');
      final preset =
          cheatPresets.firstWhere((p) => p.id == 'unit_growth_200');
      final result = applyCheat(edit, preset);
      expect(result.changedEntries, greaterThan(20));

      final field =
          unitEditableFieldsFor(fe6: false).firstWhere((f) => f.label == 'HP成长');
      expect(field.max, 255, reason: '成长率字段上限应允许 200%');
      final ally = PlayableUnits(edit.rom).indices().first;
      final addr = edit.unitAddress(ally);
      expect(edit.readField(addr, field), 200, reason: '我方角色 HP 成长应写为 200');
      edit.revertAll();
    });

    test('成长率 200% 只作用于我方（默认口径）', () {
      final edit = _open('1692 -');
      final preset =
          cheatPresets.firstWhere((p) => p.id == 'unit_growth_200');
      final pu = PlayableUnits(edit.rom);
      final enemy = pu.ambiguous().first;
      final enemyAddr = edit.unitAddress(enemy);
      final field = unitEditableFieldsFor(fe6: false)
          .firstWhere((f) => f.label == '力量成长');
      final before = edit.readField(enemyAddr, field);

      applyCheat(edit, preset);
      expect(edit.readField(enemyAddr, field), before,
          reason: '敌方不该被成长率预设波及');
    });
  });

  group('我方判定：支援互惠口径', () {
    test('原版三作：互惠口径与「有支援数据」口径命中数一致', () {
      // 互惠性是原版数据的硬约束，两个口径应当完全等价
      for (final keyword in ['0979', '1692 -', '汉化', '1692X']) {
        final rom = _open(keyword).rom;
        final pu = PlayableUnits(rom);
        final byRecip = pu.indices(criterion: PlayableCriterion.reciprocal);
        final bySup = pu.indices(criterion: PlayableCriterion.supportData);
        expect(byRecip.length, bySup.length,
            reason: '$keyword 互惠口径应与宽松口径等价');
      }
    });

    test('supportCount=0 的空支援块不再算我方', () {
      // 「铠甲的呼唤」芬瓦尔德/阿莱西亚：有指针但 supportCount=0
      final edit = _open('铠甲');
      final rom = edit.rom;
      final pu = PlayableUnits(rom);
      final base = rom.unitBase;
      final size = rom.table.unitDataSize;

      var emptyBlock = 0;
      for (var i = 0; i < rom.unitCount; i++) {
        final at = base + i * size;
        final p = FeRom.u32(rom.data, at + UnitOffsets.supportPointer);
        if (p == 0 || !FeRom.isPointer(p, rom.length)) continue;
        final b = FeRom.toOffset(p);
        if (rom.data[b + 0x15] == 0) {
          emptyBlock++;
          expect(pu.hasSupportData(i), isFalse,
              reason: 'index $i 的空支援块不该算有效');
        }
      }
      expect(emptyBlock, 2, reason: '该改版实测有 2 个空支援块');
    });

    test('改版的单向支援对：宽松口径命中、互惠口径排除', () {
      // 「铠甲的呼唤」12 个单向对全部指向 number 191/240：
      // 它们的支援列表里对方没有回指，是改版作者只做了一半的支援
      final edit = _open('铠甲');
      final rom = edit.rom;
      final pu = PlayableUnits(rom);

      final byRecip = pu.indices(criterion: PlayableCriterion.reciprocal).toSet();
      final bySup = pu.indices(criterion: PlayableCriterion.supportData);

      // 应有若干单位被互惠口径排除
      final excluded = bySup.where((i) => !byRecip.contains(i)).toList();
      expect(excluded, isNotEmpty, reason: '单向支援的单位应被互惠口径排除');
      for (final i in excluded) {
        expect(pu.reciprocalCount(i), 0, reason: 'index $i');
      }
    });

    test('默认口径是互惠', () {
      final rom = _open('1692 -').rom;
      final pu = PlayableUnits(rom);
      expect(pu.indices().length,
          pu.indices(criterion: PlayableCriterion.reciprocal).length);
    });

    test('互惠计数与支援列表一致（艾瑞珂 7 个对象全部回指）', () {
      final rom = _open('1692 -').rom;
      final pu = PlayableUnits(rom);
      // 艾瑞珂 index 0，7 个支援对象全部互惠
      expect(pu.supportPartners(0).length, 7);
      expect(pu.reciprocalCount(0), 7);
    });
  });
}
