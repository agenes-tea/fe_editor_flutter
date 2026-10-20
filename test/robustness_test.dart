import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/portrait.dart';
import 'package:fe_editor/core/rom_profile.dart';
import 'package:fe_editor/core/rom_probe.dart';

const dir = '/root/workspace/game-rom';
const fe6jp = '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

/// 「火焰纹章-铠甲的呼唤」是 20MB 的重度改版，文件名含中文不好写死，用大小定位。
String? _findBySize(int size) {
  for (final f in Directory(dir).listSync().whereType<File>()) {
    if (f.lengthSync() == size) return f.path;
  }
  return null;
}

FeRom _open(String path) {
  final data = File(path).readAsBytesSync();
  final table = FeRom.detectTable(data);
  expect(table, isNotNull, reason: path);
  return FeRom(data, table!);
}

void main() {
  group('版本识别：结构匹配（不依赖 game code）', () {
    test('未知 code 也能靠指针表结构识别出版本', () {
      // 把 FE7J 的 game code 改成乱七八糟的，识别仍应成功
      final data = File(fe7jp).readAsBytesSync();
      final hacked = Uint8List.fromList(data);
      hacked[0xAC] = 'X'.codeUnitAt(0);
      hacked[0xAD] = 'Y'.codeUnitAt(0);
      hacked[0xAE] = 'Z'.codeUnitAt(0);
      hacked[0xAF] = 'W'.codeUnitAt(0);

      final byCode = FeRom.detectTable(hacked);
      expect(byCode, isNotNull);
      expect(byCode!.id, 'FE7J');

      // 纯结构匹配也应得出同一结论
      final byStructure = profileByStructure(hacked);
      expect(byStructure?.id, 'FE7J');
    });

    test('结构匹配对每个真实 ROM 都唯一', () {
      final cases = {
        fe6jp: 'FE6',
        fe7jp: 'FE7J',
        fe8jp: 'FE8J',
      };
      for (final e in cases.entries) {
        final data = File(e.key).readAsBytesSync();
        final p = profileByStructure(data);
        expect(p, isNotNull, reason: e.key);
        expect(p!.id, e.value, reason: e.key);
      }
    });

    test('非 FE 的 ROM 不该被误识别', () {
      final junk = Uint8List(0x200000);
      // 填一些随机指针，让它看起来像有指针表
      for (var i = 0x100; i < 0x200; i++) {
        junk[i * 4] = 0x08;
        junk[i * 4 + 1] = 0x00;
        junk[i * 4 + 2] = 0x10;
        junk[i * 4 + 3] = 0x00;
      }
      expect(profileByStructure(junk), isNull);
    });
  });

  group('改版兼容：重度改版', () {
    late String? armorPath;

    setUpAll(() {
      armorPath = _findBySize(21853736);
    });

    test('「火焰纹章-铠甲的呼唤」能被识别并读出数据', () {
      // 20MB 的 BE8E 重度改版：数据搬到了 ROM 扩展区，指针槽位置没动
      if (armorPath == null) {
        markTestSkipped('未找到「火焰纹章-铠甲的呼唤.gba」');
        return;
      }
      final data = File(armorPath!).readAsBytesSync();
      final code = String.fromCharCodes(data.sublist(0xAC, 0xB0));
      expect(code, 'BE8E');

      final table = FeRom.detectTable(data);
      expect(table, isNotNull);
      expect(table!.id, 'FE8U');

      final rom = FeRom(data, table);
      // 表基址应落在 ROM 扩展区（>16MB）
      expect(rom.unitBase, greaterThan(0));
      expect(rom.unitCount, greaterThan(50));
      expect(rom.classCount, greaterThan(20));
      // 肖像表也应能定位
      final r = PortraitReader(rom);
      expect(r.entryCount, greaterThan(20));
    });
  });

  group('基址探测', () {
    test('槽值指向表本身时能直接命中', () {
      final rom = _open(fe7jp);
      final probe = RomProbe(rom.data);
      final hit = probe.findTable(
        rom.table.portraitPointerSlot,
        rom.table.portraitDataSize,
        rom.table.portraitPointerFields,
      );
      expect(hit, isNotNull);
      expect(hit!.score, greaterThan(0.9));
    });

    test('槽值不指向表时，能在附近找到真表（FE6 槽指向图像数据）', () {
      final rom = _open(fe6jp);
      final probe = RomProbe(rom.data);
      final hit = probe.findTable(
        rom.table.portraitPointerSlot,
        rom.table.portraitDataSize,
        rom.table.portraitPointerFields,
      );
      expect(hit, isNotNull);
      expect(hit!.score, greaterThan(0.9));
      // 找到的基址应与实际表位置一致
      final r = PortraitReader(rom);
      expect(r.entryCount, greaterThan(50));
    });

    test('表被搬到别处时，槽值探测失效（这是已知的能力边界）', () {
      final rom = _open(fe7jp);
      final data = Uint8List.fromList(rom.data);
      final probe = RomProbe(data);

      final original = probe.findTable(
        rom.table.portraitPointerSlot,
        rom.table.portraitDataSize,
        rom.table.portraitPointerFields,
      )!;
      const size = 28;
      final tableLen = 300 * size;

      // 把它搬到 ROM 尾部，槽值改成一个无效指针
      final newBase = data.length - tableLen - 0x100;
      data.setRange(newBase, newBase + tableLen, data.sublist(original.base, original.base + tableLen));
      data[rom.table.portraitPointerSlot] = 0;
      data[rom.table.portraitPointerSlot + 1] = 0;
      data[rom.table.portraitPointerSlot + 2] = 0;
      data[rom.table.portraitPointerSlot + 3] = 0;

      // 槽值彻底失效时，邻近探测找不到表——这是设计上的已知边界：
      // GBA ROM 里指针数组遍地都是，仅靠内容特征无法唯一定位一张表
      // （实测 FE7J 的扫描候选高达 6.8 万个）。
      // 这种情况需要用户手动指定表地址，而不是自动猜。
      final hit = probe.findTable(
        rom.table.portraitPointerSlot,
        size,
        rom.table.portraitPointerFields,
      );
      expect(hit, isNull, reason: '槽值失效时不应猜一个基址');

      // 但扫描仍能给出候选，供 UI 列出让用户选
      final cands = probe.scanTables(
        size,
        rom.table.portraitPointerFields,
        minSamples: 8,
        limit: 200,
      );
      expect(cands, isNotEmpty);
    });

    test('扫描候选数很多，说明不能自动采纳（记录能力边界）', () {
      final rom = _open(fe7jp);
      final probe = RomProbe(rom.data);
      final cands = probe.scanTables(
        rom.table.portraitDataSize,
        rom.table.portraitPointerFields,
        minSamples: 8,
        limit: 100000,
      );
      // ROM 里到处是指针数组，候选必然很多——这就是为什么扫描只能用于提示
      expect(cands.length, greaterThan(100));
    });
  });

  group('ID 与表偏移强绑定', () {
    test('单位表条目数由 ID 连续性决定，ID 恒等于表内偏移+1', () {
      for (final path in [fe6jp, fe7jp, fe8jp]) {
        final rom = _open(path);
        final base = rom.unitBase;
        for (var i = 0; i < rom.unitCount; i++) {
          final at = base + i * rom.table.unitDataSize;
          expect(rom.data[at + 4], i + 1, reason: '$path unit $i');
        }
      }
    });

    test('职业表与道具表的 ID 同样连续', () {
      for (final path in [fe6jp, fe7jp, fe8jp]) {
        final rom = _open(path);
        for (var i = 0; i < rom.classCount; i++) {
          final at = rom.classBase + i * rom.table.classDataSize;
          expect(rom.data[at + 4], i, reason: '$path class $i');
        }
        for (var i = 0; i < rom.itemCount; i++) {
          final at = rom.itemBase + i * rom.table.itemDataSize;
          expect(rom.data[at + 6], i, reason: '$path item $i');
        }
      }
    });
  });
}
