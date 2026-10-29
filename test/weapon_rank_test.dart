import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/item_catalog.dart';
import 'package:fe_editor/core/rom_info.dart';
import 'package:fe_editor/core/zh_table.dart';
import 'package:fe_editor/core/zh_tables_data.dart';

const dir = '/root/workspace/game-rom';
const fe6jp = '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const fe6cn = '$dir/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe7us = '$dir/1235 - 火炎之纹章-烈火之剑 Fire Emblem(US)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

FeRom _open(String path) {
  final data = File(path).readAsBytesSync();
  return FeRom(data, FeRom.detectTable(data)!);
}

/// 读 8 项熟练度并转成等级字母。
List<String> _ranksAt(FeRom rom, int addr, int offset) {
  final fe6 = rom.isFe6;
  return [
    for (var i = 0; i < 8; i++)
      WeaponRank.fromValue(rom.data[addr + offset + i], fe6: fe6).label,
  ];
}

int _unitAddr(FeRom rom, int index) =>
    rom.unitBase + index * rom.table.unitDataSize;

int _classAddr(FeRom rom, int index) =>
    rom.classBase + index * rom.table.classDataSize;

void main() {
  group('熟练度档位', () {
    test('两套阈值各自映射到 E~S', () {
      const fe7 = {0x00: '—', 0x01: 'E', 0x1F: 'D', 0x47: 'C',
        0x79: 'B', 0xB5: 'A', 0xFB: 'S'};
      const fe6 = {0x00: '—', 0x01: 'E', 0x33: 'D', 0x65: 'C',
        0x97: 'B', 0xC9: 'A', 0xFB: 'S'};
      fe7.forEach((v, label) {
        expect(WeaponRank.fromValue(v, fe6: false).label, label,
            reason: 'FE7/FE8 0x${v.toRadixString(16)}');
      });
      fe6.forEach((v, label) {
        expect(WeaponRank.fromValue(v, fe6: true).label, label,
            reason: 'FE6 0x${v.toRadixString(16)}');
      });
    });

    test('档位之间的值按「已达成的最高档」算', () {
      expect(WeaponRank.fromValue(0x46, fe6: false), WeaponRank.d);
      expect(WeaponRank.fromValue(0xFA, fe6: false), WeaponRank.a);
      expect(WeaponRank.fromValue(0xFF, fe6: false), WeaponRank.s);
      expect(WeaponRank.fromValue(0x64, fe6: true), WeaponRank.d);
      expect(WeaponRank.fromValue(0xFA, fe6: true), WeaponRank.a);
    });

    test('EditField 的档位跳转只落在合法值上', () {
      final field = unitEditableFieldsFor(fe6: false)
          .firstWhere((f) => f.label == '剑熟练度');
      expect(field.steps, [0, 1, 0x1F, 0x47, 0x79, 0xB5, 0xFB]);
      expect(field.stepDown(0x1F), 0x01);
      expect(field.stepUp(0x1F), 0x47);
      expect(field.stepUp(0xFB), isNull);
      expect(field.stepDown(0x00), isNull);
      // 非法值（手工输入的）也能找到最近档位
      expect(field.stepDown(0x30), 0x1F);
      expect(field.stepUp(0x30), 0x47);
      expect(field.labelFor(0x50), 'C');
      expect(field.labelFor(0), '—');
    });

    test('FE6 的档位跳转用 FE6 阈值', () {
      final field = unitEditableFieldsFor(fe6: true)
          .firstWhere((f) => f.label == '剑熟练度');
      expect(field.steps, [0, 1, 0x33, 0x65, 0x97, 0xC9, 0xFB]);
      expect(field.stepUp(0x01), 0x33);
      expect(field.labelFor(0x65), 'C');
    });
  });

  group('单位表熟练度', () {
    test('FE7J 赫克托尔：斧 C', () {
      final rom = _open(fe7jp);
      final ranks = _ranksAt(rom, _unitAddr(rom, 1), UnitOffsets.swordRank);
      expect(ranks[2], 'C', reason: '斧熟练度');
      expect(ranks[0], '—');
    });

    test('FE7J 琳：剑 D', () {
      final rom = _open(fe7jp);
      final ranks = _ranksAt(rom, _unitAddr(rom, 2), UnitOffsets.swordRank);
      expect(ranks[0], 'D');
    });

    test('FE8J 泽特：剑 A / 枪 A', () {
      final rom = _open(fe8jp);
      final ranks = _ranksAt(rom, _unitAddr(rom, 1), UnitOffsets.swordRank);
      expect(ranks[0], 'A');
      expect(ranks[1], 'A');
    });

    test('所有版本的 8 项熟练度都落在合法档位上', () {
      for (final path in [fe6cn, fe7jp, fe7us, fe8jp]) {
        final rom = _open(path);
        final known = {
          for (final r in WeaponRank.values) r.valueFor(fe6: rom.isFe6),
        };
        for (var i = 0; i < 20 && i < rom.unitCount; i++) {
          final addr = _unitAddr(rom, i);
          for (var k = 0; k < 8; k++) {
            final v = rom.data[addr + UnitOffsets.swordRank + k];
            expect(known, contains(v),
                reason: '$path unit $i 第 $k 项熟练度 = 0x${v.toRadixString(16)}');
          }
        }
      }
    });
  });

  group('职业表熟练度', () {
    test('FE7J 领主：剑 D', () {
      final rom = _open(fe7jp);
      final offset = ClassOffsets.weaponRankOffset(rom.isFe6);
      expect(offset, 44);
      final ranks = _ranksAt(rom, _classAddr(rom, 1), offset);
      expect(ranks[0], 'D');
    });

    test('FE6 领主：剑 D（偏移是 +40 不是 +44）', () {
      final rom = _open(fe6cn);
      final offset = ClassOffsets.weaponRankOffset(rom.isFe6);
      expect(offset, 40);
      final ranks = _ranksAt(rom, _classAddr(rom, 1), offset);
      expect(ranks[0], 'D');
      // +44 处不是熟练度：按熟练度读会得到非法值（实测是 0x66）
      expect(rom.data[_classAddr(rom, 1) + 44], isNot(0x33));
    });

    test('FE8J 领主：枪 D', () {
      final rom = _open(fe8jp);
      final offset = ClassOffsets.weaponRankOffset(rom.isFe6);
      final ranks = _ranksAt(rom, _classAddr(rom, 1), offset);
      expect(ranks[1], 'D');
    });

    test('所有版本职业的 8 项熟练度都落在合法档位上', () {
      for (final path in [fe6cn, fe7jp, fe7us, fe8jp]) {
        final rom = _open(path);
        final offset = ClassOffsets.weaponRankOffset(rom.isFe6);
        final known = {
          for (final r in WeaponRank.values) r.valueFor(fe6: rom.isFe6),
        };
        for (var i = 1; i < 20 && i < rom.classCount; i++) {
          final addr = _classAddr(rom, i);
          for (var k = 0; k < 8; k++) {
            final v = rom.data[addr + offset + k];
            expect(known, contains(v),
                reason: '$path class $i 第 $k 项熟练度 = 0x${v.toRadixString(16)}');
          }
        }
      }
    });
  });

  group('熟练度编辑', () {
    test('FE7J 角色剑熟练度 E→A 写入并读回', () {
      final data = File(fe7jp).readAsBytesSync();
      final edit = EditableRom.open(data, FeRom.detectTable(data)!);
      final addr = edit.unitAddress(2);
      final field = unitEditableFieldsFor(fe6: false)
          .firstWhere((f) => f.label == '剑熟练度');

      expect(edit.readField(addr, field), 0x1F); // 琳初始剑 D
      expect(field.labelFor(edit.readField(addr, field)), 'D');

      final target = WeaponRank.a.valueFor(fe6: false);
      expect(edit.writeField(addr, field, target), isTrue);
      expect(edit.readField(addr, field), 0xB5);
      expect(field.labelFor(edit.readField(addr, field)), 'A');

      edit.revertAll();
      expect(edit.readField(addr, field), 0x1F);
    });

    test('FE6 职业熟练度写入落在 +40', () {
      final data = File(fe6cn).readAsBytesSync();
      final edit = EditableRom.open(data, FeRom.detectTable(data)!);
      final addr = edit.classAddress(1);
      final field = classEditableFieldsFor(fe6: true)
          .firstWhere((f) => f.label == '剑熟练度');

      expect(field.offset, 40);
      expect(field.labelFor(edit.readField(addr, field)), 'D');
      edit.writeField(addr, field, 0xFB);
      expect(field.labelFor(edit.readField(addr, field)), 'S');
      expect(edit.readField(addr, field), 0xFB);
    });

    test('改熟练度不影响文本区与其它字段', () {
      final data = File(fe7jp).readAsBytesSync();
      final table = FeRom.detectTable(data)!;
      final edit = EditableRom.open(data, table);
      final addr = edit.unitAddress(1);
      final fields = unitEditableFieldsFor(fe6: false)
          .where((f) => f.label.endsWith('熟练度'))
          .toList();
      expect(fields, hasLength(8));

      final hpBefore = edit.readField(
          addr, unitEditableFieldsFor(fe6: false)[1]);
      for (final f in fields) {
        edit.writeField(addr, f, 0xFB);
      }
      expect(edit.edits, hasLength(8));
      expect(
          edit.readField(addr, unitEditableFieldsFor(fe6: false)[1]), hpBefore);
      expect(edit.rom.unitName(1), 'ヘクトル');
    });

    test('字段数量：16 项数值（含体格）+ 8 项熟练度', () {
      final unit = unitEditableFieldsFor(fe6: false);
      expect(unit.length, 24);
      expect(unit.where((f) => f.steps != null).length, 8);
      expect(unit.where((f) => f.signed).length, 8);
      // 体格在 +19，属于有符号字段
      final con = unit.firstWhere((f) => f.label == '体格');
      expect(con.offset, UnitOffsets.con);
      expect(con.offset, 19);
      expect(con.signed, isTrue);
      // 职业字段：移动 +18、体格 +17（不是 37/41 那两个特性标志位）
      final cls = classEditableFieldsFor(fe6: false);
      expect(cls.firstWhere((f) => f.label == '移动力').offset, 18);
      expect(cls.firstWhere((f) => f.label == '体格').offset, 17);
      // 职业共 28 项数值 + 8 项熟练度（含能力上限 7 项、转职加成 6 项、经验分母 1 项）
      expect(cls.length, 36);
      expect(cls.where((f) => f.steps != null).length, 8);
      expect(cls.where((f) => f.label.endsWith('上限')).length, 7);
      expect(cls.where((f) => f.label.startsWith('转职')).length, 6);
      expect(classEditableFieldsFor(fe6: true).last.offset, 47);
      expect(classEditableFieldsFor(fe6: false).last.offset, 51);
    });
  });

  group('道具表熟练度（+28）', () {
    test('FE6 与 FE7 的铁剑都读成 E，但字面值不同', () {
      final fe6 = ItemCatalog(_open(fe6cn)).entryAt(1)!;
      final fe7 = ItemCatalog(_open(fe7jp)).entryAt(1)!;
      expect(fe6.weaponRank.label, 'E');
      expect(fe7.weaponRank.label, 'E');
      expect(fe6.weaponRankValue, fe7.weaponRankValue);
    });

    test('FE6 汉化版的 0x33 读成 D，FE7 的 0x1F 也读成 D', () {
      final cat = ItemCatalog(_open(fe6cn));
      final e = cat.entryAt(2)!; // FE6 钢剑，档位 0x33
      expect(e.weaponRankValue, 0x33);
      expect(e.weaponRank.label, 'D');

      final fe7 = ItemCatalog(_open(fe7jp)).entryAt(3)!; // FE7 钢剑，档位 0x1F
      expect(fe7.weaponRankValue, 0x1F);
      expect(fe7.weaponRank.label, 'D');
    });

    test('FE6 汉化版走码表、日版走标准 Huffman', () {
      final rom = _open(fe6cn)..zhTable = ZhTable(zhTblFE6);
      final cat = ItemCatalog(rom);
      expect(cat.nameOf(1).trim(), '铁剑');

      // 日版此前被判成 unknown（健康度 0.23），根因是文本判定把 FE 的
      // 控制码（0C 10 50 01 之类）当成了坏字节。修好后应为标准 Huffman。
      final jp = _open(fe6jp);
      expect(jp.textEncoding.name, 'huffmanSjis');
      expect(ItemCatalog(jp).nameOf(1).trim(), 'てつの剣');
    });
  });
}
