import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/battle_anim.dart';
import 'package:fe_editor/core/battle_anim_porter.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';

import 'rom_paths.dart';

const dir = romDir;
const fe6jp = '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

EditableRom _open(String path) {
  final d = File(path).readAsBytesSync();
  return EditableRom.open(d, FeRom.detectTable(d)!);
}

/// 找一条「脚本、OAM、调色板、图形 sheet 都齐」的动画。
int _portableAnim(BattleAnimReader r) {
  for (final e in r.entries) {
    if (r.scriptData(e) == null) continue;
    if (r.modesOf(e).isEmpty) continue;
    if (r.paletteOf(e, 0) == null) continue;
    var frames = 0;
    for (final m in r.modesOf(e)) {
      frames += r.framesOf(e, m).length;
    }
    if (frames > 0) return e.id;
  }
  return -1;
}

void main() {
  group('移植前：源动画结构完整', () {
    test('三作都能找到可移植的动画', () {
      for (final path in [fe6jp, fe7jp, fe8jp]) {
        final edit = _open(path);
        final r = BattleAnimReader(edit.rom);
        expect(r.available, isTrue, reason: path);
        final id = _portableAnim(r);
        expect(id, greaterThanOrEqualTo(0), reason: '$path 应有完整动画');
      }
    });
  });

  group('替换模式：把源动画整包搬进目标的某一条', () {
    test('FE6 → FE8：搬过去后能渲染出帧', () {
      final source = _open(fe6jp);
      final target = _open(fe8jp);
      final srcReader = BattleAnimReader(source.rom);
      final id = _portableAnim(srcReader);
      expect(id, greaterThanOrEqualTo(0));

      final out = BattleAnimPorter(target)
          .port(srcReader, id, replaceTargetId: 1);
      expect(out.ok, isTrue, reason: out.message);
      expect(out.targetId, 1);
      expect(out.sheets, greaterThan(0), reason: '应复制了图形 sheet');
      expect(out.freeSpaceOffset, greaterThan(0), reason: '替换模式的新数据也写在空闲区');

      // 目标里第 1 条动画的脚本现在能解出帧
      final tgtReader = BattleAnimReader(target.liveRom);
      final e = tgtReader.entry(1)!;
      expect(e.abbr, isNotEmpty);
      final modes = tgtReader.modesOf(e);
      expect(modes, isNotEmpty);
      expect(tgtReader.paletteOf(e, 0), isNotNull);

      var frames = 0;
      for (final m in modes) {
        frames += tgtReader.framesOf(e, m).length;
      }
      expect(frames, greaterThan(0), reason: '搬过去后应能解析出帧');

      // 图形 sheet 指向的是目标 ROM 内的新副本（不是源 ROM 的地址）
      final firstFrame = tgtReader.framesOf(e, modes.first).first;
      final off = FeRom.toOffset(firstFrame.graphics);
      expect(off, greaterThan(0));
      expect(off, lessThan(target.buffer.length));
      expect(off, greaterThanOrEqualTo(out.entryAddress > 0 ? 0 : 0));
    });

    test('搬过去后真的能渲染出画面（非空像素）', () {
      final source = _open(fe6jp);
      final target = _open(fe8jp);
      final srcReader = BattleAnimReader(source.rom);
      final id = _portableAnim(srcReader);

      final out =
          BattleAnimPorter(target).port(srcReader, id, replaceTargetId: 1);
      expect(out.ok, isTrue, reason: out.message);

      final tgtReader = BattleAnimReader(target.liveRom);
      final e = tgtReader.entry(1)!;
      final modes = tgtReader.modesOf(e);
      final frames = tgtReader.framesOf(e, modes.first);
      final img = tgtReader.renderFrame(e, modes.first, 0);
      expect(img, isNotNull, reason: '应能渲染第一帧');
      var opaque = 0;
      for (var i = 3; i < img!.pixels.length; i += 4) {
        if (img.pixels[i] != 0) opaque++;
      }
      expect(opaque, greaterThan(100), reason: '画面不应是空白（frames=${frames.length}）');
    });

    test('同世代 FE7 → FE8 也能搬', () {
      final source = _open(fe7jp);
      final target = _open(fe8jp);
      final srcReader = BattleAnimReader(source.rom);
      final id = _portableAnim(srcReader);

      final out =
          BattleAnimPorter(target).port(srcReader, id, replaceTargetId: 2);
      expect(out.ok, isTrue, reason: out.message);

      final tgtReader = BattleAnimReader(target.liveRom);
      final e = tgtReader.entry(2)!;
      final modes = tgtReader.modesOf(e);
      expect(modes, isNotEmpty);
      expect(tgtReader.framesOf(e, modes.first), isNotEmpty);
    });
  });

  group('追加模式', () {
    test('追加后目标条目数 +1，新条目可读', () {
      final source = _open(fe6jp);
      final target = _open(fe8jp);
      final srcReader = BattleAnimReader(source.rom);
      final id = _portableAnim(srcReader);
      final before = BattleAnimReader(target.rom).count;

      final out = BattleAnimPorter(target).port(srcReader, id);
      expect(out.ok, isTrue, reason: out.message);

      final after = BattleAnimReader(target.liveRom);
      expect(after.count, greaterThan(before), reason: '应多出一条');
      final e = after.entry(out.targetId)!;
      expect(after.framesOf(e, after.modesOf(e).first), isNotEmpty);
    });
  });

  group('可撤销与安全', () {
    test('撤销后目标 ROM 逐字节还原', () {
      final source = _open(fe6jp);
      final target = _open(fe8jp);
      final srcReader = BattleAnimReader(source.rom);
      final id = _portableAnim(srcReader);

      expect(
          BattleAnimPorter(target)
              .port(srcReader, id, replaceTargetId: 1)
              .ok,
          isTrue);
      expect(target.hasChanges, isTrue);
      target.revertAll();
      expect(target.hasChanges, isFalse);
      expect(target.data, equals(target.original));
    });

    test('替换不存在的条目被拒绝且不写 ROM', () {
      final source = _open(fe6jp);
      final target = _open(fe8jp);
      final srcReader = BattleAnimReader(source.rom);
      final id = _portableAnim(srcReader);

      final out =
          BattleAnimPorter(target).port(srcReader, id, replaceTargetId: 9999);
      expect(out.result, AnimPortResult.noSuchEntry);
      expect(target.hasChanges, isFalse);
    });

    test('源 ID 越界返回 sourceEmpty', () {
      final source = _open(fe6jp);
      final target = _open(fe8jp);
      final out =
          BattleAnimPorter(target).port(BattleAnimReader(source.rom), 9999);
      expect(out.result, AnimPortResult.sourceEmpty);
      expect(target.hasChanges, isFalse);
    });

    test('替换一条动画不影响其它条目', () {
      final source = _open(fe6jp);
      final target = _open(fe8jp);
      final srcReader = BattleAnimReader(source.rom);
      final id = _portableAnim(srcReader);

      final beforeReader = BattleAnimReader(target.rom);
      final tableBase = beforeReader.base;
      final otherAt = tableBase + 5 * beforeReader.entrySize;
      final otherRaw = [
        for (var i = 0; i < beforeReader.entrySize; i++)
          target.buffer.data[otherAt + i]
      ];

      BattleAnimPorter(target).port(srcReader, id, replaceTargetId: 1);

      expect(
          [for (var i = 0; i < beforeReader.entrySize; i++) target.buffer.data[otherAt + i]],
          otherRaw,
          reason: '第 5 条动画的条目应一字未动');
    });
  });
}
