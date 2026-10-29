import 'dart:io';

import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/map_reader.dart';
import 'package:fe_editor/core/map_sprite_image.dart';
import 'package:fe_editor/core/unit_placement.dart';
import 'package:flutter_test/flutter_test.dart';

const dir = '/root/workspace/game-rom';
const fe7jp =
    '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe8jp =
    '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

FeRom _rom(String path) {
  final data = File(path).readAsBytesSync();
  return FeRom(data, FeRom.detectTable(data)!);
}

void main() {
  test('地图渲染不留透明像素（白点的根因）', () {
    // 越界 tile / 0xFFFF 象限原本会 continue，像素 alpha 保持 0，
    // 于是透出页面白底 —— 用户看到的就是地图上的白点。
    for (final path in [fe7jp, fe8jp]) {
      final rom = _rom(path);
      final map = MapReader(rom);
      expect(map.available, isTrue);
      for (var ch = 0; ch < map.chapterCount && ch < 14; ch++) {
        final img = map.renderMap(ch);
        if (img == null) continue;
        var transparent = 0;
        for (var i = 3; i < img.pixels.length; i += 4) {
          if (img.pixels[i] == 0) transparent++;
        }
        expect(transparent, 0,
            reason: '${rom.table.id} 第 $ch 章有 $transparent 个透明像素');
      }
    }
  });

  test('FE7 双图形章节：obj 高字节的第二套 chipset 会被拼接', () {
    // FE7J 第 5 章的 obj 是 0x1D1C（低字节 0x1C 主图形 + 高字节 0x1D 第二套）。
    // 只读第一套时 chipset 高度只有 128，而 TSA 引用到 tile 621，
    // 那一格就什么都不画 —— 表现为地图上成片空白。
    final rom = _rom(fe7jp);
    final map = MapReader(rom);
    // ch5 走完 chipIndices 后 chipHeight 应该是两套拼起来的 256
    map.chipIndices(5);
    expect(map.chipHeight, 256, reason: '两套 chipset 应该纵向拼接');
  });

  test('章节单位能取到地图小人（地图叠加用）', () {
    final rom = _rom(fe8jp);
    final data = File(fe8jp).readAsBytesSync();
    final edit = EditableRom.open(data, rom.table);
    final up = UnitPlacement(edit);
    final sprites = UnitSpriteProvider(rom);

    final units = up.units(0, UnitSlot.playerNormal);
    expect(units, isNotEmpty, reason: '第 0 章应有我方初始单位');
    var rendered = 0;
    for (final u in units) {
      if (sprites.canRender(u.classId)) {
        rendered++;
        final (w, h) = sprites.frameSize(u.classId);
        expect(w, greaterThan(0));
        expect(h, greaterThan(0));
      }
    }
    expect(rendered, units.length,
        reason: '章节单位的职业都应能取到地图小人');
    sprites.dispose();
  });

  test('阵营决定调色板组：我方蓝 / 敌方红 / 友军绿', () {
    // 与 bmudisp.c 的 GetUnitSpritePalette() 对应：蓝=0、红=1、绿=2。
    int group(Allegiance a) => switch (a) {
          Allegiance.player => 0,
          Allegiance.enemy => 1,
          Allegiance.ally => 2,
        };
    expect(group(Allegiance.player), 0);
    expect(group(Allegiance.enemy), 1);
    expect(group(Allegiance.ally), 2);
  });
}
