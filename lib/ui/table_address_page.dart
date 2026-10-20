import 'package:flutter/material.dart';

import '../core/editable_rom.dart';
import '../core/fe_rom.dart';
import '../core/portrait.dart';

/// 手动指定数据表基址。
///
/// 有些重度改版会把表搬到 ROM 其它位置**并且**不保留原指针槽，
/// 这时自动探测无能为力（GBA ROM 里指针数组遍地都是，仅靠内容特征
/// 无法唯一定位一张表——实测扫描候选高达 6.8 万个）。
/// 这种情况下由用户手动指定。
class TableAddressPage extends StatefulWidget {
  final EditableRom edit;
  const TableAddressPage({super.key, required this.edit});

  @override
  State<TableAddressPage> createState() => _TableAddressPageState();
}

class _TableAddressPageState extends State<TableAddressPage> {
  late final Map<String, TextEditingController> _controllers = {
    for (final key in const ['unit', 'class', 'item', 'portrait'])
      key: TextEditingController(text: _current(key)),
  };

  String _current(String key) {
    final v = widget.edit.rom.tableBaseOverrides[key];
    if (v != null) return '0x${v.toRadixString(16)}';
    return '';
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  int? _parse(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    var v = 0;
    if (t.toLowerCase().startsWith('0x')) {
      v = int.tryParse(t.substring(2), radix: 16) ?? -1;
    } else {
      v = int.tryParse(t) ?? -1;
    }
    return v < 0 ? null : v;
  }

  void _apply() {
    final rom = widget.edit.rom;
    for (final entry in _controllers.entries) {
      final v = _parse(entry.value.text);
      if (v == null) {
        rom.tableBaseOverrides.remove(entry.key);
      } else {
        rom.tableBaseOverrides[entry.key] = v;
      }
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final rom = widget.edit.rom;
    return Scaffold(
      appBar: AppBar(title: const Text('表地址')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '留空表示使用自动探测结果。\n'
                '填入文件偏移（可用 0x 前缀的十六进制）。\n'
                '注意：地址不对会导致列表显示乱码。',
                style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _field('unit', '角色表', rom.unitBase),
          _field('class', '职业表', rom.classBase),
          _field('item', '道具表', rom.itemBase),
          _field('portrait', '肖像表', _portraitBase(rom)),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _apply,
            icon: const Icon(Icons.check),
            label: const Text('应用'),
          ),
        ],
      ),
    );
  }

  int? _portraitBase(FeRom rom) {
    final o = rom.tableBaseOverrides['portrait'];
    if (o != null) return o;
    try {
      final r = PortraitReader(rom);
      final b = r.baseAddress;
      return b < 0 ? null : b;
    } catch (_) {
      return null;
    }
  }

  Widget _field(String key, String label, int? current) {
    final controller = _controllers[key]!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          labelText: label,
          helperText: current == null || current < 0
              ? '未探测到'
              : '当前：0x${current.toRadixString(16)}',
          helperStyle: const TextStyle(fontSize: 11),
        ),
      ),
    );
  }
}
