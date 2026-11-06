import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/text_find_replace.dart';
import 'package:fe_editor/core/text_writer.dart';

import 'rom_paths.dart';

Directory get _romDir => Directory(romDir);

File _romByKeyword(String keyword) {
  for (final f in _romDir.listSync()) {
    if (f is File && f.path.contains(keyword)) return f;
  }
  throw StateError('找不到文件名包含 $keyword 的 ROM');
}

EditableRom _open(String keyword) {
  final data =
      Uint8List.fromList(_romByKeyword(keyword).readAsBytesSync());
  return EditableRom.open(data, FeRom.detectTable(data)!);
}

void main() {
  test('明文 UTF-8：单字替换（等长原地）→ 全部条目生效且可整体回退', () {
    final edit = _open('铠甲');
    final w = TextWriter(edit);
    expect(w.isUtf8, isTrue);
    final fr = TextFindReplace(w);

    // 找一个命中 ≥2 条的单字
    String findChar = '';
    List<int> hits = const [];
    for (final c in ['的', '了', '是', '在', '有']) {
      hits = fr.search(c);
      if (hits.length >= 2) {
        findChar = c;
        break;
      }
    }
    expect(findChar, isNotEmpty, reason: '常用字应命中多条');

    final id = hits.first;
    final before = w.currentText(id) ?? '';
    expect(before.contains(findChar), isTrue);

    final r = fr.replaceAll(findChar, '某');
    expect(r.changed, greaterThanOrEqualTo(2));
    final after = w.currentText(id) ?? '';
    expect(after.contains('某'), isTrue);
    expect(after.contains(findChar), isFalse);
    // 除了被替换的字，正文其余部分不变
    expect(after.replaceAll('某', ''), before.replaceAll(findChar, ''));

    edit.revertAll();
    expect(w.currentText(id), before, reason: '整体回退后逐字复原');
  });

  test('空替换 = 删除该字', () {
    final edit = _open('铠甲');
    final w = TextWriter(edit);
    final fr = TextFindReplace(w);
    String findChar = '';
    List<int> hits = const [];
    for (final c in ['的', '了', '是']) {
      hits = fr.search(c);
      if (hits.length >= 1) {
        findChar = c;
        break;
      }
    }
    expect(findChar, isNotEmpty);
    final id = hits.first;
    final before = w.currentText(id) ?? '';
    final r = fr.replaceAll(findChar, '', ids: [id]);
    expect(r.changed, 1);
    expect(w.currentText(id), before.replaceAll(findChar, ''));
    edit.revertAll();
  });

  test('指定 ids 只改那几条', () {
    final edit = _open('铠甲');
    final w = TextWriter(edit);
    final fr = TextFindReplace(w);
    List<int> hits = const [];
    String findChar = '';
    for (final c in ['的', '了', '是', '在']) {
      hits = fr.search(c);
      if (hits.length >= 3) {
        findChar = c;
        break;
      }
    }
    expect(hits.length, greaterThanOrEqualTo(3));
    final target = hits.take(2).toList();
    final r = fr.replaceAll(findChar, 'X', ids: target);
    expect(r.changed, 2);
    // 第 3 条没被碰
    final third = w.currentText(hits[2]) ?? '';
    expect(third.contains(findChar), isTrue);
    edit.revertAll();
  });

  test('Huffman+SJIS（FE7J）：同长度假名替换可写回', () {
    final edit = _open('0979');
    final w = TextWriter(edit);
    expect(w.isHuffmanSjis, isTrue);
    final fr = TextFindReplace(w);
    final hits = fr.search('の');
    expect(hits, isNotEmpty, reason: '日版文本里「の」很常见');
    final id = hits.first;
    final before = w.currentText(id) ?? '';
    final r = fr.replaceAll('の', 'り', ids: [id]);
    expect(r.changed, 1, reason: r.failures.join('；'));
    final after = w.currentText(id) ?? '';
    expect(after.contains('り'), isTrue);
    expect(after.contains('の'), isFalse);
    edit.revertAll();
    expect(w.currentText(id), before);
  });
}
