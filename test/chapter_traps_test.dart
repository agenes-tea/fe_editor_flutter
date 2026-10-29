import 'dart:io';
import 'dart:typed_data';

import 'package:fe_editor/core/chapter_traps.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
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

void main() {
  group('章节陷阱（bmtrap.h TrapData）', () {
    test('FE8J：哥尔工蛋 59 个、弹弓 2 个、无陷阱章为空', () {
      final up = ChapterTraps(_open('1692 -'));
      expect(up.supported, isTrue);

      final eggs = up.traps(18);
      expect(eggs.length, 59);
      // 类型分布：哥尔工蛋 24 + 火地板 35（Boss 章混合陷阱）
      expect(eggs.where((t) => t.type == 12).length, 24);
      expect(eggs.where((t) => t.type == 4).length, 35);
      for (final t in eggs) {
        expect(t.x, inInclusiveRange(0, 32));
        expect(t.y, inInclusiveRange(0, 32));
      }
      final ball = up.traps(8);
      expect(ball.length, 2);
      expect(ball[0].label, '弹弓');
      expect(ball[0].x, 17);
      expect(ball[0].y, 8);
      expect(up.traps(1), isEmpty, reason: '无陷阱的章');
      // 困难追加槽
      expect(up.hardTraps(54).length, 20);
    });

    test('FE8U 改版（铠甲的呼唤）：同槽位数据仍可读', () {
      final up = ChapterTraps(_open('铠甲的呼唤'));
      expect(up.supported, isTrue);
      expect(up.traps(54).length, 41);
      expect(up.traps(54).first.type, 4, reason: '火地板');
      expect(up.traps(18), isEmpty);
    });

    test('FE7：记录结构未验证，不给标记但提示有数据', () {
      final up = ChapterTraps(_open('0979'));
      expect(up.supported, isFalse);
      expect(up.hasSlot, isTrue);
      expect(up.traps(0), isEmpty, reason: 'FE7 不解码记录');
      expect(up.chapterHasTraps(0), isTrue, reason: 'ch0 有 traps 指针');
      expect(up.chapterHasTraps(30), isTrue, reason: 'FE7 各章均有指针');
    });

    test('FE6 没有静态陷阱槽', () {
      final up = ChapterTraps(_open('0378'));
      expect(up.hasSlot, isFalse);
      expect(up.chapterHasTraps(0), isFalse);
      expect(up.traps(0), isEmpty);
    });

    test('类型名表（TRAP_* 枚举，bmtrick.h）', () {
      expect(ChapterTraps.typeName(1), '弹弓');
      expect(ChapterTraps.typeName(4), '火地板');
      expect(ChapterTraps.typeName(5), '毒气');
      expect(ChapterTraps.typeName(12), '哥尔工蛋');
      expect(ChapterTraps.typeName(99), '类型 99');
    });
  });
}
