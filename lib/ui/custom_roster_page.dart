import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_settings.dart';
import '../core/custom_roster.dart';
import '../core/fe_rom.dart';
import '../core/playable_units.dart';

/// 自定义角色名单页：在某个自动判据的基础上手工增减，然后导出/导入分享。
///
/// 交互约定（v2.3.12）：
/// - 进来时以「当前判据的结果」为初始勾选，可逐个改
/// - **导出**：点一下就把 `1,2,5,12` 写进剪贴板并提示条数，直接贴群里
/// - **导入**：**不弹键盘**，直接读剪贴板，解析出数字后弹确认框
/// - 结果按 ROM 指纹存到设置里，下次打开同一份 ROM 自动恢复
class CustomRosterPage extends StatefulWidget {
  final FeRom rom;
  final PlayableCriterion baseCriterion;
  final CustomRoster initial;

  const CustomRosterPage({
    super.key,
    required this.rom,
    required this.baseCriterion,
    required this.initial,
  });

  @override
  State<CustomRosterPage> createState() => _CustomRosterPageState();
}

class _CustomRosterPageState extends State<CustomRosterPage> {
  late CustomRoster _roster = widget.initial;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  int get _unitCount => widget.rom.unitCount;

  PlayableUnits get _pu => PlayableUnits(widget.rom);

  @override
  Widget build(BuildContext context) {
    final rom = widget.rom;
    final theme = Theme.of(context);
    final rows = <int>[
      for (var i = 0; i < _unitCount; i++)
        if (_query.isEmpty ||
            rom.unitDisplayName(i).toLowerCase().contains(_query) ||
            '$i' == _query)
          i,
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('自定义角色名单'),
        actions: [
          IconButton(
            tooltip: '从剪贴板导入',
            icon: const Icon(Icons.download),
            onPressed: _importFromClipboard,
          ),
          IconButton(
            tooltip: '复制配置',
            icon: const Icon(Icons.copy_all),
            onPressed: _copyToClipboard,
          ),
        ],
      ),
      body: Column(
        children: [
          _header(theme),
          _searchBar(),
          const Divider(height: 1),
          Expanded(child: _list(rows)),
        ],
      ),
    );
  }

  Widget _header(ThemeData theme) {
    final pu = _pu;
    final base = pu.indices(criterion: widget.baseCriterion);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '已选 ${_roster.length} 个角色'
            '（${widget.baseCriterion.label} 基准 ${base.length} 个）',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'ID 就是角色列表里的编号（0 是第一个角色，通常是我方主角）。'
            '导出后可直接贴到群或评论区，别人点「从剪贴板导入」就能复现同一份名单。',
            style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade700),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ActionChip(
                avatar: const Icon(Icons.sync, size: 16),
                label: const Text('恢复为判据结果', style: TextStyle(fontSize: 12)),
                onPressed: () => setState(() => _roster = CustomRoster({...base})),
              ),
              ActionChip(
                avatar: const Icon(Icons.deselect, size: 16),
                label: const Text('全不选', style: TextStyle(fontSize: 12)),
                onPressed: () => setState(() => _roster = CustomRoster.empty),
              ),
              ActionChip(
                avatar: const Icon(Icons.flip_to_back, size: 16),
                label: const Text('反选', style: TextStyle(fontSize: 12)),
                onPressed: () =>
                    setState(() => _roster = _roster.inverted(_unitCount)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: _searchCtrl,
        decoration: const InputDecoration(
          isDense: true,
          hintText: '按名字或 ID 过滤（只影响显示）',
          prefixIcon: Icon(Icons.search, size: 18),
          border: OutlineInputBorder(),
        ),
        onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
      ),
    );
  }

  Widget _list(List<int> rows) {
    final rom = widget.rom;
    final suspects = _pu.ambiguous().toSet();
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (ctx, i) {
        final index = rows[i];
        final name = rom.unitDisplayName(index).trim();
        final checked = _roster.containsIndex(index);
        final suspect = suspects.contains(index);
        return CheckboxListTile(
          value: checked,
          onChanged: (_) => setState(() => _roster = _roster.toggle(index)),
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(
            name.isEmpty ? '（未命名）' : name,
            style: const TextStyle(fontSize: 13),
          ),
          subtitle: Text(
            'ID $index${suspect ? ' · 疑似敌方（无支援数据）' : ''}',
            style: TextStyle(
              fontSize: 11,
              color: suspect ? Colors.orange.shade800 : null,
            ),
          ),
        );
      },
    );
  }

  Future<void> _copyToClipboard() async {
    if (_roster.isEmpty) {
      _toast('名单是空的，先勾几个角色');
      return;
    }
    await Clipboard.setData(ClipboardData(text: _roster.exportText()));
    // 同时落盘，换页面/重开 App 都不丢
    await AppSettings.instance.setRoster(widget.rom.fingerprint, _roster);
    _toast('已复制 ${_roster.length} 个角色 ID，快去群里分享吧！');
  }

  Future<void> _importFromClipboard() async {
    String? text;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text;
    } catch (_) {
      text = null;
    }
    if (text == null || text.trim().isEmpty) {
      _toast('剪贴板是空的');
      return;
    }
    final parsed = CustomRoster.parseAndFilter(text, unitCount: _unitCount);
    if (parsed.ids.isEmpty) {
      _toast('剪贴板里没找到有效的角色 ID');
      return;
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从剪贴板导入'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('识别到 ${parsed.ids.length} 个角色 ID'),
              if (parsed.dropped > 0) ...[
                const SizedBox(height: 6),
                Text(
                  '其中 ${parsed.dropped} 个超出范围'
                  '（合法 0~${_unitCount - 1}）已忽略',
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                '将覆盖当前勾选（现为 ${_roster.length} 个）。',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('覆盖'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _roster = CustomRoster(parsed.ids.toSet()));
    await AppSettings.instance.setRoster(widget.rom.fingerprint, _roster);
    _toast('已导入 ${parsed.ids.length} 个角色');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }
}
