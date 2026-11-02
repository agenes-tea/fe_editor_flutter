import 'cheat_presets.dart';
import 'custom_roster.dart';
import 'editable_rom.dart';

/// 修改配方：一份可导出、可应用的修改清单。
///
/// 两层并存，应用时**语义层先、字节层后**：
/// - `semantic`：按「角色名/道具名 + 字段 label + 预设 ID」描述意图，
///   走现有写入通道（[applyCheat] / [EditableRom.writeField]）执行——
///   目标每次应用时重新解析，同版本的另一份 ROM 也能用。
/// - `bytes`：`export_recipe` 导出的 offset/before/after 分段，
///   精确重放，要求同版本同结构（指纹核对在 MCP `apply_recipe` 层做）。
///
/// 语义层 JSON 约定（[parseSemantic] 校验）：
/// ```json
/// {
///   "presets": [{"id": "unit_max_growth", "targets": ["琳", "雷万"]}],
///   "units":   {"琳": {"等级": 99}, "3": {"HP": 20}},
///   "items":   {"铁剑": {"必杀": 30}},
///   "classes": {"骑士": {"力量上限": 50}}
/// }
/// ```
/// 目标写表内下标（0 基，数字或数字字符串）或名称；名称先按**显示名**
/// （`unitDisplayName`，汉化版含正式译名）精确匹配，再按 ROM 原文名匹配。
/// 字段 label 必须与 `unitEditableFieldsFor` / `classEditableFieldsFor` /
/// `itemEditableFieldsFor` 完全一致。

/// 目标解析结果：[indices] 是解析出的表内下标（0 基、去重、保持顺序），
/// [unresolved] 是解析失败的目标（原样字符串）。
class TargetResolution {
  final List<int> indices;
  final List<String> unresolved;

  const TargetResolution(this.indices, this.unresolved);

  bool get hasUnresolved => unresolved.isNotEmpty;
}

/// 数字 = 0 基下标、字符串 = 下标或名称，把一组目标解析成表内下标。
TargetResolution resolveTargets(
  Object? spec,
  int count, {
  required String Function(int index) displayName,
  required String Function(int index) rawName,
}) =>
    _resolveNames(spec, count, displayName, rawName);

/// 把语义层 JSON 解析成规整结构。
///
/// 返回 [ParsedRecipe]：`semantic` 是规整后的操作（presets / units /
/// items / classes，缺的键不在 map 里），`problems` 是结构问题清单
/// （非空时对应条目被跳过，合法部分仍可应用）。
class ParsedRecipe {
  final Map<String, Object> semantic;
  final List<String> problems;

  const ParsedRecipe(this.semantic, this.problems);

  bool get hasContent => semantic.isNotEmpty;
}

ParsedRecipe parseSemantic(Object? json) {
  final problems = <String>[];
  final out = <String, Object>{};
  if (json == null) return ParsedRecipe(out, problems);
  if (json is! Map) {
    problems.add('semantic 必须是 JSON 对象');
    return ParsedRecipe(out, problems);
  }
  final m = json.map((k, v) => MapEntry('$k', v));

  // presets: [{"id": "unit_max_growth", "targets": [...]}, ...]
  // 坏条目逐条跳过并报错，合法条目保留
  final presetsRaw = m['presets'];
  if (presetsRaw != null) {
    if (presetsRaw is List) {
      final presets = <Map<String, Object?>>[];
      for (var i = 0; i < presetsRaw.length; i++) {
        final e = presetsRaw[i];
        if (e is! Map) {
          problems.add('presets[$i] 不是对象，跳过');
          continue;
        }
        final p = e.map((k, v) => MapEntry('$k', v))
            as Map<String, Object?>;
        if (p['id'] == null) {
          problems.add('presets[$i] 缺 id，跳过');
          continue;
        }
        presets.add(p);
      }
      if (presets.isNotEmpty) out['presets'] = presets;
    } else {
      problems.add('presets 必须是对象数组');
    }
  }

  // units / items / classes: {目标: {label: 数值, ...}, ...}
  for (final key in const ['units', 'items', 'classes']) {
    final raw = m[key];
    if (raw == null) continue;
    if (raw is! Map) {
      problems.add('$key 必须是对象');
      continue;
    }
    final entries = <Object?, Map<String, Object?>>{};
    raw.forEach((k, v) {
      if (v is! Map || v.values.any((x) => x is! num)) {
        problems.add('$key[$k] 的字段值必须是数字，跳过该目标');
        return;
      }
      entries[k] = v.map((fk, fv) => MapEntry('$fk', fv))
          as Map<String, Object?>;
    });
    if (entries.isNotEmpty) out[key] = entries;
  }
  return ParsedRecipe(out, problems);
}

/// 一次配方应用的结果。
class RecipeApplyResult {
  /// 语义层实际写入的字节数（预设 + 字段修改合计）。
  final int semanticChangedBytes;

  /// 字节层实际写入的字节数。
  final int bytesChangedBytes;

  /// 被跳过的字节分段数（before 不匹配 / 越界）。
  final int skippedChunks;

  /// 执行过程中遇到的问题（不影响已完成的写入，调用方决定展示与否）。
  final List<String> problems;

  const RecipeApplyResult({
    required this.semanticChangedBytes,
    required this.bytesChangedBytes,
    required this.skippedChunks,
    required this.problems,
  });

  int get totalChangedBytes => semanticChangedBytes + bytesChangedBytes;
}

/// 应用一份配方（语义层 + 字节层）到 [edit]。
///
/// - [semantic]：[ParsedRecipe]，可空（纯字节重放）。
/// - [chunks]：字节层分段，每项 `{'offset': int, 'after': [..], 'before'?: [..]}`；
///   提供了 [before] 且与当前 buffer 不符的分段会**跳过并记入 problems**
///   （说明目标 ROM 与导出时不一致）。
/// - [version]：配方导出的作品代号（FE6/FE7J/…）。与 [edit] 不一致时拒绝
///   应用（字段偏移与分段位置都不同）。
/// - [expectedFingerprint]：配方导出的 ROM 指纹。不一致时**字节层全跳**
///   （原值无法保证）；语义层同版本仍可解析，继续应用。
///
/// 全部写入走 [EditableRom.writeField] / [writeInstruction] 同款通道，
/// 自动记入 `edits`，可整体撤销。
RecipeApplyResult applyRecipe(
  EditableRom edit, {
  required ParsedRecipe? semantic,
  required List<Map<String, Object?>> chunks,
  String? version,
  int? expectedFingerprint,
}) {
  final rom = edit.liveRom;
  final fe6 = rom.isFe6;
  final issues = <String>[];

  // ---------- 版本校验 ----------
  final currentVersion = rom.table.id;
  if (version != null && version != currentVersion) {
    issues.add('配方来自 $version，当前 ROM 是 $currentVersion：'
        '字段偏移与分段位置都不同，拒绝应用');
    return RecipeApplyResult(
      semanticChangedBytes: 0,
      bytesChangedBytes: 0,
      skippedChunks: chunks.length,
      problems: issues,
    );
  }

  var semanticBytes = 0;

  // ---------- 语义层 ----------
  if (semantic != null) {
    final pre = edit.changedByteCount;

    // presets：走 applyCheat；指定 targets 时用 CustomRoster 完全取代判据
    for (final p
        in (semantic.semantic['presets'] as List<Map<String, Object?>>? ??
            const <Map<String, Object?>>[])) {
      final preset = cheatPresets.where((x) => x.id == p['id']).firstOrNull;
      if (preset == null) {
        issues.add('预设「${p['id']}」不存在，跳过');
        continue;
      }
      late CustomRoster custom;
      if (p['targets'] != null) {
        final res = resolveTargets(
          p['targets'],
          rom.unitCount,
          displayName: rom.unitDisplayName,
          rawName: rom.unitName,
        );
        if (res.hasUnresolved) {
          // 有一个解析不出来就整条跳过：宁可不改，不偷偷少改一半
          issues.addAll(res.unresolved
              .map((n) => '预设「${preset.title}」找不到角色「$n」'));
          continue;
        }
        custom = CustomRoster({for (final i in res.indices) i});
      } else {
        custom = CustomRoster.empty;
      }
      applyCheat(
        edit,
        preset,
        playable: playableUnitsOf(rom),
        custom: custom,
      );
    }

    // 字段修改：units / items / classes
    applyFieldTable(
      edit: edit,
      key: 'units',
      entries: semantic.semantic['units'] as Map<Object?, Map<String, Object?>>?,
      count: rom.unitCount,
      baseOf: edit.unitAddress,
      fields: unitEditableFieldsFor(fe6: fe6),
      displayName: rom.unitDisplayName,
      rawName: rom.unitName,
      issues: issues,
    );
    applyFieldTable(
      edit: edit,
      key: 'items',
      entries: semantic.semantic['items'] as Map<Object?, Map<String, Object?>>?,
      count: rom.itemCount,
      baseOf: edit.itemAddress,
      fields: itemEditableFieldsFor(fe6: fe6),
      displayName: rom.itemDisplayName,
      rawName: rom.itemName,
      issues: issues,
    );
    applyFieldTable(
      edit: edit,
      key: 'classes',
      entries:
          semantic.semantic['classes'] as Map<Object?, Map<String, Object?>>?,
      count: rom.classCount,
      baseOf: edit.classAddress,
      fields: classEditableFieldsFor(fe6: fe6),
      displayName: rom.classDisplayName,
      rawName: rom.className,
      issues: issues,
    );

    semanticBytes = edit.changedByteCount - pre;
  }

  // ---------- 字节层 ----------
  // 指纹不一致时字节分段全部跳过（原值无从保证）；语义层已应用
  final bytesAllowed = expectedFingerprint == null ||
      expectedFingerprint == edit.rom.fingerprint;
  var bytesBytes = 0;
  var skipped = 0;
  if (!bytesAllowed && chunks.isNotEmpty) {
    skipped = chunks.length;
    issues.add('ROM 指纹不一致（配方来源与当前 ROM 不同）：'
        '${chunks.length} 个字节分段全部跳过，只应用了语义层');
  }
  for (final c in chunks) {
    if (!bytesAllowed) continue;
    final offset = c['offset'];
    final after = c['after'];
    if (offset is! int || after is! List) {
      skipped++;
      issues.add('字节分段缺 offset/after，跳过');
      continue;
    }
    if (offset < 0 || offset + after.length > edit.buffer.length) {
      skipped++;
      issues.add('字节分段 0x${offset.toRadixString(16)} 越界，跳过');
      continue;
    }
    final before = c['before'];
    if (before is List) {
      // 严格核对：导出时的原值必须还在**原始快照**里。
      // 注意不是拿 live buffer 比——语义层已经先写过了，
      // 同一批改动两边重叠时 live buffer 的 before 必不匹配（实测踩过）。
      var mismatch = false;
      for (var i = 0; i < before.length && i < after.length; i++) {
        if (edit.original[offset + i] != before[i]) {
          mismatch = true;
          break;
        }
      }
      if (mismatch) {
        skipped++;
        // ignore: avoid_print
        issues.add(
            '0x${offset.toRadixString(16)} 原值不匹配（ROM 与导出时不同），跳过');
        continue;
      }
    }
    bytesBytes +=
        edit.writeInstruction(offset, [for (final b in after) (b as num).toInt() & 0xFF]);
  }

  return RecipeApplyResult(
    semanticChangedBytes: semanticBytes,
    bytesChangedBytes: bytesBytes,
    skippedChunks: skipped,
    problems: issues,
  );
}

/// 应用一张表（units/items/classes）的字段修改。
void applyFieldTable({
  required EditableRom edit,
  required String key,
  required Map<Object?, Map<String, Object?>>? entries,
  required int count,
  required int Function(int) baseOf,
  required List<EditField> fields,
  required String Function(int) displayName,
  required String Function(int) rawName,
  required List<String> issues,
}) {
  if (entries == null) return;
  for (final MapEntry<Object?, Map<String, Object?>> e in entries.entries) {
    final res = resolveTargets(
      e.key,
      count,
      displayName: displayName,
      rawName: rawName,
    );
    if (res.hasUnresolved) {
      issues.addAll(res.unresolved.map((n) => '$key 找不到目标「$n」'));
      continue;
    }
    for (final MapEntry<String, Object?> fe in e.value.entries) {
      if (fe.value is! num) {
        issues.add('$key[${e.key}] 的字段「${fe.key}」值必须是数字');
        continue;
      }
      final field = fields.where((f) => f.label == fe.key).firstOrNull;
      if (field == null) {
        issues.add('$key[${e.key}] 找不到字段「${fe.key}」，跳过');
        continue;
      }
      for (final i in res.indices) {
        edit.writeField(baseOf(i), field, (fe.value as num).toInt());
      }
    }
  }
}

/// 数字/名称混合目标解析（[resolveTargets] 的实现）。单目标与目标列表都接受。
TargetResolution _resolveNames(
  Object? spec,
  int count,
  String Function(int index) displayName,
  String Function(int index) rawName,
) {
  final items = switch (spec) {
    List l => l,
    null => <Object?>[],
    Object o => [o],
  };
  final out = <int>[];
  final unresolved = <String>[];
  for (final t in items) {
    int? idx;
    switch (t) {
      case int i:
        idx = i >= 0 && i < count ? i : null;
      case double d:
        idx = d >= 0 && d == d.roundToDouble() && d.toInt() < count
            ? d.toInt()
            : null;
      case String s:
        final asInt = int.tryParse(s);
        if (asInt != null) {
          // 数字字符串优先当下标；越界时按名称匹配兜底
          idx = asInt >= 0 && asInt < count ? asInt : null;
          if (idx == null) {
            final trimmed = s.trim();
            for (var i = 0; i < count && idx == null; i++) {
              if (displayName(i).trim() == trimmed ||
                  rawName(i).trim() == trimmed) {
                idx = i;
              }
            }
          }
        } else {
          final trimmed = s.trim();
          for (var i = 0; i < count && trimmed.isNotEmpty; i++) {
            if (displayName(i).trim() == trimmed ||
                rawName(i).trim() == trimmed) {
              idx = i;
              break;
            }
          }
        }
      default:
        idx = null;
    }
    if (idx == null) {
      unresolved.add('$t');
    } else if (!out.contains(idx)) {
      out.add(idx);
    }
  }
  return TargetResolution(out, unresolved);
}
