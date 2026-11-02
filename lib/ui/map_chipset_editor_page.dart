import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/battle_anim.dart' show encodePng;
import '../core/editable_rom.dart';
import '../core/map_reader.dart';
import '../core/map_writer.dart';
import '../core/tile_image.dart';
import 'map_image_cache.dart';

/// chipset（TSA 砖块图形）编辑页。
///
/// 地图「地形长什么样」= 本芯片组（chipset）的 4bpp 位图 + 调色板。
/// 这里改的是位图本身（每个像素是一个 0..15 的调色板索引）：
/// 画点、填格、取色、复制 8×8 tile、镜像。保存时逐 blob 重压缩、
/// **就地覆盖**（chipset 的 plist 索引跨章节共享，变长就整批拒绝）。
///
/// 调色板本身不改：一组调色板被同章所有引用该组的 tile 共用，改色会
/// 影响一大片地形（要改色请整体评估影响面，不在本页开放）。
class MapChipsetEditorPage extends StatefulWidget {
  final EditableRom edit;
  final int chapter;

  const MapChipsetEditorPage({
    super.key,
    required this.edit,
    required this.chapter,
  });

  @override
  State<MapChipsetEditorPage> createState() =>
      _MapChipsetEditorPageState();
}

/// 编辑工具。
enum CsTool { paint, fill, eyedrop, copy, mirrorH, mirrorV }

/// 预览图放大倍数（8×8 tile = 16px，小屏可直接点）。
const _kZoom = 2;

class _MapChipsetEditorPageState extends State<MapChipsetEditorPage> {
  late MapReader _reader;
  late List<ChipsetBlob> _blobs;
  List<int>? _indices;

  CsTool _tool = CsTool.paint;
  int _color = 1;

  /// 预览上色用的调色板组（-1 = 按索引值画灰度）。
  int _group = -1;

  int? _copyFromTile;
  int? _lastTile;
  String? _error;
  bool _dirty = false;

  List<GbaPalette>? get _palettes => _reader.mapPalettes(widget.chapter);

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _reader = MapReader(widget.edit.liveRom);
    _blobs = _reader.chipsetBlobs(widget.chapter);
    if (_blobs.isNotEmpty) {
      _indices = List<int>.from(_reader.chipIndices(widget.chapter) ?? []);
      // 默认预览用 TSA 里出现次数最多的调色板组，最接近「游戏里的样子」
      _group = _dominantGroup();
    } else {
      _indices = null;
    }
    _dirty = false;
    _error = null;
    _copyFromTile = null;
    _lastTile = null;
  }

  int _dominantGroup() {
    final cfg = _reader.configData(widget.chapter);
    final pals = _palettes;
    if (cfg == null || pals == null) return -1;
    final count = List<int>.filled(pals.length, 0);
    for (var i = 0; i + 1 < cfg.length; i += 2) {
      final entry = cfg[i] | (cfg[i + 1] << 8);
      if (entry == 0xFFFF) continue;
      final g = (entry >> 12) & 0xF;
      if (g < count.length) count[g]++;
    }
    var best = -1;
    var bestN = 0;
    for (var g = 0; g < count.length; g++) {
      if (count[g] > bestN) {
        bestN = count[g];
        best = g;
      }
    }
    return best;
  }

  int get _pixelHeight {
    var h = 0;
    for (final b in _blobs) h += b.pixelHeight;
    return h;
  }

  int _tileOf(int px, int py) => (py ~/ 8) * 32 + (px ~/ 8);

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  void _reset() {
    _reload();
    setState(() {});
  }

  // ---------- 工具 ----------

  void _paintPixel(int px, int py) {
    final indices = _indices;
    if (indices == null ||
        px < 0 ||
        py < 0 ||
        px >= MapReader.chipWidth ||
        py >= _pixelHeight) {
      return;
    }
    if (indices[py * MapReader.chipWidth + px] == _color) return;
    indices[py * MapReader.chipWidth + px] = _color;
    _lastTile = _tileOf(px, py);
    _markDirty();
  }

  void _fillTile(int tx, int ty) {
    final indices = _indices;
    if (indices == null) return;
    final base = ty * 8 * MapReader.chipWidth + tx * 8;
    for (var py = 0; py < 8; py++) {
      for (var px = 0; px < 8; px++) {
        indices[base + py * MapReader.chipWidth + px] = _color;
      }
    }
    _lastTile = ty * 32 + tx;
    _markDirty();
  }

  void _eyedrop(int px, int py) {
    final indices = _indices;
    if (indices == null) return;
    final v = indices[py * MapReader.chipWidth + px] & 0x0F;
    setState(() {
      _color = v;
      _tool = CsTool.paint;
    });
  }

  void _copyTile(int tx, int ty) {
    final from = _copyFromTile;
    if (from == null) {
      _copyFromTile = ty * 32 + tx;
      setState(() {});
      return;
    }
    final indices = _indices;
    if (indices == null) return;
    final srcBase = (from! ~/ 32) * 8 * MapReader.chipWidth +
        (from % 32) * 8;
    final dstBase = ty * 8 * MapReader.chipWidth + tx * 8;
    for (var py = 0; py < 8; py++) {
      for (var px = 0; px < 8; px++) {
        indices[dstBase + py * MapReader.chipWidth + px] =
            indices[srcBase + py * MapReader.chipWidth + px];
      }
    }
    _copyFromTile = null;
    _lastTile = ty * 32 + tx;
    _markDirty();
  }

  void _mirror(int tx, int ty, bool horizontal) {
    final indices = _indices;
    if (indices == null) return;
    final base = ty * 8 * MapReader.chipWidth + tx * 8;
    if (horizontal) {
      for (var py = 0; py < 8; py++) {
        for (var px = 0; px < 4; px++) {
          final a = base + py * MapReader.chipWidth + px;
          final b = base + py * MapReader.chipWidth + 7 - px;
          final t = indices[a];
          indices[a] = indices[b];
          indices[b] = t;
        }
      }
    } else {
      for (var px = 0; px < 8; px++) {
        for (var py = 0; py < 4; py++) {
          final a = base + py * MapReader.chipWidth + px;
          final b = base + (7 - py) * MapReader.chipWidth + px;
          final t = indices[a];
          indices[a] = indices[b];
          indices[b] = t;
        }
      }
    }
    _lastTile = ty * 32 + tx;
    _markDirty();
  }

  void _tapAt(int px, int py) {
    final tx = px ~/ 8;
    final ty = py ~/ 8;
    switch (_tool) {
      case CsTool.paint:
        _paintPixel(px, py);
      case CsTool.fill:
        _fillTile(tx, ty);
      case CsTool.eyedrop:
        _eyedrop(px, py);
      case CsTool.copy:
        _copyTile(tx, ty);
      case CsTool.mirrorH:
        _mirror(tx, ty, true);
      case CsTool.mirrorV:
        _mirror(tx, ty, false);
    }
  }

  // ---------- 保存 ----------

  Future<void> _save() async {
    final indices = _indices;
    if (indices == null || !indices.isNotEmpty) return;
    final result = MapWriter(widget.edit).writeChipset(widget.chapter, indices);
    if (!mounted) return;
    if (!result.ok) {
      setState(() => _error = result.message);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(result.message)));
      return;
    }
    _reload();
    MapImageCache.instance.clear();
    setState(() {});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text(result.mode == ChipsetWriteMode.inPlace
              ? '已写回（可整体撤销）'
              : '内容与 ROM 相同，未写入')));
  }

  // ---------- 渲染 ----------

  /// 预览图：按当前索引 + 选中调色板组（或灰度索引视图）上色。
  ///
  /// 渲染 2 倍图（512 × 2H），小屏上 8×8 tile 有 16px，能直接点；
  /// 手势坐标 ÷2 换回 chipset 像素坐标。
  Uint8List? _renderPng() {
    final indices = _indices;
    if (indices == null || indices.isEmpty) return null;
    final w = MapReader.chipWidth * _kZoom;
    final h = _pixelHeight * _kZoom;
    final img = TileImage(w, h);
    final pals = _palettes;
    for (var y = 0; y < _pixelHeight; y++) {
      for (var x = 0; x < MapReader.chipWidth; x++) {
        final idx = indices[y * MapReader.chipWidth + x] & 0x0F;
        int argb;
        if (_group >= 0 && pals != null) {
          argb = pals[_group].color(idx);
          if (idx == 0) argb &= 0x00FFFFFF; // 索引 0 透明，露页面底
        } else {
          final v = idx * 16;
          argb = 0xFF000000 | (v << 16) | (v << 8) | v;
        }
        for (var dy = 0; dy < _kZoom; dy++) {
          for (var dx = 0; dx < _kZoom; dx++) {
            final di = ((y * _kZoom + dy) * w + (x * _kZoom + dx)) * 4;
            img.pixels[di] = (argb >> 16) & 0xFF;
            img.pixels[di + 1] = (argb >> 8) & 0xFF;
            img.pixels[di + 2] = argb & 0xFF;
            img.pixels[di + 3] = (argb >> 24) & 0xFF;
          }
        }
      }
    }
    return encodePng(img);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_indices == null) {
      return Scaffold(
        appBar: AppBar(
            title: Text('第 ${widget.chapter} 章 · 砖块图形')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '这一章的 chipset 图形定位不到，无法编辑。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.orange.shade900),
            ),
          ),
        ),
      );
    }
    final shared = _reader.sharedChapters(widget.chapter, 'obj');
    final png = _renderPng();
    return Scaffold(
      appBar: AppBar(
        title: Text('第 ${widget.chapter} 章 · 砖块图形'),
        actions: [
          if (_dirty)
            IconButton(
              tooltip: '放弃本页改动',
              icon: const Icon(Icons.restart_alt),
              onPressed: _reset,
            ),
          IconButton(
            tooltip: '写回 ROM',
            icon: const Icon(Icons.save),
            onPressed: _dirty ? _save : null,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(_error!,
                  style: TextStyle(
                      fontSize: 12, color: scheme.error, height: 1.4)),
            ),
          if (shared.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '这份 chipset 与章节 ${shared.take(6).join('、')}'
                '${shared.length > 6 ? ' 等' : ''} 章共用，改动会连带影响那些章节。',
                style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
              ),
            ),
          _toolRow(),
          _swatchRow(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: InteractiveViewer(
              maxScale: 8.0,
              child: Center(
                child: SizedBox(
                  width: (MapReader.chipWidth * _kZoom).toDouble(),
                  height: (_pixelHeight * _kZoom).toDouble(),
                  child: Stack(
                    children: [
                      if (png != null)
                        Image.memory(
                          png,
                          filterQuality: FilterQuality.none,
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                        ),
                      CustomPaint(
                        painter: _GridPainter(_lastTile, _copyFromTile,
                            _pixelHeight * _kZoom),
                      ),
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (d) => _tapAt(
                            (d.localPosition.dx / _kZoom).floor(),
                            (d.localPosition.dy / _kZoom).floor(),
                          ),
                          onPanUpdate: (d) {
                            if (_tool == CsTool.paint) {
                              _tapAt(
                                (d.localPosition.dx / _kZoom).floor(),
                                (d.localPosition.dy / _kZoom).floor(),
                              );
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolRow() {
    final items = <(CsTool, String, IconData)>[
      (CsTool.paint, '画', Icons.brush),
      (CsTool.fill, '填格', Icons.format_color_fill),
      (CsTool.eyedrop, '取色', Icons.colorize),
      (CsTool.copy, '复制格', Icons.copy),
      (CsTool.mirrorH, '左右镜像', Icons.swap_horiz),
      (CsTool.mirrorV, '上下镜像', Icons.swap_vert),
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final (tool, label, icon) in items)
          ChoiceChip(
            label: Text(label, style: const TextStyle(fontSize: 11)),
            avatar: Icon(icon, size: 14),
            selected: _tool == tool,
            visualDensity: VisualDensity.compact,
            onSelected: (_) {
              setState(() {
                _tool = tool;
                if (tool != CsTool.copy) _copyFromTile = null;
              });
            },
          ),
        PopupMenuButton<int>(
          tooltip: '预览上色（调色板组）',
          icon: const Icon(Icons.palette, size: 18),
          onSelected: (v) => setState(() => _group = v),
          itemBuilder: (_) {
            final pals = _palettes;
            return [
              const PopupMenuItem(
                  value: -1, child: Text('索引灰度（看砖块结构）')),
              for (var g = 0; g < 16; g++)
                PopupMenuItem(
                  value: g,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: Container(
                          color: pals != null
                              ? Color(pals[g].color(3))
                              : const Color(0xFF888888),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('组 $g${g == _dominantGroup() ? '（最常用）' : ''}'),
                    ],
                  ),
                ),
            ];
          },
        ),
      ],
    );
  }

  Widget _swatchRow() {
    final pals = _palettes;
    final colors = <Color>[
      for (var i = 0; i < 16; i++)
        if (_group >= 0 && pals != null)
          Color(_palettes![_group].color(i))
        else
          Color.fromARGB(0xFF, i * 16, i * 16, i * 16),
    ];
    return Wrap(
      spacing: 4,
      children: [
        const Padding(
          padding: EdgeInsets.only(right: 4),
          child: Text('色', style: TextStyle(fontSize: 11)),
        ),
        for (var i = 0; i < 16; i++)
          ChoiceChip(
            label: Text('$i', style: const TextStyle(fontSize: 10)),
            avatar: SizedBox(
              width: 14,
              height: 14,
              child: i == 0
                  ? const Icon(Icons.remove, size: 14)
                  : Container(color: colors[i]),
            ),
            selected: _color == i,
            visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
            onSelected: (_) => setState(() {
              _color = i;
              _copyFromTile = null;
            }),
          ),
      ],
    );
  }
}

class _GridPainter extends CustomPainter {
  final int? lastTile;
  final int? copyFrom;
  final int contentHeight;

  _GridPainter(this.lastTile, this.copyFrom, this.contentHeight);

  @override
  void paint(Canvas canvas, Size size) {
    final cell = 8.0 * _kZoom;
    final grid = Paint()
      ..color = Colors.black.withValues(alpha: 0.08)
      ..strokeWidth = 0.5;
    final maxX = MapReader.chipWidth.toDouble() * _kZoom;
    for (var x = 0.0; x <= maxX; x += cell) {
      canvas.drawLine(Offset(x, 0), Offset(x, contentHeight.toDouble()),
          grid);
    }
    for (var y = 0.0; y <= contentHeight; y += cell) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    void frame(int? tile, Color color) {
      if (tile == null) return;
      final tx = tile % 32;
      final ty = tile ~/ 32;
      final p = Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(tx * cell, ty * cell, cell, cell),
            const Radius.circular(2)),
        p,
      );
    }

    frame(copyFrom, Colors.orange);
    frame(lastTile, Colors.blueAccent);
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.lastTile != lastTile || old.copyFrom != copyFrom;
}
