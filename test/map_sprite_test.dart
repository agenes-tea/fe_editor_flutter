import 'dart:io';

import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/map_sprite.dart';
import 'package:flutter_test/flutter_test.dart';

const dir = '/root/workspace/game-rom';
const fe6jp =
    '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const fe7jp =
    '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe7us =
    '$dir/1235 - 火炎之纹章-烈火之剑 Fire Emblem(US)(Nintendo)(128Mb).gba';
const fe8jp =
    '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

FeRom _open(String path) {
  final data = File(path).readAsBytesSync();
  final table = FeRom.detectTable(data);
  expect(table, isNotNull, reason: path);
  return FeRom(data, table!);
}

void main() {
  test('FE8J 地图小人表：条目数与结构', () {
    final rom = _open(fe8jp);
    final reader = MapSpriteReader(rom);
    expect(reader.available, isTrue);
    // 反编译 unit_icon_wait_table 为 107 条
    expect(reader.count, 107);

    final e = reader.entry(0);
    expect(e, isNotNull);
    expect(e!.sizeCode, lessThanOrEqualTo(2));
    expect(FeRom.isPointer(e.sheetPointer, rom.length), isTrue);
    reader.dispose();
  });

  test('FE8J 每个职业都能按 SMSId 取到地图小人', () {
    final rom = _open(fe8jp);
    final reader = MapSpriteReader(rom);
    var hit = 0;
    for (var c = 0; c < rom.classCount && c < 40; c++) {
      final e = reader.entryForClass(c);
      if (e == null) continue;
      hit++;
      final f = reader.frame(e);
      expect(f, isNotNull, reason: 'class $c');
      final (w, h) = e.frameSize;
      expect(f!.width, w);
      expect(f.height, h);
    }
    expect(hit, greaterThan(20), reason: '至少 20 个职业能取到小人');
    reader.dispose();
  });

  test('FE8J 渲染出的像素是真实图形（描边色占比合理）', () {
    final rom = _open(fe8jp);
    final reader = MapSpriteReader(rom);
    // 取几个已知尺寸不同的职业，验证解码不空、且有轮廓
    var checked = 0;
    for (var c = 0; c < rom.classCount && checked < 6; c++) {
      final e = reader.entryForClass(c);
      if (e == null) continue;
      final f = reader.frame(e);
      if (f == null) continue;
      final ratio = f.opaqueRatio;
      expect(ratio, greaterThan(0.05), reason: 'class $c 不透明像素太少');
      expect(ratio, lessThan(0.95), reason: 'class $c 几乎全不透明');
      checked++;
    }
    expect(checked, greaterThanOrEqualTo(3));
    reader.dispose();
  });

  test('三个原版都能定位到地图小人表', () {
    for (final path in [fe6jp, fe7jp, fe7us, fe8jp]) {
      final rom = _open(path);
      final reader = MapSpriteReader(rom);
      expect(reader.available, isTrue, reason: path);
      expect(reader.count, greaterThan(50), reason: path);
      reader.dispose();
    }
  });

  test('帧数解析：实测多为 3 帧', () {
    final rom = _open(fe8jp);
    final reader = MapSpriteReader(rom);
    final e = reader.entryForClass(2) ?? reader.entry(1);
    expect(e, isNotNull);
    expect(reader.frameCount(e!), greaterThanOrEqualTo(3));
    // 越界帧返回 null，不能崩
    expect(reader.frame(e, frame: 99), isNull);
    reader.dispose();
  });

  test('四个原版调色板都能定位且内容匹配', () {
    // 这些是 unit_icon_pal_player.agbpal 在 ROM 中的实际位置（反编译
    // data_59E8E0.s 的 gPal_MapSprite：player/enemy/npc/after_action 四组连续）。
    final expectOffset = <String, int>{
      'FE6': 0x100968,
      'FE7J': 0x1900E8,
      'FE7U': 0x194594,
      'FE8J': 0x5C7340,
    };
    for (final path in [fe6jp, fe7jp, fe7us, fe8jp]) {
      final rom = _open(path);
      final reader = MapSpriteReader(rom);
      final expected = expectOffset[rom.table.id];
      expect(expected, isNotNull, reason: '无预期的调色板地址：${rom.table.id}');
      expect(reader.paletteLooksValid(expected!), isTrue,
          reason: '${rom.table.id} 调色板内容不匹配');
      expect(reader.locatePalette(), expected,
          reason: '${rom.table.id} 内容扫描应与写死地址一致');
      for (var g = 0; g < 4; g++) {
        final p = reader.palette(g);
        expect(p, isNotNull, reason: '${rom.table.id} 组 $g 调色板');
        // 索引 0 是透明，但**调色板里存的是 0x4290 而不是 0000**
        // （反编译 unit_icon_pal_player.agbpal 首色就是 0x4290）。
        // 早期按「首色必须 0000」做结构筛选用的是错误前提。
        expect(p!.argb[0], isNot(0), reason: '${rom.table.id} 组 $g 首色异常');
      }
      // 结构校验失败路径：调色板块之外 128 字节一定不合格（随机区）
      expect(reader.paletteLooksValid(0), isFalse, reason: '地址 0 不可能是调色板');
      reader.dispose();
    }
  });

  test('FE6/FE7 地图小人可渲染（四组配色）', () {
    for (final path in [fe6jp, fe7jp, fe7us]) {
      final rom = _open(path);
      final reader = MapSpriteReader(rom);
      var rendered = 0;
      for (var c = 0; c < rom.classCount && rendered < 4; c++) {
        final e = reader.entryForClass(c);
        if (e == null) continue;
        if (!reader.canRender(e)) continue;
        for (var g = 0; g < 4; g++) {
          final f = reader.frame(e, paletteGroup: g);
          expect(f, isNotNull, reason: '${rom.table.id} 职业 $c 组 $g');
          final ratio = f!.opaqueRatio;
          expect(ratio, greaterThan(0.05),
              reason: '${rom.table.id} 职业 $c 组 $g 不透明像素太少');
          expect(ratio, lessThan(0.95),
              reason: '${rom.table.id} 职业 $c 组 $g 几乎全不透明');
        }
        rendered++;
      }
      expect(rendered, greaterThan(0),
          reason: '${rom.table.id} 一个职业都渲染不出');
      reader.dispose();
    }
  });

  test('FE8U（铠甲的呼唤）调色板与站立表都能自动定位', () {
    // 20MB 重度改版：站立表从 0x8AF880 搬到了扩展区，调色板在 0x59EE20。
    final dir = '/root/workspace/game-rom';
    String? path;
    for (final f in Directory(dir).listSync()) {
      if (f.path.contains('铠甲')) path = f.path;
    }
    expect(path, isNotNull);
    final data = File(path!).readAsBytesSync();
    final table = FeRom.detectTable(data);
    expect(table, isNotNull);
    final rom = FeRom(data, table!);
    final reader = MapSpriteReader(rom);
    expect(reader.paletteLooksValid(0x59EE20), isTrue);
    expect(reader.palette(0), isNotNull);
    // 写死的 0x8AF880 在这个改版里是空的，必须回退到自动探测
    expect(reader.locatePalette(), 0x59EE20);
    expect(reader.count, greaterThan(100),
        reason: '站立表应能在扩展区被探测到（实测 109 条）');
    expect(reader.frame(reader.entry(1), paletteGroup: 0), isNotNull);
    reader.dispose();
  });

  // 玩家配色必须以蓝色为主：选错调色板时会渲染出一片紫粉/橙黄（v2.1.12~2.3.01）。
  test('四作玩家配色主色为蓝、敌军为红', () {
    for (final path in [fe6jp, fe7jp, fe7us, fe8jp]) {
      final rom = _open(path);
      final reader = MapSpriteReader(rom);
      final e = reader.entry(1);
      expect(e, isNotNull, reason: '${rom.table.id} 缺 id1');
      (int blue, int red) count(int group) {
        final img = reader.frame(e, paletteGroup: group);
        if (img == null) return (0, 0);
        var b = 0, r = 0;
        for (var i = 0; i < img.pixels.length; i += 4) {
          if (img.pixels[i + 3] == 0) continue;
          final rr = img.pixels[i], gg = img.pixels[i + 1], bb = img.pixels[i + 2];
          if (bb > rr + 25 && bb > gg + 10) b++;
          if (rr > bb + 40 && rr > gg + 15) r++;
        }
        return (b, r);
      }
      final (pb, pr) = count(0);
      final (eb, er) = count(1);
      expect(pb, greaterThan(pr), reason: '${rom.table.id} 玩家组应偏蓝');
      expect(er, greaterThan(eb), reason: '${rom.table.id} 敌军组应偏红');
      reader.dispose();
    }
  });
}
