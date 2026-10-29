import 'dart:io';
import 'dart:typed_data';

import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/hex_view.dart';
import 'package:fe_editor/core/huffman_encoder.dart';
import 'package:fe_editor/core/rom_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

Directory get _romDir =>
    Directory('${Platform.environment['HOME']}/workspace/game-rom');

Uint8List _load(String keyword) {
  for (final f in _romDir.listSync()) {
    if (f is File && f.path.contains(keyword)) return f.readAsBytesSync();
  }
  throw StateError('找不到 $keyword');
}

FeRom _rom(String keyword) {
  final data = _load(keyword);
  return FeRom(data, FeRom.detectTable(data)!);
}

const _huffmanRoms = ['0378', '0979', '1235', '1692 -', '狼组', '圣魔之光石汉化'];

void main() {
  test('各 Huffman 版本都能建出编码树', () {
    for (final kw in _huffmanRoms) {
      final h = HuffmanEncoder(_rom(kw));
      expect(h.available, isTrue, reason: kw);
    }
  });

  test('字节级往返：decodeTextBytesAt → encodeBytes → 写回 → decodeTextBytes 一致', () {
    for (final kw in _huffmanRoms) {
      final data = _load(kw);
      final table = FeRom.detectTable(data)!;
      final rom = FeRom(data, table);
      final h = HuffmanEncoder(rom);
      var tested = 0;
      for (var id = 1; id < 800 && tested < 8; id++) {
        if (rom.textEntryOffset(id) < 0) continue;
        final raw = rom.decodeTextBytesAt(id);
        if (raw.isEmpty) continue;
        if (raw.any((b) => b < 0x20)) continue; // 跳过含控制码的条目
        final comp = h.encodeBytes(raw);
        if (comp == null) continue; // 有字节不在树里（旧残骸），跳过
        final copy = Uint8List.fromList(data);
        final buf = RomBuffer(copy);
        final run =
            HexView(buf).findFreeRun(0, fill: 0xFF, minLength: comp.length + 8);
        if (run == null) continue;
        buf.data.setRange(run.offset, run.offset + comp.length, comp);
        final back = FeRom(copy, table).decodeTextBytes(run.offset);
        expect(back, equals(raw), reason: '$kw id=$id 往返不一致');
        tested++;
      }
      expect(tested, greaterThan(0), reason: '$kw 至少应有一条能往返');
    }
  });
}
