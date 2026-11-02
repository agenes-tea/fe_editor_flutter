import 'gbk_table.dart';
import 'sjis_table.dart';
import 'text_codec.dart';
import 'text_writer.dart';

/// 一段文本在该 ROM 上「写不进去」的那些字。
///
/// 火纹的文本引擎只认自己字库里的字：日版是 Huffman + Shift-JIS，
/// 汉化版是 Huffman + 自定义码表（`assets/tbl/*.tbl`），改版多是明文
/// UTF-8 / GBK。字库外的字写进去要么被 [TextWriter] 直接拒绝
/// （`charNotEncodable`），要么显示成空白。
///
/// 这个类把「哪些字缺」查出来给用户看，而不是只回一句「有字符无法编码」。
class TextCoverage {
  /// 缺的字（按首次出现顺序，去重）。
  final List<String> missing;

  /// 参与检查的字种数（去重后，不含控制码占位符）。
  final int checkedCount;

  /// 引擎是否支持写入；false 时 [missing] 无意义。
  final bool writable;

  const TextCoverage({
    required this.missing,
    required this.checkedCount,
    required this.writable,
  });

  bool get ok => writable && missing.isEmpty;

  /// 覆盖率（0..1）；没有可检查的字时为 1。
  double get ratio => checkedCount == 0
      ? 1
      : (checkedCount - missing.length) / checkedCount;

  Map<String, Object?> toJson() => {
        'writable': writable,
        'ok': ok,
        'checked': checkedCount,
        'ratio': double.parse(ratio.toStringAsFixed(3)),
        'missing_count': missing.length,
        'missing': missing,
      };
}

/// 按 ROM 的文本引擎判断每个字符能否编码。
///
/// 与 [TextWriter.encode] 用同一套查表，但**逐字判断**而不是整串判失败：
/// 用户想知道的是「到底哪个字缺」，只回 null 等于没说。
class TextCoverageChecker {
  final TextWriter _w;

  TextCoverageChecker(TextWriter writer) : _w = writer;

  bool get writable => _w.supported;

  /// 引擎名（给界面展示）。
  String get engineLabel => _w.engineLabel;

  /// 该引擎的字库说明（「能写多少字」）。
  TextCharsetInfo get charset => TextCharsetInfo.of(_w.rom.textEncoding);

  /// 检查一段可编辑文本（可能含 `〔XX〕` 控制码占位符，会被跳过）。
  TextCoverage check(String text) {
    if (!writable) {
      return const TextCoverage(missing: [], checkedCount: 0, writable: false);
    }
    final seen = <String>{};
    final missing = <String>[];
    for (final seg in textSegments(text)) {
      for (final rune in seg.runes) {
        final ch = String.fromCharCode(rune);
        if (!seen.add(ch)) continue;
        if (!encodable(ch)) missing.add(ch);
      }
    }
    return TextCoverage(
        missing: missing, checkedCount: seen.length, writable: writable);
  }

  /// 单字能否编进该 ROM。
  ///
  /// ASCII 恒可写：日版走 `LANG_ENGLISH` 的 ASCII 分支（`Font.glyphs[byte]`），
  /// 根本不进 Huffman 树——实测 FE8J 的树里一个 ASCII 单字节叶子都没有，
  /// 拿树判 ASCII 会把所有英文都错报成缺字。
  bool encodable(String ch) {
    if (ch.codeUnitAt(0) < 0x80) return true;
    final bytes = _w.encode(ch);
    if (bytes == null) return false;
    return _w.encodableBytes(bytes);
  }

  /// 把文本拆成「真正要编码的文字段」，跳过 `〔XX〕` / `〔XX:AABB〕` 占位符。
  ///
  /// 占位符是控制码或引擎特殊码，由 [TextControlCodec] 原样回注，
  /// 不参与字库判断——不跳过的话每个控制码都会被报成缺字。
  static List<String> textSegments(String text) {
    final out = <String>[];
    var i = 0;
    while (i < text.length) {
      final m = _tokenRe.matchAsPrefix(text, i);
      if (m != null) {
        i = m.end;
        continue;
      }
      final next = text.indexOf('〔', i);
      final end = next < 0 ? text.length : next;
      final chunk = text.substring(i, end);
      if (chunk.isNotEmpty) out.add(chunk);
      i = end;
    }
    return out;
  }

  static final RegExp _tokenRe =
      RegExp(r'〔([0-9A-Fa-f]{2,4})(?::([0-9A-Fa-f]{4}(?:,[0-9A-Fa-f]{4})*))?〕');
}

/// 该引擎的字库规模（回答「这个字库能写多少字」）。
class TextCharsetInfo {
  final String label;
  final int count;
  final String note;

  const TextCharsetInfo(this.label, this.count, this.note);

  static TextCharsetInfo of(FeTextEncoding engine) {
    switch (engine) {
      case FeTextEncoding.plainUtf8:
        return const TextCharsetInfo(
            '明文 UTF-8', -1, '几乎不限字；字库里没有的字会显示成空白');
      case FeTextEncoding.plainGbk:
        return TextCharsetInfo('明文 GBK', gbkDoubleByte.length,
            '覆盖 GB2312/GBK 常用汉字，做剧情改版最省心');
      case FeTextEncoding.huffmanSjis:
        return TextCharsetInfo('Huffman + SJIS', sjisDoubleByte.length,
            '日文字库，汉字约 6600 个，但只覆盖 GB2312 的一半左右');
      case FeTextEncoding.huffmanZhTbl:
      case FeTextEncoding.unknown:
        return const TextCharsetInfo('Huffman + 中文码表', -1,
            '汉化组自选的字集（比常用字少），缺字时换基底 ROM 比加字容易');
    }
  }
}
