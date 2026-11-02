import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/chapter_events.dart';

const dir = '/root/workspace/game-rom';
void main() {
  test('FE7 ch6 flag scripts', () {
    final s = RomSession.open(File('$dir/火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba').readAsBytesSync(), 'x.gba')!;
    final rom = s.rom.liveRom;
    final ce = ChapterEvents(rom);
    final t = ce.commandTable()!;
    // flag 条目：t=1 的 4 条，script 分别指向
    for (final spec in [
      (0x8d7480c, 'flag 0x19'),
      (0x8d74740, 'flag 0x7'),
      (0x8d7476c, 'flag 0x8'),
      (0x8d747c0, 'flag 0xb'),
      (0x8d6f71c, 'flag 0x65'),
    ]) {
      final off = FeRom.toOffset(spec.$1);
      print('=== ${spec.$2} @0x${off.toRadixString(16)}');
      var at = off;
      for (var i = 0; i < 20; i++) {
        final w = FeRom.u32(rom.data, at);
        final cmd = w & 0xFFFF;
        print('   +${(at-off).toString().padLeft(3)} cmd=0x${cmd.toRadixString(16)} arg0=0x${(w>>16).toRadixString(16)}');
        if (cmd == 0) break;
        final sz = cmd < t.count ? ce.commandSize(t, cmd) : 1;
        if (sz <= 0) break;
        at += 4 * sz;
      }
    }
  });
}
