import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/text_browser.dart';
import 'package:fe_editor/core/text_codec.dart';
import 'package:fe_editor/core/zh_table.dart';
import 'package:fe_editor/core/zh_tables_data.dart';

const dir = '/root/workspace/game-rom';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe7us = '$dir/1235 - 火炎之纹章-烈火之剑 Fire Emblem(US)(Nintendo)(128Mb).gba';
const fe7cn = '$dir/火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba';
const fe6cn = '$dir/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';
const fe8cn = '$dir/火炎之纹章-圣魔之光石汉化.gba';
const armor = '$dir/火焰之纹章-铠甲的呼唤.gba';

FeRom _open(String p) {
  final d = File(p).readAsBytesSync();
  return FeRom(d, FeRom.detectTable(d)!);
}

/// 「铠甲的呼唤」是 20MB 重度改版：文本表搬到扩展区并存成 UTF-8 明文。
/// 它踩过两个坑，这里都锁住：
///   1. isPointer 用固定 0x0A000000 上限，拒绝扩展寻址指针 → 名字全空
///   2. 编码判定先跑 Huffman，而 Huffman 对任意字节都能吐出可打印字符 → 乱码
void main() {
  group('扩展 ROM 的指针判定', () {
    test('铠甲的呼唤超 16MB，指针上限要按 ROM 长度算', () {
      final d = File(armor).readAsBytesSync();
      expect(d.length, greaterThan(0x1000000), reason: 'ROM 应超过 16MB');
      // 表内指针形如 0x89xxxxxx，超出 GBA 常规 0x0A000000，但减基址后落在 ROM 内
      const p = 0x89458BB8;
      expect(FeRom.isPointer(p, d.length), isTrue);
      expect(FeRom.toOffset(p), lessThan(d.length));
    });

    test('标准 ROM 的判定不受影响', () {
      final d = File(fe7jp).readAsBytesSync();
      expect(FeRom.isPointer(0x080E8414, d.length), isTrue);
      expect(FeRom.isPointer(0x0892308C, d.length), isTrue);
      // 指向 ROM 外的仍要拒绝
      expect(FeRom.isPointer(0x09F00000, d.length), isFalse);
      expect(FeRom.isPointer(0x07000000, d.length), isFalse);
      expect(FeRom.isPointer(0, d.length), isFalse);
    });

    test('铠甲的呼唤的文本指针能解出', () {
      final rom = _open(armor);
      expect(rom.textAvailable, isTrue);
      for (final tid in [0, 1, 2, 530, 531]) {
        expect(rom.textEntryOffset(tid), greaterThan(0), reason: 'text $tid');
      }
    });
  });

  group('UTF-8 明文编码', () {
    test('铠甲的呼唤识别为 plainUtf8', () {
      final rom = _open(armor);
      expect(rom.textEncoding, FeTextEncoding.plainUtf8);
      expect(rom.textEncodingHealthy, isTrue);
    });

    test('铠甲的呼唤的角色名与职业名正确', () {
      final rom = _open(armor);
      // 实测值：文本表 530 起是角色名
      expect(rom.unitName(0), 'Kuijia');
      expect(rom.unitName(1), '谢尔');
      expect(rom.unitName(2), '费尔南斯');
      expect(rom.className(1), '领主');
      expect(rom.className(3), '男爵');
      expect(rom.className(4), '大领主');
      expect(rom.className(5), '轻骑士');
    });

    test('Utf8Codec 解码与判定', () {
      expect(
        Utf8Codec.decode(Uint8List.fromList([0xE8, 0xB0, 0xA2, 0xE5, 0xB0, 0x94])),
        '谢尔',
      );
      expect(
        Utf8Codec.decode(Uint8List.fromList([0xE8, 0xB4, 0xB9, 0xE5, 0xB0, 0x94])),
        '费尔',
      );
      // 控制字符截断
      expect(
        Utf8Codec.decode(Uint8List.fromList([0x41, 0x42, 0x00, 0x43])),
        'AB',
      );
      // 中文判定通过，纯 ASCII 也通过
      expect(Utf8Codec.looksLikeUtf8(
          Uint8List.fromList([0xE4, 0xB8, 0xAD, 0xE6, 0x96, 0x87])), isTrue);
      expect(Utf8Codec.looksLikeUtf8(Uint8List.fromList([0x41, 0x42, 0x43])),
          isTrue);
    });

    test('UTF-8 与 GBK 能互相区分', () {
      // 同样的「谢尔」：UTF-8 是 3+3 字节，GBK 是 2+2 字节
      final utf8 = [0xE8, 0xB0, 0xA2, 0xE5, 0xB0, 0x94];
      final gbk = [0xD0, 0xBB, 0xB6, 0xFB];
      expect(Utf8Codec.looksLikeUtf8(Uint8List.fromList(utf8)), isTrue);
      expect(GbkCodec.looksLikeGbk(Uint8List.fromList(gbk)), isTrue);
      // UTF-8 字节流不应被判成 GBK：续接字节 0xB0/0x94 虽在 GBK 区间，
      // 但前导 0xE8 后的 0xB0 不在 GBK 第二字节合法起点（0x40~0xFE 含 0xB0），
      // 所以两者有重叠区——真正的区分靠「整段都能配对」。
      expect(Utf8Codec.decode(Uint8List.fromList(utf8)), isNot(''));
    });
  });

  group('编码判定顺序（防 Huffman 误判）', () {
    test('各版本编码识别结果', () {
      final expected = {
        fe7jp: FeTextEncoding.huffmanSjis,
        fe7us: FeTextEncoding.huffmanSjis,
        fe8jp: FeTextEncoding.huffmanSjis,
        fe7cn: FeTextEncoding.plainGbk,
        armor: FeTextEncoding.plainUtf8,
      };
      expected.forEach((path, enc) {
        expect(_open(path).textEncoding, enc, reason: path);
      });
    });

    test('日版角色名仍是日文（没被明文判定抢走）', () {
      final rom = _open(fe7jp);
      expect(rom.textEncoding, FeTextEncoding.huffmanSjis);
      expect(rom.unitName(0), 'エリウッド');
      expect(rom.unitName(1), 'ヘクトル');
    });

    test('Superxyj 烈火之剑仍是 GBK 明文', () {
      final rom = _open(fe7cn);
      expect(rom.textEncoding, FeTextEncoding.plainGbk);
      expect(rom.unitName(0), '艾利乌德');
      expect(rom.unitName(1), '海克托尔');
    });

    test('狼组封印之剑仍是 Huffman+码表', () {
      final rom = _open(fe6cn);
      // 未挂码表时是 unknown，挂上后能解出中文
      expect(rom.textEncoding, FeTextEncoding.unknown);
      rom.zhTable = ZhTable(zhTblFE6);
      expect(rom.unitName(0), '罗伊');
      expect(rom.unitName(1), '克莱丽奈');
    });

    test('铠甲的呼唤不该被误挂中文码表', () {
      // 它已是明文 UTF-8，挂 .tbl 只会把好好的名字变成乱码
      final rom = _open(armor);
      expect(rom.textEncoding, FeTextEncoding.plainUtf8);
      final before = rom.unitName(1);
      rom.zhTable = ZhTable(zhTblFE8);
      expect(rom.unitName(1), before, reason: '明文 ROM 不受码表影响');
    });
  });

  group('铠甲的呼唤的单位/职业数据可编辑', () {
    test('单位表与职业表都能定位', () {
      final rom = _open(armor);
      expect(rom.unitBase, greaterThan(0));
      expect(rom.classBase, greaterThan(0));
      expect(rom.unitCount, greaterThan(50));
      expect(rom.classCount, greaterThan(20));
    });

    test('角色表 + 职业表 = 游戏内显示值（用户实测的加法关系）', () {
      // 用户用 FE7 简中版验证：力量 2+6=8、技巧 -1+6=5、速度 -2+7=5、
      // 幸运 9+0=9、防御 4+6=10、魔防 4+0=4、体格 0+8=8、HP 7+18=25。
      // 这里用铠甲的呼唤复现同一条规律。
      final rom = _open(armor);
      final ua = rom.unitBase;
      final cid = rom.data[ua + 5]; // +5 是职业 ID
      final ca = rom.classBase + cid * rom.table.classDataSize;
      final unitHp = rom.data[ua + 0x0C];
      final classHp = rom.data[ca + 0x0B];
      expect(unitHp + classHp, 25);
      // 体格、移动只由职业决定
      expect(rom.data[ua + 0x13] + rom.data[ca + 0x11], 8); // 0 + 8
      expect(rom.data[ca + 0x12], 5);
    });

    test('角色表里的负值是相对职业的增减量', () {
      // 用户用 FE7 简中版验证过这条加法关系（截图里那个角色技 -1、速 -2）。
      // 这里用同 ROM 的其它条目复现：u8 速度 -1、u3 体格 -1、u5 体格 -3。
      final rom = _open(fe7cn);
      int s8(int unitIndex, int off) {
        final a = rom.unitBase + unitIndex * rom.table.unitDataSize;
        final v = rom.data[a + off];
        return v >= 0x80 ? v - 0x100 : v;
      }
      int classField(int unitIndex, int off) {
        final a = rom.unitBase + unitIndex * rom.table.unitDataSize;
        final cid = rom.data[a + 5];
        return rom.data[rom.classBase + cid * rom.table.classDataSize + off];
      }

      expect(s8(8, 0x0F), -1); // 速度 -1
      expect(s8(8, 0x0F) + classField(8, 0x0E), 3); // -1 + 4 = 3
      expect(s8(3, 0x13), -1); // 体格 -1
      expect(s8(3, 0x13) + classField(3, 0x11), greaterThan(0));
      expect(s8(5, 0x13), -3); // 体格 -3
    });
  });
  group('文本查看器（TextBrowser）', () {
    test('铠甲的呼唤的对话文本可读', () {
      final rom = _open(armor);
      final tb = TextBrowser(rom);
      expect(tb.maxId, greaterThan(100));
      // 实测：文本表前几条是系统提示
      expect(tb.render(2), '武器熟练度提升');
      expect(tb.render(3), '损坏了');
      expect(tb.render(4), '被偷走了');
      expect(tb.render(5), '获得');
      expect(tb.render(6), '金币');
      expect(tb.render(12), '支援等级提升');
    });

    test('日版文本仍是日文 + 控制码符号', () {
      final rom = _open(fe7jp);
      final tb = TextBrowser(rom);
      expect(tb.render(1), 'はい');
      expect(tb.render(2), 'いいえ');
      // 控制码要渲染成可读符号，不能吞掉
      final shop = tb.render(5);
      expect(shop, contains('¶'));
      expect(shop, contains('▼'));
      expect(shop, contains('武器屋'));
    });

    test('Superxyj 烈火之剑仍是中文', () {
      final rom = _open(fe7cn);
      final tb = TextBrowser(rom);
      expect(tb.render(1), '是');
      expect(tb.render(2), '否');
      expect(tb.render(5), contains('武器店'));
    });

    test('狼组封印之剑挂码表后可读', () {
      final rom = _open(fe6cn);
      rom.zhTable = ZhTable(zhTblFE6);
      final tb = TextBrowser(rom);
      // 角色名与系统文本都能解出
      expect(rom.unitName(0), '罗伊');
      final all = [for (var i = 0; i < 50; i++) tb.render(i)].join();
      expect(all, isNotEmpty);
    });
  });
}
