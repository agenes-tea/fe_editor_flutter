import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../core/mcp_service.dart';

/// MCP 的圆形图标面板 + 地址弹窗。
///
/// 交互参照「AI 浏览器」的做法：
/// - [McpMenuPanel]：4 列圆形图标网格，图标即开关/入口（MCP 运行、MCP 地址、
///   局域网、生成 Token），点图标直接操作，运行态用绿色、停用灰色。
/// - [showMcpMenuPanel]：从底部弹出 [McpMenuPanel] 的便捷入口。
/// - [showMcpAddressDialog]：集中展示「本机 / 局域网 / Token」三条连接信息，
///   逐条可复制，供用户填进 AI 客户端。
///
/// 数据全部来自 [McpService] 单例；操作后 [McpMenuPanel] 本地 `setState` 刷新，
/// 不引入 Provider（项目约定零第三方状态库）。

/// 底部弹出圆形图标面板。
Future<void> showMcpMenuPanel(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const McpMenuPanel(),
  );
}

/// 弹出「MCP 地址」对话框。服务未运行时给 SnackBar 提示先启动。
Future<void> showMcpAddressDialog(BuildContext context,
    {required bool running,
    required int port,
    required bool lan,
    required String token,
    required List<String> addresses}) {
  if (!running) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('MCP 服务未启动，先点「MCP 运行」启动')),
    );
    return Future.value();
  }
  return showDialog(
    context: context,
    builder: (_) => _McpAddressDialog(
      port: port,
      lan: lan,
      token: token,
      addresses: addresses,
    ),
  );
}

/// 圆形图标网格面板。
class McpMenuPanel extends StatefulWidget {
  const McpMenuPanel({super.key});

  @override
  State<McpMenuPanel> createState() => _McpMenuPanelState();
}

class _McpMenuPanelState extends State<McpMenuPanel> {
  final _svc = McpService.instance;
  bool _on = false;
  int _port = 0;
  bool _allowLan = false;
  String _token = '';
  List<String> _addresses = const [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 读单例最新状态 + 地址列表。
  Future<void> _reload() async {
    final s = McpService.instance;
    if (!s.running) {
      _addresses = const [];
    } else {
      _addresses = await s.addresses();
    }
    if (!mounted) return;
    setState(() {
      _on = s.running;
      _port = s.port;
      _allowLan = s.allowLan;
      _token = s.token;
      _error = s.lastError;
    });
  }

  Future<void> _toggleMcp() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_on) {
        await _svc.stop();
        _on = false;
      } else {
        _port = await _svc.start();
        _on = _port > 0;
      }
      if (!mounted) return;
      await _reload();
    } finally {
      // **必须复位**：不复位的话三个按钮的 `if (_busy) return` 会永久失效，
      // 面板看起来就是「怎么点都点不动」（实测踩到）。
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleLan() async {
    if (_busy) return;
    final turningOn = !_allowLan;
    // 开局域网且未设 Token 时先弹风险确认：绑 0.0.0.0 后同 Wi-Fi 下
    // 任何设备都能直接读写这个 ROM，必须让用户知情。
    if (turningOn && _token.isEmpty) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('局域网将无口令开放'),
          content: const Text(
            '当前没有设 Token。开启局域网后，同一 Wi-Fi 下的任何设备'
            '都能直接连接并改写这个 ROM。\n\n'
            '建议先点「生成 Token」再开。确实要在无口令下开放吗？',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('仍然开启')),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      await _svc.stop();
      final t = turningOn ? _token : '';
      await _svc.start(allowLan: turningOn, token: t);
      if (!mounted) return;
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(turningOn ? '局域网访问已开启' : '局域网访问已关闭')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _regenToken() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _svc.stop();
      // 已设 Token 时再点就是「关闭」（置空），否则是「生成」。
      // 否则写死 newToken() 会变成永远只能生成、无法单独关掉。
      final t = _token.isEmpty ? McpService.newToken() : '';
      await _svc.start(allowLan: _allowLan, token: t);
      if (!mounted) return;
      await _reload();
      if (!mounted) return;
      await showMcpAddressDialog(
        context,
        running: _on,
        port: _port,
        lan: _allowLan,
        token: _token,
        addresses: _addresses,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'MCP（给 AI 客户端用）',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              mainAxisSpacing: 14,
              crossAxisSpacing: 10,
              childAspectRatio: 0.85,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _MenuItem(
                  icon: _on ? Icons.cloud_done : Icons.cloud_off,
                  label: _on ? 'MCP 运行' : 'MCP 停止',
                  color: _on ? Colors.green : Colors.grey.shade500,
                  onTap: _busy ? null : _toggleMcp,
                ),
                _MenuItem(
                  icon: Icons.link,
                  label: 'MCP 地址',
                  color: _on ? Colors.green : Colors.grey.shade500,
                  onTap: _busy
                      ? null
                      : () => showMcpAddressDialog(
                            context,
                            running: _on,
                            port: _port,
                            lan: _allowLan,
                            token: _token,
                            addresses: _addresses,
                          ),
                ),
                _MenuItem(
                  icon: Icons.language,
                  label: _allowLan ? '局域网开' : '局域网关',
                  color: _allowLan ? Colors.green : Colors.grey.shade500,
                  onTap: _busy ? null : _toggleLan,
                ),
                _MenuItem(
                  icon: Icons.key,
                  label: _token.isNotEmpty ? 'Token 已开' : '生成 Token',
                  color:
                      _token.isNotEmpty ? Colors.green : Colors.grey.shade500,
                  onTap: _busy ? null : _regenToken,
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.error,
                    height: 1.4,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.center,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 圆形图标 + 文字标签，4 列网格的一项。
class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback? onTap;

  const _MenuItem({
    required this.icon,
    required this.label,
    this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withAlpha(40),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 22, color: color ?? Colors.grey.shade800),
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 11), maxLines: 1),
        ],
      ),
    );
  }
}

/// 「MCP 地址」对话框：本机 / 局域网 / Token 三块，逐条可复制。
class _McpAddressDialog extends StatefulWidget {
  final int port;
  final bool lan;
  final String token;
  final List<String> addresses;

  const _McpAddressDialog({
    required this.port,
    required this.lan,
    required this.token,
    required this.addresses,
  });

  @override
  State<_McpAddressDialog> createState() => _McpAddressDialogState();
}

class _McpAddressDialogState extends State<_McpAddressDialog> {
  String get _local => 'http://127.0.0.1:${widget.port}';

  /// 局域网地址：从地址列表里挑一个非回环 IP；没有就给占位符。
  String get _network {
    for (final a in widget.addresses) {
      if (!a.contains('127.0.0.1')) return a;
    }
    return widget.lan
        ? 'http://<本机IP>:${widget.port}'
        : '（未开局域网，仅本机可连）';
  }

  @override
  Widget build(BuildContext context) {
    final token = widget.token;
    return AlertDialog(
      title: const Text('MCP 地址'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _addrTile(context, '本机', _local),
            const SizedBox(height: 12),
            _addrTile(
                context, widget.lan ? '局域网' : '局域网(未开)', _network),
            if (token.isNotEmpty) ...[
              const SizedBox(height: 12),
              _addrTile(context, 'Token', token),
              const SizedBox(height: 6),
              Text(
                widget.lan
                    ? '局域网开放中，客户端需携带 Authorization: Bearer <token>'
                    : '已设 Token（仅本机 127.0.0.1 需携带；局域网未开放）',
                style: TextStyle(
                    fontSize: 12, color: Colors.grey.shade600),
              ),
            ] else ...[
              const SizedBox(height: 6),
              Text(
                widget.lan
                    ? '局域网开放但未设 Token——存在被局域网任意设备控制的风险，'
                        '请点「生成 Token」'
                    : '未设 Token。本机 127.0.0.1 使用无需鉴权；'
                        '开放局域网前建议先生成 Token。',
                style: const TextStyle(fontSize: 12, color: Colors.orange),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              '在 AI 客户端里填写上面的地址即可连接。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _addrTile(BuildContext ctx, String label, String url) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                url,
                style: const TextStyle(
                    fontSize: 13, fontFamily: 'monospace'),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              tooltip: '复制',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: url));
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text('已复制 $label 地址')),
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}
