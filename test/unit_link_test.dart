import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/portrait.dart';
import 'package:fe_editor/core/zh_table.dart';
import 'package:fe_editor/core/zh_tables_data.dart';
import 'package:fe_editor/ui/unit_page.dart';

const dir = '/root/workspace/game-rom';
const fe6cn = '$dir/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

FeRom _open(String p) {
  final d = File(p).readAsBytesSync();
  return FeRom(d, FeRom.detectTable(d)!);
}

void main() {
  group('角色 → 职业 / 肖像 关联', () {
    test('FE7J 艾利乌德：职业 1「ロード」，肖像 2', () {
      final rom = _open(fe7jp);
      expect(rom.unitName(0), 'エリウッド');
      final cid = unitClassId(rom, 0);
      expect(cid, 1);
      expect(rom.className(cid), 'ロード');
      expect(portraitFaceOf(rom, 0), 2);

      final reader = PortraitReader(rom);
      expect(reader.faceToPortraitId(2), 2);
      expect(reader.nameFor(2), 'エリウッド');
      reader.dispose();
    });

    test('FE8J 泽特：职业「パラディン」，肖像 4', () {
      final rom = _open(fe8jp);
      expect(rom.unitName(1), 'ゼト');
      final cid = unitClassId(rom, 1);
      expect(rom.className(cid), 'パラディン');
      expect(portraitFaceOf(rom, 1), 4);
    });

    test('每个单位的职业 ID 都落在职业表范围内', () {
      for (final p in [fe7jp, fe8jp, fe6cn]) {
        final rom = _open(p);
        for (var i = 0; i < rom.unitCount; i++) {
          final cid = unitClassId(rom, i);
          expect(cid, greaterThanOrEqualTo(0), reason: '$p unit $i');
          expect(cid, lessThan(rom.classCount),
              reason: '$p unit $i 职业 ID $cid 超出 ${rom.classCount}');
        }
      }
    });

    test('Face → 肖像索引在 FE7/FE8 是恒等映射', () {
      final reader = PortraitReader(_open(fe7jp));
      for (var face = 2; face < 40; face++) {
        final id = reader.faceToPortraitId(face);
        if (id != null) expect(id, face);
      }
      reader.dispose();
    });

    test('无法映射的 face 返回 null 而不是越界', () {
      final reader = PortraitReader(_open(fe7jp));
      expect(reader.faceToPortraitId(-1), isNull);
      expect(reader.faceToPortraitId(9999), isNull);
      reader.dispose();
    });

    test('unitIndexForFace 能反查回原单位', () {
      final rom = _open(fe7jp);
      final reader = PortraitReader(rom);
      for (var i = 0; i < 10; i++) {
        final id = reader.faceToPortraitId(portraitFaceOf(rom, i));
        if (id == null) continue;
        expect(reader.unitIndexForFace(id), i, reason: 'unit $i');
      }
      reader.dispose();
    });

    test('FE6：face 比肖像索引大 1，换算不能偏格', () {
      // 封印之剑里罗伊 face=2 对应肖像 1（肖像 0 是山贼）。
      // 曾把方向写反，结果取到肖像 3（珐），且前两个角色直接无图。
      final rom = _open(fe6cn);
      final reader = PortraitReader(rom);
      expect(portraitFaceOf(rom, 0), 2);
      expect(reader.faceToPortraitId(2), 1);
      expect(reader.faceToPortraitId(3), 2);
      expect(reader.faceToPortraitId(4), 3);
      // face=0 是通用敌人脸，固定落在肖像 0
      expect(reader.faceToPortraitId(0), 0);
      reader.dispose();
    });

    test('FE6：每个角色的肖像反查回来都是它自己', () {
      // 用码表解中文名，能直接看出人像归属对不对
      final rom = _open(fe6cn)..zhTable = ZhTable(zhTblFE6);
      final reader = PortraitReader(rom);
      var checked = 0;
      for (var i = 0; i < rom.unitCount && checked < 20; i++) {
        final name = rom.unitName(i).trim();
        if (name.isEmpty) continue;
        final pid = reader.faceToPortraitId(portraitFaceOf(rom, i));
        if (pid == null) continue;
        expect(reader.nameFor(pid), name, reason: 'unit $i ($name)');
        checked++;
      }
      expect(checked, greaterThan(10));
      reader.dispose();
    });

    test('FE7/FE8：face 与肖像索引仍然恒等（不受 FE6 修正影响）', () {
      for (final p in [fe7jp, fe8jp]) {
        final rom = _open(p);
        final reader = PortraitReader(rom);
        for (var i = 0; i < 8; i++) {
          final face = portraitFaceOf(rom, i);
          if (face <= 0) continue;
          expect(reader.faceToPortraitId(face), face,
              reason: '$p unit $i face=$face');
        }
        reader.dispose();
      }
    });
  });
}
