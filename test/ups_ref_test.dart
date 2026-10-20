import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/patch_format.dart';

String hex(Uint8List b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('UPS 编码与独立实现逐字节一致', () {
    final src = Uint8List.fromList(List.generate(300, (i) => i & 0xFF));
    final dst = Uint8List.fromList(src);
    dst[10] = 0xAA;
    dst[11] = 0xBB;
    dst[200] = 0x00;
    // 期望值由独立的 Python 实现（同一 UPS 规范）产出
    const expected = '555053312c812c818aa0b0003b80c800eefcbc3a27285902eb673cf5';
    expect(hex(UpsPatch.create(src, dst)), expected);
  });
}
