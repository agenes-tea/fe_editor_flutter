import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/chapter_events.dart';

const dir = '/root/workspace/game-rom';

void dump(FeRom rom, ChapterEvents ce, int ptr, String label) {
  final off = FeRom.toOffset(ptr);
  final t = ce.commandTable()!;
  print('=== $label script 0x${ptr.toRadixString(16)}');
  var at = off;
  for (var i = 0; i < 30; i++) {
    final w = FeRom.u32(rom.data, at);
    final cmd = w & 0xFFFF;
    // 打印命令 + 后续参数
    final sz = cmd < t.count ? ce.commandSize(t, cmd) : 1;
    final args = <String>[];
    for (var k = 1; k < sz && k < 6; k++) {
      args.add('0x${FeRom.u32(rom.data, at + 4*k).toRadixString(16)}');
    }
    print('   +${(at-off).toString().padLeft(3)} cmd=0x${cmd.toRadixString(16)} sz=$sz arg0=0x${(w>>16).toRadixString(16)} args=[${args.join(", ")}]');
    if (cmd == 0) break;
    if (sz <= 0) break;
    at += 4 * sz;
  }
}

void main() {
  test('FE7 ch6 area scripts full', () {
    final s = RomSession.open(File('$dir/火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba').readAsBytesSync(), 'x.gba')!;
    final rom = s.rom.liveRom;
    final ce = ChapterEvents(rom);
    dump(rom, ce, 0x8d748bc, '区域(8,1)');
    dump(rom, ce, 0x8d74960, '区域(16,7)');
    dump(rom, ce, 0x8d74a14, '区域(12,1)');
  });
}
