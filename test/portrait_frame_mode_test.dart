import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/portrait.dart';
import 'package:fe_editor/core/portrait_import.dart';
import 'package:fe_editor/core/portrait_porter.dart';
import 'package:fe_editor/core/tile_image.dart';

import 'rom_paths.dart';

const dir = romDir;

EditableRom? _open(String versionId, int size) {
  final d = Directory(dir);
  if (!d.existsSync()) return null;
  for (final f in d.listSync().whereType<File>()) {
    if (f.lengthSync() != size) continue;
    final bytes = f.readAsBytesSync();
    final table = FeRom.detectTable(bytes);
    if (table == null || table.id.toString() != versionId) continue;
    return EditableRom.open(bytes, table);
  }
  return null;
}

int _firstWithImage(PortraitReader r) {
  for (var i = 0; i < r.entryCount; i++) {
    if (r.hasImage(i) && r.faceImage(i) != null) return i;
  }
  return -1;
}

/// 一张只有两种颜色的测试图（左红右蓝），不透明。
///
/// 只用 2 色是为了让量化后的 LZ77 压得极小：烈火/圣魔原版 ROM 里
/// 最大连续空位只有几千字节（实测 FE7J 找不到 6796 字节的空位），
/// 用彩色图会撞上「找不到空闲区」而不是测到想测的行为。
Uint8List _twoTone(int w, int h) {
  final d = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final left = x < w ~/ 2;
      d[i] = left ? 220 : 20;
      d[i + 1] = 20;
      d[i + 2] = left ? 20 : 220;
      d[i + 3] = 255;
    }
  }
  return d;
}

/// 两帧是否逐像素相同。
bool _samePixels(TileImage? a, TileImage? b) {
  if (a == null || b == null) return a == b;
  if (a.width != b.width || a.height != b.height) return false;
  for (var i = 0; i < a.pixels.length; i++) {
    if (a.pixels[i] != b.pixels[i]) return false;
  }
  return true;
}

void main() {
  group('静态图 + 固定嘴型（对齐原版伊冬那种做法）', () {
    test('FE6：五帧填同一块画面，且读回后确实全同', () {
      final edit = _open('FE6', 8388608);
      if (edit == null) return;
      final reader = PortraitReader(edit.liveRom);
      final target = _firstWithImage(reader);
      final entry = reader.entryAt(target)!;
      reader.dispose();

      final conv = PortraitImporter.convertRgba(
        _twoTone(200, 240),
        200,
        240,
        fe6: true,
        mouthX: entry.mouthX,
        mouthY: entry.mouthY,
        mouthMode: PortraitFrameMode.fixed,
      );
      expect(conv.mouthMode, PortraitFrameMode.fixed);
      expect(conv.blinkMode, PortraitFrameMode.none,
          reason: '封印之剑没有眨眼帧');

      final out = PortraitPorter(edit).importFace(conv, target);
      expect(out.ok, isTrue, reason: out.message);
      expect(out.mouthMode, PortraitFrameMode.fixed);

      // 读回：五帧必须逐像素相同（原来游戏里就是这么做的）
      final after = PortraitReader(edit.liveRom);
      final f1 = after.mouthFrame(target, 1);
      expect(f1, isNotNull);
      for (var f = 2; f <= 5; f++) {
        expect(_samePixels(f1, after.mouthFrame(target, f)), isTrue,
            reason: '固定档下第 $f 帧应与第 1 帧完全相同');
      }
      after.dispose();
    });

    test('FE6：选「无嘴型」会退回固定（没有嘴型指针，做不到真正的无）', () {
      final edit = _open('FE6', 8388608);
      if (edit == null) return;
      final reader = PortraitReader(edit.liveRom);
      final target = _firstWithImage(reader);
      final entry = reader.entryAt(target)!;
      reader.dispose();

      final conv = PortraitImporter.convertRgba(
        _twoTone(200, 240),
        200,
        240,
        fe6: true,
        mouthX: entry.mouthX,
        mouthY: entry.mouthY,
        mouthMode: PortraitFrameMode.none,
      );
      // 内核就该把它归一成 fixed，而不是留下一个做不到的承诺
      expect(conv.mouthMode, PortraitFrameMode.fixed);

      final out = PortraitPorter(edit).importFace(conv, target);
      expect(out.ok, isTrue, reason: out.message);
      expect(out.mouthMode, PortraitFrameMode.fixed);
      expect(out.frameNote, isNotEmpty);
    });

    test('FE7J：固定档六帧全同，写回后读回也是全同', () {
      final edit = _open('FE7J', 16777216);
      if (edit == null) return;
      final reader = PortraitReader(edit.liveRom);
      final target = _firstWithImage(reader);
      final entry = reader.entryAt(target)!;
      reader.dispose();

      final conv = PortraitImporter.convertRgba(
        _twoTone(200, 240),
        200,
        240,
        mouthX: entry.mouthX,
        mouthY: entry.mouthY,
        mouthMode: PortraitFrameMode.fixed,
        blinkMode: PortraitFrameMode.fixed,
        mapFace: false,
      );
      expect(conv.mouthMode, PortraitFrameMode.fixed);
      expect(conv.mouthIndices, isNotNull,
          reason: '固定档也要有嘴型数据（六帧全同），不能置空指针');

      final out = PortraitPorter(edit)
          .importFace(conv, target, replaceMapFace: false);
      expect(out.ok, isTrue, reason: out.message);
      expect(out.mouthMode, PortraitFrameMode.fixed);

      final after = PortraitReader(edit.liveRom);
      final f1 = after.mouthFrame(target, 1);
      expect(f1, isNotNull, reason: '固定档必须仍然有嘴型数据');
      for (var f = 2; f <= 6; f++) {
        expect(_samePixels(f1, after.mouthFrame(target, f)), isTrue,
            reason: '固定档下第 $f 帧应与第 1 帧完全相同');
      }
      after.dispose();
    });

    test('FE7J：眨眼固定时两张眼型帧相同', () {
      final edit = _open('FE7J', 16777216);
      if (edit == null) return;
      final reader = PortraitReader(edit.liveRom);
      final target = _firstWithImage(reader);
      final entry = reader.entryAt(target)!;
      reader.dispose();

      final conv = PortraitImporter.convertRgba(
        _twoTone(200, 240),
        200,
        240,
        mouthX: entry.mouthX,
        mouthY: entry.mouthY,
        mouthMode: PortraitFrameMode.fixed,
        blinkMode: PortraitFrameMode.fixed,
        mapFace: false,
      );
      final out = PortraitPorter(edit)
          .importFace(conv, target, replaceMapFace: false);
      expect(out.ok, isTrue, reason: out.message);
      expect(out.blinkMode, PortraitFrameMode.fixed);

      final after = PortraitReader(edit.liveRom);
      final half = after.eyeFrame(target, closed: false);
      final closed = after.eyeFrame(target, closed: true);
      expect(_samePixels(half, closed), isTrue,
          reason: '眨眼固定：半目与闭眼两帧必须一模一样');
      after.dispose();
    });
  });

  group('「无」档在 FE7/8 上真正生效', () {
    test('FE7J：选「无嘴型」→ 指针置 0，读回没有嘴帧', () {
      final edit = _open('FE7J', 16777216);
      if (edit == null) return;
      final reader = PortraitReader(edit.liveRom);
      final target = _firstWithImage(reader);
      final entry = reader.entryAt(target)!;
      reader.dispose();

      final conv = PortraitImporter.convertRgba(
        _twoTone(200, 240),
        200,
        240,
        mouthX: entry.mouthX,
        mouthY: entry.mouthY,
        mouthMode: PortraitFrameMode.none,
      );
      expect(conv.mouthMode, PortraitFrameMode.none);
      expect(conv.mouthIndices, isNull);

      final out = PortraitPorter(edit).importFace(conv, target);
      expect(out.ok, isTrue, reason: out.message);
      expect(out.mouthMode, PortraitFrameMode.none);

      final after = PortraitReader(edit.liveRom);
      expect(after.entryAt(target)!.mouth, 0,
          reason: '「无嘴型」必须把 +12 指针置 0');
      after.dispose();
    });
  });

  group('素材图按所选档位取帧', () {
    test('FE8J：素材图选固定 → 六帧全同（不用图里的真帧）', () {
      final edit = _open('FE8J', 16777216);
      if (edit == null) return;
      final reader = PortraitReader(edit.liveRom);
      final id = _firstWithImage(reader);
      final material = reader.sheetMaterialImage(id)!;
      final entry = reader.entryAt(id)!;
      reader.dispose();

      final conv = PortraitImporter.convertRgba(
        material.pixels,
        material.width,
        material.height,
        mouthX: entry.mouthX,
        mouthY: entry.mouthY,
        mouthMode: PortraitFrameMode.fixed,
      );
      expect(conv.sourceSheet, isTrue);
      expect(conv.mouthMode, PortraitFrameMode.fixed);
      expect(conv.mouthIndices, isNotNull);
      // 六帧 32×16 全同 → 4bpp 压缩后应等于单帧重复；用解包比对
      final frames = _unpackMouth(conv.mouthIndices!);
      for (var f = 1; f < 6; f++) {
        expect(_sameSlice(frames, 0, f), isTrue,
            reason: '素材图选了固定档，第 $f 帧必须与第 1 帧相同');
      }
    });

    test('FE8J：素材图无嘴型 → 不给嘴型数据', () {
      final edit = _open('FE8J', 16777216);
      if (edit == null) return;
      final reader = PortraitReader(edit.liveRom);
      final id = _firstWithImage(reader);
      final material = reader.sheetMaterialImage(id)!;
      final entry = reader.entryAt(id)!;
      reader.dispose();

      final conv = PortraitImporter.convertRgba(
        material.pixels,
        material.width,
        material.height,
        mouthX: entry.mouthX,
        mouthY: entry.mouthY,
        mouthMode: PortraitFrameMode.none,
      );
      expect(conv.mouthMode, PortraitFrameMode.none);
      expect(conv.mouthIndices, isNull);
    });
  });

  group('原版事实：固定帧是合法状态', () {
    test('封印之剑 ID 189（伊冬）的五帧本来就逐像素相同', () {
      final edit = _open('FE6', 8388608);
      if (edit == null) return;
      final reader = PortraitReader(edit.liveRom);
      if (reader.entryCount <= 189) {
        reader.dispose();
        return;
      }
      final f1 = reader.mouthFrame(189, 1);
      expect(f1, isNotNull);
      for (var f = 2; f <= 5; f++) {
        expect(_samePixels(f1, reader.mouthFrame(189, f)), isTrue,
            reason: 'ID 189 是终盘那条龙，原版五帧本来就相同');
      }
      reader.dispose();
    });
  });
}

/// 32×96 嘴型图 → 每像素一个索引（用于比较各帧）。
Uint8List _unpackMouth(Uint8List packed) {
  final grid = Uint8List(32 * 96);
  const tilesPerRow = 4;
  for (var y = 0; y < 96; y++) {
    final band = y ~/ 8, rit = y % 8;
    for (var tx = 0; tx < tilesPerRow; tx++) {
      final base = band * (tilesPerRow * 32) + tx * 32 + rit * 4;
      if (base + 4 > packed.length) continue;
      for (var k = 0; k < 4; k++) {
        grid[y * 32 + tx * 8 + k * 2] = packed[base + k] & 0x0F;
        grid[y * 32 + tx * 8 + k * 2 + 1] = (packed[base + k] >> 4) & 0x0F;
      }
    }
  }
  return grid;
}

bool _sameSlice(Uint8List grid, int frameA, int frameB) {
  const size = 32 * 16;
  for (var i = 0; i < size; i++) {
    if (grid[frameA * size + i] != grid[frameB * size + i]) return false;
  }
  return true;
}
