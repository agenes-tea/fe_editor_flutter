import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/patch_library.dart';

const libDir = '/root/workspace/fe_editor/assets/patches/FE7J';
const romPath =
    '/root/workspace/game-rom/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';

void main() {
  test('扫描 FE7J 补丁库', () async {
    final lib = await PatchLibrary.load(libDir);
    print('可安装: ${lib.patches.length}  不支持: ${lib.unsupportedCount}');
    expect(lib.patches, isNotEmpty);
    // 抽查一个已知简单补丁
    final anti = lib.patches.where((p) => p.name == 'Anti-Huffman');
    expect(anti, isNotEmpty, reason: '应能解析 Anti-Huffman');
    final p = anti.first;
    print('Anti-Huffman: writes=${p.writes.length} checks=${p.checks.length}');
    print('  info: ${p.info.split('\n').first}');
    expect(p.writes, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('在真实 ROM 上安装并还原补丁', () async {
    final data = await File(romPath).readAsBytes();
    final table = FeRom.detectTable(data)!;
    expect(table.id, 'FE7J');

    final lib = await PatchLibrary.load(libDir);
    final patch = lib.patches.firstWhere((p) => p.name == 'Anti-Huffman');

    final rom = data.sublist(0);
    expect(isPatchInstalled(patch, rom), isFalse);

    final result = await applyPatch(patch, rom);
    print('安装结果: ${result.ok} / ${result.message}');
    expect(result.ok, isTrue);

    // 装完后检测应识别为已安装
    expect(isPatchInstalled(patch, rom), isTrue);

    // 再次安装应被拒绝
    final again = await applyPatch(patch, rom);
    expect(again.ok, isFalse);
    expect(again.message, contains('已经安装'));

    // 撤销后回到原样
    undoPatch(result.undo, rom);
    expect(rom, equals(data));
    expect(isPatchInstalled(patch, rom), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('批量安装所有可安装补丁，逐个校验可逆', () async {
    final data = await File(romPath).readAsBytes();
    final lib = await PatchLibrary.load(libDir);

    var installed = 0;
    var failed = 0;
    final failures = <String>[];

    for (final p in lib.patches.take(60)) {
      final rom = data.sublist(0);
      final r = await applyPatch(p, rom);
      if (!r.ok) {
        failed++;
        failures.add('${p.name}: ${r.message}');
        continue;
      }
      installed++;
      // 校验：装完必须判定为已安装
      if (!isPatchInstalled(p, rom)) {
        failures.add('${p.name}: 装完检测未通过');
      }
      // 校验：撤销必须完全复原
      undoPatch(r.undo, rom);
      if (!_same(rom, data)) {
        failures.add('${p.name}: 撤销后与原 ROM 不一致');
      }
    }
    print('批量测试: 成功 $installed, 失败 $failed');
    for (final f in failures.take(10)) {
      print('  $f');
    }
    expect(installed, greaterThanOrEqualTo(15));
  }, timeout: const Timeout(Duration(minutes: 5)));
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
