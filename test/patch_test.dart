import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/patch_format.dart';
import 'package:fe_editor/core/rom_buffer.dart';

Uint8List bytes(List<int> v) => Uint8List.fromList(v);

void main() {
  group('UPS', () {
    test('往返：小改动', () {
      final src = bytes(List.generate(300, (i) => i & 0xFF));
      final dst = Uint8List.fromList(src);
      dst[10] = 0xAA;
      dst[11] = 0xBB;
      dst[200] = 0x00;

      final patch = UpsPatch.create(src, dst);
      final out = UpsPatch.apply(patch, src);
      expect(out, isNotNull);
      expect(out, equals(dst));
    });

    test('往返：连续差异段 + 目标更长', () {
      final src = bytes(List.generate(1000, (i) => i & 0xFF));
      final dst = Uint8List.fromList(List.generate(1200, (i) => (i * 7) & 0xFF));
      final patch = UpsPatch.create(src, dst);
      final out = UpsPatch.apply(patch, src);
      expect(out, isNotNull);
      expect(out!.length, 1200);
      expect(out, equals(dst));
    });

    test('往返：无差异', () {
      final src = bytes(List.generate(64, (i) => i));
      final patch = UpsPatch.create(src, src);
      final out = UpsPatch.apply(patch, src);
      expect(out, equals(src));
    });

    test('CRC 不匹配时拒绝', () {
      final src = bytes(List.generate(300, (i) => i & 0xFF));
      final dst = Uint8List.fromList(src);
      dst[5] = 1;
      final patch = UpsPatch.create(src, dst);
      final wrong = Uint8List.fromList(src);
      wrong[0] ^= 0xFF;
      expect(UpsPatch.apply(patch, wrong), isNull);
    });

    test('真实 ROM：改动后往返', () async {
      final data = await File(
              '/root/workspace/game-rom/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba')
          .readAsBytes();
      final dst = Uint8List.fromList(data);
      // 改单位表里几个字节
      dst[0xC4C158 + 12] = 250;
      dst[0xC4C158 + 28] = 99;
      final patch = UpsPatch.create(data, dst);
      expect(patch.length, lessThan(1000));
      final out = UpsPatch.apply(patch, data);
      expect(out, isNotNull);
      expect(out, equals(dst));
    });
  });

  group('IPS', () {
    test('往返：小改动', () {
      final src = bytes(List.generate(300, (i) => i & 0xFF));
      final dst = Uint8List.fromList(src);
      dst[10] = 0xAA;
      dst[100] = 0xBB;

      final patch = IpsPatch.create(src, dst);
      expect(patch, isNotNull);
      final out = IpsPatch.apply(patch!, src);
      expect(out, isNotNull);
      expect(out, equals(dst));
    });

    test('超出 0xFFFFFF 时拒绝生成', () {
      final src = bytes(List.filled(0x1000010, 0));
      final dst = Uint8List.fromList(src);
      dst[0x1000005] = 1;
      expect(IpsPatch.exceedsRange(src, dst), isTrue);
      expect(IpsPatch.create(src, dst), isNull);
    });
  });

  group('RomBuffer', () {
    test('读写基本类型', () {
      final b = RomBuffer(Uint8List(16));
      b.writeU8(0, 0x12);
      b.writeU16(2, 0x1234);
      b.writeU32(4, 0x12345678);
      expect(b.u8(0), 0x12);
      expect(b.u16(2), 0x1234);
      expect(b.u32(4), 0x12345678);
    });

    test('空位搜索返回 4 字节对齐起点', () {
      final data = Uint8List(64);
      for (var i = 0; i < 64; i++) {
        data[i] = 0xAA;
      }
      // 从偏移 13 开始放 20 个 0xFF
      for (var i = 13; i < 33; i++) {
        data[i] = 0xFF;
      }
      final b = RomBuffer(data);
      final free = b.findFreeSpace(16);
      expect(free, 16); // 13 对齐到 16
      expect(free % 4, 0);
    });

    test('空间不足返回 -1', () {
      final data = Uint8List(32)..fillRange(0, 32, 0xAA);
      expect(RomBuffer(data).findFreeSpace(16), -1);
    });
  });
}
