import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/patch_apply.dart';
import 'package:fe_editor/core/patch_format.dart';

const dir = '/root/workspace/game-rom';
const fe8jp =
    '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';
const fe6jp =
    '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';

Uint8List _open(String path) => File(path).readAsBytesSync();

void main() {
  test('IPS 往返：改几个字节生成补丁，applyPatch 还原出目标', () {
    final orig = _open(fe8jp);
    final target = Uint8List.fromList(orig);
    target[0x1000] = 0xAA;
    target[0x50000] = 0xBB;
    target[0x50001] = 0xCC;

    final patch = IpsPatch.create(orig, target)!;
    final r = applyPatch(patch, orig);
    expect(r.kind, 'IPS');
    expect(r.ok, isTrue, reason: r.message);
    expect(r.changedBytes, 3);
    expect(r.newRom, equals(target));
  });

  test('UPS 往返：applyPatch 结果与目标逐字节一致', () {
    final orig = _open(fe8jp);
    final target = Uint8List.fromList(orig);
    target[0x200000] = 0x5A;
    target[0x012345] = 0x77;

    final patch = UpsPatch.create(orig, target);
    final r = applyPatch(patch, orig);
    expect(r.kind, 'UPS');
    expect(r.ok, isTrue, reason: r.message);
    expect(r.newRom, equals(target));
  });

  test('UPS 反向应用不支持：拿目标 ROM 打补丁会被拒（不静默反打）', () {
    final orig = _open(fe8jp);
    final target = Uint8List.fromList(orig);
    target[0x90000] = 0x11;

    final patch = UpsPatch.create(orig, target);
    // 补丁是为 orig→target 生成的；拿 target 去套，方向不对。
    // 实现上不静默反向应用（结果无法自证正确），直接拒绝。
    final r = applyPatch(patch, target);
    expect(r.ok, isFalse);
  });

  test('改 ROM 大小的补丁被拒绝（FE6 8MB → 16MB）', () {
    final orig = _open(fe6jp);
    expect(orig.length, 0x800000);
    // 造一个「16MB 目标」的 UPS：目标比源长
    final grown = Uint8List(orig.length + 0x800000);
    grown.setRange(0, orig.length, orig);
    final patch = UpsPatch.create(orig, grown);
    final r = applyPatch(patch, orig);
    expect(r.ok, isFalse);
    expect(r.message, contains('改 ROM 大小'));
  });

  test('垃圾文件与损坏补丁被识别', () {
    final orig = _open(fe8jp);
    final garbage = applyPatch(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9]), orig);
    expect(garbage.kind, 'unknown');
    expect(garbage.ok, isFalse);

    final patch = IpsPatch.create(orig, orig)!;
    // 把中间截掉一段 → 记录越界
    final broken = Uint8List.fromList(patch.sublist(0, 3 + patch.length ~/ 2));
    expect(applyPatch(broken, orig).ok, isFalse);
  });

  test('补丁与 ROM 不匹配（UPS CRC 对不上）被拒绝', () {
    final a = _open(fe8jp);
    final b = _open('$dir/1692X 火焰之纹章-圣邪的意志.gba');
    final target = Uint8List.fromList(a)..[0x100] = 0xFF;
    final patch = UpsPatch.create(a, target);
    final r = applyPatch(patch, b);
    expect(r.ok, isFalse, reason: '不同 ROM 之间 CRC 不应匹配');
    expect(r.message, contains('CRC'));
  });
}
