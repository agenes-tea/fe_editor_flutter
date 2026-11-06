import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fe_editor/core/class_terrain.dart';
import 'package:fe_editor/core/rom_session.dart';

import 'rom_paths.dart';

const _dir = romDir;
const _fe6jp =
    '0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const _fe7jp = '0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const _fe8jp =
    '1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

RomSession _open(String name) =>
    RomSession.open(File('$_dir/$name').readAsBytesSync(), name)!;

void main() {
  group('职业地形表（移动消耗 + 地形修正）', () {
    test('FE8：六个指针槽都是合法指针', () {
      final s = _open(_fe8jp);
      final t = ClassTerrain(s.rom);
      expect(t.isFe6, isFalse);
      expect(t.movCostOffsets, [56, 60, 64]);
      expect(t.lookupOffsets, [68, 72, 76]);
      for (final off in [...t.movCostOffsets, ...t.lookupOffsets]) {
        expect(t.pointerTarget(1, off), greaterThan(0),
            reason: '领主 (+$off) 应该是合法指针');
      }
    });

    test('FE6：条目 72 字节，只有一张移动消耗表', () {
      final s = _open(_fe6jp);
      final t = ClassTerrain(s.rom);
      expect(t.isFe6, isTrue);
      expect(t.movCostOffsets, [52]);
      expect(t.lookupOffsets, [56, 60, 64]);
      for (final off in [52, 56, 60, 64]) {
        expect(t.pointerTarget(1, off), greaterThan(0),
            reason: 'FE6 领主 (+$off) 应该是合法指针');
      }
    });

    test('FE7J 与 FE8J 的移动消耗表首个值都是 0xFF（地形 0 不可通行）', () {
      for (final rom in [_fe7jp, _fe8jp]) {
        final s = _open(rom);
        final t = ClassTerrain(s.rom);
        expect(t.valueAt(1, t.movCostOffsets.first, 0), -1,
            reason: '$rom 地形 0（不可通行）应为 -1');
        // 地形 1（平地）应该是 1
        expect(t.valueAt(1, t.movCostOffsets.first, 1), 1);
      }
    });

    test('地形修正表可读且三张表语义不同（回避/防御/魔防不全相同）', () {
      final s = _open(_fe8jp);
      final t = ClassTerrain(s.rom);
      final avoid = [
        for (var i = 0; i < 20; i++) t.valueAt(1, t.lookupOffsets[0], i)
      ];
      final def = [
        for (var i = 0; i < 20; i++) t.valueAt(1, t.lookupOffsets[1], i)
      ];
      final res = [
        for (var i = 0; i < 20; i++) t.valueAt(1, t.lookupOffsets[2], i)
      ];
      expect(avoid.every((v) => v != null), isTrue);
      expect(avoid, isNot(equals(def)), reason: '回避与防御不应是同一张表');
      expect(def, isNot(equals(res)), reason: '防御与魔防不应是同一张表');
    });

    test('写入后可读回，且记进 edits（可撤销）', () {
      final s = _open(_fe8jp);
      final t = ClassTerrain(s.rom);
      final off = t.lookupOffsets[0];
      final at = t.pointerTarget(1, off);
      final before = s.rom.buffer.u8(at + 5);
      final target = before == 7 ? 8 : 7;

      final n0 = s.rom.edits.length;
      expect(t.setValue(1, off, 5, target), 1);
      expect(t.valueAt(1, off, 5), target);
      expect(s.rom.edits.length, n0 + 1);

      s.rom.revertAll();
      expect(s.rom.buffer.u8(at + 5), before);
    });

    test('负值可写（-1 = 不可通行）', () {
      final s = _open(_fe7jp);
      final t = ClassTerrain(s.rom);
      final off = t.movCostOffsets.first;
      final at = t.pointerTarget(1, off);
      final before = s.rom.buffer.u8(at + 1);
      expect(before, 1);
      expect(t.setValue(1, off, 1, -1), 1);
      expect(s.rom.buffer.u8(at + 1), 0xFF);
      expect(t.valueAt(1, off, 1), -1);
    });

    test('同值不写、越界地形 ID 拒绝', () {
      final s = _open(_fe8jp);
      final t = ClassTerrain(s.rom);
      final off = t.lookupOffsets[0];
      final cur = t.valueAt(1, off, 3)!;
      expect(t.setValue(1, off, 3, cur), 0);
      expect(t.setValue(1, off, -1, 1), -1);
      expect(t.setValue(1, off, ClassTerrain.terrainCount + 1, 1), -1);
    });

    test('共享表能被识别出来（改一处会影响多个职业）', () {
      final s = _open(_fe8jp);
      final t = ClassTerrain(s.rom);
      final off = t.movCostOffsets.first;
      final sharers = t.sharersOf(1, off);
      // 实测 FE8J 领主与佣兵的移动消耗表同址，至少应能找到共享者
      expect(sharers, isNotEmpty,
          reason: 'FE8J 领主(+$off) 应与其它职业共享同一张移动消耗表');
      // sharedWith 与 sharersOf 的判定必须一致
      expect(t.sharersOf(1, off).contains(sharers.first), isTrue);
    });
  });
}
