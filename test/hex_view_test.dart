import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/hex_view.dart';
import 'package:fe_editor/core/rom_buffer.dart';

void main() {
  test('按行格式化与 ASCII 预览', () {
    final data = Uint8List.fromList(List.generate(20, (i) => i));
    data[0] = 0x41; // 'A'
    final v = HexView(RomBuffer(data));
    expect(v.rowCount, 2);
    expect(v.offsetLabel(0), '00000000');
    expect(v.offsetLabel(1), '00000010');
    expect(v.hexAt(0).startsWith('41 01 02 03'), isTrue);
    expect(v.asciiAt(0).startsWith('A.'), isTrue);
    // 第二行只有 4 字节，其余补空格
    expect(v.hexAt(1).trim().split(' ').length, 4);
  });

  test('搜索字节序列', () {
    final data = Uint8List.fromList([1, 2, 3, 1, 2, 3, 4, 5]);
    final v = HexView(RomBuffer(data));
    expect(v.search([1, 2, 3]), [0, 3]);
    expect(v.search([9, 9]), isEmpty);
    expect(v.search([]), isEmpty);
  });

  test('空位搜索', () {
    final data = Uint8List(32)..fillRange(0, 32, 0xAA);
    for (var i = 8; i < 20; i++) {
      data[i] = 0xFF;
    }
    final v = HexView(RomBuffer(data));
    final run = v.findFreeRun(0, minLength: 8);
    expect(run, isNotNull);
    expect(run!.offset, 8);
    expect(run.length, 12);
  });

  test('parseHex 解析与容错', () {
    expect(parseHex('12 34 AB'), [0x12, 0x34, 0xAB]);
    expect(parseHex('0x1234'), isNull); // 奇数长度（去掉 x 后 123 => 4,2,3 奇数）
    expect(parseHex('12 3'), isNull);
    expect(parseHex(''), isNull);
    expect(parseHex('zz'), isNull);
  });
}
