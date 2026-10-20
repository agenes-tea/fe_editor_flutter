import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/text_codec.dart';

const dir = '/root/workspace/game-rom';
const jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const us = '$dir/1235 - 火炎之纹章-烈火之剑 Fire Emblem(US)(Nintendo)(128Mb).gba';
const fe7cn = '$dir/火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba';
const fe6cn = '$dir/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';

void main() {
  test('FE7 日版：识别 + 文本解码', () async {
    final data = await File(jp).readAsBytes();
    final table = FeRom.detectTable(data)!;
    expect(table.id, 'FE7J');
    final rom = FeRom(data, table);
    expect(rom.gameCode, 'AE7J');
    expect(rom.textEncodingHealthy, isTrue);
    expect(rom.unitName(0), 'エリウッド');
    expect(rom.unitName(1), 'ヘクトル');
    expect(rom.unitName(2), 'リン');
    expect(rom.unitName(3), 'レイヴァン');
    expect(rom.className(1), 'ロード');
    expect(rom.itemName(1), 'てつの剣');
    expect(rom.itemName(2), 'ほそみの剣');
  });

  test('FE7 美版：识别 + 文本解码', () async {
    final data = await File(us).readAsBytes();
    final table = FeRom.detectTable(data)!;
    expect(table.id, 'FE7U');
    final rom = FeRom(data, table);
    expect(rom.gameCode, 'AE7E');
    expect(rom.textEncodingHealthy, isTrue);
    expect(rom.unitName(0), 'Eliwood');
    expect(rom.unitName(1), 'Hector');
    expect(rom.unitName(2), 'Lyn');
    expect(rom.className(1), 'Lord');
    expect(rom.itemName(1), 'Iron sword');
  });

  test('FE7 中文改版：地址表可用，文本识别为明文 GBK', () async {
    final data = await File(fe7cn).readAsBytes();
    final table = FeRom.detectTable(data)!;
    expect(table.id, 'FE7J');
    final rom = FeRom(data, table);
    expect(rom.unitBase, greaterThan(0));
    expect(rom.classBase, greaterThan(0));
    expect(rom.itemBase, greaterThan(0));
    expect(rom.textEncoding, FeTextEncoding.plainGbk);
    expect(rom.textEncodingHealthy, isTrue);
  });

  test('FE6 中文改版：game code 为 AFEJ，需回退识别', () async {
    final data = await File(fe6cn).readAsBytes();
    expect(String.fromCharCodes(data.sublist(0xAC, 0xB0)), 'AFEJ');
    final table = FeRom.detectTable(data);
    expect(table, isNotNull);
    expect(table!.id, 'FE6');
    final rom = FeRom(data, table);
    expect(rom.unitBase, greaterThan(0));
    expect(rom.classBase, greaterThan(0));
    expect(rom.itemBase, greaterThan(0));
  });

  test('非 FE ROM 返回 null', () async {
    final data = await File('$dir/火炎之纹章-圣魔之光石汉化.gba').readAsBytes();
    // 圣魔之光石是 FE8，应识别成功而不是 null；换真正的非 FE 用例：
    expect(FeRom.detectTable(data), isNotNull);
    // 用构造的非 FE 头部验证 null 路径
    final fake = Uint8List(0x1000);
    fake.setAll(0xAC, [0x42, 0x50, 0x45, 0x45]); // BPEE = 绿宝石
    expect(FeRom.detectTable(fake), isNull);
  });
}
