import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/chapter_events.dart';
import '../core/editable_rom.dart';
import '../core/fe_rom.dart';
import 'item_picker_dialog.dart';
import '../core/map_sprite_image.dart';

/// 编辑事件脚本里生成的单位（`UnitDefinition`）。
///
/// 只做**原地字段覆盖**：角色 / 职业 / 等级 / 坐标 / 阵营 / 四个道具槽。
/// 不插入、不删除任何事件指令——脚本是连续字节码，插一条会让后续 `CALL`
/// 的相对位置失效（AGENTS §15h）。字段覆盖只碰结构体自身的字节。
class EventUnitEditPage extends StatefulWidget {
  final EditableRom edit;
  final LoadedUnit unit;

  const EventUnitEditPage({
    super.key,
    required this.edit,
    required this.unit,
  });

  @override
  State<EventUnitEditPage> createState() => _EventUnitEditPageState();
}

class _EventUnitEditPageState extends State<EventUnitEditPage> {
  late final ChapterEvents _events;
  late final UnitSpriteProvider _sprites;
  late int _charId;
  late int _classId;
  late int _level;
  late int _x;
  late int _y;
  late int _allegiance;
  late List<int> _items;
  bool _changed = false;

  FeRom get _rom => widget.edit.liveRom;

  bool get _isFe8 {
    final id = widget.edit.rom.table.id;
    return id == 'FE8J' || id == 'FE8U';
  }

  @override
  void initState() {
    super.initState();
    _events = ChapterEvents(widget.edit.liveRom);
    _sprites = UnitSpriteProvider(widget.edit.rom);
    _reload();
  }

  /// 从**实时 buffer** 重读字段：改完道具后要立刻看到新值，
  /// 不能用 [widget.unit]（那是进入页面时的快照）。
  void _reload() {
    final u = widget.unit;
    final at = u.addr;
    final b = widget.edit.buffer;
    _charId = b.u8(at);
    _classId = b.u8(at + 1);
    final grow = b.u8(at + 3);
    _allegiance = (grow >> 1) & 0x03;
    _level = (grow >> 3) & 0x1F;
    if (_isFe8) {
      final packed = b.u16(at + 4);
      _x = packed & 0x3F;
      _y = (packed >> 6) & 0x3F;
    } else {
      _x = b.u8(at + 4);
      _y = b.u8(at + 5);
    }
    final itemsBase = at + (_isFe8 ? 12 : 8);
    _items = [for (var k = 0; k < 4; k++) b.u8(itemsBase + k)];
  }

  void _apply(void Function() fn) {
    if (!mounted) return;
    setState(() {
      fn();
      _changed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final className = _classId == 0
        ? (_rom.unitClassId(_charId - 1) < 0
            ? ''
            : _rom.classDisplayName(_rom.unitClassId(_charId - 1)))
        : _rom.classDisplayName(_classId);
    final charName = _rom.unitDisplayName(_charId - 1);
    final effectiveClass =
        _classId == 0 ? _rom.unitClassId(_charId - 1) : _classId;
    final future = effectiveClass > 0
        ? _sprites.imageFor(effectiveClass, _allegiance == 2 ? 1 : 0)
        : null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('事件单位')),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: future == null
                        ? Icon(Icons.person, color: scheme.onSurfaceVariant)
                        : FutureBuilder<ui.Image>(
                            future: future,
                            builder: (ctx, snap) {
                              if (!snap.hasData) {
                                return Icon(Icons.person,
                                    color: scheme.onSurfaceVariant);
                              }
                              return RawImage(
                                image: snap.data,
                                filterQuality: FilterQuality.none,
                                fit: BoxFit.contain,
                              );
                            },
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          charName.isEmpty ? '角色 $_charId' : charName,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          className.isEmpty ? '职业 $_classId' : className,
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _note(
              '这是事件脚本里生成的单位（剧情增援）。改动只覆盖结构体字段，'
              '不触碰事件指令流。',
            ),
            const Divider(height: 24),
            _numberTile('角色 ID', _charId, 1, _rom.unitCount - 1, (v) {
              _writeU8(widget.unit.addr, v);
              _apply(() => _charId = v);
            }, name: charName),
            _numberTile('职业 ID', _classId, 0, _rom.classCount - 1, (v) {
              _writeU8(widget.unit.addr + 1, v);
              _apply(() => _classId = v);
            }, name: className, hint: '0 = 用角色默认职业'),
            _numberTile('等级', _level, 0, 31, (v) {
              _writeGrow(level: v);
              _apply(() => _level = v);
            }),
            _numberTile('X 坐标', _x, 0, 63, (v) {
              _writePos(x: v);
              _apply(() => _x = v);
            }),
            _numberTile('Y 坐标', _y, 0, 63, (v) {
              _writePos(y: v);
              _apply(() => _y = v);
            }),
            _allegianceTile(),
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('携带道具',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant)),
            ),
            for (var i = 0; i < 4; i++) _itemField('道具 ${i + 1}', i),
          ],
        ),
      ),
    );
  }

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            height: 1.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );

  /// 数值字段：点中间数字直接弹输入框（± 只做粒度调节）。
  Widget _numberTile(
    String label,
    int value,
    int min,
    int max,
    void Function(int) onSet, {
    String name = '',
    String hint = '',
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
              width: 76,
              child: Text(label, style: const TextStyle(fontSize: 13))),
          IconButton(
            icon: const Icon(Icons.remove, size: 18),
            onPressed: value > min ? () => onSet(value - 1) : null,
          ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _promptNumber(label, value, onSet, min, max,
                  hint: hint),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant),
                ),
                child: Text(
                  '$value',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 15,
                      decoration: TextDecoration.underline,
                      decorationStyle: TextDecorationStyle.dotted),
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 18),
            onPressed: value < max ? () => onSet(value + 1) : null,
          ),
          SizedBox(
            width: 96,
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _allegianceTile() {
    const labels = ['我方', '友军', '敌方'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const SizedBox(
              width: 76,
              child: Text('阵营', style: TextStyle(fontSize: 13))),
          Expanded(
            child: SegmentedButton<int>(
              segments: [
                for (var i = 0; i < 3; i++)
                  ButtonSegment(value: i, label: Text(labels[i])),
              ],
              selected: {_allegiance.clamp(0, 2)},
              showSelectedIcon: false,
              onSelectionChanged: (s) {
                final v = s.first;
                _writeGrow(allegiance: v);
                _apply(() => _allegiance = v);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _itemField(String label, int index) {
    final id = _items[index];
    final name =
        id > 0 && id < _rom.itemCount ? _rom.itemDisplayName(id).trim() : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                  width: 76,
                  child: Text(label, style: const TextStyle(fontSize: 13))),
              IconButton(
                icon: const Icon(Icons.remove, size: 18),
                onPressed: id > 0 ? () => _setItem(index, id - 1) : null,
              ),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => _promptNumber(
                    '$label 的道具 ID',
                    id,
                    (v) => _setItem(index, v),
                    0,
                    _rom.itemCount - 1,
                    hint: '0 = 空；范围 0 ~ ${_rom.itemCount - 1}。'
                        '也可以用右边的清单按钮搜索选。',
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color:
                              Theme.of(context).colorScheme.outlineVariant),
                    ),
                    child: Text(
                      '$id',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 15,
                          decoration: TextDecoration.underline,
                          decorationStyle: TextDecorationStyle.dotted),
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, size: 18),
                onPressed:
                    id < _rom.itemCount - 1 ? () => _setItem(index, id + 1) : null,
              ),
              IconButton(
                tooltip: '从清单选',
                icon: const Icon(Icons.list, size: 20),
                onPressed: () => _pickItem(index, id),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 76),
            child: Text(
              id == 0 ? '（空）' : (name.isEmpty ? '（未命名道具）' : name),
              style: TextStyle(
                fontSize: 11,
                color: id == 0 ? Colors.grey : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _setItem(int index, int id) {
    if (_events.setUnitItem(widget.edit, widget.unit, index, id) < 0) return;
    _apply(() => _items[index] = id);
  }

  Future<void> _pickItem(int index, int current) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => ItemPickerDialog(
        count: _rom.itemCount,
        current: current,
        nameOf: (i) => _rom.itemDisplayName(i).trim(),
      ),
    );
    if (picked != null) _setItem(index, picked);
  }

  Future<void> _promptNumber(
    String label,
    int current,
    void Function(int) onSet,
    int min,
    int max, {
    String hint = '',
  }) async {
    final ctrl = TextEditingController(text: '$current');
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v.trim())),
            ),
            const SizedBox(height: 8),
            Text(
              hint.isEmpty ? '范围 $min ~ $max。' : hint,
              style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, int.tryParse(ctrl.text.trim())),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (result == null) return;
    // 范围校验放在弹框这层：超范围拒绝而不是夹紧写坏
    if (result < min || result > max) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('超出范围：$min ~ $max')));
      return;
    }
    onSet(result);
  }

  void _writeU8(int at, int value) {
    final b = widget.edit.buffer;
    final before = b.u8(at);
    final after = value & 0xFF;
    if (before == after) return;
    b.writeU8(at, after);
    widget.edit.edits.add(ByteEdit(at, before, after));
  }

  /// 阵营与等级共用 `+3` 一字节，按位合并（整字节覆盖会把另一项清零）。
  void _writeGrow({int? level, int? allegiance}) {
    final at = widget.unit.addr + 3;
    final before = widget.edit.buffer.u8(at);
    var after = before;
    if (allegiance != null) {
      after = (after & ~0x06) | ((allegiance & 0x03) << 1);
    }
    if (level != null) {
      after = (after & ~0xF8) | ((level & 0x1F) << 3);
    }
    if (after == before) return;
    widget.edit.buffer.writeU8(at, after);
    widget.edit.edits.add(ByteEdit(at, before, after));
  }

  void _writePos({int? x, int? y}) {
    if (_isFe8) {
      final at = widget.unit.addr + 4;
      final before = widget.edit.buffer.u16(at);
      final nx = x ?? (before & 0x3F);
      final ny = y ?? ((before >> 6) & 0x3F);
      final after = nx | (ny << 6);
      if (after == before) return;
      widget.edit.buffer.writeU8(at, after & 0xFF);
      widget.edit.buffer.writeU8(at + 1, (after >> 8) & 0xFF);
      widget.edit.edits
        ..add(ByteEdit(at, before & 0xFF, after & 0xFF))
        ..add(ByteEdit(at + 1, (before >> 8) & 0xFF, (after >> 8) & 0xFF));
    } else {
      if (x != null) _writeU8(widget.unit.addr + 4, x);
      if (y != null) _writeU8(widget.unit.addr + 5, y);
    }
  }
}
