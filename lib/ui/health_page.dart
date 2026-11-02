import 'package:flutter/material.dart';

import '../core/editable_rom.dart';
import '../core/rom_health.dart';

/// ROM 体检报告：静态可判定的结构问题。
///
/// 与 MCP 的 `validate_rom` 共用 [RomHealth]，所以 AI 与用户看到的是同一份结论。
/// 体检只读数据、不写 ROM，改完任何东西都可以随时点「重新体检」。
class HealthPage extends StatefulWidget {
  final EditableRom edit;

  const HealthPage({super.key, required this.edit});

  @override
  State<HealthPage> createState() => _HealthPageState();
}

class _HealthPageState extends State<HealthPage> {
  HealthReport? _report;
  bool _running = false;
  bool _deep = true;

  @override
  void initState() {
    super.initState();
    _run();
  }

  void _run() {
    setState(() => _running = true);
    final report = RomHealth(widget.edit).run(deep: _deep);
    if (!mounted) return;
    setState(() {
      _report = report;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = _report;
    return Scaffold(
      appBar: AppBar(
        title: const Text('ROM 体检'),
        actions: [
          IconButton(
            tooltip: '重新体检',
            onPressed: _running ? null : _run,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _running && report == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _summaryCard(theme, report),
                const SizedBox(height: 12),
                SwitchListTile(
                  value: _deep,
                  onChanged: (v) {
                    setState(() => _deep = v);
                    _run();
                  },
                  title: const Text('深检'),
                  subtitle: const Text('检查各章单位坐标与支援引用（约 1~2 秒）；'
                      '关闭后只查表结构与 ID 连续性'),
                ),
                const SizedBox(height: 8),
                if (report != null && report.issues.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      children: [
                        Icon(Icons.verified_outlined,
                            size: 48, color: theme.colorScheme.primary),
                        const SizedBox(height: 8),
                        Text('没有发现问题', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 4),
                        Text(
                          '表结构、ID 连续性、章节单位都在预期范围内。',
                          style: theme.textTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                if (report != null)
                  for (final issue in report.issues) _issueTile(theme, issue),
              ],
            ),
    );
  }

  Widget _summaryCard(ThemeData theme, HealthReport? report) {
    final errors = report?.errorCount ?? 0;
    final warns = report?.warningCount ?? 0;
    final ok = report?.ok ?? false;
    final color = ok
        ? (warns > 0 ? Colors.orange : Colors.green)
        : theme.colorScheme.error;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              ok
                  ? (warns > 0 ? Icons.warning_amber : Icons.check_circle_outline)
                  : Icons.error_outline,
              color: color,
              size: 32,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ok ? (warns > 0 ? '有警告' : '结构正常') : '发现致命问题',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: color, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '致命 $errors 项 · 警告 $warns 项',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _issueTile(ThemeData theme, HealthIssue issue) {
    final (icon, color) = switch (issue.level) {
      HealthLevel.error => (Icons.error_outline, theme.colorScheme.error),
      HealthLevel.warn => (Icons.warning_amber, Colors.orange),
      HealthLevel.info => (Icons.info_outline, theme.colorScheme.outline),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(issue.area, style: theme.textTheme.titleSmall),
        subtitle: Text(issue.message),
      ),
    );
  }
}
