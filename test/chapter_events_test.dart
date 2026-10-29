import 'dart:io';
import 'dart:typed_data';

import 'package:fe_editor/core/chapter_events.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/map_reader.dart';
import 'package:fe_editor/core/unit_placement.dart';
import 'package:flutter_test/flutter_test.dart';

Directory get _romDir => Directory('${Platform.environment['HOME']}/workspace/game-rom');

EditableRom _open(String keyword) {
  final f = _romDir
      .listSync()
      .whereType<File>()
      .firstWhere((e) => e.path.contains(keyword));
  final data = Uint8List.fromList(f.readAsBytesSync());
  return EditableRom.open(data, FeRom.detectTable(data)!);
}

/// 某章去重后的剧情增援（同一个单位数组常被多个事件引用）。
List<LoadedUnit> _chapterUnits(
    ChapterEvents ce, UnitPlacement up, int chapter) {
  final ev = up.eventGroupOffset(chapter);
  if (ev <= 0) return const [];
  final seen = <int>{};
  final out = <LoadedUnit>[];
  for (final e in ce.all(ev)) {
    for (final u in ce.loadedUnits(e.script)) {
      if (seen.add(u.addr)) out.add(u);
    }
  }
  return out;
}

/// 逐章统计：有增援的章数、去重后单位数、越界坐标数。
({int chapters, int units, int outOfMap}) _scanRom(EditableRom edit) {
  final up = UnitPlacement(edit);
  final ce = ChapterEvents(edit.rom);
  final map = MapReader(edit.rom);
  var chapters = 0;
  var units = 0;
  var outOfMap = 0;
  for (var ch = 0; ch < up.chapterCount; ch++) {
    final list = _chapterUnits(ce, up, ch);
    if (list.isEmpty) continue;
    chapters++;
    units += list.length;
    final info = map.available ? map.chapterMap(ch) : null;
    if (info == null) continue;
    outOfMap += list
        .where((u) => u.x >= info.width || u.y >= info.height)
        .length;
  }
  return (chapters: chapters, units: units, outOfMap: outOfMap);
}

void main() {
  group('章节事件：触发条件', () {
    test('FE8J 第 0 章回合事件读出「第 N 回合起」', () {
      final edit = _open('1692 -');
      final up = UnitPlacement(edit);
      final ce = ChapterEvents(edit.rom);
      final ev = up.eventGroupOffset(0);
      expect(ev, greaterThan(0));

      final events = ce.all(ev);
      expect(events, isNotEmpty);
      final turns = events.where((e) => e.kind == EventTriggerKind.turn);
      expect(turns.length, 4, reason: '第 0 章有 4 条回合事件');
      // 反编译 Prologue 的 Turn1/2/3 与「第 4 回合起」的常规触发
      expect(turns.map((e) => e.condition).toList(),
          containsAll(<String>['第 1 回合起', '第 2 回合起', '第 3 回合起']));
      for (final e in events) {
        expect(FeRom.isPointer(e.script, edit.rom.length), isTrue,
            reason: '每个事件的执行脚本都必须是合法指针');
      }
    });

    test('所有版本的事件脚本指针都合法（不会把数据当事件）', () {
      for (final kw in ['1692 -', '1235', '0979', 'The Last Promise', '0378 -']) {
        final edit = _open(kw);
        final up = UnitPlacement(edit);
        final ce = ChapterEvents(edit.rom);
        var checked = 0;
        for (var ch = 0; ch < up.chapterCount && ch < 20; ch++) {
          final ev = up.eventGroupOffset(ch);
          if (ev <= 0) continue;
          for (final e in ce.all(ev)) {
            expect(FeRom.isPointer(e.script, edit.rom.length), isTrue,
                reason: '$kw ch$ch');
            checked++;
          }
        }
        expect(checked, greaterThan(0), reason: '$kw 应该能读出事件');
      }
    });

    test('FE7U 的 loc 列表不被头部垃圾撑大', () {
      final edit = _open('1235');
      final up = UnitPlacement(edit);
      final ce = ChapterEvents(edit.rom);
      final events = ce.all(up.eventGroupOffset(0));
      // 修复前 loc 列表按 16 字节读会解出 38 条、混入大量非事件数据；
      // 现在 FE7 每章 10..25 条（第 0 章 21 条）
      expect(events.length, inInclusiveRange(5, 60));
    });

    test('FE6 的事件组走 ChapterEventInfo（不是 FE7/FE8 的事件 plist）', () {
      final edit = _open('0378 -');
      final up = UnitPlacement(edit);
      final ce = ChapterEvents(edit.rom);
      final ex = _open('1692 -');
      // FE6 的 ChapterEventInfo 只有 0x1C 字节（4 个列表 + 红/蓝 + 过关脚本）
      final ev = up.eventGroupOffset(0);
      expect(ev, greaterThan(0));
      final events = ce.all(ev);
      expect(events.length, 10, reason: '第 0 章 10 条事件');
      // 旧实现按事件 plist 定位 FE6 → 第 1 章读出 50 条「地点事件」、第 5 章 84 条，
      // script 指到图形数据；现在第 0/1/5 章分别是 10/8/13 条，全 ROM 最多 46 条。
      expect([for (final ch in [0, 1, 5]) ce.all(up.eventGroupOffset(ch)).length],
          [10, 8, 13]);
      for (var ch = 0; ch < up.chapterCount; ch++) {
        final ev2 = up.eventGroupOffset(ch);
        if (ev2 <= 0) continue;
        expect(ce.all(ev2).length, lessThanOrEqualTo(50), reason: 'FE6 ch$ch');
      }
      expect(ex.rom.table.id, 'FE8J'); // 仅为确保两个仓库都打开成功
    });
  });

  group('章节事件：脚本方言与 LOAD 命令定位', () {
    test('FE6/FE7 的命令表（{函数指针,字数} 8 字节/项）定位与命令数', () {
      final cases = <String, ({int offset, int count, Set<int> ids})>{
        '0378 -': (offset: 0x5c4164, count: 100, ids: {0x12, 0x13}),
        '1235': (offset: 0xb90e48, count: 232, ids: {0x32, 0x33}),
        '0979': (offset: 0xc00038, count: 236, ids: {0x30, 0x31}),
      };
      cases.forEach((kw, want) {
        final edit = _open(kw);
        final ce = ChapterEvents(edit.rom);
        final table = ce.commandTable();
        expect(table, isNotNull, reason: kw);
        expect(table!.offset, want.offset, reason: kw);
        expect(table.count, want.count, reason: kw);
        // EVT_CMD_END 只占命令字本身
        expect(ce.commandSize(table, 0), 1, reason: kw);
        // LOADUNIT / LOADUNITS 由反汇编处理函数的签名反推（各作编号不同）
        expect(ce.loadCommandIds, want.ids, reason: kw);
      });
    });

    test('FE8 的 LOADUNIT 命令号是 0x2C（自带长度字段）', () {
      for (final kw in ['1692 -', '1692X', '火焰之纹章-铠甲的呼唤']) {
        final edit = _open(kw);
        expect(ChapterEvents(edit.rom).loadCommandIds, {0x2C}, reason: kw);
        // FE8 不需要命令表
        expect(ChapterEvents(edit.rom).commandTable(), isNull, reason: kw);
      }
    });

    test('FE8 的 CALL -1 走事件槽 2（第 0 章顶层脚本本身没有 LOADUNIT）', () {
      final edit = _open('1692 -');
      final ce = ChapterEvents(edit.rom);
      // 0x8a6134c: SVAL 槽 2 = 0x8a611dc；CALL 0x8a601f8；CALL -1 → 槽 2
      final cmds = ce.loadUnits(0x8a6134c);
      expect(cmds, isNotEmpty);
      expect(cmds.first.unitArray, 0x089081d8);
      expect(cmds.first.restriction, 1, reason: 'EvtLoadUnit1 的 restriction 参数');
      expect(ce.loadedUnits(0x8a6134c), isNotEmpty);
    });

    test('FE8 的步进按 16 位半字计（len=4 → 8 字节）', () {
      final edit = _open('1692 -');
      final ce = ChapterEvents(edit.rom);
      // 0x8a611dc 第一条就是 LOADUNIT：00012c40 | 089081d8，紧接 00003020
      final cmds = ce.loadUnits(0x8a611dc);
      expect(cmds.map((c) => c.addr).toList(), [0xa611dc]);
    });
  });

  group('章节事件：FE8 剧情增援', () {
    test('第 0 章逐字段（3 个敌人，坐标与职业与地图一致）', () {
      final edit = _open('1692 -');
      final up = UnitPlacement(edit);
      final ce = ChapterEvents(edit.rom);
      final units = _chapterUnits(ce, up, 0);
      expect(units.length, 3);
      expect(
          units.map((u) => '${u.charId}/${u.classId}/${u.level}/'
              '${u.allegiance}@(${u.x},${u.y})/${u.items.first}'),
          ['104/63/4/2@(14,8)/31', '130/63/1/2@(14,7)/31', '128/63/2/2@(14,7)/31']);
    });

    test('有增援的章节数与单位总数（旧实现只解出 16 章）', () {
      final stat = _scanRom(_open('1692 -'));
      expect(stat.chapters, inInclusiveRange(45, 60));
      expect(stat.units, greaterThan(500));
      expect(stat.outOfMap, 0, reason: '全部单位都应落在本章地图内');
    });

    test('FE8U 改版同样能读出（铠甲的呼唤）', () {
      final stat = _scanRom(_open('火焰之纹章-铠甲的呼唤'));
      expect(stat.chapters, greaterThan(40));
      expect(stat.units, greaterThan(500));
    });
  });

  group('章节事件：FE7 剧情增援', () {
    test('FE7U 第 0 章逐字段（2 名山贼 + 琳）', () {
      final edit = _open('1235');
      final up = UnitPlacement(edit);
      final ce = ChapterEvents(edit.rom);
      final units = _chapterUnits(ce, up, 0);
      expect(units.map((u) => '${u.charId}/${u.classId}/${u.level}/'
          '${u.allegiance}@(${u.x},${u.y})').toList(), [
        '135/57/2/2@(3,2)',
        '136/57/1/2@(2,6)',
        '3/2/1/0@(14,9)',
      ]);
      // 琳的道具：铁剑 + 两个「物品」占位
      expect(units.last.items, [1, 107, 107, 0]);
    });

    test('FE7J 与 FE7U 第 0 章增援完全一致（跨版本互证）', () {
      String sig(String kw) {
        final edit = _open(kw);
        return _chapterUnits(
                ChapterEvents(edit.rom), UnitPlacement(edit), 0)
            .map((u) => '${u.charId}/${u.classId}/${u.level}/'
                '${u.allegiance}@(${u.x},${u.y})/${u.items.join(",")}')
            .join('|');
      }

      expect(sig('0979'), sig('1235'));
    });

    test('FE7U/FE7J 有增援的章节数（旧实现为 0）', () {
      for (final kw in ['1235', '0979']) {
        final stat = _scanRom(_open(kw));
        expect(stat.chapters, greaterThan(70), reason: kw);
        expect(stat.units, greaterThan(1500), reason: kw);
        // 少量单位来自共用脚本引用的下一章单位组（会标「图外」），不超过 10%
        expect(stat.outOfMap * 10, lessThan(stat.units), reason: kw);
      }
    });

    test('FE7U 改版（佣兵公司）命令表与命令号不变', () {
      final edit = _open('佣兵公司');
      final ce = ChapterEvents(edit.rom);
      expect(ce.commandTable()!.count, 232);
      expect(ce.loadCommandIds, {0x32, 0x33});
      expect(_scanRom(edit).chapters, greaterThan(60));
    });

    test('The Last Promise（表在扩展区）也能读出增援', () {
      final edit = _open('The Last Promise');
      final ce = ChapterEvents(edit.rom);
      expect(ce.loadCommandIds, {0x32, 0x33});
      final units = _chapterUnits(ce, UnitPlacement(edit), 0);
      expect(units.map((u) => '${u.charId}/${u.classId}').toList(),
          ['78/66', '3/7', '24/1']);
    });
  });

  group('章节事件：FE6 剧情增援', () {
    test('第 0 章：10 条事件、8 名增援、含敌方与自军', () {
      final edit = _open('0378 -');
      final up = UnitPlacement(edit);
      final ce = ChapterEvents(edit.rom);
      final units = _chapterUnits(ce, up, 0);
      expect(units.length, 8);
      expect(units.map((u) => u.charId).toSet(), {208, 209, 210, 1, 13, 38});
      expect(units.where((u) => u.allegiance == 2).length, 5);
      expect(units.where((u) => u.allegiance == 0).length, 3);
      // 罗伊（单位表 `number` 1）带铁剑
      final roy = units.firstWhere((u) => u.charId == 1);
      expect(roy.items, [11, 1, 0, 0]);
    });

    test('FE6 全章增援坐标都在地图内（旧实现 100 个越界）', () {
      for (final kw in ['0378 -', '封印之剑[狼组']) {
        final stat = _scanRom(_open(kw));
        expect(stat.chapters, greaterThan(40), reason: kw);
        expect(stat.units, greaterThan(1000), reason: kw);
        expect(stat.outOfMap, 0, reason: kw);
      }
    });
  });

  group('章节事件：结构校验不过就降级为空', () {
    test('每个版本解出的单位字段都在表范围内', () {
      for (final kw in ['1692 -', '1235', '0979', '0378 -', 'The Last Promise']) {
        final edit = _open(kw);
        final up = UnitPlacement(edit);
        final ce = ChapterEvents(edit.rom);
        for (var ch = 0; ch < up.chapterCount; ch++) {
          for (final u in _chapterUnits(ce, up, ch)) {
            expect(u.charId, inInclusiveRange(1, edit.rom.unitCount),
                reason: '$kw ch$ch');
            expect(u.classId, lessThan(edit.rom.classCount),
                reason: '$kw ch$ch');
            expect(u.level, inInclusiveRange(0, 31), reason: '$kw ch$ch');
            expect(u.allegiance, inInclusiveRange(0, 3), reason: '$kw ch$ch');
            expect(u.x, inInclusiveRange(0, 32), reason: '$kw ch$ch');
            expect(u.y, inInclusiveRange(0, 32), reason: '$kw ch$ch');
            for (final it in u.items) {
              expect(it == 0 || it < edit.rom.itemCount, isTrue,
                  reason: '$kw ch$ch item=$it');
            }
          }
        }
      }
    });

    test('不是单位数组的指针整组丢弃', () {
      final edit = _open('1692 -');
      final ce = ChapterEvents(edit.rom);
      // 图形数据 / 事件列表本身：pid 或坐标不合理 → 空
      expect(ce.loadedUnits(0), isEmpty);
      expect(ce.loadedUnits(0x081081D8), isEmpty);
      // 指向单位表本体（不是 UnitDefinition 数组）也读不出合法组
      expect(ce.loadedUnits(0x08582BC), isEmpty);
    });

    test('没有命令表时 FE7/FE6 返回空列表而不是乱读', () {
      final edit = _open('1692 -');
      // FE8 走自带长度的那条路，命令表为 null
      final ce = ChapterEvents(edit.rom);
      expect(ce.commandTable(), isNull);
      expect(ce.loadUnits(0), isEmpty);
    });
  });
}
