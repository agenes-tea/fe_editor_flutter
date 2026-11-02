import 'package:flutter/material.dart';

import '../core/external_workspace.dart';

/// 外部工作区里的 ROM 列表。
///
/// 用途：把 ROM 放在设备上一个固定目录里，App 记住这个目录，
/// 每次进来直接列出来点一下就能打开，不必反复走系统文件选择器。
///
/// 选中返回 [WorkspaceRom]，取消返回 null。
class WorkspacePage extends StatefulWidget {
  const WorkspacePage({super.key});

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  List<WorkspaceRom>? _roms;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _error = null);
    if (!ExternalWorkspace.instance.configured) {
      setState(() => _roms = const []);
      return;
    }
    final list = await ExternalWorkspace.instance.listRoms();
    if (mounted) setState(() => _roms = list);
  }

  Future<void> _pickDir() async {
    setState(() => _busy = true);
    try {
      final d = await pickWorkspaceDir();
      if (d == null) return;
      await _refresh();
    } catch (e) {
      // 选目录失败不能闪退：把原因说清楚（授权失效/目录不支持等）
      if (mounted) setState(() => _error = '选择目录失败：${_reason(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _reason(Object e) {
    final text = e.toString();
    if (text.contains('NO_PERSIST')) {
      return '这个位置不支持长期授权。请换一个目录（如「文档」或 SD 卡根目录下的文件夹）。';
    }
    if (text.contains('Unsupported Uri')) {
      return '这个目录不支持访问，请换一个目录。';
    }
    return text.replaceFirst('PlatformException(', '');
  }

  Future<void> _clear() async {
    await ExternalWorkspace.instance.clear();
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final dir = ExternalWorkspace.instance.dir;
    return Scaffold(
      appBar: AppBar(
        title: const Text('外部工作区'),
        actions: [
          if (dir != null)
            IconButton(
              tooltip: '更换目录',
              icon: const Icon(Icons.drive_file_move_outline),
              onPressed: _busy ? null : _pickDir,
            ),
          if (dir != null)
            IconButton(
              tooltip: '取消工作区',
              icon: const Icon(Icons.link_off),
              onPressed: _clear,
            ),
        ],
      ),
      body: _buildBody(dir),
    );
  }

  Widget _buildBody(WorkspaceDir? dir) {
    if (dir == null) return _buildSetup();
    final roms = _roms;
    if (roms == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.folder_open),
            title: Text(dir.name),
            subtitle: const Text('已授权，重启 App 后仍然有效'),
            trailing: _busy
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : IconButton(
                    tooltip: '刷新',
                    icon: const Icon(Icons.refresh),
                    onPressed: _refresh,
                  ),
          ),
        ),
        const SizedBox(height: 8),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_error!, style: TextStyle(color: Colors.red.shade700)),
          ),
        if (roms.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(Icons.inbox, size: 56, color: Colors.grey.shade400),
                const SizedBox(height: 12),
                const Text('这个目录里没有 ROM'),
                const SizedBox(height: 4),
                Text(
                  '把 .gba 文件放进「${dir.name}」，再点右上角刷新',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          )
        else
          ...roms.map((r) => Card(
                child: ListTile(
                  leading: const Icon(Icons.videogame_asset),
                  title: Text(r.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(r.sizeLabel),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(context, r),
                ),
              )),
      ],
    );
  }

  Widget _buildSetup() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_special, size: 72, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            const Text('设置一个工作区目录',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              '选一个放 ROM 的目录，App 会记住它：\n'
              '以后每次进来直接列出里面的 ROM，点一下就能打开；\n'
              'AI 通过 MCP 也能看到这个目录里有哪些 ROM，自己挑基底。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade700, height: 1.5),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy ? null : _pickDir,
              icon: const Icon(Icons.folder_open),
              label: Text(_busy ? '等待选择…' : '选择目录'),
            ),
            const SizedBox(height: 12),
            Text(
              '建议把 ROM 放在「文档」或 SD 卡根目录下的一个文件夹里。\n'
              '系统会要求授权访问该目录，授权一次长期有效。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: TextStyle(color: Colors.red.shade700)),
            ],
          ],
        ),
      ),
    );
  }
}
