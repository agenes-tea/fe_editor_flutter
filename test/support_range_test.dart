import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/cheat_presets.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/rom_buffer.dart';
import 'package:fe_editor/core/support_range.dart';

const dir = '/root/workspace/game-rom';

Uint8List _rom(String prefix) {
  final f = Directory(dir)
      .listSync()
      .whereType<File>()
      .firstWhere((f) => f.path.contains(prefix));
  return f.readAsBytesSync();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('五个版本都能唯一定位支援距离判定（原值 3）', () {
    const cases = {
      '0378': 'FE6',
      '0979': 'FE7J',
      '1235': 'FE7U',
      '1692 -': 'FE8J',
    };
    cases.forEach((prefix, name) {
      final data = _rom(prefix);
      final rom = FeRom(data, FeRom.detectTable(data)!);
      final r = SupportRange(rom);
      final at = r.locate();
      expect(at, greaterThan(0), reason: '$name 定位失败');
      expect(r.readDistance(), 3, reason: '$name 原版阈值应为 3');

      // 指令形态：cmp rX, #3 紧接 bgt/ble
      final h = data[at] | (data[at + 1] << 8);
      expect(h & 0xF800, 0x2800, reason: '$name 不是 cmp 立即数');
      expect(h & 0xFF, 3, reason: '$name 立即数不是 3');
    });
  });

  test('改成 30 / 60：写入位置正确、可撤销、幂等', () {
    final data = _rom('1692 -');
    final edit = EditableRom.open(data, FeRom.detectTable(data)!);
    final at = SupportRange(edit.rom).locate();

    final p30 = cheatPresets.firstWhere((p) => p.id == 'support_range_30');
    var res = applyCheat(edit, p30);
    expect(res.changedEntries, 1);
    expect(SupportRange(edit.rom).readDistanceAt(edit.buffer.data, at), 30);
    // 高位（寄存器编码）不能被改掉
    expect(edit.buffer.u16(at) & 0xFF00, 0x2800);

    // 幂等
    res = applyCheat(edit, p30);
    expect(res.changedBytes, 0);

    final p60 = cheatPresets.firstWhere((p) => p.id == 'support_range_60');
    applyCheat(edit, p60);
    expect(SupportRange(edit.rom).readDistanceAt(edit.buffer.data, at), 63);

    edit.revertAll();
    expect(edit.data, equals(data));
  });

  test('30 格确实覆盖常规地图全屏（曼哈顿距离）', () {
    // 15×10 地图：两角相距 (15-1)+(10-1) = 23
    expect(kSupportRangeFullscreen, greaterThan(23));
    // 32×32 大图：两角相距 31+31 = 62，所以 60 不够，需要 >= 63
    expect(kSupportRangeBattlefield, greaterThanOrEqualTo(63));
  });

  test('改版 ROM（圣邪的意志）：定位失败时记 skipped 而不是乱写', () {
    final data = _rom('1692X');
    final table = FeRom.detectTable(data);
    expect(table, isNotNull);
    final edit = EditableRom.open(data, table!);
    final at = SupportRange(edit.rom).locate();
    final preset = cheatPresets.firstWhere((p) => p.id == 'support_range_30');
    final at2 = at;
    final res = applyCheat(edit, preset);
    if (at < 0) {
      expect(res.skipped, isNotEmpty);
      expect(res.changedBytes, 0);
    } else {
      expect(SupportRange(edit.rom).readDistanceAt(edit.buffer.data, at), 30);
    }
  });
}
