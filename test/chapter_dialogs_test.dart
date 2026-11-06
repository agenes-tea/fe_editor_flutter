import 'dart:io';
import 'dart:typed_data';

import 'package:fe_editor/core/chapter_dialogs.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/unit_placement.dart';
import 'package:flutter_test/flutter_test.dart';

import 'rom_paths.dart';

Directory get _romDir => Directory(romDir);

EditableRom _open(String keyword) {
  File? f;
  for (final e in _romDir.listSync()) {
    if (e is File && e.path.contains(keyword)) {
      f = e;
      break;
    }
  }
  expect(f, isNotNull, reason: '找不到文件名包含 $keyword 的 ROM');
  final data = Uint8List.fromList(f!.readAsBytesSync());
  return EditableRom.open(data, FeRom.detectTable(data)!);
}

void main() {
  group('章节标题（与游戏标题卡副标题对齐）', () {
    test('FE7J：第 0/1 章标题与 ROM 内文本一致', () {
      final up = UnitPlacement(_open('0979'));
      expect(up.chapterTitle(0), '草原の少女');
      expect(up.chapterTitle(1), '運命の足音');
      // 对话提取与标题同属一章：第 0 章（草原の少女）含琳的自白
      final d = ChapterDialogues.of(_open('0979'), 0);
      expect(d.dialogues.map((e) => e.textId), contains(2101));
    });

    test('FE8J：第 0 章 = ルネス陥落（游戏内「序章」）', () {
      final up = UnitPlacement(_open('1692 -'));
      expect(up.chapterTitle(0), 'ルネス陥落');
      expect(up.chapterTitle(1), '脱出行');
    });

    test('FE6：章节条目无标题字段，返回空串不抛异常', () {
      final up = UnitPlacement(_open('0378'));
      expect(up.chapterTitle(0), '');
    });
  });

  group('章节对话提取（各版本事件脚本里的显示对话命令）', () {
    test('FE7J 第0章：琳的开场白逐条命中（#2101 起）', () {
      final d = ChapterDialogues.of(_open('0979'), 0);
      final ids = d.dialogues.map((e) => e.textId).toList();
      expect(ids, contains(2101), reason: '琳的开场白');
      expect(ids, containsAll([2102, 2103]));
      expect(ids.toSet().length, ids.length, reason: '应按 textId 去重');
    });

    test('FE7U 第0章：同一段开场白的美版文本 ID', () {
      final d = ChapterDialogues.of(_open('1235'), 0);
      final ids = d.dialogues.map((e) => e.textId).toList();
      expect(ids, containsAll([2069, 2070, 2071]));
    });

    test('FE8J 第0章：伊弗列姆报告与父王遗言', () {
      final d = ChapterDialogues.of(_open('1692 -'), 0);
      final ids = d.dialogues.map((e) => e.textId).toList();
      expect(ids, contains(2243));
      expect(ids, contains(2244));
      expect(d.dialogues, isNotEmpty);
    });

    test('FE6 第0章：指令教学对话（#12 起）', () {
      final d = ChapterDialogues.of(_open('0378'), 0);
      final ids = d.dialogues.map((e) => e.textId).toList();
      expect(ids, contains(12));
      expect(ids, contains(22));
    });

    test('提取出的 ID 全部有文本指针且可解码', () {
      for (final kw in ['0979', '1235', '1692 -', '0378']) {
        final edit = _open(kw);
        final d = ChapterDialogues.of(edit, 0);
        for (final e in d.dialogues) {
          expect(edit.liveRom.textEntryOffset(e.textId), greaterThanOrEqualTo(0),
              reason: '$kw 第0章 文本 #${e.textId} 无指针');
          expect(edit.liveRom.decodeText(e.textId), isA<String>());
        }
      }
    });

    test('没有事件的章节返回空列表而不是抛异常', () {
      final edit = _open('1692 -');
      // 试炼塔/对战章节（下标 79/85 一类）没有剧情事件
      for (final ch in [79, 85]) {
        final d = ChapterDialogues.of(edit, ch);
        expect(d.dialogues, isA<List<ChapterDialogue>>());
      }
    });

    test('命令字地址落在 ROM 内（MCP 十六进制页跳转用）', () {
      final edit = _open('0979');
      final d = ChapterDialogues.of(edit, 0);
      for (final e in d.dialogues) {
        expect(e.address, greaterThanOrEqualTo(0));
        expect(e.address, lessThan(edit.buffer.length));
      }
    });
  });
}
