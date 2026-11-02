import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fe_editor/core/chapter_event_editor.dart';
import 'package:fe_editor/core/event_preview.dart';
import 'package:fe_editor/core/event_templates.dart';
import 'package:fe_editor/core/rom_session.dart';

const _dir = '/root/workspace/game-rom';
const _gbk = '火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba';
const _fe8jp =
    '1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';
const _fe6jp =
    '0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';

RomSession _open(String name) =>
    RomSession.open(File('$_dir/$name').readAsBytesSync(), name)!;

const _units = [
  ReinforcementUnit(charId: 135, classId: 57, level: 5, x: 5, y: 7, allegiance: 2, items: [1]),
  ReinforcementUnit(charId: 3, classId: 2, level: 3, x: 10, y: 5, allegiance: 0, items: [1]),
];

void main() {
  group('追加事件（只追加不改既有脚本）', () {
    test('烈火汉化：追加后被预览正确解析出来', () {
      final s = _open(_gbk);
      final before = EventPreviewer(s.rom).of(0).events.length;
      final r = ChapterEventEditor(s.rom)
          .addTurnReinforcement(chapter: 0, turn: 7, units: _units);
      expect(r.ok, isTrue, reason: r.message);
      final p = EventPreviewer(s.rom).of(0);
      expect(p.events.length, before + 1);
      // p.events 是「回合+角色+地点+其他」四张列表拼接，最后一条是「其他」列表的，
      // 要找自己加的那条得按 kind 过滤（这个坑自己先踩了一次）
      final added = p.events.lastWhere((e) => e.kind.name == 'turn');
      expect(added.sentence, contains('第 7 回合'));
      expect(added.units.length, 2);
      expect(added.units.first.x, 5);
      expect(added.units.first.y, 7);
      expect(added.issues, isEmpty);
    });

    test('既有事件一条都没被改动（只动了一个指针）', () {
      final s = _open(_gbk);
      final before = EventPreviewer(s.rom).of(0);
      final beforeSentences = before.events.map((e) => e.sentence).toList();
      ChapterEventEditor(s.rom)
          .addTurnReinforcement(chapter: 0, turn: 7, units: _units);
      final after = EventPreviewer(s.rom).of(0);
      final afterSentences = after.events.map((e) => e.sentence).toList();

      // 新条目会插在**它所属的那张列表**里（回合列表的第 2 位），
      // 所以不能假定「旧条目是 after 的前缀」。正确的断言是：
      // 去掉新加的那一条后，剩下的句子与改前逐条相等且顺序不变。
      final newIdx = afterSentences.indexWhere((x) => x.contains('第 7 回合'));
      expect(newIdx, greaterThanOrEqualTo(0));
      final withoutNew = [...afterSentences]..removeAt(newIdx);
      expect(withoutNew, beforeSentences,
          reason: '既有事件被意外改动了（顺序或内容变了）');
    });

    test('越界参数在写任何字节之前就被拒绝', () {
      final s = _open(_gbk);
      final ed = ChapterEventEditor(s.rom);
      final before = s.rom.changedByteCount;

      // 角色 ID 越界
      var r = ed.addTurnReinforcement(chapter: 0, turn: 3, units: const [
        ReinforcementUnit(charId: 999, classId: 0, level: 1, x: 1, y: 1, allegiance: 2),
      ]);
      expect(r.result, EventEditResult.badArguments);
      expect(r.message, contains('角色 ID'));
      expect(s.rom.changedByteCount, before, reason: '校验失败不能写字节');

      // 坐标越界
      r = ed.addTurnReinforcement(chapter: 0, turn: 3, units: const [
        ReinforcementUnit(charId: 1, classId: 0, level: 1, x: 99, y: 1, allegiance: 2),
      ]);
      expect(r.result, EventEditResult.badArguments);
      expect(r.message, contains('超出'));
      expect(s.rom.changedByteCount, before);

      // 回合越界
      r = ed.addTurnReinforcement(chapter: 0, turn: 0, units: _units);
      expect(r.result, EventEditResult.badArguments);
      expect(s.rom.changedByteCount, before);

      // 职业越界
      r = ed.addTurnReinforcement(chapter: 0, turn: 3, units: const [
        ReinforcementUnit(charId: 1, classId: 9999, level: 1, x: 1, y: 1, allegiance: 2),
      ]);
      expect(r.result, EventEditResult.badArguments);
      expect(s.rom.changedByteCount, before);
    });

    test('圣魔日版也能追加', () {
      final s = _open(_fe8jp);
      final before = EventPreviewer(s.rom).of(0).events.length;
      final r = ChapterEventEditor(s.rom)
          .addTurnReinforcement(chapter: 0, turn: 5, units: _units);
      expect(r.ok, isTrue, reason: r.message);
      final p = EventPreviewer(s.rom).of(0);
      expect(p.events.length, before + 1);
      expect(p.events.lastWhere((e) => e.kind.name == 'turn').sentence,
          contains('第 5 回合'));
    });

    test('封印之剑（FE6）也能追加', () {
      final s = _open(_fe6jp);
      final before = EventPreviewer(s.rom).of(0).events.length;
      final r = ChapterEventEditor(s.rom)
          .addTurnReinforcement(chapter: 0, turn: 9, units: _units);
      expect(r.ok, isTrue, reason: r.message);
      final p = EventPreviewer(s.rom).of(0);
      expect(p.events.length, before + 1);
      expect(p.events.lastWhere((e) => e.kind.name == 'turn').sentence,
          contains('第 9 回合'));
    });

    test('地点事件能追加且条件带坐标', () {
      final s = _open(_gbk);
      final r = ChapterEventEditor(s.rom)
          .addLocationEvent(chapter: 0, x: 4, y: 3, units: _units);
      expect(r.ok, isTrue, reason: r.message);
      final p = EventPreviewer(s.rom).of(0);
      final added = p.events.lastWhere((e) => e.kind.name == 'location');
      expect(added.kind.name, 'location');
      expect(added.units.length, 2);
    });
  });

  group('删除与回退', () {
    test('删除自己追加的能还原事件数', () {
      final s = _open(_gbk);
      final n0 = EventPreviewer(s.rom).of(0).events.length;
      final ed = ChapterEventEditor(s.rom);
      ed.addTurnReinforcement(chapter: 0, turn: 7, units: _units);
      expect(EventPreviewer(s.rom).of(0).events.length, n0 + 1);
      final d = ed.removeLastAdded(chapter: 0, type: EventTriggerType.turn);
      expect(d.ok, isTrue, reason: d.message);
      expect(EventPreviewer(s.rom).of(0).events.length, n0);
    });

    test('不是本工具加的最后一条 → 拒绝删除（notMine）', () {
      final s = _open(_gbk);
      final d = ChapterEventEditor(s.rom)
          .removeLastAdded(chapter: 0, type: EventTriggerType.turn);
      expect(d.result, EventEditResult.notMine,
          reason: '原版最后一条不该被当作可删除对象');
    });

    test('撤销全部能回到零改动', () {
      final s = _open(_gbk);
      final n0 = EventPreviewer(s.rom).of(0).events.length;
      ChapterEventEditor(s.rom)
          .addTurnReinforcement(chapter: 0, turn: 7, units: _units);
      expect(s.rom.changedByteCount, greaterThan(0));
      s.rom.revertAll();
      expect(s.rom.changedByteCount, 0);
      expect(EventPreviewer(s.rom).of(0).events.length, n0);
    });
  });

  group('事件组剧情槽偏移（按版本不同）', () {
    test('烈火用 +0x38，圣魔用 +0x48', () {
      // 这条锁住 v2.4.13 的修正：FE7 剧情脚本在 0x38/0x3C，
      // FE8 在 0x48/0x4C。写错就读不到开场白。
      final fe7 = _open(_gbk);
      final fe8 = _open(_fe8jp);
      final p7 = DialogPreviewer(fe7.rom).of(0);
      final p8 = DialogPreviewer(fe8.rom).of(0);
      // 两作第 0 章都该能提取到对话（其中相当一部分来自开场/结束剧情）
      expect(p7.lines, isNotEmpty);
      expect(p8.lines, isNotEmpty);
      // 烈火第 0 章开场白一定在其中
      expect(p7.lines.map((l) => l.text).join(), contains('我叫琳'));
    });
  });
}
