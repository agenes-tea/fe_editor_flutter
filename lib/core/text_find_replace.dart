import 'text_browser.dart';
import 'text_writer.dart';

/// 文本批量查找 / 替换。
///
/// 逐条遍历全部文本条目，把**显示文本**（控制码占位符形态，
/// `TextWriter.currentText` 的口径）里的 [find] 替换为 [replacement]，
/// 写回全部走 [TextWriter.write] 同一通道（等长原地 / 变短收尾 /
/// 变长重定位 / Huffman 重压缩），撤销行为与单条编辑一致。
///
/// 注意：匹配与替换都发生在**占位符形态**上——用户把「⏳」当成普通文字
/// 找/换也能成立，占位符与正文不冲突。
class TextFindReplace {
  final TextWriter writer;

  /// 读实时 buffer 的条目遍历（重定位后 maxId 内指针已更新，可安全重查）。
  late final TextBrowser browser = TextBrowser(writer.rom);

  TextFindReplace(this.writer);

  int get entryCount => browser.maxId;

  /// 显示文本包含 [find] 的条目 ID（按 ID 升序）。
  List<int> search(String find) {
    final f = find.trim();
    if (f.isEmpty) return const [];
    final max = browser.maxId;
    final out = <int>[];
    for (var id = 0; id < max; id++) {
      final text = writer.currentText(id);
      if (text != null && text.contains(f)) out.add(id);
    }
    return out;
  }

  /// 一次批量替换的结果。
  ({int changed, int identical, List<String> failures}) replaceAll(
    String find,
    String replacement, {
    List<int>? ids,
    bool allowRelocate = true,
  }) {
    var changed = 0;
    var identical = 0;
    final failures = <String>[];
    for (final id in ids ?? search(find)) {
      final old = writer.currentText(id);
      if (old == null) {
        failures.add('条目 $id 读不出，跳过');
        continue;
      }
      final next = old.replaceAll(find, replacement);
      if (next == old) {
        identical++;
        continue;
      }
      final r = writer.write(id, next, allowRelocate: allowRelocate);
      if (r.ok) {
        changed++;
      } else {
        failures.add('条目 $id：${r.message.isEmpty ? r.mode.name : r.message}');
      }
    }
    return (changed: changed, identical: identical, failures: failures);
  }
}
