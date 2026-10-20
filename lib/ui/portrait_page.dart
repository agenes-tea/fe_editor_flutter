import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/editable_rom.dart';
import '../core/portrait.dart';
import '../core/tile_image.dart';

/// 把 [TileImage] 的 RGBA 字节转成可绘制的 `ui.Image`，并按 key 缓存。
///
/// `decodeImageFromPixels` 是异步的，所以对外统一返回 Future；
/// 缓存命中时同步完成，滑动列表不会掉帧。
class PortraitImageCache {
  PortraitImageCache._();
  static final PortraitImageCache instance = PortraitImageCache._();

  static const int cacheLimit = 96;
  final _images = <int, ui.Image>{};

  Future<ui.Image> load(int key, TileImage tile) async {
    final cached = _images[key];
    if (cached != null) return cached;
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      tile.pixels,
      tile.width,
      tile.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final img = await completer.future;
    if (_images.length >= cacheLimit) {
      final oldest = _images.keys.first;
      _images.remove(oldest)?.dispose();
    }
    _images[key] = img;
    return img;
  }

  void clear() {
    for (final img in _images.values) {
      img.dispose();
    }
    _images.clear();
  }
}

/// 统一的图像展示控件：异步解码 + 缓存 + 失败兜底。
class PortraitView extends StatelessWidget {
  final TileImage tile;
  final int cacheKey;
  final double? width;
  final double? height;

  const PortraitView({
    super.key,
    required this.tile,
    required this.cacheKey,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ui.Image>(
      future: PortraitImageCache.instance.load(cacheKey, tile),
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return SizedBox(
            width: width,
            height: height,
            child: const Center(
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        return RawImage(
          image: snap.data,
          width: width,
          height: height,
          filterQuality: FilterQuality.none,
        );
      },
    );
  }
}

class _PortraitTile {
  final int id;
  final String name;
  final bool halfBody;
  _PortraitTile(this.id, this.name, this.halfBody);
}

class PortraitListPage extends StatefulWidget {
  final EditableRom edit;
  const PortraitListPage({super.key, required this.edit});

  @override
  State<PortraitListPage> createState() => _PortraitListPageState();
}

class _PortraitListPageState extends State<PortraitListPage> {
  late final PortraitReader _reader = PortraitReader(widget.edit.rom);
  final List<_PortraitTile> _items = [];
  int _scanned = 0;
  bool _done = false;
  bool _unavailable = false;

  /// 每批构建条数：每条含 sheet 解码 + 名字反查，比纯文本重，批次取小些。
  static const int _batchSize = 20;

  @override
  void initState() {
    super.initState();
    if (!_reader.available || _reader.entryCount == 0) {
      _unavailable = true;
      _done = true;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
  }

  @override
  void dispose() {
    _reader.dispose();
    PortraitImageCache.instance.clear();
    super.dispose();
  }

  Future<void> _loadMore() async {
    if (_done) return;
    final total = _reader.entryCount;
    final end = (_scanned + _batchSize).clamp(0, total);
    final batch = <_PortraitTile>[];
    for (var id = _scanned; id < end; id++) {
      final e = _reader.entryAt(id);
      if (e == null) continue;
      if (e.unitFace == 0 && e.mapFace == 0 && e.classFace == 0) continue;
      batch.add(_PortraitTile(id, _reader.nameFor(id), _reader.isHalfBody(id)));
    }
    if (!mounted) return;
    setState(() {
      _items.addAll(batch);
      _scanned = end;
      if (end >= total) _done = true;
    });
    if (!_done) {
      await Future<void>.delayed(Duration.zero);
      if (mounted) _loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_unavailable) {
      return Scaffold(
        appBar: AppBar(title: const Text('肖像')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '未能定位此 ROM 的肖像表。\n'
              '汉化/改版可能重写过 portrait_pointer（'
              '${widget.edit.rom.table.id}），预览暂不支持。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.orange.shade900),
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title:
            Text(_done ? '肖像 ($_itemsCount)' : '肖像 (加载中 $_itemsCount…)'),
      ),
      body: ListView.separated(
        itemCount: _items.length + (_done ? 0 : 1),
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          if (i >= _items.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final t = _items[i];
          final face = _reader.faceImage(t.id);
          return ListTile(
            leading: SizedBox(
              width: 40,
              height: 40,
              child: face == null
                  ? const Icon(Icons.image_not_supported,
                      size: 20, color: Colors.grey)
                  : PortraitView(
                      tile: face,
                      cacheKey: t.id * 1000 + 1,
                      width: 40,
                      height: 40,
                    ),
            ),
            title: Text(t.name.isEmpty ? '肖像 ${t.id}' : t.name),
            subtitle: Text('ID ${t.id}${t.halfBody ? ' · 扩展肖像' : ''}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PortraitDetailPage(
                  reader: _reader,
                  id: t.id,
                  name: t.name,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  int get _itemsCount => _items.length;
}

class PortraitDetailPage extends StatelessWidget {
  final PortraitReader reader;
  final int id;
  final String name;

  const PortraitDetailPage({
    super.key,
    required this.reader,
    required this.id,
    required this.name,
  });

  @override
  Widget build(BuildContext context) {
    final half = reader.isHalfBody(id);
    final face = reader.faceImage(id);
    return Scaffold(
      appBar: AppBar(title: Text(name.isEmpty ? '肖像 $id' : name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: face == null
                ? const SizedBox(
                    width: 96,
                    height: 80,
                    child: Center(child: Icon(Icons.image_not_supported)),
                  )
                : PortraitView(
                    tile: face,
                    cacheKey: id * 1000 + 2,
                    width: 96,
                    height: 80,
                  ),
          ),
          if (half)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '此肖像使用了扩展数据（halfbody），此处显示标准部分。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.orange.shade900, fontSize: 12),
              ),
            ),
          const SizedBox(height: 16),
          if (!reader.isFe6)
            _frameRow('眼型', [
              ('半目', reader.eyeFrame(id, closed: false)),
              ('闭眼', reader.eyeFrame(id, closed: true)),
            ]),
          _frameRow('嘴型', [
            for (var f = 1; f <= (reader.isFe6 ? 5 : 6); f++)
              ('帧 $f', reader.mouthFrame(id, f)),
          ]),
          _frameRow('其它', [
            ('地图头像', reader.mapFaceImage(id)),
            ('职业卡', reader.classCardImage(id)),
          ]),
          const SizedBox(height: 16),
          Text(
            'ID $id · 表项 ${reader.isFe6 ? 16 : 28} 字节',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _frameRow(String label, List<(String, TileImage?)> frames) {
    final shown = frames.where((f) => f.$2 != null).toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              for (var i = 0; i < shown.length; i++)
                Column(
                  children: [
                    // cacheKey 必须每帧唯一，否则不同帧会互相覆盖缓存而串图
                    _Preview(tile: shown[i].$2!, cacheKey: id * 100 + i),
                    Text(shown[i].$1, style: const TextStyle(fontSize: 11)),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  final TileImage tile;
  final int cacheKey;
  const _Preview({required this.tile, required this.cacheKey});

  @override
  Widget build(BuildContext context) {
    final scaled = tile.fitIn(64, 64);
    return PortraitView(
      tile: scaled,
      cacheKey: cacheKey,
      width: scaled.width.toDouble(),
      height: scaled.height.toDouble(),
    );
  }
}
