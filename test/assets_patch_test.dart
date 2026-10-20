import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/patch_library.dart';

const rom7 =
    '/root/workspace/game-rom/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const rom6 =
    '/root/workspace/game-rom/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const assets = '/root/workspace/fe_editor/assets/patches';

void main() {
  test('收录的各版本补丁数量与实测一致', () async {
    // 用文件系统加载校验「打包进 assets 的内容」本身是否正确；
    // Flutter 单测环境不构建 AssetManifest，故不做 rootBundle 读取断言。
    final expected = {'FE6': 6, 'FE7J': 16, 'FE7U': 19, 'FE8J': 35, 'FE8U': 39};
    for (final e in expected.entries) {
      final lib = await PatchLibrary.load('$assets/${e.key}');
      expect(lib.patches.length, e.value, reason: '${e.key} 补丁数不符');
      expect(lib.unsupportedCount, 0, reason: '${e.key} 不应有无法解析的补丁');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('每个补丁都有数据块且名称唯一', () async {
    for (final v in ['FE6', 'FE7J', 'FE7U', 'FE8J', 'FE8U']) {
      final lib = await PatchLibrary.load('$assets/$v');
      final names = lib.patches.map((p) => p.name).toSet();
      expect(names.length, lib.patches.length, reason: '$v 补丁名重复');
      for (final p in lib.patches) {
        final blocks = await p.loadWrites();
        expect(blocks, isNotEmpty, reason: '$v/${p.name} 缺少数据文件');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('FE7J 全部补丁在真实 ROM 上可装可撤', () async {
    final data = await File(rom7).readAsBytes();
    final lib = await PatchLibrary.load('$assets/FE7J');
    final rom = data.sublist(0);
    var ok = 0;
    for (final p in lib.patches) {
      final snapshot = rom.sublist(0);
      final r = await applyPatch(p, rom);
      if (!r.ok) continue;
      ok++;
      expect(await isPatchInstalledAsync(p, rom), isTrue,
          reason: '${p.name} 安装后未检测到');
      undoPatch(r.undo, rom);
      expect(rom, equals(snapshot), reason: '${p.name} 撤销后不一致');
    }
    expect(ok, lib.patches.length);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('FE6 补丁应用到 FE6 ROM', () async {
    final data = await File(rom6).readAsBytes();
    expect(FeRom.detectTable(data)!.id, 'FE6');
    final lib = await PatchLibrary.load('$assets/FE6');
    final rom = data.sublist(0);
    var applied = 0;
    for (final p in lib.patches) {
      final r = await applyPatch(p, rom);
      if (r.ok) {
        applied++;
        expect(await isPatchInstalledAsync(p, rom), isTrue,
            reason: '${p.name} 检测失败');
      }
    }
    expect(applied, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
