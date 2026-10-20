import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';

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
  group('表边界（防过度读取）', () {
    test('FE6 日版：职业 76 / 道具 128', () {
      final rom = _open(fe6jp);
      expect(rom.classCount, 76);
      expect(rom.itemCount, 128);
    });

    test('FE6 汉化版：职业 76 / 道具 128', () {
      final rom = _open(fe6cn);
      expect(rom.classCount, 76);
      expect(rom.itemCount, 128);
    });

    test('边界不超过 0xFF，且条目数远小于硬编码上限', () {
      for (final path in [fe6jp, fe6cn, fe7jp, fe7us, fe8jp]) {
        final rom = _open(path);
        expect(rom.classCount, lessThanOrEqualTo(0x100), reason: path);
        expect(rom.itemCount, lessThanOrEqualTo(0x100), reason: path);
        expect(rom.unitCount, lessThanOrEqualTo(rom.table.unitMaxCount), reason: path);
      }
    });

    test('职业表判停：越界后第一条 class number 为 0', () {
      for (final path in [fe6jp, fe6cn, fe7jp]) {
        final rom = _open(path);
        final count = rom.classCount;
        if (count >= 0x100) continue;
        final addr = rom.classBase + count * rom.table.classDataSize;
        expect(rom.data[addr + 4], 0, reason: path);
      }
    });

    test('道具表判停：越界后第一条的指针字段非法', () {
      for (final path in [fe6jp, fe6cn, fe7jp]) {
        final rom = _open(path);
        final count = rom.itemCount;
        if (count >= 0x100) continue;
        final addr = rom.itemBase + count * rom.table.itemDataSize;
        bool pointerOk(int v) =>
            v == 0 || (v >= 0x08000000 && v < 0x0A000000);
        int u32(int at) => rom.data[at] | (rom.data[at + 1] << 8) |
            (rom.data[at + 2] << 16) | (rom.data[at + 3] << 24);
        final p12 = u32(addr + 12);
        final p16 = u32(addr + 16);
        expect(pointerOk(p12) && pointerOk(p16), isFalse, reason: path);
      }
    });

    test('边界内的条目名字能正常解出（不是空的）', () {
      final rom = _open(fe7jp);
      var named = 0;
      for (var i = 0; i < rom.classCount; i++) {
        if (rom.className(i).trim().isNotEmpty) named++;
      }
      expect(named, greaterThan(rom.classCount ~/ 2));
    });
  });
}
