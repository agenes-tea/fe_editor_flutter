import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/unit_placement.dart';
import 'package:fe_editor/core/chapter_events.dart';

const dir = '/root/workspace/game-rom';
void main() {
  test('ch6 describe output', () {
    final s = RomSession.open(File('$dir/火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba').readAsBytesSync(), 'x.gba')!;
    final rom = s.rom.liveRom;
    final up = UnitPlacement(s.rom);
    final ce = ChapterEvents(rom)..itemNameOf = (id) => rom.itemDisplayName(id);
    final ev = up.eventGroupOffset(6);
    for (final e in ce.all(ev)) {
      print('${e.kind.name} t=0x${(e.check&0xFFFF).toRadixString(16)} "${e.condition}"');
    }
  });
}
