import 'dart:convert';
import 'dart:typed_data';

import 'app_meta.dart';
import 'app_settings.dart';
import 'asset_converters.dart';
import 'asset_library.dart';
import 'asset_store.dart';
import 'battle_anim.dart';
import 'battle_anim_porter.dart';
import 'battle_sim.dart';
import 'battle_anim.dart' show encodePng;
import 'chapter_event_editor.dart';
import 'chapter_events.dart';
import 'chapter_dialogs.dart';
import 'class_terrain.dart';
import 'cheat_presets.dart';
import 'chest_shop.dart';
import 'custom_roster.dart';
import 'dialog_script.dart';
import 'edit_snapshot.dart';
import 'event_preview.dart';
import 'event_templates.dart';
import 'editable_rom.dart';
import 'external_workspace.dart';
import 'fe_rom.dart';
import 'hex_view.dart';
import 'item_catalog.dart';
import 'map_reader.dart';
import 'map_writer.dart';
import 'mcp_service.dart';
import 'playable_units.dart';
import 'portrait.dart';
import 'portrait_import.dart';
import 'portrait_porter.dart';
import 'recipe.dart';
import 'rom_health.dart';
import 'rom_info.dart';
import 'rom_session.dart';
import 'rom_workspace.dart';
import 'text_browser.dart';
import 'text_coverage.dart';
import 'text_find_replace.dart';
import 'text_writer.dart';
import 'unit_placement.dart';

/// 内嵌 MCP 服务器（Model Context Protocol）的协议层。
///
/// 与 socket 无关：这里只做「收一段 JSON-RPC → 返回一段 JSON」，
/// 传输交给原生线程（见 `MainActivity.kt` 的 `fe_editor/mcp` 通道）。
/// 这样这一层可以在单元测试里直接调用，不用起监听端口。
///
/// 支持的方法：`initialize` / `ping` / `tools/list` / `tools/call`。
/// 工具清单只有 [toolDefinitions] 一处定义，`tools/list` 与分发都读它——
/// 两边各写一份会出现「列出来了却调不动」。
class McpServer {
  McpServer._();

  static final McpServer instance = McpServer._();

  /// 客户端没带 protocolVersion 时回这个。
  static const String defaultProtocolVersion = '2025-06-18';

  /// 当前打开 ROM 的工作区；由主页启动时 [attach]。
  ///
  /// 服务器跑在后台线程，需要一个稳定的入口拿到「当前打开的是哪些 ROM」。
  RomWorkspace? _workspace;

  /// 素材仓库工厂。默认走原生通道；测试里可以换成内存实现。
  AssetStore Function(String project)? assetStoreFactory;

  void attach(RomWorkspace workspace) => _workspace = workspace;

  void detach() => _workspace = null;

  bool get ready => _workspace != null;

  /// 当前会话；没有打开 ROM 时返回 null（资源读取用，不抛异常）。
  RomSession? currentSessionOrNull() {
    final ws = _workspace;
    if (ws == null || ws.isEmpty) return null;
    return ws.active;
  }

  Future<RomSession?> _session(Map<String, dynamic> args) async {
    final ws = _workspace;
    if (ws == null || ws.isEmpty) return null;
    final wanted = args['rom'];
    if (wanted is String && wanted.isNotEmpty) {
      for (final s in ws.sessions) {
        if (s.versionId.toLowerCase() == wanted.toLowerCase() ||
            s.fileName == wanted) {
          return s;
        }
      }
      return null;
    }
    return ws.active;
  }

  // ---------- 协议入口 ----------

  /// 处理一整段请求体（可能是单条或批量 JSON-RPC）。
  Future<String?> handleBody(String body) async {
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return _encode(_error(null, -32700, 'JSON 解析失败'));
    }
    if (decoded is List) {
      final out = <Map<String, dynamic>>[];
      for (final item in decoded) {
        final r = await _handleOne(item);
        if (r != null) out.add(r);
      }
      return out.isEmpty ? null : _encode(out);
    }
    final r = await _handleOne(decoded);
    return r == null ? null : _encode(r);
  }

  String _encode(Object o) => jsonEncode(o);

  Future<Map<String, dynamic>?> _handleOne(dynamic raw) async {
    if (raw is! Map) {
      return _error(null, -32600, '请求必须是对象');
    }
    final id = raw['id'];
    final method = raw['method'];
    final params = raw['params'];
    if (method is! String) return _error(id, -32600, '缺少 method');

    // 通知（没有 id）不需要回复
    final isNotification = !raw.containsKey('id');
    try {
      switch (method) {
        case 'initialize':
          // 回显客户端请求的协议版本：客户端会拿它跟自己支持的列表比对，
          // 回一个不相符的值会让它误判「服务端协议不兼容」。
          final requested = params is Map ? params['protocolVersion'] : null;
          final version = requested is String && requested.isNotEmpty
              ? requested
              : defaultProtocolVersion;
          return _result(id, {
            'protocolVersion': version,
            'capabilities': {
              'tools': {},
              'resources': {},
              'prompts': {},
            },
            'serverInfo': {'name': appName, 'version': appVersion},
          });
        case 'notifications/initialized':
        case 'initialized':
          return null;
        case 'ping':
          return _result(id, {});
        case 'tools/list':
          return _result(id, {
            'tools': [for (final t in toolDefinitions) t.schema],
          });
        case 'tools/call':
          final p = params is Map ? params : const {};
          final name = p['name'];
          final args = p['arguments'];
          if (name is! String) return _error(id, -32602, '缺少工具名');
          return _result(
              id, await _callTool(name, args is Map<String, dynamic> ? args : {}));
        case 'resources/list':
          return _result(id, {
            'resources': [for (final r in mcpResources) r.descriptor],
          });
        case 'resources/templates/list':
          return _result(id, {'resourceTemplates': const []});
        case 'resources/read':
          final p = params is Map ? params : const {};
          final uri = p['uri'];
          if (uri is! String) return _error(id, -32602, '缺少 uri');
          final res = mcpResources.where((r) => r.uri == uri).firstOrNull;
          if (res == null) return _error(id, -32602, '没有资源「$uri」');
          return _result(id, {
            'contents': [
              {
                'uri': uri,
                'mimeType': res.mimeType,
                'text': await res.readAll(this),
              }
            ],
          });
        case 'prompts/list':
          return _result(id, {
            'prompts': [for (final p in mcpPrompts) p.descriptor],
          });
        case 'prompts/get':
          final p = params is Map ? params : const {};
          final name = p['name'];
          if (name is! String) return _error(id, -32602, '缺少 prompt 名');
          final prompt = mcpPrompts.where((x) => x.name == name).firstOrNull;
          if (prompt == null) return _error(id, -32602, '没有 prompt「$name」');
          final args = p['arguments'];
          return _result(id, {
            'description': prompt.description,
            'messages': [
              {
                'role': 'user',
                'content': {
                  'type': 'text',
                  'text': prompt
                      .render(args is Map ? args.map((k, v) => MapEntry('$k', v)) : const {}),
                }
              }
            ],
          });
        default:
          if (isNotification) return null;
          return _error(id, -32601, '不支持的方法：$method');
      }
    } catch (e) {
      return _error(id, -32603, '$e');
    }
  }

  Map<String, dynamic> _result(dynamic id, Object result) =>
      {'jsonrpc': '2.0', 'id': id, 'result': result};

  Map<String, dynamic> _error(dynamic id, int code, String message) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };

  /// 单次工具响应的字符预算。
  ///
  /// 超过它就会被客户端/传输层拖慢（实测一次 `dry_run` 倒出上百条逐字节 patch，
  /// 单响应几万字符，连续调用直接卡住）。宁可在响应里少给细节、留一行说明，
  /// 也不要让调用方干等。
  static const int responseCharBudget = 12000;

  /// `describe_rom` 里章节清单的条数上限（其余用 list_chapters 取）。
  static const int _describeChapterLimit = 40;

  /// `tools/call` 的返回：统一包装成 MCP 的 content 结构。
  ///
  /// 带**输出预算**：超过 [responseCharBudget] 就逐步缩减列表字段，
  /// 并在结果里标明「被截了多少」。不要指望每个工具自己算好——
  /// 一个工具多返回一个字段就可能爆预算，并且新增工具时会忘。
  Map<String, dynamic> _toolOk(Object payload) {
    if (payload is String) return _okText(payload);
    final trimmed = _fitBudget(payload);
    return _okText(const JsonEncoder.withIndent('  ').convert(trimmed));
  }

  Map<String, dynamic> _okText(String text) => {
        'content': [
          {'type': 'text', 'text': text}
        ],
        'isError': false,
      };

  /// 把结果压到预算内。
  ///
  /// 策略（从温和到激烈）：
  /// 1. 先砍 `patch`（逐字节明细，调试才需要，默认只留前 8 条）；
  /// 2. 再砍其它长列表字段（每个只留前 20 条，并记下原长度）。
  /// 任何缩减都在 `_truncated` 里写明，不静默丢信息。
  static Object _fitBudget(Object payload) {
    String encoded(Object o) {
      try {
        return jsonEncode(o);
      } catch (_) {
        return '';
      }
    }

    if (payload is! Map) return payload;
    if (encoded(payload).length <= responseCharBudget) return payload;

    final out = Map<String, dynamic>.from(payload);
    final notes = <String, Object?>{};

    // 1) patch 明细：默认只留前 8 条
    final patch = out['patch'];
    if (patch is List && patch.length > 8) {
      out['patch'] = patch.take(8).toList();
      notes['patch'] = {'kept': 8, 'total': patch.length};
    }
    if (encoded(out).length <= responseCharBudget) {
      if (notes.isNotEmpty) out['_truncated'] = notes;
      return out;
    }

    // 2) 其他长列表：每个只留前 20 条
    for (final key in out.keys.toList()) {
      final v = out[key];
      if (v is! List || v.length <= 20) continue;
      out[key] = v.take(20).toList();
      notes[key] = {'kept': 20, 'total': v.length};
      if (encoded(out).length <= responseCharBudget) break;
    }
    if (notes.isNotEmpty) out['_truncated'] = notes;
    return out;
  }

  Map<String, dynamic> _toolErr(String message) => {
        'content': [
          {'type': 'text', 'text': message}
        ],
        'isError': true,
      };

  Future<Map<String, dynamic>> _callTool(
      String name, Map<String, dynamic> args) async {
    try {
      final value = await _maybeDryRun(name, args);
      if (value is _ToolFailure) return _toolErr(value.message);
      // 兜底：先序列化一次，避免枚举之类不可编码的值在传输时炸掉，
      // 那样客户端只会看到「内部错误」，很难排查。
      try {
        jsonEncode(value);
      } catch (e) {
        return _toolErr('返回值无法序列化：$e');
      }
      return _toolOk(value);
    } on _ToolFailure catch (e) {
      return _toolErr(e.message);
    } catch (e) {
      return _toolErr('工具执行失败：$e');
    }
  }

  /// `dry_run=true` 的统一实现：真的执行一遍、比对字节、然后回滚。
  ///
  /// 之所以不是「每个工具各写一份预测逻辑」：预测与实际写入必然会产生偏差
  /// （文本重定位、地图压缩、整表搬家都要实际算才知道结果），
  /// 而 AI 最需要确信的正是「我这一下会动哪里」。走真实执行 + 回滚就完全一致。
  Future<Object> _maybeDryRun(String name, Map<String, dynamic> args) async {
    if (args['dry_run'] != true) return _dispatch(name, args);
    final tool = toolDefinitions.where((t) => t.name == name).firstOrNull;
    if (tool == null) throw _ToolFailure('未知工具：$name');
    if (!tool.dryRunnable) {
      throw _ToolFailure(tool.mutating
          ? '$name 改的是编辑会话状态（不是 ROM 数据），不支持 dry_run'
          : '$name 是只读工具，不需要 dry_run');
    }
    final s = awaitSessionSync(args);
    final snap = s.snapshots.take(s.rom, label: 'dry_run:$name');
    try {
      final value = await _dispatch(name, args);
      final diff = diffBytes(snap.data, s.rom.buffer.data);
      // 工具自己带 dry run（如 set_*_field）时不会真的写，差异为空，
      // 这时候用它自报的 patch 数量——两边都是「将改几个字节」。
      final selfPatch = value is Map ? value['patch'] : null;
      final changed = diff.total > 0
          ? diff.total
          : (selfPatch is List ? selfPatch.length : 0);
      final result = <String, Object?>{
        'dry_run': true,
        'tool': name,
        'changed_bytes': changed,
        'regions': [
          for (final r in diff.regions.take(20))
            {
              'offset': r.offset,
              'gba': 0x08000000 + r.offset,
              'length': r.length,
            }
        ],
        'rolled_back': true,
      };
      if (diff.diffs.isNotEmpty) {
        // 只给前 8 条样本：逐字节明细是调试用的，全倒出来会让单次响应急剧变大
        // （实测 99 条 patch 的响应上万字符，连续调用时调用方会卡住）。
        // 完整区间在 regions 里，足够判断「改了哪里」。
        result['patch'] = [
          for (final d in diff.diffs.take(8))
            {'offset': d.offset, 'before': d.before, 'after': d.after}
        ];
        if (diff.diffs.length > 8) {
          result['patch_total'] = diff.diffs.length;
        }
      }
      if (value is Map) {
        // 工具自己算过 patch（如 set_*_field）就沿用它，它是「写哪几个字节」
        // 的权威描述；这里只补上真实执行后的整体差异。
        result.addAll(value.cast<String, Object?>());
        result['changed_bytes'] = changed;
      } else {
        result['would_return'] = value;
      }
      return result;
    } finally {
      s.snapshots.restore(s.rom, snap);
      s.snapshots.drop(snap.id);
    }
  }

  Future<Object> _dispatch(String name, Map<String, dynamic> a) async {
    switch (name) {
      case 'list_roms':
        return _listRoms();
      case 'rom_info':
        return _romInfo(a);
      case 'list_units':
        return _listUnits(a);
      case 'get_unit':
        return _getUnit(a);
      case 'set_unit_field':
        return _setField(a, target: 'unit');
      case 'list_classes':
        return _listClasses(a);
      case 'get_class':
        return _getEntry(a, target: 'class');
      case 'get_item':
        return _getEntry(a, target: 'item');
      case 'set_class_field':
        return _setField(a, target: 'class');
      case 'list_items':
        return _listItems(a);
      case 'set_item_field':
        return _setField(a, target: 'item');
      case 'list_chapters':
        return _listChapters(a);
      case 'get_map':
        return _getMap(a);
      case 'set_map_tiles':
        return _setMapTiles(a);
      case 'list_portraits':
        return _listPortraits(a);
      case 'portrait_usage':
        return _portraitUsage(a);
      case 'import_portrait':
        return _importPortrait(a);
      case 'list_battle_anims':
        return _listBattleAnims(a);
      case 'get_portrait_png':
        return _portraitPng(a);
      case 'get_battle_anim_frame_png':
        return _animFramePng(a);
      case 'import_battle_anim':
        return _importBattleAnim(a);
      case 'read_text':
        return _readText(a);
      case 'write_text':
        return _writeText(a);
      case 'check_text_coverage':
        return _checkTextCoverage(a);
      case 'list_chapter_scenes':
        return _listChapterScenes(a);
      case 'preview_dialog':
        return _previewDialog(a);
      case 'preview_events':
        return _previewEvents(a);
      case 'add_chapter_event':
        return _addChapterEvent(a);
      case 'remove_last_chapter_event':
        return _removeLastChapterEvent(a);
      case 'list_workspace_roms':
        return _listWorkspaceRoms(a);
      case 'open_workspace_rom':
        return _openWorkspaceRom(a);
      case 'list_asset_library':
        return _listAssetLibrary(a);
      case 'read_asset':
        return _readAsset(a);
      case 'write_asset':
        return _writeAsset(a);
      case 'list_assets':
        return _listAssets(a);
      case 'asset_info':
        return _assetInfo(a);
      case 'import_asset_from_library':
        return _importAssetFromLibrary(a);
      case 'import_asset':
        return _importAsset(a);
      case 'export_asset_from_rom':
        return _exportAssetFromRom(a);
      case 'copy_asset_between_sessions':
        return _copyAssetBetweenSessions(a);
      case 'delete_asset':
        return _deleteAsset(a);
      case 'list_cheat_presets':
        return _listCheatPresets(a);
      case 'apply_cheat_preset':
        return _applyCheatPreset(a);
      case 'list_playable_units':
        return _listPlayable(a);
      case 'find_free_space':
        return _findFreeSpace(a);
      case 'read_hex':
        return _readHex(a);
      case 'write_hex':
        return _writeHex(a);
      case 'list_chapter_events':
        return _listChapterEvents(a);
      case 'list_chapter_dialogs':
        return _listChapterDialogs(a);
      case 'revert_changes':
        return _revert(a);
      case 'save_rom':
        return _saveRom(a);
      case 'save_rom_to_file':
        return _saveRomToFile(a);
      case 'validate':
        return _validate(a);
      case 'validate_rom':
        return _validateRom(a);
      case 'describe_rom':
        return _describeRom(a);
      case 'snapshot':
        return _snapshot(a);
      case 'rollback':
        return _rollback(a);
      case 'list_snapshots':
        return _listSnapshots(a);
      case 'list_changes':
        return _listChanges(a);
      case 'set_chapter_event_unit':
        return _setEventUnit(a);
      case 'set_chapter_unit':
        return _setChapterUnit(a);
      case 'attach_portrait_to_unit':
        return _attachPortrait(a);
      case 'import_portrait_image':
        return _importPortraitImage(a);
      case 'clone_unit':
        return _cloneUnit(a);
      case 'add_reinforcement':
        return _addReinforcement(a);
      case 'set_chest_item':
        return _setChestItem(a);
      case 'set_shop_item':
        return _setShopItem(a);
      case 'compare_weapons':
        return _compareWeapons(a);
      case 'find_replace_text':
        return _findReplaceText(a);
      case 'simulate_growth':
        return _simulateGrowth(a);
      case 'simulate_battle':
        return _simulateBattle(a);
      case 'export_recipe':
        return _exportRecipe(a);
      case 'apply_recipe':
        return _applyRecipe(a);
      case 'get_class_terrain':
        return _getClassTerrain(a);
      case 'set_class_terrain':
        return _setClassTerrain(a);
      default:
        throw _ToolFailure('未知工具：$name');
    }
  }

  // ---------- 工具实现 ----------

  RomWorkspace get _ws {
    final ws = _workspace;
    if (ws == null) throw _ToolFailure('MCP 服务未连接到应用界面');
    return ws;
  }

  Object _listRoms() {
    final ws = _ws;
    return {
      'count': ws.sessions.length,
      'active': ws.active?.versionId,
      'roms': [
        for (final s in ws.sessions)
          {
            'version': s.versionId,
            'file': s.fileName,
            'generation': s.generation,
            'active': s.id == ws.active?.id,
            'changed_bytes': s.rom.changedByteCount,
          }
      ],
    };
  }

  Object _romInfo(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final rom = s.rom.rom;
    return {
      'version': s.versionId,
      'version_name': s.versionName,
      'file': s.fileName,
      'size': rom.length,
      'game_code': rom.gameCode,
      'header_title': rom.headerTitle,
      'text_encoding': rom.textEncoding.name,
      'zh_table': s.hasZhTable,
      'text_writable': s.textWritable,
      'counts': {
        'units': rom.unitCount,
        'classes': rom.classCount,
        'items': rom.itemCount,
      },
      'tables': {
        'unit': rom.unitBase,
        'class': rom.classBase,
        'item': rom.itemBase,
      },
      'changed_bytes': s.rom.changedByteCount,
      'edits': s.rom.edits.length,
    };
  }

  /// 同步版取会话（工具方法内部用，失败抛 _ToolFailure）。
  RomSession awaitSessionSync(Map<String, dynamic> a) {
    final ws = _workspace;
    if (ws == null || ws.isEmpty) throw _ToolFailure('还没有打开任何 ROM');
    final wanted = a['rom'];
    if (wanted is String && wanted.isNotEmpty) {
      for (final s in ws.sessions) {
        if (s.versionId.toLowerCase() == wanted.toLowerCase() ||
            s.fileName == wanted) {
          return s;
        }
      }
      throw _ToolFailure('没有打开版本为「$wanted」的 ROM');
    }
    return ws.active!;
  }

  Object _listUnits(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final rom = s.liveRom;
    final limit = (a['limit'] as num?)?.toInt() ?? 300;
    final query = (a['query'] as String?)?.trim() ?? '';
    final out = <Map<String, Object?>>[];
    for (var i = 0; i < rom.unitCount && out.length < limit; i++) {
      final name = rom.unitDisplayName(i).trim();
      if (query.isNotEmpty && !name.contains(query)) continue;
      final cid = rom.unitClassId(i);
      out.add({
        'id': i,
        'name': name,
        'class_id': cid,
        'class_name': cid >= 0 ? rom.classDisplayName(cid).trim() : '',
        'level': rom.data[rom.unitBase + i * rom.table.unitDataSize + 11],
      });
    }
    return {'version': s.versionId, 'total': rom.unitCount, 'units': out};
  }

  Object _getUnit(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final rom = s.liveRom;
    final id = _requireIndex(a, 'id', rom.unitCount);
    final addr = s.rom.unitAddress(id);
    final fields = unitEditableFieldsFor(fe6: rom.isFe6);
    final cid = rom.unitClassId(id);
    final face = _faceOf(rom, id);
    return {
      'id': id,
      'name': rom.unitDisplayName(id).trim(),
      'class_id': cid,
      'class_name': cid >= 0 ? rom.classDisplayName(cid).trim() : '',
      'face': face,
      'fields': [
        for (final f in fields)
          {'name': f.label, 'value': s.rom.readField(addr, f)},
      ],
    };
  }

  int _faceOf(FeRom rom, int id) {
    final at = rom.unitBase + id * rom.table.unitDataSize + 6;
    return FeRom.u16(rom.data, at);
  }

  Object _listClasses(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final rom = s.liveRom;
    final out = <Map<String, Object?>>[];
    for (var i = 0; i < rom.classCount; i++) {
      out.add({
        'id': i,
        'name': rom.classDisplayName(i).trim(),
        'move': rom.data[rom.classBase + i * rom.table.classDataSize + 18],
      });
    }
    return {'version': s.versionId, 'total': rom.classCount, 'classes': out};
  }

  Object _listItems(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final catalog = ItemCatalog(s.liveRom);
    final out = <Map<String, Object?>>[];
    for (var i = 0; i < catalog.count; i++) {
      final e = catalog.entryAt(i);
      out.add({
        'id': i,
        'name': catalog.nameOf(i).trim(),
        'kind': e?.kind?.name,
        'might': e?.might,
        'durability': e?.durability,
      });
    }
    return {'version': s.versionId, 'total': out.length, 'items': out};
  }

  /// 读单条职业 / 道具的**全部可编辑字段与当前值**。
  ///
  /// 没有它 `set_*_field` 就是盲写：AI 不知道有哪些字段名可用。
  /// get_unit 早就有这个信息，职业/道具一直缺。
  Object _getEntry(Map<String, dynamic> a, {required String target}) {
    final s = awaitSessionSync(a);
    final rom = s.liveRom;
    final isClass = target == 'class';
    final count = isClass ? rom.classCount : rom.itemCount;
    final id = _requireIndex(a, 'id', count);
    final fields = isClass
        ? classEditableFieldsFor(fe6: rom.isFe6)
        : itemEditableFieldsFor(fe6: rom.isFe6);
    final addr =
        isClass ? s.rom.classAddress(id) : s.rom.itemAddress(id);
    final name = isClass
        ? rom.classDisplayName(id).trim()
        : rom.itemDisplayName(id).trim();
    final out = <String, Object?>{
      'id': id,
      'name': name,
      'fields': [
        for (final f in fields)
          {
            'name': f.label,
            'value': s.rom.readField(addr, f),
            'min': f.min,
            'max': f.max,
            if (f.stepsHint != null) 'steps': f.stepsHint,
          }
      ],
    };
    if (!isClass) {
      final catalog = ItemCatalog(rom);
      final e = catalog.entryAt(id);
      out['kind'] = e?.kind?.name;
      out['usable'] = e?.hasDurability;
    }
    return out;
  }

  /// 职业地形表：表名 → (指针槽偏移, 中文标签)。
  ({int slot, String label})? _terrainSlot(ClassTerrain t, String name) {
    switch (name) {
      case 'mov_dry':
        return (slot: t.movCostOffsets[0], label: '移动消耗（晴）');
      case 'mov_rain':
        if (t.movCostOffsets.length < 2) return null;
        return (slot: t.movCostOffsets[1], label: '移动消耗（雨）');
      case 'mov_snow':
        if (t.movCostOffsets.length < 3) return null;
        return (slot: t.movCostOffsets[2], label: '移动消耗（雪）');
      case 'avoid':
        return (slot: t.lookupOffsets[0], label: '地形回避');
      case 'defense':
        return (slot: t.lookupOffsets[1], label: '地形防御');
      case 'resistance':
        return (slot: t.lookupOffsets[2], label: '地形魔防');
    }
    return null;
  }

  Object _getClassTerrain(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final rom = s.liveRom;
    final id = _requireIndex(a, 'id', rom.classCount);
    final t = ClassTerrain(s.rom);
    final only = (a['terrain'] as num?)?.toInt();

    List<Object?> values(int slot) {
      if (only != null) {
        return [t.valueAt(id, slot, only)];
      }
      return [
        for (var i = 0; i <= ClassTerrain.terrainCount; i++)
          t.valueAt(id, slot, i)
      ];
    }

    Map<String, Object?> table(String label, int slot) => {
          'label': label,
          'pointer_slot': slot,
          'target': t.pointerTarget(id, slot),
          if (only != null) 'terrain': only,
          'values': values(slot),
          'shared_with_n': t.sharersOf(id, slot).length,
          'shared_with': [
            for (final c in t.sharersOf(id, slot).take(12))
              {'id': c, 'name': rom.classDisplayName(c).trim()}
          ],
        };

    return {
      'id': id,
      'name': rom.classDisplayName(id).trim(),
      'is_fe6': t.isFe6,
      'terrain_count': ClassTerrain.terrainCount,
      'tables': [
        for (var i = 0; i < t.movCostOffsets.length; i++)
          table(ClassTerrain.movCostLabels[i], t.movCostOffsets[i]),
        for (var i = 0; i < t.lookupOffsets.length; i++)
          table(ClassTerrain.lookupLabels[i], t.lookupOffsets[i]),
      ],
      'note': '地形表在 ROM 里常常被多个职业共享（shared_with），'
          '改一处会影响所有共享者。',
    };
  }

  Object _setClassTerrain(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final rom = s.liveRom;
    final id = _requireIndex(a, 'id', rom.classCount);
    final t = ClassTerrain(s.rom);
    final tableName = a['table'];
    if (tableName is! String) {
      throw _ToolFailure(
          'table 必填：mov_dry / mov_rain / mov_snow / avoid / defense / resistance');
    }
    final slot = _terrainSlot(t, tableName);
    if (slot == null) {
      throw _ToolFailure(t.isFe6
          ? 'FE6 没有雨/雪两张移动表；可用：mov_dry / avoid / defense / resistance'
          : '未知 table：$tableName');
    }
    final terrain = _requireInt(a, 'terrain');
    if (terrain < 0 || terrain > ClassTerrain.terrainCount) {
      throw _ToolFailure(
          'terrain 越界：0..${ClassTerrain.terrainCount}（得到 $terrain）');
    }
    final value = _requireInt(a, 'value');
    if (value < -128 || value > 127) {
      throw _ToolFailure('value 越界：-128..127（得到 $value）');
    }
    final before = t.valueAt(id, slot.slot, terrain);
    if (before == null) {
      throw _ToolFailure('职业 $id 的「${slot.label}」表指针无效，不能写');
    }
    final dry = _dryRun(a);
    final at = t.pointerTarget(id, slot.slot) + terrain;
    final n = dry ? 0 : t.setValue(id, slot.slot, terrain, value);
    return {
      'dry_run': dry,
      'class_id': id,
      'table': tableName,
      'label': slot.label,
      'terrain': terrain,
      'before': before,
      'after': value,
      'offset': at,
      'changed': dry ? (before != value) : n == 1,
      if (!dry && n == 1) 'changed_bytes': s.rom.changedByteCount,
      'shared_with_n': t.sharersOf(id, slot.slot).length,
    };
  }

  /// 单位 / 职业 / 道具共用的字段写入。
  Object _setField(Map<String, dynamic> a, {required String target}) {
    final s = awaitSessionSync(a);
    final rom = s.liveRom;
    final id = _requireIndex(a, 'id', switch (target) {
      'unit' => rom.unitCount,
      'class' => rom.classCount,
      _ => rom.itemCount,
    });
    final fieldName = a['field'];
    final value = a['value'];
    if (fieldName is! String || value is! num) {
      throw _ToolFailure('需要 field（字段名）与 value（数值）');
    }
    final fields = switch (target) {
      'unit' => unitEditableFieldsFor(fe6: rom.isFe6),
      'class' => classEditableFieldsFor(fe6: rom.isFe6),
      _ => itemEditableFieldsFor(fe6: rom.isFe6),
    };
    final field = fields.where((f) => f.label == fieldName).firstOrNull;
    if (field == null) {
      throw _ToolFailure(
          '没有字段「$fieldName」。可用：${fields.map((f) => f.label).join('、')}');
    }
    final addr = switch (target) {
      'unit' => s.rom.unitAddress(id),
      'class' => s.rom.classAddress(id),
      _ => s.rom.itemAddress(id),
    };
    final before = s.rom.readField(addr, field);
    if (_dryRun(a)) {
      // dry run：算出写入后会变成什么、动几个字节，但**不落盘**
      final clamped = _clampFor(field, value.toInt());
      final patch = _bytesFor(s.rom, addr, field, clamped);
      return {
        'dry_run': true,
        'changed': clamped != before,
        'before': before,
        'after': clamped,
        if (patch.isNotEmpty) 'patch': patch,
        'changed_bytes': s.rom.changedByteCount,
      };
    }
    final changed = s.rom.writeField(addr, field, value.toInt());
    return {
      'changed': changed,
      'before': before,
      'after': s.rom.readField(addr, field),
      'changed_bytes': s.rom.changedByteCount,
    };
  }

  /// 章节索引 → 内部资源名。AI 靠它把「第 3 章」对上索引 3。
  Object _listChapters(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final map = MapReader(s.rom.rom);
    final units = UnitPlacement(s.rom);
    final count = map.available ? map.chapterCount : units.chapterCount;
    final out = <Map<String, Object?>>[];
    for (var i = 0; i < count; i++) {
      final m = map.available ? map.chapterMap(i) : null;
      out.add({
        'id': i,
        'title': units.chapterTitle(i),
        'resource': map.available ? map.resourceNameOf(i) : '',
        'width': m?.width,
        'height': m?.height,
        'has_events': units.eventGroupOffset(i) > 0,
      });
    }
    return {
      'version': s.versionId,
      'count': count,
      'chapters': out,
      'hint': 'title 是游戏标题卡副标题（与游戏逐字一致，空串表示该版本无标题字段）；'
          '章节号 0 基，游戏内第一章通常对应第 0 章',
    };
  }

  Object _getMap(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final chapter = (a['chapter'] as num?)?.toInt() ?? 0;
    final map = MapReader(s.rom.rom).chapterMap(chapter);
    if (map == null) throw _ToolFailure('第 $chapter 章地图读不出来');
    return {
      'chapter': chapter,
      'width': map.width,
      'height': map.height,
      'tiles': map.tiles,
    };
  }

  Object _setMapTiles(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final chapter = (a['chapter'] as num?)?.toInt() ?? 0;
    final tiles = a['tiles'];
    if (tiles is! List) throw _ToolFailure('需要 tiles（砖块数组）');
    final out = MapWriter(s.rom)
        .write(chapter, [for (final t in tiles) (t as num).toInt()]);
    if (!out.ok) throw _ToolFailure(out.message);
    return {
      'written': out.newBytes,
      'original_bytes': out.originalBytes,
      'mode': out.mode.name,
      'changed_bytes': s.rom.changedByteCount,
    };
  }

  Object _listPortraits(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final reader = PortraitReader(s.rom.rom);
    final limit = (a['limit'] as num?)?.toInt() ?? 60;
    final out = <Map<String, Object?>>[];
    for (var i = 0; i < reader.entryCount && out.length < limit; i++) {
      if (!reader.hasImage(i)) continue;
      out.add({
        'id': i,
        'name': reader.nameFor(i),
        'usage': reader.usageOf(i),
        'half_body': reader.isHalfBody(i),
      });
    }
    reader.dispose();
    return {'version': s.versionId, 'portraits': out};
  }

  Object _portraitUsage(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final reader = PortraitReader(s.rom.rom);
    final id = (a['id'] as num?)?.toInt() ?? 0;
    final usage = reader.usageOf(id);
    final has = reader.hasImage(id);
    reader.dispose();
    return {'id': id, 'has_image': has, 'usage': usage};
  }

  Object _importPortrait(Map<String, dynamic> a) {
    final sourceVersion = a['source'];
    if (sourceVersion is! String) throw _ToolFailure('需要 source（源 ROM 版本，如 FE6）');
    final target = awaitSessionSync(a);
    final ws = _ws;
    final src = ws.sessions.where(
        (x) => x.versionId.toLowerCase() == sourceVersion.toLowerCase());
    if (src.isEmpty) throw _ToolFailure('没有打开源 ROM「$sourceVersion」');
    final source = src.first;
    if (source.id == target.id) throw _ToolFailure('源与目标不能是同一份 ROM');

    final srcId = (a['source_id'] as num?)?.toInt() ?? 0;
    final replaceInto = (a['target_id'] as num?)?.toInt();
    final reader = PortraitReader(source.rom.rom);
    final out = PortraitPorter(target.rom)
        .port(reader, srcId, replaceTargetId: replaceInto);
    reader.dispose();
    if (!out.ok) throw _ToolFailure(out.message);
    return {
      'target_id': out.targetId,
      'bytes_written': out.bytesWritten,
      'replaced': replaceInto != null,
      'changed_bytes': target.rom.changedByteCount,
    };
  }

  /// 肖像导出为 base64 PNG。
  ///
  /// 名字可能因汉化版同音字而看不出是谁，给图 AI 才能真正判断
  /// 「这张脸是不是同一个角色」。
  Object _portraitPng(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final id = (a['id'] as num?)?.toInt() ?? 0;
    final kind = (a['kind'] as String?) ?? 'face';
    final reader = PortraitReader(s.rom.liveRom);
    final tile = switch (kind) {
      'mouth_frame' => reader.mouthFrame(id, (a['frame'] as num?)?.toInt() ?? 1),
      'eye_half' => reader.eyeFrame(id, closed: false),
      'eye_closed' => reader.eyeFrame(id, closed: true),
      'map_face' => reader.mapFaceImage(id),
      'class_card' => reader.classCardImage(id),
      _ => reader.faceImage(id),
    };
    final usage = reader.usageOf(id);
    reader.dispose();
    if (tile == null) {
      throw _ToolFailure('肖像 $id 没有「$kind」图像（可用 face / map_face / class_card）');
    }
    return {
      'id': id,
      'kind': kind,
      'usage': usage,
      'width': tile.width,
      'height': tile.height,
      'mime': 'image/png',
      'base64': base64Encode(encodePng(tile)),
    };
  }

  /// 战斗动画某一帧导出为 base64 PNG。
  Object _animFramePng(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final id = (a['id'] as num?)?.toInt() ?? 0;
    final modeIndex = (a['mode'] as num?)?.toInt() ?? 0;
    final frame = (a['frame'] as num?)?.toInt() ?? 0;
    final paletteGroup = (a['palette'] as num?)?.toInt() ?? 0;
    final r = BattleAnimReader(s.rom.liveRom);
    final e = r.entry(id);
    if (e == null) throw _ToolFailure('没有第 $id 条战斗动画');
    final modes = r.modesOf(e);
    if (modes.isEmpty) throw _ToolFailure('第 $id 条动画的模式表读不出来');
    final mode = modes.where((m) => m.index == modeIndex).firstOrNull;
    if (mode == null) {
      throw _ToolFailure('模式 $modeIndex 不存在（可用：${modes.map((m) => m.index).join('、')}）');
    }
    final img = r.renderFrame(e, mode, frame, paletteGroup: paletteGroup);
    if (img == null) {
      throw _ToolFailure('渲染失败：模式 $modeIndex 第 $frame 帧（共 ${r.framesOf(e, mode).length} 帧）');
    }
    return {
      'id': id,
      'abbr': e.abbr,
      'mode': modeIndex,
      'frame': frame,
      'frames': r.framesOf(e, mode).length,
      'width': img.width,
      'height': img.height,
      'mime': 'image/png',
      'base64': base64Encode(encodePng(img)),
    };
  }

  Object _listBattleAnims(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final r = BattleAnimReader(s.rom.rom);
    if (!r.available) throw _ToolFailure('该版本没有战斗动画表');
    final out = <Map<String, Object?>>[];
    for (final e in r.entries) {
      out.add({
        'id': e.id,
        'abbr': e.abbr,
        'modes': r.modesOf(e).length,
      });
    }
    return {'version': s.versionId, 'total': out.length, 'anims': out};
  }

  Object _importBattleAnim(Map<String, dynamic> a) {
    final sourceVersion = a['source'];
    if (sourceVersion is! String) throw _ToolFailure('需要 source（源 ROM 版本）');
    final target = awaitSessionSync(a);
    final ws = _ws;
    final src = ws.sessions.where(
        (x) => x.versionId.toLowerCase() == sourceVersion.toLowerCase());
    if (src.isEmpty) throw _ToolFailure('没有打开源 ROM「$sourceVersion」');
    final source = src.first;
    if (source.id == target.id) throw _ToolFailure('源与目标不能是同一份 ROM');

    final srcId = (a['source_id'] as num?)?.toInt() ?? 0;
    final replaceInto = (a['target_id'] as num?)?.toInt();
    final out = BattleAnimPorter(target.rom).port(
        BattleAnimReader(source.rom.rom), srcId,
        replaceTargetId: replaceInto);
    if (!out.ok) throw _ToolFailure(out.message);
    return {
      'target_id': out.targetId,
      'sheets': out.sheets,
      'bytes_written': out.bytesWritten,
      'replaced': replaceInto != null,
      'changed_bytes': target.rom.changedByteCount,
    };
  }

  /// 按场景列出某章对话（一场戏 → 一句一句）。
  ///
  /// 与 `list_chapter_dialogs` 的区别：那个只给 ID 与整段预览，
  /// 这个把每条切成句子，AI 能定位到「第 3 场第 2 句」而不是面对一整块占位符。
  Object _listChapterScenes(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final chapter = (a['chapter'] as num?)?.toInt() ?? 0;
    final limit = ((a['limit'] as num?)?.toInt() ?? 50).clamp(1, 300);
    final script = DialogScript.of(s.rom, chapter);
    final title = UnitPlacement(s.rom).chapterTitle(chapter);
    return {
      'version': s.versionId,
      'chapter': chapter,
      'title': title,
      'count': script.scenes.length,
      'note': '一个「scene」= 一条文本记录（游戏里连续推进的一段）。'
          'lines 已按控制码切好句，写回仍用 write_text(text_id, 整段 raw)。'
          'raw 里的〔XX〕占位符必须原样保留。',
      'scenes': [
        for (final sc in script.scenes.take(limit))
          {
            'text_id': sc.textId,
            'lines': [
              for (final l in sc.lines.where((l) => !l.isEmpty)) l.text,
            ],
            'raw': sc.raw,
          }
      ],
    };
  }

  /// 对话预览：AI 改完一段对话后自查用（文本 ID 对不对、控制码有没丢、说话人是谁）。
  ///
  /// 注意行为边界（与界面上的横幅一致）：这里返回的是**工具解析结果**，
  /// 不是游戏实际画面。只做数据自洽校验（文本 ID 存在、头像索引有效），
  /// 不做游戏行为断言。
  Object _previewDialog(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final chapter = (a['chapter'] as num?)?.toInt() ?? 0;
    final limit = ((a['limit'] as num?)?.toInt() ?? 40).clamp(1, 500);
    final compact = a['compact'] != false; // 默认精简
    final p = DialogPreviewer(s.rom).of(chapter);
    final json = p.toJson();
    final all = (json['lines'] as List).cast<Map<String, Object?>>();
    final lines = all.take(limit).map((l) {
      if (!compact) return l;
      // 精简：去掉 raw（整段占位符串，单行就上千字符）与 source 字段，
      // 只留自查真正需要的：文本 ID / 句子 / 控制码数 / 问题。
      return <String, Object?>{
        'text_id': l['text_id'],
        'line': l['line'],
        'text': l['text'],
        'control_count': (l['control_tokens'] as List).length,
        if (l['issues'] != null) 'issues': l['issues'],
      };
    }).toList();
    return {
      ...json,
      'lines': lines,
      'truncated': all.length > limit,
      if (compact)
        'compact': true,
      if (compact)
        'note': 'compact 模式：已略去 raw 与控制码明细。'
            '要完整内容（raw / control_tokens / speaker_source）传 compact: false。',
      'boundary': previewBoundaryNote,
    };
  }

  /// 事件触发预览：一行自然语言 + 单位明细。改完坐标/道具后自查用。
  Object _previewEvents(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final chapter = (a['chapter'] as num?)?.toInt() ?? 0;
    final p = EventPreviewer(s.rom).of(chapter);
    final compact = a['compact'] != false; // 默认精简
    final json = p.toJson();
    if (compact) {
      // 精简模式：单位明细只留「坐标/角色/等级/阵营」与名字，
      // 去掉重复的道具名、class_name 与 allegiance_name
      // （sentence 里已经有自然语言描述，明细再全量展开会白白撑大响应）。
      final events = (json['events'] as List).cast<Map<String, Object?>>();
      json['events'] = [
        for (final e in events)
          {
            'kind': e['kind'],
            'condition': e['condition'],
            'sentence': e['sentence'],
            'units': [
              for (final u in (e['units'] as List).cast<Map<String, Object?>>())
                {
                  'char_id': u['char_id'],
                  'name': u['name'],
                  'level': u['level'],
                  'x': u['x'],
                  'y': u['y'],
                  'allegiance': u['allegiance'],
                  if ((u['items'] as List).any((i) => i != 0))
                    'items': u['items'],
                }
            ],
            if (e['issues'] != null) 'issues': e['issues'],
          }
      ];
      json['compact'] = true;
      json['note'] = 'compact 模式：单位明细只留关键字段。'
          '要完整字段（class_name/item_names/allegiance_name）传 compact: false。';
    }
    return {
      ...json,
      'boundary': previewBoundaryNote,
    };
  }

  /// 追加一条章节事件（只追加、不改既有脚本）。
  Future<Object> _addChapterEvent(Map<String, dynamic> a) async {
    final s = awaitSessionSync(a);
    final chapter = (a['chapter'] as num?)?.toInt() ?? 0;
    final typeName = a['type'] as String? ?? 'turn';
    final type = EventTriggerType.values.where((t) => t.name == typeName).firstOrNull;
    if (type == null) {
      throw _ToolFailure('未知触发类型「$typeName」，可用：'
          '${EventTriggerType.values.map((t) => t.name).join('、')}');
    }
    final rawUnits = a['units'];
    if (rawUnits is! List || rawUnits.isEmpty) {
      throw _ToolFailure('需要 units（至少一个单位）');
    }
    final units = <ReinforcementUnit>[];
    for (final item in rawUnits) {
      if (item is! Map) throw _ToolFailure('units 的每一项必须是对象');
      final items = <int>[];
      final rawItems = item['items'];
      if (rawItems is List) {
        for (final x in rawItems) {
          if (x is num) items.add(x.toInt());
        }
      }
      units.add(ReinforcementUnit(
        charId: (item['char_id'] as num?)?.toInt() ?? 0,
        classId: (item['class_id'] as num?)?.toInt() ?? 0,
        level: (item['level'] as num?)?.toInt() ?? 1,
        x: (item['x'] as num?)?.toInt() ?? 0,
        y: (item['y'] as num?)?.toInt() ?? 0,
        allegiance: (item['allegiance'] as num?)?.toInt() ?? 2,
        items: items,
      ));
    }

    final editor = ChapterEventEditor(s.rom);
    final dialogueTextId = (a['dialogue_text_id'] as num?)?.toInt() ?? 0;
    final EventEditOutcome out;
    switch (type) {
      case EventTriggerType.turn:
        final turn = (a['turn'] as num?)?.toInt() ?? 0;
        out = editor.addTurnReinforcement(chapter: chapter, turn: turn,
            units: units, dialogueTextId: dialogueTextId);
      case EventTriggerType.character:
        final charA = (a['char_a'] as num?)?.toInt() ?? 0;
        final charB = (a['char_b'] as num?)?.toInt() ?? 0;
        out = editor.addCharacterEvent(chapter: chapter, charA: charA,
            charB: charB, units: units, dialogueTextId: dialogueTextId);
      case EventTriggerType.location:
        final x = (a['x'] as num?)?.toInt() ?? 0;
        final y = (a['y'] as num?)?.toInt() ?? 0;
        out = editor.addLocationEvent(chapter: chapter, x: x, y: y,
            units: units, dialogueTextId: dialogueTextId);
      case EventTriggerType.chest:
      case EventTriggerType.shop:
        throw _ToolFailure('该类型暂不支持追加。改宝箱奖励/商店卖品请用 '
            'set_chest_item / set_shop_item（原地改，风险低）');
    }
    if (!out.ok) throw _ToolFailure(out.message);
    return {
      ...out.toJson(),
      'chapter': chapter,
      'type': type.name,
      'changed_bytes': s.rom.changedByteCount,
      'next': '用 preview_events 核对新事件是否在列表里；'
          '游戏里是否真的触发要靠模拟器/实机',
    };
  }

  /// 删除本工具追加的最后一条事件（靠特征自证，不是自己加的就拒绝）。
  Future<Object> _removeLastChapterEvent(Map<String, dynamic> a) async {
    final s = awaitSessionSync(a);
    final chapter = (a['chapter'] as num?)?.toInt() ?? 0;
    final typeName = a['type'] as String? ?? 'turn';
    final type = EventTriggerType.values.where((t) => t.name == typeName).firstOrNull;
    if (type == null) {
      throw _ToolFailure('未知触发类型「$typeName」');
    }
    final out = ChapterEventEditor(s.rom)
        .removeLastAdded(chapter: chapter, type: type);
    if (!out.ok) throw _ToolFailure(out.message);
    return {
      ...out.toJson(),
      'chapter': chapter,
      'type': type.name,
      'changed_bytes': s.rom.changedByteCount,
    };
  }

  /// 预览的行为边界（界面横幅与 MCP 返回值共用同一句话，避免两边说法不一致）。
  static const String previewBoundaryNote =
      '这是工具根据 ROM 数据渲染的预览，不是游戏实际运行画面。'
          '只校验数据自洽（文本 ID / 坐标 / 角色职业道具是否在表内），'
          '不校验游戏行为（这段对话真会在第 3 回合触发吗、演出效果对不对）。'
          '要确认「游戏里真的对不对」，请导出后用模拟器 / 实机验证。';

  /// 检查一段文本在该 ROM 上缺哪些字。
  ///
  /// 写对话前先查——「写完才发现有字显示成空白」是最难自查的失败，
  /// 因为它不会报错，只会少几个字。
  Object _checkTextCoverage(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final text = a['text'];
    if (text is! String || text.isEmpty) throw _ToolFailure('需要 text（要检查的文字）');
    final checker = TextCoverageChecker(TextWriter(s.rom));
    final r = checker.check(text);
    return {
      'version': s.versionId,
      'engine': checker.engineLabel,
      'charset': {
        'label': checker.charset.label,
        'size': checker.charset.count,
        'note': checker.charset.note,
      },
      ...r.toJson(),
      if (!r.ok) 'advice': _coverageAdvice(s, r),
    };
  }

  /// 缺字时给可执行的建议，而不是只报缺失。
  static String _coverageAdvice(RomSession s, TextCoverage r) {
    if (!r.writable) {
      return '该 ROM 的文本引擎未识别，无法写入。换用烈火之剑 Superxyj 汉化版'
          '（明文 GBK）或圣魔日版作基底。';
    }
    final sb = StringBuffer()
      ..write('缺 ${r.missing.length} 个字（${r.missing.join('、')}）。');
    if (s.generation == 7) {
      sb.write('烈火之剑改用 Superxyj 汉化版作基底（明文 GBK，常用汉字全覆盖）即可解决；');
    } else if (s.generation == 8) {
      sb.write('圣魔之光石建议改用日版或带 GBK 的改版作基底；');
    }
    sb.write('也可以换用同义词/近似字改写这几处。');
    return sb.toString();
  }

  /// 列出外部工作区里的 ROM（AI 自己挑基底用）。
  Future<Object> _listWorkspaceRoms(Map<String, dynamic> a) async {
    final ws = ExternalWorkspace.instance;
    final dir = ws.dir;
    if (dir == null) {
      return {
        'configured': false,
        'roms': const [],
        'hint': '还没设置外部工作区。让用户在 App 主页点「设置工作区」选一个存放 ROM 的目录，'
            '之后这里会列出目录里的 .gba 文件。',
      };
    }
    final roms = await ws.listRoms();
    return {
      'configured': true,
      'dir_name': dir.name,
      'dir_uri': dir.uri,
      'count': roms.length,
      'roms': [for (final r in roms) r.toJson()],
    };
  }

  /// 从外部工作区打开一个 ROM（按文件名）。
  ///
  /// 这是「AI 自己找 ROM」的入口：先 list_workspace_roms，再按名字打开。
  Future<Object> _openWorkspaceRom(Map<String, dynamic> a) async {
    final name = a['name'];
    if (name is! String || name.isEmpty) {
      throw _ToolFailure('需要 name（工作区里的 ROM 文件名，先用 list_workspace_roms 看）');
    }
    final ws = ExternalWorkspace.instance;
    if (!ws.configured) {
      throw _ToolFailure('还没设置外部工作区，先在 App 主页点「设置工作区」选一个目录');
    }
    final data = await ws.readRom(name);
    if (data == null) {
      final available = await ws.listRoms();
      throw _ToolFailure('读不到「$name」。工作区现有：'
          '${available.map((r) => r.name).join('、')}');
    }
    final w = _workspace;
    if (w == null) throw _ToolFailure('工作区未绑定（App 界面未就绪）');
    final session = await w.open(data, name);
    if (session == null) {
      throw _ToolFailure('「$name」不是可识别的火纹 ROM');
    }
    return {
      'opened': name,
      'version': session.versionId,
      'size': data.length,
      'encoding': session.liveRom.textEncoding.name,
      'text_writable': session.textWritable,
      'sessions': w.sessions.length,
    };
  }

  /// 列出素材库目录里的文件。与外部工作区对称：
  /// 目录路径(dir_uri)、显示名、文件清单都交给 AI 自己看。
  Future<Object> _listAssetLibrary(Map<String, dynamic> a) async {
    final lib = AssetLibrary.instance;
    final dir = lib.dir;
    if (dir == null) {
      return {
        'configured': false,
        'assets': const [],
        'hint': '还没设置素材库。让用户在 App 里选一个素材库目录（存导出肖像/动画帧等），'
            '之后这里会列出目录里的文件。',
      };
    }
    final files = await lib.list();
    final limit = (a['limit'] as num?)?.toInt() ?? 100;
    return {
      'configured': true,
      'dir_name': dir.name,
      'dir_uri': dir.uri,
      'count': files.length,
      'assets': [for (final f in files.take(limit)) f.toJson()],
      if (files.length > limit) 'truncated': true,
    };
  }

  /// 读素材库里的一个文件（base64 返回，AI 可直接看图 / 读内容）。
  Future<Object> _readAsset(Map<String, dynamic> a) async {
    final lib = AssetLibrary.instance;
    final name = a['name'] as String?;
    if (name == null || name.isEmpty) {
      throw _ToolFailure('需要 name（素材库里的文件名，先用 list_asset_library 看）');
    }
    if (lib.dir == null) {
      throw _ToolFailure('还没设置素材库，先让用户在 App 里选一个素材库目录');
    }
    final maxBytes = (a['max_bytes'] as num?)?.toInt() ?? 512000;
    final data = await lib.read(name);
    if (data == null) {
      final files = await lib.list();
      throw _ToolFailure('读不到素材「$name」。素材库现有：'
          '${files.map((f) => f.name).join('、')}');
    }
    if (data.length > maxBytes) {
      throw _ToolFailure(
          '素材「$name」是 ${data.length} 字节，超过 max_bytes=$maxBytes，'
          'base64 会撑爆响应。调大 max_bytes 再试，或先确认它确实是你要的文件');
    }
    return {
      'name': name,
      'size': data.length,
      'mime': _guessMime(name),
      'base64': base64Encode(data),
    };
  }

  /// 把一份素材写进素材库（同名原地覆盖）。图片给 base64、文本给 text。
  /// 不碰 ROM 会话，因此不走通用 dry_run。
  Future<Object> _writeAsset(Map<String, dynamic> a) async {
    final lib = AssetLibrary.instance;
    final name = a['name'] as String?;
    if (name == null || name.isEmpty) {
      throw _ToolFailure('需要 name（要写入的文件名，如 lyn.png）');
    }
    if (lib.dir == null) {
      throw _ToolFailure('还没设置素材库，先让用户在 App 里选一个素材库目录');
    }
    final b64 = a['base64'] as String?;
    final text = a['text'] as String?;
    final Uint8List bytes;
    if (b64 != null && b64.isNotEmpty) {
      try {
        bytes = Uint8List.fromList(base64Decode(b64));
      } catch (_) {
        throw _ToolFailure('base64 不是合法编码');
      }
    } else if (text != null) {
      bytes = Uint8List.fromList(utf8.encode(text));
    } else {
      throw _ToolFailure('需要 base64（图片等二进制）或 text（文本）之一作为内容');
    }
    final ok = await lib.write(name, bytes);
    if (!ok) {
      throw _ToolFailure('写入素材库失败：${lib.lastError ?? '未知原因'}');
    }
    return {
      'ok': true,
      'name': name,
      'size': bytes.length,
      'mime': _guessMime(name),
    };
  }

  // ---------------- AssetStore（handle 通道） ----------------
  //
  // 纪律：这一组工具**任何返回值都不得含内容**（不返回 base64 / bytes），
  // 否则就退化回「AI 搬运字节」，大文件必撞墙。测试里有断言锁住。

  /// 当前会话对应的项目素材仓库。项目 ID = ROM 指纹。
  AssetStore _storeFor(RomSession s) {
    final project = s.fingerprint.toRadixString(16).padLeft(16, '0');
    return assetStoreFactory?.call(project) ?? AssetStore(project: project);
  }

  Future<Object> _listAssets(Map<String, dynamic> a) async {
    final s = awaitSessionSync(a);
    final store = _storeFor(s);
    final type = a['type'] as String?;
    final assets = await store.list(type: type);
    final used = await store.totalBytes();
    return {
      'project': store.project,
      'count': assets.length,
      'total_bytes': used,
      'assets': [for (final x in assets) x.toJson()],
      if (type == null)
        'hint': '想只列某一类就给 type（image / portrait_sheet / map_plan / audio / binary）',
    };
  }

  Future<Object> _assetInfo(Map<String, dynamic> a) async {
    final s = awaitSessionSync(a);
    final handle = (a['handle'] as String?)?.trim();
    if (handle == null || handle.isEmpty) {
      throw _ToolFailure('需要 handle（先用 list_assets 看有哪些）');
    }
    final asset = await _storeFor(s).info(handle);
    if (asset == null) throw _ToolFailure('没有 handle 为「$handle」的素材');
    return asset.toJson();
  }

  /// 从素材库（SAF）导入一份素材到项目 AssetStore，返回 handle。
  /// 字节全程在原生侧走，**不经过 AI**，所以 1MB 的图也一步入库。
  Future<Object> _importAssetFromLibrary(Map<String, dynamic> a) async {
    final s = awaitSessionSync(a);
    final name = (a['name'] as String?)?.trim();
    if (name == null || name.isEmpty) {
      throw _ToolFailure('需要 name（素材库里的文件名，先用 list_asset_library 看）');
    }
    try {
      final asset = await _storeFor(s).importFromLibrary(name);
      return {...asset.toJson(), 'imported_from': 'library'};
    } on AssetStoreException catch (e) {
      throw _ToolFailure(e.message);
    }
  }

  /// 解析 source 参数（同样兼容 JSON 字符串与对象）。
  Map<String, dynamic> _jsonMapOf(Object? raw, String name) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        throw _ToolFailure('$name 不是合法 JSON：$raw');
      }
    }
    throw _ToolFailure('需要 $name，例如 {"kind":"portrait_png","id":11}');
  }

  /// 解析 target 参数：既接受 JSON 字符串（AI 常这么传），也接受对象。
  Map<String, dynamic> _targetOf(Map<String, dynamic> a) {
    final raw = a['target'];
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        throw _ToolFailure('target 不是合法 JSON：$raw');
      }
    }
    throw _ToolFailure('需要 target，例如 {"kind":"portrait","id":11}');
  }

  /// 把一个素材（handle）写进 ROM。目前支持 portrait（写到肖像表条目）。
  Future<Object> _importAsset(Map<String, dynamic> a) async {
    final s = awaitSessionSync(a);
    final handle = (a['handle'] as String?)?.trim();
    if (handle == null || handle.isEmpty) {
      throw _ToolFailure('需要 handle（先用 list_assets / import_asset_from_library 拿）');
    }
    final target = _targetOf(a);
    final kind = (target['kind'] as String?)?.trim();
    if (kind != 'portrait') {
      throw _ToolFailure('现在只支持 kind=portrait（target: {kind:"portrait", id:<肖像ID>}）；'
          '地图与音频的 Converter 还没接上');
    }
    final portraitId = (target['id'] as num?)?.toInt();
    if (portraitId == null) throw _ToolFailure('portrait 需要 target.id（肖像 ID）');

    final store = _storeFor(s);
    final asset = await store.info(handle);
    if (asset == null) throw _ToolFailure('没有 handle 为「$handle」的素材');
    final bytes = await store.read(handle);
    if (bytes == null) throw _ToolFailure('读不到素材内容（$handle）');

    final dry = _dryRun(a);
    final converted = Converters.portraitFromPng(
      bytes,
      fe6: s.rom.rom.table.portraitDataSize == 16,
      mapFace: a['map_face'] != false,
    );
    if (converted == null) {
      throw _ToolFailure('这份素材不是可解码的 PNG（8 位非交错 RGB/RGBA/灰度/调色板）');
    }
    final out = PortraitPorter(s.rom).importFace(
      converted.data,
      portraitId,
      fixedExpression: a['fixed_expression'] != false,
      replaceMapFace: a['map_face'] != false,
    );
    if (!out.ok) throw _ToolFailure(out.message);
    await store.addRef(handle, '${s.versionId}:portrait:$portraitId');
    return {
      'dry_run': dry,
      'handle': handle,
      'target': {'kind': 'portrait', 'id': portraitId},
      'entry_address': out.entryAddress,
      'bytes_written': out.bytesWritten,
      'conversion': converted.summary(),
      'ref': '${s.versionId}:portrait:$portraitId',
      'changed_bytes': s.rom.changedByteCount,
    };
  }

  /// 把 ROM 里的素材导出成 AssetStore 里的一个 handle（不返回字节）。
  Future<Object> _exportAssetFromRom(Map<String, dynamic> a) async {
    final s = awaitSessionSync(a);
    final source = _jsonMapOf(a['source'], 'source');
    final kind = (source['kind'] as String?)?.trim();
    if (kind != 'portrait_png' && kind != 'battle_anim_frame') {
      throw _ToolFailure('source.kind 目前支持 portrait_png / battle_anim_frame');
    }
    final Uint8List png;
    String name;
    if (kind == 'portrait_png') {
      final id = (source['id'] as num?)?.toInt() ?? 0;
      final imageKind = (source['image'] as String?) ?? 'face';
      final reader = PortraitReader(s.rom.liveRom);
      final tile = switch (imageKind) {
        'map_face' => reader.mapFaceImage(id),
        'class_card' => reader.classCardImage(id),
        _ => reader.faceImage(id),
      };
      reader.dispose();
      if (tile == null) throw _ToolFailure('肖像 $id 没有「$imageKind」图像');
      png = encodePng(tile);
      name = 'portrait_${id.toString().padLeft(3, '0')}_$imageKind.png';
    } else {
      final id = (source['id'] as num?)?.toInt() ?? 0;
      final modeIndex = (source['mode'] as num?)?.toInt() ?? 0;
      final frame = (source['frame'] as num?)?.toInt() ?? 0;
      final group = (source['palette'] as num?)?.toInt() ?? 0;
      final r = BattleAnimReader(s.rom.liveRom);
      final e = r.entry(id);
      if (e == null) throw _ToolFailure('没有第 $id 条战斗动画');
      final modes = r.modesOf(e);
      final mode = modes.where((m) => m.index == modeIndex).firstOrNull;
      if (mode == null) throw _ToolFailure('模式 $modeIndex 不存在');
      final img = r.renderFrame(e, mode, frame, paletteGroup: group);
      if (img == null) throw _ToolFailure('渲染失败：模式 $modeIndex 第 $frame 帧');
      png = encodePng(img);
      name = 'anim_${e.abbr}_${modeIndex}_$frame.png';
    }
    final store = _storeFor(s);
    final asset = await store.put(
      png,
      type: 'image',
      mime: 'image/png',
      origin: 'export',
      sourceName: name,
    );
    return {...asset.toJson(), 'exported_from': kind};
  }

  /// 跨会话直连：把一份素材（handle）搬到另一个已打开的 ROM 并写入。
  /// 全程内存，不落盘、不经 AI。
  Future<Object> _copyAssetBetweenSessions(Map<String, dynamic> a) async {
    final ws = _workspace;
    if (ws == null || ws.isEmpty) throw _ToolFailure('还没有打开任何 ROM');
    final handle = (a['handle'] as String?)?.trim();
    if (handle == null || handle.isEmpty) throw _ToolFailure('需要 handle');
    final toVersion = (a['to'] as String?)?.trim();
    if (toVersion == null || toVersion.isEmpty) {
      throw _ToolFailure('需要 to（目标 ROM 版本代号，如 FE8U）');
    }
    final target = ws.sessions
        .where((s) => s.versionId.toLowerCase() == toVersion.toLowerCase())
        .firstOrNull;
    if (target == null) {
      throw _ToolFailure('没有打开版本为「$toVersion」的 ROM。'
          '已打开：${ws.sessions.map((s) => s.versionId).join('、')}');
    }
    final dest = _targetOf(a);
    if ((dest['kind'] as String?) != 'portrait') {
      throw _ToolFailure('现在只支持 target: {kind:"portrait", id:<肖像ID>}');
    }
    final id = (dest['id'] as num?)?.toInt();
    if (id == null) throw _ToolFailure('portrait 需要 target.id');

    var asset = await _storeFor(target).info(handle);
    Uint8List? bytes = asset == null ? null : await _storeFor(target).read(handle);
    if (bytes == null) {
      for (final other in ws.sessions) {
        final st = _storeFor(other);
        final found = await st.info(handle);
        if (found != null) {
          asset = found;
          bytes = await st.read(handle);
          break;
        }
      }
    }
    if (asset == null || bytes == null) {
      throw _ToolFailure('没有 handle 为「$handle」的素材（项目间不共享素材）');
    }
    final converted = Converters.portraitFromPng(
      bytes,
      fe6: target.rom.rom.table.portraitDataSize == 16,
      mapFace: a['map_face'] != false,
    );
    if (converted == null) throw _ToolFailure('素材不是可解码的 PNG');
    final out = PortraitPorter(target.rom).importFace(
      converted.data,
      id,
      fixedExpression: a['fixed_expression'] != false,
      replaceMapFace: a['map_face'] != false,
    );
    if (!out.ok) throw _ToolFailure(out.message);
    // 目标项目自己也得留下这条素材：不然它记录了引用、却没有任何素材本体。
    // 跨会话不共享仓库，所以这里把字节落进目标项目的 AssetStore（同内容去重）。
    final destStore = _storeFor(target);
    await destStore.put(
      bytes,
      type: asset.type,
      mime: asset.mime,
      origin: 'copy_from_${ws.active?.versionId ?? 'other'}',
      sourceName: asset.sourceName,
    );
    await destStore.addRef(handle, '${target.versionId}:portrait:$id');
    return {
      'handle': handle,
      'to': target.versionId,
      'target': {'kind': 'portrait', 'id': id},
      'bytes_written': out.bytesWritten,
      'conversion': converted.summary(),
    };
  }

  Future<Object> _deleteAsset(Map<String, dynamic> a) async {
    final s = awaitSessionSync(a);
    final handle = (a['handle'] as String?)?.trim();
    if (handle == null || handle.isEmpty) throw _ToolFailure('需要 handle');
    try {
      await _storeFor(s).delete(handle, force: a['force'] == true);
      return {'deleted': handle, 'force': a['force'] == true};
    } on AssetStoreException catch (e) {
      throw _ToolFailure(e.message);
    }
  }

  /// 按扩展名猜 MIME（给客户端 / AI 判断内容类型）。
  String _guessMime(String name) {
    final l = name.toLowerCase();
    if (l.endsWith('.png')) return 'image/png';
    if (l.endsWith('.jpg') || l.endsWith('.jpeg')) return 'image/jpeg';
    if (l.endsWith('.webp')) return 'image/webp';
    if (l.endsWith('.gif')) return 'image/gif';
    if (l.endsWith('.txt') || l.endsWith('.md')) return 'text/plain';
    if (l.endsWith('.json')) return 'application/json';
    return 'application/octet-stream';
  }

  Object _readText(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    var id = (a['id'] as num?)?.toInt() ?? 0;
    final search = a['search'] as String?;
    final browser = TextBrowser(s.liveRom);

    if (search != null && search.isNotEmpty) {
      final limit = (a['count'] as num?)?.toInt() ?? 50;
      final hits = <Map<String, Object?>>[];
      for (var i = 0; i < 0x2000 && hits.length < limit; i++) {
        final t = browser.render(i);
        if (t.isNotEmpty && t.contains(search)) hits.add({'id': i, 'text': t});
      }
      return {'matches': hits, 'count': hits.length};
    }

    // 分页读：给 from 就批量返回。AI 看「角色名表前 60 条」这类需求
    // 靠一条条试 ID 太慢，这里一次给一段。
    final from = (a['from'] as num?)?.toInt();
    if (from != null) {
      final count = ((a['count'] as num?)?.toInt() ?? 30).clamp(1, 200);
      final maxId = browser.maxId;
      final out = <Map<String, Object?>>[];
      for (var i = from; i < from + count && i < maxId; i++) {
        final t = browser.render(i);
        out.add({'id': i, 'text': t});
      }
      return {
        'from': from,
        'count': out.length,
        'max_id': maxId,
        'items': out,
      };
    }

    final text = browser.render(id);
    return {'id': id, 'text': text, 'available': text.isNotEmpty};
  }

  Object _writeText(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final id = (a['id'] as num?)?.toInt() ?? 0;
    final text = a['text'];
    if (text is! String) throw _ToolFailure('需要 text（新内容）');
    final result = TextWriter(s.rom).write(id, text);
    if (!result.ok) throw _ToolFailure(result.message);
    return {
      'mode': result.mode.name,
      'original_bytes': result.originalBytes,
      'new_bytes': result.newBytes,
      'old_pointer': result.oldPointer >= 0 ? '0x${result.oldPointer.toRadixString(16)}' : null,
      'new_pointer': result.newPointer >= 0 ? '0x${result.newPointer.toRadixString(16)}' : null,
      'changed_bytes': s.rom.changedByteCount,
    };
  }

  /// 修改器预设清单。批量改成长率这类事走预设远比逐个 set_unit_field 稳。
  Object _listCheatPresets(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    return {
      'version': s.versionId,
      'presets': [
        for (final p in cheatPresets.where((p) => p.visible))
          {
            'id': p.id,
            'title': p.title,
            'description': p.description,
            'target': p.target.name,
            'scope_selectable': p.scopeSelectable,
            'values': p.values,
            // 组合预设（如 unit_full_suite）：按序应用这些子预设，
            // 让 AI 知道它一次做了哪几件事
            if (p.combo != null) 'combo': p.combo,
          }
      ],
      'criteria': [
        for (final c in PlayableCriterion.values) {'name': c.name, 'label': c.label},
      ],
    };
  }

  /// 列出某个判据下「算作我方」的角色索引。
  ///
  /// 修改器预设只作用在这份名单上；AI 想知道「为什么某个角色没被改」时查它。
  Object _listPlayable(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    var criterion = PlayableCriterion.reciprocal;
    final cname = a['criterion'];
    if (cname is String) {
      final m = PlayableCriterion.values.where((c) => c.name == cname);
      if (m.isEmpty) {
        throw _ToolFailure(
            '未知口径「$cname」。可用：${PlayableCriterion.values.map((c) => c.name).join('、')}');
      }
      criterion = m.first;
    }
    final pu = playableUnitsOf(s.liveRom);
    final scope = RosterScope(criterion: criterion, custom: _rosterFor(a, s));
    final ids = scope.effective(pu);
    final rom = s.liveRom;
    return {
      'criterion': criterion.name,
      'used_custom_roster': criterion == PlayableCriterion.custom,
      'count': ids.length,
      'units': [
        for (final i in ids)
          {
            'id': i,
            'name': rom.unitDisplayName(i).trim(),
            'has_support': s.rom.supportAddress(i) >= 0,
          }
      ],
      'criteria': [
        for (final c in PlayableCriterion.values) {'name': c.name, 'label': c.label},
      ],
    };
  }

  Object _applyCheatPreset(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final id = a['id'];
    if (id is! String) throw _ToolFailure('需要 id（预设 ID，见 list_cheat_presets）');
    final preset = cheatPresets.where((p) => p.id == id).firstOrNull;
    if (preset == null) {
      throw _ToolFailure(
          '没有预设「$id」。可用：${cheatPresets.map((p) => p.id).join('、')}');
    }
    var criterion = PlayableCriterion.reciprocal;
    final cname = a['criterion'];
    if (cname is String) {
      final m = PlayableCriterion.values.where((c) => c.name == cname);
      if (m.isEmpty) {
        throw _ToolFailure(
            '未知口径「$cname」。可用：${PlayableCriterion.values.map((c) => c.name).join('、')}');
      }
      criterion = m.first;
    }
    final rom = s.liveRom;
    final result = applyCheat(
      s.rom,
      preset,
      criterion: criterion,
      playable: playableUnitsOf(rom),
      custom: _rosterFor(a, s),
    );
    return {
      'preset': preset.id,
      'criterion': criterion.name,
      'changed_entries': result.changedEntries,
      'changed_bytes': result.changedBytes,
      'skipped': result.skipped,
    };
  }

  /// 找连续空闲区。AI 想写入新数据（搬素材、插文本）时得先知道哪儿有空。
  Object _findFreeSpace(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final need = ((a['size'] as num?)?.toInt() ?? 1024).clamp(1, 1 << 22);
    final limit = (a['limit'] as num?)?.toInt() ?? 8;
    final fill = (a['fill'] as num?)?.toInt();
    final view = HexView(s.rom.buffer);
    final out = <Map<String, Object?>>[];
    const romLimit = 0x02000000;
    for (final f in [if (fill != null) fill else 0xFF, if (fill == null) 0x00]) {
      var from = 0;
      while (from < s.rom.buffer.length && from < romLimit && out.length < limit) {
        final run = view.findFreeRun(from, fill: f, minLength: need);
        if (run == null) break;
        final aligned = run.offset + ((4 - (run.offset % 4)) % 4);
        if (aligned + need <= run.offset + run.length) {
          out.add({
            'offset': aligned,
            'gba': 0x08000000 + aligned,
            'length': run.length,
            'fill': f,
          });
        }
        from = run.offset + run.length;
      }
      if (out.length >= limit) break;
    }
    return {
      'size': need,
      'found': out.length,
      'regions': out,
      'rom_size': s.rom.buffer.length,
    };
  }

  Object _readHex(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final offset = (a['offset'] as num?)?.toInt() ?? 0;
    final length = ((a['length'] as num?)?.toInt() ?? 32).clamp(1, 4096);
    if (offset < 0 || offset + length > s.rom.buffer.length) {
      throw _ToolFailure('越界：rom 大小 ${s.rom.buffer.length}');
    }
    final d = s.rom.buffer.data;
    return {
      'offset': offset,
      'bytes': [for (var i = 0; i < length; i++) d[offset + i]],
      'hex': [
        for (var i = 0; i < length; i++)
          d[offset + i].toRadixString(16).padLeft(2, '0')
      ].join(' '),
    };
  }

  Object _writeHex(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final offset = (a['offset'] as num?)?.toInt() ?? -1;
    final bytes = a['bytes'];
    if (offset < 0 || bytes is! List) {
      throw _ToolFailure('需要 offset（非负整数）与 bytes（字节数组）');
    }
    final list = [for (final b in bytes) (b as num).toInt() & 0xFF];
    if (offset + list.length > s.rom.buffer.length) {
      throw _ToolFailure('越界：rom 大小 ${s.rom.buffer.length}');
    }
    if (_dryRun(a)) {
      final patch = <Map<String, Object>>[];
      for (var i = 0; i < list.length; i++) {
        final at = offset + i;
        final before = s.rom.buffer.u8(at);
        if (before == list[i]) continue;
        patch.add({'offset': at, 'before': before, 'after': list[i]});
      }
      return {
        'dry_run': true,
        'changed': patch.length,
        if (patch.isNotEmpty) 'patch': patch.take(64).toList(),
        'truncated': patch.length > 64,
      };
    }
    final changed = s.rom.writeBytes(offset, list);
    return {'changed': changed, 'changed_bytes': s.rom.changedByteCount};
  }

  Object _listChapterEvents(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final chapter = (a['chapter'] as num?)?.toInt() ?? 0;
    final units = UnitPlacement(s.rom);
    final ev = units.eventGroupOffset(chapter);
    if (ev <= 0) throw _ToolFailure('第 $chapter 章没有可读的事件组');
    final events = ChapterEvents(s.liveRom)
      ..itemNameOf = (id) => s.liveRom.itemDisplayName(id);
    final rows = <Map<String, Object?>>[];
    for (final e in events.all(ev)) {
      rows.add({
        'kind': e.kind.name,
        'condition': e.condition,
        'script': e.script,
        'units': [
          for (final u in events.loadedUnits(e.script))
            {
              'addr': u.addr,
              'char_id': u.charId,
              'class_id': u.classId,
              'x': u.x,
              'y': u.y,
              'allegiance': u.allegiance,
              'level': u.level,
              'items': u.items,
            }
        ],
      });
    }
    return {'chapter': chapter, 'events': rows};
  }

  /// 章节对话：提取该章事件脚本引用的文本 ID（只读；编辑走 [write_text]）。
  Object _listChapterDialogs(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final chapter = (a['chapter'] as num?)?.toInt() ?? 0;
    final limit = ((a['limit'] as num?)?.toInt() ?? 50).clamp(1, 300);
    final d = ChapterDialogues.of(s.rom, chapter);
    final writer = TextWriter(s.rom);
    final up = UnitPlacement(s.rom);
    final title = up.chapterTitle(chapter);
    return {
      'version': s.versionId,
      'chapter': chapter,
      'title': title,
      'note2': title.isNotEmpty
          ? '游戏内章节标题「$title」（标题卡副标题）；章节号 0 基，游戏内第一章通常对应第 0 章'
          : '章节号 0 基；游戏内第一章通常对应第 0 章',
      'count': d.dialogues.length,
      'writable': writer.supported,
      'edit_via': 'write_text',
      'note': 'preview 里的〔XX〕是控制码占位（换行/按键/颜色等），'
          '用 write_text 改写时保留它们；变长文本会自动重定位并更新指针',
      'items': [
        for (final e in d.dialogues.take(limit))
          {
            'id': e.textId,
            'address': 0x08000000 + e.address,
            'preview': writer.currentText(e.textId) ??
                s.liveRom.decodeText(e.textId),
          }
      ],
    };
  }

  Object _revert(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final before = s.rom.changedByteCount;
    s.rom.revertAll();
    return {'reverted_bytes': before, 'changed_bytes': 0};
  }

  Object _saveRom(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    // 返回 base64 让客户端自己落盘；不在这里弹系统「另存为」，
    // 因为那需要 UI 前台交互，MCP 调用不能阻塞在对话框上。
    final data = s.rom.buildOutput();
    return {
      'version': s.versionId,
      'size': data.length,
      'changed_bytes': s.rom.changedByteCount,
      'base64': base64Encode(data),
    };
  }

  /// MCP 调用用的自定义名单。
  ///
  /// **只有显式 `criterion: custom` 时才读用户在界面上手选的名单**。
  /// 其它判据一律按算法算——用户的名单是给界面「手工勾选」用的，
  /// 若默认套用，AI 会莫名其妙只改到那几十个人（实测踩过：
  /// 设备上残留一份 49 人的名单，导致主角 id 0 被排除在预设之外）。
  CustomRoster _rosterFor(Map<String, dynamic> a, RomSession s) {
    if (a['criterion'] != 'custom') return CustomRoster.empty;
    return AppSettings.instance.rosterFor(s.fingerprint);
  }

  /// 本次调用是否只是预演（不写 ROM）。
  bool _dryRun(Map<String, dynamic> a) => a['dry_run'] == true;

  int _clampFor(EditField f, int v) {
    if (f.nibbles) return v;
    return v.clamp(f.min, f.max);
  }

  /// 算出写这个字段会覆盖哪几个字节（偏移 + 原值 + 新值），供 dry run 展示。
  List<Map<String, Object>> _bytesFor(
      EditableRom rom, int baseAddr, EditField f, int newValue) {
    final addr = baseAddr + f.offset;
    final size = f.byteSize;
    if (!rom.buffer.inRange(addr, size)) return const [];
    final raw = newValue < 0 ? newValue + 0x100 : newValue;
    final out = <Map<String, Object>>[];
    for (var i = 0; i < size; i++) {
      final at = addr + i;
      final before = rom.buffer.u8(at);
      final after = (raw >> (8 * i)) & 0xFF;
      if (before == after) continue;
      out.add({'offset': at, 'before': before, 'after': after});
    }
    return out;
  }

  /// 改一个「事件脚本里动态生成」的单位（剧情增援/变节）。
  ///
  /// **只能原地覆盖**：事件脚本是字节码，插入或删除会改变后续所有 `CALL`
  /// 目标的位置，风险高一个量级。这里只改单位结构体自身的字段，
  /// 结构体地址与长度都不变，所以是安全的。
  Object _setEventUnit(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final addr = (a['addr'] as num?)?.toInt();
    final chars = a['char_id'];
    final level = a['level'];
    final x = a['x'];
    final y = a['y'];
    final allegiance = a['allegiance'];
    if (addr == null) {
      throw _ToolFailure(
          '需要 addr（单位结构体地址，取自 list_chapter_events 的 units[].addr）');
    }
    final isFe8 = s.generation == 8;
    final size = isFe8 ? 20 : 16;
    if (addr < 0 || addr + size > s.rom.buffer.length) {
      throw _ToolFailure('$addr 越界');
    }
    // 校验它真的像一条单位结构体：pid 非 0
    if (s.rom.buffer.u8(addr) == 0) {
      throw _ToolFailure('$addr 处不是单位结构体（pid=0 是终止符）');
    }
    final patch = <String, Object?>{};
    final dry = _dryRun(a);

    void writeU8(int at, int v, String label) {
      final before = s.rom.buffer.u8(at);
      if (before == v) return;
      patch[label] = {'offset': at, 'before': before, 'after': v};
      if (!dry) s.rom.writeBytes(at, [v]);
    }

    if (chars is num) writeU8(addr, chars.toInt().clamp(1, 0xFF), 'char_id');
    final classId = a['class_id'];
    if (classId is num) {
      writeU8(addr + 1, classId.toInt().clamp(0, 0xFF), 'class_id');
    }
    // 道具槽：4 个 u8，原地覆盖（FE8 在 +12，FE6/FE7 在 +8）
    final items = a['items'];
    if (items is List) {
      final itemsBase = addr + (isFe8 ? 12 : 8);
      for (var k = 0; k < items.length && k < 4; k++) {
        final v = items[k];
        if (v is! num) continue;
        writeU8(itemsBase + k, v.toInt().clamp(0, 0xFF), 'item${k + 1}');
      }
    }
    if (x is num || y is num || level is num || allegiance is num) {
      // grow 字节：bit0 未知，bit1-2 阵营，bit3-7 等级
      final growAt = addr + 3;
      final grow = s.rom.buffer.u8(growAt);
      var next = grow;
      if (allegiance is num) {
        next = (next & ~0x06) | ((allegiance.toInt() & 0x03) << 1);
      }
      if (level is num) {
        next = (next & ~0xF8) | ((level.toInt() & 0x1F) << 3);
      }
      writeU8(growAt, next, 'grow(allegiance+level)');

      if (isFe8) {
        final at = addr + 4;
        final packed = s.rom.buffer.u16(at);
        var nx = packed & 0x3F;
        var ny = (packed >> 6) & 0x3F;
        if (x is num) nx = x.toInt() & 0x3F;
        if (y is num) ny = y.toInt() & 0x3F;
        final v = nx | (ny << 6);
        if (v != packed) {
          patch['pos'] = {
            'offset': at,
            'before': packed,
            'after': v,
            'x': nx,
            'y': ny,
          };
          if (!dry) s.rom.writeBytes(at, [v & 0xFF, (v >> 8) & 0xFF]);
        }
      } else {
        if (x is num) writeU8(addr + 4, x.toInt() & 0xFF, 'x');
        if (y is num) writeU8(addr + 5, y.toInt() & 0xFF, 'y');
      }
    }

    var bytesToChange = 0;
    for (final label in patch.keys) {
      bytesToChange += (label == 'pos') ? 2 : 1;
    }
    return {
      'dry_run': dry,
      'addr': addr,
      'changes': patch,
      'changed_n': patch.length,
      'changed_bytes': dry ? bytesToChange : s.rom.changedByteCount,
    };
  }

  /// 改章节静态单位（`list_chapters` 列的初始单位，非事件动态生成的那批）。
  ///
  /// 与 [set_chapter_event_unit] 的区别：这里按「章节 + 入口 + 序号」定位条目，
  /// 不需要 AI 自己取结构体地址。**同样只做原地字段覆盖**，不增删。
  Object _setChapterUnit(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final chapter = _requireInt(a, 'chapter');
    final units = UnitPlacement(s.rom);
    if (chapter < 0 || chapter >= units.chapterCount) {
      throw _ToolFailure('chapter=$chapter 越界（共 ${units.chapterCount} 章）');
    }
    final slotName = a['slot'];
    final slot = slotName is String
        ? UnitSlot.values.where((x) => x.name == slotName).firstOrNull
        : units.defaultSlot;
    if (slot == null) {
      throw _ToolFailure('未知入口「$slotName」。可用：'
          '${UnitSlot.values.map((x) => x.name).join('、')}');
    }
    if (!units.slotSupported(slot)) {
      throw _ToolFailure('${s.versionId} 没有「${slot.label}」这个入口');
    }
    final list = units.units(chapter, slot);
    if (list.isEmpty) {
      throw _ToolFailure('第 $chapter 章「${slot.label}」里没有单位');
    }
    final index = (a['index'] as num?)?.toInt() ?? 0;
    if (index < 0 || index >= list.length) {
      throw _ToolFailure('index=$index 越界（该入口共 ${list.length} 条）');
    }
    final unit = list[index];
    final dry = _dryRun(a);
    final changes = <String, Object?>{};

    final charId = a['char_id'];
    final classId = a['class_id'];
    final level = a['level'];
    final x = a['x'];
    final y = a['y'];
    final allegiance = a['allegiance'];

    // 写之前先校验：这几个值一旦越界，进游戏会读垃圾
    if (charId is num &&
        (charId.toInt() < 1 || charId.toInt() > s.liveRom.unitCount)) {
      throw _ToolFailure('char_id 必须在 1..${s.liveRom.unitCount}'
          '（注意是 1 基的 unit number，不是表内索引）');
    }
    if (classId is num &&
        (classId.toInt() < 0 || classId.toInt() >= s.liveRom.classCount)) {
      throw _ToolFailure('class_id 必须在 0..${s.liveRom.classCount - 1}');
    }
    if (level is num && (level.toInt() < 0 || level.toInt() > 31)) {
      throw _ToolFailure('level 必须在 0..31');
    }

    void apply(String label, bool changed, Object? before, Object? after) {
      if (!changed) return;
      changes[label] = {'before': before, 'after': after};
    }

    if (charId is num) {
      final before = unit.charId;
      if (!dry) s.rom.writeBytes(unit.addr, [charId.toInt() & 0xFF]);
      apply('char_id', before != charId.toInt(), before, charId.toInt());
    }
    if (classId is num) {
      final before = unit.classId;
      if (!dry) s.rom.writeBytes(unit.addr + 1, [classId.toInt() & 0xFF]);
      apply('class_id', before != classId.toInt(), before, classId.toInt());
    }
    if (level is num || allegiance is num) {
      final before = s.rom.buffer.u8(unit.addr + 3);
      var next = before;
      if (allegiance is num) {
        next = (next & ~0x06) | ((allegiance.toInt() & 0x03) << 1);
      }
      if (level is num) {
        next = (next & ~0xF8) | ((level.toInt() & 0x1F) << 3);
      }
      if (!dry && next != before) s.rom.writeBytes(unit.addr + 3, [next]);
      apply('grow(level+allegiance)', before != next, before, next);
    }
    if (x is num || y is num) {
      if (unit.isFe8) {
        final at = unit.addr + 4;
        final packed = s.rom.buffer.u16(at);
        final nx = x is num ? x.toInt() & 0x3F : packed & 0x3F;
        final ny = y is num ? y.toInt() & 0x3F : (packed >> 6) & 0x3F;
        // 高 4 位是别的东西（`ext`），必须原样保留（同 UnitPlacement.setPosition）
        final v = (packed & 0xF000) | (ny << 6) | nx;
        if (!dry && v != packed) {
          s.rom.writeBytes(at, [v & 0xFF, (v >> 8) & 0xFF]);
        }
        apply('pos', packed != v, '${packed & 0x3F},${(packed >> 6) & 0x3F}', '$nx,$ny');
      } else {
        if (x is num) {
          final before = s.rom.buffer.u8(unit.addr + 4);
          if (!dry) s.rom.writeBytes(unit.addr + 4, [x.toInt() & 0xFF]);
          apply('x', before != (x.toInt() & 0xFF), before, x.toInt() & 0xFF);
        }
        if (y is num) {
          final before = s.rom.buffer.u8(unit.addr + 5);
          if (!dry) s.rom.writeBytes(unit.addr + 5, [y.toInt() & 0xFF]);
          apply('y', before != (y.toInt() & 0xFF), before, y.toInt() & 0xFF);
        }
      }
    }

    // 改完把该条读回来给调用方确认
    final after = dry ? unit : units.unitAt(unit.addr);
    var bytesToChange = 0;
    for (final label in changes.keys) {
      bytesToChange += (label == 'pos') ? 2 : 1;
    }
    return {
      'dry_run': dry,
      'chapter': chapter,
      'title': units.chapterTitle(chapter),
      'slot': slot.name,
      'index': index,
      'addr': unit.addr,
      'changes': changes,
      'changed_n': changes.length,
      'unit': after == null
          ? null
          : {
              'char_id': after.charId,
              'name': after.unitIndex >= 0 && after.unitIndex < s.liveRom.unitCount
                  ? s.liveRom.unitDisplayName(after.unitIndex).trim()
                  : '',
              'class_id': after.classId,
              'level': after.level,
              'x': after.x,
              'y': after.y,
              'allegiance': after.allegiance.code,
            },
      'changed_bytes': dry ? bytesToChange : s.rom.changedByteCount,
    };
  }

  /// 换脸的最后一步：把肖像 ID 写进角色的 `face` 字段。
  ///
  /// 肖像移植（[import_portrait]）只替换素材，不自动挂到角色，
  /// 所以“换脸”需要两下：移植素材 + 改这里的 face 字段。
  /// **FE6 的 face = 肖像索引 + 1**，换算只能走 PortraitReader，
  /// 直接写肖像 ID 会让整张角色表偏一格。
  /// 用外部图片（PNG base64）生成肖像数据，写入目标肖像条目。
  ///
  /// 只换**正脸与调色板**；地图头像 / 嘴型 / 眨眼帧原样保留。
  /// PNG 解码走 `PngDecoder`（同步，不依赖 `dart:ui`）；
  /// JPG 请先在界面里转好再导入。
  Object _importPortraitImage(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final targetId = (a['target_id'] as num?)?.toInt();
    if (targetId == null) {
      throw _ToolFailure('需要 target_id（要替换的肖像 ID，见 list_portraits）');
    }
    final b64 = a['png_base64'] as String?;
    if (b64 == null || b64.isEmpty) {
      throw _ToolFailure('需要 png_base64（PNG 图片的 base64；只支持 PNG，JPG 请先在界面里转）');
    }

    final Uint8List bytes;
    try {
      bytes = base64Decode(b64);
    } catch (_) {
      throw _ToolFailure('png_base64 不是合法的 base64');
    }

    final rgba = PngDecoder.decodeRgba(bytes);
    if (rgba == null) {
      throw _ToolFailure('PNG 解码失败：只支持非交错 8 位的 RGB/RGBA/灰度/调色板 PNG');
    }

    // 宽高交给解码器推算（每像素 4 字节）
    final pixelCount = rgba.length ~/ 4;
    final width = _guessPngWidth(bytes);
    if (width <= 0 || pixelCount % width != 0) {
      throw _ToolFailure('PNG 宽高信息异常');
    }
    final height = pixelCount ~/ width;

    final fitName = a['fit'] as String? ?? 'contain';
    final fit = switch (fitName) {
      'contain' => PortraitFit.contain,
      'cover' => PortraitFit.cover,
      _ => throw _ToolFailure('未知 fit「$fitName」，可用 contain / cover'),
    };

    final fixedExpression = a['fixed_expression'] != false; // 默认 true
    final withMapFace = a['map_face'] != false; // 默认 true
    final strategyName = a['strategy'] as String? ?? 'natural';
    final strategy = switch (strategyName) {
      'natural' => PortraitQuantStrategy.natural,
      'classic' => PortraitQuantStrategy.classic,
      'dither' => PortraitQuantStrategy.dither,
      'bright' => PortraitQuantStrategy.bright,
      _ => throw _ToolFailure(
          '未知 strategy「$strategyName」，可用 natural / classic / dither / bright'),
    };

    final data = PortraitImporter.convertRgba(
      rgba,
      width,
      height,
      fe6: s.rom.rom.table.portraitDataSize == 16,
      fit: fit,
      mapFace: withMapFace,
      mouthX: PortraitReader(s.rom.rom).entryAt(targetId)?.mouthX,
      mouthY: PortraitReader(s.rom.rom).entryAt(targetId)?.mouthY,
      strategy: strategy,
    );

    final dry = _dryRun(a);
    final beforeSampler = _portraitEntrySnapshot(s, targetId);
    final out = PortraitPorter(s.rom).importFace(
      data,
      targetId,
      fixedExpression: fixedExpression,
      replaceMapFace: withMapFace,
    );
    if (!out.ok) throw _ToolFailure(out.message);

    final result = <String, Object?>{
      'dry_run': dry,
      'tool': 'import_portrait_image',
      'target_id': targetId,
      'entry_address': out.entryAddress,
      'bytes_written': out.bytesWritten,
      'free_space_offset': out.freeSpaceOffset,
      'used_colors': data.usedColors,
      'hard_mapped_pixels': data.hardMapped,
      'transparent_ratio':
          double.parse(data.transparentRatio.toStringAsFixed(4)),
      'source_size': '$width×$height',
      'fit': fitName,
      'strategy': strategy.name,
      'fixed_expression': fixedExpression,
      'map_face_replaced': withMapFace,
      'note': fixedExpression
          ? '表情已固定（嘴型指针清空、眼嘴坐标移出脸部）：对话时嘴不动、眼不眨，'
              '但不会串色。地图小头像${withMapFace ? "已一起换" : "保持原样"}。'
              '用 get_portrait_png / kind=map_face 看图确认。'
          : '表情未固定：旧嘴型/眼睛会套用新调色板，可能串色（除非颜色恰好兼容）。',
    };
    if (beforeSampler != null) result['entry_before'] = beforeSampler;
    result['changed_bytes'] = s.rom.changedByteCount;
    return result;
  }

  /// 从 PNG 的 IHDR 读宽度（PngDecoder 已校验过签名与结构）。
  int _guessPngWidth(Uint8List png) {
    if (png.length < 24) return 0;
    return (png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19];
  }

  Map<String, Object?>? _portraitEntrySnapshot(RomSession s, int id) {
    final r = PortraitReader(s.liveRom);
    final e = r.entryAt(id);
    r.dispose();
    if (e == null) return null;
    return {
      'unit_face': e.unitFace,
      'palette': e.palette,
    };
  }

  Object _attachPortrait(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final unitId = _requireIndex(a, 'id', s.liveRom.unitCount);
    final portraitId = (a['portrait_id'] as num?)?.toInt();
    if (portraitId == null) {
      throw _ToolFailure('需要 portrait_id（肖像 ID，见 list_portraits）');
    }
    final reader = PortraitReader(s.liveRom);
    final entryCount = reader.available ? reader.entryCount : 0;
    final hasImage = reader.hasImage(portraitId);
    final face = reader.portraitToFaceId(portraitId);
    reader.dispose();
    if (entryCount <= 0) throw _ToolFailure('该版本没有可读的肖像表');
    if (portraitId < 0 || portraitId >= entryCount) {
      throw _ToolFailure('portrait_id=$portraitId 超出表范围（共 $entryCount 条）');
    }
    if (!hasImage) {
      throw _ToolFailure('肖像 $portraitId 没有图（只是占位条目），挂上去会显示空白');
    }
    if (face < 0 || face > 0xFFFF) throw _ToolFailure('肖像 $portraitId 换算不出合法 face 值');

    final addr = s.rom.unitAddress(unitId) + UnitOffsets.portraitId;
    final before = s.rom.buffer.u16(addr);
    final dry = _dryRun(a);
    if (!dry && before != face) {
      s.rom.writeBytes(addr, [face & 0xFF, (face >> 8) & 0xFF]);
    }
    return {
      'dry_run': dry,
      'unit_id': unitId,
      'unit_name': s.liveRom.unitDisplayName(unitId).trim(),
      'portrait_id': portraitId,
      'face_before': before,
      'face_after': face,
      'changed': before != face,
      'note': 'FE6 的 face = 肖像 ID + 1，这里已自动换算',
      'changed_bytes': s.rom.changedByteCount,
    };
  }

  /// 克隆一个角色到空槽（把一条单位结构体逐字节复制过去，再改 ID）。
  ///
  /// **只填空槽，不扩容整表**：扩容要搬表 + 改指针 + 越过存档位宽限制，
  /// 风险高一个量级（AGENTS 第 11 节）。空槽判据是 `unit ID != 序号+1`
  /// 之前那些条目——也就是表尾尚未被占用的位置读不出来，所以实际做法是
  /// 找一个“ID 字段为 0 的空槽”；原版三作都没有，因此本工具主要服务改版。
  Object _cloneUnit(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final rom = s.liveRom;
    final sourceId = _requireIndex(a, 'from', rom.unitCount);
    final size = rom.table.unitDataSize;
    final base = rom.unitBase;
    final src = base + sourceId * size;
    if (src + size > s.rom.buffer.length) throw _ToolFailure('源条目越界');

    // 目标：显式给 id 就要求那是空槽；不给就找第一个空槽
    int? target;
    final wanted = (a['to'] as num?)?.toInt();
    if (wanted != null) {
      if (wanted < 0 || wanted >= rom.table.unitMaxCount) {
        throw _ToolFailure('to=$wanted 超出表容量（${rom.table.unitMaxCount}）');
      }
      final at = base + wanted * size;
      if (at + size > s.rom.buffer.length) {
        throw _ToolFailure('to=$wanted 超出 ROM 末尾');
      }
      if (s.rom.buffer.u8(at + UnitOffsets.unitId) != 0) {
        throw _ToolFailure('to=$wanted 不是空槽（ID=${s.rom.buffer.u8(at + UnitOffsets.unitId)}），'
            '克隆只填空槽；想改已有角色用 set_unit_field');
      }
      target = wanted;
    } else {
      for (var i = rom.unitCount; i < rom.table.unitMaxCount; i++) {
        final at = base + i * size;
        if (at + size > s.rom.buffer.length) break;
        if (s.rom.buffer.u8(at + UnitOffsets.unitId) != 0) break;
        target = i;
      }
      if (target == null) {
        throw _ToolFailure('单位表后面没有空槽了（原版三作都是满表）。'
            '新增角色需要搬表扩容，超出本工具范围——建议改一个现有角色，'
            '或用事件模板生成剧情单位');
      }
    }

    final dst = base + target * size;
    final dry = _dryRun(a);
    if (!dry) {
      final copy = [for (var i = 0; i < size; i++) s.rom.buffer.u8(src + i)];
      // unit ID 必须等于「序号 + 1」，否则表边界判定会在这里提前结束，
      // 之后所有角色都读不出来。
      copy[UnitOffsets.unitId] = (target + 1) & 0xFF;
      s.rom.writeBytes(dst, copy);
    }
    return {
      'dry_run': dry,
      'from': sourceId,
      'to': target,
      'new_unit_id': target + 1,
      'copied_bytes': size,
      'changed_bytes': s.rom.changedByteCount,
      'note': '新条目 ID 已改成 ${target + 1}（必须与表内序号匹配）；'
          '名字/肖像等文本字段是复制过来的，需要的话再单独改',
    };
  }

  /// 成长模拟：按成长率算 1→N 级的期望值/最好/最坏曲线。
  Object _simulateGrowth(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final rom = s.liveRom;
    final id = _requireIndex(a, 'id', rom.unitCount);
    final target = ((a['target_level'] as num?)?.toInt() ?? 20).clamp(1, 60);
    final sim = BattleSimulator(s.rom);
    final p = sim.projectGrowth(id, targetLevel: target);
    final caps = sim.classCaps(id);
    return {
      'id': id,
      'name': rom.unitDisplayName(id).trim(),
      'from_level': p.fromLevel,
      'target_level': p.targetLevel,
      'current': p.current,
      'growth_rates': sim.growthRates(id),
      'expected': {
        for (final e in p.expected.entries)
          e.key: double.parse(e.value.toStringAsFixed(1)),
      },
      'gain': {
        for (final k in p.current.keys)
          k: double.parse(p.gain(k).toStringAsFixed(1)),
      },
      'worst': p.worst,
      'best': p.best,
      'class_caps': caps,
      'capped': sim.capStatus(id, p),
      'note': '期望值 = 当前值 + 级数 × 成长率%；'
          '不计职业上限截断（capped 字段标出哪些会撑到上限）',
    };
  }

  /// 战斗模拟：A 拿武器 W 打 B，算伤害/命中/必杀/追击/存活。
  Object _simulateBattle(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final rom = s.liveRom;
    final atk = _requireIndex(a, 'attacker', rom.unitCount);
    final weapon = _requireIndex(a, 'weapon', rom.itemCount);
    final def = _requireIndex(a, 'defender', rom.unitCount);
    final distance = ((a['distance'] as num?)?.toInt() ?? 1).clamp(1, 15);
    final f = BattleSimulator(s.rom).forecast(
      atk,
      weapon,
      def,
      attackerHp: (a['attacker_hp'] as num?)?.toInt(),
      defenderHp: (a['defender_hp'] as num?)?.toInt(),
      distance: distance,
    );
    return {
      'attacker': rom.unitDisplayName(atk).trim(),
      'weapon': rom.itemDisplayName(weapon).trim(),
      'defender': rom.unitDisplayName(def).trim(),
      'distance': distance,
      'damage': f.damage,
      'hit': f.hit,
      'crit': f.crit,
      'attacks': f.attacks,
      'doubling': f.doubling,
      'counter': {
        'possible': f.canCounter,
        'damage': f.counterDamage,
        'hit': f.counterHit,
        'crit': f.counterCrit,
        'attacks': f.counterAttacks,
      },
      'expected_damage_per_round': double.parse(f.expectedDamage.toStringAsFixed(1)),
      'outcome': f.outcome,
      'note': '近似值：命中/回避只用技巧与幸运，不计地形、支援、三角武器与特効；'
          'outcome 是「一个回合内能否击杀」（atk=打死对方 / def=被打死 / both / none）',
    };
  }

  /// 改宝箱奖励道具：把本章指定坐标的宝箱奖励换成另一件（只改事件条目
  /// 第 2 字的低 16 位，高 16 位原样保留；写回走 [ChestShop]，可撤销）。
  Object _setChestItem(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final chapter = _requireInt(a, 'chapter');
    final x = _requireInt(a, 'x');
    final y = _requireInt(a, 'y');
    final item = (a['item'] as num?)?.toInt();
    if (item == null) throw _ToolFailure('需要 item（道具索引，0 基）');
    final itemCount = s.rom.rom.itemCount;
    if (item < 0 || item >= itemCount) {
      throw _ToolFailure('item=$item 越界（共 $itemCount 件）');
    }
    final units = UnitPlacement(s.rom);
    final ev = units.eventGroupOffset(chapter);
    if (ev <= 0) throw _ToolFailure('第 $chapter 章没有可读的事件组');
    final ce = ChapterEvents(s.liveRom);
    final cs = ChestShop(s.rom);
    final chests = [
      for (final e in ce.all(ev))
        if (cs.isChest(e)) e
    ];
    final hits = [
      for (final e in chests)
        if ((e.value & 0xFF) == x && ((e.value >> 8) & 0xFF) == y) e
    ];
    if (hits.isEmpty) {
      final pos = chests
          .map((e) => '(${e.value & 0xFF}, ${((e.value >> 8) & 0xFF) & 0xFF})')
          .join('、');
      throw _ToolFailure('第 $chapter 章 ($x,$y) 没有宝箱。'
          '本章宝箱：${pos.isEmpty ? '无' : pos}');
    }
    final e = hits.first;
    final was = cs.chestItemNow(e);
    final n = cs.setChestItem(e, item);
    if (n < 0) throw _ToolFailure('写入失败（事件条目越界）');
    return {
      'chapter': chapter,
      'x': x,
      'y': y,
      'item': item,
      'item_name': s.liveRom.itemDisplayName(item).trim(),
      'was': was,
      'was_name': s.liveRom.itemDisplayName(was).trim(),
      'changed_bytes': n,
      'note': n == 0
          ? '与原来相同，未写入'
          : '已改。同坐标多个宝箱时只改了第一个；改完建议 validate_rom 复核',
    };
  }

  /// 改商店卖的那件：把本章指定坐标的商店第 [slot] 格换成另一件道具。
  /// 只替换、不增删（商店列表在 ROM 里挨着排布，扩容会改坏别的商店）。
  Object _setShopItem(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final chapter = _requireInt(a, 'chapter');
    final x = _requireInt(a, 'x');
    final y = _requireInt(a, 'y');
    final slot = _requireInt(a, 'slot');
    final item = (a['item'] as num?)?.toInt();
    if (item == null) throw _ToolFailure('需要 item（道具索引，0 基）');
    final itemCount = s.rom.rom.itemCount;
    if (item < 0 || item >= itemCount) {
      throw _ToolFailure('item=$item 越界（共 $itemCount 件）');
    }
    final units = UnitPlacement(s.rom);
    final ev = units.eventGroupOffset(chapter);
    if (ev <= 0) throw _ToolFailure('第 $chapter 章没有可读的事件组');
    final ce = ChapterEvents(s.liveRom);
    final cs = ChestShop(s.rom);
    final shops = [
      for (final e in ce.all(ev))
        if (cs.isShop(e)) e
    ];
    final hits = [
      for (final e in shops)
        if ((e.value & 0xFF) == x && ((e.value >> 8) & 0xFF) == y) e
    ];
    if (hits.isEmpty) {
      final pos = shops
          .map((e) => '(${e.value & 0xFF}, ${((e.value >> 8) & 0xFF) & 0xFF})')
          .join('、');
      throw _ToolFailure('第 $chapter 章 ($x,$y) 没有商店。'
          '本章商店：${pos.isEmpty ? '无' : pos}');
    }
    final e = hits.first;
    final items = cs.shopItemsOf(e);
    if (items.isEmpty) {
      throw _ToolFailure('读不到这家商店的列表（第 2 字不是合法指针）');
    }
    if (slot < 0 || slot >= items.length) {
      throw _ToolFailure('slot=$slot 越界（本店共 ${items.length} 格，'
          '只能替换、不能新增）');
    }
    final was = items[slot];
    final n = cs.setShopItem(e, slot, item);
    if (n < 0) throw _ToolFailure('写入失败（列表越界）');
    final now = cs.shopItemsOf(e);
    return {
      'chapter': chapter,
      'x': x,
      'y': y,
      'slot': slot,
      'item': item,
      'item_name': s.liveRom.itemDisplayName(item).trim(),
      'was': was,
      'was_name': s.liveRom.itemDisplayName(was).trim(),
      'shop_items': now,
      'changed_bytes': n,
      'note': n == 0 ? '与原来相同，未写入' : '已改。改完建议 validate_rom 复核',
    };
  }

  /// 全武器对比：攻方逐个试完所有有威力的武器，按每回合期望伤害降序排。
  /// 公式与 [simulate_battle] 完全一致（同一套近似），用来回答
  /// 「谁配什么武器 / 这把武器该给谁」。
  Object _compareWeapons(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final rom = s.liveRom;
    final unit = _requireIndex(a, 'unit', rom.unitCount);
    final target = _requireIndex(a, 'target', rom.unitCount);
    final distance = ((a['distance'] as num?)?.toInt() ?? 1).clamp(1, 15);
    final limit = ((a['limit'] as num?)?.toInt() ?? 30).clamp(1, 200);
    final rows = BattleSimulator(s.rom)
        .compareWeapons(unit, target, distance: distance, limit: limit);
    return {
      'unit': rom.unitDisplayName(unit).trim(),
      'target': rom.unitDisplayName(target).trim(),
      'distance': distance,
      'count': rows.length,
      'rows': [
        for (var i = 0; i < rows.length; i++)
          {
            'rank': i + 1,
            'weapon_id': rows[i].weaponId,
            'name': rows[i].name,
            'kind': rows[i].kindLabel,
            'damage': rows[i].damage,
            'hit': rows[i].hit,
            'crit': rows[i].crit,
            'attacks': rows[i].attacks,
            'expected_damage_per_round':
                double.parse(rows[i].expectedDamage.toStringAsFixed(1)),
            'one_shot': rows[i].outcome == 'atk',
          },
      ],
      'note': '公式同 simulate_battle（近似值，不计职业持枪限制/地形/支援）；'
          '按每回合期望伤害降序，只看前 ${limit} 把',
    };
  }

  /// 全 ROM 文本批量查找/替换（[TextFindReplace]：逐条走写文本同一通道）。
  Object _findReplaceText(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final find = a['find'] as String? ?? '';
    final replace = (a['replace'] as String?) ?? '';
    if (find.trim().isEmpty) {
      throw _ToolFailure('find 不能为空（留空 = 不查）');
    }
    final writer = TextWriter(s.rom);
    if (!writer.supported) {
      throw _ToolFailure('该 ROM 的文本引擎未识别，不支持写入');
    }
    final ids = a['ids'];
    final explicit = ids is List
        ? ids.map((e) => (e as num).toInt()).toList()
        : null;
    if (explicit != null) {
      final maxId = TextBrowser(writer.rom).maxId;
      for (final id in explicit) {
        if (id < 0 || id >= maxId) {
          throw _ToolFailure('ids 里 $id 越界（文本表共 $maxId 条）');
        }
      }
    }
    final fr = TextFindReplace(writer);
    // dry_run 不自己处理：通用 _maybeDryRun 会真实执行一遍再整体回滚（§28）。
    final r = fr.replaceAll(find, replace, ids: explicit);
    return {
      'find': find,
      'replace': replace,
      'changed': r.changed,
      'identical': r.identical,
      'failures': r.failures.take(20).toList(),
      'changed_bytes': s.rom.changedByteCount,
      'note': r.failures.isEmpty
          ? '替换完成（可 revert_all 整体回退）'
          : '有 ${r.failures.length} 条失败（变长没空位/编码不支持等），只列前 20 条',
    };
  }

  /// 导出「修改配方」：把 edits 记录成一份可重放的 JSON。
  ///
  /// 与直接发 ROM 补丁的区别：配方是**可读、可审查、可编辑**的操作清单，
  /// 同版本同结构的 ROM 上重放得到同样的结果，适合 AI 之间传递改动。
  ///
  /// 两层：`chunks`（offset/before/after）是精确重放；`semantic`（[a] 里
  /// 可选传入）是「按角色/道具名 + 字段 + 预设 ID」的意图层，同版本不同来源
  /// 的 ROM 上也能用。[format] 为 `patch` 时额外给一段紧凑文本便于人工核对。
  Object _exportRecipe(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final edit = s.rom;
    final original = edit.original;
    final current = edit.buffer.data;
    final n = original.length < current.length ? original.length : current.length;
    final changes = <Map<String, Object?>>[];
    var i = 0;
    while (i < n) {
      if (original[i] == current[i]) {
        i++;
        continue;
      }
      final start = i;
      while (i < n && original[i] != current[i]) {
        i++;
      }
      final before = [for (var k = start; k < i; k++) original[k]];
      final after = [for (var k = start; k < i; k++) current[k]];
      changes.add({
        'offset': start,
        'gba': 0x08000000 + start,
        'length': i - start,
        'before': before,
        'after': after,
      });
    }

    final recipe = <String, Object?>{
      'recipe_version': 1,
      'app': appName,
      'app_version': appVersion,
      'rom': {
        'version': s.versionId,
        'file': s.fileName,
        'size': edit.buffer.length,
        'fingerprint': s.fingerprint,
      },
      'changed_bytes': edit.changedByteCount,
      'chunk_count': changes.length,
      'chunks': changes,
      'summary': RomHealth.summarizeEdits(edit),
    };
    // 语义层：调用方显式传入的意图描述（AI 做完一批预设/字段修改后，
    // 把意图随配方一起导出，重放时不依赖裸字节）。
    final semanticRaw = a['semantic'];
    if (semanticRaw != null) {
      Object parsed;
      try {
        parsed = semanticRaw is String
            ? jsonDecode(semanticRaw)
            : semanticRaw;
      } catch (_) {
        throw _ToolFailure('semantic 不是合法 JSON');
      }
      final parsedRecipe = parseSemantic(parsed);
      if (parsedRecipe.problems.isNotEmpty) {
        throw _ToolFailure(
            'semantic 层有问题：${parsedRecipe.problems.join('；')}');
      }
      recipe['semantic'] = parsedRecipe.semantic;
    }
    if (a['format'] == 'patch') {
      final lines = <String>[
        for (final c in changes)
          '${(c['offset'] as int).toRadixString(16).padLeft(8, '0')}:'
              '${(c['before'] as List).map((b) => (b as int).toRadixString(16).padLeft(2, '0')).join()}'
              '>'
              '${(c['after'] as List).map((b) => (b as int).toRadixString(16).padLeft(2, '0')).join()}',
      ];
      recipe['patch_text'] = lines.join('\n');
    }
    return recipe;
  }

  /// 应用一份「修改配方」（[export_recipe] 的产物或手工写的 JSON）。
  ///
  /// 语义层按名字/预设重新解析后应用（同版本可用）；字节层只在指纹一致时
  /// 重放（原值核对不上的分段逐条跳过并报告）。改完建议跑 `validate_rom`。
  Object _applyRecipe(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final raw = a['text'];
    if (raw is! String || raw.trim().isEmpty) {
      throw _ToolFailure('需要 text（配方的 JSON 文本，export_recipe 的产物）');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      throw _ToolFailure('配方不是合法 JSON：$e');
    }
    if (decoded is! Map) {
      throw _ToolFailure('配方顶层必须是 JSON 对象');
    }
    final romInfo = (decoded['rom'] as Map?)?.cast<String, Object?>();
    final version = romInfo?['version'] as String?;
    final fingerprint = (romInfo?['fingerprint'] as num?)?.toInt();
    final chunks = [
      for (final c in (decoded['chunks'] as List?) ?? const [])
        (c as Map).cast<String, Object?>(),
    ];
    final parsed = parseSemantic(decoded['semantic']);
    if (parsed.problems.isNotEmpty) {
      throw _ToolFailure('语义层有问题：${parsed.problems.join('；')}');
    }
    final result = applyRecipe(
      s.rom,
      semantic: parsed.hasContent ? parsed : null,
      chunks: chunks,
      version: version,
      expectedFingerprint: fingerprint,
    );
    // 硬拒绝 = 版本不匹配（整份没写）；分段跳过/目标未解析是 warning 不拦
    final rejected = result.problems.any((p) => p.contains('拒绝应用'));
    return {
      'applied': !rejected,
      'semantic_changed_bytes': result.semanticChangedBytes,
      'bytes_changed_bytes': result.bytesChangedBytes,
      'skipped_chunks': result.skippedChunks,
      'problems': result.problems,
      'changed_bytes_total': s.rom.changedByteCount,
      'hint': result.problems.isEmpty
          ? '改完建议跑 validate_rom 体检'
          : '有分段/目标被跳过，先处理 problems 再重放',
    };
  }

  /// 事件模板：给本章追加一条「第 N 回合增援」。
  ///
  /// 底层走 [EventTemplates.addReinforcement]：把事件列表整表搬到空位、
  /// 追加一条新条目、只重指事件组里那个 4 字节指针，
  /// **不改动任何已有脚本**（改坏了把指针改回去即可）。
  Object _addReinforcement(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final chapter = _requireInt(a, 'chapter');
    final turn = _requireInt(a, 'turn');
    final raw = a['units'];
    if (raw is! List || raw.isEmpty) {
      throw _ToolFailure('需要 units（至少一个增援单位）；'
          '每项：{"char_id":1基, "class_id":0基, "level":1-31, "x":…, "y":…, "allegiance":2}');
    }
    final units = <ReinforcementUnit>[];
    for (final item in raw) {
      if (item is! Map) throw _ToolFailure('units 里每一项都必须是对象');
      final charId = item['char_id'];
      final x = item['x'];
      final y = item['y'];
      if (charId is! num || x is! num || y is! num) {
        throw _ToolFailure('units 每项都必须有 char_id / x / y');
      }
      final items = item['items'];
      units.add(ReinforcementUnit(
        charId: charId.toInt(),
        classId: (item['class_id'] as num?)?.toInt() ?? 0,
        level: (item['level'] as num?)?.toInt() ?? 1,
        x: x.toInt(),
        y: y.toInt(),
        allegiance: (item['allegiance'] as num?)?.toInt() ?? 2,
        items: items is List ? [for (final i in items) (i as num).toInt()] : const [],
      ));
    }

    final out = EventTemplates(s.rom).addReinforcement(
      chapter: chapter,
      turn: turn,
      units: units,
      dialogueTextId: (a['dialogue_text_id'] as num?)?.toInt() ?? 0,
    );
    if (!out.ok) {
      throw _ToolFailure('${out.result.name}: ${out.message}');
    }
    return {
      'chapter': chapter,
      'title': UnitPlacement(s.rom).chapterTitle(chapter),
      'turn': turn,
      'units': units.length,
      'result': out.result.name,
      'message': out.message,
      'script_offset': out.scriptOffset,
      'list_offset': out.listOffset,
      'unit_array_offset': out.unitArrayOffset,
      'bytes_written': out.bytesWritten,
      'changed_bytes': s.rom.changedByteCount,
      'note': '只追加，不改既有脚本；旧事件列表原样留在原地，'
          '出问题可用 rollback / revert_changes 回退',
    };
  }

  /// 把改后的 ROM 写到 App 私有导出目录，返回路径。
  Object _saveRomToFile(Map<String, dynamic> a) async {
    final s = awaitSessionSync(a);
    final data = s.rom.buildOutput();
    final base = (a['name'] as String?) ??
        '${s.fileName.replaceAll(RegExp(r'\\.gba$', caseSensitive: false), '')}_modified';
    final name = base.endsWith('.gba') ? base : '$base.gba';
    final path = await McpService.instance.writeExport(name, data);
    if (path == null) throw _ToolFailure('写入失败（详情见 App 日志页）');
    return {
      'version': s.versionId,
      'size': data.length,
      'path': path,
      'changed_bytes': s.rom.changedByteCount,
    };
  }

  /// ROM 结构自检（旧版，只查表指针）。保留是为了不打断已有客户端调用方；
  /// 新调用方用 [validate_rom]。
  Object _validate(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final rom = s.rom.liveRom;
    final problems = <String>[];
    final warnings = <String>[];

    void checkTable(String name, int base, int count, int size, int slot) {
      if (slot <= 0) {
        warnings.add('$name：该版本没有这张表，跳过');
        return;
      }
      if (base <= 0) {
        problems.add('$name：表基址无效（$base）');
        return;
      }
      if (count <= 0) {
        problems.add('$name：条目数为 0（表被写坏或指针失效）');
        return;
      }
      final end = base + count * size;
      if (end > rom.length) {
        problems.add('$name：表尾 0x${end.toRadixString(16)} 超出 ROM 大小 0x${rom.length.toRadixString(16)}');
      }
    }

    checkTable('单位表', rom.unitBase, rom.unitCount, rom.table.unitDataSize,
        rom.table.unitPointerSlot);
    checkTable('职业表', rom.classBase, rom.classCount, rom.table.classDataSize,
        rom.table.classPointerSlot);
    checkTable('道具表', rom.itemBase, rom.itemCount, rom.table.itemDataSize,
        rom.table.itemPointerSlot);

    // 文本表：抽几条看能不能解出东西
    if (rom.textAvailable) {
      var readable = 0;
      for (var i = 0; i < 50; i++) {
        if (rom.unitDisplayName(i).trim().isNotEmpty) readable++;
      }
      if (readable == 0) problems.add('文本表：前 50 个单位名全部解不出（文本引擎或指针被写坏）');
    } else {
      warnings.add('文本不可用（该 ROM 的文本引擎未识别）');
    }

    // 地图：抽查前 5 章能否读出砖块
    final map = MapReader(rom);
    if (map.available) {
      var okMaps = 0;
      for (var ch = 0; ch < 5 && ch < map.chapterCount; ch++) {
        if (map.chapterMap(ch) != null) okMaps++;
      }
      if (okMaps == 0) problems.add('地图表：前 5 章都读不出砖块');
      else if (okMaps < 5) warnings.add('地图表：前 5 章里只有 $okMaps 章可读');
    }

    // 肖像表
    final portraits = PortraitReader(rom);
    if (portraits.available) {
      if (portraits.entryCount <= 0) problems.add('肖像表：条目数为 0');
      portraits.dispose();
    }

    return {
      'version': s.versionId,
      'ok': problems.isEmpty,
      'problems': problems,
      'warnings': warnings,
      'changed_bytes': s.rom.changedByteCount,
    };
  }

  /// 体检：表结构 + ID 连续性 + 单位默认职业 + 支援引用 + 章节单位坐标。
  ///
  /// 与界面「体检报告」共用 [RomHealth]，两边结论必然一致。
  /// 改完东西建议跑一次：[deep] 默认 true（扫全部章节，约一两秒），
  /// AI 高频小改用 `deep: false` 只查表与 ID。
  Object _validateRom(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final deep = a['deep'] != false;
    final report = RomHealth(s.rom).run(deep: deep);
    return {
      'version': s.versionId,
      ...report.toJson(),
      'changed_bytes': s.rom.changedByteCount,
      'deep': deep,
    };
  }

  /// 一次调用返回当前 ROM 的完整能力清单——AI 开局读它，而不是猜偏移。
  Object _describeRom(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final rom = s.rom.liveRom;
    final placement = UnitPlacement(s.rom);
    final map = MapReader(rom);
    final chapters = placement.chapterCount;
    final mapAnim = BattleAnimReader(rom);
    final portraits = PortraitReader(rom);
    final portraitCount = portraits.available ? portraits.entryCount : 0;
    portraits.dispose();

    return {
      'version': s.versionId,
      'version_name': s.versionName,
      'file': s.fileName,
      'generation': s.generation,
      'size': rom.length,
      'changed_bytes': s.rom.changedByteCount,
      'text': {
        'encoding': rom.textEncoding.name,
        'zh_table': s.hasZhTable,
        'writable': s.textWritable,
        'homophone_names': rom.usesHomophoneSubstitution,
      },
      'tables': {
        'units': {
          'count': rom.unitCount,
          'id_range': [0, rom.unitCount - 1],
          'base': rom.unitBase,
          'entry_size': rom.table.unitDataSize,
        },
        'classes': {
          'count': rom.classCount,
          'id_range': [0, rom.classCount - 1],
          'base': rom.classBase,
        },
        'items': {
          'count': rom.itemCount,
          'id_range': [0, rom.itemCount - 1],
          'base': rom.itemBase,
        },
        'portraits': portraitCount,
        'battle_anims': mapAnim.available ? mapAnim.entries.length : 0,
        'chapter_count': chapters,
      },
      'editable': {
        'unit_fields': [for (final f in unitEditableFieldsFor(fe6: rom.isFe6)) f.label],
        'class_fields': [
          for (final f in classEditableFieldsFor(fe6: rom.isFe6)) f.label
        ],
        'item_fields': [
          for (final f in itemEditableFieldsFor(fe6: rom.isFe6)) f.label
        ],
        'chapter_units': true,
        'map_tiles': map.available,
        'text': s.textWritable,
        'support': true,
        'flags': {
          'unit_support': '支援数据在单位表 +0x2C，读支援用 get_unit 或 list_playable_units',
          'item_flags': '道具 +8 是 u32 标志位（无限耐久 bit3 等），用 apply_cheat_preset 或 write_hex',
          'class_flags': '职业 +37/+41 是标志位，不是数值',
        },
      },
      'playable': {
        'criteria': [
          for (final c in PlayableCriterion.values)
            {'name': c.name, 'label': c.label},
        ],
        'default': PlayableCriterion.reciprocal.name,
        'note': '单位表没有阵营字段；判我方靠支援互惠/章节出场，'
            '不要用「索引 < N」',
      },
      // 章节清单只给前 N 章：完整清单用 list_chapters。
      // describe_rom 是「开局自述」，把 100+ 章的明细全塞进来会让响应
      // 逼近两万字符——桥接层走主线程传输，大响应期间 UI 一卡就容易
      // 撞上 90 秒超时（表现为「MCP 卡住」）。
      'chapters': [
        for (var i = 0; i < chapters && i < _describeChapterLimit; i++)
          {
            'id': i,
            'title': placement.chapterTitle(i),
            'resource': map.available ? map.resourceNameOf(i) : '',
            'has_events': placement.eventGroupOffset(i) > 0,
            'has_units': placement.slotSupported(placement.defaultSlot),
          }
      ],
      if (chapters > _describeChapterLimit)
        'chapters_note': '只列了前 $_describeChapterLimit 章（共 $chapters 章）；'
            '完整清单用 list_chapters',
      'tools_workflow': [
        '改前先 snapshot（可选）或 preview_edit / dry_run=true 预演',
        '改完之后跑 validate_rom 体检',
        '不满意用 rollback 回到快照，或 revert_changes 全部撤销',
      ],
      'limitations': [
        '章节单位只能改字段，不能增删（要增删用事件模板生成动态单位）',
        '事件脚本只读（能改事件里的单位字段，不能插入指令）',
        '地图砖块只能就地覆盖，压缩后放不下会被拒（地图跨章节共享）',
        '肖像移植不会自动挂到角色（用 attach_portrait_to_unit）',
        '职业数量上限受存档限制，改版请替换已有职业而非新增',
      ],
    };
  }

  /// 存一个可回滚的快照。
  Object _snapshot(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final label = (a['label'] as String?) ?? '';
    final snap = s.snapshots.take(s.rom, label: label);
    return {
      'id': snap.id,
      'label': snap.label,
      'changed_bytes': snap.changedBytes,
      'snapshots': [for (final x in s.snapshots.all) x.id],
    };
  }

  Object _listSnapshots(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    return {
      'version': s.versionId,
      'current_changed_bytes': s.rom.changedByteCount,
      'snapshots': [
        for (final x in s.snapshots.all)
          {'id': x.id, 'label': x.label, 'changed_bytes': x.changedBytes}
      ],
    };
  }

  /// 回到某个快照。不给 id 就回最近一个（「试一下不行回滚」的常见写法）。
  Object _rollback(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final id = a['id'] as String?;
    final snap = id == null || id.isEmpty ? s.snapshots.latest : s.snapshots.byId(id);
    if (snap == null) {
      throw _ToolFailure(id == null || id.isEmpty
          ? '还没有任何快照（先调 snapshot 或传 id）'
          : '没有快照「$id」，可用：${s.snapshots.all.map((x) => x.id).join('、')}');
    }
    final before = s.rom.changedByteCount;
    if (!s.snapshots.restore(s.rom, snap)) {
      throw _ToolFailure('快照与当前 ROM 大小不符，无法回滚');
    }
    // 回滚到该快照之后，它自己以及更晚的都被消耗掉
    final idx = s.snapshots.all.indexOf(snap);
    for (var i = s.snapshots.all.length - 1; i >= idx; i--) {
      s.snapshots.drop(s.snapshots.all[i].id);
    }
    return {
      'rolled_back_to': snap.id,
      'label': snap.label,
      'changed_bytes_before': before,
      'changed_bytes': s.rom.changedByteCount,
      'remaining_snapshots': [for (final x in s.snapshots.all) x.id],
    };
  }

  /// 差分视图：当前 buffer 与「打开时」的差异，按区域分组。
  Object _listChanges(Map<String, dynamic> a) {
    final s = awaitSessionSync(a);
    final summary = RomHealth.summarizeEdits(s.rom);
    final snap = s.snapshots.latest;
    final result = <String, Object?>{
      'version': s.versionId,
      'changed_bytes': s.rom.changedByteCount,
      ...summary,
    };
    if (snap != null) {
      result['since_snapshot'] = {
        'id': snap.id,
        'label': snap.label,
        'changed_bytes': diffBytes(snap.data, s.rom.buffer.data).total,
      };
    }
    return result;
  }

  int _requireInt(Map<String, dynamic> a, String key) {
    final v = a[key];
    if (v is! num) throw _ToolFailure('需要 $key（整数）');
    return v.toInt();
  }

  int _requireIndex(Map<String, dynamic> a, String key, int count) {
    final v = a[key];
    if (v is! num) throw _ToolFailure('需要 $key（整数索引）');
    final i = v.toInt();
    if (i < 0 || i >= count) throw _ToolFailure('$key=$i 越界（共 $count 条）');
    return i;
  }
}

/// 工具内部的可预期失败（转成 MCP 的 isError 结果，而不是协议错误）。
class _ToolFailure implements Exception {
  final String message;
  _ToolFailure(this.message);
  @override
  String toString() => message;
}

/// 一个 MCP 工具的完整定义：协议里的 schema + 给人看的说明。
class McpToolDef {
  final String name;
  final String description;
  final Map<String, McpArg> properties;
  final List<String> required;

  /// 会写 ROM 的工具。只有它们接受 `dry_run`（预演 + 自动回滚）。
  final bool mutating;

  /// 是否支持 `dry_run`。快照/回滚这类「改的是编辑会话状态」的工具不算：
  /// 预演它们没有意义（预演 snapshot 只会得到一个多余的快照）。
  final bool dryRunnable;

  McpToolDef({
    required this.name,
    required this.description,
    this.properties = const {},
    this.required = const [],
    this.mutating = false,
    bool? dryRunnable,
  }) : dryRunnable = dryRunnable ?? mutating;

  Map<String, dynamic> get schema => {
        'name': name,
        'description': description,
        'inputSchema': {
          'type': 'object',
          'properties': {
            for (final e in properties.entries) e.key: e.value.schema,
          },
          'required': required,
        },
      };
}

/// 全部工具清单。
///
/// **只在这里定义一次**：`tools/list` 与 `tools/call` 都读它。
/// 两边各写一份会出现「列出来了却调不动」的情况（嵌入 MCP 的老坑）。
///
/// 参数类型用 [McpArg] 精确描述，因为客户端要靠 inputSchema 决定怎么传参；
/// 全写成 string 会让整数/数组参数被拒。
final List<McpToolDef> toolDefinitions = [
  McpToolDef(
    name: 'list_roms',
    description: '列出 App 里当前打开的全部 ROM（版本、文件名、是否是当前会话、已改动字节数）。',
  ),
  McpToolDef(
    name: 'rom_info',
    description: '读某个 ROM 的概况：版本、大小、文本引擎、三张主表的条目数与基址。',
    properties: {'rom': McpArg.string('版本代号（FE6/FE7J/FE7U/FE8J/FE8U）；省略则用当前会话')},
  ),
  McpToolDef(
    name: 'list_units',
    description: '列出角色（单位表）。可按名字子串过滤。',
    properties: {
      'rom': McpArg.string('版本代号，省略用当前会话'),
      'query': McpArg.string('名字过滤（子串）'),
      'limit': McpArg.integer('最多返回条数，默认 300'),
    },
  ),
  McpToolDef(
    name: 'get_unit',
    description: '读一个角色的全部可编辑字段（等级/属性/成长率/熟练度等）。',
    properties: {'id': McpArg.integer('单位表索引（0 基）'), 'rom': McpArg.string('版本代号')},
    required: ['id'],
  ),
  McpToolDef(
    name: 'set_unit_field',
    mutating: true,
    description: '改一个角色的单个字段。字段名必须与 get_unit 返回的一致。',
    properties: {
      'id': McpArg.integer('单位表索引'),
      'field': McpArg.string('字段名，如「等级」「HP成长」'),
      'value': McpArg.integer('新值（超出范围会被夹紧）'),
      'rom': McpArg.string('版本代号'),
      'dry_run': McpArg.boolean('只预演不写入：返回会改哪些字节（默认 false）'),
    },
    required: ['id', 'field', 'value'],
  ),
  McpToolDef(
    name: 'list_classes',
    description: '列出职业表。',
    properties: {'rom': McpArg.string('版本代号')},
  ),
  McpToolDef(
    name: 'get_class',
    description: '读一个职业的全部可编辑字段与当前值（含取值范围与档位），'
        'set_class_field 的字段名以它为准。',
    properties: {'id': McpArg.integer('职业表索引'), 'rom': McpArg.string('版本代号')},
    required: ['id'],
  ),
  McpToolDef(
    name: 'set_class_field',
    mutating: true,
    description: '改一个职业的单个字段（移动力/体格/基础值/成长率/能力上限等）。',
    properties: {
      'id': McpArg.integer('职业表索引'),
      'field': McpArg.string('字段名'),
      'value': McpArg.integer('新值'),
      'rom': McpArg.string('版本代号'),
      'dry_run': McpArg.boolean('只预演不写入：返回会改哪些字节（默认 false）'),
    },
    required: ['id', 'field', 'value'],
  ),
  McpToolDef(
    name: 'get_class_terrain',
    description: '读一个职业的地形相关表：移动消耗（晴/雨/雪）与地形回避/防御/魔防、'
        '按地形 ID 索引的 s8 数组（地形 0..65）。-1 表示不可通行（移动）或无修正。'
        '同时返回这些表被哪些其它职业共享（改一处会一起变）。',
    properties: {
      'id': McpArg.integer('职业表索引'),
      'terrain': McpArg.integer('只读某一地形 ID（可选，省略则返回全部 66 项）'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['id'],
  ),
  McpToolDef(
    name: 'set_class_terrain',
    mutating: true,
    description: '改一个职业某张地形表的某一项（原地覆盖单字节）。'
        'table 取值：mov_dry / mov_rain / mov_snow / avoid / defense / resistance；'
        'FE6 没有雨/雪两张移动表。**这些表常被多个职业共享**，改动会影响所有共享者。',
    properties: {
      'id': McpArg.integer('职业表索引'),
      'table': McpArg.string('哪张表：mov_dry / mov_rain / mov_snow / avoid / defense / resistance'),
      'terrain': McpArg.integer('地形 ID 0~65'),
      'value': McpArg.integer('新值 -128~127（-1 = 不可通行/无修正）'),
      'dry_run': McpArg.boolean('只预演不写入'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['id', 'table', 'terrain', 'value'],
  ),
  McpToolDef(
    name: 'list_items',
    description: '列出道具表（名字、种类、威力、耐久）。',
    properties: {'rom': McpArg.string('版本代号')},
  ),
  McpToolDef(
    name: 'get_item',
    description: '读一个道具的全部可编辑字段与当前值（含取值范围与档位），'
        'set_item_field 的字段名以它为准。',
    properties: {'id': McpArg.integer('道具表索引'), 'rom': McpArg.string('版本代号')},
    required: ['id'],
  ),
  McpToolDef(
    name: 'set_item_field',
    mutating: true,
    description: '改一个道具的单个字段（威力/命中/重量/必杀/耐久/单价/武器等级等）。',
    properties: {
      'id': McpArg.integer('道具表索引'),
      'field': McpArg.string('字段名'),
      'value': McpArg.integer('新值'),
      'rom': McpArg.string('版本代号'),
      'dry_run': McpArg.boolean('只预演不写入：返回会改哪些字节（默认 false）'),
    },
    required: ['id', 'field', 'value'],
  ),
  McpToolDef(
    name: 'list_chapters',
    description: '列出全部章节：索引、内部资源名（bmap00/T01)00/L00）、地图尺寸、是否有事件。'
        'AI 用它把「第几章」对上索引。显示名在文本表里，可用 read_text 搜索。',
    properties: {'rom': McpArg.string('版本代号')},
  ),
  McpToolDef(
    name: 'get_map',
    description: '读一章的地图砖块数组（宽、高、按行优先的砖块 ID）。',
    properties: {
      'chapter': McpArg.integer('章节索引（0 基）'),
      'rom': McpArg.string('版本代号'),
    },
  ),
  McpToolDef(
    name: 'set_map_tiles',
    mutating: true,
    description: '写回一章的地图砖块。压缩后放不下会被拒绝（地图跨章节共享，不能搬家）。',
    properties: {
      'chapter': McpArg.integer('章节索引'),
      'tiles': McpArg.array('砖块数组，长度必须等于宽×高'),
      'rom': McpArg.string('版本代号'),
      'dry_run': McpArg.boolean('只预演不写入：实际执行后立即回滚，返回将改的字节'),
    },
    required: ['chapter', 'tiles'],
  ),
  McpToolDef(
    name: 'list_portraits',
    description: '列出肖像条目（ID、名字、被谁使用、是否半身像）。',
    properties: {
      'rom': McpArg.string('版本代号'),
      'limit': McpArg.integer('最多返回条数，默认 60'),
    },
  ),
  McpToolDef(
    name: 'portrait_usage',
    description: '查某张肖像当前被哪个角色/职业使用（替换前用来确认影响面）。',
    properties: {'id': McpArg.integer('肖像 ID'), 'rom': McpArg.string('版本代号')},
    required: ['id'],
  ),
  McpToolDef(
    name: 'import_portrait',
    mutating: true,
    description: '把另一个已打开 ROM 的肖像搬进来。给 target_id 就是替换那一条（推荐），'
        '不给则在表尾追加新条目。跨版本会自动转格式，颜色不掉。',
    properties: {
      'source': McpArg.string('源 ROM 版本代号，如 FE6'),
      'source_id': McpArg.integer('源肖像 ID'),
      'target_id': McpArg.integer('要替换的目标肖像 ID；省略＝追加新条目'),
      'rom': McpArg.string('目标 ROM 版本代号'),
      'dry_run': McpArg.boolean('只预演不写入：实际执行后立即回滚，返回将改的字节'),
    },
    required: ['source', 'source_id'],
  ),
  McpToolDef(
    name: 'list_battle_anims',
    description: '列出战斗动画（ID、缩写、模式数）。',
    properties: {'rom': McpArg.string('版本代号')},
  ),
  McpToolDef(
    name: 'get_portrait_png',
    description: '把一张肖像导出成 base64 PNG，AI 可直接看图判断是谁。'
        'kind 可选 face（默认 96×80 正脸）/ map_face（32×32）/ class_card（80×80）/ '
        'mouth_frame（嘴型帧，配 frame 1..6）/ eye_half（半目）/ eye_closed（闭眼）。',
    properties: {
      'id': McpArg.integer('肖像 ID'),
      'kind': McpArg.string('face / map_face / class_card / mouth_frame / eye_half / eye_closed，默认 face'),
      'frame': McpArg.integer('kind=mouth_frame 时的帧号 1..6'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['id'],
  ),
  McpToolDef(
    name: 'get_battle_anim_frame_png',
    description: '把战斗动画的某一帧渲染并导出成 base64 PNG（248×160）。',
    properties: {
      'id': McpArg.integer('动画 ID'),
      'mode': McpArg.integer('模式索引 0~11，默认 0（攻击命中）'),
      'frame': McpArg.integer('帧索引，默认 0'),
      'palette': McpArg.integer('配色组 0=自军 1=敌军 2=友军 3=灰，默认 0'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['id'],
  ),
  McpToolDef(
    name: 'import_battle_anim',
    mutating: true,
    description: '整包搬运一条战斗动画（脚本/OAM/调色板/全部图形）。给 target_id 是替换。',
    properties: {
      'source': McpArg.string('源 ROM 版本代号'),
      'source_id': McpArg.integer('源动画 ID'),
      'target_id': McpArg.integer('要替换的目标动画 ID；省略＝追加'),
      'rom': McpArg.string('目标 ROM 版本代号'),
      'dry_run': McpArg.boolean('只预演不写入：实际执行后立即回滚，返回将改的字节'),
    },
    required: ['source', 'source_id'],
  ),
  McpToolDef(
    name: 'read_text',
    description: '读文本。三种用法：给 id 读一条；给 search 全表搜子串；'
        '给 from（+count）按范围批量读（看角色名表/章节名表这种连续区域最有用）。',
    properties: {
      'id': McpArg.integer('文本 ID'),
      'search': McpArg.string('要搜索的子串'),
      'from': McpArg.integer('批量读的起始 ID（与 id 二选一）'),
      'count': McpArg.integer('批量读条数或搜索命中上限，默认 30 / 50'),
      'rom': McpArg.string('版本代号'),
    },
  ),
  McpToolDef(
    name: 'write_text',
    mutating: true,
    description:
        '改写一条文本（明文/Huffman 均支持；含控制码的用〔XX〕占位保留）。'
        '返回写入模式与旧/新长度、旧/新指针（变长重定位时指针会变）。',
    properties: {
      'id': McpArg.integer('文本 ID'),
      'text': McpArg.string('新内容'),
      'rom': McpArg.string('版本代号'),
      'dry_run': McpArg.boolean('只预演不写入：实际执行后立即回滚，返回将改的字节'),
    },
    required: ['id', 'text'],
  ),
  McpToolDef(
    name: 'check_text_coverage',
    description:
        '检查一段文字在**当前 ROM** 上缺哪些字（写对话前先跑）。'
        '返回缺字列表、覆盖率、字库规模与建议。缺字不会报错，只会显示成空白——'
        '所以这是唯一能提前发现的检查。'
        '含〔XX〕控制码占位符的文本可直接传入，占位符不参与检查。',
    properties: {
      'text': McpArg.string('要检查的文字（可含〔XX〕控制码占位符）'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['text'],
  ),
  McpToolDef(
    name: 'list_chapter_scenes',
    description:
        '按场景列出某章对话：一场戏（一条文本记录）→ 一句一句（已按控制码切好）。'
        '比 list_chapter_dialogs 好用在能直接读懂剧情并定位到第几句；'
        '写回仍用 write_text（给 text_id 和整段 raw）。',
    properties: {
      'chapter': McpArg.integer('章节索引（0 基），默认 0'),
      'limit': McpArg.integer('最多返回几场，默认 50，上限 300'),
      'rom': McpArg.string('版本代号'),
    },
  ),
  McpToolDef(
    name: 'preview_dialog',
    description:
        '对话预览（AI 自查用）：按时间线返回每句的台词、控制码占位符、数据自洽问题。'
        '**说话人与头像目前为 null 且 speaker_source / portrait_source 标 unavailable**：'
        'FE 的对话文本不带说话人（名字由脚本的「插入名字」命令决定），'
        '静态提取给不出可靠结论，所以留空而不猜。'
        '改完对话后调一次就能自查：文本 ID 对不对、控制码有没丢、有没有越界。'
        '**返回的是工具解析结果，不是游戏画面**（不是实测，不能替代模拟器验证）。',
    properties: {
      'chapter': McpArg.integer('章节索引（0 基），默认 0'),
      'limit': McpArg.integer('最多返回几行，默认 40，上限 500'),
      'compact': McpArg.boolean('默认 true：省略 raw 与控制码明细，只留自查必需字段'),
      'rom': McpArg.string('版本代号'),
    },
  ),
  McpToolDef(
    name: 'preview_events',
    description:
        '事件触发预览（AI 自查用）：每条事件一行自然语言（「第 3 回合起，我方在 (14,9) 生成 1 个单位：琳」）'
        '、单位明细与坐标/ID 越界检查。改完坐标、道具、增援后调它验数据自洽。'
        '**不是游戏行为验证**（哪条事件真的会触发，要靠模拟器）。',
    properties: {
      'chapter': McpArg.integer('章节索引（0 基），默认 0'),
      'compact': McpArg.boolean('默认 true：单位明细只留关键字段（要完整字段传 false）'),
      'rom': McpArg.string('版本代号'),
    },
  ),
  McpToolDef(
    name: 'add_chapter_event',
    mutating: true,
    description:
        '给某一章**追加**一条触发事件（在事件列表末尾增加一条 + 它自己的「生成单位」脚本）。'
        '**只追加、不改既有脚本**：旧事件列表原样保留在 ROM 里，只改一个 4 字节指针，'
        '改坏了可 revert_changes。这是目前「加原版没有的新增援」的安全做法。'
        '给 dialogue_text_id（一个既有文本记录 ID）可让新事件的脚本在生成单位前先显示该句台词。',
    properties: {
      'chapter': McpArg.integer('章节索引（0 基）'),
      'type': McpArg.string('触发类型：turn（回合）/ character（角色）/ location（地点）'),
      'turn': McpArg.integer('type=turn 时的回合数 1..255'),
      'char_a': McpArg.integer('type=character 时的角色 ID（1 基）'),
      'char_b': McpArg.integer('type=character 时的第二个角色 ID（可省）'),
      'x': McpArg.integer('type=location 时的 X 坐标'),
      'y': McpArg.integer('type=location 时的 Y 坐标'),
      'dialogue_text_id': McpArg.integer(
          '可选：让新事件先显示某句台词的既有文本记录 ID（先改好那段文本，再填它的 ID）。本 ROM 定位不到显示命令时会拒绝'),
      'units': McpArg.objectArray('要生成/加入的单位（至少一个）', {
        'char_id': McpArg.integer('角色 ID（1 基）'),
        'class_id': McpArg.integer('职业 ID（0 基，0=角色默认）'),
        'level': McpArg.integer('等级 0..31'),
        'x': McpArg.integer('X 坐标'),
        'y': McpArg.integer('Y 坐标'),
        'allegiance': McpArg.integer('阵营 0=我方 1=友军 2=敌方'),
        'items': McpArg.array('携带道具 ID（最多 4 个）'),
      }),
      'rom': McpArg.string('版本代号'),
      'dry_run': McpArg.boolean('只预演不写入：实际执行后立即回滚，返回将改的字节'),
    },
    required: ['chapter', 'type', 'units'],
  ),
  McpToolDef(
    name: 'remove_last_chapter_event',
    mutating: true,
    description:
        '删除**本工具追加的**最后一条事件（靠特征自证：脚本必须落在本工具写过的区域）。'
        '不是本工具追加的会拒绝并提示用 revert_changes / 快照回退，不会误删原版内容。',
    properties: {
      'chapter': McpArg.integer('章节索引（0 基）'),
      'type': McpArg.string('触发类型：turn / character / location'),
      'rom': McpArg.string('版本代号'),
      'dry_run': McpArg.boolean('只预演不写入：实际执行后立即回滚'),
    },
    required: ['chapter', 'type'],
  ),
  McpToolDef(
    name: 'list_workspace_roms',
    description:
        '列出外部工作区目录里的 ROM（用户已授权的存放目录）。'
        'AI 想知道「手头有哪些基底可选」时先调它，再配合 open_workspace_rom 自己打开。'
        '未设置工作区时 configured=false 并给出提示。',
    properties: const {},
  ),
  McpToolDef(
    name: 'open_workspace_rom',
    mutating: false,
    description:
        '按文件名打开外部工作区里的一个 ROM（不写盘，只载入到工作区）。'
        '文件名先从 list_workspace_roms 拿。打开后会成为当前会话。',
    properties: {
      'name': McpArg.string('工作区里的 ROM 文件名（含 .gba 扩展名）'),
    },
    required: ['name'],
  ),
  McpToolDef(
    name: 'list_asset_library',
    description:
        '列出素材库目录里的文件（用户已授权的素材存放目录，如导出的肖像/战斗动画帧/图标）。'
        '返回目录路径(dir_uri)、显示名(dir_name)与文件清单(assets)。AI 想确认素材库现状或读某个素材时用它。'
        '未设置素材库时 configured=false 并给出提示。',
    properties: {
      'limit': McpArg.integer('最多列出多少个文件，默认 100'),
    },
  ),
  McpToolDef(
    name: 'read_asset',
    description:
        '读素材库里的一个文件，返回 base64（AI 可直接看图 / 读内容）与 mime。'
        '文件超过 max_bytes（默认 512KB）会拒绝并提示，避免 base64 撑爆响应。'
        '文件名先用 list_asset_library 拿。',
    properties: {
      'name': McpArg.string('素材库里的文件名'),
      'max_bytes': McpArg.integer('允许返回的最大字节数，默认 512000；文件更大则拒绝并提示'),
    },
    required: ['name'],
  ),
  McpToolDef(
    name: 'write_asset',
    mutating: true,
    dryRunnable: false,
    description:
        '把一份素材写进素材库（同名原地覆盖）。内容给 base64（图片等二进制）或 text（文本）之一。'
        '不碰 ROM、不支持 dry_run；写错可再写一次覆盖或在 App 里删。',
    properties: {
      'name': McpArg.string('要写入的文件名，如 lyn.png'),
      'base64': McpArg.string('内容的 base64（图片等二进制；与 text 二选一）'),
      'text': McpArg.string('文本内容（与 base64 二选一）'),
    },
    required: ['name'],
  ),
  McpToolDef(
    name: 'list_assets',
    description:
        '列出当前项目（= 当前 ROM）的素材库：只返回 handle 与小元数据，'
        '**不返回任何文件内容**。可选 type 过滤（image / portrait_sheet / map_plan / audio / binary）。'
        '素材是项目级的（按 ROM 指纹隔离），换 ROM 就是另一套素材。',
    properties: {
      'type': McpArg.string('只看某一类（可省）'),
      'rom': McpArg.string('版本代号'),
    },
  ),
  McpToolDef(
    name: 'asset_info',
    description: '看单个素材的元数据（类型/尺寸/大小/引用），不含内容。',
    properties: {
      'handle': McpArg.string('素材 handle（list_assets 里拿）'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['handle'],
  ),
  McpToolDef(
    name: 'import_asset_from_library',
    description:
        '把素材库（用户已授权的设备目录）里的一个文件导进本项目素材库，返回 handle。'
        '**字节全程在 App 内部搬运，不经过 AI**，所以 1MB 的图也一步入库——'
        '要导大文件就用它，不要用 read_asset 读 base64。',
    properties: {
      'name': McpArg.string('素材库里的文件名（先 list_asset_library）'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['name'],
  ),
  McpToolDef(
    name: 'import_asset',
    mutating: true,
    description:
        '把一个素材（handle）写进 ROM。**只接受 handle，不接受 base64。**'
        '目前支持 target={kind:"portrait", id:<肖像ID>}（PNG → 4bpp + 16 色量化在 App 侧做）。'
        '地图/音频的 Converter 还没接上，会明确报错。',
    properties: {
      'handle': McpArg.string('素材 handle'),
      'target': McpArg.string('目标槽位：{"kind":"portrait","id":11}'),
      'map_face': McpArg.boolean('是否同时换 32×32 地图小头像（默认 true）'),
      'fixed_expression': McpArg.boolean('是否固定嘴型/眨眼帧（默认 true，避免串色）'),
      'dry_run': McpArg.boolean('只预演不写入：实际执行后立即回滚'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['handle', 'target'],
  ),
  McpToolDef(
    name: 'export_asset_from_rom',
    description:
        '把 ROM 里的素材导出成素材库里的一个 handle（**不返回字节**）。'
        'source.kind：portrait_png（配 id，可选 image=face/map_face/class_card）'
        '或 battle_anim_frame（配 id/mode/frame/palette）。',
    properties: {
      'source': McpArg.string('来源：{"kind":"portrait_png","id":11}'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['source'],
  ),
  McpToolDef(
    name: 'copy_asset_between_sessions',
    mutating: true,
    description:
        '跨 ROM 直连：把一份素材（handle）写进另一个已打开的 ROM。'
        '全程内存，不落盘、不经 AI。to 是目标 ROM 版本代号。'
        '目前只支持 target={kind:"portrait", id:<肖像ID>}。',
    properties: {
      'handle': McpArg.string('素材 handle'),
      'to': McpArg.string('目标 ROM 版本代号（如 FE8U）'),
      'target': McpArg.string('{"kind":"portrait","id":11}'),
      'map_face': McpArg.boolean('同时换地图小头像（默认 true）'),
      'dry_run': McpArg.boolean('只预演不写入'),
    },
    required: ['handle', 'to', 'target'],
  ),
  McpToolDef(
    name: 'delete_asset',
    mutating: true,
    dryRunnable: false,
    description:
        '删除一个素材。被 ROM 槽位引用时默认拒绝（会列出引用），'
        '确实要删传 force=true。',
    properties: {
      'handle': McpArg.string('素材 handle'),
      'force': McpArg.boolean('有引用也强删（默认 false）'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['handle'],
  ),
  McpToolDef(
    name: 'list_chapter_dialogs',
    description:
        '列出某章事件脚本引用的对话文本（按出现顺序、按 ID 去重）。'
        'preview 里的〔XX〕是控制码占位；改对话用 write_text(id) 直接改，'
        '变长会自动找空位重指指针。',
    properties: {
      'chapter': McpArg.integer('章节索引（0 基），默认 0'),
      'limit': McpArg.integer('最多返回几条，默认 50，上限 300'),
      'rom': McpArg.string('版本代号'),
    },
  ),
  McpToolDef(
    name: 'list_cheat_presets',
    description: '列出修改器预设（批量操作，已实机验证过）与可选的作用范围口径。',
    properties: {'rom': McpArg.string('版本代号')},
  ),
  McpToolDef(
    name: 'apply_cheat_preset',
    mutating: true,
    description: '应用一个修改器预设。批量改成长率/熟练度/能力上限这类操作用它，'
        '比逐个 set_unit_field 稳（预设内部已处理字段名与档位）。',
    properties: {
      'id': McpArg.string('预设 ID，见 list_cheat_presets'),
      'criterion': McpArg.string('作用范围口径名（默认 reciprocal 仅我方）'),
      'rom': McpArg.string('版本代号'),
      'dry_run': McpArg.boolean('只预演不写入：实际执行后立即回滚，返回将改的字节'),
    },
    required: ['id'],
  ),
  McpToolDef(
    name: 'list_playable_units',
    description: '列出某个判据下算作「我方」的角色索引（修改器预设只作用在这份名单上）。'
        '想确认「为什么某个角色没被改」时查它。',
    properties: {
      'criterion': McpArg.string('判据名（默认 reciprocal），可选值见返回的 criteria'),
      'rom': McpArg.string('版本代号'),
    },
  ),
  McpToolDef(
    name: 'find_free_space',
    description: '找连续空闲区（默认依次找 0xFF 与 0x00 填充），'
        '返回偏移、GBA 地址与长度。写入新数据前先查它。',
    properties: {
      'size': McpArg.integer('需要的字节数，默认 1024'),
      'limit': McpArg.integer('最多返回几块，默认 8'),
      'fill': McpArg.integer('只找指定填充值（0xFF 或 0）；省略则两种都找'),
      'rom': McpArg.string('版本代号'),
    },
  ),
  McpToolDef(
    name: 'read_hex',
    description: '按文件偏移读一段原始字节。',
    properties: {
      'offset': McpArg.integer('文件偏移'),
      'length': McpArg.integer('字节数，默认 32，上限 4096'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['offset'],
  ),
  McpToolDef(
    name: 'write_hex',
    mutating: true,
    description: '按文件偏移写原始字节（不做值域校验，改机器码用）。支持 dry_run 预演。',
    properties: {
      'offset': McpArg.integer('文件偏移'),
      'bytes': McpArg.array('要写入的字节数组'),
      'rom': McpArg.string('版本代号'),
      'dry_run': McpArg.boolean('只预演不写入：返回会改哪些字节（默认 false）'),
    },
    required: ['offset', 'bytes'],
  ),
  McpToolDef(
    name: 'list_chapter_events',
    description: '读一章的事件触发条件与剧情增援单位（只读）。',
    properties: {
      'chapter': McpArg.integer('章节索引'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['chapter'],
  ),
  McpToolDef(
    name: 'revert_changes',
    mutating: true,
    // 它会清空 edits 记录；预演后回滚会把数据还原但编辑记录丢了，两边不一致。
    dryRunnable: false,
    description: '撤销该 ROM 的全部改动，回到刚打开时的状态。',
    properties: {'rom': McpArg.string('版本代号')},
  ),
  McpToolDef(
    name: 'set_chapter_event_unit',
    mutating: true,
    description: '改事件脚本里动态生成的单位（剧情增援）的字段：'
        '角色/职业/等级/坐标/阵营/携带道具。'
        '**只做原地字段覆盖**，不会插入或删除脚本指令。addr 为结构体地址。',
    properties: {
      'addr': McpArg.integer('单位结构体地址（文件偏移）'),
      'char_id': McpArg.integer('角色 ID'),
      'class_id': McpArg.integer('职业 ID（0 = 用角色默认职业）'),
      'level': McpArg.integer('等级 0~31'),
      'x': McpArg.integer('X 坐标'),
      'y': McpArg.integer('Y 坐标'),
      'allegiance': McpArg.integer('阵营：0 我方 1 敌方 2 友军'),
      'items': McpArg.array('四个道具槽的 ID（从第 1 格起逐项覆盖，0 = 空；最多 4 个）'),
      'dry_run': McpArg.boolean('只预演不写入'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['addr'],
  ),
  McpToolDef(
    name: 'save_rom_to_file',
    description: '把改后的 ROM 写到 App 私有导出目录（filesDir/exports），返回绝对路径。'
        '不弹系统对话框，适合 MCP 里直接落盘。',
    properties: {
      'name': McpArg.string('文件名（默认加 _modified 后缀）'),
      'rom': McpArg.string('版本代号'),
    },
  ),
  McpToolDef(
    name: 'set_chapter_unit',
    mutating: true,
    description: '改章节初始单位（静态表里那批，不是事件动态生成的）的字段：角色/职业/等级/坐标/阵营。'
        '按「章节 + 入口 + 序号」定位，不用自己算地址。**只原地覆盖，不增删条目**。',
    properties: {
      'chapter': McpArg.integer('章节索引（0 基）'),
      'slot': McpArg.string('入口名（默认 defaultSlot），可选值见 list_chapter_events 或 get_map 响应'),
      'index': McpArg.integer('该入口内第几条（0 基，默认 0）'),
      'char_id': McpArg.integer('角色 number（1 基，= 表内索引 + 1）'),
      'class_id': McpArg.integer('职业 ID（0 基索引）'),
      'level': McpArg.integer('等级 0~31'),
      'x': McpArg.integer('X 坐标'),
      'y': McpArg.integer('Y 坐标'),
      'allegiance': McpArg.integer('阵营：0 我方 1 友军 2 敌方'),
      'dry_run': McpArg.boolean('只预演不写入'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['chapter'],
  ),
  McpToolDef(
    name: 'import_portrait_image',
    mutating: true,
    description: '把一张 PNG 图片转成游戏肖像，写入指定条目：正脸、调色板、'
        '32×32 地图小头像（默认一起换），并把表情设为固定（关闭嘴型/眨眼帧）。'
        '自动缩放到 96×80、中位切分量化到 16 色、索引 0 作透明背景。'
        '**固定表情是必需的**：旧嘴型/眼睛与正脸共用同一套 16 色调色板，'
        '只换正脸会让它们串色。PNG 解码同步；JPG 请先在界面转成 PNG。',
    properties: {
      'target_id': McpArg.integer('要替换的肖像 ID（见 list_portraits）'),
      'png_base64': McpArg.string('PNG 图片的 base64（只支持非交错 8 位 PNG）'),
      'fit': McpArg.string('contain（完整放入，默认）/ cover（填满裁切）'),
      'strategy': McpArg.string(
          '量化风格（默认 natural）：natural 自然 / classic 高对比纯色块（原版质感）/ dither 误差扩散抖动（细腻渐变）/ bright 提亮高饱和（明亮色彩）'),
      'fixed_expression': McpArg.boolean(
          '默认 true：关闭嘴型与眨眼帧（旧素材与正脸共用调色板，留着会串色）'),
      'map_face': McpArg.boolean('默认 true：同时生成并替换 32×32 地图小头像'),
      'dry_run': McpArg.boolean('只预演不写入'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['target_id', 'png_base64'],
  ),
  McpToolDef(
    name: 'attach_portrait_to_unit',
    mutating: true,
    description: '换脸的最后一步：把肖像 ID 写进角色的 face 字段（自动处理 FE6 的 +1 换算）。'
        'import_portrait 只换素材不会自动挂到角色，需要它配合才算真的换脸。',
    properties: {
      'id': McpArg.integer('单位表索引（0 基）'),
      'portrait_id': McpArg.integer('要挂上的肖像 ID（见 list_portraits）'),
      'dry_run': McpArg.boolean('只预演不写入'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['id', 'portrait_id'],
  ),
  McpToolDef(
    name: 'clone_unit',
    mutating: true,
    description: '把一条单位结构体克隆到空槽并自动修正 unit ID（必须 = 序号+1，否则表边界会在那里断掉）。'
        '**只填空槽，不扩容整表**：原版三作都是满表，此工具主要服务改版。',
    properties: {
      'from': McpArg.integer('源单位索引（0 基）'),
      'to': McpArg.integer('目标空槽索引（省略＝表尾第一个空槽）'),
      'dry_run': McpArg.boolean('只预演不写入'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['from'],
  ),
  McpToolDef(
    name: 'validate',
    description: 'ROM 结构自检：检查单位/职业/道具表的指针与边界、文本可读性、'
        '地图与肖像表是否还正常。改完 ROM 后建议先跑它，能提前发现「游戏起不来」这类错。',
    properties: {'rom': McpArg.string('版本代号')},
  ),
  McpToolDef(
    name: 'validate_rom',
    description: '改完后的静态体检（比 validate 全面）：表基址/边界、单位与职业/道具的 ID 是否连续、'
        '角色默认职业是否越界、道具指针、支援引用、章节单位坐标是否在本章地图内。'
        'deep=false 只查表与 ID（快）；默认深检扫全部章节。',
    properties: {
      'deep': McpArg.boolean('是否深检（默认 true；false 只查表与 ID）'),
      'rom': McpArg.string('版本代号'),
    },
  ),
  McpToolDef(
    name: 'describe_rom',
    description: '一次调用拿到当前 ROM 的完整能力清单：版本/文本引擎、三张主表的条目数与可用 ID 范围、'
        '可编辑字段名、章节清单（带标题）、可选的「我方」判据、已知限制。'
        '**开局先调它**，就不用猜偏移与字段名。',
    properties: {'rom': McpArg.string('版本代号')},
  ),
  McpToolDef(
    name: 'snapshot',
    mutating: true,
    dryRunnable: false,
    description: '存一个可回滚的快照（事务起点）。之后改错了用 rollback 回到这里。'
        '也可配合 dry_run=false 的批量操作：「先 snapshot，再改，不满意 rollback」。',
    properties: {
      'label': McpArg.string('给自己看的标记，如「改之前」'),
      'rom': McpArg.string('版本代号'),
    },
  ),
  McpToolDef(
    name: 'rollback',
    mutating: true,
    dryRunnable: false,
    description: '回到某个快照（不给 id 就回最近一个）。与 revert_changes 不同：'
        'revert_changes 只能回刚打开时，rollback 能回到任意一次 snapshot 之后。',
    properties: {
      'id': McpArg.string('快照 ID，见 list_snapshots；省略＝最近一个'),
      'rom': McpArg.string('版本代号'),
    },
  ),
  McpToolDef(
    name: 'list_snapshots',
    description: '列出已有快照与当前已改字节数。',
    properties: {'rom': McpArg.string('版本代号')},
  ),
  McpToolDef(
    name: 'list_changes',
    description: '差分视图：当前 ROM 与刚打开时的差异，按区域（单位表/职业表/道具表/其他）分组统计；'
        '有快照时额外给出「自上次快照以来改了多少字节」。',
    properties: {'rom': McpArg.string('版本代号')},
  ),
  McpToolDef(
    name: 'save_rom',
    description: '导出改后的完整 ROM（base64）。不弹系统对话框，由客户端自己落盘。',
    properties: {'rom': McpArg.string('版本代号')},
  ),
  McpToolDef(
    name: 'add_reinforcement',
    mutating: true,
    description: '事件模板：给本章追加一条「第 N 回合在指定坐标生成指定单位」的剧情增援。'
        '做法是把本章的事件列表搬到空位、追加一条新条目、只重指那个 4 字节指针，'
        '**不改动任何已有脚本**（三作方言都支持）。坐标必须在本章地图内。'
        '给 dialogue_text_id（既有文本记录 ID）可让新事件先显示该句台词。',
    properties: {
      'chapter': McpArg.integer('章节索引（0 基）'),
      'turn': McpArg.integer('触发的回合数 1..255'),
      'dialogue_text_id': McpArg.integer(
          '可选：让新事件先显示某句台词的既有文本记录 ID。本 ROM 定位不到显示命令时会拒绝'),
      'units': McpArg.objectArray('增援单位数组', {
        'char_id': McpArg.integer('角色 ID（1 基，= 表内索引 + 1）'),
        'class_id': McpArg.integer('职业 ID（0 基）；0 = 用角色默认职业'),
        'level': McpArg.integer('等级 0..31'),
        'x': McpArg.integer('X 坐标'),
        'y': McpArg.integer('Y 坐标'),
        'allegiance': McpArg.integer('阵营：0 我方 1 友军 2 敌方'),
        'items': McpArg.array('携带道具 ID（最多 4 个，0 = 空）'),
      }),
      'dry_run': McpArg.boolean('只预演不写入'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['chapter', 'turn', 'units'],
  ),
  McpToolDef(
    name: 'simulate_growth',
    description: '成长模拟：按当前成长率算角色从当前等级到目标等级的期望值/最坏/最好曲线，'
        '并标出哪些属性会撑到职业上限。改数值前先看它，就知道「改成这样到底强多少」。',
    properties: {
      'id': McpArg.integer('单位表索引（0 基）'),
      'target_level': McpArg.integer('目标等级，默认 20'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['id'],
  ),
  McpToolDef(
    name: 'simulate_battle',
    description: '战斗模拟：角色 A 拿武器 W 打角色 B，给伤害/命中/必杀/追击次数/反击/能否击杀。'
        '**近似值**（不计地形、支援、三角武器、特効），用于对比改动前后的强弱。',
    properties: {
      'attacker': McpArg.integer('攻击方单位索引'),
      'weapon': McpArg.integer('武器道具索引'),
      'defender': McpArg.integer('防守方单位索引'),
      'distance': McpArg.integer('距离（决定能否反击，默认 1）'),
      'attacker_hp': McpArg.integer('攻击方当前 HP（默认满血）'),
      'defender_hp': McpArg.integer('防守方当前 HP（默认满血）'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['attacker', 'weapon', 'defender'],
  ),
  McpToolDef(
    name: 'export_recipe',
    description: '把当前改动导出成「修改配方」JSON（逐段 offset/before/after），可在同版本同结构的 ROM 上用 apply_recipe 重放。'
        'format=patch 时额外给一段紧凑文本便于人工核对。'
        'semantic 可传一份「意图层」JSON（{"presets":[{"id":"unit_max_growth","targets":["琳"]}],"items":{"铁剑":{"必杀":30}}}，'
        '目标用角色/道具/职业名或 0 基下标，字段名与 set_*_field 的 field 同名），'
        '随配方一起导出后在同版本其它 ROM 上也能重放。',
    properties: {
      'format': McpArg.string('json（默认）或 patch'),
      'semantic': McpArg.string('可选：语义层 JSON 文本（预设/字段意图），与字节层并存'),
      'rom': McpArg.string('版本代号'),
    },
  ),
  McpToolDef(
    name: 'apply_recipe',
    description: '应用一份修改配方（export_recipe 的产物或手工 JSON）到当前 ROM。'
        '两层：语义层（presets/units/items/classes，按名字重新解析，同版本可用）与'
        '字节层（chunks，只在 ROM 指纹一致时重放，before 对不上的分段逐条跳过并报告）。'
        '改完建议再跑 validate_rom 体检；不满意可 revert_all 一键还原。',
    properties: {
      'text': McpArg.string('配方 JSON 文本（export_recipe 的完整返回或 semantic-only 片段）'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['text'],
    mutating: true,
  ),
  McpToolDef(
    name: 'set_chest_item',
    description: '改本章指定坐标宝箱的奖励道具（事件条目第 2 字低 16 位，高 16 位原样保留；'
        '只改这一处字节，可 revert）。坐标与 list_chapter_events 里的 condition 一致。',
    properties: {
      'chapter': McpArg.integer('章节索引（0 基）'),
      'x': McpArg.integer('宝箱坐标 X'),
      'y': McpArg.integer('宝箱坐标 Y'),
      'item': McpArg.integer('新奖励道具索引（0 基；list_items 可查）'),
      'dry_run': McpArg.boolean('只预演不写入'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['chapter', 'x', 'y', 'item'],
    mutating: true,
  ),
  McpToolDef(
    name: 'set_shop_item',
    description: '把本章指定坐标商店的第 slot 格换成另一件道具。商店列表是 u16 道具数组（0 结尾），'
        '**只能原地替换、不能增删**（列表在 ROM 里挨着排布，扩容会改坏别的商店）。'
        '价格改不了——价格是道具表字段（单价/耐久），走 set_item_field。',
    properties: {
      'chapter': McpArg.integer('章节索引（0 基）'),
      'x': McpArg.integer('商店坐标 X'),
      'y': McpArg.integer('商店坐标 Y'),
      'slot': McpArg.integer('要替换的第几格（0 基，范围内）'),
      'item': McpArg.integer('新道具索引（0 基）'),
      'dry_run': McpArg.boolean('只预演不写入'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['chapter', 'x', 'y', 'slot', 'item'],
    mutating: true,
  ),
  McpToolDef(
    name: 'compare_weapons',
    description: '全武器对比：unit 逐个试完所有有威力的武器打 target，按每回合期望伤害降序排。'
        '公式与 simulate_battle 完全一致（近似值，不计职业持枪限制/地形/支援），'
        '用来回答「谁配什么武器 / 这把武器给谁最强」。',
    properties: {
      'unit': McpArg.integer('攻方单位索引（0 基）'),
      'target': McpArg.integer('守方单位索引（0 基）'),
      'distance': McpArg.integer('距离（默认 1）'),
      'limit': McpArg.integer('取前 N 把（默认 30）'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['unit', 'target'],
  ),
  McpToolDef(
    name: 'find_replace_text',
    description: '全 ROM 文本批量查找/替换：遍历全部文本条目，把显示文本（控制码占位符形态）里的 '
        'find 换成 replace，写回走 write_text 同一通道（变长自动重定位），可 revert_all 整体回退。'
        '不带 ids 时替换**全部命中条目**；先带 dry_run=true 预演看命中条数。',
    properties: {
      'find': McpArg.string('查找内容（必填，非空）'),
      'replace': McpArg.string('替换为（可为空 = 删除）'),
      'ids': McpArg.array('可选：只在这批文本条目 ID 里替换；不传 = 全部命中条目'),
      'dry_run': McpArg.boolean('只预演不写入（返回命中数与 ID 列表）'),
      'rom': McpArg.string('版本代号'),
    },
    required: ['find', 'replace'],
    mutating: true,
  ),
];

/// 一个 MCP 资源（客户端可以主动拉取的只读内容）。
///
/// 资源与工具的区别：资源是「客户端知道有这个东西就会去读」的稳定入口，
/// 比如开局读 summary，就不用先调 describe_rom。内容由当前打开的 ROM 实时生成，
/// 没有打开 ROM 时返回提示而不是报错。
class McpResource {
  final String uri;
  final String name;
  final String description;
  final String mimeType;

  const McpResource({
    required this.uri,
    required this.name,
    required this.description,
    this.mimeType = 'text/markdown',
  });

  Map<String, dynamic> get descriptor => {
        'uri': uri,
        'name': name,
        'description': description,
        'mimeType': mimeType,
      };

  Future<String> readAll(McpServer server) async {
    // 工作区/素材库列表与「是否打开了 ROM」无关：没打开任何 ROM 时也能看
    if (uri == 'fe://workspace/roms') return _workspaceRoms(null);
    if (uri == 'fe://workspace/assets') return _assetLibrary();
    final s = server.currentSessionOrNull();
    if (s == null) return '# 还没有打开任何 ROM\n\n请先在 App 里打开一个 GBA 火纹 ROM。';
    switch (uri) {
      case 'fe://rom/summary':
        return _summary(server, s);
      case 'fe://rom/fields':
        return _fields(s);
      case 'fe://rom/chapters':
        return _chapters(s);
      default:
        return '# 未知资源：$uri';
    }
  }

  /// 工作区的 ROM 列表（Markdown 渲染，客户端直接展示）。
  Future<String> _workspaceRoms(RomSession? _) async {
    final ws = ExternalWorkspace.instance;
    final dir = ws.dir;
    final sb = StringBuffer('# 外部工作区\n\n');
    if (dir == null) {
      sb.writeln('还没设置工作区目录。');
      sb.writeln();
      sb.writeln('请用户在 App 主页点「设置工作区」选一个存放 ROM 的目录，'
          '之后这里就会列出目录里的 .gba 文件，也可以直接用 `open_workspace_rom` 打开。');
      return sb.toString();
    }
    sb.writeln('- 目录：${dir.name}');
    sb.writeln('- 路径：${dir.uri}');
    final roms = await ws.listRoms();
    sb.writeln('- ROM 数量：${roms.length}');
    sb.writeln();
    if (roms.isEmpty) {
      sb.writeln('目录里没有 .gba 文件。');
      return sb.toString();
    }
    sb.writeln('| 文件名 | 大小 |');
    sb.writeln('|---|---|');
    for (final r in roms) {
      sb.writeln('| ${r.name} | ${r.sizeLabel} |');
    }
    sb.writeln();
    sb.writeln('用 `open_workspace_rom(name)` 打开其中一个。');
    return sb.toString();
  }

  /// 素材库文件清单（Markdown 渲染，客户端直接展示）。
  Future<String> _assetLibrary() async {
    final lib = AssetLibrary.instance;
    final dir = lib.dir;
    final sb = StringBuffer('# 素材库\n\n');
    if (dir == null) {
      sb.writeln('还没设置素材库目录。');
      sb.writeln();
      sb.writeln('请用户在 App 里选一个素材库目录（存导出肖像/动画帧/图标等），'
          '之后这里就会列出目录里的文件，也可以用 `list_asset_library` 查看。');
      return sb.toString();
    }
    sb.writeln('- 目录：${dir.name}');
    sb.writeln('- 路径：${dir.uri}');
    final files = await lib.list();
    if (files.isEmpty) {
      sb.writeln('- （空目录）');
      return sb.toString();
    }
    sb.writeln('| 文件名 | 大小 |');
    sb.writeln('|---|---|');
    for (final f in files) {
      sb.writeln('| ${f.name} | ${f.sizeLabel} |');
    }
    sb.writeln();
    sb.writeln('用 `list_asset_library` 查看 JSON 清单。');
    return sb.toString();
  }

  String _summary(McpServer server, RomSession s) {
    final rom = s.liveRom;
    final sb = StringBuffer()
      ..writeln('# ${s.versionId} ${s.versionName}')
      ..writeln()
      ..writeln('- 文件：${s.fileName}')
      ..writeln('- 大小：${rom.length} 字节')
      ..writeln('- 文本引擎：${rom.textEncoding.name}'
          '${s.hasZhTable ? '（已挂中文码表）' : ''}'
          '${s.textWritable ? '，可写' : '，不可写'}')
      ..writeln('- 单位 ${rom.unitCount} / 职业 ${rom.classCount} / 道具 ${rom.itemCount}')
      ..writeln('- 已改动 ${s.rom.changedByteCount} 字节'
          '${s.snapshots.all.isEmpty ? '' : '，快照 ${s.snapshots.all.length} 个'}')
      ..writeln()
      ..writeln('## 操作约定')
      ..writeln()
      ..writeln('1. 改之前先 `describe_rom` 或读本资源，不要猜偏移。')
      ..writeln('2. 不确定结果时加 `dry_run: true`：工具会真的执行再回滚，返回将改的字节。')
      ..writeln('3. 批量改动前 `snapshot`，不满意 `rollback`。')
      ..writeln('4. 改完 `validate_rom` 体检。')
      ..writeln('5. 判「我方」用 `list_playable_units`，**不要**用索引范围猜。')
      ..writeln('6. 想确认「改成这样强多少」用 `simulate_growth` / `simulate_battle`（近似值）。')
      ..writeln('7. 要把改动交给别人重放，用 `export_recipe` 导出配方（带上 semantic 层），'
              '对方用 `apply_recipe` 一键应用，不要直接发 ROM。');
    return sb.toString();
  }

  String _fields(RomSession s) {
    final rom = s.liveRom;
    final sb = StringBuffer()
      ..writeln('# 可编辑字段（${s.versionId}）')
      ..writeln()
      ..writeln('字段名直接传给 `set_unit_field` / `set_class_field` / `set_item_field`。')
      ..writeln()
      ..writeln('## 角色（set_unit_field）')
      ..writeln()
      ..writeln(unitEditableFieldsFor(fe6: rom.isFe6).map((f) => f.label).join('、'))
      ..writeln()
      ..writeln('## 职业（set_class_field）')
      ..writeln()
      ..writeln(classEditableFieldsFor(fe6: rom.isFe6).map((f) => f.label).join('、'))
      ..writeln()
      ..writeln('## 道具（set_item_field）')
      ..writeln()
      ..writeln(itemEditableFieldsFor(fe6: rom.isFe6).map((f) => f.label).join('、'))
      ..writeln()
      ..writeln('## 不能直接改的（要走专用工具）')
      ..writeln()
      ..writeln('- 道具标志位（无限耐久等）→ `apply_cheat_preset`（只改特定位）')
      ..writeln('- 支援关系 → 修改器预设「全员支援 A」')
      ..writeln('- 章节单位坐标/等级 → `get_map` 后走界面，或 `set_chapter_event_unit`（事件单位）');
    return sb.toString();
  }

  String _chapters(RomSession s) {
    final placement = UnitPlacement(s.rom);
    final map = MapReader(s.liveRom);
    final count = placement.chapterCount;
    final sb = StringBuffer()
      ..writeln('# 章节清单（${s.versionId}，共 $count 章）')
      ..writeln()
      ..writeln('章节号 0 基。显示名用 `read_text` 搜，或用下表 title（游戏标题卡副标题）。')
      ..writeln();
    for (var i = 0; i < count; i++) {
      final title = placement.chapterTitle(i);
      final m = map.available ? map.chapterMap(i) : null;
      sb.writeln('- $i：${title.isEmpty ? '（无标题）' : title}'
          '${m == null ? '' : ' · ${m.width}×${m.height}'}'
          '${placement.eventGroupOffset(i) > 0 ? ' · 有事件' : ''}');
    }
    return sb.toString();
  }
}

/// 一个 MCP prompt（客户端可选的「任务模板」）。
///
/// 它解决的是「AI 不知道怎么用这个工具」：与其让用户自己描述需求，
/// 不如把常见改版任务写成带参数模板，客户端展示成一键入口。
class McpPrompt {
  final String name;
  final String description;
  final Map<String, String> arguments;
  final String Function(Map<String, String> args) render;

  const McpPrompt({
    required this.name,
    required this.description,
    required this.arguments,
    required this.render,
  });

  Map<String, dynamic> get descriptor => {
        'name': name,
        'description': description,
        'arguments': [
          for (final e in arguments.entries)
            {'name': e.key, 'description': e.value, 'required': true}
        ],
      };
}

const _workflowPrefix = '先用 describe_rom 读清这个 ROM 的实际情况（不要猜字段名与 ID）；'
    '每次不确定结果都先加 dry_run: true 看将改的字节；批量前先 snapshot，'
    '改完用 validate_rom 体检；不满意用 rollback / revert_changes。\n\n';

final List<McpPrompt> mcpPrompts = [
  McpPrompt(
    name: 'buff_character',
    description: '把一个角色改成强力版（成长率、能力、熟练度一起提）',
    arguments: {'character': '角色名或单位 ID'},
    render: (a) =>
        '$_workflowPrefix把角色「${a['character'] ?? '（未指定角色）'}」改成强力版：'
            '先用 list_units 找到它的 ID，get_unit 看当前值，'
            '然后把成长率提到 100~150、熟练度提到 S、等级和基础属性按需提高。'
            '只改这一个角色，别用 apply_cheat_preset 的批量口径（会连敌人一起加强）。'
            '最后告诉我改了哪些字段、旧值新值，以及 validate_rom 的结论。',
  ),
  McpPrompt(
    name: 'harder_chapter',
    description: '把第 N 章改成高难度（敌人等级/属性、增援）',
    arguments: {'chapter': '章节索引（0 基）'},
    render: (a) =>
        '$_workflowPrefix把第 ${a['chapter'] ?? '（未指定章节）'} 章改成高难度：'
            '先 list_chapters 确认章节索引，list_chapter_events 看有哪些增援事件，'
            '再用 set_chapter_event_unit 提高敌方增援的等级/属性（只做原地覆盖，不会插入指令）。'
            '注意 unit 表没有阵营字段，别用「改单位表」来加强敌人。'
            '最后列出改了哪些事件单位。',
  ),
  McpPrompt(
    name: 'rebalance_weapon',
    description: '调一件武器的数值（威力/命中/重量/必杀/耐久/射程）',
    arguments: {'weapon': '武器名或道具 ID'},
    render: (a) =>
        '$_workflowPrefix调「${a['weapon'] ?? '（未指定武器）'}」的数值：'
            '用 list_items 找到 ID，get_item 看当前值与取值范围，'
            '再按我的要求改（字段名以 get_item 返回的为准）。'
            '射程是合法码集合（不是普通数值），超出合法值会被拒绝写入——'
            '先看 get_item 的 steps 说明再填。改完给对比表。',
  ),
  McpPrompt(
    name: 'replace_portrait',
    description: '换脸：从另一个已打开 ROM 搬一张肖像过来并挂到角色上',
    arguments: {'character': '目标角色名', 'source': '源 ROM 版本代号', 'source_portrait': '源肖像 ID'},
    render: (a) =>
        '$_workflowPrefix把角色「${a['character'] ?? '（未指定角色）'}」的脸换成'
            '${a['source'] ?? '（未指定源 ROM）'} 的肖像 ${a['source_portrait'] ?? '（未指定肖像 ID）'}：'
            '先 list_roms 确认源 ROM 已打开，get_portrait_png 看那是不是想要的脸，'
            'portrait_usage 确认要覆盖的目标条目影响面，'
            '然后 import_portrait（给 target_id＝替换，最安全）——'
            '移植后不会自动挂到角色，还要把肖像 ID 写进角色 face 字段才算换脸。',
  ),
  McpPrompt(
    name: 'make_stronger_start',
    description: '让开局更轻松（我方成长率/熟练度/上限整体提高）',
    arguments: {},
    render: (a) =>
        '$_workflowPrefix让开局更轻松：用 apply_cheat_preset 依次应用'
            '「成长率拉满」「熟练度 S」「能力上限 50」（口径用默认 reciprocal 仅我方）。'
            '先 list_cheat_presets 确认可用预设 ID，'
            '应用前 list_playable_units 看会影响哪些角色——如果混入了敌方角色，'
            '告诉我而不是直接应用。全部应用完跑 validate_rom。',
  ),
  McpPrompt(
    name: 'strengthen_one_character',
    description: '加强某个角色全套（成长+属性+熟练度+职业上限+经验分母）',
    arguments: {'character': '角色名或单位 ID'},
    render: (a) =>
        '$_workflowPrefix把「${a['character'] ?? '（未指定角色）'}」整套加强，步骤：'
            '① list_units 找到单位索引，get_unit 读当前值（改前先 snapshot 留后路）；'
            '② set_unit_field 把 7 项成长率提到 100、属性（HP/力量/技巧/速度/防御/魔防/幸运/体格）按需提到 20、'
            '8 项熟练度提到 S；'
            '③ 职业天花板：get_class 看它默认职业的各属性上限，set_class_field 提到 50（HP 上限 60）——'
            '只改基础值不改上限，升级时仍会被职业天花板压回去；'
            '④ 经验分母（职业表字段）改小 = 升级快，但它是职业表字段，影响**所有**同职业角色，'
            '改之前告诉我；'
            '⑤ 改完 list_changes 汇总、validate_rom 体检，'
            '最后 export_recipe（带 semantic 层，targets 写角色名）把这次加强导出成配方。'
            '字段名以 get_unit/get_class 返回的为准，别猜。',
  ),
  McpPrompt(
    name: 'chapter_reinforcement',
    description: '给某章加剧情增援（第 N 回合在指定坐标生成指定单位）',
    arguments: {
      'chapter': '章节索引（0 基）',
      'turn': '触发回合数',
      'units': '增援单位（角色 ID/职业/等级/坐标）',
    },
    render: (a) =>
        '$_workflowPrefix给第 ${a['chapter'] ?? '（未指定章节）'} 章加增援：'
            '① list_chapters 确认章节（看 title 对齐游戏内编号）与地图尺寸；'
            '② 确认增援单位：char_id 是 1 基（= 表内索引 + 1），class_id 0 基、0 = 默认职业；'
            '坐标必须落在本章地图内（get_map 看宽高）；'
            '③ 先 add_reinforcement(dry_run: true) 预演看将写哪里，确认没问题再真执行；'
            '④ list_chapter_events 核对新条目（回合数两条路径都应有值）；'
            '⑤ validate_rom 体检。这个模板只追加不改既有脚本，改坏了把事件组指针改回去或 revert_changes 即可。',
  ),
  McpPrompt(
    name: 'rewrite_chapter_dialog',
    description: '改写某章某句对话（按文本 ID 直接改文本条目，不动事件脚本）',
    arguments: {'chapter': '章节索引（0 基）', 'which': '对话（可给文本 ID、原文片段或序号）'},
    render: (a) =>
        '$_workflowPrefix改写第 ${a['chapter'] ?? '（未指定章节）'} 章的对话「${a['which'] ?? '（未指定）'}」：'
            '① list_chapter_dialogs 拿本章对话清单（带 title 与文本 ID）；'
            '② read_text 看原文——控制码显示成〔XX〕占位符、引擎双字节码是〔XXXX〕，'
            '改写时原样保留，不要删；'
            '③ write_text 回写（等长原地、变短补结束符、变长自动找空位重指指针），先 dry_run: true 看结果；'
            '④ 再 read_text 核对新文本，最后 validate_rom。改的是文本条目本身，事件脚本一字不动。',
  ),
  McpPrompt(
    name: 'start_story_hack',
    description: '新手开局：从零做一份剧情改版（先定基底 ROM，再一次改一章）',
    arguments: {
      'base': '想用的基底 ROM（可留空，让 AI 根据字库推荐）',
      'chapter': '先从第几章开始（默认 0）',
    },
    render: (a) =>
        '$_workflowPrefix我要做一份自己的剧情改版，基底是「${a['base'] ?? '（你来推荐）'}」，'
            '先从第 ${a['chapter'] ?? '0'} 章开始。请按这个顺序走：\n'
            '① **先定基底**：调 list_workspace_roms 看手头有哪些 ROM；'
            '然后用 check_text_coverage 试一句典型台词（人名 + 地名 + 兵器名），'
            '对比哪个基底缺字最少。经验：烈焰之剑 **Superxyj 汉化版**（明文 GBK）'
            '常用汉字基本不缺，是做剧情改版最省心的底子；日版（SJIS）连「琳」'
            '这种简体人名都写不进去。定好之后用 open_workspace_rom 打开它。\n'
            '② **摸清这一章**：list_chapters 看标题对齐游戏内编号（工具章节号 0 基），'
            'get_map 看地图尺寸，list_chapter_units 与 list_chapter_dialogs '
            '看这章有哪些人和哪些对话。\n'
            '③ **改剧情**：先 snapshot 留后路；用 list_chapter_dialogs 拿到文本 ID，'
            'read_text 看原文（控制码〔XX〕必须原样保留），write_text 写新台词。'
            '**每改一段就先 check_text_coverage 查缺字**——缺字不会报错，只会变成空白，'
            '事后极难发现。\n'
            '④ **改完**：validate_rom 体检，把这一章的改动汇总告诉我（改了几条对话、'
            '有没有缺字），再说下一章。一章一章来，不要一次改完。\n'
            '⑤ 剧情文本总是参考：改完用 list_chapter_dialogs 回读一遍确认顺序对。',
  ),
  McpPrompt(
    name: 'choose_base_rom',
    description: '比对手头的 ROM，为剧情改版挑一个字库够用的基底',
    arguments: {},
    render: (a) =>
        '$_workflowPrefix帮我挑一份做剧情改版的基底 ROM：\n'
            '① list_workspace_roms 列出手头的 ROM；\n'
            '② 逐个 open_workspace_rom 打开，用 check_text_coverage 试同一段文本 '
            '（包成人名、地名、兵器名、常见动词，约 100 字），记下各自缺几个字；\n'
            '③ 用一张表告诉我：文件名 / 版本 / 文本引擎 / 缺字数量 / 缺的字；\n'
            '④ 给出推荐并说明理由。已知结论（不用重新验）：\n'
            '  - 烈焰之剑 Superxyj 汉化版 = 明文 GBK，常用汉字几乎不缺，**剧情改版首选**；\n'
            '  - 圣魔/封印日版 = Huffman + SJIS，字库是日文的，简体人名/常用汉字大量缺；\n'
            '  - 圣魔火花&狼组汉化 = Huffman + 中文码表（约 2500 字），'
            '字集是按当年剧情挑的，自创剧情很容易缺字；\n'
            '  - 重度改版（plainUtf8）字库最全，但演出与关卡已被别人改过。\n'
            '⑤ 最后告诉我：选定哪份、缺字时该改写哪几个词。',
  ),
];

final List<McpResource> mcpResources = const [
  McpResource(
    uri: 'fe://rom/summary',
    name: '当前 ROM 概览',
    description: '版本、文本引擎、表条目数、操作约定（开局先读这个）',
  ),
  McpResource(
    uri: 'fe://rom/fields',
    name: '可编辑字段清单',
    description: '角色/职业/道具各自能改哪些字段名（传给 set_*_field）',
  ),
  McpResource(
    uri: 'fe://rom/chapters',
    name: '章节清单',
    description: '章节索引、标题、地图尺寸、是否有事件',
  ),
  McpResource(
    uri: 'fe://workspace/roms',
    name: '外部工作区 ROM 列表',
    description: '用户授权的 ROM 存放目录里有哪些文件（含大小与文本引擎判断用信息）',
  ),
  McpResource(
    uri: 'fe://workspace/assets',
    name: '素材库文件清单',
    description: '用户授权的素材库目录路径与文件清单（导出肖像/动画帧/图标等）',
  ),
];

///
/// 单独出来是因为 `const` 里不能写复杂的 Map 字面量嵌套。
class McpArg {
  final Map<String, dynamic> schema;
  const McpArg._(this.schema);

  static McpArg string(String description) => McpArg._(
      {'type': 'string', 'description': description});

  static McpArg integer(String description) => McpArg._(
      {'type': 'integer', 'description': description});

  static McpArg array(String description) => McpArg._({
        'type': 'array',
        'description': description,
        'items': {'type': 'integer'},
      });

  /// 对象数组（如增援单位列表）。客户端靠 `items.properties` 知道每项能填什么。
  static McpArg objectArray(String description, Map<String, McpArg> fields) =>
      McpArg._({
        'type': 'array',
        'description': description,
        'items': {
          'type': 'object',
          'properties': {
            for (final e in fields.entries) e.key: e.value.schema,
          },
        },
      });

  static McpArg boolean(String description) => McpArg._(
      {'type': 'boolean', 'description': description});
}
