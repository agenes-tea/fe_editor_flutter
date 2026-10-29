import 'dart:typed_data';

import 'package:fe_editor/core/hex_view.dart';
import 'package:fe_editor/core/rom_buffer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const dir = '/root/workspace/game-rom';
const fe8jp =
    '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

/// 十六进制视图：按任意每行字节数取行内容，且不丢字节。
void main() {
  test('不同 perRow 下行内容都完整且不越界', () {
    final data = List<int>.generate(64, (i) => i);
    final view = HexView(RomBuffer(Uint8List.fromList(data)));

    for (final perRow in [4, 8, 16]) {
      final rows = (view.buffer.length + perRow - 1) ~/ perRow;
      final collected = <int>[];
      for (var r = 0; r < rows; r++) {
        final hex = view.hexAt(r, perRow: perRow);
        final parts = hex.trim().split(RegExp(r'\s+'));
        for (final p in parts) {
          if (p.isEmpty) continue;
          collected.add(int.parse(p, radix: 16));
        }
      }
      expect(collected, data, reason: 'perRow=$perRow 不应丢字节');
    }
  });

  test('ASCII 预览按 perRow 切分', () {
    final view = HexView(RomBuffer(Uint8List.fromList('ABCDEFGH'.codeUnits)));
    expect(view.asciiAt(0, perRow: 4), 'ABCD');
    expect(view.asciiAt(1, perRow: 4), 'EFGH');
    expect(view.asciiAt(2, perRow: 4), '    ');
  });
}
