import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fe_editor/core/chapter_event_editor.dart';
import 'package:fe_editor/core/chapter_events.dart';
import 'package:fe_editor/core/chapter_dialogs.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/event_templates.dart';
import 'package:fe_editor/core/unit_placement.dart';
import 'package:fe_editor/core/rom_session.dart';

import 'rom_paths.dart';

const _dir = romDir;
const _files = [
  '火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba', // FE7J
  '1235 - 火炎之纹章-烈火之剑 Fire Emblem(US)(Nintendo)(128Mb).gba', // FE7U
  '1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba', // FE8J
  '0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba', // FE6
];

RomSession _open(String name) =>
    RomSession.open(File('$_dir/$name').readAsBytesSync(), name)!;

const _units = [
  ReinforcementUnit(charId: 135, classId: 57, level: 5, x: 5, y: 7, allegiance: 2),
  ReinforcementUnit(charId: 3, classId: 2, level: 3, x: 10, y: 5, allegiance: 0),
];

/// 取事件组里「最后一条非 0 的回合事件」的脚本偏移（= 刚追加的那条）。
///
/// 回合列表在**所有版本都是 12 字节条目**（FE7 只有角色列表是 16 字节）。
int _lastTurnScriptOffset(FeRom rom, int group) {
  const es = 12;
  final base = FeRom.toOffset(FeRom.u32(rom.data, group));
  var found = -1;
  for (var i = 0; i < 300; i++) {
    final at = base + i * es;
    if (at + 8 > rom.length) break;
    final check = FeRom.u32(rom.data, at);
    if (check == 0) break;
    final sp = FeRom.u32(rom.data, at + 4);
    if (!FeRom.isPointer(sp, rom.length)) continue;
    found = FeRom.toOffset(sp);
  }
  return found;
}

void main() {
  for (final name in _files) {
    test('追加事件带台词：$name', () {
      final s = _open(name);
      final rom = s.rom.liveRom;
      final ev = ChapterEvents(rom);
      final displayCmd = ev.displayTextCommand();
      expect(displayCmd, greaterThan(0),
          reason: '该 ROM 应能定位到显示命令，否则带台词功能应被拒绝');

      // 取本章一条真实存在的对话文本 ID 当作要挂的台词
      final ch0 = ChapterDialogues.of(s.rom, 0);
      expect(ch0.dialogues, isNotEmpty, reason: '第 0 章应有可引用的对话');
      final textId = ch0.dialogues.first.textId;

      final group = UnitPlacement(s.rom).eventGroupOffset(0);
      expect(group, greaterThan(0));

      final r = ChapterEventEditor(s.rom).addTurnReinforcement(
          chapter: 0, turn: 250, units: _units, dialogueTextId: textId);
      expect(r.ok, isTrue, reason: r.message);

      // 找到刚追加的那条脚本，核对首条记录 = 显示命令 + 文本 ID
      final script = _lastTurnScriptOffset(rom, group);
      expect(script, greaterThan(0));
      if (rom.table.id.startsWith('FE8')) {
        final w = FeRom.u32(rom.data, script);
        expect((w >> 8) & 0xFF, displayCmd, reason: 'FE8 首条应为 DISPLAYTEXT');
        expect(w >> 16, textId, reason: '文本 ID 在命令字高 16 位');
      } else {
        final cmd = FeRom.u32(rom.data, script) & 0xFFFF;
        expect(cmd, displayCmd, reason: '首条应为显示命令');
        expect(FeRom.u16(rom.data, script + 4), textId,
            reason: '文本 ID 在第二个字低 16 位');
      }

      // 单位仍能解析出来（loadUnits 走 CALL/LOADUNIT，不受前置显示记录影响）
      final loaded = ev.loadedUnits(0x08000000 + script);
      expect(loaded.map((u) => u.charId).toSet(),
          _units.map((u) => u.charId).toSet(),
          reason: '带台词后单位应照常生成');

      // 显示命令确实把该文本 ID 挂进了本章
      final ch0After = ChapterDialogues.of(s.rom, 0);
      expect(ch0After.dialogues.map((d) => d.textId).toSet(), contains(textId));
    });

    test('无效台词 ID 在写字节前就被拒绝：$name', () {
      final s = _open(name);
      final before = s.rom.changedByteCount;
      final r = ChapterEventEditor(s.rom).addTurnReinforcement(
          chapter: 0, turn: 7, units: _units, dialogueTextId: 999999);
      expect(r.ok, isFalse);
      expect(s.rom.changedByteCount, before,
          reason: '校验失败不能写字节');
    });
  }

  test('EventTemplates.addReinforcement 也支持带台词', () {
    final s = _open(_files[0]); // FE7J Superxyj
    final rom = s.rom.liveRom;
    final textId = ChapterDialogues.of(s.rom, 0).dialogues.first.textId;
    final out = EventTemplates(s.rom).addReinforcement(
        chapter: 0, turn: 240, units: _units, dialogueTextId: textId);
    expect(out.ok, isTrue, reason: out.message);
    expect(rom.textEntryOffset(textId), greaterThan(0));
  });
}
