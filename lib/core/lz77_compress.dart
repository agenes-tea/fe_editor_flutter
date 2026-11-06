import 'dart:typed_data';

/// GBA BIOS 兼容的 LZ77 压缩。
///
/// 格式与 `Lz77.decompress`（`portrait.dart`）严格互逆：
/// `10 | size(3 字节, 小端) | 标志字节 + 至多 8 个子块`，
/// 标志位为 1 表示「回溯对」（2 字节：高 4 位是长度-3、低 12 位是距离-1），
/// 为 0 表示紧跟的 1 字节是原样数据。
///
/// 滑动窗口 4096 字节、单次最长匹配 18 字节——GBA 硬件解压器的上限。
class Lz77Compressor {
  static const int windowSize = 0x1000;
  static const int maxMatch = 18;
  static const int minMatch = 3;

  /// 是否允许 `distance == 1` 的回溯。
  ///
  /// **写进 ROM 给游戏用的时候必须为 false。**
  ///
  /// GBA 的 LZ77 有两个变体：SWI 0x11 写 WRAM（字节写）、
  /// SWI 0x12 写 **VRAM**（16 位写，因为 VRAM 不接受字节写）。
  /// BIOS 参考文档对 VRAM 版的约束写得很明确：
  ///
  /// > The compressed data can't reference the previous byte in the
  /// > decompressed data, because it may not have been written yet by the
  /// > BIOS due to the 16-bit bus to VRAM.
  ///
  /// 即 `distance = 1` 在 VRAM 解压时不生效。肖像正脸就是解压到 VRAM 的，
  /// 所以生成这种回溯会导致游戏里图像错乱（工具按字节语义读却是对的）——
  /// 实测封印之剑：我们生成的流里有 78 处 `distance = 1`，游戏里花屏；
  /// 原版压缩器一处都不产生（distance=2 有 72 处）。
  ///
  /// 允许 di=1 只用于纯 WRAM 场景（地图小人等），此时能多得一点压缩率；
  /// 默认关闭，宁可多几个字节也不错。
  static Uint8List compress(Uint8List data, {bool allowDistance1 = false}) {
    final size = data.length;
    final out = _ByteSink(size + 16);
    out
      ..addByte(0x10)
      ..addByte(size & 0xFF)
      ..addByte((size >> 8) & 0xFF)
      ..addByte((size >> 16) & 0xFF);

    var pos = 0;
    while (pos < size) {
      // 标志字节先占位，8 个子块全部填完后回填
      final flagIndex = out.length;
      out.addByte(0);
      var flags = 0;

      for (var bit = 0; bit < 8 && pos < size; bit++) {
        final match = _findMatch(data, pos, allowDistance1);
        if (match != null) {
          flags |= 0x80 >> bit;
          final encodedLength = match.length - minMatch;
          final encodedDisp = match.distance - 1;
          out.addByte(((encodedLength << 4) | (encodedDisp >> 8)) & 0xFF);
          out.addByte(encodedDisp & 0xFF);
          pos += match.length;
        } else {
          out.addByte(data[pos]);
          pos++;
        }
      }

      out.setByte(flagIndex, flags);
    }

    return out.toBytes();
  }

  /// 在 [pos] 之前至多 [windowSize] 字节内找最长匹配。
  ///
  /// 只比较首字节相同的候选（等价于单字节哈希），4096 窗口下足够快，
  /// 且实现简单、不易写错边界。
  static _Match? _findMatch(Uint8List data, int pos, bool allowDistance1) {
    final limit = pos - windowSize;
    final start = limit < 0 ? 0 : limit;
    // VRAM 语义下 distance 最小为 2（disp >= 1）
    final minDistance = allowDistance1 ? 1 : 2;
    final remain = data.length - pos;
    final maxLen = remain > maxMatch ? maxMatch : remain;
    if (maxLen < minMatch) return null;

    var best = 0;
    var bestDist = 0;
    final first = data[pos];

    for (var i = pos - minDistance; i >= start; i--) {
      if (data[i] != first) continue;
      var len = 0;
      // 允许重叠回溯：距离小于匹配长度时按字节顺序复制，GBA 解压器同样如此。
      // （VRAM 16 位写只禁 distance=1，distance>=2 的重叠仍安全。）
      while (len < maxLen && data[i + len] == data[pos + len]) {
        len++;
      }
      if (len > best) {
        best = len;
        bestDist = pos - i;
        if (best == maxLen) break;
      }
    }

    if (best < minMatch) return null;
    return _Match(best, bestDist);
  }
}

class _Match {
  final int length;
  final int distance;
  const _Match(this.length, this.distance);
}

/// 可回填的字节缓冲。压缩过程中要回头改标志位，`BytesBuilder` 不支持随机写。
class _ByteSink {
  Uint8List _buf;
  int _length = 0;

  _ByteSink(int initialCapacity) : _buf = Uint8List(initialCapacity);

  int get length => _length;

  void addByte(int b) {
    if (_length >= _buf.length) {
      final next = Uint8List(_buf.length * 2);
      next.setRange(0, _length, _buf);
      _buf = next;
    }
    _buf[_length++] = b & 0xFF;
  }

  void setByte(int index, int b) {
    if (index >= 0 && index < _length) _buf[index] = b & 0xFF;
  }

  Uint8List toBytes() => Uint8List.fromList(_buf.sublist(0, _length));
}
