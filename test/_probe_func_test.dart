import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/disassembler.dart';

const dir = '/root/workspace/game-rom';
void main() {
  test('probe funcs', () {
    final s = RomSession.open(File('$dir/火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba').readAsBytesSync(), 'x.gba')!;
    final rom = s.rom.liveRom;
    final d = ArmDisassembler(rom.data);
    for (final ptr in [0x0807ad65, 0x0807a0e0, 0x080c0790]) {
      final off = FeRom.toOffset(ptr) & ~1;
      print('=== 0x${ptr.toRadixString(16)} -> off 0x${off.toRadixString(16)}');
      final bytes = [for (var i = 0; i < 16; i++) rom.data[off + i]];
      print('   raw: ${bytes.map((b) => b.toRadixString(16).padLeft(2,'0')).join(' ')}');
      for (final l in d.disassemble(off, DisasmMode.thumb, 10)) {
        print('   ${l.text}');
      }
    }
  });
}
