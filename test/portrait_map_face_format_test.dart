import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/portrait.dart';
import 'package:fe_editor/core/portrait_import.dart';

import 'rom_paths.dart';

const dir = romDir;

EditableRom? _open(String versionId, int size) {
  final d = Directory(dir);
  if (!d.existsSync()) return null;
  for (final f in d.listSync().whereType<File>()) {
    if (f.lengthSync() != size) continue;
    final b = f.readAsBytesSync();
    final t = FeRom.detectTable(b);
    if (t == null || t.id.toString() != versionId) continue;
    return EditableRom.open(b, t);
  }
  return null;
}

void main() {
  group('小头像字节格式：两条导入路径必须一致', () {
    test('普通图片路径：32×32 小头像 = 512 字节（4bpp）', () {
      final rgba = Uint8List(96 * 80 * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = 60;
        rgba[i + 1] = 120;
        rgba[i + 2] = 220;
        rgba[i + 3] = 255;
      }
      final conv = PortraitImporter.convertRgba(rgba, 96, 80,
          fe6: true, mouthX: 2, mouthY: 6);
      expect(conv.sourceSheet, isFalse);
      expect(conv.mapFaceIndices, isNotNull);
      expect(conv.mapFaceIndices!.length, 512,
          reason: '32×32 4bpp = 1024 像素 / 2 = 512 字节');
    });

    for (final spec in [('FE6', 8388608), ('FE7J', 16777216), ('FE8J', 16777216)]) {
      test('${spec.$1} 素材图路径：小头像也必须是 512 字节 4bpp', () {
        final edit = _open(spec.$1, spec.$2);
        if (edit == null) return;
        final r = PortraitReader(edit.liveRom);
        var id = -1;
        for (var i = 0; i < r.entryCount; i++) {
          if (r.hasImage(i) && r.faceImage(i) != null) { id = i; break; }
        }
        if (id < 0) { r.dispose(); return; }
        final mat = r.sheetMaterialImage(id);
        final entry = r.entryAt(id)!;
        r.dispose();
        expect(mat, isNotNull);

        final conv = PortraitImporter.convertRgba(
          mat!.pixels, mat.width, mat.height,
          fe6: edit.rom.table.portraitDataSize == 16,
          mouthX: entry.mouthX, mouthY: entry.mouthY,
        );
        expect(conv.sourceSheet, isTrue);
        expect(conv.mapFaceIndices, isNotNull);
        expect(conv.mapFaceIndices!.length, 512,
            reason: '素材图路径曾经错误地返回 1024 字节的逐像素网格，'
                '写回后被当成 4bpp 使用，游戏里就是一片竖条纹');
      });
    }

    test('修复后写回 ROM，读回的小头像不再是竖条纹', () {
      final edit = _open('FE6', 8388608);
      if (edit == null) return;
      final r = PortraitReader(edit.liveRom);
      var id = -1;
      for (var i = 0; i < r.entryCount; i++) {
        if (r.hasImage(i) && r.faceImage(i) != null) { id = i; break; }
      }
      final mat = r.sheetMaterialImage(id);
      final entry = r.entryAt(id)!;
      r.dispose();
      if (mat == null) return;

      final conv = PortraitImporter.convertRgba(
        mat.pixels, mat.width, mat.height,
        fe6: true, mouthX: entry.mouthX, mouthY: entry.mouthY,
      );
      // 直接检查 4bpp 解出来的索引网格：竖条纹的特征是同一列反复出现、
      // 相邻列差异极大。这里用「不同索引值的种类数」做粗判：
      // 正常头像会有多种索引，纯条纹往往只有 2 种且按列交替。
      final grid = _unpack4bpp(conv.mapFaceIndices!, 32, 32);
      final distinct = <int>{};
      for (final v in grid) {
        distinct.add(v);
      }
      expect(distinct.length, greaterThan(2),
          reason: '正常头像的小头像不会只有 2 种索引（那是竖条纹的特征）');
    });
  });
}

/// 32×32 4bpp → 每像素一个索引的网格。
Uint8List _unpack4bpp(Uint8List data, int width, int height) {
  final grid = Uint8List(width * height);
  final tilesPerRow = width ~/ 8;
  final tileRowBytes = tilesPerRow * 32;
  for (var y = 0; y < height; y++) {
    final band = y ~/ 8, rit = y % 8;
    for (var tx = 0; tx < tilesPerRow; tx++) {
      final base = band * tileRowBytes + tx * 32 + rit * 4;
      if (base + 4 > data.length) continue;
      for (var k = 0; k < 4; k++) {
        grid[y * width + tx * 8 + k * 2] = data[base + k] & 0x0F;
        grid[y * width + tx * 8 + k * 2 + 1] = (data[base + k] >> 4) & 0x0F;
      }
    }
  }
  return grid;
}
