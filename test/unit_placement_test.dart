import 'dart:io';
import 'dart:typed_data';

import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/unit_placement.dart';
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
  group('FE8 章节初始单位', () {
    test('第 0 章我方列表与已知值一致', () {
      final edit = _open('1692 -');
      final up = UnitPlacement(edit);
      expect(up.entrySize, 20);
      expect(up.chapterCount, greaterThan(50));

      final units = up.units(0, UnitSlot.playerNormal);
      expect(units.length, 2, reason: '第 0 章我方应有 2 人');
      // 实测：角色 2（艾夫拉姆）职业 7（领主）等级 1 坐标 (13,9)
      expect(units[0].charId, 2);
      expect(units[0].classId, 7);
      expect(units[0].level, 1);
      expect(units[0].x, 13);
      expect(units[0].y, 9);
      expect(units[0].allegiance, Allegiance.player);
      // 第二个：角色 1（艾瑞珂）职业 2 坐标 (8,5)
      expect(units[1].charId, 1);
      expect(units[1].x, 8);
      expect(units[1].y, 5);
    });

    test('所有章节的我方单位都可读且坐标在合理范围', () {
      final up = UnitPlacement(_open('1692 -'));
      var total = 0;
      for (var ch = 0; ch < up.chapterCount; ch++) {
        for (final u in up.units(ch, UnitSlot.playerNormal)) {
          total++;
          expect(u.x, inInclusiveRange(0, 63), reason: 'ch$ch char${u.charId} x');
          expect(u.y, inInclusiveRange(0, 63), reason: 'ch$ch char${u.charId} y');
          expect(u.level, inInclusiveRange(0, 31));
        }
      }
      expect(total, greaterThan(100), reason: '全部章节合计我方单位应上百');
    });

    test('入口可用性按版本区分（遭遇 6 槽仅 FE8，红/蓝仅 FE6）', () {
      final fe8 = UnitPlacement(_open('1692 -'));
      for (final slot in UnitSlot.values) {
        expect(
          fe8.slotSupported(slot),
          slot.isFe6Units ? isFalse : isTrue,
          reason: 'FE8 ${slot.name}',
        );
      }
      final fe7 = UnitPlacement(_open('0979'));
      for (final slot in UnitSlot.values) {
        expect(
          fe7.slotSupported(slot),
          slot.isEncounter || slot.isFe6Units ? isFalse : isTrue,
          reason: 'FE7 ${slot.name}',
        );
      }
      final fe6 = UnitPlacement(_open('0378'));
      for (final slot in UnitSlot.values) {
        expect(
          fe6.slotSupported(slot),
          slot.isFe6Units ? isTrue : isFalse,
          reason: 'FE6 ${slot.name}',
        );
      }
    });

    test('FE8 遭遇槽：无遭遇的章为空，有遭遇的章敌军全阵营位=2', () {
      final up = UnitPlacement(_open('1692 -'));
      // 无遭遇战的章：六个槽全空
      for (final slot in UnitSlot.values) {
        if (slot.isEncounter) {
          expect(up.units(1, slot), isEmpty, reason: 'ch1 ${slot.name}');
        }
      }
      // 第 4 章（15×10 的沼泽地伏击）：遭遇敌 1 有 21 人、全敌军阵营
      final enemies = up.units(4, UnitSlot.encounterEnemy1);
      expect(enemies.length, 21, reason: 'ch4 遭遇敌方 1');
      for (final u in enemies) {
        expect(u.allegiance, Allegiance.enemy, reason: 'ch4 遭遇敌阵营');
        expect(u.x, inInclusiveRange(0, 32));
        expect(u.y, inInclusiveRange(0, 32));
      }
      expect(up.units(4, UnitSlot.encounterPlayer1).length, greaterThan(0));
      // 全部章节：非空遭遇槽的条目坐标都在地图内（防把无关数据读成单位）
      var total = 0;
      for (var ch = 0; ch < up.chapterCount; ch++) {
        for (final slot in UnitSlot.values) {
          if (!slot.isEncounter) continue;
          for (final u in up.units(ch, slot)) {
            total++;
            expect(u.x, inInclusiveRange(0, 32), reason: 'ch$ch ${slot.name} x');
            expect(u.y, inInclusiveRange(0, 32), reason: 'ch$ch ${slot.name} y');
          }
        }
      }
      expect(total, greaterThan(100), reason: '原版 12 章有遭遇配置，合计应上百');
      expect(up.emptyHint(UnitSlot.encounterEnemy1), contains('LOAD'));
    });

    test('我方单位坐标都在地图范围内（防越界数据混入）', () {
      final up = UnitPlacement(_open('1692 -'));
      for (var ch = 0; ch < up.chapterCount && ch < 20; ch++) {
        for (final slot in UnitSlot.values) {
          for (final u in up.units(ch, slot)) {
            expect(u.x, inInclusiveRange(0, 32), reason: 'ch$ch x');
            expect(u.y, inInclusiveRange(0, 32), reason: 'ch$ch y');
          }
        }
      }
    });
  });

  group('FE7 / FE6 布局', () {
    test('FE7J 条目大小为 16 且能读出我方', () {
      final up = UnitPlacement(_open('0979'));
      expect(up.entrySize, 16);
      final units = up.units(0, UnitSlot.playerNormal);
      expect(units, isNotEmpty);
      for (final u in units) {
        expect(u.isFe8, isFalse);
        expect(u.x, inInclusiveRange(0, 63));
        expect(u.y, inInclusiveRange(0, 63));
      }
    });

    test('FE7 道具/AI 偏移为 items@+8 ai@+12（P0 回归）', () {
      final edit = _open('0979');
      final up = UnitPlacement(edit);
      final u = up.units(0, UnitSlot.playerNormal)[0];
      expect(u.charId, 3);
      // 反编译 UnitDefinition（16 字节）：items[4]@+8、ai[4]@+12；
      // 旧实现按 FE8 布局（+12/+16）读，把 AI 读成了道具、越条目读出了头部。
      expect(u.items, [0x01, 0x6b, 0x6b, 0], reason: '铁剑+铁斧，与武器表 ID 对得上');
      expect(u.ai, [0, 0, 0, 0]);
      expect(up.setItem(u, 1, 0x21), isTrue);
      final reread = up.units(0, UnitSlot.playerNormal)[0];
      expect(reread.items, [0x01, 0x21, 0x6b, 0]);
      expect(reread.ai, [0, 0, 0, 0], reason: '写道具不能碰到 AI 段');
    });

    test('FE6 走红/蓝两路 ChapterEventInfo（chapterinfo.h 反编译）', () {
      final up = UnitPlacement(_open('0378'));
      // 下标 1 章：蓝方首组（BlueA，Eirilis/Lance）2 人，红方空组。
      // 注意：units_blue 指针指向的首组数组以 pid==0 结尾；紧接在后面的
      // 是 ROM 里相邻的其它命名组（BlueB/Lance），不属于本指针，不读。
      final blue = up.units(1, UnitSlot.blueUnits);
      expect(blue.length, 2);
      expect(blue.map((u) => u.charId).toList(), [0x01, 0x1f]);
      expect(blue[0].x, 1);
      expect(blue[0].y, 20);
      expect(blue[0].items, [0x0b, 0x68, 0, 0],
          reason: '与武器表 ID 对得上（圣剑 0x68）');
      expect(blue[0].ai, [0, 0, 0, 0],
          reason: 'AI 段在 +12，修复前会越条目读出下一条头部');
      expect(up.units(1, UnitSlot.redUnits), isEmpty, reason: '红方空组');
      // 下标 4 章：蓝方 14 人单组，全部坐标在 32×32 地图内
      final blue4 = up.units(4, UnitSlot.blueUnits);
      expect(blue4.length, 14);
      for (final u in blue4) {
        expect(u.x, inInclusiveRange(0, 32));
        expect(u.y, inInclusiveRange(0, 32));
      }
    });
  });

  group('写入', () {
    test('改坐标后可读回', () {
      final edit = _open('1692 -');
      final up = UnitPlacement(edit);
      final units = up.units(0, UnitSlot.playerNormal);
      final u = units[0];
      final ok = up.setPosition(u, 5, 7);
      expect(ok, isTrue);
      final reread = up.units(0, UnitSlot.playerNormal)[0];
      expect(reread.x, 5);
      expect(reread.y, 7);
      expect(edit.hasChanges, isTrue);
    });

    test('改等级不影响阵营，改阵营不影响等级', () {
      // 回归：这两个字段共用一个字节，整字节覆盖会互相清掉
      final edit = _open('1692 -');
      final up = UnitPlacement(edit);
      var u = up.units(0, UnitSlot.playerNormal)[0];

      expect(up.setLevel(u, 20), isTrue);
      u = up.units(0, UnitSlot.playerNormal)[0];
      expect(u.level, 20);
      expect(u.allegiance, Allegiance.player, reason: '改等级不该动阵营');

      expect(up.setAllegiance(u, Allegiance.enemy), isTrue);
      u = up.units(0, UnitSlot.playerNormal)[0];
      expect(u.allegiance, Allegiance.enemy);
      expect(u.level, 20, reason: '改阵营不该动等级');
    });

    test('改职业与道具后可读回', () {
      final edit = _open('1692 -');
      final up = UnitPlacement(edit);
      var u = up.units(0, UnitSlot.playerNormal)[0];
      expect(up.setClass(u, 15), isTrue);
      expect(up.setItem(u, 0, 0x21), isTrue);
      u = up.units(0, UnitSlot.playerNormal)[0];
      expect(u.classId, 15);
      expect(u.items[0], 0x21);
    });

    test('撤销全部修改后恢复原样', () {
      final edit = _open('1692 -');
      final up = UnitPlacement(edit);
      final before = up.units(0, UnitSlot.playerNormal).first;
      up.setPosition(before, 1, 2);
      up.setLevel(up.units(0, UnitSlot.playerNormal).first, 9);
      edit.revertAll();
      final after = up.units(0, UnitSlot.playerNormal).first;
      expect(after.x, before.x);
      expect(after.y, before.y);
      expect(after.level, before.level);
    });

    test('坐标越界被拒绝', () {
      final edit = _open('1692 -');
      final up = UnitPlacement(edit);
      final u = up.units(0, UnitSlot.playerNormal)[0];
      expect(up.setPosition(u, 64, 0), isFalse);
      expect(up.setPosition(u, -1, 0), isFalse);
    });
  });

  group('章节单位角色字段是 1 基 number', () {
    // 回归：`UnitDefinition::pid` 是单位表 `number`（= 表内索引 + 1），
    // 而 `unitDisplayName(index)` 要的是表内索引。直接拿 pid 当下标查名字
    // 会让所有人整体偏一位（FE7 第 0 章第一个人显示成雷万而不是琳）。
    // 职业 ID（+1）本身就是 0 基索引，所以职业显示一直是正常的。
    test('FE7J 第 0 章首人是琳，且与职业 ID 自洽', () {
      final edit = _open('0979');
      final rom = edit.rom;
      final up = UnitPlacement(edit);
      final u = up.units(0, UnitSlot.playerNormal).first;
      expect(u.charId, 3);
      // pid 3 → 表内索引 2 → 琳；pid 本身当下标会解出索引 3 = 雷万
      expect(rom.unitName(3), 'レイヴァン');
      expect(rom.unitDisplayName(u.unitIndex), 'リン');
      // 自洽：该角色的默认职业必须等于条目里的 classId（classId 是 0 基索引）
      final at = rom.unitBase + u.unitIndex * rom.table.unitDataSize;
      expect(u.classId, rom.data[at + 5]);
    });

    test('FE8J 首章两人名字与职业都对得上', () {
      final edit = _open('1692 -');
      final rom = edit.rom;
      final up = UnitPlacement(edit);
      final us = up.units(0, UnitSlot.playerNormal);
      expect(us.map((u) => rom.unitDisplayName(u.unitIndex)).toList(),
          ['ゼト', 'エイリーク']);
      for (final u in us) {
        final at = rom.unitBase + u.unitIndex * rom.table.unitDataSize;
        expect(u.classId, rom.data[at + 5]);
      }
    });

    test('FE6 蓝方单位名字与职业 ID 自洽', () {
      final edit = _open('0378');
      final rom = edit.rom;
      final up = UnitPlacement(edit);
      final us = up.units(2, UnitSlot.blueUnits);
      expect(us, isNotEmpty);
      for (final u in us) {
        final at = rom.unitBase + u.unitIndex * rom.table.unitDataSize;
        expect(u.classId, rom.data[at + 5]);
      }
    });
  });

  group('152 字节章节条目的 event plist 字段在 +120', () {
    // 回归：FE7U 条目比 FE7J/FE8 的 148 字节多一对 u16，事件 plist 索引
    // 随之从 +116 后移到 +120。按 +116 读拿到的是 palette 索引，
    // 事件组指到图形数据上，章节单位整体读错（TLP 同为 152 字节条目）。
    test('FE7U 每章事件组都指向合法结构', () {
      final edit = _open('1235');
      final up = UnitPlacement(edit);
      expect(up.chapterCount, greaterThan(100));
      // 只看前 40 章：后续章（对战/教程）的事件组不完整，不能当样本
      var ok = 0;
      for (var ch = 0; ch < 40; ch++) {
        final ev = up.eventGroupOffset(ch);
        if (ev <= 0) continue;
        var ptrs = 0;
        for (var k = 0; k < 20; k++) {
          final v = FeRom.u32(edit.rom.data, ev + 4 * k);
          if (v == 0 || FeRom.isPointer(v, edit.rom.length)) ptrs++;
        }
        if (ptrs >= 14) ok++;
      }
      expect(ok, 40, reason: '152 字节条目必须读 +120 才能命中事件组');
    });

    test('FE7U 第 0 章读出琳（pid 3）且坐标在地图内', () {
      final edit = _open('1235');
      final up = UnitPlacement(edit);
      final us = up.units(0, UnitSlot.playerNormal);
      expect(us, isNotEmpty);
      expect(us.first.charId, 3);
      expect(us.first.items.first, 0x01, reason: '武器表 ID 对得上');
      for (final u in us) {
        expect(u.x, inInclusiveRange(0, 32));
        expect(u.y, inInclusiveRange(0, 32));
      }
    });

    test('TLP v1.5（152 字节条目 + 表搬到扩展区）也能读出章节单位', () {
      final edit = _open('The Last Promise');
      final up = UnitPlacement(edit);
      expect(up.chapterCount, greaterThan(50));
      final us = up.units(2, UnitSlot.playerNormal);
      expect(us, isNotEmpty, reason: '第 2 章有 3 人出场');
      for (final u in us) {
        expect(u.charId, lessThanOrEqualTo(edit.rom.unitCount));
        expect(u.classId, lessThanOrEqualTo(edit.rom.classCount));
        expect(u.x, inInclusiveRange(0, 32));
        expect(u.y, inInclusiveRange(0, 32));
      }
    });
  });
}
