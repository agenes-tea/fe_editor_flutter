import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/chapter_events.dart';

const dir = '/root/workspace/game-rom';
void main() {
  test('FE7 ch6 area scripts', () {
    final s = RomSession.open(File('$dir/火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba').readAsBytesSync(), 'x.gba')!;
    final rom = s.rom.liveRom;
    final ce = ChapterEvents(rom);
    for (final ptr in [0x8d748bc, 0x8d74960, 0x8d74a14]) {
      final off = FeRom.toOffset(ptr);
      print('=== script 0x${ptr.toRadixString(16)} @0x${off.toRadixString(16)}');
      final units = ce.loadedUnits(ptr);
      print('  LOADUNIT 单位数 = ${units.length}');
      for (final u in units) {
        print('    char=${u.charId} class=${u.classId} xy=${u.x},${u.y} alg=${u.allegiance} lv=${u.level}');
      }
      // 逐条字
      var at = off;
      for (var i = 0; i < 24; i++) {
        final w = FeRom.u32(rom.data, at);
        final cmd = w & 0xFFFF;
        print('   +${(at-off).toString().padLeft(3)} 0x${w.toRadixString(16).padLeft(8,'0')} cmd=0x${cmd.toRadixString(16)}');
        if (cmd == 0) break;
        final t = ce.commandTable();
        final sz = (t != null && cmd < t.count) ? ce.commandSize(t, cmd) : 1;
        at += 4 * sz;
      }
    }
  });
}
