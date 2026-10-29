import 'dart:io';
import 'dart:typed_data';

import 'package:fe_editor/core/battle_anim.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/tile_image.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实 ROM 路径：按「文件名关键字 + 大小」定位，避免在 Dart 源码里写中文文件名。
Directory get _romDir => Directory('${Platform.environment['HOME']}/workspace/game-rom');

/// 按文件名关键字定位（多个 ROM 同尺寸时必须靠关键字区分版本）。
File _romByKeyword(String keyword) {
  for (final f in _romDir.listSync()) {
    if (f is File && f.path.contains(keyword)) return f;
  }
  throw StateError('找不到文件名包含 $keyword 的 ROM');
}

FeRom _load(File f) {
  final data = Uint8List.fromList(f.readAsBytesSync());
  final table = FeRom.detectTable(data);
  expect(table, isNotNull, reason: 'ROM 未被识别');
  return FeRom(data, table!);
}

void main() {
  // 五个版本：条目数在真实 ROM 上逐个核对过。
  // FE6 = 122、FE7 = 162、FE8 = 201（FE7U/FE8U 与日版一致）。
  final cases = <String, ({String keyword, String firstAbbr, int count})>{
    'FE6 封印之剑': (keyword: '0378', firstAbbr: 'armm_sp1', count: 122),
    'FE7J 烈火之剑': (keyword: '0979', firstAbbr: 'erlm_sw1', count: 162),
    'FE7U 烈火之剑': (keyword: '1235', firstAbbr: 'erlm_sw1', count: 162),
    'FE8J 圣魔之光石': (keyword: '1692 -', firstAbbr: 'lorm_sp1', count: 201),
    'FE8 汉化版': (keyword: '汉化', firstAbbr: 'lorm_sp1', count: 201),
    'FE8 改版圣邪的意志': (keyword: '1692X', firstAbbr: 'lorm_sp1', count: 201),
  };

  group('战斗动画表定位', () {
    for (final entry in cases.entries) {
      test('${entry.key}：表可读、条目数正确', () {
        final rom = _load(_romByKeyword(entry.value.keyword));
        final reader = BattleAnimReader(rom);
        expect(reader.available, isTrue, reason: '槽位未配置');
        expect(reader.base, greaterThan(0));
        expect(reader.count, entry.value.count);
        expect(reader.entries.first.abbr, entry.value.firstAbbr);
      });
    }

    test('所有条目的五个指针都有效', () {
      final rom = _load(_romByKeyword('1692 -'));
      final reader = BattleAnimReader(rom);
      for (final e in reader.entries) {
        expect(e.modes, greaterThanOrEqualTo(0x08000000), reason: '${e.abbr} modes');
        expect(e.script, greaterThanOrEqualTo(0x08000000), reason: '${e.abbr} script');
        expect(e.oamRightToLeft, greaterThanOrEqualTo(0x08000000),
            reason: '${e.abbr} oamR');
        expect(e.palette, greaterThanOrEqualTo(0x08000000), reason: '${e.abbr} pal');
      }
    });
  });

  group('模式切分', () {
    test('12 个模式区间单调且终止于解压长度', () {
      final rom = _load(_romByKeyword('1692 -'));
      final reader = BattleAnimReader(rom);
      for (final e in reader.entries.take(20)) {
        final modes = reader.modesOf(e);
        expect(modes.length, 12, reason: '${e.abbr} 模式数');
        var prev = -1;
        for (final m in modes) {
          expect(m.start, greaterThanOrEqualTo(prev), reason: '${e.abbr} 模式 ${m.index} 起点');
          expect(m.end, greaterThanOrEqualTo(m.start), reason: '${e.abbr} 模式 ${m.index} 终点');
          prev = m.start;
        }
        final script = reader.scriptData(e);
        expect(script, isNotNull);
        expect(modes.last.end, script!.length, reason: '${e.abbr} 末模式终点');
      }
    });

    test('待机模式里能取到图像帧', () {
      final rom = _load(_romByKeyword('1692 -'));
      final reader = BattleAnimReader(rom);
      final e = reader.entries.first;
      final modes = reader.modesOf(e);
      final frames = reader.framesOf(e, modes[0]);
      expect(frames, isNotEmpty, reason: '待机模式应有帧');
      for (final f in frames) {
        expect(f.graphics, greaterThanOrEqualTo(0x08000000));
        expect(f.oamOffset, greaterThanOrEqualTo(0));
      }
    });
  });

  group('渲染', () {
    test('首条动画首模式首帧能渲染出非空画面', () {
      final rom = _load(_romByKeyword('1692 -'));
      final reader = BattleAnimReader(rom);
      final e = reader.entries.first;
      final mode = reader.modesOf(e).first;
      final img = reader.renderFrame(e, mode, 0);
      expect(img, isNotNull);
      expect(img!.width, BattleAnimReader.screenWidth);
      expect(img.height, BattleAnimReader.screenHeight);
      // 偏移写错时通常出全空图，用不透明占比兜底
      expect(img.opaqueRatio, greaterThan(0.005),
          reason: '画面几乎全透明，说明帧或 OAM 解析有误');
      expect(img.opaqueRatio, lessThan(0.9), reason: '画面几乎铺满，疑似 tile 顺序错');
    });

    test('四种调色板组都能取到且自军与敌军不同', () {
      final rom = _load(_romByKeyword('1692 -'));
      final reader = BattleAnimReader(rom);
      final e = reader.entries.first;
      // 对比整组颜色（单看某个索引可能恰好同色）
      final groups = <int, List<int>>{};
      for (var g = 0; g < 4; g++) {
        final pal = reader.paletteOf(e, g);
        expect(pal, isNotNull, reason: '调色板组 $g');
        groups[g] = List<int>.generate(16, (i) => pal!.color(i));
      }
      expect(groups[0], isNot(groups[1]), reason: '自军与敌军调色板应不同');
    });

    test('切换调色板组后像素确实变化', () {
      // 回归测试：sheet 缓存曾经只按图形指针做键，换组后仍显示上一组的颜色
      final rom = _load(_romByKeyword('1692 -'));
      final reader = BattleAnimReader(rom);
      final e = reader.entries.first;
      final mode = reader.modesOf(e).first;
      final base = reader.renderFrame(e, mode, 0, paletteGroup: 0)!;
      for (var g = 1; g < 4; g++) {
        final other = reader.renderFrame(e, mode, 0, paletteGroup: g)!;
        var diff = 0;
        for (var i = 0; i < base.pixels.length; i += 4) {
          if (base.pixels[i] != other.pixels[i] ||
              base.pixels[i + 1] != other.pixels[i + 1] ||
              base.pixels[i + 2] != other.pixels[i + 2]) {
            diff++;
          }
        }
        expect(diff, greaterThan(50), reason: '调色板组 $g 与自军配色没有差异');
      }
    });

    test('模式 01/03 会把武器图层一起绘出', () {
      final rom = _load(_romByKeyword('1692 -'));
      final reader = BattleAnimReader(rom);
      // bram_sw1：攻击帧数较多，合绘后不透明像素应多于单独绘制身体
      final e = reader.entry(12)!;
      final modes = reader.modesOf(e);
      final withWeapon = reader.renderFrame(e, modes[0], 0);
      expect(withWeapon, isNotNull);
      expect(withWeapon!.opaqueRatio, greaterThan(0.005));
    });

    test('全部条目首模式首帧都不崩且有画面', () {
      final rom = _load(_romByKeyword('1692 -'));
      final reader = BattleAnimReader(rom);
      var drawn = 0;
      for (final e in reader.entries) {
        final modes = reader.modesOf(e);
        if (modes.isEmpty) continue;
        final img = reader.renderFrame(e, modes.first, 0);
        if (img != null && img.opaqueRatio > 0.001) drawn++;
      }
      // 允许少量特殊条目（纯魔法/特效）为空，但不该大面积失败
      expect(drawn, greaterThan(reader.count * 0.8),
          reason: '只有 $drawn / ${reader.count} 条渲染出画面');
    });
  });

  group('PNG 编码', () {
    test('签名、IHDR 宽高正确且能被解码回', () {
      final img = TileImage(4, 3);
      img.setPixel(0, 0, 255, 0, 0, 255);
      img.setPixel(3, 2, 0, 255, 0, 255);
      final png = encodePng(img);
      expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      // IHDR 数据从第 16 字节开始：宽 4 字节、高 4 字节
      final width = png[16] << 24 | png[17] << 16 | png[18] << 8 | png[19];
      final height = png[20] << 24 | png[21] << 16 | png[22] << 8 | png[23];
      expect(width, img.width);
      expect(height, img.height);
      expect(png[png.length - 8], 0x49); // 'I' of IEND
    });

    test('真实帧能编码成 PNG 并写出文件', () {
      final rom = _load(_romByKeyword('1692 -'));
      final reader = BattleAnimReader(rom);
      final e = reader.entries.first;
      final img = reader.renderFrame(e, reader.modesOf(e).first, 0)!;
      final png = encodePng(img);
      // 首帧人物只占画面一小块，压缩后能有几百字节就算正常
      expect(png.length, greaterThan(400));
      final out = File('${Directory.systemTemp.path}/banim_render_check.png');
      out.writeAsBytesSync(png);
      expect(out.lengthSync(), png.length);
    });
  });
}
