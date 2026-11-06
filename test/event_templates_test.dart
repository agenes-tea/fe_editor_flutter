import 'dart:io';

import 'package:fe_editor/core/chapter_events.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/event_templates.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/unit_placement.dart';
import 'package:flutter_test/flutter_test.dart';

import 'rom_paths.dart';

const dir = romDir;
const fe6jp = '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe7us = '$dir/1235 - 火炎之纹章-烈火之剑 Fire Emblem(US)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

EditableRom open(String path) {
  final data = File(path).readAsBytesSync();
  return EditableRom.open(data, FeRom.detectTable(data)!);
}

/// 读事件组里回合列表当前的条目数（用来确认真的多了一条）。
int turnEventCount(EditableRom edit, int chapter) {
  final up = UnitPlacement(edit);
  final ev = up.eventGroupOffset(chapter);
  if (ev <= 0) return -1;
  return ChapterEvents(edit.liveRom).readList(ev, 0x00, EventTriggerKind.turn).length;
}

void main() {
  group('事件模板：回合增援', () {
    test('FE8J 追加一条增援后，条目数与单位都能读出来', () async {
      final edit = open(fe8jp);
      final before = turnEventCount(edit, 3);
      expect(before, greaterThan(0), reason: '第 3 章本来就有回合事件');

      final out = EventTemplates(edit).addReinforcement(
        chapter: 3,
        turn: 7,
        units: [
          const ReinforcementUnit(
            charId: 50, classId: 5, level: 10, x: 5, y: 6, allegiance: 2,
          ),
        ],
      );
      expect(out.ok, isTrue, reason: out.message);
      expect(out.result, EventTemplateResult.applied);
      expect(out.scriptOffset, greaterThan(0));
      expect(out.unitArrayOffset, greaterThan(0));

      // 条目数 +1
      expect(turnEventCount(edit, 3), before + 1);

      // 新条目可被解析出「第 7 回合起」
      final up = UnitPlacement(edit);
      final ev = up.eventGroupOffset(3);
      final list = ChapterEvents(edit.liveRom)
          .readList(ev, 0x00, EventTriggerKind.turn);
      final added = list.last;
      expect(added.condition, contains('7'));

      // 新条目加载出的单位就是刚写进去的那个
      final loaded = ChapterEvents(edit.liveRom).loadedUnits(added.script);
      expect(loaded, hasLength(1));
      expect(loaded.first.charId, 50);
      expect(loaded.first.classId, 5);
      expect(loaded.first.level, 10);
      expect(loaded.first.x, 5);
      expect(loaded.first.y, 6);
      expect(loaded.first.allegiance, 2);
    });

    test('旧条目原样保留（只追加不动既有脚本）', () async {
      final edit = open(fe8jp);
      final up = UnitPlacement(edit);
      final ev = up.eventGroupOffset(3);
      final before = ChapterEvents(edit.liveRom)
          .readList(ev, 0x00, EventTriggerKind.turn)
          .map((e) => '${e.check}/${e.script}/${e.value}')
          .toList();

      expect(
        EventTemplates(edit).addReinforcement(
          chapter: 3,
          turn: 7,
          units: [
            const ReinforcementUnit(
              charId: 50, classId: 5, level: 10, x: 5, y: 6, allegiance: 2),
          ],
        ).ok,
        isTrue,
      );

      final after = ChapterEvents(edit.liveRom)
          .readList(ev, 0x00, EventTriggerKind.turn)
          .map((e) => '${e.check}/${e.script}/${e.value}')
          .toList();
      expect(after.sublist(0, before.length), before,
          reason: '旧条目的 check/script/value 必须逐字不变');
    });

    test('FE7J / FE7U / FE6 三种方言都能追加并解析回来', () async {
      for (final path in [fe7jp, fe7us, fe6jp]) {
        final edit = open(path);
        final id = edit.rom.table.id;
        final chapter = 3;
        final before = turnEventCount(edit, chapter);
        expect(before, greaterThanOrEqualTo(0), reason: '$id 第 3 章应可读');

        final out = EventTemplates(edit).addReinforcement(
          chapter: chapter,
          turn: 4,
          units: [
            const ReinforcementUnit(
              charId: 30, classId: 3, level: 8, x: 4, y: 5, allegiance: 2),
          ],
        );
        expect(out.ok, isTrue, reason: '$id: ${out.message}');
        expect(turnEventCount(edit, chapter), before + 1, reason: id);

        final up = UnitPlacement(edit);
        final ev = up.eventGroupOffset(chapter);
        final list = ChapterEvents(edit.liveRom)
            .readList(ev, 0x00, EventTriggerKind.turn);
        final loaded =
            ChapterEvents(edit.liveRom).loadedUnits(list.last.script);
        expect(loaded, hasLength(1), reason: '$id 应解析出 1 个单位');
        expect(loaded.first.charId, 30, reason: id);
        expect(loaded.first.x, 4, reason: id);
        expect(loaded.first.y, 5, reason: id);
      }
    });

    test('坐标超出本章地图会被拒绝，且不写 ROM', () async {
      final edit = open(fe8jp);
      final out = EventTemplates(edit).addReinforcement(
        chapter: 3,
        turn: 7,
        units: [
          const ReinforcementUnit(
            charId: 50, classId: 5, level: 10, x: 250, y: 6, allegiance: 2),
        ],
      );
      expect(out.result, EventTemplateResult.badArguments);
      expect(out.message, contains('地图'));
      expect(edit.hasChanges, isFalse);
    });

    test('角色 ID 0（不是 1 基）会被拒绝', () async {
      final edit = open(fe8jp);
      final out = EventTemplates(edit).addReinforcement(
        chapter: 3,
        turn: 7,
        units: [
          const ReinforcementUnit(
            charId: 0, classId: 5, level: 10, x: 5, y: 6, allegiance: 2),
        ],
      );
      expect(out.result, EventTemplateResult.badArguments);
      expect(out.message, contains('1 基'));
    });

    test('回合数 0 会被拒绝', () async {
      final edit = open(fe8jp);
      final out = EventTemplates(edit).addReinforcement(
        chapter: 3,
        turn: 0,
        units: [
          const ReinforcementUnit(
            charId: 50, classId: 5, level: 10, x: 5, y: 6, allegiance: 2),
        ],
      );
      expect(out.result, EventTemplateResult.badArguments);
    });

    test('连续追加两次互不干扰（第二次建在第一次的指针之上）', () async {
      final edit = open(fe8jp);
      final before = turnEventCount(edit, 3);
      final t = EventTemplates(edit);
      final a = t.addReinforcement(
        chapter: 3,
        turn: 5,
        units: [
          const ReinforcementUnit(
            charId: 40, classId: 4, level: 9, x: 3, y: 3, allegiance: 2),
        ],
      );
      final b = t.addReinforcement(
        chapter: 3,
        turn: 9,
        units: [
          const ReinforcementUnit(
            charId: 41, classId: 4, level: 11, x: 6, y: 2, allegiance: 2),
        ],
      );
      expect(a.ok && b.ok, isTrue, reason: '${a.message} / ${b.message}');
      expect(turnEventCount(edit, 3), before + 2);
      // 两次的脚本必须落在不同位置
      expect(a.scriptOffset, isNot(b.scriptOffset));
      expect(a.unitArrayOffset, isNot(b.unitArrayOffset));

      final up = UnitPlacement(edit);
      final ev = up.eventGroupOffset(3);
      final list = ChapterEvents(edit.liveRom)
          .readList(ev, 0x00, EventTriggerKind.turn);
      final units1 = ChapterEvents(edit.liveRom).loadedUnits(list[list.length - 2].script);
      final units2 = ChapterEvents(edit.liveRom).loadedUnits(list.last.script);
      expect(units1.single.charId, 40);
      expect(units2.single.charId, 41);
    });

    test('多个单位一起写入，顺序与坐标都对', () async {
      final edit = open(fe8jp);
      final out = EventTemplates(edit).addReinforcement(
        chapter: 3,
        turn: 6,
        units: const [
          ReinforcementUnit(charId: 10, classId: 2, level: 5, x: 1, y: 1, allegiance: 2),
          ReinforcementUnit(charId: 11, classId: 2, level: 6, x: 2, y: 2, allegiance: 2),
          ReinforcementUnit(charId: 12, classId: 2, level: 7, x: 3, y: 3, allegiance: 1),
        ],
      );
      expect(out.ok, isTrue, reason: out.message);
      final up = UnitPlacement(edit);
      final ev = up.eventGroupOffset(3);
      final list = ChapterEvents(edit.liveRom)
          .readList(ev, 0x00, EventTriggerKind.turn);
      final loaded = ChapterEvents(edit.liveRom).loadedUnits(list.last.script);
      expect(loaded.map((u) => u.charId).toList(), [10, 11, 12]);
      expect(loaded.map((u) => u.allegiance).toList(), [2, 2, 1]);
      expect(loaded.map((u) => u.x).toList(), [1, 2, 3]);
    });

    test('撤销后完全回到原样', () async {
      final edit = open(fe8jp);
      final before = turnEventCount(edit, 3);
      EventTemplates(edit).addReinforcement(
        chapter: 3,
        turn: 7,
        units: [
          const ReinforcementUnit(
            charId: 50, classId: 5, level: 10, x: 5, y: 6, allegiance: 2),
        ],
      );
      expect(turnEventCount(edit, 3), before + 1);
      edit.revertAll();
      expect(turnEventCount(edit, 3), before);
      expect(edit.hasChanges, isFalse);
    });

    test('地图写回不相关：改动只落在空位与事件组指针上', () async {
      final edit = open(fe8jp);
      final up = UnitPlacement(edit);
      final groupSlot = up.eventGroupOffset(3) + 0x00;
      final before = FeRom.u32(edit.buffer.data, groupSlot);
      final out = EventTemplates(edit).addReinforcement(
        chapter: 3,
        turn: 7,
        units: [
          const ReinforcementUnit(
            charId: 50, classId: 5, level: 10, x: 5, y: 6, allegiance: 2),
        ],
      );
      expect(out.ok, isTrue);
      final after = FeRom.u32(edit.buffer.data, groupSlot);
      expect(after, isNot(before), reason: '列表指针应该被重指');
      expect(FeRom.toOffset(after), out.listOffset);
    });
  });
}
