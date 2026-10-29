import 'package:flutter/material.dart';

import '../core/editable_rom.dart';
import '../core/unit_placement.dart';

/// 章节初始单位配置。
///
/// 只展示「静态配置」——由事件脚本 LOAD 出来的增援不在这里，
/// 列表为空时会明确提示，避免让人以为数据坏了。
class UnitPlacementPage extends StatefulWidget {
  final EditableRom edit;
  const UnitPlacementPage({super.key, required this.edit});

  @override
  State<UnitPlacementPage> createState() => _UnitPlacementPageState();
}

class _UnitPlacementPageState extends State<UnitPlacementPage> {
  late final UnitPlacement _up = UnitPlacement(widget.edit);

  int _chapter = 0;
  UnitSlot? _slot;

  /// 当前入口：未手选时取默认（我方普通，FE6 为蓝方）。
  UnitSlot get _effectiveSlot {
    final s = _slot ?? _up.defaultSlot;
    return _up.slotSupported(s) ? s : _up.defaultSlot;
  }

  @override
  Widget build(BuildContext context) {
    final slot = _effectiveSlot;
    final units = _up.units(_chapter, slot);

    return Scaffold(
      appBar: AppBar(
        title: const Text('章节单位'),
        actions: [
          if (widget.edit.hasChanges)
            TextButton.icon(
              onPressed: () {
                setState(() => widget.edit.revertAll());
              },
              icon: const Icon(Icons.undo, size: 18),
              label: const Text('撤销全部'),
            ),
        ],
      ),
      body: Column(
        children: [
          _chapterBar(),
          _slotBar(),
          if (units.isEmpty)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _up.emptyHint(slot),
                    textAlign: TextAlign.center,
                    style: const TextStyle(height: 1.6, color: Colors.grey),
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: units.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) => _unitTile(units[i], i),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chapterBar() {
    return SizedBox(
      height: 48,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: _up.chapterCount,
        itemBuilder: (ctx, i) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: ChoiceChip(
            label: Text('第 $i 章'),
            selected: _chapter == i,
            onSelected: (_) => setState(() => _chapter = i),
          ),
        ),
      ),
    );
  }

  Widget _slotBar() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final slot in UnitSlot.values)
            if (_up.slotSupported(slot))
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(slot.label),
                  selected: _effectiveSlot == slot,
                  onSelected: (_) => setState(() => _slot = slot),
                ),
              ),
        ],
      ),
    );
  }

  Widget _unitTile(PlacedUnit u, int index) {
    final rom = widget.edit.rom;
    final charName = rom.unitDisplayName(u.unitIndex);
    final className = rom.classDisplayName(u.classId);
    final color = switch (u.allegiance) {
      Allegiance.player => Colors.blue,
      Allegiance.ally => Colors.green,
      Allegiance.enemy => Colors.red,
    };

    return ListTile(
      leading: Container(
        width: 6,
        height: 40,
        color: color,
      ),
      title: Text(
        '${charName.isEmpty ? '角色 ${u.charId}' : charName}'
        '${className.isEmpty ? '' : ' · $className'}',
      ),
      subtitle: Text(
        'Lv ${u.level} · (${u.x}, ${u.y}) · ${u.allegiance.label}'
        '${u.movePath.isEmpty ? '' : ' · 移动到 (${u.movePath.last.x}, ${u.movePath.last.y})'}',
      ),
      trailing: const Icon(Icons.edit, size: 18),
      onTap: () async {
        final changed = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => PlacedUnitEditPage(edit: widget.edit, unit: u),
          ),
        );
        if (changed == true) setState(() {});
      },
    );
  }
}

/// 单个单位的字段编辑。
class PlacedUnitEditPage extends StatefulWidget {
  final EditableRom edit;
  final PlacedUnit unit;

  const PlacedUnitEditPage({super.key, required this.edit, required this.unit});

  @override
  State<PlacedUnitEditPage> createState() => _PlacedUnitEditPageState();
}

class _PlacedUnitEditPageState extends State<PlacedUnitEditPage> {
  late final UnitPlacement _up = UnitPlacement(widget.edit);
  late PlacedUnit _unit = widget.unit;
  bool _changed = false;

  void _refresh() {
    // 按条目地址重新读回，保证界面显示的是 ROM 里的实际值
    final reread = _up.unitAt(_unit.addr);
    if (reread != null) setState(() => _unit = reread);
  }

  @override
  Widget build(BuildContext context) {
    final rom = widget.edit.rom;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {},
      child: Scaffold(
        appBar: AppBar(
          title: Text(rom.unitDisplayName(_unit.unitIndex).isEmpty
              ? '角色 ${_unit.charId}'
              : rom.unitDisplayName(_unit.unitIndex)),
          leading:
              BackButton(onPressed: () => Navigator.pop(context, _changed)),
        ),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _numberField('坐标 X', _unit.x, (v) {
              if (_up.setPosition(_unit, v, _unit.y)) {
                _changed = true;
                _refresh();
              }
            }),
            _numberField('坐标 Y', _unit.y, (v) {
              if (_up.setPosition(_unit, _unit.x, v)) {
                _changed = true;
                _refresh();
              }
            }),
            _numberField('等级', _unit.level, (v) {
              if (_up.setLevel(_unit, v)) {
                _changed = true;
                _refresh();
              }
            }),
            _numberField('职业 ID', _unit.classId, (v) {
              if (_up.setClass(_unit, v)) {
                _changed = true;
                _refresh();
              }
            }),
            const SizedBox(height: 8),
            const Text('阵营',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                for (final a in Allegiance.values)
                  ChoiceChip(
                    label: Text(a.label),
                    selected: _unit.allegiance == a,
                    onSelected: (_) {
                      if (_up.setAllegiance(_unit, a)) {
                        _changed = true;
                        _refresh();
                      }
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('道具（4 格）',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            for (var i = 0; i < 4; i++)
              _numberField('道具 ${i + 1}', _unit.items[i], (v) {
                if (_up.setItem(_unit, i, v)) {
                  _changed = true;
                  _refresh();
                }
              }),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv('条目地址',
                        '0x${_unit.addr.toRadixString(16).toUpperCase()}'),
                    _kv('角色 ID', '${_unit.charId}'),
                    _kv('角色表索引', '${_unit.unitIndex}'),
                    _kv('队长 ID', '${_unit.leaderId}'),
                    _kv('自动成长', _unit.autoGrow ? '是' : '否'),
                    _kv(
                        'AI',
                        _unit.ai
                            .map((v) => '0x${v.toRadixString(16)}')
                            .join(', ')),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _numberField(String label, int value, void Function(int) onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
              width: 90,
              child: Text(label, style: const TextStyle(fontSize: 13))),
          IconButton(
            icon: const Icon(Icons.remove, size: 18),
            onPressed: value > 0 ? () => onChanged(value - 1) : null,
          ),
          SizedBox(
            width: 56,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 18),
            onPressed: () => onChanged(value + 1),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(k,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          Expanded(
            child: SelectableText(v,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }
}
