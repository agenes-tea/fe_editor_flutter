import 'dart:typed_data';

import 'rom_buffer.dart';

/// UPS 补丁编解码。
///
/// 格式：`UPS1` + val(srcSize) + val(dstSize) + 记录流
///      + CRC32(源) + CRC32(目标) + CRC32(补丁自身, 不含最后 4 字节)
///
/// 记录流：val(跳过长度) + (源^目标 的字节序列) + 0x00 终止符。
/// val 不是普通 varint：每跨 7 位要给累加值加一个偏移，见 [_appendValCode]。
class UpsPatch {
  static final List<int> _magic = [0x55, 0x50, 0x53, 0x31]; // "UPS1"

  static Uint8List create(Uint8List source, Uint8List target) {
    final out = <int>[..._magic];
    _appendValCode(out, source.length);
    _appendValCode(out, target.length);

    final length =
        source.length > target.length ? source.length : target.length;
    var lastPoint = 0;
    var i = 0;
    while (i < length) {
      final ss = i < source.length ? source[i] : 0;
      final dd = i < target.length ? target[i] : 0;
      if (ss == dd) {
        i++;
        continue;
      }

      _appendValCode(out, i - lastPoint);

      final diff = <int>[ss ^ dd];
      var n = i + 1;
      while (n < length) {
        final ns = n < source.length ? source[n] : 0;
        final nd = n < target.length ? target[n] : 0;
        if (ns == nd) break;
        diff.add(ns ^ nd);
        n++;
      }
      out.addAll(diff);
      out.add(0);

      i = n;
      lastPoint = n + 1;
    }

    _appendU32(out, crc32(source));
    _appendU32(out, crc32(target));
    _appendU32(out, crc32(Uint8List.fromList(out)));
    return Uint8List.fromList(out);
  }

  /// 应用补丁；源 CRC 不匹配或补丁损坏时返回 null。
  static Uint8List? apply(Uint8List patch, Uint8List source) {
    if (patch.length < 16) return null;
    for (var i = 0; i < 4; i++) {
      if (patch[i] != _magic[i]) return null;
    }

    final srcCrc = _u32(patch, patch.length - 12);
    final dstCrc = _u32(patch, patch.length - 8);
    if (!_crcMatches(patch, source, srcCrc, dstCrc)) return null;

    var i = 4;
    final srcSize = _readValCode(patch, i);
    if (srcSize == null) return null;
    i = srcSize.next;
    final dstSize = _readValCode(patch, i);
    if (dstSize == null) return null;
    i = dstSize.next;

    final out = Uint8List(dstSize.value);
    final copyLen =
        source.length < dstSize.value ? source.length : dstSize.value;
    out.setAll(0, source.sublist(0, copyLen));

    final end = patch.length - 12;
    var romi = 0;
    while (i < end) {
      final skip = _readValCode(patch, i);
      if (skip == null) return null;
      i = skip.next;
      romi += skip.value;

      while (i < end) {
        if (romi >= dstSize.value) break;
        out[romi] = (out[romi] ^ patch[i]) & 0xFF;
        romi++;
        final b = patch[i];
        i++;
        if (b == 0x00) break;
      }
    }

    return crc32(out) == dstCrc ? out : null;
  }

  /// 判断补丁是否适用于这份 ROM（也接受目标侧的反向补丁）。
  static bool _crcMatches(
      Uint8List patch, Uint8List source, int srcCrc, int dstCrc) {
    final c = crc32(source);
    return c == srcCrc || c == dstCrc;
  }

  static void _appendValCode(List<int> out, int v) {
    var x = v & 0x7F;
    v >>= 7;
    while (v != 0) {
      out.add(x);
      v--;
      x = v & 0x7F;
      v >>= 7;
    }
    out.add(x | 0x80);
  }

  static ({int value, int next})? _readValCode(Uint8List d, int i) {
    var shift = 1;
    var value = 0;
    while (i < d.length) {
      final b = d[i];
      i++;
      value += (b & 0x7F) * shift;
      if ((b & 0x80) != 0) return (value: value, next: i);
      shift <<= 7;
      value += shift;
    }
    return null;
  }

  static void _appendU32(List<int> out, int v) {
    out.add(v & 0xFF);
    out.add((v >> 8) & 0xFF);
    out.add((v >> 16) & 0xFF);
    out.add((v >> 24) & 0xFF);
  }

  static int _u32(Uint8List d, int at) {
    if (at < 0 || at + 4 > d.length) return 0;
    return d[at] | (d[at + 1] << 8) | (d[at + 2] << 16) | (d[at + 3] << 24);
  }
}

/// IPS 补丁编解码。
///
/// 格式：`PATCH` + 若干记录（3 字节偏移 + 2 字节长度 + 数据）+ `EOF`。
/// 偏移上限 0xFFFFFF（16MB），超出时只能改用 UPS。
class IpsPatch {
  static const int maxOffset = 0xFFFFFF;

  /// 是否存在超出 IPS 可表达范围的改动。
  static bool exceedsRange(Uint8List source, Uint8List target) {
    final n = source.length > target.length ? source.length : target.length;
    for (var i = 0; i < n; i++) {
      if (_sameAt(source, target, i)) continue;
      if (i > maxOffset) return true;
    }
    return false;
  }

  /// 生成 IPS 补丁；有超出 0xFFFFFF 的改动时返回 null。
  static Uint8List? create(Uint8List source, Uint8List target) {
    if (exceedsRange(source, target)) return null;
    final out = <int>[0x50, 0x41, 0x54, 0x43, 0x48]; // "PATCH"

    final n = source.length > target.length ? source.length : target.length;
    var i = 0;
    while (i < n) {
      if (_sameAt(source, target, i)) {
        i++;
        continue;
      }
      final start = i;
      while (i < n && i - start < 0xFFFF && !_sameAt(source, target, i)) {
        i++;
      }
      final len = i - start;
      out.add((start >> 16) & 0xFF);
      out.add((start >> 8) & 0xFF);
      out.add(start & 0xFF);
      out.add((len >> 8) & 0xFF);
      out.add(len & 0xFF);
      for (var k = start; k < i; k++) {
        out.add(k < target.length ? target[k] : 0x00);
      }
    }

    out.addAll([0x45, 0x4F, 0x46]); // "EOF"
    return Uint8List.fromList(out);
  }

  /// 应用 IPS 补丁；格式非法返回 null。
  static Uint8List? apply(Uint8List patch, Uint8List source) {
    if (patch.length < 3) return null;
    var pos = 0;
    final hasHeader = patch.length >= 5 &&
        patch[0] == 0x50 &&
        patch[1] == 0x41 &&
        patch[2] == 0x54 &&
        patch[3] == 0x43 &&
        patch[4] == 0x48;
    if (hasHeader) pos = 5;

    final out = List<int>.from(source);
    while (true) {
      if (pos + 3 <= patch.length &&
          patch[pos] == 0x45 &&
          patch[pos + 1] == 0x4F &&
          patch[pos + 2] == 0x46) {
        break;
      }
      if (pos + 5 > patch.length) return null;

      final offset =
          (patch[pos] << 16) | (patch[pos + 1] << 8) | patch[pos + 2];
      final len = (patch[pos + 3] << 8) | patch[pos + 4];
      pos += 5;

      if (len == 0) {
        // RLE：2 字节重复次数 + 1 字节填充值
        if (pos + 3 > patch.length) return null;
        final count = (patch[pos] << 8) | patch[pos + 1];
        final fill = patch[pos + 2];
        pos += 3;
        _ensure(out, offset + count);
        for (var i = 0; i < count; i++) {
          out[offset + i] = fill;
        }
        continue;
      }

      if (pos + len > patch.length) return null;
      _ensure(out, offset + len);
      for (var i = 0; i < len; i++) {
        out[offset + i] = patch[pos + i];
      }
      pos += len;
    }
    return Uint8List.fromList(out);
  }

  static void _ensure(List<int> out, int size) {
    while (out.length < size) {
      out.add(0x00);
    }
  }

  static bool _sameAt(Uint8List a, Uint8List b, int i) {
    final av = i < a.length ? a[i] : -1;
    final bv = i < b.length ? b[i] : -1;
    return av == bv;
  }
}
