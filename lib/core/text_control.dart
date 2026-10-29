import 'dart:typed_data';

/// 控制码与可编辑文本之间的双向转换。
///
/// FE 对话里夹着控制码（0x01 行等待、0x02 按键、0x03/0x09 换行、0x0B/0x0C 清屏、
/// 0x0F 变色、0x10 变量、0x1A 菜单项…），有的还带参数。整条按显示文本替换会把这些
/// 一并冲掉（尾部内容也跟着乱）。这里把它们编码成**占位符**：
///
/// - 无参控制码：`〔03〕`
/// - 带参控制码：`〔0F:0500〕`（参数按 u16 小端读写，十六进制）
///
/// 用户编辑时保留这些占位符即可（删掉就等于去掉那个控制码）。文本部分仍按 ROM 的
/// 编码（UTF-8 / GBK / SJIS / 中文码表）交给调用方的 `encodeText` / `decodeText`。
class TextControlCodec {
  /// 各控制码带几个 u16 参数（与 `TextBrowser._ctrl` 一致）。
  static int argsOf(int b) {
    switch (b) {
      case 0x05:
      case 0x0F:
      case 0x1A:
        return 1;
      case 0x10:
        return 2;
      default:
        return 0;
    }
  }

  static final RegExp _token =
      RegExp(r'〔([0-9A-Fa-f]{2})(?::([0-9A-Fa-f]{4}(?:,[0-9A-Fa-f]{4})*))?〕');

  /// 原始字节 → 可编辑串（文本部分交给 [decodeText]）。以 0x00 结束。
  static String decode(
    Uint8List raw,
    String Function(Uint8List bytes) decodeText,
  ) {
    final sb = StringBuffer();
    var i = 0;
    while (i < raw.length) {
      final b = raw[i];
      if (b == 0x00) break;
      if (b < 0x20) {
        final n = argsOf(b);
        final hex = b.toRadixString(16).padLeft(2, '0').toUpperCase();
        var j = i + 1;
        final args = <String>[];
        for (var k = 0; k < n && j + 1 < raw.length; k++) {
          final v = raw[j] | (raw[j + 1] << 8);
          args.add(v.toRadixString(16).padLeft(4, '0').toUpperCase());
          j += 2;
        }
        sb.write(args.isEmpty ? '〔$hex〕' : '〔$hex:${args.join(',')}〕');
        i = j;
        continue;
      }
      final start = i;
      while (i < raw.length && raw[i] >= 0x20 && raw[i] != 0x00) {
        i++;
      }
      sb.write(decodeText(Uint8List.fromList(raw.sublist(start, i))));
    }
    return sb.toString();
  }

  /// 可编辑串 → 原始字节。文本段交给 [encodeText]；返回 null 表示有字符无法编码。
  static Uint8List? encode(
    String text,
    Uint8List? Function(String chunk) encodeText,
  ) {
    final out = <int>[];
    var i = 0;
    while (i < text.length) {
      final m = _token.matchAsPrefix(text, i);
      if (m != null) {
        out.add(int.parse(m.group(1)!, radix: 16));
        final argStr = m.group(2);
        if (argStr != null) {
          for (final p in argStr.split(',')) {
            final v = int.parse(p, radix: 16);
            out.add(v & 0xFF);
            out.add((v >> 8) & 0xFF);
          }
        }
        i = m.end;
        continue;
      }
      final next = text.indexOf('〔', i);
      final end = next < 0 ? text.length : next;
      final chunk = text.substring(i, end);
      if (chunk.isNotEmpty) {
        final enc = encodeText(chunk);
        if (enc == null) return null;
        out.addAll(enc);
      }
      i = end;
    }
    return Uint8List.fromList(out);
  }
}
