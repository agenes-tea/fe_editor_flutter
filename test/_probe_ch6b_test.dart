import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/unit_placement.dart';

const dir = '/root/workspace/game-rom';
String hx(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2,'0')).join(' ');
void main() {
  test('FE7 ch6 misc raw', () {
    final s = RomSession.open(File('$dir/火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba').readAsBytesSync(), 'x.gba')!;
    final rom = s.rom.liveRom;
    final up = UnitPlacement(s.rom);
    final ev = up.eventGroupOffset(6);
    final base = FeRom.toOffset(FeRom.u32(rom.data, ev + 0x0C));
    print('ch6 misc @0x${base.toRadixString(16)}');
    for (var i = 0; i < 12; i++) {
      final at = base + i * 12;
      final b = [for (var k = 0; k < 12; k++) FeRom.u8(rom.data, at + k)];
      final check = FeRom.u32(rom.data, at);
      final script = FeRom.u32(rom.data, at + 4);
      final value = FeRom.u32(rom.data, at + 8);
      print('[$i] ${hx(b)}  t=0x${(check&0xFFFF).toRadixString(16)} s=0x${script.toRadixString(16)} v=0x${value.toRadixString(16)}');
      if (check == 0) break;
    }
    print('--- loca 槽（门在这）');
    final lb = FeRom.toOffset(FeRom.u32(rom.data, ev + 0x08));
    for (var i = 0; i < 16; i++) {
      final at = lb + i * 12;
      final check = FeRom.u32(rom.data, at);
      final script = FeRom.u32(rom.data, at + 4);
      final value = FeRom.u32(rom.data, at + 8);
      print('[L$i] t=0x${(check&0xFFFF).toRadixString(16)} s=0x${script.toRadixString(16)} v=0x${value.toRadixString(16)}');
      if (check == 0) break;
    }
  });
}
