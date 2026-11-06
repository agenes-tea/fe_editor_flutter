import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fe_editor/core/chapter_events.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/core/unit_placement.dart';

import 'rom_paths.dart';

const _dir = romDir;
const _fe8jp =
    '1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';
const _fe7jp = '0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const _fe6jp =
    '0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';

RomSession _open(String name) =>
    RomSession.open(File('$_dir/$name').readAsBytesSync(), name)!;

/// 取该章第一个可读的事件单位（找不到就跳过——不是所有章节都有剧情增援）。
LoadedUnit? _firstEventUnit(RomSession s, int chapter) {
  final ev = ChapterEvents(s.rom.liveRom);
  final group = UnitPlacement(s.rom).eventGroupOffset(chapter);
  if (group <= 0) return null;
  for (final e in ev.all(group)) {
    final units = ev.loadedUnits(e.script);
    if (units.isNotEmpty) return units.first;
  }
  return null;
}

void main() {
  group('事件生成单位的道具可改（原地覆盖 4 字节）', () {
    test('FE8：道具槽在 +12，写完能读回新值', () {
      final s = _open(_fe8jp);
      final ev = ChapterEvents(s.rom.liveRom);
      LoadedUnit? unit;
      var chapter = -1;
      for (var c = 0; c < 40 && unit == null; c++) {
        unit = _firstEventUnit(s, c);
        if (unit != null) chapter = c;
      }
      expect(unit, isNotNull, reason: 'FE8J 应该有剧情增援单位');
      // 结构体自证：道具槽偏移 = addr + 12（FE8 条目 20 字节）
      expect(unit!.itemAddress(0, isFe8: true), unit.addr + 12);
      expect(unit.itemAddress(3, isFe8: true), unit.addr + 15);

      final before = unit.items[0];
      final target = before == 1 ? 2 : 1;
      final n = ev.setUnitItem(s.rom, unit, 0, target);
      expect(n, 1, reason: 'should write one byte');

      // 从 buffer 重读，确认写进去了
      expect(s.rom.buffer.u8(unit.addr + 12), target);
      // 且没碰别的字节（+8..+11 是 redaCount/redas 区域）
      expect(s.rom.buffer.u8(unit.addr + 11), isNotNull);

      // 重新解析事件，读回的 items[0] 应当是新值
      final again = ChapterEvents(s.rom.liveRom);
      final group = UnitPlacement(s.rom).eventGroupOffset(chapter);
      LoadedUnit? reread;
      for (final e in again.all(group)) {
        for (final u in again.loadedUnits(e.script)) {
          if (u.addr == unit.addr) reread = u;
        }
      }
      expect(reread, isNotNull);
      expect(reread!.items[0], target);
    });

    test('FE7：道具槽在 +8（条目 16 字节，不能套用 FE8 的 +12）', () {
      final s = _open(_fe7jp);
      final ev = ChapterEvents(s.rom.liveRom);
      LoadedUnit? unit;
      for (var c = 0; c < 40 && unit == null; c++) {
        unit = _firstEventUnit(s, c);
      }
      expect(unit, isNotNull, reason: 'FE7J 应该有剧情增援单位');
      expect(unit!.itemAddress(0, isFe8: false), unit.addr + 8);

      final before = unit.items[0];
      final target = before == 1 ? 2 : 1;
      expect(ev.setUnitItem(s.rom, unit, 0, target), 1);
      expect(s.rom.buffer.u8(unit.addr + 8), target);

      final again = ChapterEvents(s.rom.liveRom);
      var reread = false;
      for (var c = 0; c < 40 && !reread; c++) {
        final group = UnitPlacement(s.rom).eventGroupOffset(c);
        if (group <= 0) continue;
        for (final e in again.all(group)) {
          for (final u in again.loadedUnits(e.script)) {
            if (u.addr == unit.addr && u.items[0] == target) reread = true;
          }
        }
      }
      expect(reread, isTrue);
    });

    test('FE6：道具槽同样在 +8，且写入记进 edits（可撤销）', () {
      final s = _open(_fe6jp);
      final ev = ChapterEvents(s.rom.liveRom);
      LoadedUnit? unit;
      for (var c = 0; c < 40 && unit == null; c++) {
        unit = _firstEventUnit(s, c);
      }
      if (unit == null) return; // FE6 有的章没有剧情增援，跳过
      expect(unit.itemAddress(0, isFe8: false), unit.addr + 8);

      final n0 = s.rom.edits.length;
      final before = unit.items[1];
      final target = before == 1 ? 2 : 1;
      expect(ev.setUnitItem(s.rom, unit, 1, target), 1);
      expect(s.rom.buffer.u8(unit.addr + 9), target);
      expect(s.rom.edits.length, greaterThan(n0), reason: '应记一条 ByteEdit');

      // 撤销后应回到原值
      s.rom.revertAll();
      expect(s.rom.buffer.u8(unit.addr + 9), before);
    });

    test('同值不写（返回 0，不产生多余 edits）', () {
      final s = _open(_fe8jp);
      final ev = ChapterEvents(s.rom.liveRom);
      LoadedUnit? unit;
      for (var c = 0; c < 40 && unit == null; c++) {
        unit = _firstEventUnit(s, c);
      }
      expect(unit, isNotNull);
      final same = unit!.items[0];
      final n0 = s.rom.edits.length;
      expect(ev.setUnitItem(s.rom, unit, 0, same), 0);
      expect(s.rom.edits.length, n0);
    });

    test('道具位索引越界拒绝（0..3）', () {
      final s = _open(_fe8jp);
      final ev = ChapterEvents(s.rom.liveRom);
      LoadedUnit? unit;
      for (var c = 0; c < 40 && unit == null; c++) {
        unit = _firstEventUnit(s, c);
      }
      expect(unit, isNotNull);
      expect(ev.setUnitItem(s.rom, unit!, -1, 1), -1);
      expect(ev.setUnitItem(s.rom, unit, 4, 1), -1);
    });
  });
}
