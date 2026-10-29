import 'dart:convert';
import 'dart:typed_data';

import 'gbk_table.dart';
import 'sjis_table.dart';

/// FE ROM 的文本编码方式。
enum FeTextEncoding {
  /// 标准卡带：Huffman 压缩 + Shift-JIS
  huffmanSjis,

  /// 汉化版：把文本表整体搬走并改成明文 GBK（如 Superxyj 烈火之剑）
  plainGbk,

  /// 重度改版：文本表搬到扩展区，内容是明文 UTF-8（如「铠甲的呼唤」）
  plainUtf8,

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

/// 明文 UTF-8 解码。遇到控制字符或 0x00 则截断到显示段。
///
/// 重度改版（如「铠甲的呼唤」）把文本表搬到扩展区并存成 UTF-8 明文，
/// 不是 GBK——两者高位字节都 >= 0x80，但编码规则完全不同。
class Utf8Codec {
  static String decode(Uint8List bytes) {
    final sb = StringBuffer();
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b == 0x00 || b < 0x20) break;
      if (b < 0x80) {
        sb.writeCharCode(b);
        i++;
        continue;
      }
      // 多字节序列：按前导位判断长度
      final need = b >= 0xF0 ? 3 : (b >= 0xE0 ? 2 : 1);
      if (i + need >= bytes.length) break;
      String code;
      try {
        code = const Utf8Decoder().convert(bytes.sublist(i, i + need + 1));
      } on FormatException {
        // 非法序列（孤立续接字节、超长式等）：写替换字符并跳过一个字节继续。
        // 这些 ROM 的文本表里混有旧版 SJIS/二进制残骸（实测「三部曲」三个改版），
        // 一条坏条目绝不能让整个解码抛异常——UI 里抛了会白掉整页。
        sb.writeCharCode(0xFFFD);
        i++;
        continue;
      }
      sb.write(code);
      i += need + 1;
    }
    return sb.toString().trim();
  }

  /// 判定一段字节是否像 UTF-8 文本。
  ///
  /// 关键区分点：GBK 的双字节高位在 0x81~0xFE 且**第二字节可低到 0x40**；
  /// UTF-8 的后续字节一定在 0x80~0xBF。汉字在两者里都是 3 字节 vs 2 字节，
  /// 所以「同样长度的中文，UTF-8 明显更长」也能作为判据。
  static bool looksLikeUtf8(Uint8List bytes) {
    if (bytes.isEmpty) return false;
    var units = 0;
    var bad = 0;
    var i = 0;
    while (i < bytes.length && units < 48) {
      final b = bytes[i];
      if (b == 0x00 || b < 0x20) break;
      if (b < 0x80) {
        units++;
        i++;
        continue;
      }
      final need = b >= 0xF0 ? 3 : (b >= 0xE0 ? 2 : (b >= 0xC0 ? 1 : -1));
      if (need < 0) {
        bad++;
        i++;
        continue;
      }
      if (i + need >= bytes.length) break;
      // 后续字节必须都是 0x80~0xBF 续接字节
      var ok = true;
      for (var k = 1; k <= need; k++) {
        final c = bytes[i + k];
        if (c < 0x80 || c > 0xBF) {
          ok = false;
          break;
        }
      }
      units++;
      if (!ok) bad++;
      i += need + 1;
    }
    if (units < 2) return false;
    return bad * 10 <= units;
  }
}
