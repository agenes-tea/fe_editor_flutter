import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/text_codec.dart';
import 'package:fe_editor/core/zh_table.dart';

const cn6 =
    '/root/workspace/game-rom/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const tbl = '/root/workspace/fe_editor/assets/tbl/FE6.tbl';

void main() {
  test('FE6 汉化版挂载 .tbl 后解出角色名', () async {
    final data = await File(cn6).readAsBytes();
    final rom = FeRom(data, FeRom.detectTable(data)!);
    // 初始无法识别（不是 GBK 明文、标准 SJIS 也不成立）
    expect(rom.textEncoding, FeTextEncoding.unknown);

    final t = await ZhTable.loadFile(tbl);
    expect(t, isNotNull);
    rom.zhTable = t;

    // 码表匹配率应达标
    expect(rom.zhTableMatchRatio(), greaterThanOrEqualTo(0.5));

    expect(rom.unitName(0), '罗伊');
    expect(rom.unitName(1), '克莱丽奈');
    expect(rom.unitName(2), '珐');
    expect(rom.unitName(3), '辛');
  });
}
