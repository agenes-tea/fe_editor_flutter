import 'dart:typed_data';

import 'package:fe_editor/core/text_codec.dart';
import 'package:flutter_test/flutter_test.dart';

/// Utf8Codec.decode 的健壮性：这些 ROM 的文本表是「UTF-8 中文为主 +
/// 旧版 SJIS/二进制残留」的混合体，任何字节流都必须能解码而不抛异常
/// （UI 里一条坏文本抛异常会白掉整页）。
void main() {
  test('合法 UTF-8 中文正常解码', () {
    expect(Utf8Codec.decode(_utf8('埃德里克')), '埃德里克');
    expect(Utf8Codec.decode(_utf8('铁剑 Lv1')), '铁剑 Lv1');
  });

  test('孤立续接字节 / 旧版 SJIS 残留不抛异常', () {
    // HoloEmblem 实测条目：前段是旧版 SJIS 字节，0x00 终止
    final legacy = [0x49, 0x6d, 0x8d, 0x85, 0x8f, 0x86, 0x85, 0x83, 0x95,
        0xbc, 0xa7, 0x8b, 0x85, 0x00];
    expect(Utf8Codec.decode(Uint8List.fromList(legacy)), isNotEmpty);

    // 二进制垃圾（佣兵公司实测条目开头 59 ff 07 e0）
    final garbage = [0x59, 0xff, 0x07, 0xe0, 0xf8, 0xbb, 0x02, 0x00];
    expect(Utf8Codec.decode(Uint8List.fromList(garbage)), isNotEmpty);
  });

  test('全 256 字节覆盖与截断多字节序列都不抛异常', () {
    expect(Utf8Codec.decode(Uint8List.fromList(List.generate(0x100, (b) => b))),
        isA<String>());
    // E4BDBF=使，E794A8=用，末尾 E5 80 是缺一个续接字节的半截序列
    final truncated = [0xe4, 0xbd, 0xbf, 0xe7, 0x94, 0xa8, 0xe5, 0x80];
    expect(Utf8Codec.decode(Uint8List.fromList(truncated)), '使用');
  });

  test('GBK 双字节明文解码', () {
    // '铁' 的 GBK 编码 0xCCFA
    expect(GbkCodec.decode(Uint8List.fromList([0xCC, 0xFA, 0x20, 0x41])),
        '铁 A');
  });
}

/// 测试里把字符串转 UTF-8 字节（不 import dart:convert 的 Utf8Codec，避免同名冲突）。
Uint8List _utf8(String s) {
  final out = <int>[];
  for (final r in s.runes) {
    if (r < 0x80) {
      out.add(r);
    } else if (r < 0x800) {
      out.add(0xC0 | (r >> 6));
      out.add(0x80 | (r & 0x3F));
    } else {
      out.add(0xE0 | (r >> 12));
      out.add(0x80 | ((r >> 6) & 0x3F));
      out.add(0x80 | (r & 0x3F));
    }
  }
  return Uint8List.fromList(out);
}
