import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/text_codec.dart';
import 'package:fe_editor/core/text_browser.dart';
import 'package:fe_editor/core/zh_table.dart';
import 'package:fe_editor/core/zh_tables_data.dart';

const jp7 =
    '/root/workspace/game-rom/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const cn6 =
    '/root/workspace/game-rom/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const cn7 =
    '/root/workspace/game-rom/火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba';

void main() {
  test('FE7 日版：枚举文本并渲染', () async {
    final data = await File(jp7).readAsBytes();
    final rom = FeRom(data, FeRom.detectTable(data)!);
    final browser = TextBrowser(rom);
    final n = browser.maxId;
    print('FE7J 文本条数: $n');
    expect(n, greaterThan(1000));
    var nonEmpty = 0;
    for (var i = 0; i < 100; i++) {
      if (browser.render(i).trim().isNotEmpty) nonEmpty++;
    }
    expect(nonEmpty, greaterThan(50));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('FE6 汉化版：中文渲染', () async {
    final data = await File(cn6).readAsBytes();
    final rom = FeRom(data, FeRom.detectTable(data)!)..zhTable = ZhTable(zhTblFE6);
    final browser = TextBrowser(rom);
    var cnFound = false;
    for (var i = 0; i < 300; i++) {
      final t = browser.render(i);
      if (t.contains('罗伊') || t.contains('伯尔')) cnFound = true;
    }
    expect(cnFound, isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('FE7 汉化版（明文 GBK）：中文渲染', () async {
    final data = await File(cn7).readAsBytes();
    final rom = FeRom(data, FeRom.detectTable(data)!);
    expect(rom.textEncoding, FeTextEncoding.plainGbk);
    final browser = TextBrowser(rom);
    expect(browser.render(5), contains('武器店'));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
