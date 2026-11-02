import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/editable_rom.dart';
import '../core/event_templates.dart';
import '../core/fe_rom.dart';
import '../core/map_reader.dart';

/// 「添加增援」对话框：选回合 + 填一个单位的字段，生成正确的脚本字节。
///
/// 用户不需要懂事件脚本：这里只问「第几回合、什么角色、在哪」，
/// 字节由 [EventTemplates] 生成（搬事件列表 + 追加条目 + 重指指针）。
class AddReinforcementDialog extends StatefulWidget {
  final EditableRom edit;
  final int chapter;

  const AddReinforcementDialog({
    super.key,
    required this.edit,
    required this.chapter,
  });

  @override
  State<AddReinforcementDialog> createState() => _AddReinforcementDialogState();
}

class _AddReinforcementDialogState extends State<AddReinforcementDialog> {
  late final FeRom _rom = widget.edit.liveRom;
  late final List<String> _unitNames = [
    for (var i = 0; i < _rom.unitCount; i++)
      '${i + 1}. ${_rom.unitDisplayName(i).trim().isEmpty ? '（未命名）' : _rom.unitDisplayName(i).trim()}',
  ];
  late final List<String> _classNames = [
    for (var i = 0; i < _rom.classCount; i++)
      '$i. ${_rom.classDisplayName(i).trim().isEmpty ? '（未命名）' : _rom.classDisplayName(i).trim()}',
  ];

  int _turn = 5;
  int _charIndex = 0;
  int _classIndex = 0;
  int _level = 10;
  int _x = 1;
  int _y = 1;
  int _allegiance = 2;

  String? _error;
  String? _done;

  ChapterMap? get _map {
    final reader = MapReader(_rom);
    return reader.available ? reader.chapterMap(widget.chapter) : null;
  }

  void _apply() {
    final map = _map;
    final out = EventTemplates(widget.edit).addReinforcement(
      chapter: widget.chapter,
      turn: _turn,
      units: [
        ReinforcementUnit(
          charId: _charIndex + 1,
          classId: _classIndex,
          level: _level,
          x: _x,
          y: _y,
          allegiance: _allegiance,
        ),
      ],
    );
    setState(() {
      if (out.ok) {
        _done = out.message +
            (map == null ? '' : '（本章地图 ${map.width}×${map.height}）');
        _error = null;
      } else {
        _error = out.message;
        _done = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final map = _map;
    return AlertDialog(
      title: const Text('添加增援'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '第 ${widget.chapter} 章：在第 N 回合，于指定坐标生成一个单位。'
                '只追加一条事件，不改动已有的剧情脚本。',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              _numberField('回合', _turn, 1, 255, (v) => setState(() => _turn = v)),
              _dropdown('角色（单位表 ID 从 1 起）', _charIndex, _unitNames,
                  (v) => setState(() => _charIndex = v)),
              _dropdown('职业（0 = 用角色默认职业）', _classIndex, _classNames,
                  (v) => setState(() => _classIndex = v)),
              _numberField('等级', _level, 0, 31, (v) => setState(() => _level = v)),
              Row(
                children: [
                  Expanded(
                    child: _numberField(
                      'X 坐标',
                      _x,
                      0,
                      (map?.width ?? 32) - 1,
                      (v) => setState(() => _x = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _numberField(
                      'Y 坐标',
                      _y,
                      0,
                      (map?.height ?? 32) - 1,
                      (v) => setState(() => _y = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 2, label: Text('敌方')),
                  ButtonSegment(value: 1, label: Text('友军')),
                  ButtonSegment(value: 0, label: Text('我方')),
                ],
                selected: {_allegiance},
                onSelectionChanged: (s) => setState(() => _allegiance = s.first),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12)),
              ],
              if (_done != null) ...[
                const SizedBox(height: 12),
                Text(_done!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(onPressed: _apply, child: const Text('添加')),
      ],
    );
  }

  Widget _numberField(
    String label,
    int value,
    int min,
    int max,
    ValueChanged<int> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextFormField(
        initialValue: '$value',
        decoration: InputDecoration(
          labelText: '$label（$min~$max）',
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onChanged: (s) {
          final v = int.tryParse(s);
          if (v == null || v < min || v > max) return;
          onChanged(v);
        },
      ),
    );
  }

  Widget _dropdown(
    String label,
    int value,
    List<String> items,
    ValueChanged<int> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DropdownButtonFormField<int>(
        value: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (var i = 0; i < items.length; i++)
            DropdownMenuItem(
              value: i,
              child: Text(items[i],
                  overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            ),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}
