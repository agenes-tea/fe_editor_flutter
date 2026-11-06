import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/text_codec.dart';

import 'rom_paths.dart';

const dir = romDir;
const jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const us = '$dir/1235 - 火炎之纹章-烈火之剑 Fire Emblem(US)(Nintendo)(128Mb).gba';
const fe7cn = '$dir/火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba';
const fe6cn = '$dir/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const fe6jp = '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';

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

  // 封印之剑日版的文本里夹着大量 FE 控制码（0C 10 50 01 之类）。
  // 健康度判定早期把这些控制码当坏字节，整片算下来只有 0.23，
  // 于是 8MB 的日版 ROM 被误报成「未识别文本引擎」、角色与职业名全空。
  test('FE6 日版：文本编码可识别且名字能解出', () async {
    final data = await File(fe6jp).readAsBytes();
    final table = FeRom.detectTable(data)!;
    expect(table.id, 'FE6');
    final rom = FeRom(data, table);
    expect(rom.gameCode, 'AFEJ');
    expect(rom.textAvailable, isTrue);
    expect(rom.textEncodingHealthy, isTrue,
        reason: '控制码不应拉低健康度（曾低到 0.23 导致判为 unknown）');
    expect(rom.unitName(0), 'ロイ');
    expect(rom.unitName(1), 'クラリーネ');
    expect(rom.unitName(2), 'ファ');
    expect(rom.className(1), 'ロード');
    expect(rom.itemName(1), 'てつの剣');
    expect(rom.itemName(3), 'はがねの剣');
  });

  // 回归：指纹只采样头尾 4KB 时，「换了中段肖像图的副本」与原版指纹相同，
  // 于是打开原版会直接复用到旧会话 / 图像缓存撞车（游戏里却是真图）。
  test('指纹覆盖全文件：中段字节不同就应不同', () async {
    final data = await File(fe7cn).readAsBytes();
    final table = FeRom.detectTable(data)!;
    final a = FeRom(Uint8List.fromList(data), table).fingerprint;

    final mutated = Uint8List.fromList(data);
    // 改中段一个字节（远离头尾 4KB）
    mutated[mutated.length ~/ 2] ^= 0xFF;
    final b = FeRom(mutated, table).fingerprint;

    expect(a, isNot(b),
        reason: '中段改动必须影响指纹，否则缓存与多会话会认错 ROM');
  });
}
