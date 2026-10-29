import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'battle_anim.dart' show encodePng;
import 'fe_rom.dart';
import 'rom_info.dart';
import 'tile_image.dart';

/// 道具小图标（道具列表/详情里名称左边那个 16×16 图）。
///
/// ## 数据来源
///
/// GBA 三作的图标是 **16×16、4bpp**（每图标 64 字节图块数据），
/// 整张图标图集挂在指针槽上；调色板是另一处指针槽（16 色）。
/// 地址取自 FEBuilderGBA 的 `ROMFE6JP/ROMFE7JP/ROMFE7U/ROMFE8JP/ROMFE8U.cs`
/// （GPL-3.0，7743 著）：
///
/// | 版本 | 图标槽 | 调色板槽 |
/// |---|---|---|
/// | FE6 | `0x4CEC` | `0x4AC4` |
/// | FE7J | `0x4CFC` | `0x4C1C` |
/// | FE7U | `0x4E20` | `0x4D40` |
/// | FE8J | `0x36D4` | `0x351C` |
/// | FE8U | `0x36B4` | `0x35D0` |
///
/// ## 图标之间的间距是 128 字节，不是 64（实测）
///
/// 已验证：FE7U 的图集里图标 0/1/2/3 分别是铁剑/钢剑/铁枪/钢枪，
/// 每图标只占前 64 字节（2×2 个 8×8 tile），**后 64 字节是空**。
/// 按 64 字节紧排读会得到「斜着错开半格」的残图。
class ItemIcons {
  final FeRom rom;

  /// 缓存的调色板（同一 ROM 只需解一次）。
  GbaPalette? _palette;

  ItemIcons(this.rom);

  /// 图标数据在 ROM 里的间隔（实测 128；见类注释）。
  static const int stride = 128;

  bool get available => iconBase >= 0 && paletteOffset >= 0;

  int get iconBase {
    final slot = _iconSlot;
    if (slot <= 0) return -1;
    return rom.pointerAt(slot);
  }

  int get paletteOffset {
    final slot = _paletteSlot;
    if (slot <= 0) return -1;
    return rom.pointerAt(slot);
  }

  int get _iconSlot => switch (rom.table.id) {
        'FE6' => 0x4CEC,
        'FE7J' => 0x4CFC,
        'FE7U' => 0x4E20,
        'FE8J' => 0x36D4,
        'FE8U' => 0x36B4,
        _ => 0,
      };

  int get _paletteSlot => switch (rom.table.id) {
        'FE6' => 0x4AC4,
        'FE7J' => 0x4C1C,
        'FE7U' => 0x4D40,
        'FE8J' => 0x351C,
        'FE8U' => 0x35D0,
        _ => 0,
      };

  GbaPalette get palette {
    final cached = _palette;
    if (cached != null) return cached;
    final off = paletteOffset;
    return _palette = off < 0
        ? GbaPalette()
        : GbaPalette.fromRom(rom.data, off);
  }

  /// 图标总数（按图集长度估算）：改版可能比原版多，所以不用硬编码上限。
  int get iconCount {
    final base = iconBase;
    if (base < 0) return 0;
    final room = rom.length - base;
    return room <= 0 ? 0 : room ~/ stride;
  }

  /// 解码第 [iconId] 个图标；不可用时返回 null。
  TileImage? decode(int iconId) {
    final base = iconBase;
    if (base < 0 || iconId < 0) return null;
    final off = base + iconId * stride;
    if (off + 64 > rom.length) return null;
    final img = decode4bpp(rom.data, off, 16, 16, palette);
    // 全透明的图标（改版里常有空槽）当作不可用，界面直接不画
    var opaque = 0;
    for (var i = 3; i < img.pixels.length; i += 4) {
      if (img.pixels[i] != 0) opaque++;
    }
    return opaque == 0 ? null : img;
  }

  /// 该道具的图标（按道具表的 `+29 iconId` 字段）。
  TileImage? forItem(int itemIndex) {
    final base = rom.itemBase;
    if (base < 0) return null;
    final at = base + itemIndex * rom.table.itemDataSize;
    if (at + ItemOffsets.iconId >= rom.length) return null;
    return decode(FeRom.u8(rom.data, at + ItemOffsets.iconId));
  }
}

/// 道具图标显示组件（带上缓存，避免滚动时反复解码）。
///
/// 缓存键必须含 **ROM 指纹 + 图标 ID**：跨 ROM 用同一个 key 会显示上一个
/// ROM 的图标（本项目在肖像缓存上踩过这个坑）。
class ItemIconView extends StatelessWidget {
  final FeRom rom;
  final int iconId;
  final double size;

  /// 取不到图标时显示的内容（通常是 ID 数字）。
  final Widget? fallback;

  const ItemIconView({
    super.key,
    required this.rom,
    required this.iconId,
    this.size = 32,
    this.fallback,
  });

  static final Map<int, Uint8List> _pngCache = {};
  static final Map<int, ItemIcons> _readers = {};

  /// 缓存 key：ROM 指纹低 20 位 + 图标 ID 低 12 位。
  int get cacheKey => ((rom.fingerprint & 0xFFFFF) << 12) | (iconId & 0xFFF);

  ItemIcons get _icons =>
      _readers.putIfAbsent(rom.fingerprint, () => ItemIcons(rom));

  /// 清空缓存（打开新 ROM 时可调用；不清也不会串，因为 key 含指纹）。
  static void clearCache() => _pngCache.clear();

  /// 图标 PNG（同步编码，走既有的 [encodePng]，不依赖渲染管线）。
  ///
  /// 用 `Image.memory` 而不是 `decodeImageFromPixels`：后者是异步回调，
  /// 在 widget 测试里不会触发，图标就永远显示不出来。
  Uint8List? _png() {
    final hit = _pngCache[cacheKey];
    if (hit != null) return hit;
    final tile = _icons.decode(iconId);
    if (tile == null) return null;
    final bytes = encodePng(tile);
    if (_pngCache.length >= 256) _pngCache.remove(_pngCache.keys.first);
    _pngCache[cacheKey] = bytes;
    return bytes;
  }

  Widget _placeholder() {
    if (fallback == null) return SizedBox(width: size, height: size);
    return SizedBox(
      width: size,
      height: size,
      child: Center(child: fallback),
    );
  }

  @override
  Widget build(BuildContext context) {
    final png = _png();
    if (png == null) return _placeholder();
    return Image.memory(
      png,
      width: size,
      height: size,
      filterQuality: FilterQuality.none,
      fit: BoxFit.contain,
    );
  }
}
