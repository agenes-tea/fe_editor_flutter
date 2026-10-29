import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/lz77_compress.dart';
import 'package:fe_editor/core/portrait.dart' show Lz77;
import 'package:flutter_test/flutter_test.dart';

Directory get _romDir => Directory('${Platform.environment['HOME']}/workspace/game-rom');

File _romByKeyword(String keyword) {
  for (final f in _romDir.listSync()) {
    if (f is File && f.path.contains(keyword)) return f;
  }
  throw StateError('找不到文件名包含 $keyword 的 ROM');
}

void _roundTrip(Uint8List data, String label) {
  final packed = Lz77Compressor.compress(data);
  expect(packed[0], 0x10, reason: '$label 头字节');
  final declared = packed[1] | (packed[2] << 8) | (packed[3] << 16);
  expect(declared, data.length, reason: '$label 长度字段');
  final unpacked = Lz77.decompress(packed, 0);
  expect(unpacked, isNotNull, reason: '$label 解压失败');
  expect(unpacked!.length, data.length, reason: '$label 解压长度');
  for (var i = 0; i < data.length; i++) {
    if (unpacked[i] != data[i]) {
      fail('$label 第 $i 字节不一致: ${data[i]} != ${unpacked[i]}');
    }
  }
}

void main() {
  group('LZ77 压缩往返', () {
    test('空数据', () {
      final packed = Lz77Compressor.compress(Uint8List(0));
      expect(packed.length, 4);
      expect(packed.sublist(0, 4), [0x10, 0, 0, 0]);
    });

    test('单个字节（小于解压器最小长度，不属于本格式）', () {
      // 解压器把 size < 3 判为非法（地图/图形不会这么小），
      // 所以压缩器只需要保证 size >= 3 的往返一致
      final packed = Lz77Compressor.compress(Uint8List.fromList([0x42]));
      expect(packed.sublist(0, 4), [0x10, 1, 0, 0]);
      expect(packed.sublist(4), [0x00, 0x42]);
    });

    test('3 字节最小合法块', () {
      _roundTrip(Uint8List.fromList([0x11, 0x22, 0x33]), '3 字节');
    });

    test('全 0（长回溯）', () {
      _roundTrip(Uint8List(4096), '全 0');
    });

    test('全 0xFF', () {
      _roundTrip(Uint8List(3000)..fillRange(0, 3000, 0xFF), '全 FF');
    });

    test('重复模式', () {
      final data = Uint8List(2000);
      for (var i = 0; i < data.length; i++) {
        data[i] = [1, 2, 3, 4][i % 4];
      }
      _roundTrip(data, '周期 4');
    });

    test('随机数据（不可压缩）', () {
      final rnd = Random(1234);
      final data = Uint8List(1024);
      for (var i = 0; i < data.length; i++) {
        data[i] = rnd.nextInt(256);
      }
      _roundTrip(data, '随机数据');
    });

    test('超过窗口大小的数据', () {
      final rnd = Random(99);
      final data = Uint8List(9000);
      for (var i = 0; i < data.length; i++) {
        data[i] = rnd.nextInt(4);
      }
      _roundTrip(data, '9000 字节');
    });

    test('真实 FE8 地图数据往返', () {
      final bytes = _romByKeyword('1692 -').readAsBytesSync();
      final data = Uint8List.fromList(bytes);
      final rom = FeRom(data, FeRom.detectTable(data)!);
      // 第 0 章地图：map plist 第 4 项，LZ77 压缩、15×10
      final settingBase = rom.pointerAt(0x0BAB1C);
      final mapSlot = FeRom.u8(rom.data, settingBase + 8);
      final plistBase = rom.pointerAt(0x034588);
      final mapPtr = FeRom.u32(rom.data, plistBase + 4 * mapSlot);
      final mapOff = FeRom.toOffset(mapPtr);
      final raw = Lz77.decompress(rom.data, mapOff);
      expect(raw, isNotNull);
      expect(raw!.length, 302);
      expect(raw[0], 15);
      expect(raw[1], 10);
      _roundTrip(raw, 'FE8 第 0 章地图');
    });
  });

  group('压缩率', () {
    test('地图数据压缩后不膨胀', () {
      // 典型地图：大量重复砖块，压缩后应明显小于原始
      final data = Uint8List(302);
      data[0] = 15;
      data[1] = 10;
      for (var i = 2; i + 1 < data.length; i += 2) {
        data[i] = 2;
        data[i + 1] = 0;
      }
      final packed = Lz77Compressor.compress(data);
      expect(packed.length, lessThan(data.length),
          reason: '高度重复的数据压缩后应更小');
    });
  });
}
