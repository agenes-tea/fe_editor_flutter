import 'dart:typed_data';

/// ROM 字节读写与空位搜索。
///
/// 所有地址参数都是「文件偏移」（不是 GBA 内存地址）。
class RomBuffer {
  final Uint8List data;

  RomBuffer(this.data);

  int get length => data.length;

  bool inRange(int addr, int size) => addr >= 0 && addr + size <= data.length;

  int u8(int a) => (a >= 0 && a < data.length) ? data[a] : 0;

  int u16(int a) {
    if (!inRange(a, 2)) return 0;
    return data[a] | (data[a + 1] << 8);
  }

  int u32(int a) {
    if (!inRange(a, 4)) return 0;
    return data[a] |
        (data[a + 1] << 8) |
        (data[a + 2] << 16) |
        (data[a + 3] << 24);
  }

  /// 有符号 8 位（成长率、修正值可能是负数）
  int s8(int a) {
    final v = u8(a);
    return v >= 0x80 ? v - 0x100 : v;
  }

  void writeU8(int a, int v) {
    if (a >= 0 && a < data.length) data[a] = v & 0xFF;
  }

  void writeU16(int a, int v) {
    if (!inRange(a, 2)) return;
    data[a] = v & 0xFF;
    data[a + 1] = (v >> 8) & 0xFF;
  }

  void writeU32(int a, int v) {
    if (!inRange(a, 4)) return;
    data[a] = v & 0xFF;
    data[a + 1] = (v >> 8) & 0xFF;
    data[a + 2] = (v >> 16) & 0xFF;
    data[a + 3] = (v >> 24) & 0xFF;
  }

  void writeBytes(int a, List<int> bytes) {
    for (var i = 0; i < bytes.length; i++) {
      writeU8(a + i, bytes[i]);
    }
  }

  /// 在 [start, end) 内找一段长度 >= size、内容全部等于 [fill] 的连续区域，
  /// 返回区域起始偏移；找不到返回 -1。
  ///
  /// FE 的空位通常是 0xFF（擦除态）或 0x00，按 [fills] 顺序依次尝试。
  int findFreeSpace(int size,
      {int start = 0, int? end, List<int> fills = const [0xFF, 0x00]}) {
    final limit = end ?? data.length;
    if (size <= 0) return -1;
    for (final fill in fills) {
      var runStart = -1;
      var runLen = 0;
      for (var i = start; i < limit; i++) {
        // 最后 size 个字节不可能是完整空位起点
        if (i + size > limit) break;
        if (data[i] == fill) {
          if (runStart < 0) runStart = i;
          runLen++;
          if (runLen >= size) {
            // 起点必须 4 字节对齐，便于存放指针
            final aligned = runStart + ((4 - (runStart % 4)) % 4);
            if (aligned + size <= limit) return aligned;
            // 对齐后越过区域，继续从下一字节找
            runStart = -1;
            runLen = 0;
          }
        } else {
          runStart = -1;
          runLen = 0;
        }
      }
    }
    return -1;
  }

  RomBuffer clone() => RomBuffer(Uint8List.fromList(data));
}

/// 计算 CRC32（UPS 补丁校验用）。
/// 起始值 0、多项式 0xEDB88320 取反输出，与 UPS 规范一致。
int crc32(Uint8List bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
      crc &= 0xFFFFFFFF;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
