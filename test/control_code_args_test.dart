import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fe_editor/core/gbk_table.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/core/text_browser.dart';
import 'package:fe_editor/core/text_control.dart';
import 'package:fe_editor/core/text_writer.dart';

import 'rom_paths.dart';

const _dir = romDir;
const _gbk = '火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba';

RomSession _open(String name) =>
    RomSession.open(File('$_dir/$name').readAsBytesSync(), name)!;

void main() {
  group('控制码参数长度（按字节，不是 u16）', () {
    test('argsOf 返回字节数', () {
      expect(TextControlCodec.argsOf(0x05), 1, reason: '按键');
      expect(TextControlCodec.argsOf(0x0F), 1, reason: '变色');
      expect(TextControlCodec.argsOf(0x11), 1);
      expect(TextControlCodec.argsOf(0x15), 1);
      expect(TextControlCodec.argsOf(0x1A), 1, reason: '菜单项');
      expect(TextControlCodec.argsOf(0x10), 2, reason: '变量：2 字节');
      expect(TextControlCodec.argsOf(0x01), 0, reason: '行等待无参');
      expect(TextControlCodec.argsOf(0x0B), 0, reason: '清屏无参');
      expect(TextControlCodec.argsOf(0x0C), 0);
    });

    test('decode：15 06 只吃 1 字节，后面汉字不被吞', () {
      // 真实字节：¶ [15][06] ⏳ ⌂ ⏳ (80 20) 呀，
      final raw = Uint8List.fromList([
        0x03, 0x15, 0x06, 0x01, 0x0B, 0x01, 0x80, 0x20,
        0xD1, 0xBD, 0xA3, 0xAC, // 呀，
      ]);
      final s = TextControlCodec.decode(
          raw, (b) => String.fromCharCodes(b.map((x) => gbkDoubleByte[(x << 8) | 0] ?? x)));
      // 关键是 0x06 被当作参数吃掉，后面的 0x01/0x0B 仍是独立控制码
      expect(s, contains('〔15:06〕'));
      expect(s, contains('〔01〕'));
      expect(s, contains('〔0B〕'));
    });

    test('decode → encode 往返：参数是单字节', () {
      final raw = Uint8List.fromList([
        0x15, 0x06, 0x01, 0x0F, 0x05, 0x1A, 0x01, 0x10, 0x1A, 0x01, 0x03,
      ]);
      final text = TextControlCodec.decode(
          raw, (b) => String.fromCharCodes(b));
      expect(text, '〔15:06〕〔01〕〔0F:05〕〔1A:01〕〔10:1A,01〕〔03〕');
      final back = TextControlCodec.encode(text, (s) =>
          Uint8List.fromList(s.codeUnits));
      expect(back, isNotNull);
      expect(back!.toList(), raw.toList(), reason: '必须逐字节还原');
    });

    test('真实烈火汉化版：#2101 完整可读，无乱码块', () {
      final s = _open(_gbk);
      final browser = TextBrowser(s.rom.liveRom);
      final t = browser.render(2101);
      // 修复前这段是「〔05:A101〕〔ADA1〕〔ADD3〕兄植豢伤家榈母芯酰」
      expect(t, contains('我叫琳'));
      expect(t, contains('是罗鲁卡族人'));
      expect(t, isNot(contains('兄植豢')));
      expect(t, isNot(contains('〔ADA1〕')));
    });

    test('真实烈火汉化版：#2174 塞恩那句通顺', () {
      final s = _open(_gbk);
      final t = TextBrowser(s.rom.liveRom).render(2174);
      expect(t, contains('塞恩'));
      expect(t, contains('侠气男'));
      expect(t, isNot(contains('歉觯')));
    });

    test('全表乱码率显著低于按 u16 读', () {
      final s = _open(_gbk);
      final rom = s.rom.liveRom;
      var bad = 0, total = 0;
      for (var id = 0; id < 4700; id++) {
        final raw = rom.decodeTextBytesAt(id);
        if (raw.isEmpty) continue;
        final t = TextBrowser(rom).render(id);
        bad += '□'.allMatches(t).length;
        total += t.length;
      }
      final rate = bad / total * 100;
      // 修复前实测 2.55%，修复后 0.43%
      expect(rate, lessThan(1.0), reason: '乱码率 ${rate.toStringAsFixed(2)}%');
    });
  });
}
