import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/chapter_events.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/core/unit_placement.dart';

const dir = '/root/workspace/game-rom';

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');

void main() {
  test('probe chest/shop second word', () {
    final files = Directory(dir).listSync().map((f) => f.path).toList();
    for (final p in files) {
      final f = File(p);
      if (!f.path.endsWith('.gba')) continue;
      final bytes = f.readAsBytesSync();
      final rom = RomSession.open(bytes, f.path);
      if (rom == null) continue;
      final id = rom.table.id;
      if (!id.startsWith('FE')) continue;
      final up = UnitPlacement(rom.rom);
      final ce = ChapterEvents(rom.liveRom);
      print('===== $id ${f.path.split('/').last} (size=${bytes.length ~/ 1024 ~/ 1024}MB) chapters=${up.chapterCount}');
      var shown = 0;
      for (var ch = 0; ch < up.chapterCount && shown < 12; ch++) {
        final ev = up.eventGroupOffset(ch);
        if (ev <= 0) continue;
        for (final e in ce.all(ev)) {
          final t = e.check & 0xFFFF;
          if (t != 7 && t != 10) continue;
          final x = e.value & 0xFF;
          final y = (e.value >> 8) & 0xFF;
          final w2 = e.script; // 第 2 字原值
          final isPtr = FeRom.isPointer(w2, rom.rom.data.length);
          String head = '';
          if (isPtr) {
            final off = FeRom.toOffset(w2);
            head = ' -> [${hx(rom.rom.data.sublist(off, off + 16))}]';
          }
          print('  ch$ch ${t == 7 ? "CHES" : "SHOP"} ($x,$y) '
              'w2=0x${w2.toRadixString(16)}${isPtr ? " (ptr)" : ""}$head');
          shown++;
          if (shown >= 12) break;
        }
      }
    }
  });
}
