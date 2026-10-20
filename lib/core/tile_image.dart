import 'dart:typed_data';

/// GBA 4bpp tile 图像。
///
/// 像素以 RGBA8 逐行存放（[width] * [height] * 4 字节）。
/// 调色板索引 0 约定为透明——与 FEBuilderGBA 的 `ByteToImage16Tile`
/// 一致，肖像里背景靠它挖空。
class TileImage {
  final int width;
  final int height;
  final Uint8List pixels;

  TileImage(this.width, this.height) : pixels = Uint8List(width * height * 4);

  int alpha(int x, int y) => pixels[(y * width + x) * 4 + 3];

  void setPixel(int x, int y, int r, int g, int b, int a) {
    final i = (y * width + x) * 4;
    pixels[i] = r;
    pixels[i + 1] = g;
    pixels[i + 2] = b;
    pixels[i + 3] = a;
  }

  void clear() => pixels.fillRange(0, pixels.length, 0);

  static void blit(
    TileImage dst,
    int dx,
    int dy,
    int w,
    int h,
    TileImage src,
    int sx,
    int sy,
  ) {
    for (var y = 0; y < h; y++) {
      final ty = dy + y;
      final syy = sy + y;
      if (ty < 0 || ty >= dst.height) continue;
      if (syy < 0 || syy >= src.height) continue;
      for (var x = 0; x < w; x++) {
        final tx = dx + x;
        final sxx = sx + x;
        if (tx < 0 || tx >= dst.width) continue;
        if (sxx < 0 || sxx >= src.width) continue;
        final si = (syy * src.width + sxx) * 4;
        final di = (ty * dst.width + tx) * 4;
        dst.pixels[di] = src.pixels[si];
        dst.pixels[di + 1] = src.pixels[si + 1];
        dst.pixels[di + 2] = src.pixels[si + 2];
        dst.pixels[di + 3] = src.pixels[si + 3];
      }
    }
  }

  /// 邻近采样缩放到目标尺寸（保持比例的等比缩放由调用方算好传入）。
  TileImage scaled(int targetWidth, int targetHeight) {
    final out = TileImage(targetWidth, targetHeight);
    for (var y = 0; y < targetHeight; y++) {
      final sy = y * height ~/ targetHeight;
      for (var x = 0; x < targetWidth; x++) {
        final sx = x * width ~/ targetWidth;
        final si = (sy * width + sx) * 4;
        final di = (y * targetWidth + x) * 4;
        out.pixels[di] = pixels[si];
        out.pixels[di + 1] = pixels[si + 1];
        out.pixels[di + 2] = pixels[si + 2];
        out.pixels[di + 3] = pixels[si + 3];
      }
    }
    return out;
  }

  /// 按比例缩放进 maxW × maxH 的方框内（不放大）。
  TileImage fitIn(int maxW, int maxH) {
    final sx = maxW / width;
    final sy = maxH / height;
    final s = sx < sy ? sx : sy;
    if (s >= 1) return this;
    return scaled((width * s).round().clamp(1, maxW),
        (height * s).round().clamp(1, maxH));
  }

  /// 非透明像素占比，用于判断解码结果是否合理。
  double get opaqueRatio {
    var n = 0;
    for (var i = 3; i < pixels.length; i += 4) {
      if (pixels[i] != 0) n++;
    }
    return n / (width * height);
  }
}

/// GBA 调色板（16 色 × 15bit BGR）。
class GbaPalette {
  final List<int> argb = List<int>.filled(16, 0);

  GbaPalette();

  /// 从 ROM 的 [offset] 读 16 个颜色（32 字节）。
  factory GbaPalette.fromRom(Uint8List rom, int offset) {
    final p = GbaPalette();
    for (var i = 0; i < 16; i++) {
      final o = offset + i * 2;
      if (o + 1 >= rom.length) break;
      final c = rom[o] | (rom[o + 1] << 8);
      p.argb[i] = _bgr15(c);
    }
    return p;
  }

  static int _bgr15(int c) {
    final r = (c & 0x1F) << 3;
    final g = ((c >> 5) & 0x1F) << 3;
    final b = ((c >> 10) & 0x1F) << 3;
    return 0xFF000000 | (r << 16) | (g << 8) | b;
  }

  int color(int index) => argb[index & 0xF];
}

/// 4bpp tile 解码，遍历顺序照搬 FEBuilderGBA `ImageUtil.ByteToImage16Tile`：
///
/// 图像由 8×8 的 tile 块组成，**块内按行推进**（每行 4 字节、每字节两个
/// 相邻像素），**块间才换行**（x += 8，满了就 y += 8）。
/// 这与「整幅图按行连续排布」完全不同——后者会把 tile 顺序打乱，图会花。
TileImage decode4bpp(
  Uint8List data,
  int offset,
  int width,
  int height,
  GbaPalette palette,
) {
  final img = TileImage(width, height);
  var x = 0;
  var y = 0;
  var i = offset;
  final end = offset + width * height ~/ 2;
  while (y < height && i < end && i < data.length) {
    for (var y8 = 0; y8 < 8; y8++) {
      for (var x8 = 0; x8 < 8; x8 += 2) {
        if (i >= end || i >= data.length) return img;
        final b = data[i];
        final lo = b & 0x0F;
        final hi = (b >> 4) & 0x0F;
        final px = x + x8;
        final py = y + y8;
        if (px < width && py < height) {
          final c = palette.color(lo);
          img.setPixel(px, py, (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF,
              lo == 0 ? 0 : 0xFF);
        }
        if (px + 1 < width && py < height) {
          final c = palette.color(hi);
          img.setPixel(px + 1, py, (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF,
              hi == 0 ? 0 : 0xFF);
        }
        i++;
      }
    }
    x += 8;
    if (x >= width) {
      x = 0;
      y += 8;
    }
  }
  return img;
}
