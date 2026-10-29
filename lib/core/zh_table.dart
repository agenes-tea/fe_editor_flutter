import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// FEBuilderGBA 的中文码表（config/translate/zh_tbl/*.tbl）。
///
/// 格式：每行 `十六进制码位\t字符`，码位是游戏内双字节字符码（大端书写）。
/// 汉化版 ROM 用 Huffman 解出的字节流按 [decode] 渲染成汉字。
class ZhTable {
  final Map<int, String> table;

  ZhTable(this.table);

  static ZhTable? parse(String text) {
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    final map = <int, String>{};
    for (final line in text.split('\n')) {
      final t = line.trimRight();
      final tab = t.indexOf('\t');
      if (tab <= 0) continue;
      final code = int.tryParse(t.substring(0, tab), radix: 16);
      if (code == null) continue;
      map[code] = t.substring(tab + 1);
    }
    if (map.isEmpty) return null;
    return ZhTable(map);
  }

  /// 从 assets 加载（APK 内）。文件名可能被 URL 编码，两种 key 都试。
  static Future<ZhTable?> loadFromAssets(String assetKey) async {
    ByteData data;
    try {
      data = await rootBundle.load(assetKey);
    } catch (_) {
      final encoded = assetKey.split('/').map(Uri.encodeComponent).join('/');
      if (encoded == assetKey) rethrow;
      data = await rootBundle.load(encoded);
    }
    final bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    return parse(utf8.decode(bytes, allowMalformed: true));
  }

  /// 从文件系统加载（测试 / 桌面）。
  static Future<ZhTable?> loadFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return parse(utf8.decode(bytes, allowMalformed: true));
  }

  /// Huffman 解出的字节流 → 中文。
  ///
  /// 字节流里双字节码按大端配对（先高后低），与 .tbl 的书写顺序一致；
  /// 单字节 <0x20 视为控制符终止。
  String decode(Uint8List bytes) {
    final sb = StringBuffer();
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b == 0x00) break;
      if (b < 0x20) {
        // 控制码（换行/变色/变量等）：跳过，不终止
        i++;
        continue;
      }
      if (b < 0x80) {
        sb.writeCharCode(b);
        i++;
        continue;
      }
      if (i + 1 >= bytes.length) break;
      final code = (b << 8) | bytes[i + 1];
      sb.write(table[code] ?? '·');
      i += 2;
    }
    return sb.toString().trim();
  }

  /// 判定一段 Huffman 解出的字节是否像「tbl 可渲染文本」。
  bool looksLikeTblText(Uint8List bytes) {
    var units = 0;
    var bad = 0;
    var i = 0;
    while (i < bytes.length && units < 48) {
      final b = bytes[i];
      if (b == 0x00) break;
      if (b < 0x20) {
        i++;
        continue;
      }
      if (b < 0x80) {
        units++;
        i++;
        continue;
      }
      if (i + 1 >= bytes.length) break;
      final code = (b << 8) | bytes[i + 1];
      units++;
      if (table.containsKey(code)) {
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
