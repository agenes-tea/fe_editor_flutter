import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/zh_table.dart';
import 'package:fe_editor/core/zh_tables_data.dart';

const fe6cn =
    '/root/workspace/game-rom/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const fe6Header = 48;

void main() {
  test('FE6 单位表需要跳过指针数组', () async {
    final data = await File(fe6cn).readAsBytes();
    final table = FeRom.detectTable(data)!;
    expect(table.id, 'FE6');
    final rom = FeRom(data, table);
    expect(rom.isFe6, isTrue);

    // unitBase 指向真实结构表，首字段是名字文本 id，必须是合理值
    final base = rom.unitBase;
    expect(base, greaterThan(0));
    final nameId = FeRom.u16(data, base);
    expect(nameId, lessThan(0x7FFF));

    // 跳过之前的指针数组内容会是 GBA 指针，不可能是这个值
    final rawBase = rom.pointerAt(table.unitPointerSlot);
    expect(rawBase, lessThan(base));
    expect(base - rawBase, fe6Header);
  });

  test('FE6 单位等级字段在合理区间', () async {
    final data = await File(fe6cn).readAsBytes();
    final table = FeRom.detectTable(data)!;
    final rom = FeRom(data, table);
    final base = rom.unitBase;
    // 前 6 个单位等级应为 1~20 之间的小数值
    for (var i = 0; i < 6; i++) {
      final lv = FeRom.u8(data, base + i * table.unitDataSize + 11);
      expect(lv, greaterThanOrEqualTo(1));
      expect(lv, lessThanOrEqualTo(20));
    }
  });

  test('全部 GBA 三部曲都允许字段编辑', () {
    for (final id in ['FE6','FE7J','FE7U','FE8J','FE8U']) {
      expect(versionSupportsEditing(id), isTrue, reason: id);
    }
  });

  test('FE6 字段编辑写入与读回', () async {
    final data = await File(fe6cn).readAsBytes();
    final table = FeRom.detectTable(data)!;
    final edit = EditableRom.open(data, table);
    final addr = edit.unitAddress(0);

    final lv = unitEditableFields.firstWhere((f) => f.label == '等级');
    final hp = unitEditableFields.firstWhere((f) => f.label == 'HP');
    final grow = unitEditableFields.firstWhere((f) => f.label == 'HP成长');

    expect(edit.readField(addr, lv), 1);
    edit.writeField(addr, lv, 10);
    edit.writeField(addr, hp, 30);
    edit.writeField(addr, grow, 99);
    expect(edit.readField(addr, lv), 10);
    expect(edit.readField(addr, hp), 30);
    expect(edit.readField(addr, grow), 99);

    // 名字不受影响
    final tbl = ZhTable(zhTblFE6);
    edit.rom.zhTable = tbl;
    expect(edit.rom.unitName(0), '罗伊');
    // 撤销复原
    edit.revertAll();
    expect(edit.readField(addr, lv), 1);
  });
}
