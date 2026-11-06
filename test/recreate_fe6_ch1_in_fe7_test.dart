import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fe_editor/core/portrait.dart';
import 'package:fe_editor/core/portrait_porter.dart';
import 'package:fe_editor/core/rom_session.dart';
import 'package:fe_editor/core/event_templates.dart';
import 'package:fe_editor/core/event_preview.dart';
import 'package:fe_editor/core/map_reader.dart';
import 'package:fe_editor/core/fe_rom.dart';

import 'rom_paths.dart';

/// 把「封印之剑 第一章」的队伍按同样节奏重建进「烈火之剑 序章」，
/// 产出一个能在模拟器里跑起来验证的改后 FE7 ROM。
///
/// 宿主用「佣兵公司完全汉化版」（FE7U，23MB，有大块空闲区）；原版 FE7（日/美/Superxyj）
/// 满包、塞不下肖像+事件。做法（全部走既有安全原语，改后可整体 revert）：
/// - 借用 FE7 的 5 个晚登场单位槽（charId 34-38），把 FE6 的肖像**就地替换**进这些槽；
/// - 按 FE6 第一章节奏（turn1 ロイ / turn3 ウォルト / turn5 リリーナ + 敌方）
///   追加 FE7 方言的增援事件（坐标钳制到宿主章地图内）；
/// - 职业/属性暂不改（保持槽自身合法的 FE7 职业），先保证「能进图、人物在场、不崩」。
void main() {
  test('recreate FE6 ch1 cast into FE7 prologue', () {
    final fe6 = RomSession.open(File(romDir + '/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba').readAsBytesSync(), 'fe6.gba')!;
    final fe7 = RomSession.open(File(romDir + '/佣兵公司完全汉化版.gba').readAsBytesSync(), 'fe7.gba')!;

    final fe6Rom = fe6.rom.liveRom;
    final edit = fe7.rom;
    final fe7Rom = edit.liveRom;
    const hostChapter = 0;

    // 地图尺寸（用于钳制坐标）
    final m = MapReader(fe7Rom).chapterMap(hostChapter)!;
    int cx(int x) => x.clamp(0, m.width - 1);
    int cy(int y) => y.clamp(0, m.height - 1);
    print('  宿主章地图 ${m.width}x${m.height}');

    int fe7Face(int fe7CharId) {
      final idx = fe7CharId - 1;
      return FeRom.u16(fe7Rom.data, fe7Rom.unitBase + idx * fe7Rom.table.unitDataSize + 6);
    }
    int fe6FaceOf(int fe6CharId) {
      final idx = fe6CharId - 1;
      return FeRom.u16(fe6Rom.data, fe6Rom.unitBase + idx * fe6Rom.table.unitDataSize + 6);
    }

    const royi = 34, wolt = 35, lili = 36, bors = 37, soldier = 38;
    final porter = PortraitPorter(edit);
    final src = PortraitReader(fe6Rom);
    void port(int fe7CharId, int fe6CharId, String tag) {
      final targetFace = fe7Face(fe7CharId);
      final srcId = fe6FaceOf(fe6CharId) - 1;
      final r = porter.port(src, srcId, replaceTargetId: targetFace);
      print('  [肖像] $tag: FE6#=$srcId -> FE7 face=$targetFace : ${r.result.name} ${r.message}');
      expect(r.ok, isTrue, reason: '肖像 $tag 移植失败：${r.message}');
    }
    port(royi, 1, 'ロイ');
    port(wolt, 13, 'ウォルト');
    port(lili, 38, 'リリーナ');
    port(bors, 9, 'ボールス');
    // 士兵 FE6 face=0（通用敌脸）→ 跳过肖像，保留 FE7 槽原脸

    // 按 FE6 第一章节奏刷兵（坐标钳制到宿主章地图内）
    EventTemplates(edit)
        .addReinforcement(chapter: hostChapter, turn: 1, units: [
      ReinforcementUnit(charId: royi, classId: 0, level: 1, x: cx(0), y: cy(0), allegiance: 0),
      ReinforcementUnit(charId: bors, classId: 0, level: 5, x: cx(6), y: cy(3), allegiance: 2),
      ReinforcementUnit(charId: soldier, classId: 0, level: 3, x: cx(7), y: cy(4), allegiance: 2),
      ReinforcementUnit(charId: soldier, classId: 0, level: 3, x: cx(8), y: cy(5), allegiance: 2),
      ReinforcementUnit(charId: soldier, classId: 0, level: 3, x: cx(9), y: cy(6), allegiance: 2),
      ReinforcementUnit(charId: soldier, classId: 0, level: 3, x: cx(10), y: cy(7), allegiance: 2),
    ]);
    EventTemplates(edit)
        .addReinforcement(chapter: hostChapter, turn: 3, units: [
      ReinforcementUnit(charId: wolt, classId: 0, level: 3, x: cx(13), y: cy(0), allegiance: 0),
    ]);
    final r5 = EventTemplates(edit)
        .addReinforcement(chapter: hostChapter, turn: 5, units: [
      ReinforcementUnit(charId: lili, classId: 0, level: 5, x: cx(10), y: cy(9), allegiance: 0),
    ]);
    expect(r5.ok, isTrue, reason: r5.message);

    // 读回验证：序章预览应包含这批 charId
    final p = EventPreviewer(edit).of(hostChapter);
    final ids = p.events.expand((e) => e.units.map((u) => u.charId)).toSet();
    print('  [事件] 序章现含 charId: ${ids}');
    for (final want in [royi, wolt, lili, bors, soldier]) {
      expect(ids, contains(want), reason: 'charId $want 没进序章事件');
    }

    final out = File(romDir + '/_fe7_fe6ch1.gba')
      ..writeAsBytesSync(edit.data);
    print('  [导出] ${out.path} (${edit.data.length}B, 改 ${edit.changedByteCount} 字节)');
  });
}
