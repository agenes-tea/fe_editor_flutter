import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/rom_session.dart';

import 'rom_paths.dart';

const dir = romDir;
const fe6cn = '$dir/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';
const fe7us = '$dir/1235 - 火炎之纹章-烈火之剑 Fire Emblem(US)(Nintendo)(128Mb).gba';

RomSession _session(String path, String name) {
  final data = File(path).readAsBytesSync();
  final s = RomSession.open(data, name);
  expect(s, isNotNull, reason: '真实 ROM 必须能被识别: $path');
  return s!;
}

void main() {
  group('多 ROM 同时打开', () {
    test('三作可以同时驻留内存，各自识别出自己的版本', () {
      final s6 = _session(fe6cn, 'fe6.gba');
      final s7 = _session(fe7jp, 'fe7.gba');
      final s8 = _session(fe8jp, 'fe8.gba');

      expect([s6.versionId, s7.versionId, s8.versionId],
          ['FE6', 'FE7J', 'FE8J']);
      expect([s6.generation, s7.generation, s8.generation], [6, 7, 8]);
      // 会话 id 唯一，界面据此区分
      expect({s6.id, s7.id, s8.id}.length, 3);
    });

    test('各会话的地址表不同（三作表基址互不相同）', () {
      final s6 = _session(fe6cn, 'fe6.gba');
      final s7 = _session(fe7jp, 'fe7.gba');
      final s8 = _session(fe8jp, 'fe8.gba');

      final slots = {
        s6.table.unitPointerSlot,
        s7.table.unitPointerSlot,
        s8.table.unitPointerSlot,
      };
      expect(slots.length, 3, reason: '单位表指针槽三作各不同');
      expect([s6.table.unitDataSize, s7.table.unitDataSize, s8.table.unitDataSize],
          [48, 52, 52]);
    });

    test('编辑其中一个不影响另一个（字节数组与编辑记录互相独立）', () {
      final s6 = _session(fe6cn, 'fe6.gba');
      final s8 = _session(fe8jp, 'fe8.gba');
      final e6 = s6.rom;
      final e8 = s8.rom;

      final before8 = Uint8List.fromList(e8.data);
      final addr6 = e6.unitAddress(1);
      expect(e6.writeField(addr6, unitEditableFieldsFor(fe6: true).first, 15),
          isTrue);

      expect(e6.hasChanges, isTrue);
      expect(e8.hasChanges, isFalse, reason: '写 FE6 不该动到 FE8 的编辑记录');
      expect(e8.data, before8, reason: 'FE8 的字节数组必须完全不变');
    });

    test('FE8 系判定与同位不同区判定', () {
      final s8 = _session(fe8jp, 'fe8j.gba');
      final s7 = _session(fe7jp, 'fe7j.gba');
      final s7u = _session(fe7us, 'fe7u.gba');

      expect(s8.isFe8, isTrue);
      expect(s7.isFe8, isFalse);
      expect(s7.sameGenerationAs(s7u), isTrue);
      expect(s7.sameGenerationAs(s8), isFalse);
    });

    test('同一份 ROM 打开两次能识别出是同一份（用于避免重复占用内存）', () {
      final a = _session(fe7jp, 'a.gba');
      final b = _session(fe7jp, 'b.gba');
      expect(a.sameRomAs(b), isTrue);
      expect(a.id, isNot(b.id));
    });

    test('无法识别的数据返回 null 而不是抛异常', () {
      final junk = Uint8List(0x200);
      expect(RomSession.open(junk, 'junk.gba'), isNull);
    });
  });

  group('汉化版码表挂载', () {
    test('狼组封印默认未识别引擎，挂码表后可读中文名', () async {
      final s = _session(fe6cn, 'fe6cn.gba');
      expect(s.needsZhTable, isTrue);
      await s.attachZhTableIfNeeded();
      expect(s.liveRom.zhTable, isNotNull);
      expect(s.liveRom.zhTableMatchRatio(), greaterThanOrEqualTo(0.5));
      expect(s.liveRom.unitDisplayName(1), isNotEmpty);
    });

    test('挂上码表后 liveRom 也要能拿到（否则文本写入失效）', () async {
      final s = _session(fe6cn, 'fe6cn.gba');
      await s.attachZhTableIfNeeded();
      expect(s.hasZhTable, isTrue);
      // liveRom 必须继承码表：名字显示与文本写入都靠它
      expect(s.liveRom.zhTable, isNotNull,
          reason: 'liveRom 不继承 zhTable 会导致汉化版读不出中文、写入被判不支持');
      expect(s.rom.rom.zhTable, isNotNull);
      // 汉化版应该被判定为可写文本
      expect(s.textWritable, isTrue, reason: '狼组封印挂上码表后是可写的');
    });

    test('日版不需要挂码表', () async {
      final s = _session(fe8jp, 'fe8.gba');
      expect(s.needsZhTable, isFalse);
      await s.attachZhTableIfNeeded();
      expect(s.liveRom.zhTable, isNull);
    });
  });
}
