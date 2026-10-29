import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/battle_anim.dart';
import '../core/editable_rom.dart';
import '../core/tile_image.dart';
import '../core/file_picker_service.dart';

/// 把 [TileImage] 转成可绘制的 `ui.Image`，按 key 缓存。
///
/// 缓存 key 必须含 ROM 指纹与调色板组：换 ROM 后同样的动画索引与组号
/// 会命中上一份 ROM 的图（肖像页踩过同样的坑）。
class _BattleAnimImageCache {
  _BattleAnimImageCache._();
  static final _BattleAnimImageCache instance = _BattleAnimImageCache._();

  static const int _limit = 48;
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

  int keyFor(int animId, int mode, int frame, int paletteGroup) {
    return (_romTag & 0xFFFF) * 0x1000000 +
        (animId & 0xFFF) * 0x1000 +
        (mode & 0xF) * 0x100 +
        (frame & 0xFF) * 0x4 +
        (paletteGroup & 0x3);
  }

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
    if (_images.length >= _limit) {
      final firstKey = _images.keys.first;
      _images.remove(firstKey)?.dispose();
    }
    _images[key] = img;
    return img;
  }
}

/// 战斗动画列表。
class BattleAnimListPage extends StatefulWidget {
  final EditableRom edit;
  const BattleAnimListPage({super.key, required this.edit});

  @override
  State<BattleAnimListPage> createState() => _BattleAnimListPageState();
}

class _BattleAnimListPageState extends State<BattleAnimListPage> {
  late final BattleAnimReader _reader = BattleAnimReader(widget.edit.rom);
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _BattleAnimImageCache.instance.bindRom(widget.edit.rom.fingerprint);
  }

  @override
  Widget build(BuildContext context) {
    if (!_reader.available) {
      return Scaffold(
        appBar: AppBar(title: const Text('战斗动画')),
        body: const Center(child: Text('这个版本没有战斗动画表')),
      );
    }
    final all = _reader.entries;
    final q = _filter.trim().toLowerCase();
    final list = q.isEmpty
        ? all
        : all.where((e) => e.abbr.toLowerCase().contains(q)).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('战斗动画 (${all.length})'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: '按缩写筛选，如 lorm / sw1 / mg1',
                prefixIconConstraints: BoxConstraints(minWidth: 34),
              ),
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
        ),
      ),
      body: ListView.builder(
        itemCount: list.length,
        itemBuilder: (ctx, i) {
          final e = list[i];
          final modes = _reader.modesOf(e);
          final total = modes.fold<int>(0, (s, m) => s + m.length);
          return ListTile(
            dense: true,
            title: Text(
                '0x${e.id.toRadixString(16).toUpperCase().padLeft(2, '0')}  ${e.abbr}'),
            subtitle: Text('12 个模式 · 共 $total 字节脚本'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => BattleAnimDetailPage(
                    edit: widget.edit,
                    animId: e.id,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// 单条战斗动画：模式、帧、调色板浏览与导出。
class BattleAnimDetailPage extends StatefulWidget {
  final EditableRom edit;
  final int animId;

  const BattleAnimDetailPage({
    super.key,
    required this.edit,
    required this.animId,
  });

  @override
  State<BattleAnimDetailPage> createState() => _BattleAnimDetailPageState();
}

class _BattleAnimDetailPageState extends State<BattleAnimDetailPage> {
  late final BattleAnimReader _reader = BattleAnimReader(widget.edit.rom);
  late final BattleAnimEntry _entry = _reader.entry(widget.animId)!;

  late List<AnimMode> _modes = const [];
  List<AnimFrame> _frames = const [];

  int _modeIndex = 0;
  int _frameIndex = 0;
  int _paletteGroup = 0;

  Timer? _timer;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _modes = _reader.modesOf(_entry);
    _selectMode(_firstPlayableMode());
  }

  /// 跳过索引 1、3（武器图层）：它们单独看只有武器碎片，已由模式 0、2 合绘。
  int _firstPlayableMode() {
    for (final m in _modes) {
      if (!BattleAnimReader.isWeaponLayer(m.index)) return m.index;
    }
    return _modes.isEmpty ? 0 : _modes.first.index;
  }

  void _selectMode(int index) {
    final m =
        _modes.firstWhere((x) => x.index == index, orElse: () => _modes.first);
    _modeIndex = m.index;
    _frames = _reader.framesOf(_entry, m);
    _frameIndex = 0;
    _stop();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _playing = false;
  }

  void _togglePlay() {
    if (_frames.isEmpty) return;
    if (_playing) {
      setState(_stop);
      return;
    }
    setState(() => _playing = true);
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (!_playing || _frames.isEmpty) return;
    final cur = _frames[_frameIndex.clamp(0, _frames.length - 1)];
    // 等待时长以 1/60 秒计；夹紧到 60~1200ms，避免 0 帧疯狂重绘
    final ms = (cur.wait * 1000 ~/ 60).clamp(60, 1200);
    _timer = Timer(Duration(milliseconds: ms), () {
      if (!mounted || !_playing) return;
      setState(() {
        _frameIndex = (_frameIndex + 1) % _frames.length;
      });
      _schedule();
    });
  }

  TileImage? get _currentFrame {
    if (_frames.isEmpty) return null;
    final m = _modes.firstWhere((x) => x.index == _modeIndex,
        orElse: () => _modes.first);
    return _reader.renderFrame(_entry, m, _frameIndex,
        paletteGroup: _paletteGroup);
  }

  Future<void> _exportFrame() async {
    final img = _currentFrame;
    if (img == null) return;
    final name = 'banim_${_entry.abbr}_m${_modeIndex}_f$_frameIndex'
        '_p$_paletteGroup.png';
    final saved = await saveFile(name, encodePng(img));
    if (!mounted) return;
    _toast(saved == null ? '已取消' : '已保存 $name');
  }

  Future<void> _exportSheet() async {
    if (_frames.isEmpty) return;
    final frame = _frames[_frameIndex.clamp(0, _frames.length - 1)];
    final palette = _reader.paletteOf(_entry, _paletteGroup);
    if (palette == null) return;
    final sheet = _reader.sheetOf(frame.graphics, palette, _paletteGroup);
    if (sheet == null) {
      _toast('这一帧没有图形数据');
      return;
    }
    final name = 'banim_${_entry.abbr}_m${_modeIndex}_sheet'
        '_p$_paletteGroup.png';
    final saved = await saveFile(name, encodePng(sheet));
    if (!mounted) return;
    _toast(saved == null ? '已取消' : '已保存 $name');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final frame = _currentFrame;
    return Scaffold(
      appBar: AppBar(
        title: Text(
            '0x${_entry.id.toRadixString(16).toUpperCase()} ${_entry.abbr}'),
        actions: [
          IconButton(
            tooltip: '导出当前帧 PNG',
            icon: const Icon(Icons.image_outlined),
            onPressed: _exportFrame,
          ),
          IconButton(
            tooltip: '导出图形 sheet PNG',
            icon: const Icon(Icons.grid_on),
            onPressed: _exportSheet,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _paletteSelector(),
          const SizedBox(height: 8),
          _modeSelector(),
          const SizedBox(height: 12),
          _canvas(frame),
          const SizedBox(height: 8),
          _frameControls(),
          const SizedBox(height: 12),
          _infoCard(),
        ],
      ),
    );
  }

  Widget _paletteSelector() {
    const labels = ['自军', '敌军', '友军', '灰色'];
    return Wrap(
      spacing: 8,
      children: [
        for (var g = 0; g < labels.length; g++)
          ChoiceChip(
            label: Text(labels[g]),
            selected: _paletteGroup == g,
            onSelected: (_) => setState(() {
              _paletteGroup = g;
              _stop();
            }),
          ),
      ],
    );
  }

  Widget _modeSelector() {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final m in _modes)
          if (!BattleAnimReader.isWeaponLayer(m.index))
            ChoiceChip(
              label: Text('${m.label} (${m.length})'),
              selected: _modeIndex == m.index,
              onSelected: (_) => setState(() => _selectMode(m.index)),
            ),
      ],
    );
  }

  Widget _canvas(TileImage? frame) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF20242A),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(8),
      child: AspectRatio(
        aspectRatio:
            BattleAnimReader.screenWidth / BattleAnimReader.screenHeight,
        child: frame == null
            ? const Center(
                child: Text('这一帧没有画面', style: TextStyle(color: Colors.white70)),
              )
            : FutureBuilder<ui.Image>(
                future: _BattleAnimImageCache.instance.load(
                  _BattleAnimImageCache.instance.keyFor(
                    _entry.id,
                    _modeIndex,
                    _frameIndex,
                    _paletteGroup,
                  ),
                  frame,
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
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.none,
                  );
                },
              ),
      ),
    );
  }

  Widget _frameControls() {
    final total = _frames.length;
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              tooltip: '播放 / 暂停',
              icon: Icon(_playing ? Icons.pause_circle : Icons.play_circle),
              onPressed: total == 0 ? null : _togglePlay,
            ),
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: total == 0
                  ? null
                  : () => setState(() {
                        _stop();
                        _frameIndex = (_frameIndex - 1 + total) % total;
                      }),
            ),
            Expanded(
              child: Slider(
                value:
                    total == 0 ? 0 : _frameIndex.clamp(0, total - 1).toDouble(),
                min: 0,
                max: total <= 1 ? 1 : (total - 1).toDouble(),
                divisions: total <= 1 ? null : total - 1,
                label: total == 0 ? '-' : '${_frameIndex + 1} / $total',
                onChanged: total == 0
                    ? null
                    : (v) => setState(() {
                          _stop();
                          _frameIndex = v.round();
                        }),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: total == 0
                  ? null
                  : () => setState(() {
                        _stop();
                        _frameIndex = (_frameIndex + 1) % total;
                      }),
            ),
          ],
        ),
        Text(
          total == 0
              ? '这一模式没有图像帧'
              : '第 ${_frameIndex + 1} / $total 帧'
                  ' · 等待 ${_frames[_frameIndex.clamp(0, total - 1)].wait}',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _infoCard() {
    final sheetCount = _frames.map((f) => f.graphics).toSet().length;
    String hex(int v) =>
        '0x${v.toRadixString(16).toUpperCase().padLeft(8, '0')}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv('缩写', _entry.abbr),
            _kv('模式数据', hex(_entry.modes)),
            _kv('帧脚本', hex(_entry.script)),
            _kv('OAM (右→左)', hex(_entry.oamRightToLeft)),
            _kv('OAM (左→右)', hex(_entry.oamLeftToRight)),
            _kv('调色板', hex(_entry.palette)),
            _kv('本模式图形 sheet', '$sheetCount 张'),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(k,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          Expanded(
            child: SelectableText(
              v,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}
