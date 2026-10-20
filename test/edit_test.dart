import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/patch_format.dart';

const jp =
    '/root/workspace/game-rom/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';

void main() {
  test('修改角色字段并导出，重新打开能读回新值', () async {
    final data = await File(jp).readAsBytes();
    final table = FeRom.detectTable(data)!;
    final edit = EditableRom.open(data, table);

    final addr = edit.unitAddress(0);
    final levelField = unitEditableFields.firstWhere((f) => f.label == '等级');
    final hpField = unitEditableFields.firstWhere((f) => f.label == 'HP');

    expect(edit.readField(addr, levelField), 1);
    edit.writeField(addr, levelField, 20);
    edit.writeField(addr, hpField, 40);
    expect(edit.readField(addr, levelField), 20);
    expect(edit.hasChanges, isTrue);
    expect(edit.changedByteCount, 2);

    // 导出后重新解析
    final out = edit.buildOutput();
    final rom2 = FeRom(Uint8List.fromList(out), table);
    final edit2 = EditableRom.open(out, table);
    expect(edit2.readField(edit2.unitAddress(0), levelField), 20);
    // 名字未受影响
    expect(rom2.unitName(0), 'エリウッド');
  });

  test('写入值被夹紧到字段范围', () async {
    final data = await File(jp).readAsBytes();
    final table = FeRom.detectTable(data)!;
    final edit = EditableRom.open(data, table);
    final addr = edit.unitAddress(0);

    final lv = unitEditableFields.firstWhere((f) => f.label == '等级');
    edit.writeField(addr, lv, 999);
    expect(edit.readField(addr, lv), lv.max);

    final grow = unitEditableFields.firstWhere((f) => f.label == 'HP成长');
    edit.writeField(addr, grow, -5);
    expect(edit.readField(addr, grow), grow.min);
  });

  test('同值写入不产生改动记录', () async {
    final data = await File(jp).readAsBytes();
    final table = FeRom.detectTable(data)!;
    final edit = EditableRom.open(data, table);
    final addr = edit.unitAddress(0);
    final lv = unitEditableFields.firstWhere((f) => f.label == '等级');
    final before = edit.readField(addr, lv);
    expect(edit.writeField(addr, lv, before), isFalse);
    expect(edit.changedByteCount, 0);
  });

  test('撤销回到原始状态', () async {
    final data = await File(jp).readAsBytes();
    final table = FeRom.detectTable(data)!;
    final edit = EditableRom.open(data, table);
    final addr = edit.unitAddress(3);
    final hp = unitEditableFields.firstWhere((f) => f.label == 'HP');
    final original = edit.readField(addr, hp);
    edit.writeField(addr, hp, original + 10);
    expect(edit.hasChanges, isTrue);
    edit.revertAll();
    expect(edit.hasChanges, isFalse);
    expect(edit.readField(addr, hp), original);
    expect(edit.buildOutput(), equals(data));
  });

  test('改字段后生成 UPS，可用于还原', () async {
    final data = await File(jp).readAsBytes();
    final table = FeRom.detectTable(data)!;
    final edit = EditableRom.open(data, table);
    final addr = edit.unitAddress(0);
    edit.writeField(addr, unitEditableFields.first, 30);

    final out = edit.buildOutput();
    final patch = UpsPatch.create(edit.original, out);
    expect(patch.length, lessThan(500));

    final applied = UpsPatch.apply(patch, edit.original);
    expect(applied, isNotNull);
    expect(applied, equals(out));
  });

  test('改角色数值不会波及文本区', () async {
    final data = await File(jp).readAsBytes();
    final table = FeRom.detectTable(data)!;
    final edit = EditableRom.open(data, table);
    final namesBefore = <String>[for (var i = 0; i < 5; i++) edit.rom.unitName(i)];

    final addr = edit.unitAddress(0);
    for (final f in unitEditableFields) {
      edit.writeField(addr, f, f.max);
    }
    final rom2 = FeRom(Uint8List.fromList(edit.buildOutput()), table);
    final namesAfter = <String>[for (var i = 0; i < 5; i++) rom2.unitName(i)];
    expect(namesAfter, namesBefore);
  });
}

// ===== 追加：FE6 表定位与版本限制 =====
void fe6Tests() {}
