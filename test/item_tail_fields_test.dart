import 'dart:io';
import 'dart:typed_data';

import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/item_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

Directory get _romDir => Directory('${Platform.environment['HOME']}/workspace/game-rom');

File _romByKeyword(String keyword) {
  for (final f in _romDir.listSync()) {
    if (f is File && f.path.contains(keyword)) return f;
  }
  throw StateError('找不到文件名包含 $keyword 的 ROM');
}

EditableRom _open(String keyword) {
  final data = Uint8List.fromList(_romByKeyword(keyword).readAsBytesSync());
  return EditableRom.open(data, FeRom.detectTable(data)!);
}

void main() {
  group('道具尾段三字段（bmitem.h +30/31/32）', () {
    test('FE8J 武器特效/使用效果/武器经验读值正确', () {
      final cat = ItemCatalog(_open('1692 -').rom);
      // 毒剑（id 8）特效=毒；魔剑类（id 39）特效=魔剑、武器经验 8
      expect(cat.entryAt(8)!.weaponEffectId, 1, reason: '毒');
      expect(cat.entryAt(8)!.weaponEffectLabel, '毒');
      expect(cat.entryAt(39)!.weaponEffectId, 4, reason: '魔剑');
      expect(cat.entryAt(39)!.weaponExp, 8);
      // 石化（FE8 专有）
      expect(cat.entryAt(181)!.weaponEffectId, 5, reason: '石化');
      expect(cat.entryAt(181)!.weaponEffectLabel, '石化');
      // 龙石带毒
      expect(cat.entryAt(175)!.weaponEffectId, 1);
      // 伤药类有使用效果
      expect(cat.entryAt(75)!.useEffectId, 1);
      expect(cat.entryAt(75)!.useEffectLabel, '效果 1');
      // 普通武器无特效
      expect(cat.entryAt(1)!.weaponEffectId, 0, reason: '铁剑');
      expect(cat.entryAt(1)!.weaponEffectLabel, '无');
    });

    test('特效值域全集：0..5 都出现过，且无越界值', () {
      final cat = ItemCatalog(_open('1692 -').rom);
      final seen = <int>{};
      for (var i = 0; i < cat.count; i++) {
        final v = cat.entryAt(i)!.weaponEffectId;
        expect(v, inInclusiveRange(0, 5), reason: 'item$i');
        seen.add(v);
      }
      expect(seen, containsAll([0, 1, 2, 3, 4, 5]));
    });

    test('FE6 条目 32 字节：weaponExp 强制 0，不越进下一条', () {
      final fe6 = ItemCatalog(_open('0378').rom);
      expect(fe6.entryAt(8)!.weaponExp, 0);
      // +30/+31 在 FE6 条目范围内，照常读
      final e = fe6.entryAt(8)!;
      expect(e.useEffectId, inInclusiveRange(0, 255));
      expect(e.weaponEffectId, inInclusiveRange(0, 255));
    });
  });
}
