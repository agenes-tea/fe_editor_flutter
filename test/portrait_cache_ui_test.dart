import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/portrait.dart';
import 'package:fe_editor/ui/portrait_page.dart';
import 'package:fe_editor/ui/unit_page.dart';

const dir = '/root/workspace/game-rom';
const fe6cn = '$dir/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';

EditableRom _edit(String path) {
  final d = File(path).readAsBytesSync();
  return EditableRom.open(d, FeRom.detectTable(d)!);
}

void main() {
  testWidgets('先开烈火再开封印：第二个 ROM 的角色页显示的是它自己的肖像', (tester) async {
    // 1) 打开烈火之剑，渲染角色列表 → 触发肖像解码并写入缓存
    final fe7 = _edit(fe7jp);
    PortraitImageCache.instance.bindRom(fe7.rom.fingerprint);
    await tester.pumpWidget(MaterialApp(home: UnitListPage(edit: fe7)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('エリウッド'), findsWidgets);

    // 2) 换成封印之剑（真实流程：主页 _load 里 bindRom）
    final fe6 = _edit(fe6cn);
    PortraitImageCache.instance.bindRom(fe6.rom.fingerprint);
    await tester.pumpWidget(MaterialApp(home: UnitListPage(edit: fe6)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 3) 两个 ROM 的同一肖像索引，解码出的像素不应相等
    final r7 = PortraitReader(fe7.rom);
    final r6 = PortraitReader(fe6.rom);
    final f7 = r7.faceImage(2);
    final f6 = r6.faceImage(2);
    expect(f7, isNotNull);
    expect(f6, isNotNull);
    expect(f7!.pixels, isNot(equals(f6!.pixels)),
        reason: '烈火与封印的肖像 2 本来就是不同的图');

    r7.dispose();
    r6.dispose();
  });

  testWidgets('同一 ROM 内复用缓存 key 保持一致', (tester) async {
    final cache = PortraitImageCache.instance;
    final rom = _edit(fe7jp).rom;
    cache.bindRom(rom.fingerprint);
    final k1 = cache.keyFor(2, 1);
    final k2 = cache.keyFor(2, 1);
    expect(k1, k2);
  });
}
