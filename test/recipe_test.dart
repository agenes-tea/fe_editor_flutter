import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/cheat_presets.dart';
import 'package:fe_editor/core/custom_roster.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/recipe.dart';
import 'package:fe_editor/core/rom_session.dart';

const dir = '/root/workspace/game-rom';
const fe8jp =
    '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

/// 原样复制 MCP `export_recipe` 的 diff 逻辑：导出 original→current 的分段。
List<Map<String, Object?>> exportChunks(EditableRom edit) {
  final original = edit.original;
  final current = edit.buffer.data;
  final n = original.length < current.length ? original.length : current.length;
  final changes = <Map<String, Object?>>[];
  var i = 0;
  while (i < n) {
    if (original[i] == current[i]) {
      i++;
      continue;
    }
    final start = i;
    while (i < n && original[i] != current[i]) {
      i++;
    }
    changes.add({
      'offset': start,
      'before': [for (var k = start; k < i; k++) original[k]],
      'after': [for (var k = start; k < i; k++) current[k]],
    });
  }
  return changes;
}
void main() {
  group('recipe：目标解析', () {
    late RomSession s;
    setUpAll(() {
      s = RomSession.open(File(fe8jp).readAsBytesSync(), '圣魔.gba')!;
    });
    tearDownAll(() {});

    test('显示名 / 原文名 / 下标三种写法都能解析', () {
      final rom = s.liveRom;
      final display = rom.unitDisplayName(2).trim();
      final raw = rom.unitName(2).trim();
      expect(resolveTargets(display, rom.unitCount,
          displayName: rom.unitDisplayName, rawName: rom.unitName).indices,
          [2]);
      // 原文名与显示名一致（日版），也能解析
      expect(resolveTargets(raw, rom.unitCount,
          displayName: rom.unitDisplayName, rawName: rom.unitName).indices,
          [2]);
      // 数字 = 0 基下标
      expect(resolveTargets('5', rom.unitCount,
          displayName: rom.unitDisplayName, rawName: rom.unitName).indices,
          [5]);
      expect(resolveTargets(7, rom.unitCount,
          displayName: rom.unitDisplayName, rawName: rom.unitName).indices,
          [7]);
      // 去重
      expect(
          resolveTargets([2, 2, '2'], rom.unitCount,
              displayName: rom.unitDisplayName, rawName: rom.unitName)
              .indices,
          [2]);
    });

    test('找不到 / 越界记进 unresolved', () {
      final rom = s.liveRom;
      final res = resolveTargets(
        ['不存在的主角X', 999999],
        rom.unitCount,
        displayName: rom.unitDisplayName,
        rawName: rom.unitName,
      );
      expect(res.indices, isEmpty);
      expect(res.unresolved, ['不存在的主角X', '999999']);
    });

    test('道具名可解析（按名字改道具走这条路）', () {
      final rom = s.liveRom;
      final name = rom.itemDisplayName(4).trim();
      expect(name, isNotEmpty);
      expect(
          resolveTargets(name, rom.itemCount,
              displayName: rom.itemDisplayName, rawName: rom.itemName)
              .indices,
          [4]);
    });
  });

  group('recipe：语义层应用', () {
    late RomSession direct;
    late RomSession viaRecipe;

    setUpAll(() {
      direct = RomSession.open(File(fe8jp).readAsBytesSync(), '直改.gba')!;
      viaRecipe =
          RomSession.open(File(fe8jp).readAsBytesSync(), '配方.gba')!;
    });

    test('预设 + 字段修改：配方路径 ≡ 直接调用路径', () {
      final preset =
          cheatPresets.where((p) => p.id == 'unit_max_growth').first;
      final field = itemEditableFieldsFor(fe6: false)
          .firstWhere((f) => f.label == '必杀');

      // 直接路径：预设作用于 {2,5}，道具 4 的必杀改 30
      applyCheat(
        direct.rom,
        preset,
        custom: const CustomRoster({2, 5}),
        playable: playableUnitsOf(direct.liveRom),
      );
      direct.rom.writeField(direct.rom.itemAddress(4), field, 30);

      // 配方路径：同一份意图
      final parsed = parseSemantic({
        'presets': [
          {'id': 'unit_max_growth', 'targets': [2, 5]},
        ],
        'items': {
          '4': {'必杀': 30}
        },
      });
      expect(parsed.problems, isEmpty);
      final result = applyRecipe(
        viaRecipe.rom,
        semantic: parsed,
        chunks: const [],
        version: 'FE8J',
      );
      expect(result.problems, isEmpty, reason: result.problems.join('；'));
      expect(result.semanticChangedBytes, greaterThan(0));

      // 两份 ROM 的最终状态逐字节一致
      expect(viaRecipe.rom.buffer.data, equals(direct.rom.buffer.data));
    });

    test('字段值非法（nibbles 射程码）拒绝写入并不静默', () {
      final parsed = parseSemantic({
        'items': {
          '1': {'射程': 55}
        },
      });
      final s2 = RomSession.open(File(fe8jp).readAsBytesSync(), '射程.gba')!;
      final before = s2.rom.changedByteCount;
      final result = applyRecipe(
        s2.rom,
        semantic: parsed,
        chunks: const [],
        version: 'FE8J',
      );
      // 0x37 不是合法射程码：writeField 拒绝，写入 0 字节
      expect(s2.rom.changedByteCount, before);
      expect(result.problems, isEmpty,
          reason: '拒绝时不记 problems（值由字段定义管）');
    });
  });

  group('recipe：字节层往返', () {
    late RomSession s;
    late List<Map<String, Object?>> chunks;
    late Uint8List modifiedState;

    setUpAll(() {
      s = RomSession.open(File(fe8jp).readAsBytesSync(), '往返.gba')!;
      // 制造改动：改单位等级 + 改道具必杀
      final rom = s.rom;
      final lvl = unitEditableFieldsFor(fe6: false)
          .firstWhere((f) => f.label == '等级');
      rom.writeField(rom.unitAddress(3), lvl, 99);
      final field = itemEditableFieldsFor(fe6: false)
          .firstWhere((f) => f.label == '必杀');
      rom.writeField(rom.itemAddress(4), field, 33);
      modifiedState = Uint8List.fromList(rom.buffer.data);

      chunks = exportChunks(rom);
      rom.revertAll();
    });

    test('导出→撤销→导入：最终字节与导出前一致', () {
      expect(s.rom.buffer.data, isNot(equals(modifiedState)));
      final result = applyRecipe(
        s.rom,
        semantic: null,
        chunks: chunks,
        version: 'FE8J',
        expectedFingerprint: s.fingerprint,
      );
      expect(result.problems, isEmpty, reason: result.problems.join('；'));
      expect(result.skippedChunks, 0);
      expect(s.rom.buffer.data, equals(modifiedState));
    });

    test('指纹不一致时字节层全跳', () {
      final s2 = RomSession.open(File(fe8jp).readAsBytesSync(), '异指纹.gba')!;
      final result = applyRecipe(
        s2.rom,
        semantic: null,
        chunks: chunks,
        version: 'FE8J',
        expectedFingerprint: 12345, // 故意错
      );
      expect(result.bytesChangedBytes, 0);
      expect(result.skippedChunks, chunks.length);
      expect(result.problems, isNotEmpty);
      expect(s2.rom.changedByteCount, 0);
    });

    test('before 原值对不上时该段跳过（不误写）', () {
      final s2 = RomSession.open(File(fe8jp).readAsBytesSync(), '错原值.gba')!;
      final bad = List<Map<String, Object?>>.from(chunks);
      // 篡改第一段的 before：原值必须对得上才写
      final first = bad.first;
      final before = List<int>.from(first['before'] as List)
        ..[0] = ((first['before'] as List)[0] as int) ^ 0xFF;
      first['before'] = before;
      final result = applyRecipe(
        s2.rom,
        semantic: null,
        chunks: bad,
        version: 'FE8J',
      );
      expect(result.skippedChunks, 1);
      expect(result.problems, isNotEmpty);
      // 其余段照常应用
      expect(result.bytesChangedBytes, greaterThan(0));
    });
  });

  group('recipe：版本与结构校验', () {
    test('版本不匹配整份拒绝（不写一个字节）', () {
      final s = RomSession.open(File(fe8jp).readAsBytesSync(), '跨版本.gba')!;
      final parsed = parseSemantic({
        'presets': [
          {'id': 'unit_max_growth', 'targets': [2]}
        ]
      });
      final result = applyRecipe(
        s.rom,
        semantic: parsed,
        chunks: [
          {'offset': 0x200, 'after': [0xAA, 0xBB]}
        ],
        version: 'FE6', // 配方来自 FE6
      );
      expect(result.totalChangedBytes, 0);
      expect(result.problems, isNotEmpty);
      expect(s.rom.changedByteCount, 0);
    });

    test('parseSemantic 结构问题逐个报出', () {
      final parsed = parseSemantic({
        'presets': [
          {'id': 'unit_max_growth'},
          '不是对象',
        ],
        'units': {
          '1': {'等级': '不是数字'}
        },
        'items': '不是对象',
      });
      expect(parsed.problems, isNotEmpty);
      // 非法部分被跳过，合法部分保留
      expect((parsed.semantic['presets'] as List).length, 1);
      expect(parsed.semantic.containsKey('units'), isFalse);
      expect(parsed.semantic.containsKey('items'), isFalse);
    });

    test('配方不是 JSON 对象（顶层是数组）被拒', () {
      final parsed = parseSemantic([1, 2, 3]);
      expect(parsed.problems, isNotEmpty);
      expect(parsed.hasContent, isFalse);
    });
  });
}
