import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/core/item_catalog.dart';
import 'package:fe_editor/core/fe_rom.dart';

const dir = '/root/workspace/game-rom';
void main() {
  test('FE7J item 90 / 14 names', () {
    final s = RomSession.open(File('$dir/火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba').readAsBytesSync(), 'x.gba')!;
    final rom = s.rom.liveRom;
    final cat = ItemCatalog(rom);
    print('itemCount=${rom.itemCount}');
    for (final id in [14, 90]) {
      final e = cat.entryAt(id);
      print('item[$id] name="${rom.itemDisplayName(id)}" kind=${e?.kind.name} might=${e?.might} dur=${e?.durability} nameTextId=${e?.nameTextId}');
    }
    // 前 20 个道具名
    for (var i = 1; i <= 20; i++) {
      print('  [$i] "${rom.itemDisplayName(i)}"');
    }
  });
}
