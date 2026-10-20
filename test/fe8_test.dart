import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/text_codec.dart';

const jp8 =
    '/root/workspace/game-rom/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';
const cn8 = '/root/workspace/game-rom/火炎之纹章-圣魔之光石汉化.gba';

void main() {
  test('FE8 日版识别与文本（SJIS）', () async {
    final data = await File(jp8).readAsBytes();
    final table = FeRom.detectTable(data)!;
    expect(table.id, 'FE8J');
    final rom = FeRom(data, table);
    expect(rom.textEncoding, FeTextEncoding.huffmanSjis);
    expect(rom.textEncodingHealthy, isTrue);
    expect(rom.unitName(0), 'エイリーク');
    expect(rom.unitName(1), 'ゼト');
  });

  test('FE8 汉化版：地址表有效、字段可编辑', () async {
    final data = await File(cn8).readAsBytes();
    final table = FeRom.detectTable(data)!;
    expect(table.id, 'FE8J');
    final rom = FeRom(data, table);
    expect(rom.unitBase, greaterThan(0));
    expect(rom.classBase, greaterThan(0));
    expect(rom.itemBase, greaterThan(0));
    // 字段实测
    final edit = EditableRom.open(data, table);
    final addr = edit.unitAddress(0);
    final lv = unitEditableFields.firstWhere((f) => f.label == '等级');
    expect(edit.readField(addr, lv), inInclusiveRange(1, 20));
    edit.writeField(addr, lv, 15);
    expect(edit.readField(addr, lv), 15);
    edit.revertAll();
    expect(edit.readField(addr, lv), inInclusiveRange(1, 20));
  });

  test('FE8 日版与汉化版单位表逐字节一致', () async {
    final jp = await File(jp8).readAsBytes();
    final cn = await File(cn8).readAsBytes();
    final tjp = FeRom.detectTable(jp)!;
    final tcn = FeRom.detectTable(cn)!;
    final rjp = FeRom(jp, tjp);
    final rcn = FeRom(cn, tcn);
    expect(rjp.unitBase, rcn.unitBase);
    // 前 12 个单位的数值字段一致
    for (var i = 0; i < 12; i++) {
      final a = rjp.unitBase + i * tjp.unitDataSize;
      for (final off in [11, 12, 13, 14, 15, 16, 17, 18, 28, 29, 33, 34]) {
        expect(jp[a + off], cn[a + off], reason: 'unit$i off$off');
      }
    }
  });
}
