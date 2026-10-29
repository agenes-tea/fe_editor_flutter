import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/chapter_events.dart';
import '../core/fe_rom.dart';
import '../core/chapter_traps.dart';
import '../core/editable_rom.dart';
import '../core/map_reader.dart';
import '../core/map_sprite_image.dart';
import '../core/tile_image.dart';
import '../core/unit_placement.dart';
import 'disasm_page.dart';
import 'unit_placement_page.dart' show PlacedUnitEditPage;

/// 「章节」页：把原来的「关卡地图」和「章节单位」合成一处。
///
/// 一个章节一屏看完——上面是地图（按真实地图小人叠加单位），
/// 下面是本章的单位列表，点地图上的小人或列表条目都能进编辑。
/// 这样不用在两个页面之间来回对照坐标。
class ChapterPage extends StatefulWidget {
  final EditableRom edit;

  /// 初始章节（从主页「章节单位」进来时保持一致）。
  final int initialChapter;

  const ChapterPage({super.key, required this.edit, this.initialChapter = 0});

  @override
  State<ChapterPage> createState() => _ChapterPageState();
}

class _ChapterPageState extends State<ChapterPage> {
  late final MapReader _map = MapReader(widget.edit.rom);
  late final UnitPlacement _units = UnitPlacement(widget.edit);
  late final UnitSpriteProvider _sprites = UnitSpriteProvider(widget.edit.rom);

  late int _chapter = widget.initialChapter;
  bool _showUnits = true;
  bool _showTraps = true;
  ({int x, int y})? _selected;

  /// 当前叠加显示的单位槽（None 表示「全部可用槽」）。
  UnitSlot? _slotFilter;

  /// 地图渲染结果的缓存（换章节/换缩放时重建，避免每帧重解 LZ77）。
  TileImage? _mapImage;
  int _mapImageChapter = -1;

  /// 当前章节的陷阱（懒计算，随章节切换重建）。
  List<ChapterTrap> _traps = const [];
  int _trapsChapter = -1;

  late final ChapterEvents _events = ChapterEvents(widget.edit.rom);

  /// 当前章节的事件（触发条件 + 增援单位），随章节切换重建。
  List<({ChapterEvent event, List<LoadedUnit> units})> _eventRows = const [];
  int _eventsChapter = -1;

  List<({ChapterEvent event, List<LoadedUnit> units})> get _currentEvents {
    if (_eventsChapter != _chapter) {
      _eventsChapter = _chapter;
      final ev = _units.eventGroupOffset(_chapter);
      if (ev <= 0) {
        _eventRows = const [];
      } else {
        _eventRows = [
          for (final e in _events.all(ev))
            (event: e, units: _events.loadedUnits(e.script)),
        ];
      }
    }
    return _eventRows;
  }

  List<ChapterTrap> get _currentTraps {
    if (_trapsChapter != _chapter) {
      final t = ChapterTraps(widget.edit);
      _trapsChapter = _chapter;
      _traps = t.supported
          ? [...t.traps(_chapter), ...t.hardTraps(_chapter)]
          : const [];
    }
    return _traps;
  }

  @override
  void initState() {
    super.initState();
    _MapImageCache.instance.bindRom(widget.edit.rom.fingerprint);
    MapSpriteImageCache.instance.bindRom(widget.edit.rom.fingerprint);
  }

  @override
  void dispose() {
    _sprites.dispose();
    super.dispose();
  }

  int get _chapterCount =>
      _map.available ? _map.chapterCount : _units.chapterCount;

  /// 当前选中的单位入口（不支持的入口回退到默认）。
  UnitSlot get _currentSlot {
    final slot = _slotFilter ?? _units.defaultSlot;
    return _units.slotSupported(slot) ? slot : _units.defaultSlot;
  }

  /// 该章要列出的静态单位：当前选中入口（默认我方普通，FE6 为蓝方）。
  /// 敌方/友方单位只在对应入口下展示（遭遇槽仅 FE8、红/蓝仅 FE6）。
  List<PlacedUnit> get _visibleUnits => _units.units(_chapter, _currentSlot);

  /// 事件脚本生成的单位（只读），按单位地址去重。
  ///
  /// 同一组增援常被多个回合事件引用（烈火第 25 章 196 条原始记录只有 18 人）。
  /// **不按入口过滤阵营**：烈火/圣魔没有「敌军」静态入口，过滤掉就什么也看不到；
  /// 行内已经标了「我方/友军/敌方」，混合展示反而能看出本章到底会出场哪些人。
  List<LoadedUnit> get _dynamicUnits {
    // 遭遇战 6 槽是「遭遇战配置」，不是本章出场名单，不并事件单位。
    if (_currentSlot.isEncounter) return const [];
    final seen = <int>{};
    final out = <LoadedUnit>[];
    for (final row in _currentEvents) {
      for (final u in row.units) {
        if (seen.add(u.addr)) out.add(u);
      }
    }
    return out;
  }

  /// 列表行：静态单位（可改）+ 事件动态单位（只读，标来源）。
  ///
  /// 同一角色同坐标的事件单位会跳过——FE6/FE7 的开场单位也由事件脚本加载，
  /// 与静态表里的是同一批人（烈火第 0 章琳在 (14,9) 两边都有）。
  List<_UnitRow> get _unitRows {
    final statics = _visibleUnits;
    final rows = [for (final u in statics) _UnitRow.placed(u)];
    for (final d in _dynamicUnits) {
      final dup = statics
          .any((s) => s.charId == d.charId && s.x == d.x && s.y == d.y);
      if (!dup) rows.add(_UnitRow.loaded(d));
    }
    return rows;
  }

  /// 地图上叠加的单位：与列表同一个入口，保证「地图上看到的 = 列表里列的」。
  List<PlacedUnit> get _overlayUnits => _visibleUnits;

  TileImage? get _image {
    if (_mapImageChapter == _chapter && _mapImage != null) return _mapImage;
    _mapImage = _map.available ? _map.renderMap(_chapter) : null;
    _mapImageChapter = _chapter;
    return _mapImage;
  }

  void _selectChapter(int ch) {
    setState(() {
      _chapter = ch;
      _selected = null;
      _mapImage = null;
      _mapImageChapter = -1;
      _trapsChapter = -1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final map = _map.available ? _map.chapterMap(_chapter) : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(map == null ? '章节单位' : '第 $_chapter 章'),
        actions: [
          if (widget.edit.hasChanges)
            IconButton(
              tooltip: '撤销全部修改',
              icon: const Icon(Icons.undo),
              onPressed: () => setState(widget.edit.revertAll),
            ),
        ],
      ),
      body: Column(
        children: [
          _chapterSelector(),
          if (map != null) ...[
            _mapToolbar(map),
            _mapArea(map),
            _selectionInfo(map),
          ],
          const Divider(height: 1),
          Expanded(child: _unitList()),
        ],
      ),
    );
  }

  /// 章节选择：横向滚动的紧凑按钮，比原来 48px 高的 Chip 更省纵向空间。
  Widget _chapterSelector() {
    final n = _chapterCount;
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        itemCount: n,
        itemBuilder: (ctx, i) {
          final selected = _chapter == i;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _selectChapter(i),
              child: Container(
                constraints: const BoxConstraints(minWidth: 56),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected
                      ? Theme.of(context).colorScheme.primaryContainer
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$i',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    color: selected
                        ? Theme.of(context).colorScheme.onPrimaryContainer
                        : null,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _mapToolbar(ChapterMap map) {
    final overlayCount = _overlayUnits.length;
    final traps = _currentTraps;
    final trapHint = ChapterTraps(widget.edit);
    final trapCountText = trapCount(traps.length, trapHint);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Row(
        children: [
          // 用紧凑的图标切换，避免 Switch 在窄屏上挤压文字
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: _showUnits ? '隐藏单位' : '显示单位',
            icon: Icon(_showUnits ? Icons.visibility : Icons.visibility_off),
            onPressed: () => setState(() => _showUnits = !_showUnits),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: _trapTooltip(trapHint, traps),
            icon: Icon(
              _showTraps ? Icons.warning_amber : Icons.warning_amber_outlined,
              size: 18,
              color: _showTraps ? null : Colors.grey,
            ),
            onPressed: () => setState(() => _showTraps = !_showTraps),
          ),
          Flexible(
            child: Text(
              '${map.width}×${map.height} 格 · 单位 $overlayCount 个'
              ' · $trapCountText',
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Spacer(),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '放大',
            icon: const Icon(Icons.zoom_in),
            onPressed: () => _zoomBy(1.5),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '缩小',
            icon: const Icon(Icons.zoom_out),
            onPressed: () => _zoomBy(1 / 1.5),
          ),
        ],
      ),
    );
  }

  /// 当前缩放；`null` 表示「自适应」——让地图恰好铺满可用宽度。
  double? _scale;
  static const double _minScale = 1.0;

  Widget _mapArea(ChapterMap map) {
    return SizedBox(
      height: _mapViewportHeight,
      child: LayoutBuilder(
        builder: (ctx, box) {
          final fitScale = box.maxWidth / (map.width * 16);
          final useScale = _scale ?? fitScale;
          return InteractiveViewer(
            maxScale: 4,
            child: Center(
              child: _mapStack(map, useScale),
            ),
          );
        },
      ),
    );
  }

  /// 以「当前实际显示的缩放」为基准缩放（自适应态下先算出铺满宽度时的倍率）。
  void _zoomBy(double factor) {
    final map = _map.available ? _map.chapterMap(_chapter) : null;
    if (map == null) return;
    final area = MediaQuery.of(context).size.width;
    final base = _scale ?? (area / (map.width * 16));
    setState(() => _scale = (base * factor).clamp(_minScale, 6.0));
  }

  /// 地图区高度：占屏幕约 45%，最高 340px，保证下方单位列表可见。
  double get _mapViewportHeight {
    final h = MediaQuery.of(context).size.height;
    return (h * 0.45).clamp(180.0, 340.0);
  }

  Widget _mapStack(ChapterMap map, double scale) {
    final img = _image;
    final w = map.width * 16 * scale;
    final h = map.height * 16 * scale;
    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (img != null)
            Positioned.fill(
              child: FutureBuilder<ui.Image>(
                future: _MapImageCache.instance.load(
                  _MapImageCache.instance.keyFor(_chapter, 0),
                  img,
                ),
                builder: (ctx, snap) {
                  if (!snap.hasData) {
                    return const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }
                  return RawImage(
                    image: snap.data,
                    filterQuality: FilterQuality.none,
                    fit: BoxFit.fill,
                  );
                },
              ),
            ),
          // 点选层：像素 → 格子坐标
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                final x = (d.localPosition.dx / (16 * scale)).floor();
                final y = (d.localPosition.dy / (16 * scale)).floor();
                if (x < 0 || y < 0 || x >= map.width || y >= map.height) return;
                setState(() => _selected = (x: x, y: y));
              },
            ),
          ),
          if (_showUnits)
            for (final u in _overlayUnits) _unitMarker(u, map, scale),
          if (_showTraps)
            for (final t in _currentTraps) _trapMarker(t, map, scale),
          if (_selected != null) _selectionMarker(scale),
        ],
      ),
    );
  }

  String _trapTooltip(ChapterTraps hint, List<ChapterTrap> traps) {
    if (hint.supported) {
      return traps.isEmpty ? '该章没有陷阱' : '隐藏陷阱（${traps.length} 个）';
    }
    if (!hint.hasSlot) return '本版本没有静态陷阱槽';
    return hint.chapterHasTraps(_chapter)
        ? '该章有陷阱数据，但本版本记录结构未验证，不画标记'
        : '该章没有陷阱';
  }

  String trapCount(int n, ChapterTraps hint) {
    if (n > 0) return '陷阱 $n';
    if (hint.hasSlot && !hint.supported && hint.chapterHasTraps(_chapter)) {
      return '有陷阱（未解码）';
    }
    return '陷阱 0';
  }

  /// 陷阱标记：格中心的琥珀色菱形；越界的只计数量不画。
  Widget _trapMarker(ChapterTrap t, ChapterMap map, double scale) {
    if (t.x < 0 || t.y < 0 || t.x >= map.width || t.y >= map.height) {
      return const SizedBox.shrink();
    }
    final cell = 16 * scale;
    return Positioned(
      left: t.x * cell + cell * 0.25,
      top: t.y * cell + cell * 0.25,
      child: IgnorePointer(
        child: Transform.rotate(
          angle: 3.14159 / 4,
          child: Container(
            width: cell * 0.5,
            height: cell * 0.5,
            decoration: BoxDecoration(
              color: Colors.amber.shade900.withValues(alpha: 0.9),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.8),
                width: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 一格地图对应的小人：优先画真实地图小人（与游戏内一致），
  /// 取不到时回退成阵营色块。调色板组随单位阵营（自军/敌军/友军）。
  Widget _unitMarker(PlacedUnit u, ChapterMap map, double scale) {
    if (u.x < 0 || u.y < 0 || u.x >= map.width || u.y >= map.height) {
      return const SizedBox.shrink();
    }
    final cell = 16 * scale;
    // 调色板组：0=自军 1=敌军 2=友军（灰色组不用于单位）。
    final group = u.allegiance == Allegiance.ally
        ? 2
        : u.allegiance == Allegiance.enemy
            ? 1
            : 0;
    final color = switch (u.allegiance) {
      Allegiance.player => Colors.blue,
      Allegiance.enemy => Colors.red,
      Allegiance.ally => Colors.green,
    };
    final (fw, fh) = _sprites.frameSize(u.classId);
    final spriteW = fw * scale;
    final spriteH = fh * scale;

    final future = _sprites.imageFor(u.classId, group);
    final ready = _sprites.cached(u.classId, group);
    final fallback = Container(
      width: cell * 0.7,
      height: cell * 0.7,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(cell * 0.15),
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.9), width: 1),
      ),
    );

    // 用 CustomPaint 而不是 RawImage：
    // RawImage 会把整幅位图（含透明区）铺进布局框，透明像素的 RGB 是无效值，
    // 某些合成路径下会露出白/黑块——这就是「小人带白底方块」的根因。
    // 这里只画不透明像素，透明区完全不着色。
    return Positioned(
      // 小人以格子为中心：16×32 / 32×32 的图形向上对齐，脚落在格子上
      left: u.x * cell + (cell - spriteW) / 2,
      top: (u.y + 1) * cell - spriteH,
      child: IgnorePointer(
        child: SizedBox(
          width: spriteW,
          height: spriteH,
          child: ready != null
              ? CustomPaint(painter: _SpritePainter(ready))
              : future == null
                  ? Center(child: fallback)
                  : FutureBuilder<ui.Image>(
                      future: future,
                      builder: (ctx, snap) {
                        if (!snap.hasData) {
                          return Center(child: fallback);
                        }
                        return CustomPaint(painter: _SpritePainter(snap.data!));
                      },
                    ),
        ),
      ),
    );
  }

  Widget _selectionMarker(double scale) {
    final s = _selected!;
    return Positioned(
      left: s.x * 16 * scale,
      top: s.y * 16 * scale,
      child: IgnorePointer(
        child: Container(
          width: 16 * scale,
          height: 16 * scale,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.amber, width: 2),
          ),
        ),
      ),
    );
  }

  Widget _selectionInfo(ChapterMap map) {
    final s = _selected;
    final at = s == null
        ? const <PlacedUnit>[]
        : _overlayUnits.where((u) => u.x == s.x && u.y == s.y).toList();
    final rom = widget.edit.rom;
    final text = s == null
        ? '${map.width}×${map.height} 格 · 点地图查看格子与地形'
        : '(${s.x}, ${s.y}) · ${_map.terrainName(map.tileAt(s.x, s.y))}'
            '${at.isEmpty ? '' : ' · ${at.map((u) => rom.unitDisplayName(u.unitIndex)).join(' / ')}'}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Text(text, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _unitList() {
    final rows = _unitRows;
    return Column(
      children: [
        _slotBar(),
        _eventBar(),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _units.emptyHint(_currentSlot),
                      textAlign: TextAlign.center,
                      style: const TextStyle(height: 1.6, color: Colors.grey),
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final row = rows[i];
                    final placed = row.placed;
                    return placed != null
                        ? _unitTile(placed)
                        : _dynamicUnitTile(row.loaded!);
                  },
                ),
        ),
      ],
    );
  }

  /// 剧情增援里常见的阵营标记：蓝方我方 / 绿方友军 / 红方敌方。
  static String _factionLabel(int allegiance) => switch (allegiance) {
        0 => '我方',
        1 => '友军',
        2 => '敌方',
        _ => '其他',
      };

  /// 一个增援单位的简短标签。
  ///
  /// 坐标落在地图外的不丢弃，而是标「图外」：实测 FE7 的章节事件组里会引用
  /// 共用的「进入下一章」脚本，里面的单位属于下一张图（如第 3 章读到
  /// 第 4 章的 y=13，而第 3 章地图高 10）。
  String _unitLabel(LoadedUnit u, ChapterMap? mapInfo) {
    final outside = mapInfo != null &&
        (u.x >= mapInfo.width || u.y >= mapInfo.height);
    return '${widget.edit.rom.unitDisplayName(u.unitIndex).trim()}'
        '(${u.x},${u.y} ${_factionLabel(u.allegiance)} Lv${u.level}'
        '${outside ? ' 图外' : ''})';
  }

  /// 事件入口条：点开看本章的触发条件与剧情增援。
  Widget _eventBar() {
    final rows = _currentEvents;
    // 同一个增援数组常被多个回合事件引用（实测 FE7 第 25 章 196 条原始记录
    // 只有 18 个不同单位），按单位地址去重才是真实人数。
    final loaded = rows
        .expand((r) => r.units)
        .map((u) => u.addr)
        .toSet()
        .length;
    return InkWell(
      onTap: () => _showEventSheet(rows),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.bolt_outlined, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '事件 ${rows.length} 个 · 剧情增援 $loaded 人',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const Icon(Icons.chevron_right, size: 18),
          ],
        ),
      ),
    );
  }

  void _showEventSheet(List<({ChapterEvent event, List<LoadedUnit> units})> rows) {
    final rom = widget.edit.rom;
    final mapInfo = _map.available ? _map.chapterMap(_chapter) : null;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (ctx, controller) => rows.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    '本章没有可读的事件。\n'
                    '敌方配置可能在静态单位表里（上方切「遭遇敌方」等入口），'
                    '或在事件脚本里读不出来的条件下。',
                    textAlign: TextAlign.center,
                    style: TextStyle(height: 1.6, color: Colors.grey),
                  ),
                ),
              )
            : ListView.separated(
                controller: controller,
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final r = rows[i];
                  return ListTile(
                    dense: true,
                    leading: Chip(
                      label: Text(
                        r.event.kind.label,
                        style: const TextStyle(fontSize: 10),
                      ),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    title: Text(
                      r.event.condition,
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.units.isEmpty
                              ? '脚本 0x${r.event.script.toRadixString(16)}（无增援）'
                              : r.units
                                  .map((u) => _unitLabel(u, mapInfo))
                                  .join('、'),
                          style: const TextStyle(fontSize: 11),
                        ),
                        // 事件脚本是 ARM/Thumb 机器码：直接丢给反汇编页看命令流
                        if (r.event.script != 0 &&
                            FeRom.isPointer(r.event.script, rom.length))
                          InkWell(
                            onTap: () => Navigator.push(
                              ctx,
                              MaterialPageRoute(
                                builder: (_) => DisasmPage(
                                  edit: widget.edit,
                                  initialOffset: FeRom.toOffset(r.event.script),
                                ),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.memory,
                                      size: 13,
                                      color: Theme.of(ctx)
                                          .colorScheme
                                          .primary),
                                  const SizedBox(width: 3),
                                  Text(
                                    '反汇编打开',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Theme.of(ctx)
                                          .colorScheme
                                          .primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }

  /// 入口切换：按版本显示可用入口（我方普通/困难、遭遇 6 槽仅 FE8、红/蓝仅 FE6）。
  Widget _slotBar() {
    final slots = UnitSlot.values.where(_units.slotSupported).toList();
    final isFe6 = widget.edit.rom.table.id == 'FE6';
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final slot in slots)
            Padding(
              padding: const EdgeInsets.only(right: 6, top: 4, bottom: 4),
              child: ChoiceChip(
                label: Text(slot.label),
                selected: (_slotFilter ?? _units.defaultSlot) == slot,
                onSelected: (_) => setState(() => _slotFilter = slot),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 10),
            child: Text(
              isFe6
                  ? '（红/蓝为静态表；事件生成的单位也列在下面，标「事件」与阵营）'
                  : '（遭遇槽仅有遭遇战的章节有数据；事件生成的单位也列在下面，标「事件」与阵营）',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _unitTile(PlacedUnit u) {
    final rom = widget.edit.rom;
    final charName = rom.unitDisplayName(u.unitIndex);
    final className = rom.classDisplayName(u.classId);
    const group = 0;
    const color = Colors.blue;
    final future = _sprites.imageFor(u.classId, group);

    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 28,
        height: 28,
        child: future == null
            ? Icon(Icons.person, color: color, size: 22)
            : FutureBuilder<ui.Image>(
                future: future,
                builder: (ctx, snap) {
                  if (!snap.hasData) {
                    return Icon(Icons.person, color: color, size: 22);
                  }
                  return RawImage(
                    image: snap.data,
                    filterQuality: FilterQuality.none,
                    fit: BoxFit.contain,
                  );
                },
              ),
      ),
      title: Text(
        '${charName.isEmpty ? '角色 ${u.charId}' : charName}'
        '${className.isEmpty ? '' : ' · $className'}',
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Text(
        'Lv ${u.level} · (${u.x}, ${u.y})',
        style: const TextStyle(fontSize: 11),
      ),
      trailing: const Icon(Icons.edit, size: 16),
      onTap: () async {
        final changed = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => PlacedUnitEditPage(edit: widget.edit, unit: u),
          ),
        );
        if (changed == true) {
          setState(() {
            _mapImage = null;
            _mapImageChapter = -1;
          });
        }
      },
    );
  }

  /// 事件脚本生成的单位：只读（写回事件脚本未做），来源标「事件」。
  Widget _dynamicUnitTile(LoadedUnit u) {
    final rom = widget.edit.rom;
    final charName = rom.unitDisplayName(u.unitIndex);
    // classId 0 = 用角色默认职业（FE6/FE7 的动态单位常这么写）
    final classId = u.classId == 0
        ? (rom.unitClassId(u.unitIndex) < 0 ? u.classId : rom.unitClassId(u.unitIndex))
        : u.classId;
    final className = classId == 0 ? '' : rom.classDisplayName(classId);
    // 调色板组：0=自军 1=敌军 2=友军
    final group = u.allegiance == 2 ? 1 : (u.allegiance == 1 ? 2 : 0);
    final future = _sprites.imageFor(classId, group);
    final map = _map.available ? _map.chapterMap(_chapter) : null;
    final outside = map != null && (u.x >= map.width || u.y >= map.height);
    final scheme = Theme.of(context).colorScheme;

    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 28,
        height: 28,
        child: future == null
            ? Icon(Icons.person, size: 22, color: scheme.onSurfaceVariant)
            : FutureBuilder<ui.Image>(
                future: future,
                builder: (ctx, snap) {
                  if (!snap.hasData) {
                    return Icon(Icons.person,
                        size: 22, color: scheme.onSurfaceVariant);
                  }
                  return RawImage(
                    image: snap.data,
                    filterQuality: FilterQuality.none,
                    fit: BoxFit.contain,
                  );
                },
              ),
      ),
      title: Text(
        '${charName.isEmpty ? '角色 ${u.charId}' : charName}'
        '${className.isEmpty ? '' : ' · $className'}',
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Text(
        'Lv ${u.level} · (${u.x}, ${u.y}) · ${_factionLabel(u.allegiance)}'
        '${outside ? ' · 图外' : ''}',
        style: const TextStyle(fontSize: 11),
      ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Text(
          '事件',
          style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// 单位列表的一行：静态表里的单位可编辑，事件脚本生成的只读。
class _UnitRow {
  final PlacedUnit? placed;
  final LoadedUnit? loaded;

  const _UnitRow.placed(PlacedUnit this.placed) : loaded = null;
  const _UnitRow.loaded(LoadedUnit this.loaded) : placed = null;
}

/// 地图位图的 `ui.Image` 缓存（照旧，key 含 ROM 指纹）。
class _MapImageCache {
  _MapImageCache._();
  static final _MapImageCache instance = _MapImageCache._();

  final _images = <int, ui.Image>{};
  int _romTag = 0;

  void bindRom(int romTag) {
    if (_romTag == romTag) return;
    _romTag = romTag;
    for (final img in _images.values) {
      img.dispose();
    }
    _images.clear();
  }

  int keyFor(int chapter, int salt) =>
      (_romTag & 0xFFFF) * 0x100000 + chapter * 0x100 + (salt & 0xFF);

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
        if (_images.length >= 24) {
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

/// 把 `ui.Image` 按像素最近邻铺满画布，**跳过全透明像素**。
///
/// 直接用 `RawImage(fit: BoxFit.contain)` 时，透明区域仍会参与合成，
/// 在部分合成路径下表现为小人周围一圈白/黑方块。
class _SpritePainter extends CustomPainter {
  final ui.Image image;
  const _SpritePainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..filterQuality = FilterQuality.none;
    final dx = (size.width - image.width) / 2;
    final dy = (size.height - image.height) / 2;
    canvas.drawImage(image, Offset(dx, dy), paint);
  }

  @override
  bool shouldRepaint(_SpritePainter old) => old.image != image;
}
