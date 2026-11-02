import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fe_editor/core/dialog_script.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/core/text_writer.dart';

const _dir = '/root/workspace/game-rom';
const _gbk = '火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba';
const _fe8jp =
    '1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

RomSession _open(String name) =>
    RomSession.open(File('$_dir/$name').readAsBytesSync(), name)!;

void main() {
  group('句子切分（纯逻辑）', () {
    test('按换行/清屏/按键切句，纯等待不切', () {
      final lines = DialogScript.splitLines(
          '〔01〕你好啊，〔01〕今天天气不错。〔03〕〔02〕是啊〔03〕');
      expect(lines.length, 2);
      expect(lines[0].text, '你好啊，今天天气不错。');
      expect(lines[1].text, '是啊');
    });

    test('纯控制码碎片并入下一句，不单独成行', () {
      final lines = DialogScript.splitLines('〔0B〕〔10:1A,01〕开头。〔03〕');
      expect(lines.length, 1);
      expect(lines[0].text, '开头。');
    });

    test('每句的 raw 带控制码，能拼回原文', () {
      const raw = '〔01〕甲说。〔03〕〔02〕乙说。〔03〕';
      final lines = DialogScript.splitLines(raw);
      final joined = lines.map((l) => l.raw).join();
      expect(joined, raw);
    });

    test('结尾只剩控制码时挂到上一句，不丢字节', () {
      // 真实案例：文本 #2103 结尾是〔03〕〔05〕，按句切分后最后只剩〔05〕。
      // 丢掉它就拼不回原记录，整条写入通道的前提就破了。
      const raw = '〔01〕甲。〔03〕〔05〕';
      final lines = DialogScript.splitLines(raw);
      expect(lines.map((l) => l.raw).join(), raw);
    });

    test('空文本不产生句子', () {
      expect(DialogScript.splitLines(''), isEmpty);
      // 纯控制码没有可见文字，不单独成句
      expect(DialogScript.splitLines('〔03〕').where((l) => !l.isEmpty), isEmpty);
    });

    test('特殊双字节占位符〔8020〕不当作控制码', () {
      final lines = DialogScript.splitLines('〔8020〕呀，〔03〕');
      expect(lines.length, 1);
      expect(lines[0].raw, contains('〔8020〕'));
    });

    test('句子序号连续', () {
      final lines = DialogScript.splitLines('一〔03〕二〔03〕三〔03〕');
      expect([for (final l in lines) l.index], [0, 1, 2]);
    });
  });

  group('真实 ROM 场景提取', () {
    test('烈火汉化版第 0 章：场景与句子都能读', () {
      final s = _open(_gbk);
      final d = DialogScript.of(s.rom, 0);
      expect(d.scenes, isNotEmpty);
      final first = d.scenes.first;
      expect(first.textId, 2101);
      expect(first.lines, isNotEmpty);
      // 切出来的句子必须是干净的中文，不能带乱码块
      final joined = first.lines.map((l) => l.text).join();
      expect(joined, contains('我叫琳'));
      expect(joined, isNot(contains('□')));
    });

    test('每一句的 raw 带控制码，且能交给写入通道', () {
      final s = _open(_gbk);
      final d = DialogScript.of(s.rom, 0);
      final writer = TextWriter(s.rom);
      for (final sc in d.scenes.take(3)) {
        final raw = sc.raw;
        expect(writer.currentText(sc.textId), raw,
            reason: '场景 raw 必须与写入通道看到的完全一致');
      }
    });

    test('整条 raw 回写不改变内容（identical）', () {
      final s = _open(_gbk);
      final d = DialogScript.of(s.rom, 0);
      final writer = TextWriter(s.rom);
      final sc = d.scenes.first;
      final r = writer.write(sc.textId, sc.raw);
      expect(r.mode, TextWriteMode.identical);
    });

    test('圣魔日版也能提取场景', () {
      final s = _open(_fe8jp);
      final d = DialogScript.of(s.rom, 0);
      expect(d.scenes, isNotEmpty);
      expect(d.scenes.first.lines, isNotEmpty);
    });

    test('空章节返回空列表而不是抛异常', () {
      final s = _open(_gbk);
      final d = DialogScript.of(s.rom, 999);
      expect(d.scenes, isEmpty);
    });
  });
}
