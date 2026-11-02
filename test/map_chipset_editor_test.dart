import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/map_reader.dart';
import 'package:fe_editor/core/map_writer.dart';
import 'package:fe_editor/core/portrait.dart' show Lz77;

const dir = '/root/workspace/game-rom';
const fe6jp =
    '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const fe7jp =
    '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe7up =
    '$dir/1235 - 火炎之纹章-烈火之剑 Fire Emblem(US)(Nintendo)(128Mb).gba';
const fe8jp =
    '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

EditableRom _open(String path) {
  final d = File(path).readAsBytesSync();
  return EditableRom.open(d, FeRom.detectTable(d)!);
}

/// 逐 blob 解码出调色板索引数组。
List<int> _blobIndices(EditableRom edit, int chapter, ChipsetBlob b) {
  final uz = Lz77.decompress(edit.buffer.data, b.offset)!;
  return decode4bppIndices(uz, 256, b.tileRows * 8).toList();
}

void main() {
  group('encode4bppIndices 是 decode4bppIndices 的严格逆', () {
    for (final (name, path) in [
      ('FE6', fe6jp),
      ('FE7J', fe7jp),
      ('FE7U', fe7up),
      ('FE8J', fe8jp),
    ]) {
      test('$name：原版 chipset 流 encode(decode(x)) 逐字节一致', () {
        final edit = _open(path);
        final reader = MapReader(edit.rom);
        var checked = 0;
        for (var ch = 0; ch < 8; ch++) {
          for (final b in reader.chipsetBlobs(ch)) {
            final uz = Lz77.decompress(edit.buffer.data, b.offset)!;
            final idx = decode4bppIndices(uz, 256, b.tileRows * 8);
            final re = encode4bppIndices(idx, b.tileRows);
            expect(re, equals(uz),
                reason: '$name 第$ch章 blob ${b.plistIndex} 往返不一致');
            checked++;
          }
        }
        expect(checked, greaterThanOrEqualTo(8),
            reason: '$name 至少应读到 8 个 chipset blob');
      });
    }
  });

  group('chipset blob 枚举', () {
    test('FE6 第 0 章是双 blob 拼接', () {
      final edit = _open(fe6jp);
      final reader = MapReader(edit.rom);
      final blobs = reader.chipsetBlobs(0);
      expect(blobs, hasLength(2));
      final expected = blobs.fold(0, (a, b) => a + b.pixelCount);
      expect(reader.chipIndices(0)!.length, expected);
      // chipIndices 的顺序 = 逐 blob 解码再拼接
      var pos = 0;
      for (final b in blobs) {
        final part = _blobIndices(edit, 0, b);
        final joined =
            reader.chipIndices(0)!.sublist(pos, pos + b.pixelCount);
        expect(joined, equals(part.toList()));
        pos += b.pixelCount;
      }
    });

    test('FE7J 双 chipset 章节（obj=0x1D1C）两个 blob 都在', () {
      final edit = _open(fe7jp);
      final reader = MapReader(edit.rom);
      final blobs = reader.chipsetBlobs(5);
      expect(blobs, hasLength(2),
          reason: 'FE7J 第 5 章 obj 高低字节各引一个 chipset');
    });

    test('sharedChapters 点名共用章节（FE7J 第 5 章 obj 被 7/11 共用）', () {
      final edit = _open(fe7jp);
      final reader = MapReader(edit.rom);
      final shared = reader.sharedChapters(5, 'obj');
      expect(shared, containsAll([7, 11]));
      expect(shared, isNot(contains(5)));
      // 第 0 章地图不与他人共用
      expect(reader.sharedChapters(0, 'map'), isEmpty);
    });
  });

  group('chipset 写回', () {
    test('画一格后读回一致，撤销后还原（FE8J）', () {
      final edit = _open(fe8jp);
      final reader = MapReader(edit.rom);
      final blobs = reader.chipsetBlobs(0);
      expect(blobs, isNotEmpty);
      final original = reader.chipIndices(0)!.toList();

      final modified = List<int>.from(original);
      // 第一个 blob 的 tile (0,0) 填成索引 14
      for (var py = 0; py < 8; py++) {
        for (var px = 0; px < 8; px++) {
          modified[py * 256 + px] = 14;
        }
      }
      final r = MapWriter(edit).writeChipset(0, modified);
      expect(r.ok, isTrue, reason: r.message);
      expect(r.mode, ChipsetWriteMode.inPlace);

      final back = MapReader(edit.liveRom).chipIndices(0)!;
      expect(back[0], 14, reason: '画过的像素应变成索引 14');
      var diff = 0;
      for (var i = 0; i < original.length; i++) {
        if (back[i] != original[i]) diff++;
      }
      expect(diff, 64, reason: '只有画过的那 8×8 格被改');

      edit.revertAll();
      expect(edit.data, equals(edit.original));
    });

    test('内容未变时不写任何字节', () {
      final edit = _open(fe6jp);
      final reader = MapReader(edit.rom);
      final r = MapWriter(edit).writeChipset(0, reader.chipIndices(0)!);
      expect(r.mode, ChipsetWriteMode.identical);
      expect(edit.edits, isEmpty);
    });

    test('双 blob 章节改第二个 blob 也写得到（FE7J 第 5 章）', () {
      final edit = _open(fe7jp);
      final reader = MapReader(edit.rom);
      final blobs = reader.chipsetBlobs(5);
      expect(blobs, hasLength(2));
      final original = reader.chipIndices(5)!.toList();

      final modified = List<int>.from(original);
      final blob0Rows = blobs[0].tileRows;
      // 第二个 blob 的 tile (1,1)（相对该 blob 自己的行 0）
      final ty = blob0Rows + 1;
      final tx = 1;
      for (var py = 0; py < 8; py++) {
        for (var px = 0; px < 8; px++) {
          modified[(ty * 8 + py) * 256 + tx * 8 + px] = 9;
        }
      }
      final r = MapWriter(edit).writeChipset(5, modified);
      expect(r.ok, isTrue, reason: r.message);

      final back = MapReader(edit.liveRom).chipIndices(5)!;
      expect(back[(ty * 8) * 256 + tx * 8], 9);
      // 第一个 blob 一个像素都没动
      final firstLen = blobs[0].pixelCount;
      for (var i = 0; i < firstLen; i++) {
        expect(back[i], original[i]);
      }
    });

    test('索引数量不符时拒绝写入', () {
      final edit = _open(fe8jp);
      final reader = MapReader(edit.rom);
      final r = MapWriter(edit).writeChipset(
          0, reader.chipIndices(0)!.sublist(1));
      expect(r.mode, ChipsetWriteMode.unavailable);
      expect(edit.hasChanges, isFalse);
    });

    test('定位不到的章节返回 unavailable 而不是崩', () {
      final edit = _open(fe8jp);
      final r = MapWriter(edit).writeChipset(9999, [0]);
      expect(r.mode, ChipsetWriteMode.unavailable);
    });
  });

  group('地图改尺寸', () {
    test('同尺寸同内容写回 = identical，不产生编辑记录', () {
      final edit = _open(fe8jp);
      final reader = MapReader(edit.rom);
      final map = reader.chapterMap(0)!;
      final r = MapWriter(edit).writeSize(0, map.width, map.height, map.tiles);
      expect(r.mode, MapWriteMode.identical);
      expect(edit.edits, isEmpty);
    });

    test('缩小一行写回后读出新尺寸，撤销还原（FE8J 第 0 章）', () {
      final edit = _open(fe8jp);
      final reader = MapReader(edit.rom);
      final map = reader.chapterMap(0)!;
      final nh = map.height - 1;
      final remapped = MapWriter.remapTiles(
          map.tiles, map.width, map.height, map.width, nh);
      final r = MapWriter(edit).writeSize(0, map.width, nh, remapped);
      expect(r.ok, isTrue, reason: r.message);
      expect(r.dataOffset, map.dataOffset, reason: '还是原地写，不搬家');

      final back = MapReader(edit.liveRom).chapterMap(0)!;
      expect(back.width, map.width);
      expect(back.height, nh);
      expect(back.tiles.length, map.width * nh);
      // 重排是行主序：前 nh 行与旧图逐格一致
      for (var y = 0; y < nh; y++) {
        for (var x = 0; x < map.width; x++) {
          expect(back.tiles[y * map.width + x], map.tiles[y * map.width + x]);
        }
      }

      edit.revertAll();
      expect(MapReader(edit.rom).chapterMap(0)!.height, map.height);
    });

    test('放大一行放不下时被拒绝（三作同规则）', () {
      for (final (name, path) in [
        ('FE6', fe6jp),
        ('FE7J', fe7jp),
        ('FE8J', fe8jp),
      ]) {
        final edit = _open(path);
        final reader = MapReader(edit.rom);
        final map = reader.chapterMap(0)!;
        final remapped = MapWriter.remapTiles(
            map.tiles, map.width, map.height, map.width, map.height + 1);
        final r = MapWriter(edit)
            .writeSize(0, map.width, map.height + 1, remapped);
        expect(r.mode, MapWriteMode.tooLarge, reason: '$name $r.message');
        expect(edit.hasChanges, isFalse);
      }
    });

    test('remapTiles 行主序裁切/补 0', () {
      // 3×2 → 2×3：旧行主序 [1,2,3 / 4,5,6]，新网格取左上 2×3，缺的补 0
      final old = [1, 2, 3, 4, 5, 6];
      final out = MapWriter.remapTiles(old, 3, 2, 2, 3);
      expect(out, [1, 2, 4, 5, 0, 0]);
      // 2×2 → 3×2（右边补 0）
      expect(MapWriter.remapTiles([1, 2, 3, 4], 2, 2, 3, 2),
          [1, 2, 0, 3, 4, 0]);
    });

    test('宽高越界/砖块数不符被拒绝', () {
      final edit = _open(fe8jp);
      final reader = MapReader(edit.rom);
      final map = reader.chapterMap(0)!;
      expect(MapWriter(edit).writeSize(0, 0, map.height, []).mode,
          MapWriteMode.unavailable);
      expect(
          MapWriter(edit)
              .writeSize(0, map.width, 65, List.filled(map.width * 65, 0))
              .mode,
          MapWriteMode.unavailable);
      expect(
          MapWriter(edit).writeSize(0, map.width, map.height,
              map.tiles.sublist(0, map.tiles.length - 1)).mode,
          MapWriteMode.unavailable);
      expect(edit.hasChanges, isFalse);
    });
  });
}
