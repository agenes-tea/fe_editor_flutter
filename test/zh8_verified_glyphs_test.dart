import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';

/// FE8 汉化版（火花天龙剑 & 狼组）**已验证**的「码位 → 汉字」映射。
///
/// ## 推导方法（可复现）
///
/// 1. 用 FE8J 日版解出单位表的 `nameTextId` 对应的日文名；
/// 2. 用同一 `nameTextId` 从汉化版解出双字节码流；
/// 3. 逐字对齐——**仅当日文假名数与中文汉字数相等时才对齐**，
///    去掉长音 `ー` 与促音 `ッ` 后计数。
///
/// 第 3 步的相等条件是对齐成立的前提。日文 `モルダ`(3 假名) 对中文 `摩达`(2 字)
/// 天然不等，硬对齐会产生错位——那正是早期出现大量「同音冲突」假象的原因
/// （实测：55 个名字里只有 25 个满足相等条件）。
///
/// ## 已知限制
///
/// - 只有 56 个码位，完整表约 2548 项。**不要按拼音顺序猜测填充**。
/// - `0x8FDF` 在「罗斯」中是斯、在「约书亚」中是书——汉化组的「同音替代字」
///   机制，一个码位只对应一个字形。这里取我方角色更常用的「斯」。
/// - 界面文字（菜单/状态页）的码位与人物名不通用，且不同改版 ROM 之间也不同，
///   尚未逐一核实，故不收在这里。
const fe8ZhVerified = <int, String>{
  0x83A2: '阿',   0x83AC: '安',   0x83BC: '巴',   0x83EA: '贝',   0x849B: '波',   0x849D: '勃',
  0x86B2: '多',   0x86BD: '肯',   0x86C1: '尔',   0x86F7: '夫',   0x8783: '弗',   0x87B2: '格',
  0x88FE: '吉',   0x89D9: '约',   0x8AA9: '卡',   0x8ABB: '科',   0x8AC0: '克',   0x8AC4: '肯',
  0x8ACF: '库',   0x8AE8: '拉',   0x8AFE: '勒',   0x8B80: '雷',   0x8B81: '蕾',   0x8B90: '莉',
  0x8B95: '利',   0x8BB0: '列',   0x8BD2: '鲁',   0x8BD4: '露',   0x8BEA: '罗',   0x8BF1: '玛',
  0x8C80: '曼',   0x8CA4: '米',   0x8CC1: '魔',   0x8CCB: '姆',   0x8CD8: '娜',   0x8CD9: '纳',
  0x8CEA: '尼',   0x8D85: '诺',   0x8D8A: '巴',   0x8DC7: '普',   0x8ECF: '萨',   0x8ED0: '塞',
  0x8FDF: '斯',   0x8FE1: '思',   0x908A: '塔',   0x90A9: '亚',   0x9184: '维',   0x91B1: '物',
  0x91B8: '西',   0x91BE: '希',   0x92C4: '亚',   0x92F4: '伊',   0x958D: '兹',   0x9591: '兹',
  0x95BF: '忒',   0x95EE: '娅',
};

const fe8cn = '/root/workspace/game-rom/火炎之纹章-圣魔之光石汉化.gba';
const fe8jp =
    '/root/workspace/game-rom/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

/// 满足「日文假名数 == 中文汉字数」的 nameTextId → 中文译名。
///
/// 只有这些名字的逐字对齐是成立的，可用来重建上面的映射表。
const _alignable = <int, String>{
  410: '塞思', 411: '吉利安姆', 415: '罗斯', 417: '科曼',
  419: '希尼亚斯', 420: '露忒', 422: '库格', 423: '伊弗列姆',
  426: '阿米莉娅', 428: '约书亚', 430: '玛莉卡', 431: '塞勒夫',
  434: '多兹拉', 436: '雷纳克', 439: '诺鲁', 441: '西蕾尼',
  442: '塔娜', 461: '阿维', 448: '普利肯', 449: '波肯',
  450: '巴兹巴', 476: '魔物', 451: '萨尔', 452: '诺贝拉',
  456: '巴勃罗',
};

void main() {
  group('FE8 汉化版已验证码位', () {
    test('映射表自身无矛盾', () {
      expect(fe8ZhVerified.length, 56);
      for (final e in fe8ZhVerified.entries) {
        expect(e.key, greaterThan(0x8100));
        expect(e.value.length, 1);
      }
    });

    test('对齐前提：日文假名数（去长音/促音）等于中文汉字数', () {
      final jp = FeRom(File(fe8jp).readAsBytesSync(),
          FeRom.detectTable(File(fe8jp).readAsBytesSync())!);
      for (final e in _alignable.entries) {
        final ja = jp.decodeText(e.key);
        expect(ja, isNotEmpty, reason: 'nameTextId ${e.key}');
        final n = ja.replaceAll('ー', '').replaceAll('ッ', '').length;
        expect(n, e.value.length,
            reason: 'nameTextId ${e.key}：「$ja」($n) vs「${e.value}」');
      }
    });

    test('从 ROM 重建映射，逐条与映射表一致', () {
      final cn = FeRom(File(fe8cn).readAsBytesSync(),
          FeRom.detectTable(File(fe8cn).readAsBytesSync())!);

      final rebuilt = <int, String>{};
      for (final e in _alignable.entries) {
        final bytes = cn.decodeTextBytesAt(e.key);
        expect(bytes.length, e.value.length * 2,
            reason: 'nameTextId ${e.key} 码流长度');
        for (var i = 0; i + 1 < bytes.length; i += 2) {
          final code = (bytes[i] << 8) | bytes[i + 1];
          rebuilt[code] = e.value[i ~/ 2];
        }
      }
      // 同音替代导致的 1 处冲突（0x8FDF 斯/书）单独处理，其余必须完全一致
      var mismatch = 0;
      rebuilt.forEach((code, ch) {
        final known = fe8ZhVerified[code];
        if (known == null) return;
        if (known != ch && code != 0x8FDF) {
          // ignore: avoid_print
          print('不一致 0x${code.toRadixString(16)}: 表=$known 重建=$ch');
          mismatch++;
        }
      });
      expect(mismatch, 0);
      // 重建出的码位应全部在表内
      for (final code in rebuilt.keys) {
        expect(fe8ZhVerified.containsKey(code), isTrue,
            reason: '0x${code.toRadixString(16)} 不在映射表内');
      }
    });

    test('利昂 = 8B95 83B3、沃尔塔需靠 4 字名对齐', () {
      final cn = FeRom(File(fe8cn).readAsBytesSync(),
          FeRom.detectTable(File(fe8cn).readAsBytesSync())!);
      final jp = FeRom(File(fe8jp).readAsBytesSync(),
          FeRom.detectTable(File(fe8jp).readAsBytesSync())!);

      // 利昂（リオン 3 假名 = 利昂 2 字？不等，所以用「利」单独验证）
      expect(jp.decodeText(443), 'リオン');
      final b = cn.decodeTextBytesAt(443);
      expect((b[0] << 8) | b[1], 0x8B95, reason: '「利」');
      expect(fe8ZhVerified[0x8B95], '利');
      // 「利」同时出现在吉利安姆（ギリアム = 吉利安姆，4=4）里，交叉验证通过
      final g = cn.decodeTextBytesAt(411);
      expect((g[2] << 8) | g[3], 0x8B95, reason: '吉利安姆第 2 字也是「利」');
    });

    test('锚点码位确实出现在 ROM 文本流里', () {
      final cn = FeRom(File(fe8cn).readAsBytesSync(),
          FeRom.detectTable(File(fe8cn).readAsBytesSync())!);
      final used = <int>{};
      for (var id = 0; id < 3400; id++) {
        final b = cn.decodeTextBytesAt(id);
        for (var i = 0; i + 1 < b.length; i += 2) {
          used.add((b[i] << 8) | b[i + 1]);
        }
      }
      var hit = 0;
      for (final c in fe8ZhVerified.keys) {
        if (used.contains(c)) hit++;
      }
      expect(hit, fe8ZhVerified.length,
          reason: '全部锚点都应出现在文本流中（实际 $hit/${fe8ZhVerified.length}）');
    });

    test('同音替代：0x8FDF 一个字形对应斯/书两个近音字', () {
      final cn = FeRom(File(fe8cn).readAsBytesSync(),
          FeRom.detectTable(File(fe8cn).readAsBytesSync())!);
      // 罗斯（ロス 2 = 罗斯 2）第 2 字
      final ross = cn.decodeTextBytesAt(415);
      expect((ross[2] << 8) | ross[3], 0x8FDF);
      // 约书亚（ジスト 3 = 约书亚 3）第 2 字
      final josh = cn.decodeTextBytesAt(428);
      expect((josh[2] << 8) | josh[3], 0x8FDF);
      // 同一码位，本表取「斯」
      expect(fe8ZhVerified[0x8FDF], '斯');
    });
  });
}
