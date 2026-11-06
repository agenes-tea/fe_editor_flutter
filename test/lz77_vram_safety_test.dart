import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/lz77_compress.dart';
import 'package:fe_editor/core/portrait.dart';

import 'rom_paths.dart';

/// 统计一条压缩流里各种回溯距离的分布。
({int total, int d1, int d2, int other}) _distStats(Uint8List d, int at) {
  final size = d[at + 1] | (d[at + 2] << 8) | (d[at + 3] << 16);
  var i = at + 4, w = 0;
  var total = 0, d1 = 0, d2 = 0, other = 0;
  while (w < size && i + 1 < d.length) {
    final flags = d[i];
    i++;
    for (var bit = 0x80; bit > 0 && w < size; bit >>= 1) {
      if (i >= d.length) break;
      if ((flags & bit) == 0) {
        w++;
        i++;
      } else {
        if (i + 1 >= d.length) break;
        final f = d[i], s = d[i + 1];
        i += 2;
        final len = 3 + (f >> 4);
        final dist = (((f & 0x0F) << 8) | s) + 1;
        total++;
        if (dist == 1) {
          d1++;
        } else if (dist == 2) {
          d2++;
        } else {
          other++;
        }
        w += len;
      }
    }
  }
  return (total: total, d1: d1, d2: d2, other: other);
}

void main() {
  group('LZ77 压缩必须兼容 GBA VRAM 解压（SWI 0x12）', () {
    test('默认不产生 distance=1 的回溯', () {
      // 造一段大量重复的数据，这种输入最容易被压成 distance=1
      final data = Uint8List(1024);
      for (var i = 0; i < data.length; i++) {
        data[i] = 0x11;
      }
      final packed = Lz77Compressor.compress(data);
      final st = _distStats(packed, 0);
      expect(st.d1, 0,
          reason: 'VRAM 用 16 位写，distance=1 引用的前一字节尚未写入，'
              '这种回溯在游戏里不生效（工具按字节语义读却是对的）');
      // 仍然要能压缩（全相同字节应高度压缩）
      expect(packed.length, lessThan(data.length ~/ 4));
    });

    test('allowDistance1=true 时才允许（仅 WRAM 场景）', () {
      final data = Uint8List(1024);
      for (var i = 0; i < data.length; i++) {
        data[i] = 0x11;
      }
      final packed = Lz77Compressor.compress(data, allowDistance1: true);
      final st = _distStats(packed, 0);
      expect(st.d1, greaterThan(0));
    });

    test('压缩结果仍能正确解压（往返无损）', () {
      final data = Uint8List(2048);
      for (var i = 0; i < data.length; i++) {
        data[i] = (i * 7 + (i ~/ 13)) & 0xFF;
      }
      final packed = Lz77Compressor.compress(data);
      final back = Lz77.decompress(packed, 0);
      expect(back, isNotNull);
      expect(back!.length, data.length);
      for (var i = 0; i < data.length; i++) {
        expect(back[i], data[i], reason: '第 $i 字节往返不一致');
      }
    });

    test('真实肖像：我们的流与原版在距离分布上一致（佐证规格对齐）', () {
      final dir = Directory(romDir);
      if (!dir.existsSync()) return;
      EditableRom? edit;
      for (final f in dir.listSync().whereType<File>()) {
        if (f.lengthSync() != 8388608) continue;
        final b = f.readAsBytesSync();
        final t = FeRom.detectTable(b);
        if (t == null || t.id.toString() != 'FE6') continue;
        edit = EditableRom.open(b, t);
        break;
      }
      if (edit == null) return;
      final reader = PortraitReader(edit.liveRom);
      final en = reader.entryAt(1);
      if (en == null || en.unitFace <= 0) {
        reader.dispose();
        return;
      }
      final uz = Lz77.decompress(edit.liveRom.data, en.unitFace);
      expect(uz, isNotNull);
      final orig = _distStats(edit.liveRom.data, en.unitFace);
      final mine = _distStats(Lz77Compressor.compress(uz!), 0);
      reader.dispose();

      expect(orig.d1, 0, reason: '原版压缩器本身就不产生 distance=1');
      expect(mine.d1, 0, reason: '我们的压缩器也必须不产生');
      expect(mine.total, orig.total,
          reason: '回溯数量应与原版一致（同样的匹配策略）');
    });
  });
}
