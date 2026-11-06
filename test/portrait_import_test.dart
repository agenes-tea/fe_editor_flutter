import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';


import 'package:fe_editor/core/portrait_import.dart';
import 'package:fe_editor/core/tile_image.dart';

/// 造一张 [w]×[h] 的 RGBA 图：左上到右下渐变，带一块透明区。
Uint8List _gradient(int w, int h, {bool withHole = false}) {
  final d = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      d[i] = x * 255 ~/ (w - 1);
      d[i + 1] = y * 255 ~/ (h - 1);
      d[i + 2] = 128;
      var a = 255;
      if (withHole && x < w ~/ 2 && y < h ~/ 2) a = 0;
      d[i + 3] = a;
    }
  }
  return d;
}

/// 用项目的 decode4bpp 把索引解回像素，与预览比对：
/// 这条断言锁住「打包进 sheet」和「从 sheet 解码」是互逆的，
/// 布局写错（比如按行连续而非 tile 顺序）会立刻失败。
void expectRoundTrip(PortraitImportResult r, {required bool fe6}) {
  final colors = <int>[];
  for (var i = 0; i < 16; i++) {
    final v = r.paletteBytes[i * 2] | (r.paletteBytes[i * 2 + 1] << 8);
    final rr = (v & 0x1F) << 3;
    final gg = ((v >> 5) & 0x1F) << 3;
    final bb = ((v >> 10) & 0x1F) << 3;
    colors.add(0xFF000000 | (rr << 16) | (gg << 8) | bb);
  }
  final pal = GbaPalette();
  for (var i = 0; i < 16; i++) {
    pal.argb[i] = colors[i];
  }

  final sheetHeight =
      fe6 ? PortraitSlots.sheetHeightFe6 : PortraitSlots.sheetHeight;
  final sheet =
      decode4bpp(r.faceIndices, 0, 256, sheetHeight, pal);

  // 按六块 blit 从 sheet 取回 96×80
  for (final b in PortraitSlots.blits) {
    final dx = b[0], dy = b[1], w = b[2], h = b[3], sx = b[4], sy = b[5];
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final got = sheet.pixels[
            ((sy + y) * 256 + (sx + x)) * 4 + 3];
        final want = r.preview.pixels[
            ((dy + y) * PortraitSlots.faceWidth + (dx + x)) * 4 + 3];
        expect(got == 0, want == 0,
            reason: '第 ($dx+$x,$dy+$y) 格的透明性与预览不一致——'
                '打包布局或 tile 顺序写错了');
      }
    }
  }
}

void main() {
  group('肖像导入：核心转换', () {
    test('FE7/FE8：40 行 sheet，索引长度 5120，往返一致', () {
      final r = PortraitImporter.convertRgba(_gradient(96, 80), 96, 80);
      expect(r.faceIndices.length, 256 * 40 ~/ 2);
      expect(r.paletteBytes.length, 32);
      expect(r.preview.width, 96);
      expect(r.preview.height, 80);
      expectRoundTrip(r, fe6: false);
    });

    test('FE6：34 行 sheet，索引长度 4352，往返一致', () {
      final r = PortraitImporter.convertRgba(_gradient(96, 80), 96, 80,
          fe6: true);
      expect(r.faceIndices.length, 256 * 34 ~/ 2);
      expectRoundTrip(r, fe6: true);
    });

    test('调色板最多 16 色，且索引 0 不被任何像素使用', () {
      final r = PortraitImporter.convertRgba(_gradient(96, 80), 96, 80);
      expect(r.usedColors, lessThanOrEqualTo(16));
      expect(r.hardMapped, 0, reason: '渐变图只有少量颜色，量化不该失真');
    });

    test('透明像素写成索引 0（游戏靠它挖空背景）', () {
      final r = PortraitImporter.convertRgba(
          _gradient(96, 80, withHole: true), 96, 80);
      // 左上 48×40 应全透明
      var opaque = 0;
      for (var y = 0; y < 40; y++) {
        for (var x = 0; x < 48; x++) {
          if (r.preview.pixels[(y * 96 + x) * 4 + 3] != 0) opaque++;
        }
      }
      expect(opaque, 0, reason: '透明区不该被画出像素');
      expect(r.transparentRatio, greaterThan(0.2));
    });

    test('非 96×80 的图片会被等比放进画布（不越界、不拉伸变形）', () {
      final r = PortraitImporter.convertRgba(_gradient(200, 100), 200, 100);
      expect(r.preview.width, 96);
      expect(r.preview.height, 80);
      // 200×100 等比放进 96×80 → 宽撑满 96、高 48，上下各留 16 行透明
      for (var x = 0; x < 96; x++) {
        expect(r.preview.pixels[(2 * 96 + x) * 4 + 3], 0,
            reason: '上方留白区应透明');
      }
    });

    test('cover 模式裁掉超出部分而不是留白', () {
      final r = PortraitImporter.convertRgba(_gradient(200, 100), 200, 100,
          fit: PortraitFit.cover);
      // cover 时高度被撑满，最上面一行应有像素
      var anyOpaque = false;
      for (var x = 0; x < 96; x++) {
        if (r.preview.pixels[(0 * 96 + x) * 4 + 3] != 0) anyOpaque = true;
      }
      expect(anyOpaque, isTrue, reason: 'cover 应填满整张画布');
    });

    test('图片数据不足时报错而不是静默产出坏图', () {
      expect(
        () => PortraitImporter.convertRgba(Uint8List(10), 96, 80),
        throwsArgumentError,
      );
    });

    test('默认生成 32×32 小头像，且与主脸同色板（索引不越界）', () {
      final r = PortraitImporter.convertRgba(_gradient(96, 80), 96, 80);
      expect(r.mapFaceIndices, isNotNull);
      expect(r.mapFaceIndices!.length, 32 * 32 ~/ 2);
      expect(r.mapFacePreview, isNotNull);
      expect(r.mapFacePreview!.width, 32);
      // 小头像的颜色索引必须落在调色板范围内（同色板才不会串色）
      var used = 0;
      for (final b in r.mapFaceIndices!) {
        for (final ci in [b & 0x0F, (b >> 4) & 0x0F]) {
          if (ci >= r.usedColors) used++;
        }
      }
      expect(used, 0, reason: '小头像用了调色板外的索引，会显示成杂色');
    });

    test('关掉小头像时不产出它', () {
      final r = PortraitImporter.convertRgba(_gradient(96, 80), 96, 80,
          mapFace: false);
      expect(r.mapFaceIndices, isNull);
      expect(r.mapFacePreview, isNull);
    });

    test('纯透明图不崩，产出全索引 0', () {
      final r = PortraitImporter.convertRgba(Uint8List(96 * 80 * 4), 96, 80);
      expect(r.transparentRatio, 1.0);
      expect(r.faceIndices.every((b) => b == 0), isTrue);
    });
  });

  group('肖像导入：完整素材图（128×112）', () {
  // 从调色板字节构造 GbaPalette（与 expectRoundTrip 同一套解码）
  GbaPalette palOf(PortraitImportResult r) {
    final pal = GbaPalette();
    for (var i = 0; i < 16; i++) {
      final v = r.paletteBytes[i * 2] | (r.paletteBytes[i * 2 + 1] << 8);
      pal.argb[i] = 0xFF000000 |
          (((v & 0x1F) << 3) << 16) |
          ((((v >> 5) & 0x1F) << 3) << 8) |
          (((v >> 10) & 0x1F) << 3);
    }
    return pal;
  }

  // 造一张 FEBuilderGBA 风格的素材图：各分区颜色不同，量化后可逐区核对。
  Uint8List sheetImage() {
    const w = 128, h = 112;
    final d = Uint8List(w * h * 4);
    void fill(int x0, int y0, int x1, int y1, int r, int g, int b) {
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final i = (y * w + x) * 4;
          d[i] = r; d[i + 1] = g; d[i + 2] = b; d[i + 3] = 255;
        }
      }
    }
    // 索引 0 的透明背景色（(127,0) 取色点必须透明）
    for (var i = 0; i < w * h; i++) {
      d[i * 4 + 3] = 0;
    }
    fill(0, 0, 96, 80, 200, 0, 0);        // 正脸：红
    fill(96, 16, 128, 48, 0, 200, 0);     // 地图小头像：绿
    fill(96, 48, 128, 80, 0, 0, 200);     // 眨眼帧两格：蓝
    fill(0, 80, 96, 112, 200, 200, 0);    // 嘴型帧排：黄
    fill(96, 80, 128, 112, 20, 20, 20);   // 口7/余白：暗灰
    return d;
  }

  test('识别为素材图：face 不缩放、sourceSheet=true', () {
    final r = PortraitImporter.convertRgba(sheetImage(), 128, 112);
    expect(r.sourceSheet, isTrue);
    expect(r.preview.width, 96);
    // 正脸区是纯红色：量化后预览里不该出现缩放造成的其它颜色
    var nonRed = 0;
    for (var i = 0; i < 96 * 80; i++) {
      final o = i * 4;
      if (r.preview.pixels[o + 3] != 0 &&
          (r.preview.pixels[o] < 150 || r.preview.pixels[o + 1] > 100 ||
              r.preview.pixels[o + 2] > 100)) {
        nonRed++;
      }
    }
    expect(nonRed, 0, reason: '素材图的正脸区应原样进入画布，不混入其它分区颜色');
  });

  test('FE7/8：从帧排区提取 6 个真实嘴帧（32×96）', () {
    final r = PortraitImporter.convertRgba(sheetImage(), 128, 112);
    expect(r.mouthIndices, isNotNull);
    expect(r.mouthIndices!.length, 32 * 96 ~/ 2);
    // 帧排全是黄色 → 嘴帧索引应全部相同且非 0
    final first = r.mouthIndices![0] & 0x0F;
    expect(first, isNot(0));
    for (final b in r.mouthIndices!) {
      expect(b & 0x0F, first);
      expect((b >> 4) & 0x0F, first);
    }
  });

  test('FE7/8：眨眼帧与口7 blit 回 sheet 右侧（不是独立数据）', () {
    final r = PortraitImporter.convertRgba(sheetImage(), 128, 112);
    // sheet 里 (192,0)-(224,16) 应是眨眼帧的蓝色
    final sheet = decode4bpp(
        r.faceIndices, 0, 256, PortraitSlots.sheetHeight,
        palOf(r));
    var blue = 0, total = 0;
    for (var y = 0; y < 16; y++) {
      for (var x = 192; x < 224; x++) {
        final o = (y * 256 + x) * 4;
        if (sheet.pixels[o + 2] > 150 && sheet.pixels[o] < 100) blue++;
        total++;
      }
    }
    expect(blue, total, reason: 'sheet 右侧 (192,0) 应是素材图里眨眼帧的蓝色');
  });

  test('FE6：素材图帧排 blit 进正脸 sheet 坑位', () {
    final r = PortraitImporter.convertRgba(sheetImage(), 128, 112, fe6: true);
    expect(r.faceIndices.length, 256 * 34 ~/ 2);
    // 坑位 (192,0) 应是嘴排的黄色
    final sheet = decode4bpp(
        r.faceIndices, 0, 256, PortraitSlots.sheetHeightFe6,
        palOf(r));
    var yellow = 0, total = 0;
    for (var y = 0; y < 16; y++) {
      for (var x = 192; x < 224; x++) {
        final o = (y * 256 + x) * 4;
        if (sheet.pixels[o] > 150 && sheet.pixels[o + 1] > 150 &&
            sheet.pixels[o + 2] < 100) {
          yellow++;
        }
        total++;
      }
    }
    expect(yellow, total, reason: 'FE6 坑位 (192,0) 应是素材图帧排的黄色');
    expect(r.mouthIndices, isNull, reason: 'FE6 无独立嘴型图');
  });

  test('地图小头像取素材图自带的那张（绿色区）', () {
    final r = PortraitImporter.convertRgba(sheetImage(), 128, 112);
    expect(r.mapFaceIndices, isNotNull);
    // 32×32 全绿 → 索引一致且非 0
    final first = r.mapFaceIndices![0] & 0x0F;
    expect(first, isNot(0));
    for (final b in r.mapFaceIndices!) {
      expect(b & 0x0F, first);
    }
  });

  test('素材图全透明时报错而不是产出空脸', () {
    final blank = Uint8List(128 * 112 * 4);
    expect(
      () => PortraitImporter.convertRgba(blank, 128, 112),
      throwsArgumentError,
    );
  });
  });
}
