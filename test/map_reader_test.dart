import 'dart:io';
import 'dart:typed_data';

import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/map_reader.dart';
import 'package:flutter_test/flutter_test.dart';

Directory get _romDir => Directory('${Platform.environment['HOME']}/workspace/game-rom');

File _romByKeyword(String keyword) {
  for (final f in _romDir.listSync()) {
    if (f is File && f.path.contains(keyword)) return f;
  }
  throw StateError('找不到文件名包含 $keyword 的 ROM');
}

FeRom _load(String keyword) {
  final data = Uint8List.fromList(_romByKeyword(keyword).readAsBytesSync());
  return FeRom(data, FeRom.detectTable(data)!);
}

void main() {
  group('章节与地图数据', () {
    test('FE8J：章节数与首章尺寸', () {
      final reader = MapReader(_load('1692 -'));
      expect(reader.available, isTrue);
      expect(reader.chapterCount, greaterThan(50));
      final map = reader.chapterMap(0);
      expect(map, isNotNull);
      expect(map!.width, 15);
      expect(map.height, 10);
      expect(map.tiles.length, 150);
    });

    test('每章都能读出砖块数据或明确为空', () {
      final reader = MapReader(_load('1692 -'));
      var ok = 0;
      for (var ch = 0; ch < reader.chapterCount; ch++) {
        final map = reader.chapterMap(ch);
        if (map == null) continue;
        expect(map.width, greaterThan(0));
        expect(map.height, greaterThan(0));
        expect(map.tiles.length, map.width * map.height);
        ok++;
      }
      expect(ok, greaterThan(50), reason: '只有 $ok 章能读出地图');
    });

    test('五个版本都能读到章节', () {
      for (final keyword in ['0378', '0979', '1235', '1692 -', '铠甲']) {
        final reader = MapReader(_load(keyword));
        expect(reader.available, isTrue, reason: '$keyword 地图表不可用');
        expect(reader.chapterCount, greaterThan(10), reason: '$keyword 章节数');
        var readable = 0;
        for (var ch = 0; ch < reader.chapterCount && readable < 3; ch++) {
          if (reader.chapterMap(ch) != null) readable++;
        }
        expect(readable, greaterThan(0), reason: '$keyword 没有任何可读地图');
      }
    });
  });

  group('渲染', () {
    test('第 0 章能渲染出非空画面', () {
      final reader = MapReader(_load('1692 -'));
      final img = reader.renderMap(0);
      expect(img, isNotNull);
      expect(img!.width, 15 * 16);
      expect(img.height, 10 * 16);
      // 地图整片铺满，不应有透明区域
      expect(img.opaqueRatio, greaterThan(0.99));
    });

    test('不同章节渲染结果不同', () {
      final reader = MapReader(_load('1692 -'));
      final a = reader.renderMap(0)!;
      final b = reader.renderMap(3)!;
      var diff = 0;
      final n = a.pixels.length < b.pixels.length
          ? a.pixels.length
          : b.pixels.length;
      for (var i = 0; i < n; i++) {
        if (a.pixels[i] != b.pixels[i]) diff++;
      }
      expect(diff, greaterThan(100), reason: '两张地图完全一样，渲染可能有误');
    });

    test('多数章节能渲染', () {
      final reader = MapReader(_load('1692 -'));
      var ok = 0;
      var total = 0;
      for (var ch = 0; ch < reader.chapterCount; ch++) {
        final map = reader.chapterMap(ch);
        if (map == null) continue;
        total++;
        final img = reader.renderMap(ch);
        if (img != null && img.opaqueRatio > 0.99) ok++;
      }
      expect(ok, greaterThan(total * 0.8),
          reason: '只有 $ok / $total 章渲染正常');
    });
  });

  group('地形名与砖块', () {
    test('地形名能解出且不为空', () {
      final reader = MapReader(_load('1692 -'));
      // 实测：0=ーー(不可通行) 1=平地 2=道 3=村 4=閉じ村
      expect(reader.terrainName(0), 'ーー');
      expect(reader.terrainName(1), '平地');
      expect(reader.terrainName(2), '道');
      expect(reader.terrainName(3), '村');
    });

    test('砖块数量为正', () {
      final reader = MapReader(_load('1692 -'));
      expect(reader.chipCount(0), greaterThan(100));
    });
  });
}
