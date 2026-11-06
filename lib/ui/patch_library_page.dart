import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/editable_rom.dart';
import '../core/patch_library.dart';

/// FEBuilderGBA 社区补丁库：一键安装「固定字节写入」类补丁。
class PatchListPage extends StatefulWidget {
  final EditableRom edit;
  const PatchListPage({super.key, required this.edit});

  @override
  State<PatchListPage> createState() => _PatchListPageState();
}

class _PatchListPageState extends State<PatchListPage> {
  PatchLibrary? _lib;
  bool _loading = true;
  String? _error;
  bool _changed = false;
  final _filter = TextEditingController();

  String get _assetDir => 'assets/patches/${widget.edit.rom.table.id}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final lib = await PatchLibrary.loadFromAssets(_assetDir);
      if (!mounted) return;
      setState(() {
        _lib = lib;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('补丁库')),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('加载补丁库失败：$_error'),
        ),
      );
    }
    final lib = _lib!;
    if (lib.patches.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '这个版本（${widget.edit.rom.table.id}）暂无内置补丁。\n'
            '目前收录了 FEBuilderGBA 中「固定字节写入」类补丁。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ),
      );
    }

    final q = _filter.text.trim().toLowerCase();
    final list = q.isEmpty
        ? lib.patches
        : lib.patches.where((p) =>
            p.name.toLowerCase().contains(q) ||
            p.info.toLowerCase().contains(q)).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _filter,
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索补丁（共 ${lib.patches.length} 个）',
              prefixIcon: const Icon(Icons.search, size: 20),
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final p = list[i];
              final installed = isPatchInstalled(p, widget.edit.data);
              return ListTile(
                leading: Icon(
                  installed ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: installed ? Colors.green : Colors.grey,
                ),
                title: Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: p.info.isEmpty
                    ? null
                    : Text(p.info.split('\n').first,
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12)),
                trailing: installed
                    ? const Text('已安装', style: TextStyle(fontSize: 12, color: Colors.green))
                    : TextButton(
                        onPressed: () => _install(p),
                        child: const Text('安装'),
                      ),
                onTap: () => _showDetail(p),
              );
            },
          ),
        ),
      ],
    );
  }

  void _showDetail(FePatch p) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(p.name),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (p.info.isNotEmpty) Text(p.info),
              if (p.author.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('作者：${p.author}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ],
              const SizedBox(height: 12),
              Text('写入位置：${p.writes.length} 处',
                  style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          if (!isPatchInstalled(p, widget.edit.data))
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _install(p);
              },
              child: const Text('安装'),
            ),
        ],
      ),
    );
  }

  Future<void> _install(FePatch p) async {
    final e = widget.edit;
    final before = Uint8List.fromList(e.data);
    final result = await applyPatch(p, e.data);
    if (!mounted) return;
    if (!result.ok) {
      e.data.setAll(0, before);
      _toast(result.message);
      return;
    }
    for (final u in result.undo) {
      for (var i = 0; i < u.before.length; i++) {
        e.edits.add(ByteEdit(
          u.offset + i,
          u.before[i],
          e.data[u.offset + i],
        ));
      }
    }
    setState(() => _changed = true);
    _toast('已安装 ${p.name}');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }
}
