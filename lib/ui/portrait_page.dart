import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/asset_library.dart';
import '../core/battle_anim.dart' show encodePng;
import '../core/editable_rom.dart';
import '../core/fe_rom.dart';
import '../core/file_picker_service.dart';
import '../core/portrait.dart';
import '../core/tile_image.dart';
import 'portrait_import_page.dart';

/// 把 [TileImage] 的 RGBA 字节转成可绘制的 `ui.Image`，并按 key 缓存。
///
/// `decodeImageFromPixels` 是异步的，所以对外统一返回 Future；
/// 缓存命中时同步完成，滑动列表不会掉帧。
///
/// **key 必须含 ROM 身份**：缓存是全局单例，只按「肖像索引 + 用途」做 key 的话，
/// 先打开烈火之剑再打开封印之剑，相同索引会直接命中上一个 ROM 的图。
///
/// 身份由调用方显式传入（[keyFor] 的 `romTag`），而不是「当前 ROM」这样的
/// 全局状态：多个 ROM 同时打开时，各自页面始终读到自己那份图，
/// 也不会因为切换 ROM 把另一份的缓存清掉。
class PortraitImageCache {
  PortraitImageCache._();
  static final PortraitImageCache instance = PortraitImageCache._();

  static const int cacheLimit = 96;
  final _images = <int, ui.Image>{};

  /// 每次写入肖像后自增。参与 key，让写入后的新图不会命中旧缓存。
  ///
  /// 不用「清空 map」实现：清空会让正在显示的 [RawImage] 拿到已失效句柄，
  /// 且旧图其实还在 widget 手上一段时间，不如换个 key 让它自然失效。
  int _generation = 0;

  /// 告诉缓存「ROM 内容变了」。调用后所有 key 都会变，下次 build 重新解码。
  void invalidate() {
    _generation++;
    // 旧图不 dispose（见 [clear] 的说明），只从 map 里丢掉引用
    _images.clear();
  }

  /// 把 [romTag]（指纹）与 [contentVersion] 合成一个稳定的缓存键前缀。
  ///
  /// 不用乘法拼接（`指纹 × N + 代次 × M`）：位域重叠，不同指纹配不同
  /// 代次会撞 key。用顺序哈希把几段揉进一个整数，冲突只影响缓存命中率。
  int _baseKey(int romTag, int contentVersion) {
    var h = 0x811C9DC5;
    for (final v in [romTag, contentVersion, _generation]) {
      var x = v & 0xFFFFFFFF;
      for (var i = 0; i < 4; i++) {
        h ^= x & 0xFF;
        h = (h * 0x01000193) & 0x7FFFFFFF;
        x >>= 8;
      }
    }
    return h;
  }

  /// 拼 key：ROM 指纹 | 内容版本号 | 代次 | 索引 | 用途。
  ///
  /// **必须传 `contentVersion`**（`EditableRom.contentVersion`）：指纹是
  /// **打开时**算的，写 ROM 不会变它。以前只看指纹，导入一张脸后撤销全部，
  /// 界面就一直显示导入的那张。参数写成可选只为兼容旧调用点。
  int keyFor(int romTag, int portraitId, int purpose,
      {int contentVersion = 0}) {
    final id = portraitId & 0xFFFF;
    return _baseKey(romTag, contentVersion) * 0x1000 +
        ((id & 0xFFF) << 4) +
        (purpose & 0xF);
  }

  /// 直接用 ROM 视图拼 key（推荐）：指纹 + 内容版本号自动带上。
  ///
  /// 必须传**实时视图**（`EditableRom.liveRom`），因为内容版本号记在它身上。
  int keyForRom(FeRom rom, int portraitId, int purpose) => keyFor(
      rom.fingerprint, portraitId, purpose,
      contentVersion: rom.contentVersion);

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
    // **不能 dispose**：界面上正在显示的 RawImage 还持着这些句柄，
    // dispose 后 Flutter 会在下一帧 throw「Cannot clone a disposed image」。
    // 交给 GC —— 这里的图最多几十张，不主动释放不会有可见的内存压力。
    _images.clear();
  }
}

/// 统一的图像展示控件：异步解码 + 缓存 + 失败兜底。
class PortraitView extends StatefulWidget {
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
  State<PortraitView> createState() => _PortraitViewState();
}

class _PortraitViewState extends State<PortraitView> {
  Future<ui.Image>? _future;
  int? _key;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PortraitView old) {
    super.didUpdateWidget(old);
    // key 变了（换 ROM / 换条目 / 缓存被清后重算）就必须重新取图，
    // 否则 FutureBuilder 会一直拿着旧的已完成 future，界面永远不更新。
    if (old.cacheKey != widget.cacheKey || old.tile != widget.tile) {
      _load();
    }
  }

  void _load() {
    _key = widget.cacheKey;
    _future = PortraitImageCache.instance.load(widget.cacheKey, widget.tile);
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    final height = widget.height;
    return FutureBuilder<ui.Image>(
      key: ValueKey(_key),
      future: _future,
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
  int? _selectedId;
  late PortraitReader _reader = PortraitReader(widget.edit.liveRom);
  final List<_PortraitTile> _items = [];
  int _scanned = 0;
  bool _done = false;
  bool _unavailable = false;
  String _query = '';
  /// 导入后覆盖的肖像名：key=portrait ID，value=导入时计算出的显示名。
  /// 用于「导入后 portrait editor 仍显示旧角色名」的问题——portrait table
  /// entry 已更新，但 unit table 的 face 字段未变，nameFor(id) 仍返回旧名。
  final Map<int, String> _importedNames = {};

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
    super.dispose();
  }

  Future<void> _loadMore() async {
    if (_done) return;
    final total = _reader.entryCount;
    final end = (_scanned + _batchSize).clamp(0, total);
    final batch = <_PortraitTile>[];
    for (var id = _scanned; id < end; id++) {
      if (!_reader.hasImage(id)) continue;
      final name = _importedNames[id] ?? _reader.nameFor(id);
      batch.add(_PortraitTile(id, name, _reader.isHalfBody(id)));
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
        title: Text(_done ? '肖像 ($_itemsCount)' : '肖像 (加载中 $_itemsCount…)'),
        actions: [
          IconButton(
            tooltip: '用外部图片新建肖像',
            icon: const Icon(Icons.add_photo_alternate_outlined),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => PortraitImportPage(
                        edit: widget.edit,
                        initialTargetId: _selectedId)),
              ).then((result) {
                // 子页面可能写入了肖像：reader 里的 sheet 缓存是旧图，
                // 不重建的话详情页会一直显示写入前的脸（只有不走缓存
                // 的嘴型帧会变成新图——实测就是这个现象）。
                _reader.dispose();
                _reader = PortraitReader(widget.edit.liveRom);
                if (result != null && mounted) {
                  final id = result['id'] as int?;
                  final name = result['name'] as String?;
                  if (id != null && name != null) {
                    setState(() => _importedNames[id] = name);
                  }
                }
                setState(() {});
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              decoration: const InputDecoration(
                isDense: true,
                hintText: '搜索肖像名 / ID',
                prefixIcon: Icon(Icons.search, size: 20),
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: _visible.length + (_done ? 0 : 1),
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                if (i >= _visible.length) {
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
                final t = _visible[i];
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
                            cacheKey:
                                PortraitImageCache.instance.keyForRom(_reader.rom, t.id, 1),
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
          ),
        ],
      ),
    );
  }

  /// 当前可见条目：搜索时对已加载条目做名字 / ID 过滤。
  List<_PortraitTile> get _visible {
    final q = _query;
    if (q.isEmpty) return _items;
    final asId = int.tryParse(q);
    return _items
        .where((t) =>
            t.name.contains(q) ||
            t.id.toRadixString(16).toUpperCase().contains(q.toUpperCase()) ||
            (asId != null && t.id == asId))
        .toList();
  }

  int get _itemsCount {
    final q = _query;
    return q.isEmpty ? _items.length : _visible.length;
  }
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

  /// 导出档名后缀：可再导入的素材图与内部 sheet 分开，避免同名覆盖。
  static const String _materialSuffix = '_sheet';
  static const String _rawSuffix = '_raw';

  @override
  Widget build(BuildContext context) {
    final half = reader.isHalfBody(id);
    final face = reader.faceImage(id);
    return Scaffold(
      appBar: AppBar(
        title: Text(name.isEmpty ? '肖像 $id' : name),
        actions: [
          if (face != null)
            IconButton(
              tooltip: '存入素材库',
              icon: const Icon(Icons.save_alt),
              onPressed: () => _saveAsset(context, face),
            ),
          if (face != null)
            IconButton(
              tooltip: '导出素材图（128×112，可再导回游戏）',
              icon: const Icon(Icons.view_comfy_alt_outlined),
              onPressed: () {
                final sheet = reader.sheetMaterialImage(id);
                if (sheet == null) return;
                _saveAsset(context, sheet, suffix: _materialSuffix);
              },
            ),
          if (face != null)
            IconButton(
              tooltip: '导出原始 sheet（256×40，仅供查看，不能导回）',
              icon: const Icon(Icons.view_comfy_alt_outlined),
              onPressed: () {
                final sheet = reader.fullSheetImage(id);
                if (sheet == null) return;
                _saveAsset(context, sheet, suffix: _rawSuffix);
              },
            ),
        ],
      ),
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
                    cacheKey: PortraitImageCache.instance.keyForRom(reader.rom, id, 2),
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

  /// 把当前肖像存到素材库；未配置素材库时退回「另存为」。
  ///
  /// [suffix] 区分档名：正脸空白（
  /// `portrait_001_罗伊.png`），素材图 `_sheet`，原始 sheet `_raw`。
  Future<void> _saveAsset(BuildContext context, TileImage face,
      {String suffix = ''}) async {
    final safeName =
        name.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final fileName =
        'portrait_${id.toString().padLeft(3, '0')}'
        '${safeName.isEmpty ? '' : '_$safeName'}$suffix.png';
    final png = encodePng(face);
    final messenger = ScaffoldMessenger.of(context);
    if (AssetLibrary.instance.configured) {
      final ok = await AssetLibrary.instance.write(fileName, png);
      messenger.showSnackBar(SnackBar(
        content: Text(ok
            ? '已存入素材库 $fileName'
            : '存入素材库失败：${AssetLibrary.instance.lastError ?? '未知原因'}'),
      ));
      return;
    }
    final saved = await saveFile(fileName, png);
    messenger.showSnackBar(
        SnackBar(content: Text(saved == null ? '已取消' : '已保存 $fileName')));
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
                    _Preview(
                      tile: shown[i].$2!,
                      cacheKey: PortraitImageCache.instance.keyForRom(reader.rom, id, 3 + i),
                    ),
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
