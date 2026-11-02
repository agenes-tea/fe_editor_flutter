import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/chapter_event_editor.dart';
import '../core/chapter_events.dart';
import '../core/editable_rom.dart';
import '../core/event_preview.dart';
import '../core/event_templates.dart';
import 'item_picker_dialog.dart';

/// 章节事件编辑器。
///
/// 能做的（**只有这一类**）：在事件列表末尾追加一条触发 + 它自己的「生成单位」脚本，
/// 以及删除本工具追加的那条。
///
/// 不能做的：往既有脚本里插指令。事件脚本是连续字节码，插一条会让后续
/// `CALL` 的相对位置全部失效——要做到「在原版没有的地方加一句新台词」，
/// 现在的做法是**追加一条新事件**，在它自己的脚本里写对话与单位生成，
/// 既有脚本一个字节不动。这与 AGENTS §28b 的边界一致。
class EventEditorPage extends StatefulWidget {
  const EventEditorPage({
    super.key,
    required this.edit,
    required this.chapter,
    required this.chapterTitle,
  });

  final EditableRom edit;
  final int chapter;
  final String chapterTitle;

  @override
  State<EventEditorPage> createState() => _EventEditorPageState();
}

class _EventEditorPageState extends State<EventEditorPage> {
  EventTriggerType _type = EventTriggerType.turn;
  int _turn = 3;
  int _charA = 1;
  int _x = 5;
  int _y = 5;
  int _dialogueTextId = 0;
  final List<_DraftUnit> _units = [
    _DraftUnit(charId: 1, classId: 0, level: 5, x: 5, y: 5, allegiance: 2),
  ];
  String? _message;
  bool _ok = false;
  EventPreview? _preview;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() => _preview = EventPreviewer(widget.edit).of(widget.chapter));
  }

  void _toast(String msg, bool ok) {
    setState(() {
      _message = msg;
      _ok = ok;
    });
  }

  Future<void> _add() async {
    final editor = ChapterEventEditor(widget.edit);
    final units = [
      for (final u in _units)
        ReinforcementUnit(
          charId: u.charId,
          classId: u.classId,
          level: u.level,
          x: u.x,
          y: u.y,
          allegiance: u.allegiance,
          items: u.items,
        )
    ];
    EventEditOutcome r;
    switch (_type) {
      case EventTriggerType.turn:
        r = editor.addTurnReinforcement(chapter: widget.chapter, turn: _turn,
            units: units, dialogueTextId: _dialogueTextId);
      case EventTriggerType.character:
        r = editor.addCharacterEvent(chapter: widget.chapter, charA: _charA,
            units: units, dialogueTextId: _dialogueTextId);
      case EventTriggerType.location:
        r = editor.addLocationEvent(chapter: widget.chapter, x: _x, y: _y,
            units: units, dialogueTextId: _dialogueTextId);
      case EventTriggerType.chest:
      case EventTriggerType.shop:
        _toast('该类型暂未开放追加（宝箱奖励/商店换品请用章节页事件表的按钮）', false);
        return;
    }
    _toast(r.message.isEmpty ? r.result.name : r.message, r.ok);
    if (r.ok) _reload();
  }

  Future<void> _removeLast() async {
    final r = ChapterEventEditor(widget.edit)
        .removeLastAdded(chapter: widget.chapter, type: _type);
    _toast(r.message.isEmpty ? r.result.name : r.message, r.ok);
    if (r.ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.chapterTitle.isEmpty
        ? '第 ${widget.chapter} 章'
        : widget.chapterTitle;
    return Scaffold(
      appBar: AppBar(
        title: Text('$title · 事件编辑'),
        actions: [
          IconButton(
            tooltip: '刷新预览',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _boundaryNote(context),
          const SizedBox(height: 12),
          _formCard(context),
          if (_message != null) ...[
            const SizedBox(height: 12),
            _messageBox(context),
          ],
          const SizedBox(height: 16),
          _previewSection(context),
        ],
      ),
    );
  }

  Widget _boundaryNote(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF3A2E13) : const Color(0xFFFFF4D9),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '这里只能「追加一条新事件」，不能往原版已有的事件脚本中间插指令'
        '（事件脚本是连续字节码，插入会让后续 CALL 跳转全部失效）。\n'
        '追加时旧事件列表原样保留在 ROM 里，只改一个 4 字节指针——改坏了可以「撤销全部」。\n'
        '可给新事件填一个「台词文本 ID」，让它在生成单位前先显示一句既有台词（先把那段文本改好再填 ID）。加完用地图工具栏 👁 预览，再导出到模拟器确认。',
        style: TextStyle(
          fontSize: 11,
          height: 1.5,
          color: dark ? const Color(0xFFF1D48A) : const Color(0xFF7A5B00),
        ),
      ),
    );
  }

  Widget _formCard(BuildContext context) {
    final theme = Theme.of(context);
    final rom = widget.edit.liveRom;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('追加事件', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            DropdownButtonFormField<EventTriggerType>(
              value: _type,
              decoration: const InputDecoration(
                  labelText: '触发类型', border: OutlineInputBorder(), isDense: true),
              items: [
                for (final t in [
                  EventTriggerType.turn,
                  EventTriggerType.character,
                  EventTriggerType.location,
                ])
                  DropdownMenuItem(value: t, child: Text(t.label)),
              ],
              onChanged: (v) => setState(() => _type = v ?? _type),
            ),
            const SizedBox(height: 10),
            if (_type == EventTriggerType.turn)
              _numField('第几回合', _turn, 1, 255,
                  (v) => setState(() => _turn = v)),
            if (_type == EventTriggerType.character)
              _numField('角色 ID（1 基）', _charA, 1, rom.unitCount,
                  (v) => setState(() => _charA = v),
                  hint: '1 = ${rom.unitDisplayName(0).trim()}'),
            if (_type == EventTriggerType.location) ...[
              _numField('X', _x, 0, 63, (v) => setState(() => _x = v)),
              const SizedBox(height: 8),
              _numField('Y', _y, 0, 63, (v) => setState(() => _y = v)),
            ],
            _numField('台词文本 ID（可选）', _dialogueTextId, 0, 30000,
                (v) => setState(() => _dialogueTextId = v),
                hint: '0=不带台词；填一个既有文本记录 ID，新事件会先显示该句'),
            const Divider(height: 24),
            Row(
              children: [
                Text('生成单位（${_units.length}）', style: theme.textTheme.titleSmall),
                const Spacer(),
                TextButton.icon(
                  onPressed: _addUnit,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('加一个', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            for (var i = 0; i < _units.length; i++) _unitRow(i),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.add_alert_outlined, size: 18),
                  label: const Text('追加这条事件'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _removeLast,
                  child: const Text('删除最后一条'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _numField(String label, int value, int min, int max,
      void Function(int) onChanged,
      {String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextFormField(
        initialValue: '$value',
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: (v) {
          final n = int.tryParse(v);
          if (n == null) return;
          if (n < min || n > max) return;
          onChanged(n);
        },
      ),
    );
  }

  Widget _unitRow(int index) {
    final u = _units[index];
    final rom = widget.edit.liveRom;
    final unitIdx = u.charId - 1;
    final name = (unitIdx >= 0 && unitIdx < rom.unitCount)
        ? rom.unitDisplayName(unitIdx).trim()
        : '?';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${name.isEmpty ? '（未命名）' : name}'
                      '  Lv${u.level} (${u.x},${u.y}) '
                      '${_allegianceName(u.allegiance)}',
                      style: const TextStyle(fontSize: 12)),
                ),
                IconButton(
                  tooltip: '删除这个单位',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: _units.length <= 1
                      ? null
                      : () => setState(() => _units.removeAt(index)),
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _smallNum('角色', u.charId, 1, rom.unitCount,
                    (v) => setState(() => u.charId = v)),
                _smallNum('职业', u.classId, 0, rom.classCount - 1,
                    (v) => setState(() => u.classId = v),
                    hint: '0=默认'),
                _smallNum('等级', u.level, 0, 31,
                    (v) => setState(() => u.level = v)),
                _smallNum('X', u.x, 0, 63, (v) => setState(() => u.x = v)),
                _smallNum('Y', u.y, 0, 63, (v) => setState(() => u.y = v)),
                DropdownButton<int>(
                  value: u.allegiance,
                  isDense: true,
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('我方', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 1, child: Text('友军', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 2, child: Text('敌方', style: TextStyle(fontSize: 12))),
                  ],
                  onChanged: (v) => setState(() => u.allegiance = v ?? 0),
                ),
                TextButton(
                  onPressed: () => _pickItem(index),
                  child: Text(
                    u.items.isEmpty
                        ? '选道具'
                        : u.items.map((id) => rom.itemDisplayName(id).trim()).join('、'),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _smallNum(String label, int value, int min, int max,
      void Function(int) onChanged,
      {String? hint}) {
    return SizedBox(
      width: 78,
      child: TextFormField(
        initialValue: '$value',
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(fontSize: 12),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          border: const OutlineInputBorder(),
        ),
        onChanged: (v) {
          final n = int.tryParse(v);
          if (n == null || n < min || n > max) return;
          onChanged(n);
        },
      ),
    );
  }

  Future<void> _pickItem(int index) async {
    final rom = widget.edit.liveRom;
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => ItemPickerDialog(
        count: rom.itemCount,
        current: _units[index].items.isEmpty ? 0 : _units[index].items.first,
        nameOf: (id) => rom.itemDisplayName(id).trim(),
        title: '选一件道具',
      ),
    );
    if (picked == null) return;
    setState(() {
      final u = _units[index];
      if (!u.items.contains(picked)) u.items.add(picked);
    });
  }

  void _addUnit() {
    final last = _units.last;
    setState(() {
      _units.add(_DraftUnit(
        charId: last.charId,
        classId: last.classId,
        level: last.level,
        x: last.x,
        y: last.y,
        allegiance: last.allegiance,
      ));
    });
  }

  static String _allegianceName(int a) => switch (a) {
        0 => '我方',
        1 => '友军',
        _ => '敌方',
      };

  Widget _messageBox(BuildContext context) {
    final color = _ok ? Colors.green : Colors.red;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(_message!,
          style: TextStyle(fontSize: 12, color: color.shade800)),
    );
  }

  Widget _previewSection(BuildContext context) {
    final p = _preview;
    if (p == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('本章事件（${p.events.length} 条）', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        Text(
          '下面是工具解析结果，用来确认「数据写进去了」；'
          '至于游戏里会不会真的触发，要导出到模拟器验证。',
          style: TextStyle(fontSize: 11, color: theme.hintColor, height: 1.4),
        ),
        const SizedBox(height: 8),
        for (final e in p.events)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  switch (e.kind) {
                    EventTriggerKind.turn => Icons.timelapse,
                    EventTriggerKind.location => Icons.place_outlined,
                    EventTriggerKind.character => Icons.person_search_outlined,
                    _ => Icons.flag_outlined,
                  },
                  size: 14,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(e.sentence,
                      style: const TextStyle(fontSize: 12, height: 1.4)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DraftUnit {
  int charId;
  int classId;
  int level;
  int x;
  int y;
  int allegiance;
  final List<int> items;

  _DraftUnit({
    required this.charId,
    required this.classId,
    required this.level,
    required this.x,
    required this.y,
    required this.allegiance,
    List<int>? items,
  }) : items = items ?? [];
}
