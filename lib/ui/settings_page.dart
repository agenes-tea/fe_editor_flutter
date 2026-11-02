import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../core/app_log.dart';
import '../core/app_settings.dart';
import '../core/mcp_service.dart';

/// 设置页。
///
/// - 「覆盖模式」：对齐口袋改版工具盒的习惯，保存时直接写回原 ROM，
///   而不是生成 `_modified` 副本。
/// - 「外观」：浅色 / 暗色 / 跟随系统，切换即时生效并持久化。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 本地状态：开关立即反映点击，落盘在后台进行。
  /// 直接读单例的话，异步写入完成前后 UI 不会重建（表现为「点了没反应」）。
  late bool _on = AppSettings.instance.overwriteMode;
  late int _mode = AppSettings.instance.themeModeIndex;

  /// MCP 服务是否在跑（与端口一起显示，方便复制到客户端配置里）。
  late bool _mcpOn = McpService.instance.running;
  int _mcpPort = McpService.instance.port;
  bool _mcpBusy = false;
  String? _mcpError;
  bool _allowLan = McpService.instance.allowLan;
  String _mcpToken = '';
  List<String> _mcpAddresses = const [];

  static const _themeLabels = ['跟随系统', '浅色', '暗色'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          _sectionHeader(context, '保存'),
          SwitchListTile(
            value: _on,
            onChanged: (v) {
              setState(() => _on = v);
              AppSettings.instance.setOverwriteMode(v);
              AppLog.instance.log('info', '设置：覆盖模式 ${v ? '开启' : '关闭'}');
            },
            title: const Text('覆盖模式'),
            subtitle: const Text(
              '开启后「保存 ROM」直接覆盖原文件，不会生成新文件（patched）。\\n'
              '请自行做好备份——覆盖后无法用本工具还原。',
            ),
            isThreeLine: true,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              '说明：覆盖写回的是「打开 ROM」时选中的那个文件。'
              '如果选中的文件所在目录不可写（例如只读的系统位置），会提示写入失败，'
              '此时请关闭覆盖模式改用另存为。',
              style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5),
            ),
          ),
          const Divider(height: 24),
          _sectionHeader(context, '外观'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<int>(
              segments: [
                for (var i = 0; i < _themeLabels.length; i++)
                  ButtonSegment(value: i, label: Text(_themeLabels[i])),
              ],
              selected: {_mode},
              onSelectionChanged: (s) {
                final i = s.first;
                setState(() => _mode = i);
                AppSettings.instance.setThemeMode(i);
                AppLog.instance.log('info', '设置：主题 ${_themeLabels[i]}');
              },
            ),
          ),
          const Divider(height: 24),
          _sectionHeader(context, 'MCP（给 AI 客户端用）'),
          SwitchListTile(
            value: _mcpOn,
            onChanged: _mcpBusy ? null : _toggleMcp,
            title: const Text('启动 MCP 服务器'),
            subtitle: Text(_mcpOn
                ? '监听 http://127.0.0.1:$_mcpPort（仅本机可访问）\\n'
                    '把该地址填进 MCP 客户端即可读写当前打开的 ROM'
                : '开启后，AI 客户端可以通过 MCP 协议读取与修改当前打开的 ROM'),
            isThreeLine: true,
          ),
          if (_mcpOn)
            SwitchListTile(
              value: _allowLan,
              onChanged: (v) async {
                await McpService.instance.stop();
                final t = v
                    ? (_mcpToken.isEmpty ? McpService.newToken() : _mcpToken)
                    : '';
                setState(() {
                  _allowLan = v;
                  _mcpToken = t;
                });
                final p = await McpService.instance.start(
                    allowLan: v, token: t);
                if (!mounted) return;
                setState(() {
                  _mcpOn = p > 0;
                  _mcpPort = p;
                  _mcpToken = McpService.instance.token;
                });
                if (p > 0) await _refreshAddresses();
              },
              title: const Text('允许局域网访问'),
              subtitle: const Text(
                '开启后同一 Wi-Fi 下的电脑才能连（地址会变成手机 IP）。'
                '此时必须带访问口令，否则任何人都能改你的 ROM。默认关闭。',
              ),
              isThreeLine: true,
            ),
          if (_mcpError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _mcpError!,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onErrorContainer,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          if (_mcpOn)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('MCP 地址（点一下复制）',
                        style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    for (final addr in _mcpAddresses)
                      InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: addr));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('已复制 $addr')),
                          );
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(addr,
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    if (_mcpToken.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text('访问口令（客户端必须带）',
                          style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant)),
                      Row(
                        children: [
                          Expanded(
                            child: SelectableText(_mcpToken,
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.bold)),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: '换一个口令',
                            icon: const Icon(Icons.refresh, size: 18),
                            onPressed: () async {
                              await McpService.instance.stop();
                              final t = McpService.newToken();
                              setState(() => _mcpToken = t);
                              final p = await McpService.instance.start(
                                  allowLan: _allowLan, token: t);
                              if (!mounted) return;
                              setState(() {
                                _mcpOn = p > 0;
                                _mcpPort = p;
                              });
                              await _refreshAddresses();
                            },
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      '所有改动与界面共用一个 ROM 缓冲区：客户端改了字节，'
                      '界面上的「已修改」计数会跟着涨，也能用「撤销全部修改」还原。'
                      '\n\nApp 申请网络权限只用于 MCP 的本机回环 / 局域网调试，'
                      '不向任何外部服务器发送你的 ROM 或个人信息。',
                      style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.5),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _toggleMcp(bool value) async {
    setState(() => _mcpBusy = true);
    if (value) {
      final port = await McpService.instance.start();
      if (!mounted) return;
      setState(() {
        _mcpBusy = false;
        _mcpOn = port > 0;
        _mcpPort = port;
        _mcpToken = McpService.instance.token;
        _allowLan = McpService.instance.allowLan;
      });
      if (port > 0) await _refreshAddresses();
      if (port == 0) {
        final reason = McpService.instance.lastError ?? '未知原因';
        setState(() => _mcpError = reason);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('MCP 启动失败：$reason')),
        );
      } else {
        setState(() => _mcpError = null);
      }
    } else {
      await McpService.instance.stop();
      if (!mounted) return;
      setState(() {
        _mcpBusy = false;
        _mcpOn = false;
        _mcpPort = 0;
        _mcpError = null;
      });
    }
  }

  Future<void> _refreshAddresses() async {
    final list = await McpService.instance.addresses();
    if (!mounted) return;
    setState(() => _mcpAddresses = list);
  }

  Widget _sectionHeader(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
