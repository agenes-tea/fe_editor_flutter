import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/core/chapter_events.dart';
import 'package:fe_editor/core/disassembler.dart';

const dir = '/root/workspace/game-rom';
void main() {
  test('FE7 cmd table entries for 0x46/0x75', () {
    final s = RomSession.open(File('$dir/火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba').readAsBytesSync(), 'x.gba')!;
    final ce = ChapterEvents(s.rom.liveRom);
    final t = ce.commandTable()!;
    print('cmdTable 0x${t.offset.toRadixString(16)} count=${t.count}');
    for (final cmd in [0x46, 0x75, 0x43, 0x42, 0x7d, 0x2]) {
      final sz = ce.commandSize(t, cmd);
      final handler = s.rom.liveRom.data;
      final ptr = handler[t.offset + 8*cmd] | (handler[t.offset+8*cmd+1]<<8) | (handler[t.offset+8*cmd+2]<<16) | (handler[t.offset+8*cmd+3]<<24);
      print('cmd=0x${cmd.toRadixString(16)} size=$sz handler=0x${ptr.toRadixString(16)}');
    }
    // 反汇编 0x46 的 handler 看看在干什么
    final d = ArmDisassembler(s.rom.liveRom.data);
    for (final cmd in [0x46]) {
      final h = s.rom.liveRom.data;
      var ptr = h[t.offset + 8*cmd] | (h[t.offset+8*cmd+1]<<8) | (h[t.offset+8*cmd+2]<<16) | (h[t.offset+8*cmd+3]<<24);
      final off = (ptr & 0x1FFFFFF) & ~1;
      print('--- cmd 0x${cmd.toRadixString(16)} handler @0x${off.toRadixString(16)}');
      for (final l in d.disassemble(off, DisasmMode.thumb, 14)) {
        print('   ${l.text}');
      }
    }
  });
}
