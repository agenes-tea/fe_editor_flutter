import 'package:flutter/material.dart';

import '../core/battle_anim.dart';
import '../core/battle_anim_porter.dart';
import '../core/rom_session.dart';

/// 战斗动画移植页。
///
/// 只做「整包搬运」：把一条动画需要的脚本 / OAM / 调色板 / 全部图形 sheet
/// 复制到目标 ROM 的空闲区，再让目标条目指向这份副本。**不做逐帧编辑**。
///
/// 默认就是替换模式——社区改版的主流做法是把旧动画直接换掉，
/// 不新增条目（不新增就不需要动表，也不会撞上引擎的动画数量上限）。
class BattleAnimPortPage extends StatefulWidget {
  final List<RomSession> sessions;
  final RomSession current;
  final int initialSourceId;

  const BattleAnimPortPage({
    super.key,
    required this.sessions,
    required this.current,
    this.initialSourceId = 0,
  });

  @override
  State<BattleAnimPortPage> createState() => _BattleAnimPortPageState();
}

class _BattleAnimPortPageState extends State<BattleAnimPortPage> {
  late RomSession _source = widget.current;
  late RomSession _target = widget.sessions.length > 1
      ? widget.sessions.firstWhere((s) => s.id != _source.id)
      : widget.current;

  BattleAnimReader get _reader => _readerCache ??= BattleAnimReader(_source.rom.rom);
  BattleAnimReader? _readerCache;

  late int _sourceId = widget.initialSourceId;

  /// 替换模式（默认）：目标条目 ID 由用户填。
  bool _replaceMode = true;
  final _targetIdCtrl = TextEditingController(text: '0');
  int _replaceInto = 0;
  final _sourceIdCtrl = TextEditingController(text: '0');

  String? _status;
  bool _busy = false;

  bool get _canPort =>
      _source.id != _target.id &&
      !_busy &&
      _reader.count > 0 &&
      _sourceId >= 0 &&
      _sourceId < _reader.count;

  @override
  void initState() {
    super.initState();
    _sourceIdCtrl.text = '$_sourceId';
    _targetIdCtrl.text = '$_replaceInto';
  }

  @override
  void dispose() {
    _sourceIdCtrl.dispose();
    _targetIdCtrl.dispose();
    super.dispose();
  }

  void _switchSource(RomSession s) {
    setState(() {
      _source = s;
      _readerCache = null;
      if (_target.id == s.id && widget.sessions.length > 1) {
        _target = widget.sessions.firstWhere((x) => x.id != s.id);
      }
      _sourceId = 0;
      _sourceIdCtrl.text = '0';
      _status = null;
    });
  }

  void _port() {
    if (!_canPort) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    final outcome = BattleAnimPorter(_target.rom).port(
      _reader,
      _sourceId,
      replaceTargetId: _replaceMode ? _replaceInto : null,
    );
    setState(() {
      _busy = false;
      _status = outcome.ok
          ? '已写入目标 ROM 第 #${outcome.targetId} 条动画'
              '（${outcome.sheets} 张图形，${outcome.bytesWritten} 字节，可撤销）'
          : outcome.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('战斗动画移植')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sessionRow('源 ROM（取动画）', _source, _switchSource),
          const SizedBox(height: 8),
          _sessionRow('目标 ROM（写入）', _target, (s) {
            if (s.id == _source.id) return;
            setState(() {
              _target = s;
              _status = null;
            });
          }),
          const SizedBox(height: 16),
          _idsCard(scheme),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _canPort ? _port : null,
                icon: Icon(_replaceMode ? Icons.swap_horiz : Icons.download),
                label: Text(_replaceMode ? '替换' : '追加'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _canPort
                      ? (_replaceMode
                          ? '把源动画整包写进目标第 $_replaceInto 条并覆盖它'
                          : '在目标动画表末尾追加一条')
                      : '请选择两个不同的 ROM，并填有效的源动画 ID',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                ),
              ),
            ],
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_status!, style: const TextStyle(fontSize: 12)),
              ),
            ),
          const SizedBox(height: 20),
          Text('源动画 #$_sourceId 预览',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _preview(),
          const SizedBox(height: 16),
          Text(
            '搬运内容：脚本 + 模式表 + 左右两套 OAM + 调色板 + 全部图形 sheet。'
            '脚本与 OAM 原样复制（三作用同一套帧记录格式），图形按目标位置重指向。'
            '不做逐帧编辑，写入可整体撤销。',
            style: TextStyle(
                fontSize: 12, color: Colors.grey.shade700, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _idsCard(ColorScheme scheme) {
    final total = _reader.count;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 130,
                child: TextField(
                  controller: _sourceIdCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '源动画 ID',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    final id = int.tryParse(v.trim());
                    if (id == null) return;
                    setState(() {
                      _sourceId = id;
                      _status = null;
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              Text('（源共 $total 条）',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const Spacer(),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('替换已有')),
                  ButtonSegment(value: false, label: Text('追加')),
                ],
                selected: {_replaceMode},
                onSelectionChanged: (v) => setState(() {
                  _replaceMode = v.first;
                  _status = null;
                }),
              ),
            ],
          ),
          if (_replaceMode) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: 130,
                  child: TextField(
                    controller: _targetIdCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '目标动画 ID',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      final id = int.tryParse(v.trim());
                      if (id == null) return;
                      setState(() {
                        _replaceInto = id;
                        _status = null;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _targetEntryLabel(),
                    style: const TextStyle(fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 目标条目的现状（缩写），让用户确认换的是哪一条。
  String _targetEntryLabel() {
    final r = BattleAnimReader(_target.rom.liveRom);
    final e = r.entry(_replaceInto);
    if (e == null) return '目标第 $_replaceInto 条不存在（共 ${r.count} 条）';
    return '目标第 $_replaceInto 条现在是：${e.abbr}';
  }

  Widget _preview() {
    final r = _reader;
    final e = r.entry(_sourceId);
    if (e == null) {
      return Text('源 ROM 没有第 $_sourceId 条动画',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 12));
    }
    final modes = r.modesOf(e);
    if (modes.isEmpty) {
      return Text('这条动画（${e.abbr}）的模式表读不出来',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 12));
    }
    final frames = r.framesOf(e, modes.first);
    if (frames.isEmpty) {
      return Text('这条动画（${e.abbr}）第一模式没有图像帧',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 12));
    }
    final img = r.renderFrame(e, modes.first, 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${e.abbr} · 第一模式 ${frames.length} 帧',
            style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 6),
        if (img == null)
          Text('这一帧渲染不出来（可能是武器图层单独成帧）',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12))
        else
          Container(
            color: const Color(0xFF20242A),
            child: _StillView(img: img),
          ),
      ],
    );
  }

  Widget _sessionRow(
      String label, RomSession active, ValueChanged<RomSession> onPick) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        SizedBox(
          height: 52,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: widget.sessions.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final s = widget.sessions[i];
              final selected = s.id == active.id;
              final scheme = Theme.of(context).colorScheme;
              return InkWell(
                onTap: () => onPick(s),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: selected
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: selected ? scheme.primary : Colors.transparent,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(s.versionId,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.bold)),
                      Text(
                        s.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 把一帧渲染结果画出来（只画不透明像素，避免黑底透出）。
class _StillView extends StatelessWidget {
  final dynamic img;
  const _StillView({required this.img});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: img.width / img.height,
      child: CustomPaint(painter: _FramePainter(img)),
    );
  }
}

class _FramePainter extends CustomPainter {
  final dynamic img;
  _FramePainter(this.img);

  @override
  void paint(Canvas canvas, Size size) {
    final pixels = img.pixels as List<int>;
    final w = img.width as int;
    final h = img.height as int;
    final scale = size.width / w;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        if (pixels[i + 3] == 0) continue;
        final paint = Paint()
          ..color = Color.fromARGB(
              255, pixels[i], pixels[i + 1], pixels[i + 2]);
        canvas.drawRect(
          Rect.fromLTWH(x * scale, y * scale, scale + 0.5, scale + 0.5),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FramePainter old) => old.img != img;
}
