import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_log.dart';

/// 应用日志查看：最新在上，可一键复制全部（发给我们排查）、清空。
class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  late List<LogEntry> _entries = AppLog.instance.snapshot();

  @override
  void initState() {
    super.initState();
    // 进页时把日志文件挂上（设备端首次打开才真正开始写盘）
    AppLog.instance.attachFile();
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: AppLog.instance.allText()));
    if (!mounted) return;
    _toast('已复制全部日志（${_entries.length} 条），粘贴发给开发者即可');
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('清空后内存与设备端的日志都会删除，继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await AppLog.instance.clear();
    if (!mounted) return;
    setState(() => _entries = AppLog.instance.snapshot());
    _toast('日志已清空');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final file = AppLog.instance.filePath;
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志'),
        actions: [
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy_all, size: 20),
            onPressed: _copyAll,
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: _clear,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              file == null ? '日志目前只在内存中（重启后丢失）' : '日志文件：$file',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          if (_entries.isEmpty)
            const Expanded(
              child: Center(
                child: Text('（还没有日志）', style: TextStyle(color: Colors.grey)),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                // 倒序：最新的在最上面
                reverse: true,
                itemCount: _entries.length,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemBuilder: (ctx, i) {
                  final e = _entries[_entries.length - 1 - i];
                  final line = e.line();
                  final isErr = e.level.toLowerCase() == 'error';
                  final headEnd = line.indexOf(']') + 1;
                  return InkWell(
                    onTap: () => _showEntry(e),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            headEnd > 0 ? line.substring(0, headEnd) : line,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: isErr ? FontWeight.bold : null,
                              color: isErr ? Colors.red.shade800 : Colors.grey,
                            ),
                          ),
                          const SizedBox(height: 2),
                          SelectableText(
                            e.message,
                            style: TextStyle(
                              fontSize: 13,
                              color: isErr ? Colors.red.shade900 : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  void _showEntry(LogEntry e) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        content: SelectableText(e.line()),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: e.line()));
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
            },
            child: const Text('复制'),
          ),
        ],
      ),
    );
  }
}
