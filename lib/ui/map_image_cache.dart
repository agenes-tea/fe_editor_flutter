import 'dart:async';
import 'dart:ui' as ui;

import '../core/tile_image.dart';

/// 地图位图的 `ui.Image` 缓存（key 含 ROM 指纹 + 章节）。
///
/// 两份 ROM 的图可以同时驻留，靠 ROM 指纹区分。
///
/// **注意**：key 只含 ROM 指纹与章节，编辑 ROM 后指纹不变。地图砖块、
/// chipset 图形、地图宽高被写回后，旧位图立刻失效——调用方在写回成功
/// 后必须 `clear()`（见 `MapTileEditorPage` / `MapChipsetEditorPage` 的保存路径），
/// 否则章节页会继续显示改前的图。不要在页面 `dispose()` 里无条件 clear
/// （那会连另一份 ROM 的缓存一起清掉）。
class MapImageCache {
  MapImageCache._();
  static final MapImageCache instance = MapImageCache._();

  static const int _limit = 24;
  final _images = <int, ui.Image>{};

  int keyFor(int romTag, int chapter, int salt) =>
      (romTag & 0xFFFF) * 0x100000 + chapter * 0x100 + (salt & 0xFF);

  Future<ui.Image> load(int key, TileImage tile) {
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

  /// ROM 内容被编辑（砖块/chipset/尺寸写回）后丢弃全部缓存。
  ///
  /// 不逐个 `dispose()`：在飞的 FutureBuilder 可能还引用着旧 ui.Image，
  /// 主动 dispose 会让下次绘制用到已释放的对象；最多 24 张的图留给 GC。
  void clear() {
    _images.clear();
  }
}
