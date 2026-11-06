import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/mcp_server.dart';
import 'package:fe_editor/core/rom_workspace.dart';

import 'rom_paths.dart';

const dir = romDir;
const fe6jp =
    '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe8jp =
    '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

/// 直接调 [McpServer.handleBody]，不起端口。
class Harness {
  final RomWorkspace ws = RomWorkspace();

  Future<dynamic> tool(String name,
      [Map<String, dynamic> args = const {}]) async {
    final out = await McpServer.instance.handleBody(jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': args},
    }));
    final resp = jsonDecode(out!) as Map<String, dynamic>;
    final result = resp['result'] as Map<String, dynamic>;
    if (result['isError'] == true) {
      final content = (result['content'] as List).first as Map;
      return {'__error': content['text']};
    }
    final content = (result['content'] as List).first as Map;
    final text = content['text'] as String;
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  }
}

void main() {
  group('MCP：职业地形表', () {
    test('get_class_terrain 返回六张表（FE8）与共享信息', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);

      final r = await h.tool('get_class_terrain', {'id': 1});
      expect(r['is_fe6'], isFalse);
      expect(r['terrain_count'], 65);
      final tables = (r['tables'] as List).cast<Map<String, dynamic>>();
      expect(tables.length, 6, reason: '移动 3 + 修正 3');
      expect(tables.map((t) => t['label']).toList(),
          containsAll(['移动消耗（晴）', '地形回避', '地形防御', '地形魔防']));
      for (final t in tables) {
        expect((t['values'] as List).length, 66, reason: '地形 0..65');
        expect(t['target'], greaterThan(0), reason: '指针应有效');
      }
    });

    test('get_class_terrain 只读单个地形时给 1 个值', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('get_class_terrain', {'id': 1, 'terrain': 5});
      final tables = (r['tables'] as List).cast<Map<String, dynamic>>();
      for (final t in tables) {
        expect((t['values'] as List).length, 1);
        expect(t['terrain'], 5);
      }
    });

    test('set_class_terrain 写入并回读一致', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);

      final before = await h.tool('get_class_terrain', {'id': 1, 'terrain': 5});
      final t0 = (before['tables'] as List)
          .firstWhere((t) => t['label'] == '地形回避') as Map<String, dynamic>;
      final old = (t0['values'] as List).first as int;
      final target = old == 7 ? 8 : 7;

      final w = await h.tool('set_class_terrain', {
        'id': 1,
        'table': 'avoid',
        'terrain': 5,
        'value': target,
      });
      expect(w['changed'], isTrue);
      expect(w['before'], old);
      expect(w['after'], target);
      expect(s!.rom.hasChanges, isTrue);

      final after = await h.tool('get_class_terrain', {'id': 1, 'terrain': 5});
      final t1 = (after['tables'] as List)
          .firstWhere((t) => t['label'] == '地形回避') as Map<String, dynamic>;
      expect((t1['values'] as List).first, target);
    });

    test('dry_run 不写盘', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('set_class_terrain', {
        'id': 1,
        'table': 'avoid',
        'terrain': 5,
        'value': 99,
        'dry_run': true,
      });
      expect(r['dry_run'], isTrue);
      expect(s!.rom.hasChanges, isFalse);
    });

    test('FE6 没有雨/雪移动表，且给出可用表名', () async {
      final h = Harness();
      await h.ws.open(File(fe6jp).readAsBytesSync(), '封印.gba');
      McpServer.instance.attach(h.ws);
      final ok = await h.tool('get_class_terrain', {'id': 1});
      expect(ok['is_fe6'], isTrue);
      expect((ok['tables'] as List).length, 4, reason: 'FE6 = 1 移动 + 3 修正');

      final bad = await h.tool(
          'set_class_terrain', {'id': 1, 'table': 'mov_rain', 'terrain': 1, 'value': 2});
      expect(bad['__error'], contains('FE6'));
      expect(bad['__error'], contains('mov_dry'));
    });

    test('地形 ID 越界与 value 越界都被拒绝', () async {
      final h = Harness();
      await h.ws.open(File(fe7jp).readAsBytesSync(), '烈火.gba');
      McpServer.instance.attach(h.ws);
      final a = await h.tool(
          'set_class_terrain', {'id': 1, 'table': 'avoid', 'terrain': 999, 'value': 1});
      expect(a['__error'], contains('越界'));
      final b = await h.tool(
          'set_class_terrain', {'id': 1, 'table': 'avoid', 'terrain': 1, 'value': 999});
      expect(b['__error'], contains('越界'));
      final c = await h.tool(
          'set_class_terrain', {'id': 1, 'table': '不存在', 'terrain': 1, 'value': 1});
      expect(c['__error'], contains('未知 table'));
    });
  });

  group('MCP：事件单位道具', () {
    test('set_chapter_event_unit 能改 items 与 class_id', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);

      // 找本章（第 0 章）一个事件单位
      final ev = await h.tool('list_chapter_events', {'chapter': 0});
      final events = (ev['events'] as List).cast<Map<String, dynamic>>();
      Map<String, dynamic>? unit;
      for (final e in events) {
        final us = (e['units'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        if (us.isNotEmpty) {
          unit = us.first;
          break;
        }
      }
      expect(unit, isNotNull, reason: 'FE8J 第 0 章应有剧情增援');
      final addr = unit!['addr'] as int;

      final w = await h.tool('set_chapter_event_unit', {
        'addr': addr,
        'items': [1, 2, 0, 0],
        'class_id': 3,
      });
      expect(w['changed_n'], greaterThan(0));
      expect(s!.rom.hasChanges, isTrue);

      // 回读：items 前两格应该是 1 和 2
      final again = await h.tool('list_chapter_events', {'chapter': 0});
      final evs = (again['events'] as List).cast<Map<String, dynamic>>();
      Map<String, dynamic>? re;
      for (final e in evs) {
        for (final u in (e['units'] as List? ?? [])) {
          final m = u as Map<String, dynamic>;
          if (m['addr'] == addr) re = m;
        }
      }
      expect(re, isNotNull);
      final items = (re!['items'] as List).cast<int>();
      expect(items[0], 1);
      expect(items[1], 2);
    });
  });
}
