import 'package:flutter/material.dart';

import '../core/app_log.dart';
import '../core/app_settings.dart';

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
