import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/core/text_coverage.dart';
import 'package:fe_editor/core/text_writer.dart';

const _dir = '/root/workspace/game-rom';

RomSession _open(String name) =>
    RomSession.open(File('$_dir/$name').readAsBytesSync(), name)!;

void main() {
  test('明文 GBK 汉化版：常用汉字全都能写', () {
    final s = _open('火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba');
    final c = TextCoverageChecker(TextWriter(s.rom));
    expect(c.writable, isTrue);
    expect(c.engineLabel, contains('GBK'));

    const story = '清晨的薄雾笼罩着利贝拉城，艾瑞珂公主站在城墙上，'
        '望着远方燃烧的地平线。敌军旗帜在晨风中猎猎作响。';
    final r = c.check(story);
    expect(r.missing, isEmpty);
    expect(r.ok, isTrue);
    expect(r.checkedCount, greaterThan(20));
  });

  test('明文 GBK：缺字能逐个点名', () {
    final s = _open('火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba');
    final c = TextCoverageChecker(TextWriter(s.rom));
    // GBK 码表外的字（扩展区汉字不在 gbkDoubleByte 里）
    final r = c.check('正常文字㐀');
    expect(r.missing, contains('㐀'));
    expect(r.ok, isFalse);
  });

  test('控制码占位符不参与缺字检查', () {
    final s = _open('火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba');
    final c = TextCoverageChecker(TextWriter(s.rom));
    final withCtrl = c.check('〔0C〕你好〔03〕世界〔15〕');
    final withoutCtrl = c.check('你好世界');
    expect(withCtrl.missing, withoutCtrl.missing);
    // 占位符本身不是文字，不该把 checkedCount 算大
    expect(withCtrl.checkedCount, withoutCtrl.checkedCount);
  });

  test('日版 SJIS：中文常用字会缺一部分，且缺的具体是哪些字', () {
    final s = _open(
        '1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba');
    final c = TextCoverageChecker(TextWriter(s.rom));
    expect(c.writable, isTrue);
    // 简体中文人名在日文字库里基本都没有（实测 6 个全缺）
    final r = c.check('琳琪芙蒂罗伊');
    expect(r.checkedCount, 6);
    expect(r.missing.length, 6);
    // 日文汉字（旧字体）可以
    expect(c.encodable('剣'), isTrue);
    expect(c.charset.label, contains('SJIS'));
  });

  test('汉化码表版：码表外的字全部点名', () async {
    final s = _open('火炎之纹章-圣魔之光石汉化.gba');
    await s.attachZhTableIfNeeded();
    final c = TextCoverageChecker(TextWriter(s.rom));
    expect(c.writable, isTrue);
    final r = c.check('琪琳芙蒂');
    expect(r.missing.length, 4);
    expect(r.checkedCount, 4);
    expect(r.ratio, 0);
  });

  test('ASCII 永远可写', () {
    final s = _open('火炎之纹章-圣魔之光石汉化.gba');
    final c = TextCoverageChecker(TextWriter(s.rom));
    final r = c.check('ABC123 !?');
    expect(r.missing, isEmpty);
  });

  test('toJson 字段齐全（MCP 直接返回它）', () {
    final s = _open('火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba');
    final r = TextCoverageChecker(TextWriter(s.rom)).check('测试');
    final j = r.toJson();
    expect(j.keys, containsAll(['writable', 'ok', 'checked', 'ratio', 'missing']));
    expect(j['ok'], isTrue);
  });
}

// 注：tree URI 解析在原生 Kotlin 侧（MainActivity.treeDisplayName），
// Dart 单元测试无法覆盖。这里锁住的是 Dart 侧对「原生返回 null / 抛错」的容错，
// 原生行为由下方注释记录，改动时对照检查。
//
// 事故记录（v2.4.9 首版）：describeWorkspace 用 contentResolver.query() 取目录名，
// 而 SAF 的 tree URI 不支持 query，抛
//   UnsupportedOperationException: Unsupported Uri content://.../tree/primary%3A...
// 该调用在 onActivityResult 主线程上且无 try-catch → 设置工作区直接闪退。
// 修法：tree URI 走 DocumentsContract.getTreeDocumentId 解析（treeDisplayName），
// 且所有调用点都包 try-catch。
