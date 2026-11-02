import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fe_editor/core/event_preview.dart';
import 'package:fe_editor/core/rom_session.dart';

const _dir = '/root/workspace/game-rom';
const _gbk = '火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba';
const _fe8jp =
    '1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';
const _fe6jp =
    '0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';

RomSession _open(String name) =>
    RomSession.open(File('$_dir/$name').readAsBytesSync(), name)!;

void main() {
  group('对话预览', () {
    test('时间线给出台词，且句子可读无乱码', () {
      final s = _open(_gbk);
      final p = DialogPreviewer(s.rom).of(0);
      expect(p.lines, isNotEmpty);
      expect(p.chapterTitle, isNotEmpty);
      final all = p.lines.map((l) => l.text).join();
      expect(all, contains('我叫琳'));
      expect(all, isNot(contains('□')));
      expect(all, isNot(contains('兄植豢')));
    });

    test('说话人不猜：一律为 null 且标 unavailable', () {
      final s = _open(_gbk);
      final p = DialogPreviewer(s.rom).of(0);
      for (final l in p.lines) {
        // 拿不到就留空，不能用「上一句说话人」之类猜出来的值
        expect(l.speaker, isNull);
        expect(l.speakerSource, PreviewSource.unavailable);
      }
    });

    test('控制码占位符被抽出来（`控制码有没丢`的自查点）', () {
      final s = _open(_gbk);
      final p = DialogPreviewer(s.rom).of(0);
      final withTokens = p.lines.where((l) => l.controlTokens.isNotEmpty);
      expect(withTokens, isNotEmpty, reason: '对话里一定有控制码');
      for (final l in p.lines) {
        for (final t in l.controlTokens) {
          expect(t, startsWith('〔'));
          expect(t, endsWith('〕'));
        }
      }
    });

    test('控制码占位符按**这一句**统计，不是整段的', () {
      final s = _open(_gbk);
      final p = DialogPreviewer(s.rom).of(0);
      final first = p.lines.first;
      // 回归：曾经每行都返回整段的全部控制码（41 个），会误导 AI 自查
      expect(first.controlTokens.length, lessThan(first.sceneControlCount));
      expect(first.controlTokens.length, greaterThan(0));
      // 同一段内各行的控制码数不应全部相同（说明确实是按行算的）
      final sameScene = p.lines.where((l) => l.textId == first.textId).toList();
      final counts = sameScene.map((l) => l.controlTokens.length).toSet();
      expect(counts.length, greaterThan(1),
          reason: '各行控制码数完全一样，很可能又退回了按整段算');
    });

    test('每句 raw 拼回去等于原记录（分句不丢字）', () {
      final s = _open(_gbk);
      final p = DialogPreviewer(s.rom).of(0);
      for (final scene in p.scenes) {
        final joined = p.lines
            .where((l) => l.textId == scene.textId)
            .map((l) => l.raw)
            .join();
        expect(joined, scene.raw, reason: '文本 #${scene.textId} 分句后拼不回原记录');
      }
    });

    test('数据自洽：文本 ID 与 raw 一一对应', () {
      final s = _open(_gbk);
      final p = DialogPreviewer(s.rom).of(0);
      for (final l in p.lines) {
        expect(s.rom.liveRom.textEntryOffset(l.textId), greaterThanOrEqualTo(0));
        expect(l.raw, isNotEmpty);
        expect(l.issues, isEmpty, reason: '原版 ROM 不该有自洽问题');
      }
    });

    test('多版本都能出预览（不是只对汉化版有效）', () {
      for (final f in [_fe8jp, _fe6jp]) {
        final s = _open(f);
        final p = DialogPreviewer(s.rom).of(0);
        expect(p.lines, isNotEmpty, reason: '${s.versionId} 应该有对话');
      }
    });

    test('空章节给出说明而不是抛异常', () {
      final s = _open(_gbk);
      final p = DialogPreviewer(s.rom).of(999);
      expect(p.lines, isEmpty);
      expect(p.issues, isNotEmpty);
    });
  });

  group('事件触发预览', () {
    test('生成一行自然语言，含回合/阵营/坐标/单位名', () {
      final s = _open(_gbk);
      final p = EventPreviewer(s.rom).of(0);
      final withUnits = p.events.where((e) => e.units.isNotEmpty);
      expect(withUnits, isNotEmpty);
      final s0 = withUnits.first.sentence;
      expect(s0, contains('回合'));
      expect(s0, contains('生成'));
      expect(s0, contains('('));
    });

    test('FE6 的「第 N 回合起」也能解析出来', () {
      final s = _open(_fe6jp);
      final p = EventPreviewer(s.rom).of(0);
      final sents = p.events.map((e) => e.sentence).join('\n');
      expect(sents, contains('第 3 回合起'), reason: 'FE6 第 0 章有第 3 回合增援');
    });

    test('单位明细带角色/职业/等级/坐标/道具名', () {
      final s = _open(_gbk);
      final p = EventPreviewer(s.rom).of(0);
      final u = p.events
          .firstWhere((e) => e.units.isNotEmpty)
          .units
          .firstWhere((x) => x.name.isNotEmpty);
      expect(u.charId, greaterThan(0));
      expect(u.name, isNotEmpty);
      expect(u.className, isNotEmpty);
      expect(u.level, greaterThanOrEqualTo(1));
      expect(u.allegianceName, isIn(['我方', '友军', '敌方']));
    });

    test('坐标在地图内时不自洽问题为空', () {
      final s = _open(_gbk);
      final p = EventPreviewer(s.rom).of(0);
      expect(p.mapWidth, greaterThan(0));
      for (final e in p.events) {
        for (final u in e.units) {
          expect(u.x, lessThan(p.mapWidth));
          expect(u.y, lessThan(p.mapHeight));
          expect(u.issues, isEmpty, reason: '${u.name} 坐标 ${u.x},${u.y}');
        }
      }
    });

    test('同阵营同角色同坐标不重复列（LOADUNIT 被引用两次的情况）', () {
      final s = _open(_gbk);
      final p = EventPreviewer(s.rom).of(0);
      for (final e in p.events) {
        if (e.units.isEmpty) continue;
        // 句子按阵营分行，每行自报的「生成 N 个单位」应与该行列出的数量一致
        for (final line in e.sentence.split('\n')) {
          final m = RegExp(r'生成 (\d+) 个单位').firstMatch(line);
          if (m == null) continue;
          final declared = int.parse(m.group(1)!);
          final listed = line.split('：').last.split('、').length;
          expect(listed, declared,
              reason: '自报 $declared 个但列了 $listed 个：$line');
        }
      }
    });

    test('空章节给出说明而不是抛异常', () {
      final s = _open(_gbk);
      final p = EventPreviewer(s.rom).of(999);
      expect(p.events, isEmpty);
      expect(p.issues, isNotEmpty);
    });
  });

  group('预览边界声明', () {
    test('两个视图都带上「不是游戏画面」的数据来源标记', () {
      final s = _open(_gbk);
      final d = DialogPreviewer(s.rom).of(0);
      final e = EventPreviewer(s.rom).of(0);
      // 序列化后必须能看出说话人是「未解析」而不是被填了假值
      final json = d.toJson();
      final lines = json['lines'] as List;
      expect((lines.first as Map)['speaker_source'], 'unavailable');
      // 事件预览必须带地图尺寸（坐标校验的前提，缺了要显式说明）
      expect(e.toJson()['map'], isA<Map>());
    });
  });
}
