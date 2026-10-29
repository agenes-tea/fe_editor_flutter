import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/cheat_presets.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/playable_units.dart';
import 'package:fe_editor/core/support.dart';

Uint8List _rom() {
  final dir = Directory('/root/workspace/game-rom');
  final f = dir
      .listSync()
      .whereType<File>()
      .firstWhere((f) => f.path.contains('1692 -'));
  return f.readAsBytesSync();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('全员支援 A：我方每个对象的初始值都写到 A 阈值之上', () {
    final data = _rom();
    final edit = EditableRom.open(data, FeRom.detectTable(data)!);
    final preset = cheatPresets.firstWhere((p) => p.id == 'support_all_a');
    final r = applyCheat(edit, preset);
    expect(r.changedEntries, greaterThan(20));
    expect(r.changedBytes, greaterThan(0));

    // 逐条回读：有支援对象（partner>0）的槽位，初始值必须 >= A 阈值
    final rom = edit.rom;
    final playable = PlayableUnits(rom).indices(criterion: PlayableCriterion.reciprocal);
    var checked = 0;
    for (final i in playable) {
      if (edit.supportAddress(i) < 0) continue;
      for (var slot = 0; slot < SupportTable.maxPartners; slot++) {
        final partner = edit.readSupport(i, slot, SupportPart.partner);
        if (partner <= 0) continue;
        // A 级判据是 > 240（bmreliance.c GetUnitSupportLevel）
        expect(edit.readSupport(i, slot, SupportPart.base), greaterThan(240),
            reason: '角色 $i 槽 $slot 的支援初始值没到 A 的阈值');
        expect(edit.readSupport(i, slot, SupportPart.growth), kSupportGrowthMax);
        checked++;
      }
    }
    expect(checked, greaterThan(50), reason: '应该校验到大量支援槽位');
  });

  test('支援增长拉满：只改增长，不动初始值', () {
    final data = _rom();
    final edit = EditableRom.open(data, FeRom.detectTable(data)!);
    final before = <String, int>{};
    final playable = PlayableUnits(edit.rom)
        .indices(criterion: PlayableCriterion.reciprocal);
    for (final i in playable) {
      for (var slot = 0; slot < SupportTable.maxPartners; slot++) {
        if (edit.readSupport(i, slot, SupportPart.partner) <= 0) continue;
        before['$i/$slot'] = edit.readSupport(i, slot, SupportPart.base);
      }
    }
    applyCheat(edit, cheatPresets.firstWhere((p) => p.id == 'support_growth_max'));
    for (final i in playable) {
      for (var slot = 0; slot < SupportTable.maxPartners; slot++) {
        if (edit.readSupport(i, slot, SupportPart.partner) <= 0) continue;
        expect(edit.readSupport(i, slot, SupportPart.base), before['$i/$slot'],
            reason: '初始值不应被改动');
        expect(edit.readSupport(i, slot, SupportPart.growth), kSupportGrowthMax);
      }
    }
  });

  test('支援预设可整体撤销', () {
    final data = _rom();
    final edit = EditableRom.open(data, FeRom.detectTable(data)!);
    applyCheat(edit, cheatPresets.firstWhere((p) => p.id == 'support_all_a'));
    edit.revertAll();
    expect(edit.data, equals(data));
  });

  test('不误改敌方：非我方角色条目的支援值保持不变', () {
    final data = _rom();
    final edit = EditableRom.open(data, FeRom.detectTable(data)!);
    final rom = edit.rom;
    final playable = PlayableUnits(rom)
        .indices(criterion: PlayableCriterion.reciprocal)
        .toSet();
    final untouched = <String, int>{};
    for (var i = 0; i < rom.unitCount; i++) {
      if (playable.contains(i)) continue;
      for (var slot = 0; slot < SupportTable.maxPartners; slot++) {
        if (edit.readSupport(i, slot, SupportPart.partner) <= 0) continue;
        untouched['$i/$slot'] = edit.readSupport(i, slot, SupportPart.base);
      }
    }
    applyCheat(edit, cheatPresets.firstWhere((p) => p.id == 'support_all_a'));
    untouched.forEach((key, value) {
      final parts = key.split('/').map(int.parse).toList();
      expect(edit.readSupport(parts[0], parts[1], SupportPart.base), value,
          reason: '非我方角色 $key 被误改');
    });
  });

  test('支援 A 的阈值必须真的判成 A（>240），不是 B（>160）', () {
    expect(kSupportLevelAExp, greaterThan(240));
    final data = _rom();
    final edit = EditableRom.open(data, FeRom.detectTable(data)!);
    applyCheat(edit, cheatPresets.firstWhere((p) => p.id == 'support_all_a'));
    final playable = PlayableUnits(edit.rom)
        .indices(criterion: PlayableCriterion.reciprocal);
    for (final i in playable) {
      for (var slot = 0; slot < SupportTable.maxPartners; slot++) {
        if (edit.readSupport(i, slot, SupportPart.partner) <= 0) continue;
        final v = edit.readSupport(i, slot, SupportPart.base);
        expect(v, greaterThan(240), reason: '写入 $v 只会显示 B');
        expect(v, lessThanOrEqualTo(255), reason: '超出 u8');
      }
    }
  });

  test('全员支援 A 的预设文案包含结局提示', () {
    final preset = cheatPresets.firstWhere((p) => p.id == 'support_all_a');
    expect(preset.description.contains('结局'), isTrue);
    expect(preset.target, CheatTarget.support);
  });
}
