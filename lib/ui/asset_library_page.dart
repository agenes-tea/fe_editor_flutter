import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/asset_library.dart';
import '../core/editable_rom.dart';
import '../core/external_workspace.dart' show WorkspaceDir, WorkspaceRom;
import '../core/portrait.dart';
import '../core/portrait_import.dart';
import '../core/portrait_porter.dart';
import 'portrait_page.dart' show PortraitImageCache;

/// 素材库页：管理一个设备目录，用来存导出的肖像 / 战斗动画帧 / 图标等。
///
/// 与「工作区」分开——工作区只装 ROM。
/// 传了 [edit]（有打开的 ROM）时，PNG 条目可以一步导进该 ROM 的肖像表。
class AssetLibraryPage extends StatefulWidget {
  /// 当前编辑的 ROM；为 null 时只能看和导出，不能导回游戏。
  final EditableRom? edit;

  const AssetLibraryPage({super.key, this.edit});

  @override
  State<AssetLibraryPage> createState() => _AssetLibraryPageState();
}

class _AssetLibraryPageState extends State<AssetLibraryPage> {
  List<WorkspaceRom>? _assets;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _error = null);
    if (!AssetLibrary.instance.configured) {
      await AssetLibrary.instance.load();
    }
    if (!AssetLibrary.instance.configured) {
      setState(() => _assets = const []);
      return;
    }
    setState(() => _busy = true);
    final list = await AssetLibrary.instance.list();
    if (!mounted) return;
    setState(() {
      _assets = list;
      _busy = false;
      _error = AssetLibrary.instance.lastError;
    });
  }

  Future<void> _pickDir() async {
    try {
      final d = await AssetLibrary.instance.pick();
      if (!mounted) return;
      if (d == null) return;
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = AssetLibrary.instance.lastError ?? '$e');
    }
  }

  Future<void> _clearDir() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消素材库？'),
        content: const Text('只撤销本应用的目录访问权限，**不会删除目录里的文件**。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) return;
    await AssetLibrary.instance.clear();
    await _refresh();
  }

  Future<void> _preview(WorkspaceRom file) async {
    final bytes = await AssetLibrary.instance.read(file.name);
    if (!mounted) return;
    if (bytes == null) {
      _toast('读不出来：${AssetLibrary.instance.lastError ?? '文件可能已被移走'}');
      return;
    }
    final isPng = file.name.toLowerCase().endsWith('.png');
    if (!isPng) {
      _toast('${file.name} · ${bytes.length} 字节（非图片，不能预览）');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(file.name,
                  style: const TextStyle(fontSize: 13),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
            Flexible(
              child: InteractiveViewer(
                maxScale: 8,
                child: Image.memory(
                  Uint8List.fromList(bytes),
                  filterQuality: FilterQuality.none,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('关闭'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 把素材库里的 PNG 导进当前 ROM 的某条肖像。
  Future<void> _importToGame(WorkspaceRom file) async {
    final edit = widget.edit;
    if (edit == null) return;
    final bytes = await AssetLibrary.instance.read(file.name);
    if (!mounted) return;
    if (bytes == null) {
      _toast('读不出来：${AssetLibrary.instance.lastError ?? '文件可能已被移走'}');
      return;
    }
    final rgba = PngDecoder.decodeRgba(bytes);
    if (rgba == null) {
      _toast('这张图不是可解码的 PNG');
      return;
    }
    final w = _pngWidth(bytes);
    if (w <= 0 || rgba.length ~/ 4 % w != 0) {
      _toast('PNG 宽高信息异常');
      return;
    }
    final h = (rgba.length ~/ 4) ~/ w;

    final target = await _askTarget(edit);
    if (target == null || !mounted) return;

    setState(() => _busy = true);
    final conv = PortraitImporter.convertRgba(
      rgba,
      w,
      h,
      fe6: edit.rom.table.portraitDataSize == 16,
      mapFace: true,
    );
    final out = PortraitPorter(edit).importFace(conv, target,
        fixedExpression: true, replaceMapFace: true);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!out.ok) {
      _toast('写入失败：${out.message}');
      return;
    }
    PortraitImageCache.instance.invalidate();
    _toast('已写入第 $target 条肖像（${out.bytesWritten} 字节）');
  }

  static int _pngWidth(Uint8List png) {
    if (png.length < 24) return 0;
    return (png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19];
  }

  /// 让用户选「写到哪一条肖像」。
  Future<int?> _askTarget(EditableRom edit) async {
    final reader = PortraitReader(edit.liveRom);
    final count = reader.entryCount;
    reader.dispose();
    if (count <= 0) {
      _toast('这个 ROM 的肖像表定位不到');
      return null;
    }
    final ctrl = TextEditingController(text: '1');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('写到哪一条肖像'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('这个 ROM 共 $count 条肖像（编号 0 ~ ${count - 1}）',
                style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '目标编号',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('写入')),
        ],
      ),
    );
    final v = int.tryParse(ctrl.text.trim());
    ctrl.dispose();
    if (ok != true || v == null) return null;
    if (v < 0 || v >= count) {
      _toast('编号 $v 超出范围（0 ~ ${count - 1}）');
      return null;
    }
    return v;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dir = AssetLibrary.instance.dir;

    return Scaffold(
      appBar: AppBar(
        title: const Text('素材库'),
        actions: [
          if (dir != null) ...[
            IconButton(
              tooltip: '刷新',
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: '取消目录授权',
              onPressed: _clearDir,
              icon: const Icon(Icons.link_off),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          _dirCard(dir),
          if (_error != null)
            Container(
              width: double.infinity,
              color: scheme.errorContainer,
              padding: const EdgeInsets.all(10),
              child: Text(
                _error!,
                style: TextStyle(
                    fontSize: 12, color: scheme.onErrorContainer),
              ),
            ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _body(dir)),
        ],
      ),
    );
  }

  Widget _dirCard(WorkspaceDir? dir) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.photo_library_outlined,
                    size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    dir == null ? '还没有选择素材库目录' : dir.name,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                FilledButton.tonal(
                  onPressed: _pickDir,
                  child: Text(dir == null ? '选择目录' : '更换'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              dir == null
                  ? '选一个设备上的目录（如「文档/纹章修改器素材」）。'
                      '导出的肖像、战斗动画帧会直接存进去，下次不用再弹系统文件框。'
                  : '导出素材时会写进这个目录；同名文件原地覆盖。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(WorkspaceDir? dir) {
    if (dir == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '先选一个目录，导出素材时就会存到这里。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ),
      );
    }
    final assets = _assets;
    if (assets == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (assets.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '这个目录里还没有素材。\n'
            '在肖像 / 战斗动画页点「存入素材库」就会出现在这里。',
            textAlign: TextAlign.center,
            style: TextStyle(height: 1.6, color: Colors.grey.shade600),
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: assets.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final f = assets[i];
        final isPng = f.name.toLowerCase().endsWith('.png');
        return ListTile(
          dense: true,
          leading: Icon(
            isPng ? Icons.image_outlined : Icons.insert_drive_file_outlined,
            size: 20,
          ),
          title: Text(f.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13)),
          subtitle: Text(
            f.size < 0
                ? '大小未知'
                : '${(f.size / 1024).toStringAsFixed(1)} KB',
            style: const TextStyle(fontSize: 11),
          ),
          onTap: () => _preview(f),
          trailing: (isPng && widget.edit != null)
              ? IconButton(
                  tooltip: '导入到这个 ROM 的肖像表',
                  icon: const Icon(Icons.download_outlined, size: 20),
                  onPressed: _busy ? null : () => _importToGame(f),
                )
              : null,
        );
      },
    );
  }
}
