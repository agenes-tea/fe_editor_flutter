import 'package:flutter/material.dart';

import '../core/app_log.dart';
import '../core/app_settings.dart';
import '../core/mcp_service.dart';
import 'mcp_panel.dart';

/// 设置页。
///
/// - 「覆盖模式」：对齐口袋改版工具盒的习惯，保存时直接写回原 ROM，
///   而不是生成 `_modified` 副本。
/// - 「外观」：浅色 / 暗色 / 跟随系统，切换即时生效并持久化。
/// - 「MCP」：状态摘要卡片，点开弹圆形图标面板（[McpMenuPanel]），
///   面板内集中管理 启停 / 地址 / 局域网 / Token。
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

  static const _themeLabels = ['跟随系统', '浅色', '暗色'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mcp = McpService.instance;
    final mcpOn = mcp.running;
    final mcpPort = mcp.port;
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Material(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () async {
                  await showMcpMenuPanel(context);
                  if (mounted) setState(() {});
                },
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: mcpOn
                              ? Colors.green.withAlpha(30)
                              : Colors.grey.withAlpha(30),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          mcpOn ? Icons.cloud_done : Icons.cloud_off,
                          size: 22,
                          color: mcpOn
                              ? Colors.green
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              mcpOn
                                  ? 'MCP 服务运行中 · 端口 $mcpPort'
                                  : 'MCP 服务已停止',
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              mcpOn
                                  ? '把连接地址填进 AI 客户端即可读写当前 ROM'
                                  : '开启后可让 AI 客户端读写当前打开的 ROM',
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right,
                          color: theme.colorScheme.onSurfaceVariant),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '点上面卡片打开 MCP 面板：圆形图标管理「运行 / 地址 / 局域网 / Token」，'
              '「MCP 地址」里可一键复制连接信息。\n\n'
              '所有改动与界面共用一个 ROM 缓冲区：客户端改了字节，界面上的'
              '「已修改」计数会跟着涨，也能用「撤销全部修改」还原。\n\n'
              'App 申请网络权限只用于 MCP 的本机回环 / 局域网调试，'
              '不向任何外部服务器发送你的 ROM 或个人信息。',
              style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5),
            ),
          ),
        ],
      ),
    );
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
