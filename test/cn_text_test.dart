import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/text_codec.dart';

const cn7 =
    '/root/workspace/game-rom/火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba';
const jp7 =
    '/root/workspace/game-rom/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const cn6 =
    '/root/workspace/game-rom/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';

void main() {
  test('汉化版烈火之剑识别为明文 GBK', () async {
    final data = await File(cn7).readAsBytes();
    final rom = FeRom(data, FeRom.detectTable(data)!);
    expect(rom.textEncoding, FeTextEncoding.plainGbk);
    expect(rom.textEncodingHealthy, isTrue);
  });

  test('汉化版烈火之剑角色名正确', () async {
    final data = await File(cn7).readAsBytes();
    final rom = FeRom(data, FeRom.detectTable(data)!);
    expect(rom.unitName(0), '艾利乌德');
    expect(rom.unitName(1), '海克托尔');
    expect(rom.unitName(2), '琳');
    expect(rom.unitName(3), '雷万');
  });

  test('汉化版烈火之剑职业与道具名正确', () async {
    final data = await File(cn7).readAsBytes();
    final rom = FeRom(data, FeRom.detectTable(data)!);
    expect(rom.className(1), '领主');
    expect(rom.className(4), '利基亚骑士');
    expect(rom.itemName(1), '铁剑');
    expect(rom.itemName(2), '细剑');
    expect(rom.itemName(3), '钢剑');
  });

  test('日版仍是 Huffman+SJIS，不受影响', () async {
    final data = await File(jp7).readAsBytes();
    final rom = FeRom(data, FeRom.detectTable(data)!);
    expect(rom.textEncoding, FeTextEncoding.huffmanSjis);
    expect(rom.unitName(0), 'エリウッド');
    expect(rom.itemName(1), 'てつの剣');
  });

  test('封印之剑汉化版：非明文 GBK，需挂 .tbl 码表（由 UI 层完成）', () async {
    final data = await File(cn6).readAsBytes();
    final rom = FeRom(data, FeRom.detectTable(data)!);
    expect(rom.textEncoding, isNot(FeTextEncoding.plainGbk));
  });
}

void fe6TblTests() {}
