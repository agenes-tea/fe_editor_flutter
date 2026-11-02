import 'package:flutter/material.dart';

import '../core/dialog_script.dart';
import '../core/editable_rom.dart';
import '../core/text_coverage.dart';
import '../core/text_writer.dart';
import '../core/unit_placement.dart';
import 'text_edit_dialog.dart';

/// 场景化对话编辑：按「一场戏 → 一句一句」读写某一章的剧情。
///
/// 与文本查看器的区别：文本查看器按 ID 平铺（几千条编号），
/// 这里只列**本章事件脚本实际引用**的对话，且每条按控制码切成句子，
/// 标题用章节标题而不是编号——目的是让不熟数据结构的人也能顺着剧情改。
class DialogScriptPage extends StatefulWidget {
  const DialogScriptPage({
    super.key,
    required this.edit,
    required this.chapter,
    required this.chapterTitle,
  });

  final EditableRom edit;
  final int chapter;
  final String chapterTitle;

  @override
  State<DialogScriptPage> createState() => _DialogScriptPageState();
}

class _DialogScriptPageState extends State<DialogScriptPage> {
  DialogScript? _script;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    try {
      setState(() {
        _script = DialogScript.of(widget.edit, widget.chapter);
        _error = null;
      });
    } catch (e) {
      setState(() => _error = '读取对话失败：$e');
    }
  }

  Future<void> _editScene(DialogScene scene) async {
    final header = _CoverageHeader(edit: widget.edit, textId: scene.textId);
    final changed = await showTextEditDialog(
      context,
      edit: widget.edit,
      textId: scene.textId,
      title: '改这段对话（文本 #${scene.textId}）',
      header: header,
    );
    if (changed) _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = _script;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.chapterTitle.isEmpty
            ? '第 ${widget.chapter} 章 · 对话'
            : '${widget.chapterTitle} · 对话'),
        actions: [
          IconButton(
            tooltip: '重新读取',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, style: TextStyle(color: Colors.red.shade700)),
              ),
            )
          : s == null
              ? const Center(child: CircularProgressIndicator())
              : s.scenes.isEmpty
                  ? _empty()
                  : _list(s),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            const Text('这一章没有提取到对话'),
            const SizedBox(height: 8),
            Text(
              '可能是：① 本章没有剧情文本；② 该 ROM 的事件脚本结构不是原版三作的形态。\n'
              '可以先用「本章对话」列表按文本 ID 查看，或用文本查看器搜索原文。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(DialogScript s) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: s.scenes.length,
      itemBuilder: (ctx, i) {
        final sc = s.scenes[i];
        final lines = sc.lines.where((l) => !l.isEmpty).toList();
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 14,
                    child: Text('${i + 1}', style: const TextStyle(fontSize: 12)),
                  ),
                  title: Text('第 ${i + 1} 段 · ${lines.length} 句',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('文本 #${sc.textId}',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                  trailing: IconButton(
                    tooltip: '改这一段',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _editScene(sc),
                  ),
                ),
                for (final l in lines)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(56, 2, 16, 2),
                    child: Text(l.text,
                        style: const TextStyle(fontSize: 13, height: 1.5)),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 编辑框上方的提示：当前字库够不够、这段文本的缺字情况。
class _CoverageHeader extends StatelessWidget {
  const _CoverageHeader({required this.edit, required this.textId});

  final EditableRom edit;
  final int textId;

  @override
  Widget build(BuildContext context) {
    final writer = TextWriter(edit);
    if (!writer.supported) return const SizedBox.shrink();
    final checker = TextCoverageChecker(writer);
    final current = writer.currentText(textId) ?? '';
    final cov = checker.check(current);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('字库：${checker.charset.label}',
            style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
        if (!cov.ok)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '这段里这些字当前 ROM 写不了：${cov.missing.join(' ')}',
              style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
            ),
          ),
      ],
    );
  }
}
