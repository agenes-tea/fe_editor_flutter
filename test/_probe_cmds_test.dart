import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/core/chapter_events.dart';
import 'package:fe_editor/core/disassembler.dart';

const dir = '/root/workspace/game-rom';
void main() {
  test('FE7J cmd handlers', () {
    final s = RomSession.open(File('$dir/火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba').readAsBytesSync(), 'x.gba')!;
    final rom = s.rom.liveRom;
    final ce = ChapterEvents(rom);
    final t = ce.commandTable()!;
    final d = ArmDisassembler(rom.data);
    int handlerOf(int cmd) {
      final o = t.offset + 8 * cmd;
      return rom.data[o] | (rom.data[o+1]<<8) | (rom.data[o+2]<<16) | (rom.data[o+3]<<24);
    }
    for (final cmd in [0x75, 0x46, 0x1d, 0x4a, 0x43]) {
      final ptr = handlerOf(cmd);
      final off = (ptr & 0x1FFFFFF) & ~1;
      print('=== cmd 0x${cmd.toRadixString(16)} size=${ce.commandSize(t, cmd)} handler=0x${ptr.toRadixString(16)} @0x${off.toRadixString(16)}');
      for (final l in d.disassemble(off, DisasmMode.thumb, 16)) {
        print('   ${l.text}');
      }
    }
  });
}
