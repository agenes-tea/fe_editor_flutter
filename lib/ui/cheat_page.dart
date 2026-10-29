import 'package:flutter/material.dart';

import '../core/app_log.dart';
import '../core/app_settings.dart';
import '../core/cheat_presets.dart';
import '../core/custom_roster.dart';
import '../core/editable_rom.dart';
import '../core/feature_flags.dart';
import '../core/game_debugger.dart';
import '../core/playable_units.dart';
import 'custom_roster_page.dart';
import 'game_debugger_page.dart';

/// 内置修改器：预设批量修改项，一键写入内存副本。
///
/// 所有改动都记在 [EditableRom.edits] 里，可整体撤销；
/// 真正的落盘仍走主页的「导出」，与手工改字段是同一套流程。
///
/// 角色类预设默认只作用在**我方角色**上（口径见 [PlayableCriterion]），
/// 可以在页面顶部换口径——全表加满会把敌方也一起加强。
class CheatListPage extends StatefulWidget {
  final EditableRom edit;

  const CheatListPage({super.key, required this.edit});

  @override
  State<CheatListPage> createState() => _CheatListPageState();
}

class _CheatListPageState extends State<CheatListPage> {
  PlayableCriterion _criterion = PlayableCriterion.reciprocal;

  bool get _canEdit => versionSupportsEditing(widget.edit.rom.table.id);

  /// 带章节出场名单的判据数据源（章节扫描较贵，只算一次）。
  late final PlayableUnits _playable = playableUnitsOf(widget.edit.rom);

  /// 自定义名单（玩家手工勾选）。为空时完全按 [_criterion] 走。
  ///
  /// 用 ROM 指纹从设置里取，保证同一份 ROM 下次进来还在。
  CustomRoster get _custom =>
      AppSettings.instance.rosterFor(widget.edit.rom.fingerprint);

  /// 判据 + 自定义名单的叠加结果。
  RosterScope get _scope =>
      RosterScope(criterion: _criterion, custom: _custom);

  Future<void> _openCustomRoster() async {
    final rom = widget.edit.rom;
    final existing = _custom;
    final initial = existing.isEmpty
        ? CustomRoster({
            ..._playable.indices(criterion: _criterion),
          })
        : existing;
    final result = await Navigator.push<CustomRoster>(
      context,
      MaterialPageRoute(
        builder: (_) => CustomRosterPage(
          rom: rom,
          baseCriterion: _criterion,
          initial: initial,
        ),
      ),
    );
    // 页面返回时已落盘；这里只要刷新（也可以从结果里读）
    if (!mounted) return;
    setState(() {});
    if (result != null) {
      await AppSettings.instance.setRoster(rom.fingerprint, result);
      if (mounted) setState(() {});
    }
  }

  Future<void> _apply(CheatPreset preset) async {
    final edit = widget.edit;
    final fe6 = edit.rom.isFe6;
    final values = resolveValues(preset, fe6: fe6);
    final criterion =
        preset.scopeSelectable ? _criterion : PlayableCriterion.reciprocal;
    final count = cheatEntryCount(preset, edit.rom,
        criterion: criterion, playable: _playable, custom: _custom);

    // 第 5 层保障：当前口径是否会带入「有图鉴排序但无支援数据」的疑似敌方。
    // 我方几个口径（reciprocal/supportData/deployed）不会命中这批；只有手动选了
    // 「按图鉴排序 / 全表」时才非空，写入前逐个点名拦截。
    final pu = _playable;
    final targets = _scope.effective(pu);
    final suspects = preset.target == CheatTarget.unit ||
            preset.target == CheatTarget.support
        ? pu.enemySuspects(targets)
        : const <int>[];

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(preset.title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(preset.description),
              const SizedBox(height: 12),
              Text(
                preset.scopeSelectable
                    ? '作用范围：${_scope.describe(_playable)}，$count 条'
                    : '影响 ${preset.target.label}：$count 条',
                style: const TextStyle(fontSize: 13),
              ),
              if (criterion == PlayableCriterion.all) ...[
                const SizedBox(height: 6),
                Text(
                  '注意：全表包含敌方与 NPC，加满会连同敌人一起加强。',
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
                ),
              ],
              if (suspects.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '以下角色没有支援数据、大概率是敌方，当前口径会连同修改：\n'
                  '${suspects.take(10).map((i) => edit.rom.unitDisplayName(i).trim()).join('、')}'
                  '${suspects.length > 10 ? ' 等 ${suspects.length} 个' : ''}。\n'
                  '只改我方请切回「仅我方角色」。',
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
                ),
              ],
              if (preset.target == CheatTarget.support &&
                  preset.id == 'support_all_a') ...[
                const SizedBox(height: 6),
                Text(
                  '注意：支援等级决定结局里的双人配对，全部设为 A 可能改变结局。'
                  '对正常流程的战斗没有影响。',
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
                ),
              ],
              const SizedBox(height: 8),
              for (final e in values.entries)
                Text('· ${e.key} → ${e.value}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 12),
              const Text(
                '改动只作用于内存副本，可随时撤销；导出时才写入文件。',
                style: TextStyle(fontSize: 12, color: Colors.blueGrey),
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
            child: const Text('应用'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final result = applyCheat(edit, preset,
        criterion: criterion, playable: _playable, custom: _custom);
    AppLog.instance.log(
        'info',
        '修改器 ${preset.title}（${_scope.describe(_playable)}）：'
            '修改 ${result.changedEntries} 条 / ${result.changedBytes} 字节'
            '${result.skipped.isEmpty ? '' : '，跳过：${result.skipped.join('；')}'}');
    setState(() {});
    _toast(result.changedBytes == 0
        ? '没有需要修改的内容（已经是目标值）'
        : '已修改 ${result.changedEntries} 条 / ${result.changedBytes} 字节');
  }

  void _revertAll() {
    widget.edit.revertAll();
    AppLog.instance.log('info', '修改器：撤销全部修改');
    setState(() {});
    _toast('已撤销全部修改');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final edit = widget.edit;
    return Scaffold(
      appBar: AppBar(
        title: const Text('修改器'),
        actions: [
          if (edit.hasChanges)
            TextButton.icon(
              onPressed: _revertAll,
              icon: const Icon(Icons.undo, size: 18),
              label: const Text('撤销全部'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (!_canEdit)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Text(
                '当前版本（${edit.rom.table.id}）不支持字段写入，'
                '修改器暂不可用。',
                style: TextStyle(color: Colors.orange.shade900, fontSize: 13),
              ),
            ),
          if (edit.hasChanges)
            Padding(
              padding: const EdgeInsets.only(bottom: 12, left: 4),
              child: Text(
                '当前已修改 ${edit.changedByteCount} 字节（内存中，尚未导出）',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          _scopeCard(),
          const SizedBox(height: 4),
          if (Features.gameDebugger && gameDebuggerSupports(edit.rom.table))
            ..._debuggerCard(),
          for (final group in CheatTarget.values) ..._presetGroup(group),
        ],
      ),
    );
  }

  /// 「游戏内调试器」入口卡片。
  ///
  /// 它不走按字段写入那套机制（要往固定地址打整段补丁），所以单独一项。
  List<Widget> _debuggerCard() => [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
          child: Text(
            '进阶',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.terminal_outlined),
            title: const Text('游戏内调试器'),
            subtitle: const Text(
              '装进 ROM，在战斗地图上按 B 呼出菜单：改金币/回合/单位属性、'
              '载入单位、编辑地图与陷阱等（支持中文菜单）',
              style: TextStyle(fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => GameDebuggerPage(edit: widget.edit)),
            ),
          ),
        ),
      ];

  /// 作用范围选择 + 判据说明。
  ///
  /// 单位表没有阵营字段（阵营在关卡事件里），所以这里把判据和差异摊开给用户看，
  /// 而不是悄悄替他决定。
  Widget _scopeCard() {
    final pu = _playable;
    final supCount = pu.indices().length;
    final sortCount = pu.indices(criterion: PlayableCriterion.sortOrder).length;
    final diff = pu.ambiguous();
    final firstUnit = cheatPresets
        .where((p) => p.target == CheatTarget.unit && p.visible)
        .first;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.filter_alt_outlined, size: 18),
                const SizedBox(width: 6),
                Text(
                  '作用范围',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 自动判据（custom 是「自定义名单」，单独在下面渲染，避免重复）
            for (final c in PlayableCriterion.values)
              if (c != PlayableCriterion.custom)
                RadioListTile<PlayableCriterion>(
                  value: c,
                  groupValue: _criterion,
                  onChanged: _canEdit
                      ? (v) => setState(() => _criterion = v ?? _criterion)
                      : null,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(c.label, style: const TextStyle(fontSize: 13)),
                  subtitle: Text(
                    '${cheatEntryCount(firstUnit, widget.edit.rom, criterion: c, playable: pu, custom: _custom)} 条',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
            // 自定义名单：在自动判据的基础上手工微调，可导出/导入分享
            RadioListTile<PlayableCriterion>(
              value: PlayableCriterion.custom,
              groupValue: _criterion,
              onChanged: _canEdit
                  ? (v) => setState(() => _criterion = v ?? _criterion)
                  : null,
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(PlayableCriterion.custom.label,
                  style: const TextStyle(fontSize: 13)),
              subtitle: Text(
                _custom.isEmpty
                    ? '未设置 · 点下面按钮开始'
                    : '已选 ${_custom.length} 个角色',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _canEdit ? _openCustomRoster : null,
                icon: const Icon(Icons.checklist, size: 18),
                label: Text(_custom.isEmpty ? '勾选角色 / 导入分享' : '编辑名单 / 复制配置'),
              ),
            ),
            const Divider(height: 16),
            Text(
              '单位表里没有阵营字段——阵营写在关卡事件里，'
              '同一角色可能前期是敌人、后期被说服加入。',
              style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade700),
            ),
            const SizedBox(height: 6),
            Text(
              '「有支援数据」判据命中 $supCount 条：支援对话只给玩家角色配，'
              '敌方与 NPC 不会配。',
              style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade700),
            ),
            const SizedBox(height: 6),
            Text(
              '「按章节出场」判据命中 '
              '${pu.indices(criterion: PlayableCriterion.deployed).length} 条：'
              '把章节初始单位里出现过的角色也算进来（或支援互惠）。'
              '改版可能没给主角配支援对话，那种情况下前两个判据会漏掉他。',
              style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade700),
            ),
            const SizedBox(height: 6),
            Text(
              '「含事件动态」命中 '
              '${pu.indices(criterion: PlayableCriterion.deployedWithEvents).length} 条：'
              '再把事件脚本里以蓝方出场的角色算进来（剧情增援、后期加入），'
              '红方敌军与绿方 NPC 不计；会带入一次性剧情友军，'
              '想精确请用自定义名单。',
              style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade700),
            ),
            if (diff.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '「按图鉴排序」会多算 ${sortCount - supCount} 条'
                '（敌方主要角色等）：'
                '${diff.take(8).map((i) => widget.edit.rom.unitDisplayName(i).trim()).join('、')}'
                '${diff.length > 8 ? ' 等' : ''}',
                style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade700),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 按生效对象分组的预设列表（只显示 visible 的选项）。
  List<Widget> _presetGroup(CheatTarget target) {
    final items =
        cheatPresets.where((p) => p.target == target && p.visible).toList();
    if (items.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
        child: Text(
          '${target.label}类',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
      for (final p in items) _presetCard(p),
    ];
  }

  Widget _presetCard(CheatPreset preset) {
    final criterion =
        preset.scopeSelectable ? _criterion : PlayableCriterion.reciprocal;
    final count = cheatEntryCount(preset, widget.edit.rom,
        criterion: criterion, playable: _playable, custom: _custom);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.auto_fix_high),
        title: Text(preset.title),
        subtitle: Text(
          '${preset.description}\n'
          '${preset.scopeSelectable ? _scope.describe(_playable) : preset.target.label}'
          ' · $count 条',
          style: const TextStyle(fontSize: 12),
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        enabled: _canEdit,
        onTap: _canEdit ? () => _apply(preset) : null,
      ),
    );
  }
}
