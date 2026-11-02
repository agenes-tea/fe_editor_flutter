import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/battle_anim.dart' show encodePng;
import '../core/editable_rom.dart';
import '../core/event_preview.dart';
import '../core/map_reader.dart';
import '../core/map_writer.dart';
import '../core/tile_image.dart';
import '../core/unit_placement.dart';
import 'map_image_cache.dart';

/// 地形砖块编辑页。
///
/// 地图本体是 `w×h` 的砖块 ID 数组（每格 16×16 像素，砖块再经 TSA 展开成
/// 8×8 tile），所以编辑就是「选一个砖块 → 在地图上涂抹」。
///
/// 两条硬约束：
/// - **只写本地**：地图的 plist 索引在多个章节之间共享（实测 FE8J 有
///   28 章共用地图、FE6 有 21 章），重指向会把共享它的章节一起改掉，
///   所以只做原地写入；压缩后变长时提示「少改几格」，绝不搬家。
/// - **改尺寸会连带共享章节**：宽高与砖块写在同一条记录里，一张地图被
///   多个章节共用时尺寸会一起变；改前会点名共享章节与「会越界的单位」。
class MapTileEditorPage extends StatefulWidget {
  final EditableRom edit;
  final int chapter;

  const MapTileEditorPage({
    super.key,
    required this.edit,
    required this.chapter,
  });

  @override
  State<MapTileEditorPage> createState() => _MapTileEditorPageState();
}

class _MapTileEditorPageState extends State<MapTileEditorPage> {
  late final MapReader _reader = MapReader(widget.edit.liveRom);

  ChapterMap? _original;
  List<int>? _tiles;
  int _brush = 0;
  int _dirtyCells = 0;
  String? _error;

  /// 砖块缩略图的 PNG（按砖块值缓存，涂改地图时不重复编码）。
  final _thumbCache = <int, Uint8List>{};

  @override
  void initState() {
    super.initState();
    final map = _reader.chapterMap(widget.chapter);
    _original = map;
    if (map != null) {
      _tiles = List<int>.from(map.tiles);
      _brush = map.tiles.isNotEmpty ? map.tiles.first : 0;
    }
  }

  ChapterMap? get _map => _tiles == null ? null : _original;
  void _paint(int x, int y) {
    final map = _map;
    final tiles = _tiles;
    if (map == null || tiles == null) return;
    if (x < 0 || y < 0 || x >= map.width || y >= map.height) return;
    final at = y * map.width + x;
    if (tiles[at] == _brush) return;
    setState(() {
      tiles[at] = _brush;
      _dirtyCells++;
      _error = null;
    });
  }

  void _reset() {
    final original = _original;
    if (original == null) return;
    setState(() {
      _tiles = List<int>.from(original.tiles);
      _dirtyCells = 0;
      _error = null;
    });
  }

  Future<void> _save() async {
    final tiles = _tiles;
    if (tiles == null) return;
    final result = MapWriter(widget.edit).write(widget.chapter, tiles);
    if (!mounted) return;
    if (!result.ok) {
      setState(() => _error = result.message);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(result.message)));
      return;
    }
    // 写回后重读一次，界面显示的就是 ROM 里的真实内容
    MapImageCache.instance.clear();
    final back = MapReader(widget.edit.liveRom).chapterMap(widget.chapter);
    setState(() {
      _original = back;
      _tiles = back == null ? null : List<int>.from(back.tiles);
      _dirtyCells = 0;
      _error = null;
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已写回（可整体撤销）')));
  }

  @override
  Widget build(BuildContext context) {
    final map = _map;
    return Scaffold(
      appBar: AppBar(
        title: Text('第 ${widget.chapter} 章 · 地形'),
        actions: [
          if (_dirtyCells > 0)
            IconButton(
              tooltip: '放弃本页改动',
              icon: const Icon(Icons.restart_alt),
              onPressed: _reset,
            ),
          IconButton(
            tooltip: '写回 ROM',
            icon: const Icon(Icons.save),
            onPressed: _dirtyCells > 0 ? _save : null,
          ),
        ],
      ),
      body: map == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '这一章的地图数据定位不到，无法编辑。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.orange.shade900),
                ),
              ),
            )
          : Column(
              children: [
                _toolbar(map),
                Expanded(child: _canvas(map)),
                _palette(map),
              ],
            ),
    );
  }

  Widget _toolbar(ChapterMap map) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: scheme.surfaceContainerHighest,
      child: Row(
        children: [
          Expanded(
            child: Text(
              _error ??
                  '${map.width}×${map.height} 格 · 砖块 '
                      '0x${_brush.toRadixString(16).toUpperCase()}'
                      '${_dirtyCells > 0 ? ' · 已改 $_dirtyCells 格（未写入）' : ''}',
              style: TextStyle(
                  fontSize: 12, color: _error == null ? null : scheme.error),
            ),
          ),
          TextButton(
            onPressed: () => _openSizeDialog(map),
            child: const Text('改尺寸', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// 改地图宽高：重排砖块（行主序裁切/补 0）→ 重打包 → 就地写回。
  ///
  /// 写前把「共享章节」「会越界的单位」两样点名给用户看；写回后地图缓存
  /// 失效、页面状态重读。
  void _openSizeDialog(ChapterMap map) {
    final shared = _reader.sharedChapters(widget.chapter, 'map');
    final placement = UnitPlacement(widget.edit);
    // 静态表单位（遭遇 6 槽在 FE8 是另一张遭遇地图，不参与本图坐标）
    final staticUnits = [
      for (final slot in UnitSlot.values
          .where(placement.slotSupported)
          .where((s) => !s.isEncounter))
        for (final u in placement.units(widget.chapter, slot))
          (u.x, u.y),
    ];
    final preview = EventPreviewer(widget.edit).of(widget.chapter);
    final eventUnits = [
      for (final e in preview.events)
        ...e.units.map((u) => (u.x, u.y)),
    ];
    final coords = [...staticUnits, ...eventUnits];

    int outsideCount(int nw, int nh) {
      var n = 0;
      for (final (x, y) in coords) {
        if (x >= nw || y >= nh) n++;
      }
      return n;
    }

    Uint8List? renderPreview(int nw, int nh, List<int> tiles) {
      final parts = _renderParts();
      if (parts == null) return null;
      final img = MapReader.renderTiles(parts.$1, MapReader.chipWidth,
          _reader.chipHeight, parts.$2, nw, nh, tiles, parts.$3);
      return encodePng(img);
    }

    showDialog<void>(
      context: context,
      builder: (ctx) => _SizeDialog(
        oldWidth: map.width,
        oldHeight: map.height,
        tiles: _tiles!,
        sharedChapters: shared,
        outsideCount: outsideCount,
        renderPreview: renderPreview,
        onConfirm: _applySize,
      ),
    );
  }

  Future<void> _applySize(int nw, int nh, List<int> remapped) async {
    final result = MapWriter(widget.edit)
        .writeSize(widget.chapter, nw, nh, remapped);
    if (!mounted) return;
    if (!result.ok) {
      setState(() => _error = result.message);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(result.message)));
      return;
    }
    MapImageCache.instance.clear();
    final back = MapReader(widget.edit.liveRom).chapterMap(widget.chapter);
    setState(() {
      _original = back;
      _tiles = back == null ? null : List<int>.from(back.tiles);
      _brush = _tiles != null && _tiles!.isNotEmpty ? _tiles!.first : 0;
      _dirtyCells = 0;
      _error = null;
    });
    final msg = result.mode == MapWriteMode.identical
        ? '尺寸未变，未写入'
        : '尺寸已写回（可整体撤销）';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Widget _canvas(ChapterMap map) {
    final tiles = _tiles!;
    final png = _renderPng(map, tiles);
    return InteractiveViewer(
      maxScale: 4,
      child: Center(
        child: SizedBox(
          width: map.width * 16,
          height: map.height * 16,
          child: Stack(
            children: [
              if (png != null)
                Positioned.fill(
                  child: Image.memory(
                    png,
                    filterQuality: FilterQuality.none,
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                  ),
                ),
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _paint(
                    (d.localPosition.dx / 16).floor(),
                    (d.localPosition.dy / 16).floor(),
                  ),
                ),
              ),
              Positioned.fill(child: CustomPaint(painter: _GridPainter(map))),
            ],
          ),
        ),
      ),
    );
  }

  /// 渲染当前砖块数组。用同步 PNG 编码（`encodePng`）而不是
  /// `decodeImageFromPixels`：后者是异步回调，widget 测试里不会触发。
  Uint8List? _renderPng(ChapterMap map, List<int> tiles) {
    final parts = _renderParts();
    if (parts == null) return null;
    final tile = MapReader.renderTiles(parts.$1, MapReader.chipWidth,
        _reader.chipHeight, parts.$2, map.width, map.height, tiles, parts.$3);
    return encodePng(tile);
  }

  (Uint8List, Uint8List, List<GbaPalette>)? _renderParts() {
    final indices = _reader.chipIndices(widget.chapter);
    final cfg = _reader.configData(widget.chapter);
    final palettes = _reader.mapPalettes(widget.chapter);
    if (indices == null || cfg == null || palettes == null) return null;
    return (indices, cfg, palettes);
  }

  Widget _palette(ChapterMap map) {
    final tiles = _tiles!;
    final used = <int>[...tiles.toSet()]..sort();
    final choices = _choices(used, _reader.chipCount(widget.chapter));
    return Container(
      height: 104,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(
              '选择砖块（本章已用 ${used.length} 种）',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              itemCount: choices.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) => _swatch(choices[i]),
            ),
          ),
        ],
      ),
    );
  }

  /// 候选砖块：本章已用的全部砖块 + 补足到 24 个未用过的（便于换成新地形）。
  List<int> _choices(List<int> used, int chipCount) {
    const target = 24;
    if (used.length >= target) return used;
    final out = <int>[...used];
    final usedSet = used.toSet();
    for (var step = 1; step < chipCount && out.length < target * 2; step++) {
      final v = step * 4;
      if (usedSet.contains(v)) continue;
      out.add(v);
      if (out.length >= target) break;
    }
    return out;
  }

  Widget _swatch(int value) {
    final selected = value == _brush;
    final png = _thumbCache.putIfAbsent(value, () {
      final parts = _renderParts();
      if (parts == null) return Uint8List(0);
      final tile = MapReader.renderTiles(parts.$1, MapReader.chipWidth,
          _reader.chipHeight, parts.$2, 1, 1, [value], parts.$3);
      return encodePng(tile);
    });
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => setState(() => _brush = value),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 56,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: png.isEmpty
                  ? const SizedBox.shrink()
                  : Image.memory(png,
                      filterQuality: FilterQuality.none,
                      fit: BoxFit.contain),
            ),
            Text(
              '0x${value.toRadixString(16).toUpperCase()}',
              style: const TextStyle(fontSize: 9),
            ),
          ],
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  final ChapterMap map;
  _GridPainter(this.map);

  @override
  void paint(Canvas canvas, Size size) {
    // 格子多时抽稀网格，避免密集线条糊成一片
    final step = map.width > 32 ? 2 : 1;
    final paint = Paint()
      ..color = Colors.black.withValues(alpha: 0.12)
      ..strokeWidth = 0.5;
    for (var x = 0; x <= map.width; x += step) {
      final dx = x * 16.0;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), paint);
    }
    for (var y = 0; y <= map.height; y += step) {
      final dy = y * 16.0;
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) => old.map != map;
}

/// 改尺寸对话框：输入新宽高 → 实时预览重排后的地图 + 点名共享章节与
/// 会越界的单位 → 确认后写回（可整体撤销）。
class _SizeDialog extends StatefulWidget {
  final int oldWidth;
  final int oldHeight;
  final List<int> tiles;
  final List<int> sharedChapters;
  final int Function(int newW, int newH) outsideCount;
  final Uint8List? Function(int newW, int newH, List<int> tiles)
      renderPreview;
  final Future<void> Function(int newW, int newH, List<int> remapped)
      onConfirm;

  const _SizeDialog({
    required this.oldWidth,
    required this.oldHeight,
    required this.tiles,
    required this.sharedChapters,
    required this.outsideCount,
    required this.renderPreview,
    required this.onConfirm,
  });

  @override
  State<_SizeDialog> createState() => _SizeDialogState();
}

class _SizeDialogState extends State<_SizeDialog> {
  late String _wText = '${widget.oldWidth}';
  late String _hText = '${widget.oldHeight}';
  bool _busy = false;

  int get _nw => int.tryParse(_wText) ?? 0;
  int get _nh => int.tryParse(_hText) ?? 0;

  bool get _valid =>
      _nw >= 1 && _nw <= 64 && _nh >= 1 && _nh <= 64;

  List<int> get _remapped => _valid
      ? MapWriter.remapTiles(
          widget.tiles, widget.oldWidth, widget.oldHeight, _nw, _nh)
      : const [];

  void _onFieldChanged(String w, String h) {
    setState(() {
      _wText = w;
      _hText = h;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final outside = _valid ? widget.outsideCount(_nw, _nh) : 0;
    final kept = _valid
        ? (widget.oldWidth.clamp(0, _nw)) * (widget.oldHeight.clamp(0, _nh))
        : 0;
    final dropped = widget.oldWidth * widget.oldHeight - kept;
    final png = _valid ? widget.renderPreview(_nw, _nh, _remapped) : null;

    return AlertDialog(
      title: Text('把地图改为 ${widget.oldWidth}×${widget.oldHeight} → '
          '${_nw <= 0 ? '?' : _nw}×${_nh <= 0 ? '?' : _nh} 格'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 90,
                  child: TextFormField(
                    initialValue: '${widget.oldWidth}',
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                        labelText: '新宽（格）', isDense: true),
                    onChanged: (v) => _onFieldChanged(v, _hText),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 90,
                  child: TextFormField(
                    initialValue: '${widget.oldHeight}',
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                        labelText: '新高（格）', isDense: true),
                    onChanged: (v) => _onFieldChanged(_wText, v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_valid && png != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(
                  png,
                  filterQuality: FilterQuality.none,
                  fit: BoxFit.contain,
                ),
              ),
            if (_valid) ...[
              const SizedBox(height: 10),
              Text(
                '砖块按行主序重排：旧图里 ${kept.clamp(0, widget.oldWidth * widget.oldHeight)} 格保留，'
                '${dropped < 0 ? 0 : dropped} 格丢弃；新图里旧图没有的格子填 0（本图第一个地形）。',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
            if (widget.sharedChapters.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '⚠ 这张地图由章节 '
                '${widget.sharedChapters.take(6).join('、')}'
                '${widget.sharedChapters.length > 6 ? ' 等' : ''} '
                '共用，改尺寸会连同那些章节一起变。',
                style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
              ),
            ],
            if (outside > 0) ...[
              const SizedBox(height: 8),
              Text(
                '⚠ 本章有 $outside 个单位（静态表+事件生成）在新尺寸下会超出地图范围，'
                '游戏里它们会显示异常或无法移动。',
                style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '压缩后放不下会被拒绝（地图跨章节共享，不能搬家）；写回后可整体撤销。',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _valid && !_busy
              ? () async {
                  setState(() => _busy = true);
                  await widget.onConfirm(_nw, _nh, _remapped);
                  if (context.mounted) Navigator.pop(context);
                }
              : null,
          child: const Text('确认改尺寸'),
        ),
      ],
    );
  }
}
