import 'dart:typed_data';

import 'portrait_import.dart';

/// 格式转换层：**永远在 App 侧做，绝不在 AI 侧做**。
///
/// 为什么单独一层：PNG→4bpp 是像素级操作，AI 做不可靠；
/// 图片→地图方案是量化 + 匹配，AI 更不该碰。
/// 这一层是纯 Dart 函数，可以单测，可以脱离 UI 与原生跑。
///
/// 约定：输入/输出都是「AssetStore 的 handle 或 ROM 槽位」，
/// 中间产物（RGBA / 索引图 / 调色板）不外传。
class Converters {
  Converters._();

  /// PNG bytes → 肖像导入数据（含 96×80 正脸索引、调色板、地图小头像）。
  ///
  /// 只做解码与量化，**不写 ROM**；写 ROM 由 `PortraitPorter.importFace` 负责。
  /// 这样可以先 dry_run 看量化质量（`usedColors` / `transparentRatio`），
  /// 再决定是否真的写进去。
  static PortraitImport? portraitFromPng(
    Uint8List png, {
    required bool fe6,
    bool mapFace = true,
    PortraitFit fit = PortraitFit.contain,
  }) {
    final rgba = PngDecoder.decodeRgba(png);
    if (rgba == null) return null;
    final width = pngWidth(png);
    if (width <= 0) return null;
    final pixels = rgba.length ~/ 4;
    if (pixels % width != 0) return null;
    final height = pixels ~/ width;
    final data = PortraitImporter.convertRgba(
      rgba,
      width,
      height,
      fe6: fe6,
      fit: fit,
      mapFace: mapFace,
    );
    return PortraitImport(
      data: data,
      sourceWidth: width,
      sourceHeight: height,
      fit: fit,
    );
  }

  /// 从 PNG 的 IHDR 读宽度（`PngDecoder` 已校验签名与结构）。
  static int pngWidth(Uint8List png) {
    if (png.length < 24) return 0;
    return (png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19];
  }

  /// 按文件名猜类型（素材入库时用）。
  static String typeOfName(String name) {
    final l = name.toLowerCase();
    if (l.endsWith('.png') || l.endsWith('.jpg') || l.endsWith('.jpeg')) {
      return 'image';
    }
    if (l.endsWith('.json')) return 'map_plan';
    if (l.endsWith('.gba') || l.endsWith('.agb')) return 'rom';
    return 'binary';
  }

  /// 按文件名猜 MIME。
  static String mimeOfName(String name) {
    final l = name.toLowerCase();
    if (l.endsWith('.png')) return 'image/png';
    if (l.endsWith('.jpg') || l.endsWith('.jpeg')) return 'image/jpeg';
    if (l.endsWith('.json')) return 'application/json';
    if (l.endsWith('.txt')) return 'text/plain';
    return 'application/octet-stream';
  }
}

/// 一次「图片 → 肖像数据」的产物。故意不包含原始 PNG 字节。
class PortraitImport {
  final PortraitImportResult data;
  final int sourceWidth;
  final int sourceHeight;
  final PortraitFit fit;

  const PortraitImport({
    required this.data,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.fit,
  });

  /// 给 AI 看的摘要：量化质量，不含像素。
  Map<String, Object?> summary() => {
        'source_size': '$sourceWidth×$sourceHeight',
        'used_colors': data.usedColors,
        'hard_mapped_pixels': data.hardMapped,
        'transparent_ratio':
            double.parse(data.transparentRatio.toStringAsFixed(4)),
        'fit': fit.name,
        'has_map_face': data.mapFaceIndices != null,
      };
}
