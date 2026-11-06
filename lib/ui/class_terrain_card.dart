import 'package:flutter/material.dart';

import '../core/class_terrain.dart';
import '../core/editable_rom.dart';
import '../core/map_reader.dart';

/// 职业的「地形」编辑卡片：移动消耗 + 地形回避/防御/魔防。
///
/// 每张表是**按地形 ID 索引**的 s8 数组（65 项）。这些表在 ROM 里由
/// 多个职业**共享**（指针同址），所以改一处会影响所有共享该表的职业——
/// 卡片顶部会把共享职业列出来，避免用户以为只改了自己这一个。
class ClassTerrainCard extends StatefulWidget {
  final EditableRom edit;
  final int classIndex;
  final bool readOnly;

  const ClassTerrainCard({
    super.key,
    required this.edit,
    required this.classIndex,
    this.readOnly = false,
  });

  @override
  State<ClassTerrainCard> createState() => _ClassTerrainCardState();
}

class _ClassTerrainCardState extends State<ClassTerrainCard> {
  late final ClassTerrain _terrain = ClassTerrain(widget.edit);
  late final MapReader _maps = MapReader(widget.edit.rom);

  @override
  Widget build(BuildContext context) {
    final movOffsets = _terrain.movCostOffsets;
    final lookupOffsets = _terrain.lookupOffsets;

    // 共享影响面：任一表被共享就提示（各槽可能共享不同职业）
    final shared = <String>[];
    for (var i = 0; i < movOffsets.length; i++) {
      final n = _terrain.sharersOf(widget.classIndex, movOffsets[i]).length;
      if (n > 0) shared.add('${ClassTerrain.movCostLabels[i]} 与 $n 个职业共享');
    }
    for (var i = 0; i < lookupOffsets.length; i++) {
      final n = _terrain.sharersOf(widget.classIndex, lookupOffsets[i]).length;
      if (n > 0) shared.add('${ClassTerrain.lookupLabels[i]} 与 $n 个职业共享');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < movOffsets.length; i++)
          _terrainTable(
            title: ClassTerrain.movCostLabels[i],
            slotOffset: movOffsets[i],
            hint: '1 = 消耗 1 格移动；-1 = 不可通行。',
          ),
        for (var i = 0; i < lookupOffsets.length; i++)
          _terrainTable(
            title: ClassTerrain.lookupLabels[i],
            slotOffset: lookupOffsets[i],
            hint: '站在该地形上的修正值，可为负。',
          ),
        if (shared.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4),
            child: Text(
              '这张表还有其它职业在用（游戏里本就是共享数据，'
              '改一处会一起变）：\n${shared.join('\n')}',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  Widget _terrainTable({
    required String title,
    required int slotOffset,
    required String hint,
  }) {
    final target = _terrain.pointerTarget(widget.classIndex, slotOffset);
    if (target < 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Text(
          '$title：该职业没有这张表（指针为空）。',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      );
    }

    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      subtitle: Text(hint, style: const TextStyle(fontSize: 11)),
      children: [
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (var t = 0; t <= ClassTerrain.terrainCount; t++)
              _cell(t, slotOffset, target),
          ],
        ),
      ],
    );
  }

  Widget _cell(int terrainId, int slotOffset, int tableOffset) {
    final v = _terrain.valueAt(widget.classIndex, slotOffset, terrainId);
    if (v == null) return const SizedBox.shrink();
    final name = _maps.terrainName(terrainId);
    final special = v < 0;
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '地形 $terrainId：$name\n点一下改值',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: widget.readOnly
            ? null
            : () => _prompt(terrainId, name, slotOffset, v),
        child: Container(
          width: 52,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: special ? scheme.errorContainer : scheme.surfaceContainerHighest,
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            children: [
              Text(
                '$terrainId',
                style: TextStyle(
                  fontSize: 9,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              Text(
                '$v',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: special ? scheme.onErrorContainer : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _prompt(
      int terrainId, String terrainName, int slotOffset, int current) async {
    final ctrl = TextEditingController(text: '$current');
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('地形 $terrainId · $terrainName'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v.trim())),
            ),
            const SizedBox(height: 8),
            Text(
              '范围 -128 ~ 127。-1 表示不可通行（移动消耗）或没有修正。',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
              ),
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
    if (result < -128 || result > 127) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('超出范围：-128 ~ 127')));
      return;
    }
    if (_terrain.setValue(widget.classIndex, slotOffset, terrainId, result) < 0) {
      return;
    }
    if (mounted) setState(() {});
  }
}
