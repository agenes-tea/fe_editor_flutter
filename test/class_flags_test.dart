import 'dart:io';
import 'dart:typed_data';

import 'package:fe_editor/core/class_flags.dart';
import 'package:fe_editor/core/cheat_presets.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/rom_info.dart';
import 'package:flutter_test/flutter_test.dart';

Directory get _romDir => Directory('${Platform.environment['HOME']}/workspace/game-rom');

File _romByKeyword(String keyword) {
  for (final f in _romDir.listSync()) {
    if (f is File && f.path.contains(keyword)) return f;
  }
  throw StateError('找不到文件名包含 $keyword 的 ROM');
}

EditableRom _open(String keyword) {
  final data = Uint8List.fromList(_romByKeyword(keyword).readAsBytesSync());
  return EditableRom.open(data, FeRom.detectTable(data)!);
}

int attrs(EditableRom edit, int classIndex) =>
    edit.buffer.u32(edit.classAddress(classIndex) + ClassOffsets.attributes);

void main() {
  group('职业 CA_* 特性位', () {
    test('位含义与真实 ROM 一致（反编译 CA_* 逐位核对）', () {
      final e8 = _open('1692 -');
      // FE8J 72/73 = 天马骑士/天马领主
      expect(attrs(e8, 72) & (1 << 12), isNot(0), reason: 'CA_PEGASUS');
      expect(attrs(e8, 73) & (1 << 8), isNot(0), reason: '上级 CA_PROMOTED');
      expect(attrs(e8, 73) & (1 << 12), isNot(0), reason: 'CA_PEGASUS');
      // 未上位职业不带 CA_PROMOTED
      expect(attrs(e8, 5) & (1 << 8), 0);

      final e7 = _open('0979');
      // FE7J 50/51 = 飞马骑士/飞马领主（attrs 0x1003/0x1103）
      expect(attrs(e7, 50) & (1 << 12), isNot(0), reason: 'CA_PEGASUS');
      expect(attrs(e7, 51) & (1 << 8), isNot(0), reason: 'CA_PROMOTED');
    });

    test('writeFlagBit 只动一位，其余位原样，且可撤销', () {
      final edit = _open('1692 -');
      final addr = edit.classAddress(5) + ClassOffsets.attributes;
      expect(attrs(edit, 5), 0x00000403, reason: 'MOUNTED|CANTO|MOUNTEDAID');
      expect(edit.writeFlagBit(addr, 8, true), isTrue);
      expect(attrs(edit, 5), 0x00000503, reason: '只加了 CA_PROMOTED');
      edit.revertAll();
      expect(attrs(edit, 5), 0x00000403);
      expect(edit.hasChanges, isFalse);
    });

    test('FE6 条目 72 字节：CA_* 开关不开放（+40 是熟练度区）', () {
      final edit = _open('0378');
      expect(ClassFlags.supported(edit.rom.table.classDataSize), isFalse);
      // 对照：FE7/FE8 条目 84 字节，开放
      expect(ClassFlags.supported(_open('0979').rom.table.classDataSize), isTrue);
    });
  });

  group('职业类修改器预设', () {
    test('职业能力上限 50（HP 60）：全表生效且可撤销', () {
      for (final keyword in ['0979', '1692 -']) {
        final edit = _open(keyword);
        final rom = edit.rom;
        final caps = cheatPresets.firstWhere((p) => p.id == 'class_caps_50');

        final r = applyCheat(edit, caps);
        expect(r.skipped, isEmpty, reason: '7 项上限字段必须匹配');
        for (var i = 1; i < rom.classCount; i++) {
          final base = edit.classAddress(i);
          expect(edit.buffer.u8(base + ClassOffsets.maxHp), 60,
              reason: 'FE7/8 ch$i HP 上限');
          expect(edit.buffer.u8(base + ClassOffsets.maxStr), 50,
              reason: 'FE7/8 ch$i 力量上限');
          expect(edit.buffer.u8(base + ClassOffsets.maxCon), 50,
              reason: 'FE7/8 ch$i 体格上限');
        }
        edit.revertAll();
        expect(edit.hasChanges, isFalse, reason: '$keyword 撤销');
      }
    });

    test('新预设可重复应用（幂等）', () {
      final edit = _open('0979');
      final caps = cheatPresets.firstWhere((p) => p.id == 'class_caps_50');
      applyCheat(edit, caps);
      final again = applyCheat(edit, caps);
      expect(again.changedBytes, 0, reason: '第二次应用不写新字节');
    });
  });
}
