import 'dart:io';
import 'dart:typed_data';

import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/text_browser.dart';
import 'package:fe_editor/core/text_writer.dart';
import 'package:fe_editor/core/zh_table.dart';
import 'package:fe_editor/core/zh_tables_data.dart';
import 'package:flutter_test/flutter_test.dart';

Directory get _romDir =>
    Directory('${Platform.environment['HOME']}/workspace/game-rom');

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

int _firstEditableLen(TextWriter w, int len) {
  for (var id = 1; id < 4096; id++) {
    final b = w.entryBytes(id);
    if (b == null) continue;
    if (b.length == len && w.entryEditable(id)) return id;
  }
  return -1;
}

int _firstEditableRange(TextWriter w, {int min = 4, int max = 40}) {
  for (var id = 1; id < 4096; id++) {
    final b = w.entryBytes(id);
    if (b == null) continue;
    if (b.length >= min && b.length <= max && w.entryEditable(id)) return id;
  }
  return -1;
}

void main() {
  group('引擎判定', () {
    test('明文与 Huffman 引擎都可写（只剩未识别不可写）', () {
      final utf8w = TextWriter(_open('铠甲'));
      expect(utf8w.supported, isTrue);
      expect(utf8w.isUtf8, isTrue);
      expect(utf8w.engineLabel, contains('UTF-8'));

      final gbkw = TextWriter(_open('Superxyj'));
      expect(gbkw.supported, isTrue);
      expect(gbkw.isGbk, isTrue);

      final sjis = TextWriter(_open('0979'));
      expect(sjis.supported, isTrue, reason: 'FE7J 是 Huffman+SJIS');
      expect(sjis.isHuffmanSjis, isTrue);

      final zhtbl = _open('圣魔之光石汉化');
      zhtbl.rom.zhTable = ZhTable(Map<int, String>.from(zhTblFE8));
      final zhtblW = TextWriter(zhtbl);
      expect(zhtblW.supported, isTrue, reason: 'FE8 汉化是 unknown + 中文码表');
      expect(zhtblW.isHuffmanZhTbl, isTrue);
    });
  });

  group('编码与解码往返', () {
    test('UTF-8：encode/decodeExact 往返', () {
      final w = TextWriter(_open('铠甲'));
      final enc = w.encode('武器熟练度');
      expect(enc, isNotNull);
      expect(w.decodeExact(enc!), '武器熟练度');
    });

    test('GBK：已知字节与往返（是 = CA C7）', () {
      final w = TextWriter(_open('Superxyj'));
      final enc = w.encode('是');
      expect(enc, [0xCA, 0xC7]);
      expect(w.decodeExact(Uint8List.fromList(enc!)), '是');
    });

    test('GBK：码表里没有的字返回 null', () {
      final w = TextWriter(_open('Superxyj'));
      // 私用区 / 扩展区字符不在 GBK 双字节码表里
      expect(w.encode(String.fromCharCode(0xE000)), isNull);
    });
  });

  group('明文 GBK：原地等长 / 变短', () {
    test('等长原地覆盖，指针不变', () {
      final edit = _open('Superxyj');
      final w = TextWriter(edit);
      final id = _firstEditableLen(w, 2);
      expect(id, greaterThan(0), reason: '应有一条 2 字节的纯文本条目');
      final orig = w.currentText(id)!;
      final replacement = orig == '是' ? '否' : '是';
      final ptrBefore = edit.buffer.u32(w.rom.textTableBase + id * 4);

      final r = w.write(id, replacement);
      expect(r.mode, TextWriteMode.inPlace);
      expect(r.originalBytes, 2);
      expect(r.newBytes, 2);
      expect(w.currentText(id), replacement);
      // 指针没有被改动
      expect(edit.buffer.u32(w.rom.textTableBase + id * 4), ptrBefore);
      expect(edit.hasChanges, isTrue);
    });

    test('变短：原地写 + 提前结束符，读回只剩新内容', () {
      final edit = _open('Superxyj');
      final w = TextWriter(edit);
      final id = _firstEditableLen(w, 4);
      expect(id, greaterThan(0), reason: '应有一条 4 字节（两个汉字）的条目');
      final r = w.write(id, '是'); // 2 字节
      expect(r.mode, TextWriteMode.shorter);
      expect(r.originalBytes, 4);
      expect(r.newBytes, 2);
      expect(w.currentText(id), '是');
    });

    test('内容完全相同 → identical，不产生改动', () {
      final edit = _open('Superxyj');
      final w = TextWriter(edit);
      final id = _firstEditableLen(w, 2);
      final orig = w.currentText(id)!;
      final r = w.write(id, orig);
      expect(r.mode, TextWriteMode.identical);
      expect(edit.hasChanges, isFalse);
    });
  });

  group('明文 UTF-8：变长重定位', () {
    test('变长写入空位并重指指针，读回新内容', () {
      final edit = _open('铠甲');
      final w = TextWriter(edit);
      final id = _firstEditableRange(w, min: 4, max: 40);
      expect(id, greaterThan(0));
      final orig = w.currentText(id)!;
      final newer = '${orig}X'; // 追加 1 字节 ASCII，必然变长
      final slot = w.rom.textTableBase + id * 4;
      final ptrBefore = edit.buffer.u32(slot);

      final r = w.write(id, newer);
      expect(r.mode, TextWriteMode.relocated);
      expect(r.newOffset, greaterThan(0));
      expect(r.newOffset, lessThan(0x02000000));
      // 指针槽被改到新位置
      final ptrAfter = edit.buffer.u32(slot);
      expect(ptrAfter, isNot(ptrBefore));
      expect(ptrAfter, 0x08000000 + r.newOffset);
      // 新位置可读回新文本
      expect(w.currentText(id), newer);
      expect(w.entryBytes(id)!.length, r.newBytes);
    });

    test('关闭重定位时变长直接拒绝', () {
      final edit = _open('铠甲');
      final w = TextWriter(edit);
      final id = _firstEditableRange(w, min: 4, max: 40);
      final orig = w.currentText(id)!;
      final r = w.write(id, '${orig}X', allowRelocate: false);
      expect(r.mode, TextWriteMode.tooLong);
      expect(edit.hasChanges, isFalse);
    });

    test('撤销后指针与内容都还原', () {
      final edit = _open('铠甲');
      final w = TextWriter(edit);
      final id = _firstEditableRange(w, min: 4, max: 40);
      final orig = w.currentText(id)!;
      final slot = w.rom.textTableBase + id * 4;
      final ptrBefore = edit.buffer.u32(slot);

      final r = w.write(id, '${orig}X');
      expect(r.mode, TextWriteMode.relocated);

      edit.revertAll();
      expect(edit.hasChanges, isFalse);
      expect(edit.buffer.u32(slot), ptrBefore);
      // 用同一份 buffer 的实时视图重新读，应回到原文
      expect(TextWriter(edit).currentText(id), orig);
    });
    test('TextBrowser 读实时 buffer：写入后渲染到新内容', () {
      final edit = _open('铠甲');
      final w = TextWriter(edit);
      final browser = TextBrowser(w.rom);
      final id = _firstEditableRange(w, min: 4, max: 40);
      final before = browser.render(id);
      w.write(id, '${w.currentText(id)}X');
      final after = browser.render(id);
      expect(after, isNot(before));
      expect(after.endsWith('X'), isTrue);
    });
    test('liveRom 读实时 buffer，rom 仍是原始快照', () {
      final edit = _open('铠甲');
      final w = TextWriter(edit);
      final id = _firstEditableRange(w, min: 4, max: 40);
      final beforeRom = edit.rom.decodeText(id);
      final orig = w.currentText(id)!;
      w.write(id, '${orig}X');
      // 实时视图能看到新内容
      expect(edit.liveRom.decodeText(id), contains('X'));
      // 原始快照不变（给按指令特征扫描的定位逻辑用）
      expect(edit.rom.decodeText(id), beforeRom);
    });
  });

  group('Huffman 引擎可写（用 ROM 自带树）', () {
    test('FE7J（SJIS）：改名往返，原始快照不变', () {
      final edit = _open('0979');
      final w = TextWriter(edit);
      expect(w.supported, isTrue);
      expect(w.isHuffmanSjis, isTrue);
      expect(w.currentText(1), 'はい');
      // 原名回写 → identical
      expect(w.write(1, 'はい').mode, TextWriteMode.identical);
      // 追加一个字 → 重定位
      final r = w.write(1, 'はいは');
      expect(r.mode, TextWriteMode.relocated);
      expect(w.currentText(1), 'はいは');
      // 原始快照（按指令扫描用）仍是原值
      expect(edit.rom.decodeText(1), 'はい');
    });

    test('狼组封印（中文码表 Huffman）：原名回写往返', () {
      final edit = _open('狼组');
      edit.rom.zhTable = ZhTable(zhTblFE6);
      final w = TextWriter(edit);
      expect(w.supported, isTrue);
      expect(w.isHuffmanZhTbl, isTrue);
      var found = -1;
      for (var id = 1; id < 800 && found < 0; id++) {
        final raw = w.entryBytes(id);
        if (raw == null || raw.isEmpty) continue;
        if (raw.any((b) => b < 0x20)) continue;
        final cur = w.currentText(id) ?? '';
        if (cur.trim().isEmpty) continue;
        if (w.write(id, cur).mode == TextWriteMode.identical) found = id;
        edit.revertAll();
      }
      expect(found, greaterThan(0), reason: '至少一条能原名往返');
    });

    test('Huffman：字符不在码表 → 拒绝且不写入', () {
      final edit = _open('0979');
      final w = TextWriter(edit);
      // 私用区字符不在 SJIS 里
      final r = w.write(1, String.fromCharCode(0xE000));
      expect(r.mode, TextWriteMode.charNotEncodable);
      expect(edit.hasChanges, isFalse);
    });
  });

  group('拒绝与不写入', () {
    test('含控制码的对话条目可编辑（控制码用占位符保留）', () {
      final edit = _open('Superxyj');
      final w = TextWriter(edit);
      var controlId = -1;
      for (var id = 1; id < 4096; id++) {
        final b = w.entryBytes(id);
        if (b == null || b.isEmpty) continue;
        if (b.any((x) => x < 0x20)) {
          controlId = id;
          break;
        }
      }
      expect(controlId, greaterThan(0), reason: 'Superxyj 应有含控制码的条目');
      final cur = w.currentText(controlId)!;
      expect(cur.contains('〔'), isTrue, reason: '控制码应显示为占位符');
      // 原名回写 → 字节完全一致（identical）
      final r = w.write(controlId, cur);
      expect(r.mode, TextWriteMode.identical);
    });

    test('未识别引擎不支持写入', () {
      // 狼组本来是 unknown + 中文码表（Huffman）；清掉码表就变成真·未识别
      final edit = _open('狼组');
      edit.rom.zhTable = null;
      final w = TextWriter(edit);
      expect(w.supported, isFalse);
      final r = w.write(1, '测试');
      expect(r.mode, TextWriteMode.unsupportedEngine);
      expect(edit.hasChanges, isFalse);
    });
  });
}
