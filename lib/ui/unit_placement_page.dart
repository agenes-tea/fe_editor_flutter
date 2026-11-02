import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
            }, max: 63, hint: '范围 0 ~ 63（地图格坐标）'),
            _numberField('坐标 Y', _unit.y, (v) {
              if (_up.setPosition(_unit, _unit.x, v)) {
                _changed = true;
                _refresh();
              }
            }, max: 63, hint: '范围 0 ~ 63（地图格坐标）'),
            _numberField('等级', _unit.level, (v) {
              if (_up.setLevel(_unit, v)) {
                _changed = true;
                _refresh();
              }
            }, max: 31, hint: '范围 0 ~ 31'),
            _classField(),
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
              _itemField('道具 ${i + 1}', i),
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

  /// 数值字段：± 按钮微调，**点中间的数字直接输入**（输 147 号不用点一百多下）。
  Widget _numberField(String label, int value, void Function(int) onChanged,
      {int min = 0, int max = 255, String? hint}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
              width: 90,
              child: Text(label, style: const TextStyle(fontSize: 13))),
          IconButton(
            icon: const Icon(Icons.remove, size: 18),
            onPressed: value > min ? () => onChanged(value - 1) : null,
          ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _promptNumber(label, value, onChanged,
                  min: min, max: max, hint: hint),
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
            onPressed: value < max ? () => onChanged(value + 1) : null,
          ),
        ],
      ),
    );
  }

  /// 弹输入框要一个整数（带范围提示与校验）。
  Future<void> _promptNumber(
      String label, int value, void Function(int) onChanged,
      {int min = 0, int max = 255, String? hint}) async {
    final ctrl = TextEditingController(text: '$value');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            helperText: hint ?? '范围 $min ~ $max',
            helperMaxLines: 3,
          ),
          onSubmitted: (s) {
            final p = int.tryParse(s.trim());
            Navigator.pop(ctx, p);
          },
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final p = int.tryParse(ctrl.text.trim());
              Navigator.pop(ctx, p);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (v == null) return;
    if (v < min || v > max) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('$label 必须在 $min ~ $max')));
      return;
    }
    onChanged(v);
  }


  /// 职业字段：与数值字段一致的手输，外加清单搜索（职业有名字，比记编号好用）。
  Widget _classField() {
    final rom = widget.edit.liveRom;
    final name = _unit.classId >= 0 && _unit.classId < rom.classCount
        ? rom.classDisplayName(_unit.classId).trim()
        : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                  width: 90,
                  child: Text('职业 ID', style: TextStyle(fontSize: 13))),
              IconButton(
                icon: const Icon(Icons.remove, size: 18),
                onPressed: _unit.classId > 0
                    ? () => _setClass(_unit.classId - 1)
                    : null,
              ),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => _promptNumber('职业 ID', _unit.classId,
                      _setClass,
                      max: rom.classCount - 1,
                      hint: '范围 0 ~ ${rom.classCount - 1}。'
                          '也可以用右边的清单按钮搜索选。'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant),
                    ),
                    child: Text('${_unit.classId}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 15,
                            decoration: TextDecoration.underline,
                            decorationStyle: TextDecorationStyle.dotted)),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, size: 18),
                onPressed: _unit.classId < rom.classCount - 1
                    ? () => _setClass(_unit.classId + 1)
                    : null,
              ),
              IconButton(
                tooltip: '从清单选',
                icon: const Icon(Icons.list, size: 20),
                onPressed: () => _pickClass(),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 90),
            child: Text(name.isEmpty ? '（未命名职业）' : name,
                style: const TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }

  void _setClass(int id) {
    if (_up.setClass(_unit, id)) {
      _changed = true;
      _refresh();
    }
  }

  Future<void> _pickClass() async {
    final rom = widget.edit.liveRom;
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => _ItemPickerDialog(
        count: rom.classCount,
        current: _unit.classId,
        nameOf: (i) => rom.classDisplayName(i).trim(),
        title: '选择职业',
      ),
    );
    if (picked != null) _setClass(picked);
  }

  /// 道具格：显示「名字（ID）」，点数字可手输，右侧按钮开道具清单搜索选。
  Widget _itemField(String label, int index) {
    final rom = widget.edit.liveRom;
    final id = _unit.items[index];
    final name = id > 0 && id < rom.itemCount
        ? rom.itemDisplayName(id).trim()
        : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                  width: 90,
                  child: Text(label, style: const TextStyle(fontSize: 13))),
              IconButton(
                icon: const Icon(Icons.remove, size: 18),
                onPressed: id > 0
                    ? () => _setItem(index, id - 1)
                    : null,
              ),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => _promptNumber(
                    '$label 的道具 ID',
                    id,
                    (v) => _setItem(index, v),
                    min: 0,
                    max: rom.itemCount - 1,
                    hint: '0 = 空；范围 0 ~ ${rom.itemCount - 1}。'
                        '也可以用右边的清单按钮搜索选。',
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant),
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
                onPressed: id < rom.itemCount - 1
                    ? () => _setItem(index, id + 1)
                    : null,
              ),
              IconButton(
                tooltip: '从清单选',
                icon: const Icon(Icons.list, size: 20),
                onPressed: () => _pickItem(index, id),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 90),
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
    if (_up.setItem(_unit, index, id)) {
      _changed = true;
      _refresh();
    }
  }

  /// 道具清单：可按名字/ID 搜索，选中直接写回。
  Future<void> _pickItem(int index, int current) async {
    final rom = widget.edit.liveRom;
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => _ItemPickerDialog(
        count: rom.itemCount,
        current: current,
        nameOf: (i) => rom.itemDisplayName(i).trim(),
      ),
    );
    if (picked != null) _setItem(index, picked);
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

/// 道具选择：可按名字 / ID 搜索，列表带名字，避免只凭编号猜。
class _ItemPickerDialog extends StatefulWidget {
  final int count;
  final int current;
  final String Function(int) nameOf;
  final String title;

  const _ItemPickerDialog({
    required this.count,
    required this.current,
    required this.nameOf,
    this.title = '选择道具',
  });

  @override
  State<_ItemPickerDialog> createState() => _ItemPickerDialogState();
}

class _ItemPickerDialogState extends State<_ItemPickerDialog> {
  final _ctrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool _matches(int id) {
    if (id == 0) return _query.isEmpty;
    final q = _query.trim();
    if (q.isEmpty) return true;
    if ('$id' == q) return true;
    return widget.nameOf(id).contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final ids = [for (var i = 0; i < widget.count; i++) if (_matches(i)) i];
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 380,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 20),
                hintText: '输名字或 ID 过滤',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: ids.length,
                itemBuilder: (ctx, i) {
                  final id = ids[i];
                  final name = id == 0 ? '（空）' : widget.nameOf(id);
                  return ListTile(
                    dense: true,
                    selected: id == widget.current,
                    title: Text(name.isEmpty ? '（未命名）' : name),
                    trailing: Text('$id',
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12)),
                    onTap: () => Navigator.pop(ctx, id),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('共 ${ids.length} 条',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
      ],
    );
  }
}
