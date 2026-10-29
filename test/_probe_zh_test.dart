import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

const dir = '/root/workspace/game-rom';
void main() {
  test('raw slot bytes', () {
    final d = File('$dir/火焰之纹章-铠甲的呼唤.gba').readAsBytesSync();
    print('ROM size = ${d.length} = 0x${d.length.toRadixString(16)}');
    final slot = 0xA2A0;
    final b = d.sublist(slot, slot + 4);
    print('slot 0xA2A0 bytes = ${b.map((x) => x.toRadixString(16).padLeft(2, "0")).join(" ")}');
    final v = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
    print('as u32 LE = 0x${v.toRadixString(16)}');
    final vbe = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    print('as u32 BE = 0x${vbe.toRadixString(16)}');
    // FE8U 正常 ROM 的同一槽
    final d8 = File('$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba').readAsBytesSync();
    final b8 = d8.sublist(0xA2A0, 0xA2A0 + 4);
    print('FE8J slot 0xA2A0 bytes = ${b8.map((x) => x.toRadixString(16).padLeft(2, "0")).join(" ")}');
  });
}
