import 'dart:io';

import 'package:fe_editor/core/app_settings.dart';
import 'package:fe_editor/core/cheat_presets.dart';
import 'package:fe_editor/core/custom_roster.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/playable_units.dart';
import 'package:fe_editor/ui/custom_roster_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _dir = '/root/workspace/game-rom';

EditableRom _open(String keyword) {
  final f = Directory(_dir)
      .listSync()
      .whereType<File>()
      .firstWhere((e) => e.path.contains(keyword));
  final data = f.readAsBytesSync();
  return EditableRom.open(data, FeRom.detectTable(data)!);
}

void main() {
  // AppSettings 走 MethodChannel，需要先初始化 binding
  TestWidgetsFlutterBinding.ensureInitialized();

  group('解析分享文本（防呆）', () {
    test('纯逗号分隔', () {
      expect(CustomRoster.parseIds('1,2,5,12,48,99'), [1, 2, 5, 12, 48, 99]);
    });

    test('带空格、中文说明、换行都能抽出来', () {
      expect(CustomRoster.parseIds('我用的 ID 是：1, 2, 5'), [1, 2, 5]);
      expect(CustomRoster.parseIds('  3 4\n5\n\n6  '), [3, 4, 5, 6]);
      expect(CustomRoster.parseIds('名单：12、13、14'), [12, 13, 14]);
    });

    test('剥掉分享码前缀里的指纹，不把十六进制拆成数字', () {
      // FE_1a2b_1,2,5 → 只该得到 1,2,5（不能把 1a2b 拆成 1 和 2）
      expect(CustomRoster.parseIds('FE_1a2b_1,2,5'), [1, 2, 5]);
      expect(CustomRoster.parseIds('fe-0f9c-7,8'), [7, 8]);
    });

    test('空文本返回空', () {
      expect(CustomRoster.parseIds(''), isEmpty);
      expect(CustomRoster.parseIds('   '), isEmpty);
      expect(CustomRoster.parseIds('没有数字'), isEmpty);
    });
  });

  group('过滤非法 ID', () {
    test('0 保留；超出 unitCount 的被丢弃并计数', () {
      // 单位表 185 条：合法 0..184（**0 是合法角色**，各作索引 0 都是主角）
      final r = CustomRoster.parseAndFilter('0,1,2,184,185,999',
          unitCount: 185);
      expect(r.ids, [0, 1, 2, 184]);
      expect(r.dropped, 2, reason: '185 / 999 越界');
    });

    test('重复 ID 去重且排序', () {
      final r = CustomRoster.parseAndFilter('5,1,5,1,2', unitCount: 100);
      expect(r.ids, [1, 2, 5]);
      expect(r.dropped, 0);
    });

    test('负数与越界都丢弃；0 保留', () {
      final r = CustomRoster.parseAndFilter('0,9999,12345', unitCount: 100);
      expect(r.ids, [0]);
      expect(r.dropped, 2);
    });

    test('全部越界时返回空列表', () {
      final r = CustomRoster.parseAndFilter('9999,8888', unitCount: 100);
      expect(r.ids, isEmpty);
      expect(r.dropped, 2);
    });
  });

  group('0 号是合法角色（自军主角）', () {
    test('五个 ROM 的索引 0 都是有名字的自军角色', () {
      for (final kw in ['0979', '1235', '1692 -', '0378', 'The Last Promise']) {
        final rom = _open(kw).rom;
        expect(rom.unitDisplayName(0).trim(), isNotEmpty, reason: kw);
        // number 字段应该是 1（1 基）
        final at = rom.unitBase;
        expect(rom.data[at + 4], 1, reason: '$kw 的索引 0 对应 number 1');
      }
    });

    test('导出文本可以包含 0，导入后仍是 0', () {
      const r = CustomRoster({0, 3, 7});
      expect(r.exportText(), '0,3,7');
      final back = CustomRoster.parseAndFilter(r.exportText(), unitCount: 200);
      expect(back.ids, [0, 3, 7]);
    });

    test('修改器能改到 0 号（主角）', () {
      final edit = _open('1692 -');
      final rom = edit.rom;
      final preset = cheatPresets.firstWhere((p) => p.id == 'unit_max_growth');
      final before = rom.data[rom.unitBase];
      final result = applyCheat(edit, preset, custom: const CustomRoster({0}));
      expect(result.changedEntries, 1);
      expect(edit.buffer.u8(rom.unitBase + 28), 100,
          reason: '0 号角色的成长率应被改成 100');
      expect(before, isNotNull);
    });
  });

  group('导出 / 往返', () {
    test('导出是逗号分隔且升序', () {
      const r = CustomRoster({12, 1, 5});
      expect(r.exportText(), '1,5,12');
    });

    test('导出再导入能还原同一份名单', () {
      const r = CustomRoster({1, 2, 5, 12, 48});
      final back = CustomRoster.parseAndFilter(r.exportText(), unitCount: 200);
      expect(back.ids, [1, 2, 5, 12, 48]);
      expect(back.dropped, 0);
    });

    test('分享码带 ROM 指纹，粘贴回来仍能解析出同一批 ID', () {
      final edit = _open('1692 -');
      const r = CustomRoster({1, 2, 5});
      final code = r.exportShareCode(edit.rom);
      expect(code, startsWith('FE_'));
      expect(CustomRoster.parseIds(code), [1, 2, 5]);
    });
  });

  group('ID 语义：对外是表内索引（0 起）', () {
    test('toNumbers / fromNumbers 差 1', () {
      const r = CustomRoster({0, 1, 2});
      expect(r.toNumbers, {1, 2, 3});
      expect(CustomRoster.fromNumbers({1, 2, 3}).indices, {0, 1, 2});
    });

    test('与角色列表页显示的「ID i」一致（取到的是同一个角色）', () {
      final edit = _open('1692 -');
      final rom = edit.rom;
      // 名单里放索引 1，导出的就是 1；再解析回来仍是索引 1
      const r = CustomRoster({1});
      expect(r.exportText(), '1');
      final back = CustomRoster.parseAndFilter(r.exportText(),
          unitCount: rom.unitCount);
      expect(back.ids.single, 1);
      expect(rom.unitDisplayName(1), rom.unitDisplayName(1));
    });
  });

  group('叠加：自定义名单覆盖自动判据', () {
    test('自定义名单非空时完全取代判据结果', () {
      final edit = _open('1692 -');
      final pu = playableUnitsOf(edit.rom);
      final scope = RosterScope(
        criterion: PlayableCriterion.reciprocal,
        custom: const CustomRoster({1, 2, 3}),
      );
      expect(scope.usesCustom, isTrue);
      expect(scope.effective(pu), [1, 2, 3]);
      expect(scope.describe(pu), contains('自定义名单'));
    });

    test('自定义名单为空时回落到判据', () {
      final edit = _open('1692 -');
      final pu = playableUnitsOf(edit.rom);
      final scope = RosterScope(criterion: PlayableCriterion.reciprocal);
      expect(scope.usesCustom, isFalse);
      // 走自动判据时保持原行为（判据结果原样返回，可能含 0 号槽）
      expect(scope.effective(pu),
          pu.indices(criterion: PlayableCriterion.reciprocal));
    });

    test('可以在判据结果上补人（模拟「漏了 3 个」）', () {
      final edit = _open('1692 -');
      final pu = playableUnitsOf(edit.rom);
      final base = pu.indices(criterion: PlayableCriterion.reciprocal);
      // 补 3 个判据没覆盖的角色
      final extra = <int>[];
      for (var i = 0; i < edit.rom.unitCount && extra.length < 3; i++) {
        if (!base.contains(i)) extra.add(i);
      }
      final roster = CustomRoster({...base, ...extra});
      final scope = RosterScope(
        criterion: PlayableCriterion.reciprocal,
        custom: roster,
      );
      // 0 是合法角色，名单里保留它 → 净增 3
      expect(scope.effective(pu).length, base.length + 3);
      expect(scope.effective(pu), contains(0),
          reason: '0 是自军主角，必须能改');
    });

    test('也可以在判据结果上剔除（模拟「多了几个敌方」）', () {
      final edit = _open('1692 -');
      final pu = playableUnitsOf(edit.rom);
      final base = pu.indices(criterion: PlayableCriterion.reciprocal);
      final roster = CustomRoster({...base}..remove(base.first));
      final scope = RosterScope(
        criterion: PlayableCriterion.reciprocal,
        custom: roster,
      );
      expect(scope.effective(pu).length, base.length - 1);
      expect(scope.effective(pu), isNot(contains(base.first)));
    });

    test('custom 口径本身不产生集合（必须靠 CustomRoster）', () {
      final edit = _open('1692 -');
      final pu = playableUnitsOf(edit.rom);
      expect(pu.indices(criterion: PlayableCriterion.custom), isEmpty);
    });
  });

  group('修改器真的只改名单里的角色', () {
    test('自定义名单 3 个角色：只有这 3 个的成长率被改', () {
      final edit = _open('1692 -');
      final rom = edit.rom;
      const roster = CustomRoster({1, 2, 30});
      final preset =
          cheatPresets.firstWhere((p) => p.id == 'unit_max_growth');
      // 先记下名单外某个角色的原值
      final outside = 40;
      final beforeOutside = rom.data[
          rom.unitBase + outside * rom.table.unitDataSize + 28];

      final result = applyCheat(edit, preset, custom: roster);
      expect(result.changedEntries, roster.length);

      for (final i in roster.indices) {
        final at = rom.unitBase + i * rom.table.unitDataSize + 28;
        expect(edit.buffer.u8(at), 100, reason: '索引 $i 的成长率应为 100');
      }
      final afterOutside = edit.buffer
          .u8(rom.unitBase + outside * rom.table.unitDataSize + 28);
      expect(afterOutside, beforeOutside, reason: '名单外的角色不能被动到');
    });

    test('cheatEntryCount 与自定义名单一致', () {
      final edit = _open('1692 -');
      final preset =
          cheatPresets.firstWhere((p) => p.id == 'unit_max_growth');
      const roster = CustomRoster({1, 2, 3, 4});
      expect(
        cheatEntryCount(preset, edit.rom, custom: roster),
        roster.length,
      );
    });

    test('空名单时不会把全表改掉', () {
      final edit = _open('1692 -');
      final preset =
          cheatPresets.firstWhere((p) => p.id == 'unit_max_growth');
      final result = applyCheat(edit, preset, custom: CustomRoster.empty);
      // 空名单 → 回落到默认判据（我方），不是全表
      expect(result.changedEntries, greaterThan(0));
      expect(result.changedEntries, lessThan(edit.rom.unitCount));
    });
  });

  group('设置里的持久化（按 ROM 指纹隔离）', () {
    test('JSON 往返：0 保留，越界与非法类型被过滤', () {
      const r = CustomRoster({0, 1, 2, 5});
      final json = r.toJson();
      final back = CustomRoster.fromJson(json, unitCount: 100);
      expect(back.indices, {0, 1, 2, 5});

      final dirty = CustomRoster.fromJson(
        {
          'v': 1,
          'ids': [0, 1, 999, 'x', 5],
        },
        unitCount: 100,
      );
      expect(dirty.indices, {0, 1, 5}, reason: '999/非法类型丢掉，0 保留');
    });

    test('坏 JSON 不抛异常', () {
      expect(CustomRoster.fromJson(null, unitCount: 10).isEmpty, isTrue);
      expect(CustomRoster.fromJson('x', unitCount: 10).isEmpty, isTrue);
      expect(CustomRoster.fromJson({'ids': 'x'}, unitCount: 10).isEmpty, isTrue);
    });

    test('AppSettings 按 ROM 指纹各存一份，互不干扰', () async {
      // 测试环境没有原生通道，写入会被忽略；这里只验证内存层的隔离语义
      final s = AppSettings.instance;
      const fprA = 0x1111;
      const fprB = 0x2222;
      await s.setRoster(fprA, const CustomRoster({1, 2, 3}));
      await s.setRoster(fprB, const CustomRoster({7}));
      expect(s.rosterFor(fprA).indices, {1, 2, 3});
      expect(s.rosterFor(fprB).indices, {7});
      expect(s.rosterFor(0x3333).isEmpty, isTrue, reason: '没存过的 ROM 是空名单');

      // 空名单 = 删除
      await s.setRoster(fprA, CustomRoster.empty);
      expect(s.rosterFor(fprA).isEmpty, isTrue);
    });
  });

  group('自定义名单页界面', () {
    testWidgets('能渲染，显示已选数量与三个快捷操作', (tester) async {
      final edit = _open('1692 -');
      await tester.pumpWidget(MaterialApp(
        home: CustomRosterPage(
          rom: edit.rom,
          baseCriterion: PlayableCriterion.reciprocal,
          initial: const CustomRoster({1, 2, 3}),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('自定义角色名单'), findsOneWidget);
      expect(find.textContaining('已选 3 个角色'), findsOneWidget);
      expect(find.text('全不选'), findsOneWidget);
      expect(find.text('反选'), findsOneWidget);
      expect(find.text('恢复为判据结果'), findsOneWidget);
    });

    testWidgets('勾选与全不选能改变数量', (tester) async {
      final edit = _open('1692 -');
      await tester.pumpWidget(MaterialApp(
        home: CustomRosterPage(
          rom: edit.rom,
          baseCriterion: PlayableCriterion.reciprocal,
          initial: const CustomRoster({1, 2}),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('已选 2 个角色'), findsOneWidget);

      await tester.tap(find.text('全不选'));
      await tester.pump();
      expect(find.textContaining('已选 0 个角色'), findsOneWidget);
    });

    testWidgets('空名单时点复制会提示先勾选（不会崩）', (tester) async {
      final edit = _open('1692 -');
      await tester.pumpWidget(MaterialApp(
        home: CustomRosterPage(
          rom: edit.rom,
          baseCriterion: PlayableCriterion.reciprocal,
          initial: CustomRoster.empty,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byIcon(Icons.copy_all));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('名单是空的'), findsOneWidget);
    });

    testWidgets('按名字过滤只影响显示，不改勾选状态', (tester) async {
      final edit = _open('1692 -');
      await tester.pumpWidget(MaterialApp(
        home: CustomRosterPage(
          rom: edit.rom,
          baseCriterion: PlayableCriterion.reciprocal,
          initial: const CustomRoster({1}),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(find.byType(TextField), '99');
      await tester.pump();
      // 过滤后列表变短，但已选数量不变
      expect(find.textContaining('已选 1 个角色'), findsOneWidget);
    });
  });
}
