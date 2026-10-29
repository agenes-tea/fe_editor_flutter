import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/ui/portrait_page.dart';

const dir = '/root/workspace/game-rom';
const fe6cn = '$dir/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

FeRom _open(String p) {
  final d = File(p).readAsBytesSync();
  return FeRom(d, FeRom.detectTable(d)!);
}

void main() {
  group('ROM 指纹', () {
    test('不同 ROM 的指纹不同', () {
      final a = _open(fe7jp).fingerprint;
      final b = _open(fe6cn).fingerprint;
      final c = _open(fe8jp).fingerprint;
      expect(a, isNot(b));
      expect(a, isNot(c));
      expect(b, isNot(c));
    });

    test('同一 ROM 多次读取指纹一致', () {
      expect(_open(fe7jp).fingerprint, _open(fe7jp).fingerprint);
    });
  });

  group('肖像缓存不跨 ROM 串图', () {
    test('同一个肖像索引在两个 ROM 下 key 不同', () {
      final cache = PortraitImageCache.instance;
      cache.bindRom(_open(fe7jp).fingerprint);
      final k7 = cache.keyFor(2, 1);

      cache.bindRom(_open(fe6cn).fingerprint);
      final k6 = cache.keyFor(2, 1);

      expect(k7, isNot(k6),
          reason: '烈火之剑与封印之剑的肖像 2 不能共用缓存槽');
    });

    test('同一 ROM 内不同用途 / 不同索引依旧互不冲突', () {
      final cache = PortraitImageCache.instance;
      cache.bindRom(_open(fe7jp).fingerprint);
      final keys = <int>{
        cache.keyFor(2, 1),
        cache.keyFor(2, 2),
        cache.keyFor(2, 3),
        cache.keyFor(3, 1),
        cache.keyFor(0, 1),
      };
      expect(keys.length, 5);
    });

    test('换 ROM 后旧 key 不再对应新 ROM 的图', () {
      final cache = PortraitImageCache.instance;
      cache.bindRom(_open(fe7jp).fingerprint);
      final before = cache.keyFor(2, 1);
      cache.bindRom(_open(fe6cn).fingerprint);
      expect(cache.keyFor(2, 1), isNot(before));
    });
  });
}
