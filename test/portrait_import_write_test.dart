import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/portrait.dart';
import 'package:fe_editor/core/portrait_import.dart';
import 'package:fe_editor/core/portrait_porter.dart';

import 'rom_paths.dart';

/// 按「文件大小 + 识别出的版本」挑 ROM。
/// 中文文件名在 Dart 源码里写会出问题，所以按大小遍历后看识别结果。
EditableRom? _openVersion(String versionId, {int? size}) {
  // FE6 是 8MB，FE7/FE8 是 16MB；不按大小过滤会永远拿不到 FE6。
  final want = size ?? (versionId == 'FE6' ? 8388608 : 16777216);
  final dir = Directory(romDir);
  if (!dir.existsSync()) return null;
  for (final f in dir.listSync().whereType<File>()) {
    if (f.lengthSync() != want) continue;
    final bytes = f.readAsBytesSync();
    final table = FeRom.detectTable(bytes);
    if (table == null || table.id.toString() != versionId) continue;
    return EditableRom.open(bytes, table);
  }
  return null;
}

/// 造一张有明确色块的测试图：左半红、右半蓝。
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

void main() {
  group('肖像导入：写回真实 ROM', () {
    test('FE7J 替换已有条目，读回的脸与量化结果一致', () {
      final edit = _openVersion('FE7J');
      if (edit == null) {
        markTestSkipped('缺少 FE7J 16MB 样本');
        return;
      }

      const targetId = 44; // 琳
      final original = PortraitReader(edit.rom);
      final before = original.faceImage(targetId);
      expect(before, isNotNull, reason: '样本肖像应有图');
      final oldFacePtr = original.entryAt(targetId)!.unitFace;

      final data = PortraitImporter.convertRgba(_twoTone(96, 80), 96, 80);
      final out = PortraitPorter(edit).importFace(data, targetId);
      expect(out.ok, isTrue, reason: out.message);
      expect(out.targetId, targetId);
      expect(out.bytesWritten, greaterThan(0));

      final reader = PortraitReader(edit.liveRom);
      final after = reader.faceImage(targetId);
      expect(after, isNotNull);
      expect(reader.entryAt(targetId)!.unitFace, isNot(oldFacePtr),
          reason: '正脸指针应该指向新数据');

      // 左半偏红、右半偏蓝。
      // 取样点必须选在 6 块 blit 真正覆盖到的位置——96×80 拼完只覆盖 80%，
      // 四个角是空档（原版这些位置本来就不显示），落在那里会读到透明。
      final leftR = after!.pixels[(40 * 96 + 20) * 4];
      final rightB = after.pixels[(60 * 96 + 88) * 4 + 2];
      expect(leftR, greaterThan(150), reason: '左半应偏红');
      expect(rightB, greaterThan(150), reason: '右半应偏蓝');

      // 像素与量化预览一致（写回没走样）
      expect(after.pixels.length, data.preview.pixels.length);
      var diff = 0;
      // 只比对透明度：读写两侧的 RGB 都要经过 BGR555 量化，色值会有 ±8 舍入，
      // 但「哪里是实体、哪里是透明」必须完全一致（布局写错会立刻暴露）。
      for (var i = 3; i < after.pixels.length; i += 4) {
        final got = after.pixels[i] != 0;
        final want = data.preview.pixels[i] != 0;
        if (got != want) diff++;
      }
      expect(diff, 0, reason: '写回后再读出的透明区域应与预览完全一致');
      reader.dispose();

      // 撤销回原状
      edit.revertAll();
      final restored = PortraitReader(edit.liveRom).faceImage(targetId);
      expect(restored, isNotNull);
      final a = restored!.pixels;
      final b = before!.pixels;
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) fail('撤销后第 $i 个字节不一致');
      }
    });

    test('同时替换 32×32 小头像，读回的尺寸与内容都对', () {
      final edit = _openVersion('FE7J');
      if (edit == null) {
        markTestSkipped('缺少 FE7J 16MB 样本');
        return;
      }
      const targetId = 44;
      final oldMapPtr = PortraitReader(edit.rom).entryAt(targetId)!.mapFace;

      final data = PortraitImporter.convertRgba(_twoTone(96, 80), 96, 80);
      final out = PortraitPorter(edit).importFace(data, targetId);
      expect(out.ok, isTrue, reason: out.message);

      final reader = PortraitReader(edit.liveRom);
      expect(reader.entryAt(targetId)!.mapFace, isNot(oldMapPtr),
          reason: '小头像指针应换到新数据');
      final img = reader.mapFaceImage(targetId);
      expect(img, isNotNull, reason: '换后的小头像必须能解出来');
      expect(img!.width, 32);
      expect(img.height, 32);
      reader.dispose();
    });

    test('固定表情：嘴型指针置 0、眼嘴坐标推出脸外', () {
      final edit = _openVersion('FE7J');
      if (edit == null) {
        markTestSkipped('缺少 FE7J 16MB 样本');
        return;
      }
      const targetId = 44;
      final data = PortraitImporter.convertRgba(_twoTone(96, 80), 96, 80);
      final out = PortraitPorter(edit).importFace(data, targetId);
      expect(out.ok, isTrue, reason: out.message);

      final r = PortraitReader(edit.liveRom);
      final e = r.entryAt(targetId)!;
      expect(e.mouth, 0, reason: '嘴型指针置 0 = 没有嘴型帧');
      expect(r.mouthFrame(targetId, 1), isNull,
          reason: '嘴型指针为 0 时不该解出帧');
      // 坐标必须是合法小值（0xFF 是越界坐标，部分引擎分支会拿它算偏移）
      expect(e.eyeX, inInclusiveRange(0, 64));
      expect(e.eyeY, inInclusiveRange(0, 64));
      expect(e.mouthX, inInclusiveRange(0, 64));
      expect(e.mouthY, inInclusiveRange(0, 64));
      r.dispose();
    });

    test('FE6：导入保留原 sheet 的嘴型帧区，且主脸 6 块被新数据覆盖', () {
      EditableRom? fe6;
      final dir = Directory(romDir);
      for (final f in dir.listSync().whereType<File>()) {
        if (f.lengthSync() != 8388608) continue;
        final bytes = f.readAsBytesSync();
        final table = FeRom.detectTable(bytes);
        if (table == null || table.id.toString() != 'FE6') continue;
        fe6 = EditableRom.open(bytes, table);
        break;
      }
      if (fe6 == null) {
        markTestSkipped('缺少 FE6 8MB 样本');
        return;
      }

      const targetId = 1;
      // 先记下原 sheet
      final r0 = PortraitReader(fe6.liveRom);
      final before = Uint8List.fromList(r0.faceIndices(targetId)!);
      r0.dispose();

      final data = PortraitImporter.convertRgba(_twoTone(96, 80), 96, 80,
          fe6: true);
      final out = PortraitPorter(fe6).importFace(data, targetId);
      expect(out.ok, isTrue, reason: out.message);

      final reader = PortraitReader(fe6.liveRom);
      final after = reader.faceIndices(targetId)!;
      reader.dispose();

      // 新语义：6 块之外（含 x≥192 的嘴型帧区）保留原样。
      // 全清 0 会让「写回原图也花」—— 那是真实踩过的坑。
      expect(after.length, before.length);
      var kept = 0, changed = 0;
      for (var i = 0; i < after.length; i++) {
        if (after[i] == before[i]) {
          kept++;
        } else {
          changed++;
        }
      }
      expect(changed, greaterThan(0), reason: '主脸 6 块应该被新数据覆盖');
      expect(kept, greaterThan(0), reason: '6 块之外的区域应原样保留');
    });

    test('目标 ID 越界时拒绝，且一个字节都不写', () {
      final edit = _openVersion('FE7J');
      if (edit == null) {
        markTestSkipped('缺少 FE7J 16MB 样本');
        return;
      }
      final data = PortraitImporter.convertRgba(_twoTone(96, 80), 96, 80);
      final out = PortraitPorter(edit).importFace(data, 99999);
      expect(out.ok, isFalse);
      expect(out.result, PortraitImportOutcome.noTargetEntry);
      expect(edit.edits, isEmpty, reason: '校验失败不该留下任何改动');
    });

    // 回归：指针落到奇数地址 → 游戏按 halfword 读调色板 → 整张图花屏，
    // 而 App 自己逐字节读所以显示正常（「App 正常、游戏花」的典型症状）。
    for (final v in ['FE6', 'FE7J']) {
      test('$v：导入后正脸/调色板地址必须 4 字节对齐', () {
        final edit = _openVersion(v);
        if (edit == null) {
          markTestSkipped('缺少 $v 样本');
          return;
        }
        final fe6 = edit.rom.table.portraitDataSize == 16;
        final data = PortraitImporter.convertRgba(_twoTone(96, 80), 96, 80,
            fe6: fe6);
        final out = PortraitPorter(edit).importFace(data, 1);
        expect(out.ok, isTrue, reason: out.message);

        final reader = PortraitReader(edit.liveRom);
        final e = reader.entryAt(1)!;
        reader.dispose();
        expect(e.unitFace % 4, 0, reason: '正脸地址 ${e.unitFace} 未对齐');
        expect(e.palette % 4, 0, reason: '调色板地址 ${e.palette} 未对齐');
        if (e.mapFace > 0) {
          expect(e.mapFace % 4, 0, reason: '小头像地址 ${e.mapFace} 未对齐');
        }
      });
    }
    // 回归（v2.4.31 修）：FE6 的正脸 sheet 是 34 行，尾部 y≥32 那两行不在
    // 6 块 blit 内。早期版本会「预填原 sheet」，于是那两行留着**旧角色**的像素；
    // 游戏拿到的就是「上半新脸 + 下半旧人」的错位画面，表现为嘴部往下全是碎片。
    // 这里锁两件事：① 写进去的每一个字节都能原样解回来；② 嘴型四格已被新脸覆盖。
    test('FE6：写回整张 sheet 逐字节可往返，不留旧角色像素', () {
      final edit = _openVersion('FE6');
      if (edit == null) {
        markTestSkipped('缺少 FE6 8MB 样本');
        return;
      }
      const targetId = 1;
      final oldEntry = PortraitReader(edit.rom).entryAt(targetId)!;
      final data = PortraitImporter.convertRgba(_twoTone(96, 80), 96, 80,
          fe6: true, mouthX: oldEntry.mouthX, mouthY: oldEntry.mouthY);
      final out = PortraitPorter(edit).importFace(data, targetId);
      expect(out.ok, isTrue, reason: out.message);

      final reader = PortraitReader(edit.liveRom);
      final sheet = reader.faceIndices(targetId)!;
      reader.dispose();

      // ① 与写入源逐字节一致
      expect(sheet.length, data.faceIndices.length);
      for (var i = 0; i < sheet.length; i++) {
        if (sheet[i] != data.faceIndices[i]) {
          fail('第 $i 个字节与写入源不一致（0x${sheet[i].toRadixString(16)} '
              'vs 0x${data.faceIndices[i].toRadixString(16)}）');
        }
      }

      // ② 嘴型四格已换成新脸内容（不是旧图的残留）
      final grid = Uint8List(256 * 34);
      for (var y = 0; y < 34; y++) {
        for (var tx = 0; tx < 32; tx++) {
          final base = (y ~/ 8) * (32 * 32) + tx * 32 + (y % 8) * 4;
          if (base + 4 > sheet.length) continue;
          for (var k = 0; k < 4; k++) {
            final x = tx * 8 + k * 2;
            grid[y * 256 + x] = sheet[base + k] & 0x0F;
            grid[y * 256 + x + 1] = (sheet[base + k] >> 4) & 0x0F;
          }
        }
      }
      var mouthNonZero = 0;
      for (final slot in [
        const [192, 0, 32, 16],
        const [224, 0, 32, 16],
        const [192, 16, 32, 16],
        const [224, 16, 32, 16],
      ]) {
        for (var y = slot[1]; y < slot[1] + slot[3]; y++) {
          for (var x = slot[0]; x < slot[0] + slot[2]; x++) {
            if (grid[y * 256 + x] != 0) mouthNonZero++;
          }
        }
      }
      expect(mouthNonZero, greaterThan(0),
          reason: '嘴型四格必须被新脸重铺，否则游戏会贴旧角色的嘴');
    });
    // 回归（v2.4.31 修）：导入图往往只用 2~6 色，早期 `encodePalette` 把
    // 剩下的 14 格补成 0（黑）。引擎会拿这些索引去画新脸没覆盖到的格子，
    // 于是脸周围浮出一片纯黑色块（实测同一帧里有 1933 个纯黑像素）。
    test('FE6：未用到的调色板格子填背景色，不补黑', () {
      final edit = _openVersion('FE6');
      if (edit == null) {
        markTestSkipped('缺少 FE6 8MB 样本');
        return;
      }
      const targetId = 1;
      final oldEntry = PortraitReader(edit.rom).entryAt(targetId)!;
      final data = PortraitImporter.convertRgba(_twoTone(96, 80), 96, 80,
          fe6: true, mouthX: oldEntry.mouthX, mouthY: oldEntry.mouthY);
      final out = PortraitPorter(edit).importFace(data, targetId);
      expect(out.ok, isTrue, reason: out.message);

      final reader = PortraitReader(edit.liveRom);
      final pal = reader.paletteBytes(targetId)!;
      reader.dispose();
      expect(pal.length, 32);

      // 索引 0 必须是原条目的背景色（不是黑）
      final c0 = pal[0] | (pal[1] << 8);
      expect(c0, isNot(0), reason: '索引 0 不能是黑色');

      // 补位格子也不能是黑色
      var black = 0;
      for (var i = 1; i < 16; i++) {
        final v = pal[i * 2] | (pal[i * 2 + 1] << 8);
        if (v == 0) black++;
      }
      expect(black, 0, reason: '不应有补成黑色的调色板格子');
    });
  });
}
