import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/chapter_dialog_io.dart';
import '../core/chapter_dialogs.dart';
import 'chapter_preview_page.dart';
import 'dialog_script_page.dart';
import 'event_editor_page.dart';
import '../core/chapter_events.dart';
import '../core/fe_rom.dart';
import '../core/chapter_traps.dart';
import '../core/chest_shop.dart';
import '../core/editable_rom.dart';
import '../core/file_picker_service.dart';
import '../core/map_reader.dart';
import '../core/map_sprite_image.dart';
import '../core/tile_image.dart';
import '../core/unit_placement.dart';
import 'add_reinforcement_dialog.dart';
import 'disasm_page.dart';
import 'item_picker_dialog.dart';
import 'map_chipset_editor_page.dart';
import 'map_image_cache.dart';
import 'map_tile_editor_page.dart';
import 'text_edit_dialog.dart';
import 'unit_placement_page.dart' show PlacedUnitEditPage;

import '../core/text_writer.dart';

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

  late final ChapterEvents _events = ChapterEvents(widget.edit.rom)
    ..itemNameOf = (id) => widget.edit.liveRom.itemDisplayName(id);
  late final ChestShop _chestShop = ChestShop(widget.edit);

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

  /// 当前章节事件脚本引用的对话（文本 ID，去重后按出现顺序）。
  List<ChapterDialogue> _dialogRows = const [];
  int _dialogsChapter = -1;

  List<ChapterDialogue> get _currentDialogues {
    if (_dialogsChapter != _chapter) {
      _dialogsChapter = _chapter;
      _dialogRows = ChapterDialogues.of(widget.edit, _chapter).dialogues;
    }
    return _dialogRows;
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
    final title = _units.chapterTitle(_chapter);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          map == null ? '章节单位' : '第 $_chapter 章${title.isEmpty ? '' : '「$title」'}',
        ),
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
                child: _buildChapterChip(ctx, i, selected),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 章节选择 chip：序号 + 游戏内章节标题（与标题卡副标题一致，方便跟游戏对齐）。
  Widget _buildChapterChip(BuildContext ctx, int i, bool selected) {
    final title = _units.chapterTitle(i);
    final style = TextStyle(
      fontSize: 14,
      fontWeight: selected ? FontWeight.bold : FontWeight.normal,
      color: selected
          ? Theme.of(ctx).colorScheme.onPrimaryContainer
          : null,
    );
    return title.isEmpty
        ? Text('$i', style: style)
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$i', style: style),
              Text(
                title,
                style: TextStyle(
                  fontSize: 9,
                  color: selected
                      ? Theme.of(ctx).colorScheme.onPrimaryContainer
                      : Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
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
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '预览（对话时间线 / 事件触发）',
            icon: const Icon(Icons.visibility_outlined, size: 18),
            onPressed: _openPreviewPage,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '编辑地形砖块',
            icon: const Icon(Icons.edit_location_alt, size: 18),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MapTileEditorPage(
                  edit: widget.edit,
                  chapter: _chapter,
                ),
              ),
            ).then((_) {
              MapImageCache.instance.clear();
              setState(() {
                _mapImage = null;
                _mapImageChapter = -1;
              });
            }),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '编辑砖块图形（TSA 图形，改地形长什么样）',
            icon: const Icon(Icons.texture, size: 18),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MapChipsetEditorPage(
                  edit: widget.edit,
                  chapter: _chapter,
                ),
              ),
            ).then((_) {
              MapImageCache.instance.clear();
              setState(() {
                _mapImage = null;
                _mapImageChapter = -1;
              });
            }),
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
            tooltip: '事件编辑（追加触发事件）',
            icon: const Icon(Icons.bolt_outlined, size: 18),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => EventEditorPage(
                  edit: widget.edit,
                  chapter: _chapter,
                  chapterTitle: _units.chapterTitle(_chapter),
                ),
              ),
            ).then((_) => setState(() {})),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '添加剧情增援（第 N 回合生成单位）',
            icon: const Icon(Icons.person_add_alt, size: 18),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AddReinforcementDialog(
                edit: widget.edit,
                chapter: _chapter,
              ),
            ).then((_) => setState(() {})),
          ),
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
                future: MapImageCache.instance.load(
                  MapImageCache.instance.keyFor(
                      widget.edit.rom.fingerprint, _chapter, 0),
                  img,
                ),
                builder: (ctx, snap) {
                  if (!snap.hasData) {
                    // 解码未完成的占位用**静态**控件。
                    // 不用 CircularProgressIndicator：无限圆环是周期性动画，
                    // 会永久调度帧——widget 测试里 `decodeImageFromPixels`
                    // 的回调永不触发，spinner 就永远转，`pumpAndSettle` 挂死。
                    return Center(
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(3),
                        ),
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
    // 格子里存的是砖块值（渲染时按 `~/4` 查 TSA），不是地形 ID；
    // 直接拿去查地形名表只会拿到「地形 0xNN」这类无效值。
    final text = s == null
        ? '${map.width}×${map.height} 格 · 点地图查看格子与站位单位'
        : '(${s.x}, ${s.y}) · 砖块 '
            '0x${map.tileAt(s.x, s.y).toRadixString(16).toUpperCase()}'
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
        _dialogBar(),
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

  /// 宝箱行标题：奖励道具名从**实时 buffer** 重读（事件行的 condition 文本
  /// 在缓存里是按原快照生成的，改完奖励后不重读会一直显示旧道具）。
  String _chestTitle(ChapterEvent e) {
    final x = e.value & 0xFF;
    final y = (e.value >> 8) & 0xFF;
    final item = _chestShop.chestItemNow(e);
    final name = widget.edit.liveRom.itemDisplayName(item).trim();
    return '开宝箱 ($x, $y)（得到 ${name.isEmpty ? '道具 $item' : name}）';
  }

  /// 改完宝箱奖励：关掉当前底表重开（condition 文本是读时生成的）。
  void _refreshEventSheet(BuildContext sheetCtx) {
    Navigator.pop(sheetCtx);
    _eventsChapter = -1;
    setState(() {});
    if (mounted) _showEventSheet(_currentEvents);
  }

  /// 宝箱行尾的「改奖励」入口。
  Widget _chestAction(BuildContext ctx, ChapterEvent e) {
    final cs = _chestShop;
    final item = cs.chestItemNow(e);
    final name = widget.edit.liveRom.itemDisplayName(item).trim();
    return InkWell(
      onTap: () async {
        final picked = await showDialog<int>(
          context: ctx,
          builder: (dctx) => ItemPickerDialog(
            count: widget.edit.rom.itemCount,
            current: item,
            nameOf: (id) => widget.edit.liveRom.itemDisplayName(id),
            title: '改宝箱奖励',
          ),
        );
        if (picked == null) return;
        final n = cs.setChestItem(e, picked);
        if (n < 0 || n == 0) return;
        _refreshEventSheet(ctx);
      },
      child: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.confirmation_number_outlined,
                size: 13, color: Theme.of(ctx).colorScheme.primary),
            const SizedBox(width: 3),
            Text(
              '改奖励（现为：${name.isEmpty ? '道具 $item' : name}）',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(ctx).colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 商店行尾的「换品」入口：只能**原地替换**已有槽位（列表在 ROM 里
  /// 挨着排布，扩容会顶进下一张列表，所以不做增删）。
  Widget _shopAction(BuildContext ctx, ChapterEvent e) {
    final items = _chestShop.shopItemsOf(e);
    if (items.isEmpty) return const SizedBox.shrink();
    return InkWell(
      onTap: () => _editShopList(ctx, e, items),
      child: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.storefront, size: 13,
                color: Theme.of(ctx).colorScheme.primary),
            const SizedBox(width: 3),
            Text(
              '商店 ${items.length} 件 · 点换品',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(ctx).colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _editShopList(BuildContext ctx, ChapterEvent e, List<int> items) {
    final cs = _chestShop;
    final live = widget.edit.liveRom;
    showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      builder: (sctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        builder: (sctx, controller) => ListView(
          controller: controller,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                '本店出售（点某行换掉那件；只替换、不增删——'
                '列表在 ROM 里挨着排，扩容会改坏别的商店）',
                style:
                    TextStyle(fontSize: 12, color: Colors.blueGrey.shade700),
              ),
            ),
            for (var i = 0; i < items.length; i++)
              ListTile(
                dense: true,
                leading: Text('${i + 1}',
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                title: Text(
                  live.itemDisplayName(items[i]).trim().isEmpty
                      ? '（未命名）'
                      : live.itemDisplayName(items[i]).trim(),
                ),
                trailing: Text('${items[i]}',
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                onTap: () async {
                  Navigator.pop(sctx);
                  final picked = await showDialog<int>(
                    context: context,
                    builder: (dctx) => ItemPickerDialog(
                      count: widget.edit.rom.itemCount,
                      current: items[i],
                      nameOf: (id) => live.itemDisplayName(id),
                      title: '换掉第 ${i + 1} 格',
                    ),
                  );
                  if (picked == null || picked == items[i]) {
                    setState(() {});
                    return;
                  }
                  final n = cs.setShopItem(e, i, picked);
                  if (n < 0) return;
                  _eventsChapter = -1;
                  setState(() {});
                },
              ),
          ],
        ),
      ),
    );
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
                  final cs = _chestShop;
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
                      cs.isChest(r.event) ? _chestTitle(r.event) : r.event.condition,
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
                        if (cs.isChest(r.event)) _chestAction(ctx, r.event),
                        if (cs.isShop(r.event)) _shopAction(ctx, r.event),
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

  /// 对话入口条：点开看本章事件脚本引用的对话文本（可编辑）。
  Widget _dialogBar() {
    final rows = _currentDialogues;
    final supported = TextWriter(widget.edit).supported;
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: () => _showDialogSheet(rows),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.chat_bubble_outline, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '本章对话 ${rows.length} 条（点条目直接编辑）',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // 整章批量导入/导出（#define 风格文本，对大量改剧情的人最实用）
        TextButton.icon(
          onPressed: supported ? () => _exportChapterDialogs() : null,
          icon: const Icon(Icons.file_download_outlined, size: 14),
          label: const Text('导出', style: TextStyle(fontSize: 12)),
        ),
        TextButton.icon(
          onPressed: supported ? () => _importChapterDialogs() : null,
          icon: const Icon(Icons.file_upload_outlined, size: 14),
          label: const Text('导入', style: TextStyle(fontSize: 12)),
        ),
        // 场景化编辑：按「一场戏 → 一句一句」读，比按 ID 点更接近写剧情
        TextButton.icon(
          onPressed: rows.isEmpty ? null : _openScriptPage,
          icon: const Icon(Icons.article_outlined, size: 16),
          label: const Text('按场景编辑', style: TextStyle(fontSize: 12)),
        ),
        const Icon(Icons.chevron_right, size: 18),
      ],
    );
  }

  /// 把本章引用的对话导出成 #define 风格文本（系统「另存为」落盘）。
  Future<void> _exportChapterDialogs() async {
    final text = ChapterDialogIO.exportChapter(widget.edit, _chapter);
    if (text == null) {
      _snackbar('该 ROM 文本引擎不可写，无法导出');
      return;
    }
    final saved = await saveFile(
        'chapter${_chapter}_dialog.txt',
        Uint8List.fromList(utf8.encode(text)));
    _snackbar(saved == null ? '已取消' : '已导出 ${saved.split('/').last}');
  }

  /// 导入一份 #define 对话补丁：选文件 → 逐条写回（同一写回通道、可整体撤销）
  /// → 弹窗报告写了几条、跳了几条。
  Future<void> _importChapterDialogs() async {
    final text = await pickTextFile();
    if (text == null) return; // 取消选择
    final result = ChapterDialogIO.importDialogs(widget.edit, text);
    if (!mounted) return;
    setState(() {}); // 对话列表内容可能已变，刷新预读
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(result.allOk ? '对话补丁已应用' : '对话补丁应用（有问题）'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(result.summary, style: const TextStyle(fontSize: 13)),
              if (result.problems.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  result.problems.take(12).join('\n'),
                  style: TextStyle(
                      fontSize: 11, color: Colors.orange.shade800, height: 1.5),
                ),
                if (result.problems.length > 12)
                  Text('… 另有 ${result.problems.length - 12} 条未列出',
                      style: TextStyle(fontSize: 11, color: Colors.orange.shade800)),
              ],
              const SizedBox(height: 8),
              Text('全部改动都记在编辑记录里，顶栏「撤销全部修改」可一键还原。',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _snackbar(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _openPreviewPage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChapterPreviewPage(
          edit: widget.edit,
          chapter: _chapter,
          chapterTitle: _units.chapterTitle(_chapter),
        ),
      ),
    ).then((_) => setState(() {}));
  }

  void _openScriptPage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DialogScriptPage(
          edit: widget.edit,
          chapter: _chapter,
          chapterTitle: _units.chapterTitle(_chapter),
        ),
      ),
    ).then((_) => setState(() {}));
  }

  void _showDialogSheet(List<ChapterDialogue> rows) {
    final writer = TextWriter(widget.edit);
    final title = _units.chapterTitle(_chapter);
    final titleLine = title.isEmpty
        ? '本工具章节号是 0 基（游戏内第一章通常就是第 0 章）。'
        : '本章游戏内标题「$title」（与游戏标题卡副标题一致）。本工具章节号 0 基，游戏内第一章通常对应第 0 章。';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (ctx, controller) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Text(titleLine, style: const TextStyle(fontSize: 11)),
            ),
            Expanded(
              child: rows.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          '本章事件脚本里没有引用到对话文本。\n'
                              '对话由事件脚本按文本 ID 引用；\n本章没有引用时这里是空的（不等于游戏里没有文本）。',
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
                  final d = rows[i];
                  // 与编辑框一致的预填文本（控制码以〔XX〕占位），
                  // 引擎不可写时退回只读解码
                  final preview = writer.currentText(d.textId) ??
                      widget.edit.rom.decodeText(d.textId);
                  return ListTile(
                    dense: true,
                    onTap: () {
                      // 编辑框叠在面板上（不关掉列表，方便连续改多条）
                      showTextEditDialog(
                        ctx,
                        edit: widget.edit,
                        textId: d.textId,
                        title: '本章对话 #${d.textId}',
                      );
                    },
                    leading: Chip(
                      label: Text(
                        '#${d.textId}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    title: Text(
                      preview.replaceAll('\n', '⏎').length > 40
                          ? '${preview.replaceAll('\n', '⏎').substring(0, 40)}…'
                          : preview.replaceAll('\n', '⏎'),
                      style: const TextStyle(fontSize: 12, height: 1.4),
                    ),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                  );
                },
              ),
            ),
          ],
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
