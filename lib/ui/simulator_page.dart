import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/battle_sim.dart';
import '../core/editable_rom.dart';
import '../core/item_catalog.dart';

/// 战斗 / 成长模拟器。
///
/// 公式在 [BattleSimulator]（取自 GBA 火纹的 `BattleCalculate` 结算，
/// 近似值：不计地形、支援、三角武器与特効）。
///
/// 「对比模式」用**打开 ROM 时的原始快照**与**当前 buffer** 各算一遍，
/// 同屏展示「改前 vs 改后」——改数值（修改器预设 / 字段编辑）后
/// 直接看效果，不用来回开关页面。
class SimulatorPage extends StatefulWidget {
  final EditableRom edit;

  const SimulatorPage({super.key, required this.edit});

  @override
  State<SimulatorPage> createState() => _SimulatorPageState();
}

class _SimulatorPageState extends State<SimulatorPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  bool _compare = false;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rom = widget.edit.liveRom;
    if (rom.unitCount == 0) {
      return Scaffold(
        appBar: AppBar(title: const Text('模拟器')),
        body: const Center(
          child: Text('没有读到单位表，无法模拟（可去「表地址」页手动指定）'),
        ),
      );
    }
    final hasChanges = widget.edit.hasChanges;
    return Scaffold(
      appBar: AppBar(
        title: const Text('模拟器'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '成长模拟'),
            Tab(text: '战斗模拟'),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: false,
                        label: Text('当前'),
                      ),
                      ButtonSegment(
                        value: true,
                        label: Text('对比改前/改后'),
                      ),
                    ],
                    selected: {_compare},
                    onSelectionChanged: (s) =>
                        setState(() => _compare = s.first),
                  ),
                ),
                if (hasChanges)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                      '已改 ${widget.edit.changedByteCount} 字节',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _GrowthPanel(edit: widget.edit, compare: _compare),
                _BattlePanel(edit: widget.edit, compare: _compare),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------
// 公共选择器：角色 / 武器，都是「搜索 + 列表」对话框
// ------------------------------------------------------------------

/// 选一个角色（单位表索引）。返回选中的索引，取消返回 null。
Future<int?> pickUnit(BuildContext context, EditableRom edit) async {
  final rom = edit.liveRom;
  final picked = await showDialog<int>(
    context: context,
    builder: (ctx) => _UnitPickerDialog(edit: edit),
  );
  if (picked == null || picked < 0 || picked >= rom.unitCount) return null;
  return picked;
}

/// 选一把武器（道具表索引，含魔法杖类；只列有「武器」标志的条目）。
Future<int?> pickWeapon(BuildContext context, EditableRom edit) async {
  final rom = edit.liveRom;
  final picked = await showDialog<int>(
    context: context,
    builder: (ctx) => _ItemPickerDialog(edit: edit),
  );
  if (picked == null || picked < 0 || picked >= rom.itemCount) return null;
  return picked;
}

/// 可搜索的角色列表对话框。
class _UnitPickerDialog extends StatefulWidget {
  final EditableRom edit;

  const _UnitPickerDialog({required this.edit});

  @override
  State<_UnitPickerDialog> createState() => _UnitPickerDialogState();
}

class _UnitPickerDialogState extends State<_UnitPickerDialog> {
  final _query = TextEditingController();
  String _text = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rom = widget.edit.liveRom;
    final all = List<int>.generate(rom.unitCount, (i) => i);
    final q = _text.trim().toLowerCase();
    final items = q.isEmpty
        ? all
        : all.where((i) {
            final name = rom.unitDisplayName(i).toLowerCase();
            return name.contains(q) || i.toString() == q;
          }).toList();

    return AlertDialog(
      title: Text('选择角色（${rom.unitCount}）'),
      content: SizedBox(
        width: double.maxFinite,
        height: 420,
        child: Column(
          children: [
            // 不 autofocus：光标闪烁计时器会让 widget 测试的
            // pumpAndSettle 永不结束；真机上点搜索框即可调起键盘
            TextField(
              controller: _query,
              decoration: const InputDecoration(
                hintText: '按名字或编号搜索',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _text = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('没有匹配的角色'))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (c, i) {
                        final id = items[i];
                        final name = rom.unitDisplayName(id).trim();
                        return ListTile(
                          dense: true,
                          leading: Text('#$id',
                              style: Theme.of(c).textTheme.labelSmall),
                          title: Text(
                              name.isEmpty ? '（未命名）' : name,
                              overflow: TextOverflow.ellipsis),
                          onTap: () => Navigator.pop(c, id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

/// 可搜索的武器列表对话框。
class _ItemPickerDialog extends StatefulWidget {
  final EditableRom edit;

  const _ItemPickerDialog({required this.edit});

  @override
  State<_ItemPickerDialog> createState() => _ItemPickerDialogState();
}

class _ItemPickerDialogState extends State<_ItemPickerDialog> {
  final _query = TextEditingController();
  String _text = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<int> _weapons(EditableRom edit) {
    final rom = edit.liveRom;
    final catalog = ItemCatalog(rom);
    return [
      for (var i = 1; i < rom.itemCount; i++)
        if (catalog.entryAt(i)?.kind.group == ItemGroup.weapon) i,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final rom = widget.edit.liveRom;
    final catalog = ItemCatalog(rom);
    final all = _weapons(widget.edit);
    final q = _text.trim().toLowerCase();
    final items = q.isEmpty
        ? all
        : all.where((i) {
            final name = rom.itemDisplayName(i).toLowerCase();
            return name.contains(q) || i.toString() == q;
          }).toList();

    return AlertDialog(
      title: Text('选择武器（${all.length}）'),
      content: SizedBox(
        width: double.maxFinite,
        height: 420,
        child: Column(
          children: [
            // 不 autofocus：光标闪烁计时器会让 widget 测试的
            // pumpAndSettle 永不结束；真机上点搜索框即可调起键盘
            TextField(
              controller: _query,
              decoration: const InputDecoration(
                hintText: '按名字或编号搜索',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _text = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('没有匹配的武器'))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (c, i) {
                        final id = items[i];
                        final e = catalog.entryAt(id)!;
                        final name =
                            rom.itemDisplayName(id).trim();
                        return ListTile(
                          dense: true,
                          leading: Text('#$id',
                              style: Theme.of(c).textTheme.labelSmall),
                          title: Text(
                            name.isEmpty ? '（未命名）' : name,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${e.kind.label} · 威力 ${e.might} · 命中 ${e.hit}',
                            style: Theme.of(c).textTheme.labelSmall,
                          ),
                          onTap: () => Navigator.pop(c, id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

/// 一行「标签 + 值 + 右箭头」的选择条，整行可点打开选择器。
///
/// 整行可点而不是单独的「更换」按钮：TabBarView 会预建相邻 tab，
/// 多个同名按钮会互相干扰测试定位与点按；行标签（角色/攻方/守方…）
/// 本身就是唯一句柄。
Widget _pickerRow(
  BuildContext context,
  String label,
  String value,
  VoidCallback onTap,
) {
  final theme = Theme.of(context);
  return InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(label, style: theme.textTheme.bodyMedium),
          ),
          Expanded(
            child: Text(value,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge),
          ),
          Icon(Icons.chevron_right,
              size: 18, color: theme.colorScheme.outlineVariant),
        ],
      ),
    ),
  );
}

// ------------------------------------------------------------------
// 成长模拟
// ------------------------------------------------------------------

class _GrowthPanel extends StatefulWidget {
  final EditableRom edit;
  final bool compare;

  const _GrowthPanel({required this.edit, required this.compare});

  @override
  State<_GrowthPanel> createState() => _GrowthPanelState();
}

class _GrowthPanelState extends State<_GrowthPanel> {
  int _unit = 0;
  int _target = 20;
  String _stat = 'HP';

  static const _statKeys = ['HP', '力量', '技巧', '速度', '防御', '魔防', '幸运'];

  @override
  Widget build(BuildContext context) {
    final rom = widget.edit.liveRom;
    final sim = BattleSimulator(widget.edit);
    final proj = sim.projectGrowth(_unit, targetLevel: _target);
    final oProj = widget.compare
        ? BattleSimulator.overOriginal(widget.edit)
            .projectGrowth(_unit, targetLevel: _target)
        : null;
    final growth = sim.growthRates(_unit);
    final caps = sim.classCaps(_unit);
    final capped = sim.capStatus(_unit, proj);
    final cid = sim.classIdOf(_unit);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _pickerRow(
          context,
          '角色',
          '${rom.unitDisplayName(_unit).trim()}'
              '（Lv ${proj.fromLevel} · '
              '${cid >= 0 ? rom.classDisplayName(cid).trim() : '—'}）',
          () async {
            final picked = await pickUnit(context, widget.edit);
            if (picked != null && mounted) setState(() => _unit = picked);
          },
        ),
        Row(
          children: [
            const SizedBox(width: 56, child: Text('目标等级')),
            IconButton(
              onPressed: _target > 1 ? () => setState(() => _target--) : null,
              icon: const Icon(Icons.remove),
              visualDensity: VisualDensity.compact,
            ),
            Text('$_target', style: theme.textTheme.titleMedium),
            IconButton(
              onPressed: _target < 60 ? () => setState(() => _target++) : null,
              icon: const Icon(Icons.add),
              visualDensity: VisualDensity.compact,
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Text('按当前 ROM 的成长率计算',
                    style: theme.textTheme.labelSmall),
              ),
            ),
          ],
        ),
        // 成长率一行
        Row(
          children: [
            const SizedBox(width: 56, child: Text('成长率')),
            Expanded(
              child: Text(
                _statKeys
                    .map((k) => '$k ${growth[k]?.clamp(0, 255) ?? 0}%')
                    .join(' '),
                style: theme.textTheme.labelMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 属性表
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            children: [
              _tableHeader(
                ['属性', '当前', '期望', '最坏', '最好', '上限'],
              ),
              for (final k in _statKeys)
                _statRow(
                  k,
                  proj.current[k]!.toString(),
                  proj.expected[k]!.toStringAsFixed(1),
                  proj.worst[k]!.toString(),
                  proj.best[k]!.toString(),
                  caps[k]?.toString() ?? '—',
                  capped[k] ?? false,
                  theme,
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 曲线：选一个属性看逐级曲线
        Row(
          children: [
            for (final k in _statKeys)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(k),
                  selected: _stat == k,
                  onSelected: (v) => v ? setState(() => _stat = k) : null,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (proj.levels <= 0)
          Text('目标等级不高于当前等级，没有成长可模拟',
              style: theme.textTheme.bodyMedium)
        else ...[
          Wrap(
            spacing: 8,
            children: [
              _legendDot(context, colors.primary, '期望'),
              if (oProj != null)
                _legendDot(context, colors.tertiary, '改前期望', dashed: true),
              _legendDot(context, colors.outline, '最好'),
              _legendDot(context, colors.outlineVariant, '最坏'),
              if (caps[_stat] != null)
                _legendDot(context, Colors.orange.shade700,
                    '职业上限 ${caps[_stat]}',
                    dashed: true),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 170,
            child: CustomPaint(
              painter: _CurvePainter(
                stat: _stat,
                proj: proj,
                original: oProj,
                cap: caps[_stat],
                colors: colors,
              ),
            ),
          ),
        ],
        // 改前 vs 改后
        if (widget.compare)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: widget.edit.hasChanges
                ? _CompareTable(proj: proj, oProj: oProj!, theme: theme)
                : Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('还没有改动，改前与改后相同。\n'
                          '在修改器或角色页改数值后回来对比。',
                              style: theme.textTheme.bodyMedium),
                    ),
                  ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _tableHeader(List<String> cols) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium
        ?.copyWith(fontWeight: FontWeight.bold);
    Widget cell(String v, {TextAlign align = TextAlign.end}) =>
        SizedBox(width: 46, child: Text(v, textAlign: align, style: style));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(cols[0], textAlign: TextAlign.start, style: style),
          ),
          for (final c in cols.sublist(1)) cell(c),
          const SizedBox(width: 18),
        ],
      ),
    );
  }

  Widget _statRow(
    String k,
    String current,
    String expected,
    String worst,
    String best,
    String cap,
    bool capped,
    ThemeData theme,
  ) {
    final colors = theme.colorScheme;
    Widget cell(String v, {Color? color}) => SizedBox(
          width: 46,
          child: Text(
            v,
            textAlign: TextAlign.end,
            style: color == null ? null : TextStyle(color: color),
          ),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(k)),
          cell(current),
          cell(expected),
          cell(worst),
          cell(best),
          cell(cap, color: capped ? colors.error : null),
          SizedBox(
            width: 18,
            child: capped
                ? Icon(Icons.arrow_upward, size: 14, color: colors.error)
                : null,
          ),
        ],
      ),
    );
  }
}

/// 改前 vs 改后（逐级期望值）。
class _CompareTable extends StatelessWidget {
  final GrowthProjection proj;
  final GrowthProjection oProj;
  final ThemeData theme;

  const _CompareTable(
      {required this.proj, required this.oProj, required this.theme});

  @override
  Widget build(BuildContext context) {
    const keys = ['HP', '力量', '技巧', '速度', '防御', '魔防', '幸运'];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              '改前 vs 改后（期望值 @Lv ${proj.targetLevel}，仅列有差异的属性）',
              style:
                  theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          for (final k in keys)
            if ((proj.expected[k]! - oProj.expected[k]!) != 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    SizedBox(width: 44, child: Text(k)),
                    Expanded(
                      child: Text(
                        '改前 ${oProj.expected[k]!.toStringAsFixed(1)} → '
                        '改后 ${proj.expected[k]!.toStringAsFixed(1)}',
                      ),
                    ),
                    Text(
                      '${proj.expected[k]! > oProj.expected[k]! ? '+' : ''}'
                      '${(proj.expected[k]! - oProj.expected[k]!).toStringAsFixed(1)}',
                      style: TextStyle(
                        color: proj.expected[k]! > oProj.expected[k]!
                            ? Colors.green.shade700
                            : theme.colorScheme.error,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
          if (keys.every(
              (k) => proj.expected[k]! - oProj.expected[k]! == 0))
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('改动未影响该角色的成长期望值'),
            ),
        ],
      ),
    );
  }
}

/// 曲线图例里的一小段线（虚线/实线）。
Widget _legendDot(
  BuildContext context,
  Color color,
  String label, {
  bool dashed = false,
}) {
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      CustomPaint(
        size: const Size(18, 6),
        painter: _LegendLinePainter(color: color, dashed: dashed),
      ),
      const SizedBox(width: 4),
      Text(label, style: Theme.of(context).textTheme.labelSmall),
    ],
  );
}

class _LegendLinePainter extends CustomPainter {
  final Color color;
  final bool dashed;

  const _LegendLinePainter({required this.color, required this.dashed});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(0, size.height / 2)
      ..lineTo(size.width, size.height / 2);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) =>
      oldDelegate is _LegendLinePainter &&
      (oldDelegate.color != color || oldDelegate.dashed != dashed);
}

class _CurvePainter extends CustomPainter {
  final String stat;
  final GrowthProjection proj;
  final GrowthProjection? original;
  final int? cap;
  final ColorScheme colors;

  _CurvePainter({
    required this.stat,
    required this.proj,
    required this.original,
    required this.cap,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final levels = proj.levels;
    final expected = proj.expectedByLevel[stat]!;
    final best = proj.bestByLevel[stat]!.map((v) => v.toDouble()).toList();
    final worst = proj.worstByLevel[stat]!.map((v) => v.toDouble()).toList();
    final orig = original?.expectedByLevel[stat];

    // y 轴范围
    var yMax = 4.0;
    for (final v in expected) {
      yMax = math.max(yMax, v);
    }
    for (final v in best) {
      yMax = math.max(yMax, v);
    }
    if (cap != null) yMax = math.max(yMax, cap!.toDouble());
    if (orig != null) {
      for (final v in orig) {
        yMax = math.max(yMax, v);
      }
    }
    yMax *= 1.08;

    const padLeft = 34.0;
    const padRight = 10.0;
    const padTop = 8.0;
    const padBottom = 20.0;
    final plot = Rect.fromLTWH(padLeft, padTop,
        size.width - padLeft - padRight, size.height - padTop - padBottom);

    double x(int i) =>
        levels == 0 ? plot.left : plot.left + (i / levels) * plot.width;
    double y(double v) => plot.bottom - (v / yMax) * plot.height;

    // 网格（4 条横线）
    final gridPaint = Paint()
      ..color = colors.outlineVariant.withValues(alpha: 0.4)
      ..strokeWidth = 1;
    for (var g = 1; g <= 4; g++) {
      final v = yMax * g / 4;
      final py = y(v);
      canvas.drawLine(Offset(plot.left, py), Offset(plot.right, py), gridPaint);
      final label = TextPainter(
        text: TextSpan(
            text: v.toInt().toString(),
            style: TextStyle(
                fontSize: 9, color: colors.outlineVariant)),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
          canvas, Offset(plot.left - label.width - 3, py - label.height / 2));
    }

    // x 轴标签：起始 / 中间 / 目标
    final mid = levels ~/ 2;
    final xlabels = [
      (0, proj.fromLevel.toString()),
      (mid, (proj.fromLevel + mid).toString()),
      (levels, proj.targetLevel.toString()),
    ];
    for (final (i, s) in xlabels) {
      final tp = TextPainter(
        text: TextSpan(
            text: s,
            style: TextStyle(fontSize: 9, color: colors.outlineVariant)),
        textDirection: TextDirection.ltr,
      )..layout();
      final px = x(i);
      tp.paint(canvas, Offset(px - tp.width / 2, plot.bottom + 4));
    }

    // 职业上限（虚线）
    if (cap != null && cap! > 0) {
      final py = y(cap!.toDouble());
      _dashedLine(canvas,
          Offset(plot.left, py), Offset(plot.right, py),
          Colors.orange.shade700, 1.5);
      final tp = TextPainter(
        text: TextSpan(
            text: '上限 $cap',
            style: TextStyle(fontSize: 9, color: Colors.orange.shade700)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(plot.right - tp.width - 2, py - 14));
    }

    // 最坏（平线，灰色）/ 最好（灰线）
    _polyline(canvas, worst.map((v) => Offset(x(0), y(v))).toList(),
        colors.outlineVariant.withValues(alpha: 0.7), 1);
    _polyline(
        canvas,
        [for (var i = 0; i <= levels; i++) Offset(x(i), y(best[i]))],
        colors.outline.withValues(alpha: 0.7),
        1);

    // 改前期望（虚线，辅助色）
    if (orig != null) {
      _dashedPolyline(
          canvas, [for (var i = 0; i <= levels; i++) Offset(x(i), y(orig[i]))],
          colors.tertiary, 1.5);
    }

    // 期望（主线）
    _polyline(
        canvas,
        [for (var i = 0; i <= levels; i++) Offset(x(i), y(expected[i]))],
        colors.primary,
        2.5);
    // 终点标记
    final last = Offset(x(levels), y(expected[levels]));
    canvas.drawCircle(last, 3, Paint()..color = colors.primary);
    final endTp = TextPainter(
      text: TextSpan(
          text: expected[levels].toStringAsFixed(1),
          style: TextStyle(fontSize: 10, color: colors.primary, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    endTp.paint(
        canvas,
        Offset(
            plot.right - endTp.width - 2,
            math.max(plot.top, last.dy - endTp.height - 4)));
  }

  void _polyline(Canvas canvas, List<Offset> pts, Color c, double w) {
    final paint = Paint()
      ..color = c
      ..strokeWidth = w
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (var i = 1; i < pts.length; i++) {
      canvas.drawLine(pts[i - 1], pts[i], paint);
    }
  }

  void _dashedLine(Canvas canvas, Offset a, Offset b, Color c, double w) {
    final paint = Paint()
      ..color = c
      ..strokeWidth = w
      ..style = PaintingStyle.stroke;
    const dash = 6.0;
    const gap = 4.0;
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    final ux = dx / len;
    final uy = dy / len;
    var s = 0.0;
    while (s < len) {
      final s2 = math.min(s + dash, len);
      canvas.drawLine(
          Offset(a.dx + ux * s, a.dy + uy * s),
          Offset(a.dx + ux * s2, a.dy + uy * s2),
          paint);
      s = s2 + gap;
    }
  }

  void _dashedPolyline(
      Canvas canvas, List<Offset> pts, Color c, double w) {
    for (var i = 1; i < pts.length; i++) {
      _dashedLine(canvas, pts[i - 1], pts[i], c, w);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is! _CurvePainter ||
        oldDelegate.stat != stat ||
        oldDelegate.proj != proj ||
        oldDelegate.original != original ||
        oldDelegate.cap != cap;
  }
}

// ------------------------------------------------------------------
// 战斗模拟
// ------------------------------------------------------------------

class _BattlePanel extends StatefulWidget {
  final EditableRom edit;
  final bool compare;

  const _BattlePanel({required this.edit, required this.compare});

  @override
  State<_BattlePanel> createState() => _BattlePanelState();
}

class _BattlePanelState extends State<_BattlePanel> {
  late int _att = 0;
  late int _def = 0;
  late int _weapon = 1;
  int _dist = 1;

  @override
  void initState() {
    super.initState();
    final rom = widget.edit.liveRom;
    _def = rom.unitCount > 1 ? 1 : 0;
    // 默认武器：第一个带「武器」标志的道具
    final catalog = ItemCatalog(rom);
    for (var i = 1; i < rom.itemCount; i++) {
      if (catalog.entryAt(i)?.kind.group == ItemGroup.weapon) {
        _weapon = i;
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rom = widget.edit.liveRom;
    final sim = BattleSimulator(widget.edit);
    final f = sim.forecast(_att, _weapon, _def, distance: _dist);
    final oF = BattleSimulator.overOriginal(widget.edit)
        .forecast(_att, _weapon, _def, distance: _dist);
    final w = sim.weaponAt(_weapon);
    final bonusVals = sim.weaponBonusAt(_weapon);
    final bonusObjs = ItemStatBonuses(
      bonusVals[0],
      bonusVals[1],
      bonusVals[2],
      bonusVals[3],
      bonusVals[4],
      bonusVals[5],
      bonusVals[6],
      bonusVals[7],
      bonusVals[8],
    );
    final theme = Theme.of(context);

    String weaponName() => rom.itemDisplayName(_weapon).trim().isEmpty
        ? '（未命名）'
        : rom.itemDisplayName(_weapon).trim();

    Widget forecastCard(
      String title,
      BattleForecast fc, {
      BattleForecast? diffAgainst,
    }) {
      final labels = fc.labels();
      final changedKeys = diffAgainst == null
          ? <String>{}
          : labels.keys
                .where((k) => labels[k] != diffAgainst.labels()[k])
                .toSet();
      final outcomeColor = switch (fc.outcome) {
        'atk' => Colors.green.shade700,
        'def' => theme.colorScheme.error,
        'both' => Colors.orange.shade700,
        _ => null,
      };
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(title,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  if (diffAgainst != null)
                    Text('vs 改前', style: theme.textTheme.labelSmall),
                ],
              ),
              const SizedBox(height: 8),
              for (final k in [
                '伤害',
                '次数',
                '命中',
                '必杀',
                '每回合期望伤害',
                '追击',
                '反击',
                '一回合结果',
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      SizedBox(
                          width: 110,
                          child: Text(k,
                              style: theme.textTheme.labelMedium)),
                      Expanded(
                        child: Text(
                          labels[k]!,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: changedKeys.contains(k)
                                ? theme.colorScheme.primary
                                : (k == '一回合结果' ? outcomeColor : null),
                            fontWeight:
                                changedKeys.contains(k) ? FontWeight.bold : null,
                          ),
                        ),
                      ),
                      if (changedKeys.contains(k))
                        Icon(Icons.bolt,
                            size: 12, color: theme.colorScheme.primary),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _pickerRow(
          context,
          '攻方',
          rom.unitDisplayName(_att).trim(),
          () async {
            final picked = await pickUnit(context, widget.edit);
            if (picked != null && mounted) setState(() => _att = picked);
          },
        ),
        _pickerRow(
          context,
          '武器',
          '$weaponName()${w != null ? '（威力 ${w.might} · ${w.range.label}）' : ''}',
          () async {
            final picked = await pickWeapon(context, widget.edit);
            if (picked != null && mounted) setState(() => _weapon = picked);
          },
        ),
        _pickerRow(
          context,
          '守方',
          rom.unitDisplayName(_def).trim(),
          () async {
            final picked = await pickUnit(context, widget.edit);
            if (picked != null && mounted) setState(() => _def = picked);
          },
        ),
        Row(
          children: [
            const SizedBox(width: 56, child: Text('距离')),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('1')),
                ButtonSegment(value: 2, label: Text('2')),
                ButtonSegment(value: 3, label: Text('3')),
              ],
              selected: {_dist},
              onSelectionChanged: (s) => setState(() => _dist = s.first),
            ),
            if (w != null && w.range.maxRange < _dist)
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text('距离超出射程', style: theme.textTheme.labelSmall),
              ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: () => _showWeaponRanking(context, sim),
          icon: const Icon(Icons.assessment, size: 16),
          label: const Text('全部武器排名'),
        ),
        const SizedBox(height: 8),
        // 免责声明放在结果上方：既醒目，也在首屏视口内
        Text(
          '近似值：不计地形、支援、三角武器与特効；反击按徒手速度；'
          '武器自带的数值加成（+12 表）已加到攻方属性上。',
          style: theme.textTheme.labelSmall,
        ),
        const SizedBox(height: 4),
        if (!bonusObjs.isEmpty) ...[
          Row(
            children: [
              const SizedBox(width: 56, child: Text('武器加成')),
              Expanded(
                child: Text(
                  bonusObjs.summaryText,
                  style: TextStyle(
                    color: Colors.green.shade700,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
        ],
        if (widget.compare && widget.edit.hasChanges) ...[
          forecastCard('改前（原始快照）', oF),
          const SizedBox(height: 8),
          forecastCard(
            '改后（当前）',
            f,
            diffAgainst: oF,
          ),
        ] else if (widget.compare)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('还没有改动，改前与改后相同。\n'
                  '在修改器或角色页改数值后回来对比。',
                  style: theme.textTheme.bodyMedium),
            ),
          )
        else
          forecastCard('模拟结果', f),
      ],
    );
  }

  /// 全武器对比：把攻方对守方**逐个武器**的每回合期望伤害排一遍，
  /// 看「谁配什么武器」；公式与战斗推演完全一致（BattleSimulator.compareWeapons）。
  void _showWeaponRanking(BuildContext ctx, BattleSimulator sim) {
    final rows = sim.compareWeapons(_att, _def, distance: _dist, limit: 60);
    final rom = widget.edit.liveRom;
    showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      builder: (sctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (sctx, controller) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
              child: Text(
                '对 ${rom.unitDisplayName(_def).trim()} 的每回合期望伤害（前 ${rows.length} 把）',
                style: Theme.of(sctx).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '公式同战斗推演（近似值，不计职业持枪限制与追击反击）；点某行选中该武器',
                style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade700),
              ),
            ),
            Expanded(
              child: ListView.separated(
                controller: controller,
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final r = rows[i];
                  final oneShot = r.outcome == 'atk';
                  final name = r.name.isEmpty ? '（未命名）' : r.name;
                  return ListTile(
                    dense: true,
                    onTap: () {
                      Navigator.pop(sctx);
                      setState(() => _weapon = r.weaponId);
                    },
                    leading: Text(
                      '${i + 1}',
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 11, color: Colors.grey),
                    ),
                    title: Text(
                      '$name（${r.kindLabel}）',
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      '伤害 ${r.damage} · 命中 ${r.hit}% · 必杀 ${r.crit}% · '
                      '${r.attacks} 次 · 期望 ${r.expectedDamage.toStringAsFixed(1)}'
                      '${oneShot ? ' · 一回合打死' : ''}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    trailing: oneShot
                        ? Icon(Icons.whatshot, size: 16,
                            color: Colors.green.shade700)
                        : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
