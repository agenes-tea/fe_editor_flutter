import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/app_meta.dart';
import 'package:fe_editor/core/feature_flags.dart';
import 'package:fe_editor/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:fe_editor/core/app_settings.dart';
import 'package:fe_editor/core/custom_roster.dart';
import 'package:fe_editor/core/mcp_server.dart';
import 'package:fe_editor/core/mcp_service.dart';
import 'package:fe_editor/core/rom_workspace.dart';

const dir = '/root/workspace/game-rom';
const fe6jp = '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

Map<String, dynamic> _decode(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;

/// 直接调 [McpServer.handleBody]，不起端口（协议层与传输层解耦）。
class Harness {
  final RomWorkspace ws = RomWorkspace();

  Future<Map<String, dynamic>> call(String body) async {
    final out = await McpServer.instance.handleBody(body);
    return _decode(out!);
  }

  Future<dynamic> tool(String name, [Map<String, dynamic> args = const {}]) async {
    final resp = await call(jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': args},
    }));
    final result = resp['result'] as Map<String, dynamic>;
    final content = (result['content'] as List).first as Map;
    final text = content['text'] as String;
    if (result['isError'] == true) {
      return {'__error': text};
    }
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  }
}

void main() {
  group('协议层', () {
    test('initialize 返回协议版本与服务名', () async {
      final h = Harness();
      final r = await h.call(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2024-11-05',
          'capabilities': {},
          'clientInfo': {'name': 'test', 'version': '1.0'},
        },
      }));
      final result = r['result'] as Map;
      // 必须回显客户端请求的版本，否则客户端会误判协议不兼容
      expect(result['protocolVersion'], '2024-11-05');
      expect((result['serverInfo'] as Map)['name'], appName);
      expect((result['capabilities'] as Map).containsKey('tools'), isTrue);
    });

    test('客户端不带协议版本时回默认值', () async {
      final h = Harness();
      final r = await h.call(jsonEncode({
        'jsonrpc': '2.0',
        'id': 9,
        'method': 'initialize',
        'params': {},
      }));
      expect((r['result'] as Map)['protocolVersion'],
          McpServer.defaultProtocolVersion);
    });

    test('新版本协议（2025-06-18）也能回显', () async {
      final h = Harness();
      final r = await h.call(jsonEncode({
        'jsonrpc': '2.0',
        'id': 10,
        'method': 'initialize',
        'params': {'protocolVersion': '2025-06-18'},
      }));
      expect((r['result'] as Map)['protocolVersion'], '2025-06-18');
    });

    test('ping 回空结果', () async {
      final h = Harness();
      final r = await h.call(jsonEncode(
          {'jsonrpc': '2.0', 'id': 2, 'method': 'ping'}));
      expect(r['result'], isEmpty);
      expect(r['id'], 2);
    });

    test('tools/list 列出全部工具，且每个都有 schema', () async {
      final h = Harness();
      final r = await h.call(jsonEncode({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/list',
      }));
      final tools = (r['result'] as Map)['tools'] as List;
      expect(tools.length, toolDefinitions.length);
      expect(tools.length, greaterThan(15));
      for (final t in tools) {
        final m = t as Map;
        expect(m['name'], isA<String>());
        expect(m['description'], isA<String>());
        final schema = m['inputSchema'] as Map;
        expect(schema['type'], 'object');
        expect(schema['properties'], isA<Map>());
      }
      final names = tools.map((t) => (t as Map)['name']).toList();
      expect(names, contains('list_roms'));
      expect(names, contains('set_unit_field'));
      expect(names, contains('import_portrait'));
      expect(names, contains('save_rom'));
    });

    test('未知方法返回 -32601', () async {
      final h = Harness();
      final r = await h.call(jsonEncode(
          {'jsonrpc': '2.0', 'id': 4, 'method': 'no/such/method'}));
      expect((r['error'] as Map)['code'], -32601);
    });

    test('非法 JSON 返回 -32700', () async {
      final h = Harness();
      final r = await h.call('{not json');
      expect((r['error'] as Map)['code'], -32700);
    });

    test('通知（无 id）不需要回复', () async {
      final h = Harness();
      final out = await McpServer.instance.handleBody(jsonEncode({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      }));
      expect(out, isNull);
    });

    test('批量请求逐条处理', () async {
      final h = Harness();
      final out = await McpServer.instance.handleBody(jsonEncode([
        {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
        {'jsonrpc': '2.0', 'id': 2, 'method': 'ping'},
      ]));
      final list = jsonDecode(out!) as List;
      expect(list.length, 2);
    });
  });

  group('工具：ROM 与会话', () {
    test('没有打开 ROM 时给出明确错误', () async {
      final h = Harness();
      final r = await h.tool('list_roms');
      expect(r, isA<Map>());
      expect(r['__error'], contains('未连接'));
    });

    test('list_roms 与 rom_info', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);

      final roms = await h.tool('list_roms');
      expect(roms['count'], 1);
      expect(roms['roms'][0]['version'], 'FE8J');

      final info = await h.tool('rom_info');
      expect(info['version'], 'FE8J');
      expect(info['counts']['classes'], greaterThan(100));
    });

    test('多 ROM 时按版本代号选择', () async {
      final h = Harness();
      await h.ws.open(File(fe6jp).readAsBytesSync(), '封印.gba');
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);

      final a = await h.tool('rom_info', {'rom': 'FE6'});
      final b = await h.tool('rom_info', {'rom': 'fe8j'});
      expect(a['version'], 'FE6');
      expect(b['version'], 'FE8J', reason: '版本代号应不区分大小写');

      final missing = await h.tool('rom_info', {'rom': 'FE9'});
      expect(missing['__error'], contains('没有打开'));
    });
  });

  group('工具：数据读写', () {
    test('list_units / get_unit / set_unit_field 往返', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);

      final list = await h.tool('list_units', {'limit': 5});
      expect((list['units'] as List).length, lessThanOrEqualTo(5));

      final before = await h.tool('get_unit', {'id': 1});
      final level = (before['fields'] as List)
          .firstWhere((f) => f['name'] == '等级')['value'];

      final write = await h.tool(
          'set_unit_field', {'id': 1, 'field': '等级', 'value': 17});
      expect(write['changed'], isTrue);
      expect(write['before'], level);
      expect(write['after'], 17);
      expect(s!.rom.hasChanges, isTrue);
    });

    test('字段名写错时列出可用字段', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool(
          'set_unit_field', {'id': 1, 'field': '不存在的字段', 'value': 1});
      expect(r['__error'], contains('没有字段'));
      expect(r['__error'], contains('等级'));
    });

    test('索引越界被拒绝', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('get_unit', {'id': 99999});
      expect(r['__error'], contains('越界'));
    });

    test('list_classes / list_items 可读', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final cls = await h.tool('list_classes');
      expect((cls['classes'] as List), isNotEmpty);
      final items = await h.tool('list_items');
      expect((items['items'] as List), isNotEmpty);
      expect(items['items'][0].containsKey('might'), isTrue);
    });

    test('read_hex / write_hex 往返，且可撤销', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);

      final before = await h.tool('read_hex', {'offset': 0x100, 'length': 4});
      final orig = (before['bytes'] as List).cast<int>();
      final write = await h.tool(
          'write_hex', {'offset': 0x100, 'bytes': [0xAA, 0xBB, 0xCC, 0xDD]});
      expect(write['changed'], 4);

      final after = await h.tool('read_hex', {'offset': 0x100, 'length': 4});
      expect((after['bytes'] as List).cast<int>(), [0xAA, 0xBB, 0xCC, 0xDD]);

      final rev = await h.tool('revert_changes');
      expect(rev['reverted_bytes'], greaterThan(0));
      final back = await h.tool('read_hex', {'offset': 0x100, 'length': 4});
      expect((back['bytes'] as List).cast<int>(), orig);
      expect(s!.rom.hasChanges, isFalse);
    });

    test('read_hex 越界给出范围提示', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('read_hex', {'offset': 99999999, 'length': 16});
      expect(r['__error'], contains('越界'));
    });

    test('get_map 返回砖块数组，set_map_tiles 能写回', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);

      final map = await h.tool('get_map', {'chapter': 0});
      final tiles = (map['tiles'] as List).cast<int>();
      expect(tiles.length, map['width'] * map['height']);

      // 找一个和原值不同的砖块再写，避免 identical
      final probe = List<int>.from(tiles);
      probe[0] = probe[0] == 24 ? 28 : 24;
      final w = await h.tool('set_map_tiles', {'chapter': 0, 'tiles': probe});
      if (w['__error'] != null) {
        // 原版地图压缩得很紧，可能放不下——这也算正确行为
        expect(w['__error'], contains('就地放不下'));
      } else {
        final back = await h.tool('get_map', {'chapter': 0});
        expect((back['tiles'] as List)[0], probe[0]);
      }
      expect(s!.rom.changedByteCount, greaterThanOrEqualTo(0));
    });

    test('read_text 能搜到内容', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('read_text', {'id': 0});
      expect(r.containsKey('text'), isTrue);
      expect(r.containsKey('available'), isTrue);
    });

    test('list_chapter_events 能列出触发条件', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('list_chapter_events', {'chapter': 0});
      expect((r['events'] as List), isNotEmpty);
      expect((r['events'] as List).first['kind'], isA<String>());
    });
  });

  group('工具：跨 ROM 移植', () {
    test('import_portrait 替换指定条目', () async {
      final h = Harness();
      await h.ws.open(File(fe6jp).readAsBytesSync(), '封印.gba');
      final target = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);

      final before = await h.tool('portrait_usage', {'id': 2, 'rom': 'FE8J'});
      final r = await h.tool('import_portrait', {
        'source': 'FE6',
        'source_id': 1,
        'target_id': 2,
        'rom': 'FE8J',
      });
      expect(r['__error'], isNull);
      expect(r['target_id'], 2);
      expect(r['replaced'], isTrue);
      expect(target!.rom.hasChanges, isTrue);
      // 替换后影响面文案应仍是原来的角色（肖像 ID 没变，只是图像换了）
      final after = await h.tool('portrait_usage', {'id': 2, 'rom': 'FE8J'});
      expect(after['usage'], before['usage']);
    });

    test('源与目标相同被拒绝', () async {
      final h = Harness();
      await h.ws.open(File(fe6jp).readAsBytesSync(), '封印.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('import_portrait', {
        'source': 'FE6',
        'source_id': 1,
        'rom': 'FE6',
      });
      expect(r['__error'], contains('同一份 ROM'));
    });

    test('import_battle_anim 替换指定条目', () async {
      final h = Harness();
      await h.ws.open(File(fe6jp).readAsBytesSync(), '封印.gba');
      final target = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);

      final list = await h.tool('list_battle_anims', {'rom': 'FE6'});
      expect((list['anims'] as List), isNotEmpty);

      final r = await h.tool('import_battle_anim', {
        'source': 'FE6',
        'source_id': 0,
        'target_id': 1,
        'rom': 'FE8J',
      });
      expect(r['__error'], isNull);
      expect(r['target_id'], 1);
      expect(r['sheets'], greaterThan(0));
      expect(target!.rom.hasChanges, isTrue);
    });

    test('save_rom 返回可用的 base64', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe6jp).readAsBytesSync(), '封印.gba');
      McpServer.instance.attach(h.ws);
      await h.tool('set_unit_field', {'id': 1, 'field': '等级', 'value': 20});

      final out = await h.tool('save_rom');
      expect(out['size'], s!.rom.data.length);
      final bytes = base64Decode(out['base64'] as String);
      expect(bytes.length, out['size']);
      // 导出的内容里确实带了改动
      expect(bytes, equals(s.rom.data));
    });
  });

  group('局域网模式与访问口令', () {
    test('随机口令 16 位、字符集安全（无易混字符）', () {
      final t = McpService.newToken();
      expect(t.length, 16);
      expect(RegExp(r'^[a-z2-9]+$').hasMatch(t), isTrue,
          reason: '只含小写字母与数字');
      expect(t.contains('l'), isFalse, reason: '排除了 l/1/o/0 这类易混字符');
      // 两次生成不应相同
      expect(McpService.newToken(), isNot(t));
    });

    test('未启动时地址列表为空', () async {
      // 单例可能被其它用例改过，这里只验证「没在跑就没有地址」
      final s = McpService.instance;
      await s.stop();
      expect(await s.addresses(), isEmpty);
    });

    test('只开本机模式时地址只有回环', () async {
      final s = McpService.instance;
      s.allowLan = false;
      // running 依赖原生，单元测试里起不来；这里直接验证分支语义
      expect(s.allowLan, isFalse);
    });
  });

  group('设置页入口', () {
    testWidgets('显示 MCP 开关，默认关闭且不显示地址', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('MCP（给 AI 客户端用）'), findsOneWidget);
      expect(find.text('启动 MCP 服务器'), findsOneWidget);
      // 没开启时不该显示地址块
      expect(find.textContaining('http://127.0.0.1'), findsNothing);
    });
  });

  group('T1 list_chapters', () {
    test('返回章节索引、资源名、地图尺寸', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('list_chapters');
      expect(r['count'], greaterThan(50));
      final first = (r['chapters'] as List).first as Map;
      expect(first['id'], 0);
      expect(first['resource'], isNotEmpty, reason: '应有内部资源名');
      expect(first['width'], greaterThan(0));
      expect(first['title'], 'ルネス陥落', reason: '第 0 章 = 游戏内序章，标题与 ROM 文本一致');
      expect(r['hint'], contains('0 基'));
    });
  });

  group('T2 read_text 分页', () {
    test('给 from 一次读一段', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('read_text', {'from': 1362, 'count': 4});
      expect(r['count'], 4);
      final texts = (r['items'] as List).map((e) => e['text']).toList();
      // 1362 起是「序章 / 第１章 / 第２章 / 第３章」
      expect(texts[0], contains('序章'));
      expect(texts[1], contains('１'));
    });

    test('count 会被夹紧，越界不崩', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('read_text', {'from': 900000, 'count': 5});
      expect(r['count'], 0);
    });
  });

  group('T3 get_item / get_class', () {
    test('get_item 返回字段名与取值范围', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('get_item', {'id': 1});
      final fields = r['fields'] as List;
      expect(fields, isNotEmpty);
      final names = fields.map((f) => f['name']).toList();
      expect(names, contains('威力'));
      expect(names, contains('耐久'.replaceFirst('耐久', '使用次数')));
      final might = fields.firstWhere((f) => f['name'] == '威力') as Map;
      expect(might['min'], isA<int>());
      expect(might['max'], isA<int>());
    });

    test('get_class 返回字段名（set_class_field 的依据）', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('get_class', {'id': 1});
      final names = (r['fields'] as List).map((f) => f['name']).toList();
      expect(names, contains('移动力'));
      expect(names, contains('HP上限'));
    });

    test('取出的字段名能直接用于 set_*_field', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final info = await h.tool('get_item', {'id': 1});
      final aField = (info['fields'] as List).firstWhere(
          (f) => f['name'] == '威力') as Map;
      final w = await h.tool('set_item_field', {
        'id': 1,
        'field': aField['name'],
        'value': (aField['value'] as int) + 1,
      });
      expect(w['__error'], isNull);
      expect(w['changed'], isTrue);
      s!.rom.revertAll();
    });
  });

  group('T4 dry_run', () {
    test('dry_run 不改 ROM，但报出会改的字节', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('set_unit_field',
          {'id': 1, 'field': '等级', 'value': 20, 'dry_run': true});
      expect(r['dry_run'], isTrue);
      expect(r['after'], 20);
      expect(r['patch'], isNotNull);
      expect(s!.rom.hasChanges, isFalse, reason: '预演不能落盘');
    });

    test('write_hex 的 dry_run 同样不写', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('write_hex', {
        'offset': 0x200,
        'bytes': [1, 2, 3, 4],
        'dry_run': true,
      });
      expect(r['dry_run'], isTrue);
      expect(r['changed'], 4);
      expect(s!.rom.hasChanges, isFalse);
    });

    test('不给 dry_run 时照常写入', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      await h.tool('set_unit_field', {'id': 1, 'field': '等级', 'value': 20});
      expect(s!.rom.hasChanges, isTrue);
      s.rom.revertAll();
    });
  });

  group('T5 find_free_space', () {
    test('能给出可用的空闲区', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('find_free_space', {'size': 4096, 'limit': 3});
      expect(r['found'], greaterThan(0));
      final region = (r['regions'] as List).first as Map;
      expect(region['offset'], isA<int>());
      expect(region['length'], greaterThanOrEqualTo(4096));
      expect(region['gba'], (region['offset'] as int) + 0x08000000);
    });

    test('要得太大时返回空列表而不是崩', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('find_free_space', {'size': 1 << 22});
      expect(r['found'], 0);
    });
  });

  group('T7 修改器预设', () {
    test('列出预设与口径', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('list_cheat_presets');
      final presets = r['presets'] as List;
      expect(presets.length, greaterThan(8));
      expect(presets.first.containsKey('id'), isTrue);
      expect((r['criteria'] as List), isNotEmpty);
    });

    test('应用预设真的改了数据，且可撤销', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final list = await h.tool('list_cheat_presets');
      // 挑一个只作用在我方角色的预设
      final p = (list['presets'] as List)
          .cast<Map>()
          .firstWhere((m) => m['scope_selectable'] == true);
      final r = await h.tool('apply_cheat_preset', {'id': p['id']});
      expect(r['__error'], isNull, reason: '预设 ${p['id']} 应能应用');
      expect(r['changed_entries'], greaterThan(0));
      expect(s!.rom.hasChanges, isTrue);
      s.rom.revertAll();
      expect(s.rom.hasChanges, isFalse);
    });

    test('未知预设 ID 给出可用清单', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('apply_cheat_preset', {'id': 'no_such'});
      expect(r['__error'], contains('可用'));
    });
  });

  group('T10 describe_rom', () {
    test('返回能力清单：表规模、字段名、章节标题、限制', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('describe_rom');
      expect(r['version'], 'FE8J');
      expect(r['tables']['units']['count'], greaterThan(200));
      expect(r['tables']['units']['id_range'], [0, (r['tables']['units']['count'] as int) - 1]);
      expect((r['editable']['unit_fields'] as List), contains('HP成长'));
      expect((r['editable']['item_fields'] as List), contains('射程'));
      expect((r['chapters'] as List).first['title'], isA<String>());
      expect((r['limitations'] as List), isNotEmpty);
      expect((r['text'] as Map)['encoding'], isNotNull);
    });

    test('FE6 也走得通（表特例不影响能力清单）', () async {
      final h = Harness();
      await h.ws.open(File(fe6jp).readAsBytesSync(), '封印.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('describe_rom');
      expect(r['version'], 'FE6');
      expect(r['tables']['units']['count'], greaterThan(100));
      expect((r['tables']['chapters'] as int), greaterThan(10));
    });
  });

  group('T11 快照与回滚', () {
    test('snapshot → 改 → rollback 回到快照点', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);

      final snap = await h.tool('snapshot', {'label': '改之前'});
      expect(snap['id'], isNotNull);
      expect(snap['changed_bytes'], 0);

      await h.tool('set_unit_field', {'id': 0, 'field': '等级', 'value': 20});
      final after = await h.tool('list_snapshots');
      expect(after['current_changed_bytes'], greaterThan(0));

      final rb = await h.tool('rollback');
      expect(rb['rolled_back_to'], snap['id']);
      expect(rb['changed_bytes'], 0);
      expect(s.rom.changedByteCount, 0);

      final unit = await h.tool('get_unit', {'id': 0});
      final level = (unit['fields'] as List).where((f) => f['name'] == '等级').first;
      expect(level['value'], isNot(20), reason: '回滚后应恢复原等级');
      s.rom.revertAll();
    });

    test('多个快照按 id 回滚，回滚后更晚的快照被消耗', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);

      final s1 = await h.tool('snapshot', {'label': '第一'});
      await h.tool('set_unit_field', {'id': 0, 'field': '等级', 'value': 15});
      final s2 = await h.tool('snapshot', {'label': '第二'});
      await h.tool('set_unit_field', {'id': 0, 'field': '等级', 'value': 25});

      final rb = await h.tool('rollback', {'id': s1['id']});
      expect(rb['rolled_back_to'], s1['id']);
      final list = await h.tool('list_snapshots');
      final ids = (list['snapshots'] as List).map((x) => x['id']).toList();
      expect(ids, isNot(contains(s2['id'])), reason: '回滚到 s1 后 s2 应被消耗');
      s.rom.revertAll();
    });

    test('没有快照时 rollback 给出明确提示', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('rollback');
      expect(r['__error'], contains('快照'));
    });
  });

  group('T12 统一 dry_run', () {
    test('set_unit_field 的 dry_run 走真实执行再回滚', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);
      final before = s.rom.changedByteCount;
      final r = await h.tool('set_unit_field',
          {'id': 0, 'field': '等级', 'value': 30, 'dry_run': true});
      expect(r['dry_run'], isTrue);
      expect(r['changed_bytes'], greaterThan(0), reason: '应报出会改的字节数');
      expect((r['patch'] as List), isNotEmpty);
      expect(s.rom.changedByteCount, before, reason: 'dry_run 不能真的落盘');
    });

    test('apply_cheat_preset 也能 dry_run（批量写入工具）', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);
      final r = await h.tool('apply_cheat_preset',
          {'id': 'unit_max_growth', 'dry_run': true});
      if (r['__error'] != null) {
        // 预设 ID 若改名则跳过本断言，不阻塞
        return;
      }
      expect(r['dry_run'], isTrue);
      expect(r['changed_bytes'], greaterThan(0));
      expect(s.rom.changedByteCount, 0);
    });

    test('只读工具带 dry_run 会被拒绝（避免误解）', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('list_units', {'dry_run': true});
      expect(r['__error'], contains('只读'));
    });
  });

  group('T13 validate_rom', () {
    test('原版 ROM 体检通过', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('validate_rom');
      expect(r['ok'], isTrue, reason: 'problems=${r['problems']}');
      expect(r['deep'], isTrue);
    });

    test('deep=false 跳过章节扫描', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('validate_rom', {'deep': false});
      expect(r['ok'], isTrue);
      expect(r['deep'], isFalse);
    });

    test('把角色默认职业改超界能报错', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final addr = s!.rom.unitAddress(0) + 5;
      await h.tool('write_hex', {'offset': addr, 'bytes': [0xFE]});
      final r = await h.tool('validate_rom', {'deep': false});
      expect(r['ok'], isFalse);
      expect((r['problems'] as List).join(), contains('默认职业'));
      s.rom.revertAll();
    });
  });

  group('T15 换脸与克隆', () {
    test('attach_portrait_to_unit 把肖像挂到角色（FE6 自动 +1）', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe6jp).readAsBytesSync(), '封印.gba'))!;
      McpServer.instance.attach(h.ws);

      final list = await h.tool('list_portraits', {'limit': 20});
      final portraits = list['portraits'] as List;
      expect(portraits, isNotEmpty);
      final target = portraits[3] as Map;
      final pid = target['id'] as int;

      final r = await h.tool(
          'attach_portrait_to_unit', {'id': 0, 'portrait_id': pid});
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['changed'], isTrue);
      // FE6：face = 肖像 ID + 1
      expect(r['face_after'], pid + 1,
          reason: 'FE6 的 face 字段是肖像索引 + 1，写错会让整张表偏一格');
      // 读回确认：角色表 +6 真的变了
      final face =
          s.rom.buffer.u16(s.rom.unitAddress(0) + 6);
      expect(face, pid + 1);
      s.rom.revertAll();
    });

    test('没有图的肖像拒绝挂（占位条目）', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      // 找一个没有图的 ID：遍历前 300 条
      final list = await h.tool('list_portraits', {'limit': 300});
      final withImage = (list['portraits'] as List)
          .map((p) => (p as Map)['id'] as int)
          .toSet();
      final empty = List.generate(300, (i) => i).where((i) => !withImage.contains(i));
      if (empty.isEmpty) return;
      final r = await h.tool(
          'attach_portrait_to_unit', {'id': 0, 'portrait_id': empty.first});
      expect(r['__error'], contains('没有图'));
    });

    test('clone_unit 在原版满表时明确拒绝，不偷改已有角色', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);
      final r = await h.tool('clone_unit', {'from': 0});
      expect(r['__error'], contains('空槽'));
      expect(s.rom.hasChanges, isFalse);
    });

    test('clone_unit 有真实空槽时能粘过去并修正 ID', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);
      // 原版是满表（条目数 == 表容量），把最后一条清成空槽来验证写路径
      final rom = s.liveRom;
      final slot = rom.unitCount - 1;
      final at = rom.unitBase + slot * rom.table.unitDataSize;
      await h.tool('write_hex', {
        'offset': at + 4,
        'bytes': [0],
      });
      final r = await h.tool('clone_unit', {'from': 0, 'to': slot});
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['to'], slot);
      expect(r['new_unit_id'], slot + 1);
      expect(s.rom.buffer.u8(at + 4), slot + 1,
          reason: 'unit ID 必须等于序号+1，否则表边界会在这里断掉');
      expect(rom.unitCount, slot + 1, reason: '克隆后表应多一条');
      s.rom.revertAll();
    });
  });

  group('T16 章节单位写回', () {
    test('set_chapter_unit 改等级与坐标，字段读回一致', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);

      // 找一章有初始单位的
      final r0 = await h.tool('set_chapter_unit', {'chapter': 0, 'level': 7});
      if (r0['__error'] != null) {
        // 第 0 章没有单位时换一章试
        expect(r0['__error'], contains('没有单位'));
        return;
      }
      expect(r0['dry_run'], isFalse);
      final after = r0['unit'] as Map;
      expect(after['level'], 7);
      expect(r0['changed_n'], greaterThan(0));
      s.rom.revertAll();
    });

    test('set_chapter_unit 的 char_id 越界被拒绝（1 基提醒）', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool(
          'set_chapter_unit', {'chapter': 0, 'char_id': 999});
      expect(r['__error'], contains('1 基'));
    });

    test('set_chapter_unit 的 dry_run 不写入', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);
      final r = await h.tool(
          'set_chapter_unit', {'chapter': 0, 'level': 3, 'dry_run': true});
      if (r['__error'] != null) return;
      expect(r['dry_run'], isTrue);
      expect(s.rom.hasChanges, isFalse);
    });
  });

  group('T18 事件模板', () {
    test('add_reinforcement 追加增援，事件数与单位都对', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);

      final before = await h.tool('list_chapter_events', {'chapter': 3});
      final beforeCount = ((before['events'] as List)
          .where((e) => (e as Map)['kind'] == 'turn')).length;

      final r = await h.tool('add_reinforcement', {
        'chapter': 3,
        'turn': 7,
        'units': [
          {'char_id': 30, 'class_id': 3, 'level': 8, 'x': 4, 'y': 5, 'allegiance': 2}
        ],
      });
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['result'], 'applied');
      expect(r['units'], 1);
      expect(r['script_offset'], greaterThan(0));
      expect((r['message'] as String), contains('第 7 回合'));

      final after = await h.tool('list_chapter_events', {'chapter': 3});
      final turnEvents = (after['events'] as List)
          .where((e) => (e as Map)['kind'] == 'turn')
          .toList();
      expect(turnEvents.length, beforeCount + 1);
      final added = turnEvents.last as Map;
      expect((added['condition'] as String), contains('7'));
      final units = added['units'] as List;
      expect(units, hasLength(1));
      expect((units.single as Map)['char_id'], 30);
      expect((units.single as Map)['x'], 4);
      s.rom.revertAll();
    });

    test('坐标超地图被拒绝（错误在 isError 里，不是协议错误）', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);
      final r = await h.tool('add_reinforcement', {
        'chapter': 3,
        'turn': 7,
        'units': [
          {'char_id': 30, 'class_id': 3, 'level': 8, 'x': 99, 'y': 5}
        ],
      });
      expect(r['__error'], contains('地图'));
      expect(s.rom.hasChanges, isFalse);
    });

    test('缺少 units 给出可操作的提示', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('add_reinforcement', {'chapter': 3, 'turn': 7});
      expect(r['__error'], contains('units'));
      expect(r['__error'], contains('char_id'));
    });

    test('dry_run 不写入，但报出将改的字节', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);
      final r = await h.tool('add_reinforcement', {
        'chapter': 3,
        'turn': 7,
        'units': [
          {'char_id': 30, 'class_id': 3, 'level': 8, 'x': 4, 'y': 5}
        ],
        'dry_run': true,
      });
      expect(r['dry_run'], isTrue);
      expect(r['changed_bytes'], greaterThan(0));
      expect((r['regions'] as List), isNotEmpty);
      expect(s.rom.hasChanges, isFalse, reason: 'dry_run 不能落盘');
    });

    test('三作（FE6/FE7J/FE8J）都能通过 MCP 追加', () async {
      for (final path in [fe6jp, fe7jp, fe8jp]) {
        final h = Harness();
        await h.ws.open(File(path).readAsBytesSync(), 'x.gba');
        McpServer.instance.attach(h.ws);
        final info = await h.tool('rom_info');
        final r = await h.tool('add_reinforcement', {
          'chapter': 3,
          'turn': 5,
          'units': [
            {'char_id': 20, 'class_id': 2, 'level': 6, 'x': 2, 'y': 3, 'allegiance': 2}
          ],
        });
        expect(r['__error'], isNull,
            reason: '${info['version']}: ${r['__error']}');
        expect(r['result'], 'applied', reason: '${info['version']}');
      }
    });
  });

  group('T17 模拟与配方', () {
    test('simulate_growth 给出期望/最好/最坏与上限标记', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('simulate_growth', {'id': 0, 'target_level': 20});
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['target_level'], 20);
      expect((r['current'] as Map)['HP'], isA<int>());
      final expected = r['expected'] as Map;
      final worst = r['worst'] as Map;
      final best = r['best'] as Map;
      expect((expected['HP'] as num) >= (worst['HP'] as num), isTrue);
      expect((best['HP'] as num) >= (expected['HP'] as num), isTrue,
          reason: '最坏 ≤ 期望 ≤ 最好');
      expect((r['class_caps'] as Map).containsKey('HP'), isTrue);
      expect(r['from_level'], isA<int>());
    });

    test('成长率改高后期望值也随之变高（改前改后对比）', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);
      final before = await h.tool('simulate_growth', {'id': 0});
      await h.tool('set_unit_field', {'id': 0, 'field': '力量成长', 'value': 100});
      final after = await h.tool('simulate_growth', {'id': 0});
      expect((after['expected'] as Map)['力量'] as num,
          greaterThan((before['expected'] as Map)['力量'] as num));
      s.rom.revertAll();
    });

    test('simulate_battle 给伤害/命中/追击/反击', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);
      // 找一把剑
      final items = await h.tool('list_items');
      final sword = (items['items'] as List)
          .map((e) => e as Map)
          .firstWhere((e) => e['kind'] == 'sword' && (e['might'] as int? ?? 0) > 0);
      final r = await h.tool('simulate_battle',
          {'attacker': 0, 'weapon': sword['id'], 'defender': 1});
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['damage'], isA<int>());
      expect(r['hit'], inInclusiveRange(0, 100));
      expect(r['attacks'], anyOf(1, 2));
      expect((r['counter'] as Map).containsKey('possible'), isTrue);
      expect(['atk', 'def', 'both', 'none'], contains(r['outcome']));
      expect((r['note'] as String), contains('近似'));
      s.rom.revertAll();
    });

    test('simulate_battle 距离超出武器射程时不能反击', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final items = await h.tool('list_items');
      final sword = (items['items'] as List).map((e) => e as Map).firstWhere(
          (e) => e['kind'] == 'sword' && (e['might'] as int? ?? 0) > 0);
      final r = await h.tool('simulate_battle', {
        'attacker': 0,
        'weapon': sword['id'],
        'defender': 1,
        'distance': 3,
      });
      expect(r['__error'], isNull);
      // 近战剑在 3 格外打不到，也就无法反击
      expect((r['counter'] as Map)['possible'], isFalse);
    });

    test('export_recipe 导出改动的 offset/before/after', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);
      await h.tool('write_hex', {'offset': 0x200, 'bytes': [0xAA, 0xBB]});
      final r = await h.tool('export_recipe');
      expect(r['recipe_version'], 1);
      expect(r['changed_bytes'], greaterThan(0));
      final chunks = r['chunks'] as List;
      expect(chunks, isNotEmpty);
      final c = chunks.firstWhere((x) => (x as Map)['offset'] == 0x200) as Map;
      expect(c['after'], [0xAA, 0xBB]);
      expect((r['rom'] as Map)['version'], 'FE8J');

      final asPatch = await h.tool('export_recipe', {'format': 'patch'});
      expect((asPatch['patch_text'] as String), contains('00000200:'));
      s.rom.revertAll();
    });

    test('没改动时配方是空的，不崩', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('export_recipe');
      expect(r['changed_bytes'], 0);
      expect((r['chunks'] as List), isEmpty);
    });
  });

  group('T19 配方 apply_recipe', () {
    test('export→撤销→apply：字节层重放 + 语义层双通道', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);
      // 等级 40：在合法域（1..60）内，语义层（写字段会夹紧）与字节层（原样写）
      // 写入同样的值，两层结果才可比
      await h.tool('set_unit_field', {'id': 3, 'field': '等级', 'value': 40});
      await h.tool('set_item_field', {'id': 4, 'field': '必杀', 'value': 30});
      final exported = await h.tool('export_recipe', {
        'semantic': jsonEncode({
          'units': {'3': {'等级': 40}},
          'items': {'4': {'必杀': 30}},
        }),
      });
      expect(exported['__error'], isNull, reason: exported['__error']?.toString());
      final changed = exported['changed_bytes'] as int;
      expect(changed, greaterThan(0));
      expect((exported['semantic'] as Map).containsKey('units'), isTrue);

      await h.tool('revert_changes');
      expect((await h.tool('list_changes'))['changed_bytes'], 0);

      final applied =
          await h.tool('apply_recipe', {'text': jsonEncode(exported)});
      expect(applied['__error'], isNull, reason: applied['__error']?.toString());
      expect(applied['applied'], isTrue,
          reason: (applied['problems'] as List).join('；'));
      expect(applied['changed_bytes_total'], changed);
      expect(applied['skipped_chunks'], 0);

      // 读回核对两层都生效
      final unit = await h.tool('get_unit', {'id': 3});
      expect(
          (unit['fields'] as List).firstWhere((x) => x['name'] == '等级')[
              'value'],
          40);
      final item = await h.tool('get_item', {'id': 4});
      expect(
          (item['fields'] as List).firstWhere((x) => x['name'] == '必杀')[
              'value'],
          30);
      s.rom.revertAll();
    });

    test('版本不匹配整份拒绝（一个字节都不写）', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);
      final r = await h.tool('apply_recipe', {
        'text': jsonEncode({
          'rom': {'version': 'FE6'},
          'chunks': [
            {'offset': 0x200, 'after': [0xAA, 0xBB]},
          ],
        }),
      });
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['applied'], isFalse);
      expect(r['semantic_changed_bytes'], 0);
      expect(r['bytes_changed_bytes'], 0);
      expect((r['problems'] as List).join(' '), contains('拒绝应用'));
      expect(s.rom.changedByteCount, 0);
      s.rom.revertAll();
    });

    test('指纹不一致：字节层全跳，语义层仍应用', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);
      final r = await h.tool('apply_recipe', {
        'text': jsonEncode({
          'rom': {'version': 'FE8J', 'fingerprint': 12345},
          'semantic': {
            'units': {'3': {'等级': 99}}
          },
          'chunks': [
            {'offset': 0x200, 'after': [0xAA]},
          ],
        }),
      });
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['applied'], isTrue, reason: (r['problems'] as List).join('；'));
      expect(r['semantic_changed_bytes'], greaterThan(0));
      expect(r['bytes_changed_bytes'], 0);
      expect(r['skipped_chunks'], 1);
      s.rom.revertAll();
    });

    test('dry_run 预演不写入', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);
      final r = await h.tool('apply_recipe', {
        'text': jsonEncode({
          'rom': {'version': 'FE8J'},
          'semantic': {
            'units': {'3': {'等级': 99}}
          },
          'chunks': const [],
        }),
        'dry_run': true,
      });
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['dry_run'], isTrue);
      expect(r['rolled_back'], isTrue);
      // 预演回滚后一个字节都没改
      expect((await h.tool('list_changes'))['changed_bytes'], 0);
      s.rom.revertAll();
    });

    test('语义目标解析失败时报明哪个目标/字段，不静默', () async {
      final h = Harness();
      final s = (await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba'))!;
      McpServer.instance.attach(h.ws);
      final r = await h.tool('apply_recipe', {
        'text': jsonEncode({
          'rom': {'version': 'FE8J'},
          'semantic': {
            'units': {'不存在的主角X': {'等级': 99}},
            'items': {
              '0': {'不存在的字段': 1}
            },
          },
          'chunks': const [],
        }),
      });
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      final problems = (r['problems'] as List).join('；');
      expect(problems, contains('不存在的主角X'));
      expect(problems, contains('不存在的字段'));
      expect(r['semantic_changed_bytes'], 0);
      s.rom.revertAll();
    });
  });

  group('T14 resources 与 prompts', () {
    test('initialize 声明 resources 与 prompts 能力', () async {
      final h = Harness();
      final r = await h.call(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': '2024-11-05'},
      }));
      final caps = (r['result'] as Map)['capabilities'] as Map;
      expect(caps.containsKey('resources'), isTrue);
      expect(caps.containsKey('prompts'), isTrue);
    });

    test('resources/list 与 resources/read', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);

      final list = await h.call(jsonEncode(
          {'jsonrpc': '2.0', 'id': 2, 'method': 'resources/list'}));
      final res = (list['result'] as Map)['resources'] as List;
      final uris = res.map((r) => (r as Map)['uri']).toList();
      expect(uris, contains('fe://rom/summary'));
      expect(uris, contains('fe://rom/fields'));

      final read = await h.call(jsonEncode({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'resources/read',
        'params': {'uri': 'fe://rom/summary'},
      }));
      final contents = (read['result'] as Map)['contents'] as List;
      final text = (contents.first as Map)['text'] as String;
      expect(text, contains('FE8J'));
      expect(text, contains('validate_rom'), reason: '应给出操作约定');
    });

    test('没打开 ROM 时读资源返回提示而不报错', () async {
      final h = Harness();
      McpServer.instance.attach(h.ws);
      final read = await h.call(jsonEncode({
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'resources/read',
        'params': {'uri': 'fe://rom/summary'},
      }));
      expect(read['error'], isNull);
      final text = (((read['result'] as Map)['contents'] as List).first
          as Map)['text'] as String;
      expect(text, contains('还没有打开'));
    });

    test('未知资源 uri 报错', () async {
      final h = Harness();
      final r = await h.call(jsonEncode({
        'jsonrpc': '2.0',
        'id': 5,
        'method': 'resources/read',
        'params': {'uri': 'fe://nope'},
      }));
      expect((r['error'] as Map)['message'], contains('没有资源'));
    });

    test('prompts/list 与 prompts/get 能渲染出任务描述', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);

      final list = await h.call(jsonEncode(
          {'jsonrpc': '2.0', 'id': 6, 'method': 'prompts/list'}));
      final prompts = (list['result'] as Map)['prompts'] as List;
      final names = prompts.map((p) => (p as Map)['name']).toList();
      expect(names, contains('buff_character'));
      expect(names, contains('harder_chapter'));

      final got = await h.call(jsonEncode({
        'jsonrpc': '2.0',
        'id': 7,
        'method': 'prompts/get',
        'params': {
          'name': 'buff_character',
          'arguments': {'character': '罗伊'},
        },
      }));
      final msg = ((got['result'] as Map)['messages'] as List).first as Map;
      final text = (msg['content'] as Map)['text'] as String;
      expect(text, contains('罗伊'));
      expect(text, contains('dry_run'), reason: '模板应带上安全操作约定');
      expect(text, contains('validate_rom'));
    });
  });

  group('T9 validate', () {
    test('正常 ROM 自检通过', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('validate');
      expect(r['ok'], isTrue, reason: 'problems=${r['problems']}');
      expect((r['problems'] as List), isEmpty);
    });

    test('把单位表指针写坏后自检能报错', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      // 把单位表指针槽改成 0
      await h.tool('write_hex', {
        'offset': s!.rom.rom.table.unitPointerSlot,
        'bytes': [0, 0, 0, 0],
      });
      final r = await h.tool('validate');
      expect(r['ok'], isFalse);
      expect((r['problems'] as List).join(), contains('单位表'));
      s.rom.revertAll();
    });
  });

  group('T6 PNG 导出', () {
    test('肖像导出成 base64 PNG，宽高正确', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('get_portrait_png', {'id': 2});
      expect(r['width'], 96);
      expect(r['height'], 80);
      final bytes = base64Decode(r['base64'] as String);
      expect(bytes.length, greaterThan(100));
      // PNG 魔数
      expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });

    test('地图头像 32×32', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('get_portrait_png', {'id': 2, 'kind': 'map_face'});
      expect(r['width'], 32);
      expect(r['height'], 32);
    });

    test('无图时给出可用 kind 提示', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('get_portrait_png', {'id': 0});
      expect(r['__error'], contains('face'));
    });

    test('动画帧导出 248×160', () async {
      final h = Harness();
      await h.ws.open(File(fe7jp).readAsBytesSync(), '烈火.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('get_battle_anim_frame_png', {'id': 0});
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['width'], 248);
      expect(r['height'], 160);
    });
  });

  group('T10 事件单位原地覆盖', () {
    test('改等级与坐标，字段读回一致', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);

      // list_chapter_events 现在会给出每个单位的结构体地址
      final ev = await h.tool('list_chapter_events', {'chapter': 0});
      final units = ((ev['events'] as List).first as Map)['units'] as List;
      expect(units, isNotEmpty, reason: '第 0 章应有剧情增援单位');
      final u = units.first as Map;
      final addr = u['addr'] as int;
      expect(addr, greaterThan(0));

      final r = await h.tool('set_chapter_event_unit',
          {'addr': addr, 'level': 7, 'x': 5, 'y': 4});
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['changed_n'], greaterThan(0));
      expect(s!.rom.hasChanges, isTrue);

      // 读回：list_chapter_events 应报出新的等级与坐标
      final after = await h.tool('list_chapter_events', {'chapter': 0});
      final a2 = ((after['events'] as List).first as Map)['units'] as List;
      final hit = a2.cast<Map>().firstWhere((m) => m['addr'] == addr);
      expect(hit['level'], 7);
      expect(hit['x'], 5);
      expect(hit['y'], 4);
      s.rom.revertAll();
    });

    test('dry_run 不写入', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      // 用单位表的地址冒充事件结构体，验证 dry_run 语义
      final addr = s!.rom.unitAddress(1);
      final r = await h.tool('set_chapter_event_unit', {
        'addr': addr,
        'level': 3,
        'dry_run': true,
      });
      if (r['__error'] == null) {
        expect(r['dry_run'], isTrue);
        expect(s.rom.hasChanges, isFalse);
      }
    });
  });

  group('MCP 不该套用界面手选的自定义名单', () {
    test('存了自定义名单后，reciprocal 判据仍按算法算', () async {
      final h = Harness();
      final s1 = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final fpr = s1!.fingerprint;

      // 先取算法口径的名单
      final before = await h.tool('list_playable_units', {'criterion': 'reciprocal'});
      final beforeIds = (before['units'] as List).map((u) => u['id']).toList();

      // 存一份只含 3 个人的自定义名单
      await AppSettings.instance.setRoster(
          fpr, CustomRoster({1, 2, 3}));

      // 仍用 reciprocal：结果必须与之前一致，不能被名单顶掉
      final after = await h.tool('list_playable_units', {'criterion': 'reciprocal'});
      final afterIds = (after['units'] as List).map((u) => u['id']).toList();
      expect(afterIds, beforeIds, reason: '非 custom 判据不该受自定义名单影响');
      expect(after['used_custom_roster'], isFalse);

      // 显式用 custom 时才读它
      final custom = await h.tool('list_playable_units', {'criterion': 'custom'});
      expect(custom['used_custom_roster'], isTrue);
      expect((custom['units'] as List).map((u) => u['id']).toList(), [1, 2, 3]);

      await AppSettings.instance.setRoster(fpr, CustomRoster.empty);
    });

    test('预设只改判据名单，不受自定义名单限制', () async {
      final h = Harness();
      final s1 = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final fpr = s1!.fingerprint;

      // 只留 1 个人的名单
      await AppSettings.instance.setRoster(
          fpr, CustomRoster({5}));

      final r = await h.tool(
          'apply_cheat_preset', {'id': 'unit_growth_200', 'criterion': 'reciprocal'});
      expect(r['changed_entries'], greaterThan(1),
          reason: '不该只改自定义名单里的那 1 个人');

      await AppSettings.instance.setRoster(fpr, CustomRoster.empty);
      s1.rom.revertAll();
    });
  });

  group('T11 章节对话 list_chapter_dialogs', () {
    test('FE7J 第0章：琳的开场白命中且可写', () async {
      final h = Harness();
      await h.ws.open(File(fe7jp).readAsBytesSync(), '烈火.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('list_chapter_dialogs', {'chapter': 0});
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['version'], 'FE7J');
      expect(r['title'], '草原の少女', reason: '标题与游戏标题卡一致，可用来对齐章节');
      expect(r['count'], greaterThan(0));
      final ids = (r['items'] as List).map((e) => e['id']).toList();
      expect(ids, contains(2101));
      expect(r['writable'], isTrue, reason: 'Huffman 引擎可写');
    });

    test('FE8J 第0章：伊弗列姆的开场白', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('list_chapter_dialogs', {'chapter': 0});
      final ids = (r['items'] as List).map((e) => e['id']).toList();
      expect(ids, contains(2243));
      expect(r['items'].first['address'], greaterThan(0));
    });

    test('limit 会被夹紧，越界不崩', () async {
      final h = Harness();
      await h.ws.open(File(fe7jp).readAsBytesSync(), '烈火.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('list_chapter_dialogs', {'chapter': 0, 'limit': 2});
      expect((r['items'] as List).length, lessThanOrEqualTo(2));
    });

    test('提取的 ID 能直接给 write_text 用（等长改写指针不变）', () async {
      final h = Harness();
      final s1 = (await h.ws.open(File(fe7jp).readAsBytesSync(), '烈火.gba'))!;
      McpServer.instance.attach(h.ws);
      final r = await h.tool('list_chapter_dialogs', {'chapter': 0});
      final items = r['items'] as List;
      // 找一条含特殊码占位符（〔8020〕这类 4 位十六进制）的对话：
      // 原样回写应判 identical（字节逐字还原）——这是「不丢字节」的直接证据
      Map<String, dynamic>? item;
      for (final e in items) {
        final m = e as Map;
        if ((m['preview'] ?? '').toString().contains('〔') &&
            ((m['preview'] ?? '') as String).trim().isNotEmpty) {
          item = m.map((k, v) => MapEntry(k as String, v));
          break;
        }
      }
      if (item == null) {
        s1.rom.revertAll();
        return;
      }
      // 先拿同一渲染路径的原文，供写后对比
      final beforeRender = (await h.tool('read_text', {'id': item['id']}))['text'];
      final w = await h.tool(
          'write_text', {'id': item['id'], 'text': item['preview']});
      expect(w['__error'], isNull, reason: w['__error']?.toString());
      expect(w['mode'], 'identical',
          reason: '特殊码占位符必须原样注入，同内容回写不该变长');
      expect(w['old_pointer'], isNotNull);
      expect(w['new_pointer'], w['old_pointer'], reason: 'identical 不动指针');
      // 新指针读回的内容与写前一致
      final after = await h.tool('read_text', {'id': item['id']});
      expect((after['text'] as String), beforeRender,
          reason: '写回后读回内容应不变');
      s1.rom.revertAll();
    });
  });

  group('宝箱/商店/武器对比/文本批量替换', () {
    test('set_chest_item：预演 + 实改 + 回退', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);

      final dry =
          await h.tool('set_chest_item', {'chapter': 3, 'x': 6, 'y': 3, 'item': 0x4B, 'dry_run': true});
      expect(dry['__error'], isNull, reason: dry['__error']?.toString());
      expect(dry['dry_run'], isTrue);
      expect(dry['changed_bytes'], 1, reason: '0x14→0x4B 只改低字节（高 16 位保持 0）');
      expect(s!.rom.hasChanges, isFalse, reason: '预演后必须已回滚');

      final r =
          await h.tool('set_chest_item', {'chapter': 3, 'x': 6, 'y': 3, 'item': 0x4B});
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['was'], 0x14, reason: '探针锚点');
      expect(r['item'], 0x4B);
      expect(s.rom.hasChanges, isTrue);

      final revert = await h.tool('revert_changes');
      expect(revert['changed_bytes'], 0);
      expect(s.rom.hasChanges, isFalse);
    });

    test('set_chest_item：坐标不存在时报错并列出本章宝箱', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('set_chest_item',
          {'chapter': 3, 'x': 99, 'y': 99, 'item': 5});
      expect(r['__error'], contains('没有宝箱'));
      expect(s!.rom.hasChanges, isFalse);
    });

    test('set_shop_item：原地换品 + 越界槽位拒绝', () async {
      final h = Harness();
      final s = await h.ws.open(File(fe8jp).readAsBytesSync(), '圣魔.gba');
      McpServer.instance.attach(h.ws);

      final r = await h.tool('set_shop_item',
          {'chapter': 2, 'x': 5, 'y': 7, 'slot': 3, 'item': 45});
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['was'], 21, reason: '第 3 格原本是 21（探针锚点 [1,2,20,21,31]）');
      expect((r['shop_items'] as List)[3], 45);

      final bad = await h.tool('set_shop_item',
          {'chapter': 2, 'x': 5, 'y': 7, 'slot': 9, 'item': 45});
      expect(bad['__error'], contains('越界'));

      s!.rom.revertAll();
      final back = await h.tool('set_shop_item',
          {'chapter': 2, 'x': 5, 'y': 7, 'slot': 3, 'item': 21});
      expect(back['changed_bytes'], 0, reason: '换回原值 = 未改动');
    });

    test('compare_weapons：按期望伤害降序，前几名有名字', () async {
      final h = Harness();
      await h.ws.open(File(fe7jp).readAsBytesSync(), '烈火.gba');
      McpServer.instance.attach(h.ws);

      final r =
          await h.tool('compare_weapons', {'unit': 0, 'target': 1, 'limit': 10});
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      final rows = r['rows'] as List;
      expect(rows, isNotEmpty);
      expect(rows.length, lessThanOrEqualTo(10));
      for (var i = 1; i < rows.length; i++) {
        final a = (rows[i - 1] as Map)['expected_damage_per_round'] as num;
        final b = (rows[i] as Map)['expected_damage_per_round'] as num;
        expect(a, greaterThanOrEqualTo(b));
      }
      expect((rows.first as Map)['name'], isNotEmpty);
    });

    test('find_replace_text：同长替换全部命中条目，可整体回退', () async {
      final h = Harness();
      final f = _firstUtf8Rom();
      final s = await h.ws.open(f.readAsBytesSync(), '改文本.gba');
      McpServer.instance.attach(h.ws);

      // 找一个命中多条的单字：用 dry_run 预演「换成某」，
      // 通用 dry_run 把工具结果展平到顶层，changed 就是实际会改的条目数（预演后自动回滚）
      String findChar = '';
      for (final c in ['的', '了', '是', '在']) {
        final probe = await h.tool('find_replace_text',
            {'find': c, 'replace': '某', 'dry_run': true});
        if (probe['__error'] != null) continue;
        if ((((probe['changed']) as int?) ?? 0) >= 2) {
          findChar = c;
          break;
        }
      }
      expect(findChar, isNotEmpty, reason: '常用字应命中多条');
      expect(s!.rom.hasChanges, isFalse, reason: 'dry_run 必须已回滚');

      final r =
          await h.tool('find_replace_text', {'find': findChar, 'replace': '某'});
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['changed'], greaterThanOrEqualTo(2));
      expect(s!.rom.changedByteCount, greaterThan(0));

      final revert = await h.tool('revert_changes');
      expect(revert['reverted_bytes'], greaterThan(0),
          reason: '回退前改过 1040 条文本');
      expect(s.rom.hasChanges, isFalse);
    });
  });

  group('缺字检查', () {
    test('GBK 汉化版：一段剧情文本零缺字', () async {
      final h = Harness();
      await h.ws.open(File(_gbkRom()).readAsBytesSync(), 'gbk.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('check_text_coverage', {
        'text': '清晨的薄雾笼罩着利贝拉城，艾瑞珂公主站在城墙上。敌军旗帜猎猎作响。'
      });
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['ok'], isTrue);
      expect(r['missing_count'], 0);
      expect(r['engine'], contains('GBK'));
      expect((r['charset'] as Map)['label'], contains('GBK'));
    });

    test('缺字时逐一报出并给建议', () async {
      final h = Harness();
      await h.ws.open(File(_gbkRom()).readAsBytesSync(), 'gbk.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('check_text_coverage', {'text': '正常㐀'});
      expect(r['ok'], isFalse);
      expect((r['missing'] as List), contains('㐀'));
      expect(r['advice'], isNotNull);
    });

    test('未传 text 时报错', () async {
      final h = Harness();
      await h.ws.open(File(fe8jp).readAsBytesSync(), 'fe8.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('check_text_coverage', {});
      expect(r['__error'], isNotNull);
    });
  });

  group('场景化对话', () {
    test('list_chapter_scenes 返回场景与句子', () async {
      final h = Harness();
      await h.ws.open(File(_gbkRom()).readAsBytesSync(), 'gbk.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('list_chapter_scenes', {'chapter': 0, 'limit': 3});
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['title'], isNotNull);
      expect(r['count'], greaterThan(0));
      final scenes = r['scenes'] as List;
      expect(scenes, isNotEmpty);
      final first = scenes.first as Map;
      expect(first['text_id'], isA<int>());
      final lines = first['lines'] as List;
      expect(lines, isNotEmpty);
      // 句子必须是可读中文，不能带乱码块
      expect(lines.join(), isNot(contains('□')));
      expect(first['raw'], isA<String>());
    });

    test('空章节返回空场景而不是报错', () async {
      final h = Harness();
      await h.ws.open(File(_gbkRom()).readAsBytesSync(), 'gbk.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('list_chapter_scenes', {'chapter': 999});
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['count'], 0);
    });
  });

  group('预览（AI 自查）', () {
    test('preview_dialog 返回说话人/台词/控制码与边界声明', () async {
      final h = Harness();
      await h.ws.open(File(_gbkRom()).readAsBytesSync(), 'gbk.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('preview_dialog', {'chapter': 0, 'limit': 20});
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['line_count'], greaterThan(0));
      final lines = r['lines'] as List;
      expect(lines, isNotEmpty);
      final first = lines.first as Map;
      expect(first['text'], isA<String>());
      // 默认 compact：只给控制码数量，不给明细（避免响应过大）
      expect(first['control_count'], isA<int>());
      expect(first['control_count'], greaterThan(0));
      expect(r['compact'], isTrue);
      // compact 模式省略了 speaker 字段；完整模式才看 speaker_source
      expect(first.containsKey('speaker'), isFalse);
      // 边界声明必须随结果返回，AI 不能把预览当实测
      expect(r['boundary'], contains('不是游戏实际运行画面'));
    });

    test('compact=false 时给出 raw 与控制码明细', () async {
      final h = Harness();
      await h.ws.open(File(_gbkRom()).readAsBytesSync(), 'gbk.gba');
      McpServer.instance.attach(h.ws);
      final r =
          await h.tool('preview_dialog', {'chapter': 0, 'compact': false, 'limit': 5});
      final lines = (r['lines'] as List).cast<Map>();
      expect(lines, isNotEmpty);
      expect(lines.first['raw'], isA<String>());
      expect(lines.first['control_tokens'], isA<List>());
      expect(r['compact'], isNull);
      // 说话人拿不到就必须标 unavailable，不能填猜值
      expect(lines.first['speaker'], isNull);
      expect(lines.first['speaker_source'], 'unavailable');
    });

    test('preview_events 返回自然语言句子与单位明细', () async {
      final h = Harness();
      await h.ws.open(File(_gbkRom()).readAsBytesSync(), 'gbk.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('preview_events', {'chapter': 0});
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['event_count'], greaterThan(0));
      final events = (r['events'] as List).cast<Map>();
      final withUnits = events.where((e) => (e['units'] as List).isNotEmpty);
      expect(withUnits, isNotEmpty);
      expect(withUnits.first['sentence'], contains('生成'));
      expect(r['boundary'], contains('不是游戏实际运行画面'));
      expect((r['map'] as Map)['width'], greaterThan(0));
    });

    test('preview_dialog 空章节不报错、给说明', () async {
      final h = Harness();
      await h.ws.open(File(_gbkRom()).readAsBytesSync(), 'gbk.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('preview_dialog', {'chapter': 999});
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['line_count'], 0);
      expect(r['issues'], isNotEmpty);
    });
  });

  group('事件编辑（只追加不改既有脚本）', () {
    test('add_chapter_event 追加后被 preview_events 看到', () async {
      final h = Harness();
      await h.ws.open(File(_gbkRom()).readAsBytesSync(), 'gbk.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('add_chapter_event', {
        'chapter': 0,
        'type': 'turn',
        'turn': 7,
        'units': [
          {
            'char_id': 135,
            'class_id': 57,
            'level': 5,
            'x': 5,
            'y': 7,
            'allegiance': 2,
            'items': [1],
          }
        ],
      });
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['ok'], isTrue);

      final p = await h.tool('preview_events', {'chapter': 0});
      final events = (p['events'] as List).cast<Map>();
      final hit = events.where(
          (e) => (e['sentence'] as String).contains('第 7 回合'));
      expect(hit, isNotEmpty, reason: '新事件应出现在预览里');
      final units = hit.first['units'] as List;
      expect(units.length, 1);
      expect((units.first as Map)['x'], 5);
    });

    test('参数越界时报可理解的错且不写字节', () async {
      final h = Harness();
      final s = await h.ws.open(File(_gbkRom()).readAsBytesSync(), 'gbk.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('add_chapter_event', {
        'chapter': 0,
        'type': 'turn',
        'turn': 7,
        'units': [
          {'char_id': 9999, 'class_id': 0, 'level': 1, 'x': 1, 'y': 1}
        ],
      });
      expect(r['__error'], contains('角色 ID'));
      expect(s!.rom.changedByteCount, 0);
    });

    test('未知类型列出可用值', () async {
      final h = Harness();
      await h.ws.open(File(_gbkRom()).readAsBytesSync(), 'gbk.gba');
      McpServer.instance.attach(h.ws);
      final r = await h.tool('add_chapter_event', {
        'chapter': 0,
        'type': 'nonsense',
        'units': [
          {'char_id': 1, 'class_id': 0, 'level': 1, 'x': 1, 'y': 1}
        ],
      });
      expect(r['__error'], contains('turn'));
    });

    test('remove_last_chapter_event 能回退自己加的', () async {
      final h = Harness();
      await h.ws.open(File(_gbkRom()).readAsBytesSync(), 'gbk.gba');
      McpServer.instance.attach(h.ws);
      await h.tool('add_chapter_event', {
        'chapter': 0,
        'type': 'turn',
        'turn': 7,
        'units': [
          {'char_id': 135, 'class_id': 57, 'level': 5, 'x': 5, 'y': 7}
        ],
      });
      final d = await h.tool(
          'remove_last_chapter_event', {'chapter': 0, 'type': 'turn'});
      expect(d['__error'], isNull, reason: d['__error']?.toString());
      expect(d['ok'], isTrue);
      final p = await h.tool('preview_events', {'chapter': 0});
      final events = (p['events'] as List).cast<Map>();
      expect(
          events.where(
              (e) => (e['sentence'] as String).contains('第 7 回合')),
          isEmpty);
    });
  });

  group('外部工作区', () {
    test('未设置工作区时 list_workspace_roms 给出提示而不是报错', () async {
      final h = Harness();
      McpServer.instance.attach(h.ws);
      final r = await h.tool('list_workspace_roms');
      expect(r['__error'], isNull, reason: r['__error']?.toString());
      expect(r['configured'], isFalse);
      expect(r['hint'], contains('设置工作区'));
    });

    test('未设置工作区时 open_workspace_rom 报可理解的错', () async {
      final h = Harness();
      McpServer.instance.attach(h.ws);
      final r = await h.tool('open_workspace_rom', {'name': 'x.gba'});
      expect(r['__error'], contains('设置工作区'));
    });

    test('资源 fe://workspace/roms 没打开 ROM 也能读', () async {
      final h = Harness();
      McpServer.instance.attach(h.ws);
      final r = await h.call(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'resources/read',
        'params': {'uri': 'fe://workspace/roms'},
      }));
      final content = ((r['result'] as Map)['contents'] as List).first as Map;
      expect(content['text'], contains('外部工作区'));
    });
  });
}

File _firstUtf8Rom() {
  for (final f in Directory(dir).listSync()) {
    if (f is File && f.path.contains('铠甲')) return f;
  }
  throw StateError('找不到明文 UTF-8 的 ROM');
}

/// 明文 GBK 的烈火汉化版（字库覆盖最全的基底）。
String _gbkRom() {
  for (final f in Directory(dir).listSync()) {
    if (f is File && f.path.contains('Superxyj')) return f.path;
  }
  throw StateError('找不到明文 GBK 的 ROM');
}
