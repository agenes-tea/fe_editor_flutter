import 'chapter_dialogs.dart';
import 'chapter_events.dart';
import 'dialog_script.dart';
import 'editable_rom.dart';
import 'fe_rom.dart';
import 'map_reader.dart';
import 'portrait.dart';
import 'unit_placement.dart';

/// 预览的数据来源标记。
///
/// **这是这个模块最重要的一个概念**：预览渲染的是「工具解析出的数据」，
/// 不是游戏实际画面。解析器认错结构 / 偏移读错 / 条目大小判错时，
/// 预览会显得完全正常（因为预览用的就是错误的解析结果）。
/// 所以每个结论都要带上它从哪来，让用户知道哪部分是「读到了」、
/// 哪部分是「没读到所以留空」。
enum PreviewSource {
  /// 从 ROM 数据直接读出（可靠度高）。
  rom,

  /// 由 ROM 数据推导（可靠度中，例如按脚本命令号反查）。
  derived,

  /// 工具解析不出来，留空（**绝不猜**）。
  unavailable,
}

/// 一条预览出来的对话行。
class PreviewLine {
  /// 所属文本 ID。
  final int textId;

  /// 这是这段文本的第几句（0 基）。
  final int lineIndex;

  /// 台词（控制码已换成可读形式）。
  final String text;

  /// 台词原文（带〔XX〕占位符），写作基准。
  final String raw;

  /// 说话人。拿不到时为 null，并在 [speakerSource] 标 unavailable。
  final String? speaker;

  /// 说话人来自哪里。
  final PreviewSource speakerSource;

  /// 头像（肖像表索引）。拿不到时为 null。
  final int? portraitId;

  final PreviewSource portraitSource;

  /// 这条文本里残留的控制码占位符（自查「控制码有没有丢」用）。
  final List<String> controlTokens;

  /// 所属那段文本（整条记录）的控制码总数。
  ///
  /// 与 [controlTokens] 配合能看出「这一句占全段多少个控制码」，
  /// 从而判断分句有没有呑掉控制码。
  final int sceneControlCount;

  /// 数据自洽问题（文本 ID 不存在、头像越界等）。空表示这一行没有硬错误。
  final List<String> issues;

  const PreviewLine({
    required this.textId,
    required this.lineIndex,
    required this.text,
    required this.raw,
    required this.speaker,
    required this.speakerSource,
    required this.portraitId,
    required this.portraitSource,
    required this.controlTokens,
    required this.sceneControlCount,
    required this.issues,
  });

  bool get hasIssues => issues.isNotEmpty;

  Map<String, Object?> toJson() => {
        'text_id': textId,
        'line': lineIndex,
        'text': text,
        'raw': raw,
        'speaker': speaker,
        'speaker_source': speakerSource.name,
        'portrait_id': portraitId,
        'portrait_source': portraitSource.name,
        'control_tokens': controlTokens,
        'scene_control_count': sceneControlCount,
        if (issues.isNotEmpty) 'issues': issues,
      };
}

/// 一章的对话预览。
class DialogPreview {
  final int chapter;
  final String chapterTitle;
  final List<PreviewLine> lines;

  /// 整章层面的问题（例如「本章解析不出任何对话」）。
  final List<String> issues;

  /// 每段对话一个场景（供时间线分组）。
  final List<DialogScene> scenes;

  const DialogPreview({
    required this.chapter,
    required this.chapterTitle,
    required this.lines,
    required this.scenes,
    required this.issues,
  });

  bool get isEmpty => lines.isEmpty;

  Map<String, Object?> toJson() => {
        'chapter': chapter,
        'title': chapterTitle,
        'line_count': lines.length,
        'scene_count': scenes.length,
        'lines': [for (final l in lines) l.toJson()],
        if (issues.isNotEmpty) 'issues': issues,
      };
}

/// 对话预览的生成器。
///
/// 只读：不改任何字节。依据 [DialogScript]（场景 → 句子）与单位/肖像表。
///
/// **说话人与头像的可靠性说明（重要，别在这里"改进"成猜）**：
/// FE 的对话文本本身不带说话人。说话人是脚本里的「插入名字」命令
/// （FE7 `0x17`、FE8 的 `DISPLAYTEXT` 前置命令）决定，而
/// [ChapterDialogues] 只记录「哪条文本被引用」，没记录「由哪条命令引用」。
/// 因此这里**给不出说话人**，统一标 [PreviewSource.unavailable] 并留空——
/// 乱猜会让用户照着错的名字写台词，比不显示糟得多。
/// 等事件解析补上「命令级上下文」再填这里。
class DialogPreviewer {
  final EditableRom edit;

  DialogPreviewer(this.edit);

  DialogPreview of(int chapter) {
    final rom = edit.liveRom;
    final script = DialogScript.of(edit, chapter);
    final title = UnitPlacement(edit).chapterTitle(chapter);
    final portraits = PortraitReader(rom);
    final portraitOk = portraits.available;
    final portraitCount = portraitOk ? portraits.entryCount : 0;
    if (portraitOk) portraits.dispose();

    final lines = <PreviewLine>[];
    final issues = <String>[];
    if (script.scenes.isEmpty) {
      issues.add('本章事件脚本里没有引用到对话文本（可能是本章没有剧情，'
          '或该 ROM 的事件脚本结构不是原版三作的形态）。');
    }

    for (final scene in script.scenes) {
      final sceneTokens = _tokens(scene.raw);
      for (final l in scene.lines) {
        if (l.isEmpty) continue;
        final lineIssues = <String>[];
        // 数据自洽：文本 ID 必须真的在指针表里
        if (rom.textEntryOffset(scene.textId) < 0) {
          lineIssues.add('文本 #${scene.textId} 在文本指针表里不存在');
        }
        // 控制码按**这一句**算，不能用整段的（那样每行都返回全段控制码，
        // AI 自查「这一句的控制码丢了没」会被误导）。
        lines.add(PreviewLine(
          textId: scene.textId,
          lineIndex: l.index,
          text: l.text,
          raw: l.raw,
          // 说话人：静态提取给不出可靠结论，明确标 unavailable
          speaker: null,
          speakerSource: PreviewSource.unavailable,
          portraitId: null,
          portraitSource: PreviewSource.unavailable,
          controlTokens: _tokens(l.raw),
          sceneControlCount: sceneTokens.length,
          issues: lineIssues,
        ));
      }
    }

    if (!portraitOk) {
      issues.add('该 ROM 的肖像表不可用，预览里不显示头像。');
    } else if (portraitCount <= 0) {
      issues.add('该 ROM 的肖像表为空，预览里不显示头像。');
    }

    return DialogPreview(
      chapter: chapter,
      chapterTitle: title,
      lines: lines,
      scenes: script.scenes,
      issues: issues,
    );
  }

  /// 抽出控制码占位符（〔XX〕/〔XX:..〕/〔XXXX〕）。
  static List<String> _tokens(String raw) {
    final out = <String>[];
    final re = RegExp(r'〔[0-9A-Fa-f]{2,4}(?::[0-9A-Fa-f,]*)?〕');
    for (final m in re.allMatches(raw)) {
      out.add(m.group(0)!);
    }
    return out;
  }
}

// ---------- 事件触发预览 ----------

/// 一条「事件触发」预览。
class PreviewEvent {
  final int addr;
  final EventTriggerKind kind;

  /// 原始检查命令字（排查用）。
  final int check;

  /// 工具解析出的触发条件（原文）。
  final String condition;

  /// 自然语言一行（给小白看）。
  final String sentence;

  /// 该事件加载的单位（增援/出击）。
  final List<PreviewEventUnit> units;

  /// 本条的问题（解析存疑、坐标越界等）。
  final List<String> issues;

  const PreviewEvent({
    required this.addr,
    required this.kind,
    required this.check,
    required this.condition,
    required this.sentence,
    required this.units,
    required this.issues,
  });

  Map<String, Object?> toJson() => {
        'addr': addr,
        'gba': 0x08000000 + addr,
        'kind': kind.name,
        'check': check,
        'condition': condition,
        'sentence': sentence,
        'units': [for (final u in units) u.toJson()],
        if (issues.isNotEmpty) 'issues': issues,
      };
}

/// 事件里生成的一个单位（预览用）。
class PreviewEventUnit {
  final int charId;
  final String name;
  final int classId;
  final String className;
  final int level;
  final int x;
  final int y;
  final int allegiance;
  final List<int> items;
  final List<String> itemNames;
  final List<String> issues;

  const PreviewEventUnit({
    required this.charId,
    required this.name,
    required this.classId,
    required this.className,
    required this.level,
    required this.x,
    required this.y,
    required this.allegiance,
    required this.items,
    required this.itemNames,
    required this.issues,
  });

  String get allegianceName => switch (allegiance) {
        0 => '我方',
        1 => '友军',
        2 => '敌方',
        _ => '未知阵营',
      };

  Map<String, Object?> toJson() => {
        'char_id': charId,
        'name': name,
        'class_id': classId,
        'class_name': className,
        'level': level,
        'x': x,
        'y': y,
        'allegiance': allegiance,
        'allegiance_name': allegianceName,
        'items': items,
        'item_names': itemNames,
        if (issues.isNotEmpty) 'issues': issues,
      };
}

/// 一章的事件触发预览。
class EventPreview {
  final int chapter;
  final String chapterTitle;
  final int mapWidth;
  final int mapHeight;
  final List<PreviewEvent> events;
  final List<String> issues;

  const EventPreview({
    required this.chapter,
    required this.chapterTitle,
    required this.mapWidth,
    required this.mapHeight,
    required this.events,
    required this.issues,
  });

  Map<String, Object?> toJson() => {
        'chapter': chapter,
        'title': chapterTitle,
        'map': {'width': mapWidth, 'height': mapHeight},
        'event_count': events.length,
        'events': [for (final e in events) e.toJson()],
        if (issues.isNotEmpty) 'issues': issues,
      };
}

/// 事件触发预览的生成器（只读）。
class EventPreviewer {
  final EditableRom edit;

  EventPreviewer(this.edit);

  EventPreview of(int chapter) {
    final rom = edit.liveRom;
    final title = UnitPlacement(edit).chapterTitle(chapter);
    final issues = <String>[];
    final ev = ChapterEvents(rom)
      ..itemNameOf = (id) => rom.itemDisplayName(id).trim();
    final group = UnitPlacement(edit).eventGroupOffset(chapter);

    var width = 0;
    var height = 0;
    try {
      final map = MapReader(rom).chapterMap(chapter);
      if (map != null) {
        width = map.width;
        height = map.height;
      }
    } catch (_) {
      // 地图读不出来就不校验坐标，下面会注明
    }

    if (group <= 0) {
      issues.add('本章没有事件组（可能不是剧情章）。');
      return EventPreview(
        chapter: chapter,
        chapterTitle: title,
        mapWidth: width,
        mapHeight: height,
        events: const [],
        issues: issues,
      );
    }

    final events = <PreviewEvent>[];
    for (final e in ev.all(group)) {
      final raw = <PreviewEventUnit>[];
      final eventIssues = <String>[];
      if (e.script != 0 && FeRom.isPointer(e.script, rom.length)) {
        for (final u in ev.loadedUnits(e.script)) {
          raw.add(_unit(rom, u, width, height, eventIssues));
        }
      }
      // 同阵营内按「角色+坐标+等级」去重：同一个单位数组被两条 LOADUNIT
      // 引用时会出现重复项，列两遍会让人以为生成了两个。
      final seen = <String>{};
      final units = raw.where((u) {
        final key = '${u.charId}|${u.x}|${u.y}|${u.level}|${u.allegiance}';
        return seen.add(key);
      }).toList();
      events.add(PreviewEvent(
        addr: e.addr,
        kind: e.kind,
        check: e.check,
        condition: e.condition,
        sentence: _sentence(e, units),
        units: units,
        issues: eventIssues,
      ));
    }

    if (events.isEmpty) issues.add('本章事件列表解析为空。');
    if (width == 0) {
      issues.add('地图尺寸读取失败，未校验单位坐标是否在地图内。');
    }

    return EventPreview(
      chapter: chapter,
      chapterTitle: title,
      mapWidth: width,
      mapHeight: height,
      events: events,
      issues: issues,
    );
  }

  PreviewEventUnit _unit(
      FeRom rom, LoadedUnit u, int w, int h, List<String> bucket) {
    final issues = <String>[];
    final index = u.unitIndex;
    var name = '';
    if (index < 0 || index >= rom.unitCount) {
      issues.add('角色 ID ${u.charId} 超出单位表范围（1..${rom.unitCount}）');
    } else {
      name = rom.unitDisplayName(index).trim();
    }
    var className = '';
    if (u.classId <= 0) {
      // class_id 0 = 用角色默认职业（AGENTS §15 的坑），回退查单位表
      if (index >= 0 && index < rom.unitCount) {
        final def = rom.unitClassId(index);
        className = def >= 0 ? rom.classDisplayName(def).trim() : '';
      }
    } else if (u.classId >= rom.classCount) {
      issues.add('职业 ID ${u.classId} 超出职业表范围（0..${rom.classCount - 1}）');
    } else {
      className = rom.classDisplayName(u.classId).trim();
    }
    if (w > 0 && h > 0 && (u.x >= w || u.y >= h)) {
      issues.add('坐标 (${u.x},${u.y}) 超出地图 ${w}×$h');
    }
    final itemNames = <String>[];
    for (final it in u.items) {
      if (it == 0) continue;
      if (it >= rom.itemCount) {
        issues.add('道具 ID $it 超出道具表范围');
        itemNames.add('?');
      } else {
        itemNames.add(rom.itemDisplayName(it).trim());
      }
    }
    bucket.addAll(issues);
    return PreviewEventUnit(
      charId: u.charId,
      name: name,
      classId: u.classId,
      className: className,
      level: u.level,
      x: u.x,
      y: u.y,
      allegiance: u.allegiance,
      items: u.items,
      itemNames: itemNames,
      issues: issues,
    );
  }

  /// 一行自然语言，按阵营分段。
  ///
  /// 多个阵营/多批单位不挤在一句（新手分不清谁是谁）：
  /// 「第 1 回合起，敌方在 (3,2)、(2,6) 生成 2 个单位：巴塔、山贼」
  /// 「第 1 回合起，我方在 (14,9) 生成 1 个单位：琳」。
  static String _sentence(ChapterEvent e, List<PreviewEventUnit> units) {
    final trig = e.condition.isEmpty ? e.kind.label : e.condition;
    if (units.isEmpty) return '$trig：执行脚本（本工具未解析出其中的单位生成）';
    // 同阵营内再按「角色+坐标+等级」去重：同一个单位数组被两条 LOADUNIT
    // 引用时会出现重复项，列两遍会让人以为生成了两个。
    final groups = <String, List<PreviewEventUnit>>{};
    for (final u in units) {
      groups.putIfAbsent(u.allegianceName, () => []).add(u);
    }
    final parts = <String>[];
    for (final entry in groups.entries) {
      final seen = <String>{};
      final uniq = <PreviewEventUnit>[];
      for (final u in entry.value) {
        final key = '${u.charId}|${u.x}|${u.y}|${u.level}';
        if (seen.add(key)) uniq.add(u);
      }
      final positions = uniq.map((u) => '(${u.x},${u.y})').toSet();
      final names =
          uniq.map((u) => u.name.isEmpty ? '（未命名）' : u.name).toList();
      final posText = positions.length <= 3
          ? positions.join('、')
          : '${positions.length} 个格子';
      parts.add('$trig，${entry.key}在 $posText 生成 ${uniq.length} 个单位：'
          '${names.join('、')}');
    }
    return parts.join('\n');
  }
}
