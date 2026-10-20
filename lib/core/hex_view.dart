import 'dart:typed_data';

import 'rom_buffer.dart';

/// 十六进制编辑器的数据视图。
///
/// 负责把字节按行切分、格式化，并支持「按值搜索」与「空位搜索」。
class HexView {
  final RomBuffer buffer;
  static const int bytesPerRow = 16;

  HexView(this.buffer);

  int get rowCount => (buffer.length + bytesPerRow - 1) ~/ bytesPerRow;

  /// 第 [row] 行的起始偏移
  int rowOffset(int row) => row * bytesPerRow;

  /// 生成一行的十六进制表示（未使用的尾部用空格补齐）
  String hexAt(int row) {
    final start = rowOffset(row);
    final sb = StringBuffer();
    for (var i = 0; i < bytesPerRow; i++) {
      if (start + i < buffer.length) {
        sb.write(buffer.u8(start + i).toRadixString(16).padLeft(2, '0').toUpperCase());
      } else {
        sb.write('  ');
      }
      if (i != bytesPerRow - 1) sb.write(' ');
    }
    return sb.toString();
  }

  /// 生成一行的 ASCII 预览（不可打印字符用 . 代替）
  String asciiAt(int row) {
    final start = rowOffset(row);
    final sb = StringBuffer();
    for (var i = 0; i < bytesPerRow; i++) {
      if (start + i >= buffer.length) {
        sb.write(' ');
        continue;
      }
      final b = buffer.u8(start + i);
      sb.write(b >= 0x20 && b < 0x7F ? String.fromCharCode(b) : '.');
    }
    return sb.toString();
  }

  String offsetLabel(int row) =>
      rowOffset(row).toRadixString(16).padLeft(8, '0').toUpperCase();

  /// 搜索字节序列，返回所有匹配偏移（最多 [limit] 个）。
  List<int> search(List<int> pattern, {int limit = 200}) {
    final results = <int>[];
    if (pattern.isEmpty || pattern.length > buffer.length) return results;
    final first = pattern.first;
    final last = buffer.length - pattern.length;
    for (var i = 0; i <= last; i++) {
      if (buffer.data[i] != first) continue;
      var ok = true;
      for (var k = 1; k < pattern.length; k++) {
        if (buffer.data[i + k] != pattern[k]) {
          ok = false;
          break;
        }
      }
      if (ok) {
        results.add(i);
        if (results.length >= limit) break;
      }
    }
    return results;
  }

  /// 找一段连续的 [fill] 空位，返回起点与长度。
  ///
  /// 返回的是连续区域的**完整长度**（不是到 minLength 为止），
  /// 便于界面如实展示可用空间。
  ({int offset, int length})? findFreeRun(int from, {int fill = 0xFF, int minLength = 1}) {
    var start = -1;
    for (var i = from; i < buffer.length; i++) {
      if (buffer.data[i] == fill) {
        if (start < 0) start = i;
      } else {
        if (start >= 0) {
          final len = i - start;
          if (len >= minLength) return (offset: start, length: len);
          start = -1;
        }
      }
    }
    if (start >= 0) {
      final len = buffer.length - start;
      if (len >= minLength) return (offset: start, length: len);
    }
    return null;
  }
}

/// 把用户输入的十六进制字符串解析成字节列表；非法返回 null。
Uint8List? parseHex(String input) {
  final cleaned = input.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (cleaned.isEmpty || cleaned.length.isOdd) return null;
  final out = Uint8List(cleaned.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
