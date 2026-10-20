import 'dart:typed_data';

import 'gbk_table.dart';
import 'sjis_table.dart';

/// FE ROM 的文本编码方式。
enum FeTextEncoding {
  /// 标准卡带：Huffman 压缩 + Shift-JIS
  huffmanSjis,

  /// 汉化版：把文本表整体搬走并改成明文 GBK（如 Superxyj 烈火之剑）
  plainGbk,

  /// 汉化版：仍是 Huffman，但字符按中文码表渲染（如狼组封印之剑，配 .tbl）
  huffmanZhTbl,

  /// 无法识别
  unknown,
}

/// 明文 GBK 解码。遇到控制字符则截断到显示段。
class GbkCodec {
  /// 解出可显示字符串；控制字符（<0x20）视为结束。
  static String decode(Uint8List bytes) {
    final sb = StringBuffer();
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b < 0x20) break;
      if (b < 0x80) {
        sb.writeCharCode(b);
        i++;
        continue;
      }
      if (i + 1 >= bytes.length) break;
      final code = (b << 8) | bytes[i + 1];
      final u = gbkDoubleByte[code];
      if (u != null) {
        sb.writeCharCode(u);
      }
      i += 2;
    }
    return sb.toString().trim();
  }

  /// 判定一段字节是否像 GBK 文本：双字节码必须在 GBK 表里。
  static bool looksLikeGbk(Uint8List bytes) {
    var units = 0;
    var bad = 0;
    var i = 0;
    while (i < bytes.length && units < 48) {
      final b = bytes[i];
      if (b < 0x20) break;
      if (b < 0x80) {
        units++;
        i++;
        continue;
      }
      if (i + 1 >= bytes.length) break;
      final code = (b << 8) | bytes[i + 1];
      units++;
      if (gbkDoubleByte.containsKey(code)) {
        i += 2;
      } else {
        bad++;
        i += 2;
      }
    }
    if (units < 2) return false;
    return bad * 10 <= units;
  }
}

/// Shift-JIS 解码器（标准日版用）。
class SjisCodecLocal {
  static String decode(Uint8List bytes) {
    final sb = StringBuffer();
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b < 0x20) break;
      if (b < 0x80) {
        sb.writeCharCode(b);
        i++;
        continue;
      }
      if (b >= 0xA1 && b <= 0xDF) {
        sb.writeCharCode(0xFF61 + (b - 0xA1));
        i++;
        continue;
      }
      if (i + 1 >= bytes.length) break;
      final code = (b << 8) | bytes[i + 1];
      final u = sjisDoubleByte[code];
      if (u != null) sb.writeCharCode(u);
      i += 2;
    }
    return sb.toString().trim();
  }
}
