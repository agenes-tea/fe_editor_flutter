import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/rom_info.dart';
import 'package:fe_editor/core/rom_workspace.dart';

const dir = '/root/workspace/game-rom';
const fe6cn = '$dir/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

Uint8List _bytes(String p) => File(p).readAsBytesSync();

void main() {
  late RomWorkspace ws;

  setUp(() => ws = RomWorkspace());

  test('打开多个 ROM：全部保留，最后打开的是当前会话', () async {
    await ws.open(_bytes(fe7jp), 'fe7.gba');
    await ws.open(_bytes(fe6cn), 'fe6.gba');
    await ws.open(_bytes(fe8jp), 'fe8.gba');

    expect(ws.sessions.map((s) => s.versionId).toList(), ['FE7J', 'FE6', 'FE8J']);
    expect(ws.active!.versionId, 'FE8J');
  });

  test('切换会话不丢其它会话的数据与修改', () async {
    final s7 = (await ws.open(_bytes(fe7jp), 'fe7.gba'))!;
    final s8 = (await ws.open(_bytes(fe8jp), 'fe8.gba'))!;

    const level = EditField('等级', UnitOffsets.level, min: 1, max: 60);
    s7.rom.writeField(s7.rom.unitAddress(1), level, 20);
    expect(s7.rom.hasChanges, isTrue);

    ws.activate(s7);
    expect(ws.active!.id, s7.id);
    expect(s7.rom.hasChanges, isTrue, reason: '切走再切回，改动仍在');
    expect(s8.rom.hasChanges, isFalse);
  });

  test('重复打开同一份 ROM 只切换，不新增会话', () async {
    final a = (await ws.open(_bytes(fe7jp), 'a.gba'))!;
    await ws.open(_bytes(fe8jp), 'fe8.gba');
    final again = (await ws.open(_bytes(fe7jp), 'b.gba'))!;

    expect(ws.sessions.length, 2);
    expect(again.id, a.id);
    expect(ws.active!.id, a.id);
    expect(again.fileName, 'a.gba', reason: '保留首次打开时的文件名');
  });

  test('关闭当前会话后自动切到剩下的最后一个', () async {
    final s7 = (await ws.open(_bytes(fe7jp), 'fe7.gba'))!;
    final s8 = (await ws.open(_bytes(fe8jp), 'fe8.gba'))!;

    ws.close(s8);
    expect(ws.sessions.length, 1);
    expect(ws.active!.id, s7.id);

    ws.close(s7);
    expect(ws.isEmpty, isTrue);
    expect(ws.active, isNull);
  });

  test('关闭非当前会话不影响当前选择', () async {
    final s7 = (await ws.open(_bytes(fe7jp), 'fe7.gba'))!;
    final s8 = (await ws.open(_bytes(fe8jp), 'fe8.gba'))!;
    ws.close(s7);
    expect(ws.active!.id, s8.id);
  });

  test('无法识别的数据返回 null 且不改变已有会话', () async {
    final s7 = (await ws.open(_bytes(fe7jp), 'fe7.gba'))!;
    expect(await ws.open(Uint8List(512), 'junk.gba'), isNull);
    expect(ws.sessions.length, 1);
    expect(ws.active!.id, s7.id);
  });

  test('每次变更都通知监听者', () async {
    var calls = 0;
    ws.addListener(() => calls++);
    final s7 = (await ws.open(_bytes(fe7jp), 'fe7.gba'))!;
    final s8 = (await ws.open(_bytes(fe8jp), 'fe8.gba'))!;
    ws.activate(s7);
    ws.close(s8);
    ws.close(s7);
    expect(calls, 5);
  });
}
