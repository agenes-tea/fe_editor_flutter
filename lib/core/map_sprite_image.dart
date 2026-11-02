import 'dart:async';
import 'dart:ui' as ui;

import 'fe_rom.dart';
import 'map_sprite.dart';
import 'tile_image.dart';

/// 地图小人的 `ui.Image` 缓存（给地图页叠加真实单位图标用）。
///
/// 与 [MapSpriteReader] 的分工：那边负责「解出 TileImage」，这里负责
/// 「转成 ui.Image 并缓存」。key 必须带 ROM 指纹，否则换 ROM 后同索引
/// 会命中上一个 ROM 的图（肖像缓存踩过同样的坑）。
///
/// 指纹由调用方传入，缓存不持有「当前 ROM」这种全局状态——
/// 同时打开多个 ROM 时各自的图并存，互不覆盖。
class MapSpriteImageCache {
  MapSpriteImageCache._();

  static final MapSpriteImageCache instance = MapSpriteImageCache._();

  static const int _limit = 96;
  final _images = <int, ui.Image>{};

  int keyFor(int romTag, int spriteId, int paletteGroup) =>
      (romTag & 0xFFFF) * 0x10000 + (spriteId & 0xFF) * 4 + (paletteGroup & 3);

  /// 已缓存好的图（同步返回，供 FutureBuilder 首帧直接命中）。
  ui.Image? peek(int key) => _images[key];

  Future<ui.Image>? image(TileImage? tile, int key) {
    if (tile == null) return null;
    final cached = _images[key];
    if (cached != null) return Future.value(cached);
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      tile.pixels,
      tile.width,
      tile.height,
      ui.PixelFormat.rgba8888,
      (img) {
        if (_images.length >= _limit) {
          final first = _images.keys.first;
          _images.remove(first)?.dispose();
        }
        _images[key] = img;
        completer.complete(img);
      },
    );
    return completer.future;
  }
}

/// 单位的地图小人：按「职业 → 站立表 SMSId → 帧」取图。
///
/// 阵营决定调色板组（`bmudisp.c` 的 `GetUnitSpritePalette()`：
/// 蓝=0、红=1、绿=2），与游戏内一致。
class UnitSpriteProvider {
  final FeRom rom;
  late final MapSpriteReader _reader = MapSpriteReader(rom);

  /// 缓存命名空间：取 ROM 内容指纹。
  late final int _romTag = rom.fingerprint;

  UnitSpriteProvider(this.rom);

  MapSpriteImageCache get _cache => MapSpriteImageCache.instance;

  /// 该职业是否有可渲染的地图小人。
  bool canRender(int classId) =>
      _reader.canRender(_reader.entryForClass(classId));

  /// 取某职业第 0 帧的图；取不到返回 null（由界面回退到色块）。
  Future<ui.Image>? imageFor(int classId, int paletteGroup) {
    final entry = _reader.entryForClass(classId);
    if (entry == null) return null;
    final tile = _reader.frame(entry, paletteGroup: paletteGroup);
    if (tile == null) return null;
    final sms = _reader.classSmsId(classId);
    return _cache.image(
        tile, _cache.keyFor(_romTag, sms < 0 ? entry.id : sms, paletteGroup));
  }

  /// 已经解码好的小人图（同步返回）。用于 build 里直接命中缓存，
  /// 避免每帧都走一遍 FutureBuilder（首次加载后才需要异步等）。
  ui.Image? cached(int classId, int paletteGroup) {
    final sms = _reader.classSmsId(classId);
    final entry = _reader.entryForClass(classId);
    if (entry == null) return null;
    return _cache
        .peek(_cache.keyFor(_romTag, sms < 0 ? entry.id : sms, paletteGroup));
  }

  /// 小人的单帧像素尺寸（16 / 16×32 / 32×32），取不到时按 16×16。
  (int, int) frameSize(int classId) {
    final entry = _reader.entryForClass(classId);
    return entry?.frameSize ?? (16, 16);
  }

  void dispose() => _reader.dispose();
}
