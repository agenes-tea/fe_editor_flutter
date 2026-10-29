import 'dart:io';

import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/text_codec.dart';
import 'package:flutter_test/flutter_test.dart';

const dir = '/root/workspace/game-rom';

/// 用户提供的「已装好调试器」圣魔之光石成品（18768416 B，FE8 美版底 + 汉化）。
///
/// 它是排查「我方能装、对方能跑」差异的金标准（见 AGENTS.md 第 20b 节）：
/// 调试器代码在 0xB80000 起 ~17KB，中文菜单是**明文 UTF-8 追加**在 0x11E5B15。
/// 这里锁住「工具能正确识别并解码它」这条基线——若以后改动让识别退化，这里先红。
File? _gold() {
  for (final f in Directory(dir).listSync().whereType<File>()) {
    if (f.lengthSync() == 18768416) return f;
  }
  return null;
}

void main() {
  test('金标准自调试 ROM：识别为 FE8U 且文本为明文 UTF-8', () {
    final f = _gold();
    expect(f, isNotNull, reason: '缺少 18768416 字节的自调试版 ROM');
    final data = f!.readAsBytesSync();
    expect(String.fromCharCodes(data.sublist(0xAC, 0xB0)), 'BE8E',
        reason: '这是 FE8 美版底（BE8E），不是 BE8J');

    final table = FeRom.detectTable(data);
    expect(table, isNotNull);
    expect(table!.id, 'FE8U');

    final rom = FeRom(data, table);
    expect(rom.textEncoding, FeTextEncoding.plainUtf8);
    expect(rom.unitCount, 255);
    expect(rom.classCount, 128);
    expect(rom.itemCount, 206);
  });

  test('金标准自调试 ROM：前几个单位是正式译名，且不抛异常', () {
    final data = _gold()!.readAsBytesSync();
    final rom = FeRom(data, FeRom.detectTable(data)!);
    final names = [for (var i = 1; i <= 4; i++) rom.unitDisplayName(i)];
    expect(names, ['塞思', '吉利安姆', '弗朗茨', '摩达']);

    // 全表解码不得抛异常（改版文本混有非 UTF-8 残骸的容错保障）
    for (var i = 0; i < rom.unitCount; i++) {
      rom.unitName(i);
    }
    for (var i = 0; i < rom.classCount; i++) {
      rom.className(i);
    }
    for (var i = 0; i < rom.itemCount; i++) {
      rom.itemName(i);
    }
  });
}
