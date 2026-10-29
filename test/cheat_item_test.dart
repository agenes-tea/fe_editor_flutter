import 'dart:io';
import 'dart:typed_data';

import 'package:fe_editor/core/cheat_presets.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
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

int _attrsOf(EditableRom edit, int itemIndex) =>
    edit.buffer.u32(edit.itemAddress(itemIndex) + ItemOffsets.attributes);

void main() {
  group('无限耐久 = attributes bit3', () {
    test('原版已有若干无限耐久道具，且耐久字段为 0', () {
      // 反编译依据：GetItemMaxUses 对 IA_UNBREAKABLE 返回 0xFF，实际数据里 dur=0
      for (final keyword in ['0979', '0378', '汉化']) {
        final edit = _open(keyword);
        final rom = edit.rom;
        var unbreakable = 0;
        for (var i = 0; i < rom.itemCount; i++) {
          final at = edit.itemAddress(i);
          final attrs = FeRom.u32(rom.data, at + ItemOffsets.attributes);
          if (attrs & (1 << kItemFlagUnbreakable) != 0) {
            unbreakable++;
            expect(FeRom.u8(rom.data, at + ItemOffsets.durability), 0,
                reason: '$keyword item $i 的无限耐久道具耐久字段应为 0');
          }
        }
        // FE7 有 4 条、FE6 有 4 条、FE8 有 17 条（实测）
        expect(unbreakable, greaterThanOrEqualTo(4),
            reason: '$keyword 原版无限耐久道具数量');
      }
    });

    test('应用「全部道具无限耐久」后每条都置位', () {
      final edit = _open('汉化');
      final preset =
          cheatPresets.firstWhere((p) => p.id == 'item_all_unbreakable');
      final result = applyCheat(edit, preset);
      expect(result.changedEntries, greaterThan(100));

      for (var i = 1; i < edit.rom.itemCount; i++) {
        final attrs = _attrsOf(edit, i);
        expect(attrs & (1 << kItemFlagUnbreakable), isNot(0),
            reason: 'item $i 应已无限耐久');
      }
    });

    test('只改 bit3，其余标志位一律不动', () {
      // 回归：attributes 是 u32，整块覆盖会毁掉 bit8+（逆转三角、无视防御等）
      final edit = _open('0979');
      final preset =
          cheatPresets.firstWhere((p) => p.id == 'item_all_unbreakable');

      final before = <int, int>{};
      for (var i = 0; i < edit.rom.itemCount; i++) {
        before[i] = _attrsOf(edit, i);
      }
      applyCheat(edit, preset);

      for (var i = 1; i < edit.rom.itemCount; i++) {
        final b = before[i]!;
        final a = _attrsOf(edit, i);
        // 除 bit3 外必须完全一致
        expect(a & ~(1 << kItemFlagUnbreakable),
            b & ~(1 << kItemFlagUnbreakable),
            reason: 'item $i 的其它标志位被改坏了：$b -> $a');
        // 原本就是无限耐久的条目不重写（同值不写），所以用「或」判断
        expect((a | b) & (1 << kItemFlagUnbreakable),
            1 << kItemFlagUnbreakable,
            reason: 'item $i 应已无限耐久');
      }
      // item 0 是空槽，按设计跳过（没名字、游戏里也用不到）
      expect(_attrsOf(edit, 0), before[0]);
    });

    test('「仅武器」不动消耗品与转职道具', () {
      final edit = _open('汉化');
      final preset =
          cheatPresets.firstWhere((p) => p.id == 'item_weapon_unbreakable');
      final all = cheatPresets.firstWhere((p) => p.id == 'item_all_unbreakable');

      // 仅武器的条目数应明显少于全部
      expect(cheatEntryCount(preset, edit.rom),
          lessThan(cheatEntryCount(all, edit.rom)));

      final before = <int, int>{};
      for (var i = 0; i < edit.rom.itemCount; i++) {
        before[i] = _attrsOf(edit, i);
      }
      applyCheat(edit, preset);

      for (var i = 0; i < edit.rom.itemCount; i++) {
        final kind = FeRom.u8(
            edit.rom.data, edit.itemAddress(i) + ItemOffsets.kind);
        final attrs = _attrsOf(edit, i);
        final isWeapon = const {0, 1, 2, 3, 5, 6, 7}.contains(kind);
        final hasBit = attrs & (1 << kItemFlagUnbreakable) != 0;
        if (isWeapon && i != 0) {
          expect(hasBit, isTrue, reason: 'item $i (kind=$kind) 是武器应置位');
        } else if (!isWeapon) {
          expect(attrs, before[i], reason: 'item $i (kind=$kind) 不该被改');
        }
      }
    });

    test('重复应用是幂等的', () {
      final edit = _open('汉化');
      final preset =
          cheatPresets.firstWhere((p) => p.id == 'item_all_unbreakable');
      applyCheat(edit, preset);
      final after1 = <int>[
        for (var i = 0; i < edit.rom.itemCount; i++) _attrsOf(edit, i)
      ];
      final second = applyCheat(edit, preset);
      expect(second.changedBytes, 0, reason: '第二次不该再有变化');
      for (var i = 0; i < edit.rom.itemCount; i++) {
        expect(_attrsOf(edit, i), after1[i]);
      }
    });

    test('撤销后恢复原样', () {
      final edit = _open('汉化');
      final before = <int>[
        for (var i = 0; i < edit.rom.itemCount; i++) _attrsOf(edit, i)
      ];
      applyCheat(
          edit, cheatPresets.firstWhere((p) => p.id == 'item_all_unbreakable'));
      expect(edit.hasChanges, isTrue);
      edit.revertAll();
      expect(edit.hasChanges, isFalse);
      for (var i = 0; i < edit.rom.itemCount; i++) {
        expect(_attrsOf(edit, i), before[i]);
      }
    });

    test('五个版本都能应用', () {
      for (final keyword in ['0378', '0979', '1235', '1692 -', '铠甲']) {
        final edit = _open(keyword);
        final preset =
            cheatPresets.firstWhere((p) => p.id == 'item_all_unbreakable');
        final result = applyCheat(edit, preset);
        expect(result.changedEntries, greaterThan(50),
            reason: '$keyword 生效条目数');
      }
    });
  });
}
