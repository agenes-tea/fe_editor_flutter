import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import 'portrait.dart' show PortraitEntry;
import 'tile_image.dart';

/// PNG 同步解码（只支持非交错 8 位 RGB/RGBA/灰度/调色板）。
///
/// 用 `dart:io` 的 [ZLibCodec]：**同步**，所以核心层与 MCP 都能用，
/// 不必依赖 `dart:ui` 的异步回调（那条路在 widget 测试里不推进）。
/// JPG 等其它格式仍需界面层用 `instantiateImageCodec` 先转成 RGBA。
class PngDecoder {
  /// 解码成 RGBA8；不支持的格式返回 null。
  static Uint8List? decodeRgba(Uint8List png, {int? outWidth, int? outHeight}) {
    if (png.length < 8) return null;
    const sig = [137, 80, 78, 71, 13, 10, 26, 10];
    for (var i = 0; i < 8; i++) {
      if (png[i] != sig[i]) return null;
    }

    var pos = 8;
    var width = 0, height = 0, bitDepth = 0, colorType = 0, interlace = 0;
    final idat = BytesBuilder(copy: false);
    Uint8List? palette;
    Uint8List? trns;

    while (pos + 8 <= png.length) {
      final len = (png[pos] << 24) |
          (png[pos + 1] << 16) |
          (png[pos + 2] << 8) |
          png[pos + 3];
      final type = String.fromCharCodes(png.sublist(pos + 4, pos + 8));
      final start = pos + 8;
      if (len < 0 || start + len > png.length) return null;
      final data = Uint8List.sublistView(png, start, start + len);

      switch (type) {
        case 'IHDR':
          if (len < 13) return null;
          width = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
          height = (data[4] << 24) | (data[5] << 16) | (data[6] << 8) | data[7];
          bitDepth = data[8];
          colorType = data[9];
          interlace = data[12];
          break;
        case 'PLTE':
          palette = data;
          break;
        case 'tRNS':
          trns = data;
          break;
        case 'IDAT':
          idat.add(data);
          break;
        case 'IEND':
          pos = png.length;
          continue;
      }
      pos = start + len + 4; // 跳 CRC
    }

    if (width <= 0 || height <= 0 || bitDepth != 8 || interlace != 0) {
      return null;
    }
    final channels = switch (colorType) {
      0 => 1, // 灰度
      2 => 3, // RGB
      3 => 1, // 调色板索引
      4 => 2, // 灰度 + alpha
      6 => 4, // RGBA
      _ => 0,
    };
    if (channels == 0) return null;
    if (colorType == 3 && palette == null) return null;

    final raw = Uint8List.fromList(
        ZLibCodec().decode(idat.toBytes()));
    final stride = width * channels;
    if (raw.length < (stride + 1) * height) return null;

    // 去行过滤（PNG 每行开头 1 字节的 filter type）
    final pixels = Uint8List(stride * height);
    for (var y = 0; y < height; y++) {
      final filter = raw[y * (stride + 1)];
      final src = y * (stride + 1) + 1;
      final dst = y * stride;
      for (var x = 0; x < stride; x++) {
        final a = x >= channels ? pixels[dst + x - channels] : 0;
        final b = y > 0 ? pixels[dst - stride + x] : 0;
        final c =
            (x >= channels && y > 0) ? pixels[dst - stride + x - channels] : 0;
        final v = raw[src + x];
        final out = switch (filter) {
          0 => v,
          1 => v + a,
          2 => v + b,
          3 => v + ((a + b) >> 1),
          4 => v + _paeth(a, b, c),
          _ => v,
        };
        pixels[dst + x] = out & 0xFF;
      }
    }

    final rgba = Uint8List(width * height * 4);
    for (var i = 0; i < width * height; i++) {
      final o = i * 4;
      switch (colorType) {
        case 0:
          final g = pixels[i];
          rgba[o] = g;
          rgba[o + 1] = g;
          rgba[o + 2] = g;
          rgba[o + 3] = 255;
        case 2:
          rgba[o] = pixels[i * 3];
          rgba[o + 1] = pixels[i * 3 + 1];
          rgba[o + 2] = pixels[i * 3 + 2];
          rgba[o + 3] = 255;
        case 3:
          final idx = pixels[i];
          if (idx * 3 + 2 >= palette!.length) return null;
          rgba[o] = palette[idx * 3];
          rgba[o + 1] = palette[idx * 3 + 1];
          rgba[o + 2] = palette[idx * 3 + 2];
          rgba[o + 3] = (trns != null && idx < trns.length) ? trns[idx] : 255;
        case 4:
          final g = pixels[i * 2];
          rgba[o] = g;
          rgba[o + 1] = g;
          rgba[o + 2] = g;
          rgba[o + 3] = pixels[i * 2 + 1];
        case 6:
          rgba[o] = pixels[i * 4];
          rgba[o + 1] = pixels[i * 4 + 1];
          rgba[o + 2] = pixels[i * 4 + 2];
          rgba[o + 3] = pixels[i * 4 + 3];
      }
    }
    return rgba;
  }

  static int _paeth(int a, int b, int c) {
    final p = a + b - c;
    final pa = (p - a).abs();
    final pb = (p - b).abs();
    final pc = (p - c).abs();
    if (pa <= pb && pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
  }
}

/// 面部锚点：目标条目原本记录的眼睛位置（像素）。
///
/// 原版用 `eyeX/eyeY` 标记「眼睛帧该叠在脸内哪个位置」，它天然指出了
/// 这张脸的五官在哪，用来给小头像取景比猜外接框可靠。
class PortraitMapAnchor {
  /// 眼睛中心的 x（像素）。
  final int eyeX;

  /// 眼睛中心的 y（像素）。
  final int eyeY;

  /// 坐标是否可用：`0,0` 表示该条目没配眼睛帧（原版里确实有这种偷懒条目）。
  final bool valid;

  const PortraitMapAnchor(this.eyeX, this.eyeY) : valid = eyeX > 0 || eyeY > 0;

  /// 从肖像条目的 `eyeX/eyeY`（8 像素格坐标）构造。
  factory PortraitMapAnchor.fromEntry(PortraitEntry e) =>
      PortraitMapAnchor(e.eyeX * 8, e.eyeY * 8);
}

/// 32×32 小头像的裁切方式。
///
/// 原版小头像是「头部特写」，所以默认 [head]：只取脸部上部居中一块，
/// 整张缩下去（[full]）会让五官压得看不清。
enum PortraitMapCrop {
  /// 头部特写（推荐）：96×80 里取 32×32 的脸部区域。
  head,

  /// 整张脸压到 32×32。
  full,
}

/// 图片与 96×80 画布的贴合方式。
enum PortraitFit {
  /// 等比缩放完整放进画布，空出的部分留透明。
  contain,

  /// 等比放大填满画布，超出部分居中裁掉。
  cover,
}

/// 量化（Quantization）策略：同一张图一键生成多张风格不同的预览，让用户点选。
///
/// 全部策略共用同一套「中位切分量化 + 16 色 GBA 调色板」骨架，差别只在
/// 量化前对像素做怎样的预处理、以及最终像素到 15 色里选哪一格（最近 vs 抖动）。
enum PortraitQuantStrategy {
  /// 默认：中位切分 + 最近色，无预处理。最接近原图明暗。
  natural('自然', '中位切分 + 最近色，保留原图明暗，不抖动'),

  /// 原版质感：拉高对比度后纯色块（不抖动），还原老 GBA 火纹的硬色块观感。
  classic('原版质感', '高对比 + 纯色块（不抖动），尽量还原老 GBA 火纹质感'),

  /// 细腻渐变：不预处理，用 Floyd–Steinberg 误差扩散抖动，让色块过渡更柔和、
  /// 保留原图亮度渐变，适合画法复杂的二次元图。
  dither('细腻渐变', '误差扩散抖动，保留亮度与渐变，色块过渡更柔和'),

  /// 明亮色彩：提亮暗部 + 提饱和后再量化，让角色更醒目，画面更「亮」。
  bright('明亮色彩', '提亮暗部 + 提饱和，角色更显眼、画面更亮');

  const PortraitQuantStrategy(this.label, this.desc);

  /// 界面上显示在预览下方的短标签。
  final String label;

  /// 一句说明。
  final String desc;
}

/// 一个策略的量化产物：策略本身 + 转出来的 [PortraitImportResult]。
class PortraitQuantVariant {
  final PortraitQuantStrategy strategy;
  final PortraitImportResult result;
  const PortraitQuantVariant(this.strategy, this.result);
}

/// 96×80 主脸由 6 次 blit 拼成：把 256×40 的 sheet 切成六块贴进 96×80。
///
/// 源坐标全部落在这里，**不能按行连续理解 sheet**——4bpp 是 tile 顺序，
/// 先解成 256×40 像素图再按这六块取值。顺序与 `PortraitReader.faceImage` 一致。
class PortraitSlots {
  static const int faceWidth = 96;
  static const int faceHeight = 80;
  static const int sheetWidth = 256;

  /// sheet 高度：FE7/FE8 明文 40 行；FE6 的 LZ77 只有 34 行。
  static const int sheetHeight = 40;
  static const int sheetHeightFe6 = 34;

  /// 六个 blit：(dstX, dstY, w, h, srcX, srcY)
  ///
  /// 与 `PortraitReader.faceImage` 里的六次 `TileImage.blit` 逐项对应。
  /// 第 6 块的源是 (176, 0)，不是 (160, 16)——写错会造成整块错位。
  static const List<List<int>> blits = [
    [16, 0, 64, 32, 0, 0],
    [16, 32, 64, 32, 64, 0],
    [16, 64, 32, 16, 128, 0],
    [0, 48, 16, 32, 160, 0],
    [48, 64, 32, 16, 128, 16],
    [80, 48, 16, 32, 176, 0],
  ];

  /// 嘴型图：FE7/FE8 是独立的 32×96（4 列 × 6 帧）。
  static const int mouthWidth = 32;
  static const int mouthHeight = 96;

  /// FE6 的嘴型帧画在正脸 sheet 里，四个 32×16 格子在 `(192,0) (224,0)`
  /// `(192,16) (224,16)`；帧 5 只 8 行高，分存在 `(0,32)` 与 `(32,32)`。
  /// 游戏按条目的 `mouthX/mouthY`（8 像素格）把其中一帧叠到脸上。
  static const List<List<int>> mouthFrameSlots = [
    [192, 0, 32, 16],
    [224, 0, 32, 16],
    [192, 16, 32, 16],
    [224, 16, 32, 16],
  ];

  /// 帧 5 的两个半格。
  static const List<List<int>> mouthFrame5Slots = [
    [0, 32, 32, 8],
    [32, 32, 32, 8],
  ];
}

/// 表情帧（嘴型 / 眨眼）的处理方式。
///
/// 原版三作里这三档全都有真实例子，**「全帧相同」是合法状态而不是缺陷**：
/// 实测封印之剑 230 条有图条目里有 5 条五帧逐像素相同（ID 0 山贼通用脸、
/// **189 伊冬那条终盘龙**、193/194/195），烈火 5 条（ID 1/88/93/94/186）、
/// 圣魔 5 条（ID 1/72/172/173/174）——非人类角色（龙 / 魔物 / 通用杂兵）
/// 本来就是固定嘴型，制作者是故意这么画的。眨眼同理：烈火 28 条、圣魔 20 条
/// 的两张眼帧一模一样。
///
/// 所以导入一张图时，用户应该能明确选「带帧 / 固定 / 无」，
/// 而不是由工具一律替他把表情锁死。
enum PortraitFrameMode {
  /// 用素材图里带来的真实帧（嘴会开合、眼会眨）。
  /// 只有 128×112 完整素材图才有；普通静态图选它会退回 [fixed]。
  real,

  /// 固定：所有帧填同一块内容（对齐原版伊冬那种做法）。
  /// 游戏里照常播动画，但每帧长得一样，所以看上去不动。
  fixed,

  /// 不要这组分帧。
  ///
  /// **FE7/FE8**：嘴型指针置 0 = 真正没有嘴型数据。
  /// **FE6 做不到**：它的嘴型帧画在正脸 sheet 里，条目没有嘴型指针，
  /// 游戏只要按 `mouthX/mouthY` 去贴就一定能贴到东西（见 [fixed] 的说明）。
  none,
}

/// 一次导入的产物：可直接写进 ROM 的三块数据。
class PortraitImportResult {
  /// FE7/FE8 独立嘴型图（32×96，6 帧，每帧 32×16）。
  /// 来源是素材图的帧排区，或按 [PortraitFrameMode.fixed] 填成同一块。
  /// 为 null 表示这一版不写嘴型数据（FE7/FE8 = 指针置 0）。
  final Uint8List? mouthIndices;

  /// 输入图是否被识别为完整素材图（128×112，含帧排区）。
  final bool sourceSheet;

  /// 这次实际用的嘴型处理方式（[PortraitFrameMode.real] 在普通静态图上
  /// 会退回 [PortraitFrameMode.fixed]，这里记的是**实际生效**的那档）。
  final PortraitFrameMode mouthMode;

  /// 这次实际用的眨眼处理方式（FE6 没有眼帧，恒为 [PortraitFrameMode.none]）。
  final PortraitFrameMode blinkMode;

  /// 4bpp 索引（256×40 或 256×34，取决于目标版本）。
  final Uint8List faceIndices;

  /// 32 字节 BGR555 调色板（索引 0 是背景/透明色）。
  final Uint8List paletteBytes;

  /// 量化后的 96×80 预览（RGBA，索引 0 画成透明）。
  final TileImage preview;

  /// 96×80 的 4bpp 索引（每像素一个索引，不是 sheet 打包格式）。
  /// 小头像重取景要用它——`faceIndices` 是 256×W 的打包 sheet，不能当网格读。
  final Uint8List facePixels;

  /// 32×32 地图小头像的 4bpp 索引（1024 像素 / 2）。
  /// `mapFace == false` 时为 null。
  final Uint8List? mapFaceIndices;

  /// 32×32 小头像预览，用于界面核对裁切位置。
  final TileImage? mapFacePreview;

  /// 离原图很远、属于「硬凑」的颜色数（0 表示量化质量良好）。
  final int hardMapped;

  /// 图片里透明像素占比，用来提示「背景没抠干净」。
  final double transparentRatio;

  /// 实际用到的颜色数（含背景色）。
  final int usedColors;

  /// 预览像素指纹：界面用它做缓存 key，换一张图就必须换 key。
  ///
  /// 取前若干像素的抽样哈希就行——它只用来区分「同一次会话里的两张图」，
  /// 不需要抗碰撞（两张图抽样完全相同也无伤大雅：它们看上去就是一样）。
  int get previewHash {
    final p = preview.pixels;
    var h = p.length;
    final step = p.length ~/ 64 < 4 ? 4 : p.length ~/ 64;
    for (var i = 0; i < p.length; i += step) {
      h = (h * 31 + p[i]) & 0x3FFFFFFF;
    }
    return h;
  }

  const PortraitImportResult({
    required this.faceIndices,
    required this.paletteBytes,
    required this.preview,
    required this.facePixels,
    this.mouthIndices,
    this.sourceSheet = false,
    this.mouthMode = PortraitFrameMode.real,
    this.blinkMode = PortraitFrameMode.real,
    this.mapFaceIndices,
    this.mapFacePreview,
    required this.hardMapped,
    required this.transparentRatio,
    required this.usedColors,
  });
}

/// FEBuilderGBA 导出素材图的固定布局（128×112）。
///
/// 与 `ImagePortraitForm.DrawPortraitSeet`（FE7/FE8）与
/// `ImagePortraitFE6Form.DrawPortraitSeetFE6`（FE6）的 BitBlt 位置逐项对应
/// （GPL-3.0，7743 著）。
class PortraitSheetLayout {
  static const int width = 128;
  static const int height = 112;

  /// 正脸在素材图里的位置（与 96×80 画布一致，不再缩放）。
  static const int faceX = 0, faceY = 0;

  /// 32×32 地图小头像。
  static const int mapX = 96, mapY = 16;

  /// 备用眼型两帧（FE7/FE8：とろん目 (96,48)、閉じ目 (96,64)；FE6 素材图无眼帧区）。
  static const int eyeX = 96, eyeY = 48;

  /// 嘴型帧排起点：两排 6 帧（FE7/FE8），FE6 是 2×2 四帧 + 右侧帧 5。
  static const int mouthY = 80;
}

/// 把任意图片转成 GBA 火纹肖像数据。
///
/// 流程：RGBA →（缩放/裁切到 96×80）→ 中位切分量化为 15 色 + 1 个背景色
/// → 铺回 256×40 的 sheet 布局 → 输出 4bpp 索引与调色板字节。
///
/// **纯同步、不碰 `dart:ui`**：图片解码属于界面层（`instantiateImageCodec`
/// 是异步回调，在 widget 测试里不推进），这里只接受裸 RGBA 字节，
/// 保证核心逻辑可以在测试里直接跑。
class PortraitImporter {
  /// [rgba] 为 `width * height * 4` 的 RGBA8。
  ///
  /// 输出索引图的透明像素一律写成 0：游戏把调色板索引 0 当透明，
  /// 所以索引 0 不能被任何实际颜色占用。
  static PortraitImportResult convertRgba(
    Uint8List rgba,
    int width,
    int height, {
    bool fe6 = false,
    PortraitFit fit = PortraitFit.contain,
    int alphaThreshold = 8,
    bool mapFace = true,
    PortraitMapCrop crop = PortraitMapCrop.head,
    PortraitMapAnchor? anchor,
    Uint8List? originalSheet,
    int? mouthX,
    int? mouthY,
    int? index0Color,
    PortraitQuantStrategy strategy = PortraitQuantStrategy.natural,
    PortraitFrameMode mouthMode = PortraitFrameMode.real,
    PortraitFrameMode blinkMode = PortraitFrameMode.real,
  }) {
    if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
      throw ArgumentError(
          '图片数据不完整：$width×$height 需要 ${width * height * 4} 字节，'
          '实际 ${rgba.length}');
    }

    // 完整素材图（128×112）单独走分区提取：正脸不再缩放，嘴型/眨眼帧
    // 直接取素材图里的真实帧，写回后游戏里嘴会动、眼会眨。
    if (_isSheetInput(width, height)) {
      return _convertSheet(rgba,
          fe6: fe6,
          alphaThreshold: alphaThreshold,
          mapFace: mapFace,
          mouthX: mouthX,
          mouthY: mouthY,
          index0Color: index0Color,
          mouthMode: mouthMode,
          blinkMode: blinkMode);
    }

    final face = _fitToFace(rgba, width, height, fit, alphaThreshold);
    final quant = _quantize(face, alphaThreshold, strategy);

    final sheetHeight =
        fe6 ? PortraitSlots.sheetHeightFe6 : PortraitSlots.sheetHeight;
    final indices =
        Uint8List(PortraitSlots.sheetWidth * sheetHeight ~/ 2);
    // 原 sheet 先整体拷过来：6 块 blit 之外的区域（含 FE6 的嘴型帧区、
    // 对话框遮住的边缘）原版本来就有数据，全清 0 会让游戏把那些位置
    // 画成空白/杂色（实测「写回原图也会花」就是这个原因）。
    if (originalSheet != null && originalSheet.length == indices.length) {
      indices.setRange(0, indices.length, originalSheet);
    }
    _spreadFaceToSheet(quant.indices, indices, sheetHeight);
    // FE6 的嘴型帧画在同一张 sheet 里，游戏按 mouthX/mouthY 把它们叠到脸上。
    // 不重画就会保留旧角色的嘴，换脸后那一块仍是旧人（实测的「嘴开始花」）。
    //
    // 「真实帧」只有完整素材图才有。普通静态图选了 real 该怎么办：
    // - 退回 fixed 会**凭空多写 1536 字节嘴型数据**（六帧同一块），
    //   在烈火/圣魔这种空位紧张的原版 ROM 上会直接把「找不到空闲区」顶出来，
    //   而且用户根本没要求过动画——旧行为是不写；
    // - 所以退回 none，保持与旧实现一致：普通图默认不带嘴型数据。
    //   想要固定嘴型请显式选「固定」。
    final mouthResolved =
        mouthMode == PortraitFrameMode.real ? PortraitFrameMode.none : mouthMode;
    // FE6 没有嘴型指针：扇区总是会被 `_spreadMouthFrames` 重铺（那是换脸必须的），
    // 所以「无嘴型」在这个版本上只能表现为固定，结果里如实记录。
    final mouthForFe6 = mouthResolved == PortraitFrameMode.none
        ? PortraitFrameMode.fixed
        : mouthResolved;
    if (fe6) {
      _spreadMouthFrames(quant.indices, indices,
          mouthX: mouthX, mouthY: mouthY);
    }

    // 小头像：从同一张量化结果裁切缩放，所以与主脸同色板
    Uint8List? mapIndices;
    TileImage? mapPreview;
    if (mapFace) {
      final crop32 = _cropForMapFace(quant.indices, crop, anchor);
      mapPreview = _renderSmall(crop32, quant.colors);
      mapIndices = _encodeSmall4bpp(crop32);
    }

    // FE7/FE8 的嘴型是独立指针：固定档就把同一块嘴区复制成 6 帧，
    // 不要档就留 null（写回时指针置 0）。
    Uint8List? mouthIndices;
    if (!fe6 && mouthResolved == PortraitFrameMode.fixed) {
      mouthIndices = _fixedMouthStrip(quant.indices, mouthX: mouthX, mouthY: mouthY);
    }

    return PortraitImportResult(
      faceIndices: indices,
      paletteBytes: encodePalette(quant.colors, index0Color: index0Color),
      preview: renderPreview(quant.indices, quant.colors),
      facePixels: quant.indices,
      mouthIndices: mouthIndices,
      mouthMode: fe6 ? mouthForFe6 : mouthResolved,
      blinkMode: fe6 ? PortraitFrameMode.none : blinkMode,
      mapFaceIndices: mapIndices,
      mapFacePreview: mapPreview,
      hardMapped: quant.hardMapped,
      transparentRatio: quant.transparentRatio,
      usedColors: quant.colors.length,
    );
  }

  /// 一键生成全部 [PortraitQuantStrategy] 的预览（用于界面上并排点选）。
  ///
  /// 同一张图、同样的贴合/地图头像等参数，只换量化策略，返回 4 个变体。
  /// 完整素材图（[convertRgba] 会走 [\_convertSheet]）不随策略变化，
  /// 4 个变体会完全相同——界面层据此收敛成单张即可。
  static List<PortraitQuantVariant> convertAll(
    Uint8List rgba,
    int width,
    int height, {
    bool fe6 = false,
    PortraitFit fit = PortraitFit.contain,
    int alphaThreshold = 8,
    bool mapFace = true,
    PortraitMapCrop crop = PortraitMapCrop.head,
    PortraitMapAnchor? anchor,
    Uint8List? originalSheet,
    int? mouthX,
    int? mouthY,
    int? index0Color,
    PortraitFrameMode mouthMode = PortraitFrameMode.real,
    PortraitFrameMode blinkMode = PortraitFrameMode.real,
  }) {
    return [
      for (final s in PortraitQuantStrategy.values)
        PortraitQuantVariant(
          s,
          convertRgba(
            rgba,
            width,
            height,
            fe6: fe6,
            fit: fit,
            alphaThreshold: alphaThreshold,
            mapFace: mapFace,
            crop: crop,
            anchor: anchor,
            originalSheet: originalSheet,
            mouthX: mouthX,
            mouthY: mouthY,
            index0Color: index0Color,
            strategy: s,
            mouthMode: mouthMode,
            blinkMode: blinkMode,
          ),
        ),
    ];
  }

  /// 输入是不是 FEBuilderGBA 导出的完整素材图。
  ///
  /// 两作导出图都是 128×112；宽高吻合即认（普通图片恰好 128×112 会被
  /// 误认的概率极低，且误认的后果只是「不缩放直接取左上 96×80」，
  /// 用户选「填满裁切」也能救回来）。
  static bool _isSheetInput(int width, int height) {
    return width == PortraitSheetLayout.width &&
        height == PortraitSheetLayout.height;
  }

  /// 完整素材图的分区提取。
  ///
  /// 素材图已经是**游戏坐标系**（正脸就是 96×80 原样），所以：
  /// - 正脸：直接量化 (0,0)-(96,80)，不做缩放；
  /// - 嘴型帧：FE7/FE8 取底部两排 6 帧（32×96）；FE6 取 2×2 四帧 + 右侧帧 5；
  /// - 眨眼帧：FE7/FE8 取 (96,32)/(96,48) 两帧；FE6 素材图无眼帧区；
  /// - 地图小头像：优先取素材图 (96,16) 那块**原版手绘**，比算法裁切准；
  /// - 整体一套调色板：16 色在**全图**上统计，脸/嘴/眼/小头像同色板不串色。
  static PortraitImportResult _convertSheet(
    Uint8List rgba, {
    required bool fe6,
    required int alphaThreshold,
    required bool mapFace,
    int? mouthX,
    int? mouthY,
    int? index0Color,
    PortraitFrameMode mouthMode = PortraitFrameMode.real,
    PortraitFrameMode blinkMode = PortraitFrameMode.real,
  }) {
    const lw = PortraitSheetLayout.width;
    const lh = PortraitSheetLayout.height;
    // 素材图的透明色就是索引 0（FEBuilderGBA 导出时写在 (127,0)）。
    final index0 = _pixel(rgba, lw, 127, 0);

    // 全图统计颜色（透明区跳过）——所有分区共用一套 16 色调色板
    final samples = <int>[];
    for (var i = 0; i < lw * lh; i++) {
      final o = i * 4;
      if (rgba[o + 3] <= alphaThreshold) continue;
      samples.add((rgba[o] << 16) | (rgba[o + 1] << 8) | rgba[o + 2]);
    }
    if (samples.isEmpty) {
      throw ArgumentError('素材图里没有不透明像素');
    }
    final colors = _medianCut(samples, 15);
    final palette = <int>[index0, ...colors];

    // 全图建索引（一次性，所有分区从同一张索引图上取）
    final grid = Uint8List(lw * lh);
    var hardMapped = 0;
    for (var i = 0; i < grid.length; i++) {
      final o = i * 4;
      if (rgba[o + 3] <= alphaThreshold) continue;
      final c = (rgba[o] << 16) | (rgba[o + 1] << 8) | rgba[o + 2];
      var best = 0;
      var bestDist = 1 << 30;
      for (var k = 0; k < palette.length; k++) {
        final d = _dist2(c, palette[k]);
        if (d < bestDist) {
          bestDist = d;
          best = k;
        }
      }
      grid[i] = best;
      if (bestDist > 64 * 64 * 3) hardMapped++;
    }

    // 正脸 96×80 索引（原样，不缩放）
    final face = Uint8List(96 * 80);
    for (var y = 0; y < 80; y++) {
      for (var x = 0; x < 96; x++) {
        face[y * 96 + x] = grid[y * lw + x];
      }
    }

    // FE6 没有嘴型指针，也不支持眨眼：把两档都归成实际能做的形状，
    // 而不是默默忽略用户的选择。
    final mouthEffective = fe6 && mouthMode == PortraitFrameMode.none
        ? PortraitFrameMode.fixed
        : mouthMode;

    // 地图小头像：素材图自带原版手绘那张
    Uint8List? mapIndices;
    TileImage? mapPreview;
    if (mapFace) {
      // 先从素材图的 (96,16) 块抠出 32×32 索引网格，再打包成 4bpp。
      //
      // **必须打包成 4bpp（512 字节）**，不能直接交 1024 字节的逐像素网格：
      // 普通图片路径（`_encodeSmall4bpp`）产出的是 4bpp，写回时 porter 直接
      // 把这块字节写进 ROM（FE6 无压缩 / FE7·8 再 LZ77）。把 1024 字节的网格
      // 当 4bpp 用，每两个像素抢一个字节，游戏里就是一片竖条纹——
      // 而且导出成 128×112 素材图时，右上角那块也是条纹（同一份错数据）。
      final mapGrid = Uint8List(32 * 32);
      for (var y = 0; y < 32; y++) {
        for (var x = 0; x < 32; x++) {
          mapGrid[y * 32 + x] = grid[
              (PortraitSheetLayout.mapY + y) * lw +
                  PortraitSheetLayout.mapX +
                  x];
        }
      }
      mapIndices = _encodeSmall4bpp(mapGrid);
      mapPreview = _renderSmall(mapGrid, palette);
    }

    // 嘴型帧（FE7/FE8：底部两排 6 帧 → 32×96 独立嘴型图，4bpp 打包）
    Uint8List? mouth;
    if (!fe6) {
      if (mouthMode == PortraitFrameMode.none) {
        // 不要嘴型：留给 porter 把指针置 0
      } else if (mouthMode == PortraitFrameMode.fixed) {
        mouth = _fixedMouthStrip(face, mouthX: mouthX, mouthY: mouthY);
      } else {
        final mgrid = Uint8List(32 * 96);
        for (var f = 0; f < 6; f++) {
          final col = f % 3, row = f ~/ 3;
          final sx = col * 32;
          final sy = PortraitSheetLayout.mouthY + row * 16;
          for (var y = 0; y < 16; y++) {
            for (var x = 0; x < 32; x++) {
              mgrid[f * 16 * 32 + y * 32 + x] =
                  grid[(sy + y) * lw + sx + x];
            }
          }
        }
        mouth = _pack4bpp(mgrid, 32, 96);
      }
    }

    final sheetHeight =
        fe6 ? PortraitSlots.sheetHeightFe6 : PortraitSlots.sheetHeight;
    final indices = Uint8List(PortraitSlots.sheetWidth * sheetHeight ~/ 2);
    _spreadFaceToSheet(face, indices, sheetHeight);
    if (fe6) {
      _spreadFe6SheetMouthFrames(grid, lw, indices, sheetHeight);
    } else {
      // 眨眼：两张眼型帧在正脸 sheet 右侧（(192,0) とろん目 / (192,16) 闭眼）。
      // 固定档把第一帧复制到第二帧；不要档就保留 sheet 里原有的（FE7/FE8 的
      // 眼帧没有独立指针，无法真正关掉，只能让他两帧一样）。
      _spreadFe78SheetParts(grid, lw, indices,
          blinkMode: fe6 ? PortraitFrameMode.none : blinkMode);
    }

    return PortraitImportResult(
      faceIndices: indices,
      paletteBytes: encodePalette(palette, index0Color: index0),
      preview: renderPreview(face, palette),
      facePixels: face,
      mouthIndices: mouth,
      sourceSheet: true,
      mouthMode: mouthEffective,
      blinkMode: fe6 ? PortraitFrameMode.none : blinkMode,
      mapFaceIndices: mapIndices,
      mapFacePreview: mapPreview,
      hardMapped: hardMapped,
      transparentRatio: 0,
      usedColors: palette.length,
    );
  }

  /// FE6 素材图的嘴型帧排 → 正脸 sheet 坑位。
  ///
  /// 素材图布局（`DrawPortraitSeetFE6`）：嘴型 2×2 四帧在 (0,80)-(64,112)，
  /// 帧 5 的两半在 (96,80) 与 (96,88)（各 8 行高）。
  /// FE7/FE8 备用眼型两帧与第 7 口帧画在**正脸 sheet 右侧**
  /// （(192,0) とろん目、(192,16) 閉じ目、(224,0) 口7），没有独立指针——
  /// 所以 sheet 输入时必须 blit 回 sheet，而不是另写一块数据。
  /// 对应 `ImagePortraitForm.DrawPortraitUnit` 的眼/口7 取图位置。
  static void _spreadFe78SheetParts(Uint8List grid, int lw, Uint8List sheet,
      {PortraitFrameMode blinkMode = PortraitFrameMode.real}) {
    const sw = PortraitSlots.sheetWidth;
    const sheetH = PortraitSlots.sheetHeight;
    final out = _unpackGrid(sheet, sheetH);

    void blitRect(int dstX, int dstY, int srcX, int srcY) {
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 32; x++) {
          out[(dstY + y) * sw + dstX + x] = grid[(srcY + y) * lw + srcX + x];
        }
      }
    }

    blitRect(192, 0, PortraitSheetLayout.eyeX, PortraitSheetLayout.eyeY);
    if (blinkMode == PortraitFrameMode.fixed) {
      // 固定眨眼：把「半目」帧原样复到「闭眼」那一格，两眼帧长得一样，
      // 游戏照常播但看上去不闭眼（对齐原版那些两帧相同的条目）。
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 32; x++) {
          out[(16 + y) * sw + 192 + x] = out[y * sw + 192 + x];
        }
      }
    } else {
      blitRect(192, 16, PortraitSheetLayout.eyeX, PortraitSheetLayout.eyeY + 16);
    }
    // 口7（右端の口）与余白
    blitRect(224, 0, 96, PortraitSheetLayout.mouthY);
    blitRect(224, 16, 96, PortraitSheetLayout.mouthY + 16);
    _packGrid(out, sheet, sheetH);
  }

  static void _spreadFe6SheetMouthFrames(
    Uint8List grid,
    int lw,
    Uint8List sheet,
    int sheetHeight,
  ) {
    const sw = PortraitSlots.sheetWidth;
    const sheetH = PortraitSlots.sheetHeightFe6;
    final out = _unpackGrid(sheet, sheetH);
    const mw = 32, mh = 16;

    void blitRect(int dstX, int dstY, int srcX, int srcY, int w, int h) {
      for (var y = 0; y < h; y++) {
        final gy = dstY + y;
        if (gy >= sheetH) continue;
        for (var x = 0; x < w; x++) {
          out[gy * sw + dstX + x] = grid[(srcY + y) * lw + srcX + x];
        }
      }
    }

    // 2×2 四帧 → 四个 32×16 坑位（与 DrawPortraitSeetFE6 的 BitBltRev 逆变换一致）
    blitRect(192, 0, 0, PortraitSheetLayout.mouthY, mw, mh);
    blitRect(224, 0, 32, PortraitSheetLayout.mouthY, mw, mh);
    blitRect(192, 16, 0, PortraitSheetLayout.mouthY + 16, mw, mh);
    blitRect(224, 16, 32, PortraitSheetLayout.mouthY + 16, mw, mh);
    // 帧 5：素材图 (96,80) 与 (96,88) 两半
    blitRect(0, 32, 96, PortraitSheetLayout.mouthY, mw, 8);
    blitRect(32, 32, 96, PortraitSheetLayout.mouthY + 8, mw, 8);
    _packGrid(out, sheet, sheetH);
  }

  /// 按目标条目的 [mouthX]/[mouthY] 重铺 FE6 嘴型帧。
  ///
  /// **不再预填原 sheet**：FE6 的索引 0 是不透明背景色，而原 sheet 尾部
  /// （y≥32 那两行，与嘴型帧区）全是旧角色的像素——留着它们没好处，
  /// 反而会让「换脸后下半张脸是旧人」这类错位残留下来（实测 119 字节）。
  static PortraitImportResult withMouthFrames(
    PortraitImportResult base, {
    int? mouthX,
    int? mouthY,
  }) {
    if (base.faceIndices.length !=
        PortraitSlots.sheetWidth * PortraitSlots.sheetHeightFe6 ~/ 2) {
      return base;
    }
    final indices = Uint8List.fromList(base.faceIndices);
    _spreadMouthFrames(base.facePixels, indices,
        mouthX: mouthX, mouthY: mouthY);
    return PortraitImportResult(
      faceIndices: indices,
      paletteBytes: base.paletteBytes,
      preview: base.preview,
      facePixels: base.facePixels,
      mapFaceIndices: base.mapFaceIndices,
      mapFacePreview: base.mapFacePreview,
      hardMapped: base.hardMapped,
      transparentRatio: base.transparentRatio,
      usedColors: base.usedColors,
    );
  }

  /// 从 96×80 量化索引里裁一块出来再缩到 32×32。
  ///
  /// 原版小头像是「头+脸」的方形特写，而**头部在画布里的位置因人而异**
  /// （长发角色头顶偏左、侧身角色脸偏右），固定坐标必然对不齐。
  /// 所以先按不透明像素求外接框，再以外接框的**上部及其水平中心**定位，
  /// 这样同一张脸生成的小头像能复现原版构图。
  static Uint8List _cropForMapFace(
      Uint8List face, PortraitMapCrop crop, PortraitMapAnchor? anchor) {
    const fw = PortraitSlots.faceWidth;
    const fh = PortraitSlots.faceHeight;
    final (sx, sy, sw, sh) = switch (crop) {
      PortraitMapCrop.head => _headBox(face, anchor),
      PortraitMapCrop.full => (0, 0, fw, fh),
    };

    final out = Uint8List(32 * 32);
    for (var y = 0; y < 32; y++) {
      for (var x = 0; x < 32; x++) {
        final sxx = sx + (x * sw ~/ 32);
        final syy = sy + (y * sh ~/ 32);
        if (sxx < 0 || sxx >= fw || syy < 0 || syy >= fh) continue;
        out[y * 32 + x] = face[syy * fw + sxx];
      }
    }
    return out;
  }

  /// 求「头部」的取景框：以眼睛位置为中心取一块正方形，再缩到 32×32。
  ///
  /// 实测 FE7J 十二条原版肖像：**眼睛位置几乎都是 (24,24) 像素**
  /// （eyeX*8, eyeY*8），不透明区却是 x=7..93 / y=4..79 的一大片
  /// （含大量头发与肩膀）。所以不能按外接框取景——那样框到的全是头顶空白
  /// 和头发，脸被挤到角落（实测就是这么翻车的）。
  ///
  /// 取景规则：眼睛落在框内约 (16,14) 处，框边长 [side]。
  /// 没有眼睛坐标的条目（原版确实有 eyeX=eyeY=0 的偷懒条目）
  /// 退回按不透明区中心 + 上沿定位。
  static (int, int, int, int) _headBox(
      Uint8List face, PortraitMapAnchor? anchor) {
    const fw = PortraitSlots.faceWidth;
    const fh = PortraitSlots.faceHeight;
    const side = 40;

    if (anchor != null && anchor.valid) {
      // 眼睛落在框内 (16,14)：实测这组偏移在真实肖像上能把脸框在正中
      final left = (anchor.eyeX - 16).clamp(0, fw - side);
      final top = (anchor.eyeY - 14).clamp(0, fh - side);
      return (left, top, side, side);
    }

    var minX = fw, maxX = -1, minY = fh;
    for (var y = 0; y < fh; y++) {
      for (var x = 0; x < fw; x++) {
        if (face[y * fw + x] == 0) continue;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
      }
    }
    if (maxX < 0) return ((fw - side) ~/ 2, (fh - side) ~/ 2, side, side);

    // 没有眼睛坐标时按原版构图取（实测原版十二条肖像的眼睛都在
    // (24,24) 附近，脸大致落在 (8,10) 起的一块）。不透明区左沿/顶沿
    // 只做轻微偏移——图若带不透明背景，整块都会被算进外接框，
    // 按中心取景会跑到无关区域。
    final left = (minX + 8).clamp(0, fw - side);
    final top = (minY + 10).clamp(0, fh - side);
    return (left, top, side, side);
  }

  static TileImage _renderSmall(Uint8List indices, List<int> colors) {
    final img = TileImage(32, 32);
    for (var y = 0; y < 32; y++) {
      for (var x = 0; x < 32; x++) {
        final ci = indices[y * 32 + x];
        if (ci == 0) continue;
        final c = ci < colors.length ? colors[ci] : 0;
        img.setPixel(x, y, (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF, 0xFF);
      }
    }
    return img;
  }

  /// 32×32 像素索引 → 512 字节 4bpp（tile 顺序，与 decode4bpp 互逆）。
  static Uint8List _encodeSmall4bpp(Uint8List indices) {
    final out = Uint8List(32 * 32 ~/ 2);
    const w = 32;
    final tilesPerRow = w ~/ 8;
    for (var y = 0; y < 32; y++) {
      final band = y ~/ 8;
      final rowInTile = y % 8;
      for (var tx = 0; tx < tilesPerRow; tx++) {
        final base = band * (tilesPerRow * 32) + tx * 32 + rowInTile * 4;
        if (base + 4 > out.length) continue;
        for (var k = 0; k < 4; k++) {
          final lo = indices[y * w + tx * 8 + k * 2];
          final hi = indices[y * w + tx * 8 + k * 2 + 1];
          out[base + k] = (lo & 0x0F) | ((hi & 0x0F) << 4);
        }
      }
    }
    return out;
  }

  /// 用给定锚点重算 32×32 小头像，其余（主脸/调色板）原样沿用。
  ///
  /// 写回时目标条目自己带 `eyeX/eyeY`，那是这张脸的五官位置，
  /// 比按不透明区猜准，所以写之前用它重取一次景。
  static PortraitImportResult convertFromIndices(
    PortraitImportResult base, {
    PortraitMapAnchor? anchor,
    PortraitMapCrop crop = PortraitMapCrop.head,
  }) {
    if (base.mapFaceIndices == null) return base;
    final crop32 = _cropForMapFace(base.facePixels, crop, anchor);
    final colors = <int>[];
    for (var i = 0; i < 16; i++) {
      final v = base.paletteBytes[i * 2] | (base.paletteBytes[i * 2 + 1] << 8);
      final r = (v & 0x1F) << 3;
      final g = ((v >> 5) & 0x1F) << 3;
      final b = ((v >> 10) & 0x1F) << 3;
      colors.add((r << 16) | (g << 8) | b);
    }
    return PortraitImportResult(
      faceIndices: base.faceIndices,
      paletteBytes: base.paletteBytes,
      preview: base.preview,
      facePixels: base.facePixels,
      mapFaceIndices: _encodeSmall4bpp(crop32),
      mapFacePreview: _renderSmall(crop32, colors),
      hardMapped: base.hardMapped,
      transparentRatio: base.transparentRatio,
      usedColors: base.usedColors,
    );
  }

  /// 索引 + 调色板 → 96×80 预览（索引 0 透明）。写回前用它给界面看效果。
  ///
  /// **只渲染 6 块 blit 真正覆盖的区域**：96×80 拼完只占 80%，四个角
  /// （如 x<16 且 y<32、x≥80 且 y<48）在游戏里永远不会显示。
  /// 如果预览把那些位置也画出来，用户会看到一张比实际游戏里更完整的图，
  /// 改完一进游戏却缺角——所以预览必须与实际可见区域一致。
  static TileImage renderPreview(List<int> indices, List<int> colors) {
    final img = TileImage(PortraitSlots.faceWidth, PortraitSlots.faceHeight);
    for (final b in PortraitSlots.blits) {
      final dx = b[0], dy = b[1], w = b[2], h = b[3];
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final px = dx + x, py = dy + y;
          if (px < 0 ||
              px >= PortraitSlots.faceWidth ||
              py < 0 ||
              py >= PortraitSlots.faceHeight) {
            continue;
          }
          final ci = indices[py * PortraitSlots.faceWidth + px];
          if (ci == 0) continue;
          final c = ci < colors.length ? colors[ci] : 0;
          img.setPixel(px, py, (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF,
              0xFF);
        }
      }
    }
    return img;
  }

  /// 16 色 → 32 字节 BGR555。不足 16 色补 0。
  /// 16 色 → 32 字节 BGR555。不足 16 色补 0。
  ///
  /// [index0Color] 非空时用它作为索引 0 的颜色。**FE6 必须传**：
  /// 原版把索引 0 当「不透明背景色」（实测罗伊是 #78a070 绿灰），
  /// 而不是透明。正脸 6 块里约 47% 的像素是索引 0——
  /// 写成黑色就会变成「一半黑底 + 一半人物」，游戏里看着就是花屏。
  ///
  /// **不足 16 色时用索引 0 的颜色补齐，不要补黑**：
  /// 引擎会用索引 0 去填新脸未覆盖的区域（下部、嘴型帧边角），
  /// 那些格子若为黑色就表现为「脸周围一圈黑斑」（实测）。
  static Uint8List encodePalette(List<int> colors, {int? index0Color}) {
    final out = Uint8List(32);
    final fill = index0Color != null && colors.isNotEmpty ? index0Color : colors.isEmpty ? 0 : colors[0];
    for (var i = 0; i < 16; i++) {
      final int c;
      if (i == 0 && index0Color != null) {
        c = index0Color;
      } else if (i < colors.length) {
        c = colors[i];
      } else {
        c = fill;
      }
      final r = ((c >> 16) & 0xFF) * 31 ~/ 255;
      final g = ((c >> 8) & 0xFF) * 31 ~/ 255;
      final b = (c & 0xFF) * 31 ~/ 255;
      final v = r | (g << 5) | (b << 10);
      out[i * 2] = v & 0xFF;
      out[i * 2 + 1] = (v >> 8) & 0xFF;
    }
    return out;
  }

  /// 等比缩放进 96×80，返回 RGB 与透明掩码。
  static _Face _fitToFace(
    Uint8List rgba,
    int width,
    int height,
    PortraitFit fit,
    int alphaThreshold,
  ) {
    const fw = PortraitSlots.faceWidth;
    const fh = PortraitSlots.faceHeight;
    final rgb = Uint8List(fw * fh * 3);
    final opaque = Uint8List(fw * fh);

    final scaleX = fw / width;
    final scaleY = fh / height;
    final scale = fit == PortraitFit.cover
        ? (scaleX > scaleY ? scaleX : scaleY)
        : (scaleX < scaleY ? scaleX : scaleY);

    final drawW = (width * scale).round();
    final drawH = (height * scale).round();
    final offsetX = (fw - drawW) ~/ 2;
    final offsetY = (fh - drawH) ~/ 2;

    // **面积平均降采样**，不是点采样。
    //
    // 点采样（floor 取源坐标）在缩小十几倍时只读到 1/12 的像素，
    // 剩下的细节全被丢掉 —— 实测 1127×1164 的图缩到 96×80 后，
    // 背景渐变被抽成随机噪点，往 15 色里一压就是一片花斑。
    // 面积平均把每个目标像素覆盖的所有源像素按 alpha 加权混合，
    // 渐变平滑地退化成中间色，量化后就干净了。
    for (var dy = 0; dy < fh; dy++) {
      for (var dx = 0; dx < fw; dx++) {
        // 目标像素在源图上的浮点包围盒
        final sx0 = (dx - offsetX) / scale;
        final sx1 = (dx + 1 - offsetX) / scale;
        final sy0 = (dy - offsetY) / scale;
        final sy1 = (dy + 1 - offsetY) / scale;
        final ix0 = sx0.floor().clamp(0, width);
        final ix1 = sx1.ceil().clamp(0, width);
        final iy0 = sy0.floor().clamp(0, height);
        final iy1 = sy1.ceil().clamp(0, height);
        if (ix1 <= ix0 || iy1 <= iy0) continue;

        // 全部用 double 累加。大图缩到 96×80 时单个覆盖面积 `w` 很小，
        // 用 `(a * w).round()` 累计会把每个小面积都舍成 0，
        // 导致不透明的图被大量误判成透明（实测 600×800 → 37.5% 透明，
        // 进游戏就是「黑底 + 碎片」）。
        var sumA = 0.0, sumR = 0.0, sumG = 0.0, sumB = 0.0, weight = 0.0;
        for (var sy = iy0; sy < iy1; sy++) {
          // 与目标像素的实际重叠高度（边界像素只算一部分）
          final oy = _overlap(sy.toDouble(), sy + 1.0, sy0, sy1);
          if (oy <= 0) continue;
          for (var sx = ix0; sx < ix1; sx++) {
            final ox = _overlap(sx.toDouble(), sx + 1.0, sx0, sx1);
            if (ox <= 0) continue;
            final w = ox * oy;
            final si = (sy * width + sx) * 4;
            final a = rgba[si + 3];
            // 按面积加权累加 alpha；颜色额外乘 alpha：
            // 透明像素的 RGB 无意义（常见是 0 或白），
            // 等权平均会把边缘拉黑/拉白。
            sumA += a * w;
            sumR += rgba[si] * a * w;
            sumG += rgba[si + 1] * a * w;
            sumB += rgba[si + 2] * a * w;
            weight += w;
          }
        }
        if (weight <= 0 || sumA <= 0) continue;

        if (sumA / weight <= alphaThreshold) continue;
        final di = dy * fw + dx;
        // sumR 已经带了 alpha 权重，除以 alpha 加权和才是真正的平均颜色
        rgb[di * 3] = (sumR / sumA).round().clamp(0, 255);
        rgb[di * 3 + 1] = (sumG / sumA).round().clamp(0, 255);
        rgb[di * 3 + 2] = (sumB / sumA).round().clamp(0, 255);
        opaque[di] = 1;
      }
    }
    return _Face(rgb, opaque, fw, fh);
  }

  /// 区间 [a0,a1) 与 [b0,b1) 的重叠长度。
  static double _overlap(double a0, double a1, double b0, double b1) {
    final lo = a0 > b0 ? a0 : b0;
    final hi = a1 < b1 ? a1 : b1;
    return hi > lo ? hi - lo : 0.0;
  }

  /// 取 RGBA 图上 (x,y) 的颜色（RGB 打包）。
  static int _pixel(Uint8List rgba, int width, int x, int y) {
    final o = (y * width + x) * 4;
    return (rgba[o] << 16) | (rgba[o + 1] << 8) | rgba[o + 2];
  }

  /// 像素索引网格 → 4bpp（tile 顺序，与 [_unpackGrid] 同一套布局）。
  /// 生成 FE7/FE8 的「固定嘴型」图：32×96，六帧内容完全相同。
  ///
  /// 内容是从新脸按 `mouthX/mouthY`（8 像素格）抠下来的 32×16 嘴部区域。
  /// 游戏会照常按帧号播放，但每帧长得一样，所以看上去嘴不动——
  /// 这正是原版处理「龙 / 魔物 / 通用杂兵」的做法（实测封印之剑 ID 189 伊冬
  /// 与 ID 193..195 的五帧逐像素相同）。
  static Uint8List _fixedMouthStrip(
    Uint8List face, {
    int? mouthX,
    int? mouthY,
  }) {
    final grid = Uint8List(PortraitSlots.mouthWidth * PortraitSlots.mouthHeight);
    _copyMouthCell(face, grid, 0, mouthX: mouthX, mouthY: mouthY);
    for (var f = 1; f < 6; f++) {
      grid.setRange(f * 32 * 16, (f + 1) * 32 * 16, grid, 0);
    }
    return _pack4bpp(grid, PortraitSlots.mouthWidth, PortraitSlots.mouthHeight);
  }

  /// 把 96×80 新脸里的一块 32×16 嘴部区域抽出来，写进嘴型图的第 [frame] 格。
  ///
  /// 坐标取自条目的 `mouthX/mouthY`（8 像素格）——原版绝大多数是 (2,5)/(2,6)。
  /// 与 [_spreadMouthFrames] 用的是同一套换算，保证「固定帧」跟游戏实际
  /// 叠到脸上那块是同一处像素。
  static void _copyMouthCell(
    Uint8List face,
    Uint8List grid, int frame, {
    int? mouthX,
    int? mouthY,
  }) {
    const fw = PortraitSlots.faceWidth;
    const fh = PortraitSlots.faceHeight;
    final mx = (mouthX ?? 2) * 8;
    final my = (mouthY ?? 6) * 8;
    final dstBase = frame * 32 * 16;
    for (var y = 0; y < 16; y++) {
      final fy = my + y;
      for (var x = 0; x < 32; x++) {
        final fx = mx + x;
        // 越界就留索引 0（与嘴型扇区周边一致，不是透明发黑）
        if (fx < 0 || fx >= fw || fy < 0 || fy >= fh) continue;
        grid[dstBase + y * 32 + x] = face[fy * fw + fx];
      }
    }
  }

  static Uint8List _pack4bpp(Uint8List grid, int w, int h) {
    final out = Uint8List(w * h ~/ 2);
    final tilesPerRow = w ~/ 8;
    for (var y = 0; y < h; y++) {
      final band = y ~/ 8;
      final rit = y % 8;
      for (var tx = 0; tx < tilesPerRow; tx++) {
        final base = band * (tilesPerRow * 32) + tx * 32 + rit * 4;
        if (base + 4 > out.length) continue;
        for (var k = 0; k < 4; k++) {
          final lo = grid[y * w + tx * 8 + k * 2];
          final hi = grid[y * w + tx * 8 + k * 2 + 1];
          out[base + k] = (lo & 0x0F) | ((hi & 0x0F) << 4);
        }
      }
    }
    return out;
  }

  /// 中位切分量化：把不透明像素拼成 15 色以内，索引 0 留给背景。
  ///
  /// [strategy] 决定量化前对像素做怎样的预处理、以及像素到 15 色里怎么落格：
  /// [PortraitQuantStrategy.dither] 走误差扩散，其余走最近色。
  static _Quantized _quantize(_Face face, int alphaThreshold,
      PortraitQuantStrategy strategy) {
    final total = face.width * face.height;
    var opaqueCount = 0;
    for (var i = 0; i < total; i++) {
      if (face.opaque[i] != 0) opaqueCount++;
    }
    final transparentRatio = total == 0 ? 0.0 : 1 - opaqueCount / total;

    // 策略预处理：classic/bright 改像素，natural/dither 原样。
    // 预处理后的像素既供采样（调色板跟它匹配）也供落格。
    final rgb = _preTransform(face.rgb, face.opaque, strategy);

    final samples = <int>[];
    for (var i = 0; i < total; i++) {
      if (face.opaque[i] == 0) continue;
      samples.add((rgb[i * 3] << 16) | (rgb[i * 3 + 1] << 8) | rgb[i * 3 + 2]);
    }

    // 全透明图：只有一个背景色，整张图都是索引 0
    if (samples.isEmpty) {
      final indices = Uint8List(total);
      return _Quantized(indices, [0x000000], 0, transparentRatio);
    }

    final colors = _medianCut(samples, 15);
    // 索引 0 固定为背景色（不被任何像素使用），实际颜色从 1 开始
    final palette = <int>[0x000000, ...colors];

    final indices = Uint8List(total);
    var hardMapped = 0;
    if (strategy == PortraitQuantStrategy.dither) {
      // 误差扩散：局部平均明度得以保留，色块过渡柔和，不报告 hardMapped。
      _floydSteinberg(rgb, face.opaque, face.width, face.height, palette, indices);
    } else {
      for (var i = 0; i < total; i++) {
        if (face.opaque[i] == 0) continue;
        final c = (rgb[i * 3] << 16) | (rgb[i * 3 + 1] << 8) | rgb[i * 3 + 2];
        var best = 1;
        var bestDist = 1 << 30;
        for (var k = 1; k < palette.length; k++) {
          final d = _dist2(c, palette[k]);
          if (d < bestDist) {
            bestDist = d;
            best = k;
          }
        }
        indices[i] = best;
        // 误差超过「每通道 64 级」才算是硬凑（约 25% 亮度偏差）。
        if (bestDist > 64 * 64 * 3) hardMapped++;
      }
    }
    return _Quantized(indices, palette, hardMapped, transparentRatio);
  }

  /// 量化前的像素预处理（[strategy] 决定）。
  ///
  /// [natural]/[dither] 原样返回；[classic] 拉高对比度；[bright] 提亮暗部 + 提饱和。
  /// 只对不透明像素改写，透明区保持 0（反正后面按 opaque 掩码跳过）。
  static Uint8List _preTransform(Uint8List rgb, Uint8List opaque,
      PortraitQuantStrategy strategy) {
    final out = Uint8List.fromList(rgb);
    switch (strategy) {
      case PortraitQuantStrategy.natural:
      case PortraitQuantStrategy.dither:
        return out;
      case PortraitQuantStrategy.classic:
        // 以 128 为中心拉对比度：暗更暗、亮更亮，得到硬色块观感。
        for (var i = 0; i < out.length; i += 3) {
          if (opaque[i ~/ 3] == 0) continue;
          for (var ch = 0; ch < 3; ch++) {
            final o = i + ch;
            final v = (out[o] - 128) * 1.45 + 128;
            out[o] = (v < 0 ? 0 : (v > 255 ? 255 : v.round()));
          }
        }
        break;
      case PortraitQuantStrategy.bright:
        for (var i = 0; i < out.length; i += 3) {
          if (opaque[i ~/ 3] == 0) continue;
          var r = out[i].toDouble(), g = out[i + 1].toDouble(), b = out[i + 2].toDouble();
          // 提亮暗部：向 255 拉，暗部提得多
          r = r + (255 - r) * 0.16;
          g = g + (255 - g) * 0.16;
          b = b + (255 - b) * 0.16;
          // 提饱和：以灰度为锚，把各通道离灰度的距离拉开
          final m = (r + g + b) / 3;
          r = m + (r - m) * 1.25;
          g = m + (g - m) * 1.25;
          b = m + (b - m) * 1.25;
          out[i] = (r < 0 ? 0 : (r > 255 ? 255 : r.round()));
          out[i + 1] = (g < 0 ? 0 : (g > 255 ? 255 : g.round()));
          out[i + 2] = (b < 0 ? 0 : (b > 255 ? 255 : b.round()));
        }
        break;
    }
    return out;
  }

  /// Floyd–Steinberg 误差扩散量化：把 [rgb]（不透明区）落到 [palette]（索引 1..15），
  /// 把落格误差扩散到右下邻居，保留局部平均明度、让渐变柔和。
  ///
  /// 结果写入 [out]（每像素一个调色板索引；透明像素写 0）。[palette] 长度 16，
  /// 索引 0 是背景，只在 1..15 里选。
  static void _floydSteinberg(
    Uint8List rgb,
    Uint8List opaque,
    int width,
    int height,
    List<int> palette,
    Uint8List out,
  ) {
    final n = width * height;
    // 用 float 累积误差，避免 int 累积误差精度丢失
    final fr = Float64List(n), fg = Float64List(n), fb = Float64List(n);
    for (var i = 0; i < n; i++) {
      final o = i * 3;
      fr[i] = rgb[o].toDouble();
      fg[i] = rgb[o + 1].toDouble();
      fb[i] = rgb[o + 2].toDouble();
    }
    int nearest(int r, int g, int b) {
      var best = 1;
      var bd = 1 << 30;
      for (var k = 1; k < palette.length; k++) {
        final pr = (palette[k] >> 16) & 0xFF, pg = (palette[k] >> 8) & 0xFF, pb = palette[k] & 0xFF;
        final dr = r - pr, dg = g - pg, db = b - pb;
        final d = dr * dr + dg * dg + db * db;
        if (d < bd) {
          bd = d;
          best = k;
        }
      }
      return best;
    }

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        if (opaque[i] == 0) continue;
        final cr = (fr[i] < 0 ? 0 : (fr[i] > 255 ? 255 : fr[i].round()));
        final cg = (fg[i] < 0 ? 0 : (fg[i] > 255 ? 255 : fg[i].round()));
        final cb = (fb[i] < 0 ? 0 : (fb[i] > 255 ? 255 : fb[i].round()));
        final idx = nearest(cr, cg, cb);
        out[i] = idx;
        // 落格误差（用量化后的整数颜色算）
        final q = palette[idx];
        final er = cr - ((q >> 16) & 0xFF);
        final eg = cg - ((q >> 8) & 0xFF);
        final eb = cb - (q & 0xFF);
        // 扩散到右下 7 邻（标准 7/16、5/16、3/16、1/16 权重）
        void add(int j, double er, double eg, double eb) {
          if (j < 0 || j >= n) return;
          if (opaque[j] == 0) return; // 不把误差渗进透明区
          fr[j] += er;
          fg[j] += eg;
          fb[j] += eb;
        }
        add(i + 1, er * 7 / 16, eg * 7 / 16, eb * 7 / 16);
        add(i + width - 1, er * 3 / 16, eg * 3 / 16, eb * 3 / 16);
        add(i + width, er * 5 / 16, eg * 5 / 16, eb * 5 / 16);
        add(i + width + 1, er * 1 / 16, eg * 1 / 16, eb * 1 / 16);
      }
    }
  }

  /// 中位切分（median cut）：递归把颜色空间按最长边切到 [maxColors] 个盒子。
  ///
  /// 每个色点带权重（出现次数）——不按权重切的话，渐变图里占一半像素的
  /// 主色调会被当成与零星颜色等价，割出来的调色板对主体严重失真。
  static List<int> _medianCut(List<int> samples, int maxColors) {
    if (samples.isEmpty) return const [];
    final hist = <int, int>{};
    for (final c in samples) {
      hist[c] = (hist[c] ?? 0) + 1;
    }
    if (hist.length <= maxColors) {
      // 颜色本来就不多，直接按出现次数从多到少取，保证主体色不被挤掉
      final keys = hist.keys.toList()
        ..sort((a, b) => hist[b]!.compareTo(hist[a]!));
      return keys.take(maxColors).toList();
    }

    var boxes = <_ColorBox>[_ColorBox(hist.entries.toList())];
    while (boxes.length < maxColors) {
      // 选「最长边 × 像素数」最大的盒子来切：既照顾色域跨度，也照顾占比
      var target = -1;
      var bestScore = -1;
      for (var i = 0; i < boxes.length; i++) {
        final b = boxes[i];
        if (b.entries.length < 2) continue;
        final score = b.span * b.weight;
        if (score > bestScore) {
          bestScore = score;
          target = i;
        }
      }
      if (target < 0) break;
      final box = boxes[target];
      final (lo, hi) = box.cut();
      boxes = [
        ...boxes.sublist(0, target),
        lo,
        hi,
        ...boxes.sublist(target + 1),
      ];
    }
    return [for (final b in boxes) b.average()];
  }

  static int _dist2(int a, int b) {
    final dr = ((a >> 16) & 0xFF) - ((b >> 16) & 0xFF);
    final dg = ((a >> 8) & 0xFF) - ((b >> 8) & 0xFF);
    final db = (a & 0xFF) - (b & 0xFF);
    return dr * dr + dg * dg + db * db;
  }

  /// 把 96×80 的索引按六块布局铺回 256×H 的 sheet。
  ///
  /// 4bpp 打包：块内按行、块间才换行，低半字节在前（与 `decode4bpp` 互逆）。
  static void _spreadFaceToSheet(
      Uint8List face, Uint8List sheet, int sheetHeight) {
    const sw = PortraitSlots.sheetWidth;
    // 先解成 sheet 像素网格，再统一打包，避免块间互相覆盖
    final grid = Uint8List(sw * sheetHeight);
    for (final b in PortraitSlots.blits) {
      final dx = b[0], dy = b[1], w = b[2], h = b[3], sx = b[4], sy = b[5];
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final gy = sy + y;
          if (gy >= sheetHeight) continue;
          final fi = (dy + y) * PortraitSlots.faceWidth + (dx + x);
          grid[gy * sw + (sx + x)] = face[fi];
        }
      }
    }
    _packGrid(grid, sheet, sheetHeight);
  }

  /// 把新脸的嘴部区域复制到 FE6 sheet 的嘴型坑位（4 帧 + 帧 5 的两半）。
  ///
  /// 原版把「嘴型帧」画在同一张 sheet 的四个 32×16 格子里：
  /// `(192,0) (224,0) (192,16) (224,16)`，帧 5 另占 `(0,32)` 与 `(32,32)`
  /// （各自只有下半 8 行）。游戏按条目的 `mouthX/mouthY` 把其中一帧叠到脸上，
  /// 所以**换脸时不重画这四格，游戏就会把旧角色的嘴贴到新脸上**。
  ///
  /// 坑位坐标来自 FEBuilderGBA `DrawPortraitUnitFE6` 的 `showFrame` 分支
  /// （GPL-3.0，7743 著）与 `ImagePortraitImporterForm.GenMouth` 的写回位置，
  /// 两边一致、已在真实 ROM 上对过字节。
  static void _spreadMouthFrames(
    Uint8List face,
    Uint8List sheet, {
    int? mouthX,
    int? mouthY,
  }) {
    const sw = PortraitSlots.sheetWidth;
    // **必须按 40 行建网格，不能按 FE6 的 34 行**：帧 5 的两半在 (0,32) 与
    // (32,32)，各占 8 行（y=32..39）。4bpp 的排布是「32 个 tile 一行、
    // 每行 1024 字节」的 tile 带，band4 只需要 x<64 那 8 个 tile（256 字节），
    // 所以 34 行的数据**装得下**这 16 行——只是绝大多数网格实现按
    // 「34 行 × 256 宽」截断，把 y>=34 的行整块丢掉（实测帧 5 只有 2 行有效，
    // 与帧 1 不同，游戏里播到第 5 帧会跳一下）。
    const sheetH = PortraitSlots.sheetHeight; // 40：虚拟高度，打包时按 34 行写出
    final grid = _unpackGrid(sheet, sheetH);

    // 嘴部区域在 96×80 里的位置由条目的 `mouthX/mouthY`（8 像素格）决定，
    // 原版绝大多数是 (2,6)/(2,5)。没有传坐标时用最常见的 (2,6)。
    final mouthFaceX = (mouthX ?? 2) * 8;
    final mouthFaceY = (mouthY ?? 6) * 8;
    const mouthW = 32;
    const mouthH = 16;

    void copyRect(int sx, int sy) {
      for (var y = 0; y < mouthH; y++) {
        final gy = sy + y;
        if (gy >= sheetH) continue;
        final fy = mouthFaceY + y;
        if (fy >= PortraitSlots.faceHeight) continue;
        for (var x = 0; x < mouthW; x++) {
          final fx = mouthFaceX + x;
          if (fx >= PortraitSlots.faceWidth) continue;
          grid[gy * sw + (sx + x)] = face[fy * PortraitSlots.faceWidth + fx];
        }
      }
    }

    // 帧 1/2/3/4：四个普通 32×16 格子
    copyRect(192, 0);
    copyRect(224, 0);
    copyRect(192, 16);
    copyRect(224, 16);
    // 帧 5：只有 8 行高，分两半存在 (0,32) 与 (32,32)。
    // 不填这两格的话，游玩嘴型动画播到帧 5 时就会露出旧角色的像素。
    for (var half = 0; half < 2; half++) {
      for (var y = 0; y < mouthH ~/ 2; y++) {
        final fy = mouthFaceY + half * (mouthH ~/ 2) + y;
        if (fy >= PortraitSlots.faceHeight) continue;
        final gy = 32 + y;
        if (gy >= sheetH) continue;
        for (var x = 0; x < mouthW; x++) {
          final fx = mouthFaceX + x;
          if (fx >= PortraitSlots.faceWidth) continue;
          grid[gy * sw + half * mouthW + x] =
              face[fy * PortraitSlots.faceWidth + fx];
        }
      }
    }
    _packGrid(grid, sheet, sheetH);
  }

  /// 4bpp sheet → 像素索引网格（1 字节/像素）。
  static Uint8List _unpackGrid(Uint8List sheet, int sheetHeight) {
    const sw = PortraitSlots.sheetWidth;
    const tilesPerRow = sw ~/ 8;
    const tileRowBytes = tilesPerRow * 32;
    final grid = Uint8List(sw * sheetHeight);
    for (var y = 0; y < sheetHeight; y++) {
      final band = y ~/ 8, rit = y % 8;
      for (var tx = 0; tx < tilesPerRow; tx++) {
        final base = band * tileRowBytes + tx * 32 + rit * 4;
        if (base + 4 > sheet.length) continue;
        for (var k = 0; k < 4; k++) {
          final x = tx * 8 + k * 2;
          grid[y * sw + x] = sheet[base + k] & 0x0F;
          grid[y * sw + x + 1] = (sheet[base + k] >> 4) & 0x0F;
        }
      }
    }
    return grid;
  }

  /// 像素索引网格 → 4bpp sheet（与 [_unpackGrid] 互逆）。
  static void _packGrid(Uint8List grid, Uint8List sheet, int sheetHeight) {
    const sw = PortraitSlots.sheetWidth;
    const tilesPerRow = sw ~/ 8;
    const tileRowBytes = tilesPerRow * 32;
    for (var y = 0; y < sheetHeight; y++) {
      final band = y ~/ 8;
      final rowInTile = y % 8;
      for (var tx = 0; tx < tilesPerRow; tx++) {
        final base = band * tileRowBytes + tx * 32 + rowInTile * 4;
        // FE6 只有 34 行：最后一个 band 不完整，越界部分直接不写
        if (base + 4 > sheet.length) continue;
        for (var k = 0; k < 4; k++) {
          final lo = grid[y * sw + tx * 8 + k * 2];
          final hi = grid[y * sw + tx * 8 + k * 2 + 1];
          sheet[base + k] = (lo & 0x0F) | ((hi & 0x0F) << 4);
        }
      }
    }
  }
}

class _Face {
  final Uint8List rgb;
  final Uint8List opaque;
  final int width;
  final int height;
  _Face(this.rgb, this.opaque, this.width, this.height);
}

class _Quantized {
  final Uint8List indices;
  final List<int> colors;
  final int hardMapped;
  final double transparentRatio;
  _Quantized(this.indices, this.colors, this.hardMapped, this.transparentRatio);
}

/// 中位切分的一个颜色盒子：带权重的颜色列表。
class _ColorBox {
  final List<MapEntry<int, int>> entries;

  _ColorBox(this.entries);

  /// 盒内像素总数。
  int get weight {
    var n = 0;
    for (final e in entries) {
      n += e.value;
    }
    return n;
  }

  /// 最长一条通道的跨度。
  int get span {
    var minR = 255, maxR = 0, minG = 255, maxG = 0, minB = 255, maxB = 0;
    for (final e in entries) {
      final c = e.key;
      final r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF;
      if (r < minR) minR = r;
      if (r > maxR) maxR = r;
      if (g < minG) minG = g;
      if (g > maxG) maxG = g;
      if (b < minB) minB = b;
      if (b > maxB) maxB = b;
    }
    final dr = maxR - minR, dg = maxG - minG, db = maxB - minB;
    return dr > dg ? (dr > db ? dr : db) : (dg > db ? dg : db);
  }

  /// 按跨度最大的通道排序后从中间切开，按累计权重选取切点。
  (_ColorBox, _ColorBox) cut() {
    var minR = 255, maxR = 0, minG = 255, maxG = 0, minB = 255, maxB = 0;
    for (final e in entries) {
      final c = e.key;
      final r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF;
      if (r < minR) minR = r;
      if (r > maxR) maxR = r;
      if (g < minG) minG = g;
      if (g > maxG) maxG = g;
      if (b < minB) minB = b;
      if (b > maxB) maxB = b;
    }
    final dr = maxR - minR, dg = maxG - minG, db = maxB - minB;
    final channel = (dg >= dr && dg >= db) ? 1 : (dr >= db ? 0 : 2);
    final sorted = [...entries]..sort((a, b) =>
        _ch(a.key, channel).compareTo(_ch(b.key, channel)));

    // 按累计像素权重选切点（不是按下标对半），主体色才不会被切碎
    final total = weight;
    var acc = 0;
    var cutAt = 1;
    for (var i = 0; i < sorted.length - 1; i++) {
      acc += sorted[i].value;
      if (acc * 2 >= total) {
        cutAt = i + 1;
        break;
      }
      cutAt = i + 2;
    }
    cutAt = cutAt.clamp(1, sorted.length - 1);
    return (_ColorBox(sorted.sublist(0, cutAt)),
        _ColorBox(sorted.sublist(cutAt)));
  }

  /// 盒内按像素权重加权平均色。
  int average() {
    var r = 0, g = 0, b = 0, n = 0;
    for (final e in entries) {
      final c = e.key;
      r += ((c >> 16) & 0xFF) * e.value;
      g += ((c >> 8) & 0xFF) * e.value;
      b += (c & 0xFF) * e.value;
      n += e.value;
    }
    if (n == 0) return 0;
    return ((r ~/ n) << 16) | ((g ~/ n) << 8) | (b ~/ n);
  }

  static int _ch(int c, int ch) => switch (ch) {
        0 => (c >> 16) & 0xFF,
        1 => (c >> 8) & 0xFF,
        _ => c & 0xFF,
      };
}
