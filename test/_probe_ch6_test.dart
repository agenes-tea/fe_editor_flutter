import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/unit_placement.dart';
import 'package:fe_editor/core/chapter_events.dart';
import 'package:fe_editor/core/map_reader.dart';

const dir = '/root/workspace/game-rom';
String hx(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2,'0')).join(' ');

void main() {
  test('FE7 ch6 doors and areas', () {
    final s = RomSession.open(File('$dir/火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba').readAsBytesSync(), 'x.gba')!;
    final rom = s.rom.liveRom;
    final up = UnitPlacement(s.rom);
    final ce = ChapterEvents(rom);
    final map = MapReader(rom);
    final m = map.chapterMap(6);
    print('ch6 map=${m?.width}x${m?.height} title="${up.chapterTitle(6)}"');
    final ev = up.eventGroupOffset(6);
    print('eventGroup=0x${ev.toRadixString(16)}');
    for (final e in ce.all(ev)) {
      final t = e.check & 0xFFFF;
      final v = e.value;
      final a = v & 0xFF, b = (v >> 8) & 0xFF;
      if (t == 5 || t == 6 || t == 7 || t == 8 || t == 9 || t == 10) {
        print('  ${e.kind.name} type=0x${t.toRadixString(16)} (${a},${b}) script=0x${e.script.toRadixString(16)} "${e.condition}"');
      }
    }
  });
}
