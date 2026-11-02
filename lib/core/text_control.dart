import 'dart:typed_data';

/// 控制码与可编辑文本之间的双向转换。
///
/// FE 对话里夹着控制码（0x01 行等待、0x02 按键、0x03/0x09 换行、0x0B/0x0C 清屏、
/// 0x0F 变色、0x10 变量、0x1A 菜单项…），有的还带参数。整条按显示文本替换会把这些
/// 一并冲掉（尾部内容也跟着乱）。这里把它们编码成**占位符**：
///
/// - 无参控制码：`〔03〕`
/// - 带参控制码：`〔0F:05〕`（参数**按字节**读写，十六进制）
/// - 码表外的双字节码对（引擎保留的特殊码，如 FE7/FE8 的 `80 20`）：
///   `〔8020〕`（4 位十六进制，无冒号）——原样回写，不丢字节
///
/// 用户编辑时保留这些占位符即可（删掉就等于去掉那个控制码）。文本部分仍按 ROM 的
/// 编码（UTF-8 / GBK / SJIS / 中文码表）交给调用方的 `encodeText` / `decodeText`。
class TextControlCodec {
  /// 各控制码带几个**字节**参数。
  ///
  /// 必须是字节数、不能按 u16 个数算：这些参数实际是单字节字段
  /// （如 `15 06` 是「变色 6」、`05 01` 是「按键 1」）。
  /// 早期按 u16 读会把后面紧跟的汉字吃掉半个字节，导致整条文本错位乱码：
  /// 实测烈火汉化版 GBK 文本非法字节率 2.55% → 0.43%，日版 1.29% → 0.69%。
  ///
  /// `0x10`（变量/名字插入）是例外，它是 2 字节（如 `10 1a 01` = 变量 0x011a；
  /// `10 ff ff` = 无变量）。
  static int argsOf(int b) {
    switch (b) {
      case 0x05:
      case 0x0F:
      case 0x11:
      case 0x15:
      case 0x1A:
        return 1;
      case 0x10:
        return 2;
      default:
        return 0;
    }
  }

  static final RegExp _token =
      RegExp(r'〔([0-9A-Fa-f]{2,4})(?::([0-9A-Fa-f]{1,2}(?:,[0-9A-Fa-f]{1,2})*))?〕');

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
        final hex = _hex2(b);
        var j = i + 1;
        final args = <String>[];
        for (var k = 0; k < n && j < raw.length; k++) {
          args.add(_hex2(raw[j]));
          j++;
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

  static String _hex2(int v) =>
      v.toRadixString(16).padLeft(2, '0').toUpperCase();

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
        final code = int.parse(m.group(1)!, radix: 16);
        final argStr = m.group(2);
        if (code <= 0xFF) {
          // 单字节控制码（〔03〕/〔15:06〕）
          out.add(code);
          if (argStr != null) {
            for (final p in argStr.split(',')) {
              // 参数是单字节字段（〔10:1A,01〕 → 10 1A 01）
              out.add(int.parse(p, radix: 16) & 0xFF);
            }
          }
        } else {
          // 4 位十六进制 = 码表外双字节码对原样回注（〔8020〕）
          out.add((code >> 8) & 0xFF);
          out.add(code & 0xFF);
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
