import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/battle_anim.dart' show encodePng;
import '../core/chapter_events.dart';
import '../core/editable_rom.dart';
import '../core/event_preview.dart';
import '../core/portrait.dart';

/// 章节预览页：**两个视图**——对话时间线 + 事件触发。
///
/// 定位（务必别改错）：这是「编辑时的即时反馈」，渲染的是**工具解析出的数据**，
/// 不是游戏实际运行画面。解析器认错结构、偏移读错、条目大小判错时，
/// 预览会显得完全正常（因为预览用的就是错误的解析结果）。
/// 因此界面固定展示 [PreviewBoundaryNotice]，且只做「数据自洽」校验
/// （文本 ID 存在、坐标在地图内、角色/职业/道具 ID 在表内），
/// 不做「游戏行为」断言（这段对话真的会在第 3 回合触发吗 → 那是模拟器的事）。
class ChapterPreviewPage extends StatefulWidget {
  const ChapterPreviewPage({
    super.key,
    required this.edit,
    required this.chapter,
    required this.chapterTitle,
  });

  final EditableRom edit;
  final int chapter;
  final String chapterTitle;

  @override
  State<ChapterPreviewPage> createState() => _ChapterPreviewPageState();
}

class _ChapterPreviewPageState extends State<ChapterPreviewPage> {
  DialogPreview? _dialogs;
  EventPreview? _events;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    try {
      setState(() {
        _dialogs = DialogPreviewer(widget.edit).of(widget.chapter);
        _events = EventPreviewer(widget.edit).of(widget.chapter);
        _error = null;
      });
    } catch (e) {
      setState(() => _error = '生成预览失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.chapterTitle.isEmpty
        ? '第 ${widget.chapter} 章'
        : widget.chapterTitle;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text('$title · 预览'),
          actions: [
            IconButton(
              tooltip: '重新生成预览',
              icon: const Icon(Icons.refresh),
              onPressed: _load,
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.forum_outlined, size: 18), text: '对话时间线'),
              Tab(icon: Icon(Icons.bolt_outlined, size: 18), text: '事件触发'),
            ],
          ),
        ),
        body: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!,
                      style: TextStyle(color: Colors.red.shade700)),
                ),
              )
            : Column(
                children: [
                  const PreviewBoundaryNotice(),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _DialogTimeline(
                            preview: _dialogs,
                            edit: widget.edit,
                            onChanged: _load),
                        _EventTimeline(preview: _events),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// 顶部不可忽略的界线说明。
///
/// 这不是免责声明式的客套：项目踩过「解析器认错结构但预览看起来完全正常」的坑，
/// 用户会以为改对了、实际游戏里是乱码或崩溃。所以固定展示、不能折叠。
class PreviewBoundaryNotice extends StatelessWidget {
  const PreviewBoundaryNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF3A2E13) : const Color(0xFFFFF4D9);
    final fg = dark ? const Color(0xFFF1D48A) : const Color(0xFF7A5B00);
    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: fg),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '这是工具根据 ROM 数据渲染的预览，不是游戏实际运行画面。\n'
              '只校验数据自洽（文本 ID / 坐标 / 角色职业道具是否在表内），'
              '不校验游戏行为（这段对话真会在第 3 回合触发吗、演出效果对不对）。'
              '要确认「游戏里真的对不对」，请导出后用模拟器 / 实机验证。',
              style: TextStyle(fontSize: 11, color: fg, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// 视图一：对话时间线（头像 + 角色名 + 台词）。
class _DialogTimeline extends StatelessWidget {
  const _DialogTimeline({
    required this.preview,
    required this.edit,
    required this.onChanged,
  });

  final DialogPreview? preview;
  final EditableRom edit;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final p = preview;
    if (p == null) return const Center(child: CircularProgressIndicator());
    if (p.isEmpty) {
      return _EmptyState(
        icon: Icons.forum_outlined,
        title: '这一章没有解析到对话',
        detail: '本章事件脚本里没有引用对话文本，'
            '或该 ROM 的事件脚本结构不是原版三作的形态。',
        issues: p.issues,
      );
    }

    final portraits = PortraitReader(edit.liveRom);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: p.lines.length + (p.issues.isEmpty ? 0 : 1),
      itemBuilder: (ctx, i) {
        if (i == 0 && p.issues.isNotEmpty) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _IssueBox(issues: p.issues),
          );
        }
        final idx = p.issues.isEmpty ? i : i - 1;
        final line = p.lines[idx];
        return _DialogLineTile(
          line: line,
          portraits: portraits,
          isNewScene: idx == 0 || p.lines[idx - 1].textId != line.textId,
        );
      },
    );
  }
}

class _DialogLineTile extends StatelessWidget {
  const _DialogLineTile({
    required this.line,
    required this.portraits,
    required this.isNewScene,
  });

  final PreviewLine line;
  final PortraitReader portraits;
  final bool isNewScene;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isNewScene)
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 6),
            child: Row(
              children: [
                const Icon(Icons.movie_outlined, size: 14),
                const SizedBox(width: 6),
                Text('文本 #${line.textId}',
                    style: TextStyle(
                        fontSize: 11, color: theme.hintColor)),
                if (line.controlTokens.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text('控制码 ${line.controlTokens.length} 个',
                      style: TextStyle(
                          fontSize: 11, color: theme.hintColor)),
                ],
              ],
            ),
          ),
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: line.hasIssues
                  ? Colors.red.shade300
                  : theme.dividerColor.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Avatar(portraits: portraits, portraitId: line.portraitId),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      line.speaker ?? '（工具未解析出说话人）',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: line.speaker == null
                            ? theme.hintColor
                            : theme.textTheme.bodyMedium?.color,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(line.text,
                        style: const TextStyle(fontSize: 14, height: 1.5)),
                    if (line.hasIssues)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          line.issues.join('；'),
                          style: TextStyle(
                              fontSize: 11, color: Colors.red.shade700),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 头像占位。拿不到肖像时显示明确说明，不用随机图糊过去。
class _Avatar extends StatelessWidget {
  const _Avatar({required this.portraits, required this.portraitId});

  final PortraitReader portraits;
  final int? portraitId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final id = portraitId;
    Uint8List? png;
    if (id != null && id >= 0) {
      try {
        final face = portraits.mapFaceImage(id);
        if (face != null) png = encodePng(face);
      } catch (_) {
        png = null;
      }
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: theme.dividerColor.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(6),
          ),
          clipBehavior: Clip.antiAlias,
          child: png != null
              ? Image.memory(png, fit: BoxFit.cover, filterQuality: FilterQuality.none)
              : Icon(Icons.person_outline,
                  size: 22, color: theme.hintColor),
        ),
        const SizedBox(height: 2),
        SizedBox(
          width: 46,
          child: Text(
            png != null ? '头像 #$id' : '无头像',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 9, color: theme.hintColor),
          ),
        ),
      ],
    );
  }
}

/// 视图二：事件触发（一行自然语言 + 展开看单位明细）。
class _EventTimeline extends StatelessWidget {
  const _EventTimeline({required this.preview});

  final EventPreview? preview;

  @override
  Widget build(BuildContext context) {
    final p = preview;
    if (p == null) return const Center(child: CircularProgressIndicator());
    if (p.events.isEmpty) {
      return _EmptyState(
        icon: Icons.bolt_outlined,
        title: '这一章没有解析到事件',
        detail: '本章没有事件组，或事件列表解析为空。',
        issues: p.issues,
      );
    }
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        if (p.issues.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _IssueBox(issues: p.issues),
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            '地图 ${p.mapWidth}×${p.mapHeight} 格 · 共 ${p.events.length} 条事件',
            style: TextStyle(fontSize: 11, color: theme.hintColor),
          ),
        ),
        for (final e in p.events) _EventTile(event: e),
      ],
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final PreviewEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        leading: Icon(
          switch (event.kind) {
            EventTriggerKind.turn => Icons.timelapse,
            EventTriggerKind.location => Icons.place_outlined,
            EventTriggerKind.character => Icons.person_search_outlined,
            _ => Icons.flag_outlined,
          },
          size: 20,
        ),
        title: Text(
          event.sentence,
          style: const TextStyle(fontSize: 13, height: 1.45),
        ),
        subtitle: event.units.isEmpty
            ? null
            : Text('${event.units.length} 个单位',
                style: TextStyle(fontSize: 11, color: theme.hintColor)),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '原文条件：${event.condition}   检查字 0x${event.check.toRadixString(16)}',
              style: TextStyle(fontSize: 11, color: theme.hintColor),
            ),
          ),
          if (event.units.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final u in event.units) _UnitRow(unit: u),
          ],
          if (event.issues.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                event.issues.join('\n'),
                style: TextStyle(fontSize: 11, color: Colors.red.shade700),
              ),
            ),
        ],
      ),
    );
  }
}

class _UnitRow extends StatelessWidget {
  const _UnitRow({required this.unit});

  final PreviewEventUnit unit;

  @override
  Widget build(BuildContext context) {
    final items = unit.itemNames.isEmpty ? '无道具' : unit.itemNames.join('、');
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AllegianceChip(name: unit.allegianceName, allegiance: unit.allegiance),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${unit.name.isEmpty ? '（未命名）' : unit.name}'
              '${unit.className.isEmpty ? '' : ' · ${unit.className}'}'
              '  Lv${unit.level}  (${unit.x},${unit.y})  道具：$items',
              style: const TextStyle(fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _AllegianceChip extends StatelessWidget {
  const _AllegianceChip({required this.name, required this.allegiance});

  final String name;
  final int allegiance;

  @override
  Widget build(BuildContext context) {
    final color = switch (allegiance) {
      0 => Colors.blue,
      1 => Colors.green,
      2 => Colors.red,
      _ => Colors.grey,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(name, style: TextStyle(fontSize: 10, color: color)),
    );
  }
}

class _IssueBox extends StatelessWidget {
  const _IssueBox({required this.issues});

  final List<String> issues;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        issues.join('\n'),
        style: TextStyle(fontSize: 11, color: Colors.orange.shade900, height: 1.5),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.detail,
    required this.issues,
  });

  final IconData icon;
  final String title;
  final String detail;
  final List<String> issues;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(title, style: const TextStyle(fontSize: 15)),
            const SizedBox(height: 8),
            Text(detail,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12, color: Colors.grey.shade600, height: 1.5)),
            if (issues.isNotEmpty) ...[
              const SizedBox(height: 16),
              _IssueBox(issues: issues),
            ],
          ],
        ),
      ),
    );
  }
}
