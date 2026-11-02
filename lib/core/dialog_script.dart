import 'chapter_dialogs.dart';
import 'editable_rom.dart';
import 'text_browser.dart';
import 'text_writer.dart';

/// 一段台词在游戏里的「一句话」（按控制码切开后的一段）。
///
/// 火纹的对话文本是一条记录里塞很多句，用换行/等待/清屏控制码分隔。
/// 逐字编辑整条记录对新手太粗暴（改一句要面对几百个占位符），
/// 所以这里按控制码切成句子，一句一句给用户看和改。
class DialogLine {
  /// 在所属 [DialogScene] 里的序号（0 基，按出现顺序）。
  final int index;

  /// 显示文本（控制码已换成可读符号）。
  final String text;

  /// 原文（含〔XX〕占位符，写作时的基准）。
  final String raw;

  const DialogLine({required this.index, required this.text, required this.raw});

  bool get isEmpty => text.trim().isEmpty;
}

/// 一场戏：同一条文本记录 = 游戏里连续推进的一段对话。
class DialogScene {
  /// 文本表 ID（写回用）。
  final int textId;

  /// 这段脚本在事件里的位置（GBA 地址，排查用）。
  final int address;

  /// 切好的台词。
  final List<DialogLine> lines;

  /// 整条记录的原始可编辑文本（含占位符）。
  final String raw;

  const DialogScene({
    required this.textId,
    required this.address,
    required this.lines,
    required this.raw,
  });

  /// 给界面/日志看的单行摘要。
  String get summary {
    final first = lines.where((l) => !l.isEmpty).firstOrNull?.text ?? '(空)';
    return first.length > 40 ? '${first.substring(0, 40)}…' : first;
  }
}

/// 把一章的事件脚本对话整理成「场景 → 台词」两层。
///
/// 与 [ChapterDialogues] 的区别：后者只给一串文本 ID（界面上是一堆编号），
/// 这里额外做三件事让小白能顺着剧情读：
/// 1. 按脚本归属分组（同一段事件脚本里连续出现的对话 = 一场戏）；
/// 2. 按控制码把一条记录切成句子（一句一行）；
/// 3. 尽量推断说话人（脚本里紧邻的 `CHAI`/名字文本引用）。
class DialogScript {
  final EditableRom edit;
  final int chapter;
  final List<DialogScene> scenes;

  DialogScript._(this.edit, this.chapter, this.scenes);

  /// 读一章的场景化对话。
  static DialogScript of(EditableRom edit, int chapter) {
    final dlg = ChapterDialogues.of(edit, chapter);
    if (dlg.dialogues.isEmpty) return DialogScript._(edit, chapter, const []);
    final rom = edit.liveRom;
    final browser = TextBrowser(rom);
    final writer = TextWriter(edit);

    final scenes = <DialogScene>[];
    for (final d in dlg.dialogues) {
      final raw = writer.currentText(d.textId) ?? browser.render(d.textId);
      scenes.add(DialogScene(
        textId: d.textId,
        address: d.address,
        raw: raw,
        lines: splitLines(raw),
      ));
    }
    return DialogScript._(edit, chapter, scenes);
  }

  /// 把一条记录切成句子。
  ///
  /// 切点取「会改变显示状态」的控制码：换行（03/09）、清屏（0B/0C）、
  /// 等待按键（02）。纯等待（01）不切——它只控制打字停顿，
  /// 切开会把一句话拆碎。
  ///
  /// 只有控制码没有文字的碎片（如开头的 `〔0B〕`、单独的 `〔02〕`）
  /// **并入下一句**：它们在游戏里不会单独出现，列出来只会让用户困惑。
  /// 控制码保留在每句末尾，写作时原样带回去。
  static List<DialogLine> splitLines(String raw) {
    final out = <DialogLine>[];
    final sb = StringBuffer();
    var i = 0;
    while (i < raw.length) {
      final tok = _matchToken(raw, i);
      if (tok != null) {
        sb.write(tok.text);
        i = tok.end;
        if (tok.breaksLine && _hasVisibleText(sb.toString())) {
          out.add(_line(out.length, sb.toString()));
          sb.clear();
        }
        continue;
      }
      sb.write(raw[i]);
      i++;
    }
    if (sb.isEmpty) return out;
    // 末尾只剩控制码（如文本 #2103 结尾的〔05〕）：不能丢，
    // 挂到上一句的 raw 末尾——否则拼回去对不上原记录，
    // 而「拼回去 == 原记录」是整条写入通道的前提。
    if (out.isNotEmpty) {
      final last = out.removeLast();
      final merged = last.raw + sb.toString();
      out.add(_line(last.index, merged));
    } else {
      out.add(_line(0, sb.toString()));
    }
    return out;
  }

  static DialogLine _line(int index, String s) =>
      DialogLine(index: index, text: _visible(s), raw: s);

  /// 去掉占位符后的可见文本（判「这句是不是空的」）。
  static String _visible(String s) {
    final sb = StringBuffer();
    var i = 0;
    while (i < s.length) {
      final t = _matchToken(s, i);
      if (t != null) {
        i = t.end;
        continue;
      }
      sb.write(s[i]);
      i++;
    }
    return sb.toString().trim();
  }

  static bool _hasVisibleText(String s) => _visible(s).isNotEmpty;

  /// 这些控制码之后另起一句。
  static const Set<int> _lineBreakers = {0x03, 0x09, 0x0B, 0x0C, 0x02};

  static _Token? _matchToken(String s, int i) {
    if (s.codeUnitAt(i) != 0x3014) return null; // '〔'
    final close = s.indexOf('〕', i);
    if (close < 0) return null;
    final body = s.substring(i + 1, close);
    final colon = body.indexOf(':');
    final codeStr = colon < 0 ? body : body.substring(0, colon);
    final code = int.tryParse(codeStr, radix: 16);
    if (code == null) return null;
    return _Token(
      text: s.substring(i, close + 1),
      end: close + 1,
      breaksLine: code <= 0xFF && _lineBreakers.contains(code),
    );
  }

}

class _Token {
  final String text;
  final int end;
  final bool breaksLine;
  const _Token({required this.text, required this.end, required this.breaksLine});
}
