import 'chapter_dialogs.dart';
import 'editable_rom.dart';
import 'text_writer.dart';

/// 一次对话补丁导入的结果。
class DialogImportResult {
  /// 文件里解析出的 #define 条目数。
  final int total;

  /// 成功写入的条数（含内容未变的）。
  final int written;

  /// 内容未变（identical）的条数。
  final int unchanged;

  /// 被跳过的条数（ID 无效 / 编码失败 / 变长放不下等）。
  final int skipped;

  /// 文件里非 #define 也非注释的行数。
  final int badLines;

  /// 每条跳过/异常的原因（给人看的短句）。
  final List<String> problems;

  DialogImportResult({
    required this.total,
    required this.written,
    required this.unchanged,
    required this.skipped,
    required this.badLines,
    required this.problems,
  });

  bool get allOk => skipped == 0 && badLines == 0 && total > 0;

  String get summary {
    final parts = <String>['共 $total 条'];
    if (written > 0) parts.add('写入 ${written - unchanged} 条'
        '${unchanged > 0 ? '（其中 $unchanged 条内容未变）' : ''}');
    if (unchanged > 0 && written == unchanged) parts.add('内容均未变');
    if (skipped > 0) parts.add('跳过 $skipped 条');
    if (badLines > 0) parts.add('忽略 $badLines 行无法识别的行');
    return parts.join('，');
  }
}

/// 整章对话的批量导入/导出（`#define` 风格的 patch 文本）。
///
/// 导出：把该章事件脚本引用的全部对话写成一个 .txt，一行一条：
/// `#define <文本ID> <内容>`（内容里的控制码是 〔XX〕/〔XXXX〕 占位符，
/// 与编辑框里看到的完全一致）。拿出去改台词、批量替换、再导回来即可。
///
/// 导入：解析同一个格式，逐条走 [TextWriter.write] 同一写回通道
/// （等长/变短原地、变长找空位重指指针，全部记进 edits、可整体撤销）。
/// 单条失败不中断整批，结果里逐条点名。
class ChapterDialogIO {
  static final RegExp _defineRe =
      RegExp(r'^#define\s+(\d+)(?:\s+(.*))?\s*$', dotAll: false);

  /// 导出该章全部对话。文本引擎不可写时返回 null（调用方禁用入口）。
  static String? exportChapter(EditableRom edit, int chapter) {
    final writer = TextWriter(edit);
    if (!writer.supported) return null;
    final rows = ChapterDialogues.of(edit, chapter).dialogues;
    final title = edit.rom.table.name;
    final sb = StringBuffer()
      ..writeln('# fe_editor 对话补丁')
      ..writeln('# 作品: ${edit.rom.table.id} ($title)  章节: $chapter')
      ..writeln('# 每行 `#define <文本ID> <内容>`；〔XX〕/〔XXXX〕 是控制码占位符，原样保留即可')
      ..writeln('# 用本工具「本章对话 → 导入对话补丁」导回');
    for (final d in rows) {
      final text = writer.currentText(d.textId) ?? edit.rom.decodeText(d.textId);
      // 一条记录一行：把换行吃成空（游戏里的换行是 〔03〕 控制码，不是真换行）
      sb.writeln('#define ${d.textId} ${text.replaceAll('\n', '')}');
    }
    return sb.toString();
  }

  /// 导入一份 #define 文本。[ids] 非空时只处理其中列出的条目。
  static DialogImportResult importDialogs(EditableRom edit, String text,
      {List<int>? ids}) {
    final writer = TextWriter(edit);
    final records = <int, String>{};
    var badLines = 0;
    var dupIds = 0;

    if (!writer.supported) {
      return DialogImportResult(
        total: 0,
        written: 0,
        unchanged: 0,
        skipped: 0,
        badLines: 0,
        problems: ['该 ROM 文本引擎（${writer.engineLabel}）不支持写入，未做任何改动'],
      );
    }

    for (var raw in text.split('\n')) {
      final line = raw.replaceFirst(RegExp(r'\r$'), '').trimLeft();
      if (line.isEmpty || line.startsWith('#') && !line.startsWith('#define')) {
        continue; // 空行与注释
      }
      final m = _defineRe.firstMatch(line);
      if (m == null) {
        badLines++;
        continue;
      }
      final id = int.parse(m.group(1)!);
      final content = (m.group(2) ?? '').trimRight();
      if (records.containsKey(id)) {
        dupIds++;
        continue; // 同一 ID 出现多次：先出现的为准
      }
      records[id] = content;
    }

    final problems = <String>[];
    if (dupIds > 0) problems.add('$dupIds 个重复 ID 只取第一次出现');
    if (ids != null) {
      records.removeWhere((id, _) => !ids.contains(id));
    }

    var written = 0;
    var unchanged = 0;
    var skipped = 0;
    for (final entry in records.entries) {
      // 内容与当前解码结果一致 → 跳过不写。
      // 不能直接依赖 writer.write 的「字节级 identical」：原版压缩器/残留字节
      // 会让「同内容重编码」产生不同的字节流，写一遍就白记一堆编辑。
      final current = writer.currentText(entry.key);
      if (current == entry.value) {
        written++;
        unchanged++;
        continue;
      }
      final r = writer.write(entry.key, entry.value);
      switch (r.mode) {
        case TextWriteMode.identical:
          written++;
          unchanged++;
        case TextWriteMode.inPlace:
        case TextWriteMode.shorter:
        case TextWriteMode.relocated:
          written++;
        case TextWriteMode.tooLong:
        case TextWriteMode.unsupportedEngine:
        case TextWriteMode.hasControlCodes:
        case TextWriteMode.charNotEncodable:
        case TextWriteMode.missing:
          skipped++;
          problems.add('#${entry.key}: ${_skipReason(r)}');
      }
    }

    return DialogImportResult(
      total: records.length,
      written: written,
      unchanged: unchanged,
      skipped: skipped,
      badLines: badLines,
      problems: problems,
    );
  }

  static String _skipReason(TextWriteResult r) => switch (r.mode) {
        TextWriteMode.tooLong => '变长且没有空位可放',
        TextWriteMode.unsupportedEngine => '引擎不支持写入',
        TextWriteMode.hasControlCodes => '条目无法读取',
        TextWriteMode.charNotEncodable => r.message.isEmpty
            ? '有字符无法编码'
            : r.message,
        TextWriteMode.missing => '文本指针表里找不到该 ID',
        _ => r.message,
      };
}
