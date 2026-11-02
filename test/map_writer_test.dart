import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/lz77_compress.dart';
import 'package:fe_editor/core/map_reader.dart';
import 'package:fe_editor/core/map_writer.dart';
import 'package:fe_editor/core/patch_format.dart';
import 'package:fe_editor/core/portrait.dart' show Lz77;

const dir = '/root/workspace/game-rom';
const fe6jp = '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

EditableRom _open(String path) {
  final d = File(path).readAsBytesSync();
  return EditableRom.open(d, FeRom.detectTable(d)!);
}

/// 找一个「只改一格后压缩后仍放得下」的章节：原版多数地图已压到上限，
/// 改一格体积会涨 1~5 字节，所以测试不能假设任意章节都能原地写。
({int chapter, List<int> tiles})? _findWritableChapter(
    EditableRom edit, {int maxChapters = 30}) {
  final reader = MapReader(edit.rom);
  for (var ch = 0; ch < maxChapters; ch++) {
    final map = reader.chapterMap(ch);
    if (map == null) continue;
    final orig = MapWriter.compressedLengthOf(edit.buffer.data, map.dataOffset);
    final alts = map.tiles.toSet().toList();
    if (alts.length < 2) continue;
    final tiles = List<int>.from(map.tiles);
    tiles[0] = alts.first == tiles[0] ? alts.last : alts.first;
    final raw = _pack(map.width, map.height, tiles);
    if (Lz77Compressor.compress(raw).length <= orig) {
      return (chapter: ch, tiles: tiles);
    }
  }
  return null;
}

Uint8List _pack(int w, int h, List<int> tiles) {
  final raw = Uint8List(2 + tiles.length * 2);
  raw[0] = w;
  raw[1] = h;
  for (var i = 0; i < tiles.length; i++) {
    raw[2 + i * 2] = tiles[i] & 0xFF;
    raw[2 + i * 2 + 1] = (tiles[i] >> 8) & 0xFF;
  }
  return raw;
}

void main() {
  group('压缩器与原版数据的一致性（写回的前提）', () {
    test('把原版地图重新压缩，得到的长度与原流完全一致', () {
      final edit = _open(fe8jp);
      final reader = MapReader(edit.rom);
      var checked = 0;
      for (var ch = 0; ch < 20; ch++) {
        final map = reader.chapterMap(ch);
        if (map == null) continue;
        final raw = Lz77.decompress(edit.buffer.data, map.dataOffset);
        expect(raw, isNotNull, reason: '第 $ch 章地图应是合法 LZ77');
        final packed = Lz77Compressor.compress(raw!);
        final orig = MapWriter.compressedLengthOf(edit.buffer.data, map.dataOffset);
        expect(packed.length, orig, reason: '第 $ch 章重压缩长度应等于原流');
        checked++;
      }
      expect(checked, greaterThan(10));
    });

    test('压缩长度计算与原流逐字节吻合（内容也一致）', () {
      final edit = _open(fe7jp);
      final reader = MapReader(edit.rom);
      final map = reader.chapterMap(0)!;
      final orig = MapWriter.compressedLengthOf(edit.buffer.data, map.dataOffset);
      final raw = Lz77.decompress(edit.buffer.data, map.dataOffset)!;
      final packed = Lz77Compressor.compress(raw);
      expect(packed.length, orig);
      for (var i = 0; i < packed.length; i++) {
        expect(edit.buffer.data[map.dataOffset + i], packed[i],
            reason: '第 $i 字节与原流不一致');
      }
    });
  });

  group('砖块写回：原地覆盖', () {
    test('改一格后读回一致，且数据没搬家', () {
      final edit = _open(fe8jp);
      final pick = _findWritableChapter(edit);
      expect(pick, isNotNull, reason: 'FE8J 前 30 章里应存在可原地写回的章节');

      final before = MapReader(edit.rom).chapterMap(pick!.chapter)!;
      final result = MapWriter(edit).write(pick.chapter, pick.tiles);

      expect(result.ok, isTrue, reason: result.message);
      expect(result.mode, MapWriteMode.inPlace);
      expect(result.newBytes, lessThanOrEqualTo(result.originalBytes));
      expect(result.dataOffset, before.dataOffset, reason: '写回位置就是原数据块位置');

      final after = MapReader(edit.liveRom).chapterMap(pick.chapter)!;
      expect(after.dataOffset, before.dataOffset, reason: '原地覆盖不该挪动数据');
      expect(after.tiles[0], pick.tiles[0]);
      for (var i = 1; i < pick.tiles.length; i++) {
        expect(after.tiles[i], before.tiles[i], reason: '第 $i 格被误改');
      }
    });

    test('内容未变时不写入任何字节', () {
      final edit = _open(fe8jp);
      final map = MapReader(edit.rom).chapterMap(0)!;
      final result = MapWriter(edit).write(0, map.tiles);
      expect(result.mode, MapWriteMode.identical);
      expect(edit.edits, isEmpty, reason: '没有实际改动就不该产生编辑记录');
    });

    test('撤销后与原始 ROM 逐字节一致', () {
      final edit = _open(fe8jp);
      final pick = _findWritableChapter(edit)!;
      expect(MapWriter(edit).write(pick.chapter, pick.tiles).ok, isTrue);
      expect(edit.hasChanges, isTrue);
      edit.revertAll();
      expect(edit.hasChanges, isFalse);
      expect(edit.data, equals(edit.original));
    });
  });

  group('砖块写回：三作都成立', () {
    for (final (name, path) in [
      ('FE6', fe6jp),
      ('FE7J', fe7jp),
      ('FE8J', fe8jp),
    ]) {
      test('$name 能写回并读回', () {
        final edit = _open(path);
        final pick = _findWritableChapter(edit);
        expect(pick, isNotNull, reason: '$name 前 30 章里应有可写回的章节');
        final result = MapWriter(edit).write(pick!.chapter, pick.tiles);
        expect(result.ok, isTrue, reason: result.message);
        final after = MapReader(edit.liveRom).chapterMap(pick.chapter)!;
        expect(after.tiles[0], pick.tiles[0]);
        expect(after.tiles.length, pick.tiles.length);
      });
    }
  });

  group('放不下时拒绝而不是改坏别的章节', () {
    test('把地图塞满无法压缩的砖块后被拒绝', () {
      final edit = _open(fe8jp);
      final map = MapReader(edit.rom).chapterMap(0)!;
      // 相邻格互不相同 → 回溯匹配全部失效，压缩后必然比原流长
      final tiles = [
        for (var i = 0; i < map.tiles.length; i++)
          ((i * 4) + (i.isEven ? 0 : 2)) & 0xFFFF,
      ];
      final result = MapWriter(edit).write(0, tiles);

      expect(result.ok, isFalse);
      expect(result.mode, MapWriteMode.tooLarge);
      expect(result.message, contains('就地放不下'));
      expect(edit.hasChanges, isFalse, reason: '被拒绝时不得写入任何字节');
      // 其它章节共享同一张地图时也不受影响
      final back = MapReader(edit.liveRom).chapterMap(0)!;
      expect(back.tiles, equals(map.tiles));
    });

    test('tooLarge 会报出原占用与新长度', () {
      final edit = _open(fe6jp);
      final map = MapReader(edit.rom).chapterMap(0)!;
      final tiles = [
        for (var i = 0; i < map.tiles.length; i++)
          ((i * 4) + (i.isEven ? 0 : 2)) & 0xFFFF,
      ];
      final result = MapWriter(edit).write(0, tiles);
      expect(result.mode, MapWriteMode.tooLarge);
      expect(result.newBytes, greaterThan(result.originalBytes));
      expect(result.originalBytes, greaterThan(0));
      expect(edit.hasChanges, isFalse);
    });
  });

  group('边界与防护', () {
    test('砖块数不符时拒绝写入', () {
      final edit = _open(fe8jp);
      final map = MapReader(edit.rom).chapterMap(0)!;
      final result = MapWriter(edit).write(0, map.tiles.sublist(1));
      expect(result.ok, isFalse);
      expect(result.mode, MapWriteMode.unavailable);
      expect(edit.hasChanges, isFalse);
    });

    test('越界章节返回 unavailable 而不是崩', () {
      final edit = _open(fe8jp);
      final result = MapWriter(edit).write(9999, const [1, 2, 3]);
      expect(result.mode, MapWriteMode.unavailable);
      expect(edit.hasChanges, isFalse);
    });

    test('改完的地图能渲染（无透明像素）', () {
      final edit = _open(fe8jp);
      final pick = _findWritableChapter(edit)!;
      MapWriter(edit).write(pick.chapter, pick.tiles);

      final img = MapReader(edit.liveRom).renderMap(pick.chapter);
      expect(img, isNotNull);
      var transparent = 0;
      for (var i = 3; i < img!.pixels.length; i += 4) {
        if (img.pixels[i] == 0) transparent++;
      }
      expect(transparent, 0, reason: '渲染结果不能有透明像素（会透出白底）');
    });

    test('改后的 ROM 能导出成 UPS 并还原', () {
      final edit = _open(fe8jp);
      final pick = _findWritableChapter(edit)!;
      MapWriter(edit).write(pick.chapter, pick.tiles);

      final out = edit.buildOutput();
      final patch = UpsPatch.create(edit.original, out);
      final restored = UpsPatch.apply(patch, edit.original);
      expect(restored, isNotNull);
      final rom = FeRom(restored!, FeRom.detectTable(restored)!);
      expect(MapReader(rom).chapterMap(pick.chapter)!.tiles[0], pick.tiles[0]);
    });
  });
}
