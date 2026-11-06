import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/chapter_dialogs.dart';
import 'package:fe_editor/core/chapter_dialog_io.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/text_writer.dart';

import 'rom_paths.dart';

const dir = romDir;
const fe8jp =
    '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';
const superxyj = '$dir/火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba';

EditableRom _open(String path) {
  final d = File(path).readAsBytesSync();
  return EditableRom.open(d, FeRom.detectTable(d)!);
}

void main() {
  group('导出（#define 风格文本）', () {
    test('Superxyj 第 0 章：条数与本章引用一致、可整段重导入', () {
      final edit = _open(superxyj);
      
      final rows = ChapterDialogues.of(edit, 0).dialogues;
      expect(rows, isNotEmpty);
      final text = ChapterDialogIO.exportChapter(edit, 0);
      expect(text, isNotNull);

      final lines = text!.split('\n');
      final defines =
          lines.where((l) => l.startsWith('#define')).toList();
      expect(defines.length, rows.length,
          reason: '每行一条，且按出现顺序、ID 去重');
      // 头部注释在
      expect(lines.first, startsWith('#'));

      // 原样导回 = 全部 identical
      final r = ChapterDialogIO.importDialogs(edit, text);
      expect(r.total, defines.length);
      expect(r.skipped, 0, reason: r.problems.join('; '));
      expect(r.unchanged, r.total);
      expect(edit.hasChanges, isFalse,
          reason: '内容全没变，不应产生任何编辑');
    });

    test('改一行台词后导入：只改那一行，其它原样', () {
      final edit = _open(superxyj);
      
      final text = ChapterDialogIO.exportChapter(edit, 0)!;
      final lines = text.split('\n');
      final defineLines =
          lines.where((l) => l.startsWith('#define')).toList();
      expect(defineLines, isNotEmpty);

      // 把第一条换成一句短的已知可编码内容（变短 → 原地写，不踩重定位）
      final target = defineLines.first;
      final m = RegExp(r'^#define (\d+)').firstMatch(target)!;
      final id = int.parse(m.group(1)!);
      const shorter = '测试';
      final changed = '#define $id $shorter';
      final newText = lines.join('\n').replaceFirst(target, changed);

      final r = ChapterDialogIO.importDialogs(edit, newText);
      expect(r.total, defineLines.length);
      expect(r.skipped, 0, reason: r.problems.join('; '));
      expect(r.unchanged, defineLines.length - 1);
      expect(edit.hasChanges, isTrue);

      // 只改了那一条
      final writer = TextWriter(edit);
      expect(writer.currentText(id), shorter);
      edit.revertAll();
    });

    test('不存在的文本 ID 被跳过并点名', () {
      final edit = _open(superxyj);
      
      final text = ChapterDialogIO.exportChapter(edit, 0)!;
      final r = ChapterDialogIO.importDialogs(edit, text + '#define 999999 没有这条\n');
      expect(r.skipped, 1, reason: r.problems.join('; '));
      expect(r.problems.join('; '), contains('999999'));
      expect(edit.hasChanges, isFalse,
          reason: '其它行 identical，跳过的不写 → 无编辑');
    });

    test('非 #define 行计入 badLines；重复 ID 取第一次', () {
      final edit = _open(superxyj);
      
      final text = ChapterDialogIO.exportChapter(edit, 0)!;
      final r = ChapterDialogIO.importDialogs(
        edit,
        text + '这不是补丁行\n#define 999999 重复ID测试\n#define 999999 再来一次\n',
      );
      expect(r.badLines, 1);
      // 两个 999999 只保留第一个（且它本身因 ID 无效被跳过）
      expect(r.problems.any((p) => p.contains('重复')), isTrue);
    });
  });

  group('导入/导出的引擎边界', () {
    test('不可写引擎：导出 null、导入 0 条并说明原因', () {
      // 狼组汉化封印 = unknown + tbl；不挂表时引擎不可写
      final edit = _open('$dir/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba');
      expect(TextWriter(edit).supported, isFalse,
          reason: '未挂码表时 unknown 引擎不可写');
      
      expect(ChapterDialogIO.exportChapter(edit, 0), isNull);
      final r = ChapterDialogIO.importDialogs(edit, '#define 1 你好\n');
      expect(r.total, 0);
      expect(r.problems.first, contains('不支持写入'));
      expect(edit.hasChanges, isFalse);
    });

    test('FE8J（Huffman）：导出带占位符、原样导回不写字节', () {
      final edit = _open(fe8jp);
      
      expect(TextWriter(edit).supported, isTrue);
      final text = ChapterDialogIO.exportChapter(edit, 0);
      expect(text, isNotNull);
      final r = ChapterDialogIO.importDialogs(edit, text!);
      expect(r.total, greaterThan(0));
      expect(r.skipped, 0, reason: r.problems.join('; '));
      expect(edit.hasChanges, isFalse,
          reason: 'Huffman 同内容重压缩 = 不写（v2.3.33 起原地字节相同即跳过）');
    });
  });
}
