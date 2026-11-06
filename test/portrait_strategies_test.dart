import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fe_editor/core/portrait_import.dart';

/// 一张高分多色图（平滑渐变 + 中间一块「脸」），量化策略才有可分辨的差异。
Uint8List _rich(int w, int h) {
  final d = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = (y * w + x) * 4;
      final t = (x + y) / (w + h);
      final cx = w ~/ 2, cy = h ~/ 2;
      final face = (x - cx).abs() < w ~/ 4 && (y - cy).abs() < h ~/ 4;
      if (face) {
        // 脸：暖色皮肤 + 一点明暗
        final s = 1 - (y - cy).abs() / (h ~/ 4);
        d[o] = (200 + s * 40).clamp(0, 255).toInt();
        d[o + 1] = (150 + s * 40).clamp(0, 255).toInt();
        d[o + 2] = (120 + s * 30).clamp(0, 255).toInt();
      } else {
        // 背景：冷色平滑渐变
        d[o] = (t * 255).toInt().clamp(0, 255);
        d[o + 1] = (90 + t * 120).toInt().clamp(0, 255);
        d[o + 2] = (200 - t * 150).toInt().clamp(0, 255);
      }
      d[o + 3] = face ? 255 : 255;
    }
  }
  return d;
}

int _facePixelDiff(Uint8List a, Uint8List b) {
  var n = 0;
  final len = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < len; i++) {
    if (a[i] != b[i]) n++;
  }
  return n;
}

void main() {
  group('多量化策略（convertAll）', () {
    test('四种策略都产出合法结果（调色板/索引长度正确）', () {
      final variants =
          PortraitImporter.convertAll(_rich(384, 320), 384, 320, fe6: true);
      expect(variants.length, 4);
      final names = variants.map((v) => v.strategy.name).toSet();
      expect(names, {
        'natural',
        'classic',
        'dither',
        'bright',
      });
      for (final v in variants) {
        expect(v.result.faceIndices.length, 256 * 34 ~/ 2,
            reason: 'FE6 正脸 34 行');
        expect(v.result.paletteBytes.length, 32);
        expect(v.result.usedColors, greaterThanOrEqualTo(2));
        expect(v.result.usedColors, lessThanOrEqualTo(16));
        // 索引 0 保留给背景：实际色从 1 起
        expect(v.result.preview, isNotNull);
      }
    });

    test('FE7/FE8 目标：40 行 sheet', () {
      final variants =
          PortraitImporter.convertAll(_rich(384, 320), 384, 320, fe6: false);
      for (final v in variants) {
        expect(v.result.faceIndices.length, 256 * 40 ~/ 2);
      }
    });

    test('多色图上经典/明亮 与 自然 确实不同（不是一模一样的 4 张）', () {
      final variants =
          PortraitImporter.convertAll(_rich(384, 320), 384, 320, fe6: true);
      Map<String, PortraitImportResult> byName = {};
      for (final v in variants) {
        byName[v.strategy.name] = v.result;
      }
      final natural = byName['natural']!;
      final classic = byName['classic']!;
      final bright = byName['bright']!;
      // 高对比与提亮都要改动像素，facePixels 应与自然不同
      expect(_facePixelDiff(natural.facePixels, classic.facePixels),
          greaterThan(0), reason: '经典（高对比）应改动像素');
      expect(_facePixelDiff(natural.facePixels, bright.facePixels),
          greaterThan(0), reason: '明亮（提亮+饱和）应改动像素');
    });

    test('抖动策略：结果能渲染出非空白主脸，且与最近色量化不同', () {
      final variants =
          PortraitImporter.convertAll(_rich(384, 320), 384, 320, fe6: true);
      Map<String, PortraitImportResult> byName = {};
      for (final v in variants) {
        byName[v.strategy.name] = v.result;
      }
      final natural = byName['natural']!;
      final dither = byName['dither']!;
      // 抖动用误差扩散，落格与最近色法不同
      expect(_facePixelDiff(natural.facePixels, dither.facePixels),
          greaterThan(0), reason: '抖动与最近色应产生不同索引');
      // 抖动结果渲染出来仍有实际内容（不是一把透明）
      expect(dither.preview.opaqueRatio, greaterThan(0.05));
      // 抖动保留局部平均明度：硬凑像素应为 0（不误报失真）
      expect(dither.hardMapped, 0);
    });

    test('单一 strategy 参数走 convertRgba 也能拿到对应结果', () {
      final single = PortraitImporter.convertRgba(_rich(384, 320), 384, 320,
          fe6: true, strategy: PortraitQuantStrategy.bright);
      final all = PortraitImporter.convertAll(_rich(384, 320), 384, 320,
          fe6: true);
      final bright =
          all.firstWhere((v) => v.strategy == PortraitQuantStrategy.bright);
      expect(single.previewHash, bright.result.previewHash,
          reason: 'convertRgba(strategy:) 与 convertAll 里同策略应一致');
    });

    test('全透明图：所有策略都只留背景色、不崩', () {
      final clear = Uint8List(48 * 32 * 4); // 全 0（含 alpha=0）
      final variants =
          PortraitImporter.convertAll(clear, 48, 32, fe6: true);
      for (final v in variants) {
        expect(v.result.preview.opaqueRatio, 0.0);
        expect(v.result.faceIndices,
            everyElement(0), reason: '全透明 → 全索引 0');
      }
    });
  });
}
