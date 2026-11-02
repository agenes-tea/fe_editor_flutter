import 'package:flutter/material.dart';

/// 道具选择弹窗：按名字 / ID 搜索，列表带名字，避免只凭编号猜。
///
/// 公共版：供章节页（宝箱奖励 / 商店换品）等页面复用。
/// `Navigator.pop(ctx, id)` 返回选中的道具 ID（取消返回 null）。
class ItemPickerDialog extends StatefulWidget {
  final int count;
  final int current;
  final String Function(int) nameOf;
  final String title;

  const ItemPickerDialog({
    required this.count,
    required this.current,
    required this.nameOf,
    this.title = '选择道具',
    super.key,
  });

  @override
  State<ItemPickerDialog> createState() => _ItemPickerDialogState();
}

class _ItemPickerDialogState extends State<ItemPickerDialog> {
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
