import 'dart:io';

import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/portrait.dart';
import 'package:flutter_test/flutter_test.dart';

const dir = '/root/workspace/game-rom';
const fe6jp =
    '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const fe7jp =
    '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe8jp =
    '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

FeRom _open(String path) {
  final data = File(path).readAsBytesSync();
  final table = FeRom.detectTable(data);
  expect(table, isNotNull, reason: path);
  return FeRom(data, table!);
}

/// 职业页的地图头像 / 职业卡：职业 → defaultPortraitId(+08) → 肖像表。
/// 三个原版都应在前若干职业里解出若干张真图。
void main() {
  for (final path in [fe6jp, fe7jp, fe8jp]) {
    test('职业地图图标 $path', () {
      final rom = _open(path);
      final r = PortraitReader(rom);

      var maps = 0;
      var cards = 0;
      final n = rom.classCount;
      for (var i = 0; i < n && (maps < 3 || cards < 3); i++) {
        final pid = rom.classPortraitId(i);
        if (pid < 0) continue;
        final m = r.mapFaceImage(pid);
        if (m != null) {
          expect(m.width, 32);
          expect(m.height, 32);
          expect(m.opaqueRatio, greaterThan(0.02), reason: 'mapFace #$i');
          maps++;
        }
        final c = r.classCardImage(pid);
        if (c != null) {
          expect(c.width, 80);
          expect(c.height, 80);
          cards++;
        }
      }
      expect(maps, greaterThan(0), reason: '至少一个职业有地图头像');
      r.dispose();
    });
  }
}
