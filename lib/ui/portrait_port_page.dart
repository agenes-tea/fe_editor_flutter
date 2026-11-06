import 'package:flutter/material.dart';

import '../core/battle_anim.dart' show encodePng;
import '../core/editable_rom.dart';
import '../core/portrait.dart';
import '../core/portrait_porter.dart';
import '../core/rom_session.dart';
import '../core/tile_image.dart';
import 'portrait_page.dart' show PortraitImageCache;

/// 跨版本肖像移植页。
///
/// 左边是**源 ROM**（只读浏览），右边选**目标 ROM**，点一下就搬过去：
/// 源肖像的调色板索引 + 调色板被重新编码成目标版本的格式，
/// 写进目标 ROM 的空闲区，并在目标肖像表尾部新建条目。
///
/// 两个 ROM 都来自 [sessions]（多 ROM 工作区），所以这一页本身不持有引擎状态。
class PortraitPortPage extends StatefulWidget {
  /// 已打开的 ROM 会话（含当前这个）。
  final List<RomSession> sessions;

  /// 当前会话（默认作为源）。
  final RomSession current;

  const PortraitPortPage({
    super.key,
    required this.sessions,
    required this.current,
  });

  @override
  State<PortraitPortPage> createState() => _PortraitPortPageState();
}

class _PortraitPortPageState extends State<PortraitPortPage> {
  late RomSession _source = widget.current;
  late RomSession _target = widget.sessions.length > 1
      ? widget.sessions.firstWhere((s) => s.id != _source.id)
      : widget.current;

  // 换源时要重建（PortraitReader 绑在具体 ROM 上），所以不是 final
  late PortraitReader _reader = PortraitReader(_source.rom.rom);

  int _selected = 1;
  final _idCtrl = TextEditingController(text: '1');

  /// 是否替换目标 ROM 已有的条目（社区改版的主流做法：替换优于新增）。
  bool _replaceMode = false;

  /// 替换模式下要覆盖的目标条目 ID。
  final _targetIdCtrl = TextEditingController(text: '1');
  int _replaceInto = 1;

  String? _status;
  bool _busy = false;

  bool get _canPort =>
      _source.id != _target.id && !_busy && _reader.entryCount > 0;

  @override
  void dispose() {
    _idCtrl.dispose();
    _targetIdCtrl.dispose();
    _reader.dispose();
    super.dispose();
  }

  void _switchSource(RomSession s) {
    setState(() {
      _source = s;
      if (_target.id == s.id && widget.sessions.length > 1) {
        _target = widget.sessions.firstWhere((x) => x.id != s.id);
      }
      _status = null;
    });
    // PortraitReader 绑在具体 ROM 上，换源必须换 reader
    _rebuildReader();
  }

  void _rebuildReader() {
    _reader.dispose();
    _reader = PortraitReader(_source.rom.rom);
    setState(() {});
  }

  void _port() {
    if (!_canPort) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    final outcome = PortraitPorter(_target.rom).port(
      _reader,
      _selected,
      replaceTargetId: _replaceMode ? _replaceInto : null,
    );
    if (outcome.ok) {
      // 缓存 key 是「指纹 + 肖像 ID + 用途」，写入后这些 key 全都没变，
      // 不清缓存的话界面会继续端出写入前的旧图（用户看到的就是「移植了但没变化」）。
      PortraitImageCache.instance.invalidate();
    }
    setState(() {
      _busy = false;
      _status = outcome.ok
          ? (_replaceMode
              ? '已替换目标 ROM 的第 #${outcome.targetId} 条肖像'
                  '（${outcome.bytesWritten} 字节，可撤销）'
              : '已写入目标 ROM：新条目 #${outcome.targetId}'
                  '（${outcome.bytesWritten} 字节，可撤销）')
          : outcome.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('肖像移植')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sessionRow('源 ROM（取图）', _source, (s) => _switchSource(s)),
          const SizedBox(height: 8),
          _sessionRow('目标 ROM（写入）', _target, (s) {
            if (s.id == _source.id) return;
            setState(() {
              _target = s;
              _status = null;
            });
          }),
          const SizedBox(height: 12),
          _modeCard(scheme),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _idCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '源肖像 ID',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    final id = int.tryParse(v.trim());
                    if (id == null) return;
                    setState(() => _selected = id);
                  },
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _canPort ? _port : null,
                icon: Icon(_replaceMode ? Icons.swap_horiz : Icons.download),
                label: Text(_replaceMode ? '替换' : '追加'),
              ),
            ],
          ),
          if (_source.id == _target.id)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '源与目标是同一份 ROM，请选择另一个已打开的 ROM。',
                style: TextStyle(color: scheme.error, fontSize: 12),
              ),
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
          Text('源肖像 #$_selected 预览',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _preview(),
          const SizedBox(height: 16),
          Text(
            '移植会重新编码为目标版本的格式（两作的压缩方式与图像高度不同），'
            '并新建一条肖像条目，不改动原有的任何一张脸。写入可整体撤销。',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700, height: 1.5),
          ),
        ],
      ),
    );
  }

  /// 写入方式：追加新条目 / 替换已有条目。
  ///
  /// 默认推荐替换：社区改版常见做法是把旧职业、旧角色直接换掉，
  /// 不新增条目——不动表、不依赖存档补丁、风险最低。
  Widget _modeCard(ColorScheme scheme) {
    final targetId = _replaceInto;
    final users = _replaceMode
        ? PortraitReader(_target.rom.liveRom).usageOf(targetId)
        : '';
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
              const Text('写入方式', style: TextStyle(fontSize: 12)),
              const Spacer(),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('追加新条目')),
                  ButtonSegment(value: true, label: Text('替换已有')),
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
                  width: 140,
                  child: TextField(
                    controller: _targetIdCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '目标肖像 ID',
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
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    users.isEmpty
                        ? '目标第 $targetId 条：没有角色或职业使用它'
                        : '目标第 $targetId 条当前用于：$users',
                    style: TextStyle(
                      fontSize: 11,
                      color: users.isEmpty ? Colors.grey : scheme.error,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '替换只改写这一条条目，不新增、不动表；原有的脸会被覆盖（可整体撤销）。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sessionRow(String label, RomSession active, ValueChanged<RomSession> onPick) {
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
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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

  Widget _preview() {
    final face = _reader.faceImage(_selected);
    final map = _reader.mapFaceImage(_selected);
    if (face == null) {
      return Text('源 ROM 没有这张肖像（ID $_selected，共 ${_reader.entryCount} 条）',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 12));
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _png(face, 96 * 2),
        const SizedBox(width: 12),
        if (map != null)
          Column(
            children: [
              _png(map, 64),
              const Text('地图头像', style: TextStyle(fontSize: 10)),
            ],
          ),
      ],
    );
  }

  Widget _png(TileImage tile, double size) {
    final png = encodePng(tile);
    return Image.memory(
      png,
      width: size,
      height: size * tile.height / tile.width,
      filterQuality: FilterQuality.none,
      fit: BoxFit.contain,
    );
  }
}
