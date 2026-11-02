import 'dart:typed_data';

import 'chapter_events.dart';
import 'editable_rom.dart';
import 'event_templates.dart';
import 'fe_rom.dart';
import 'hex_view.dart';
import 'map_reader.dart';
import 'unit_placement.dart';

/// 事件编辑能追加的「触发类型」。
///
/// 只覆盖**在事件列表里新增一条条目**这一类操作，不碰既有脚本内容——
/// 插进已有脚本要重算所有后续 `CALL` 的相对位置，风险高一个量级（见 AGENTS §28b）。
enum EventTriggerType {
  /// 第 N 回合起（`EVT_LIST_CMD_TURN`）。
  turn('回合', 0x02, '第 {n} 回合起'),

  /// 角色事件（`EVT_LIST_CMD_CHAR`）：指定角色达到条件。
  character('角色', 0x03, '角色 {a} 达成条件'),

  /// 地点事件（`EVT_LIST_CMD_LOCA`）：踩到指定地砖。
  location('地点', 0x05, '踩到 ({x}, {y})'),

  /// 宝箱（`EVT_LIST_CMD_CHES`）。
  chest('宝箱', 0x07, '打开 ({x}, {y}) 的宝箱'),

  /// 商店（`EVT_LIST_CMD_SHOP`）。
  shop('商店', 0x0A, '访问 ({x}, {y}) 的商店');

  final String label;

  /// `EVT_LIST_CMD_*`（`check` 的低 16 位）。
  final int listCmd;

  /// 给界面看的条件模板。
  final String template;

  const EventTriggerType(this.label, this.listCmd, this.template);

  /// 该类型在事件组里的槽偏移。
  int get groupOffset => switch (this) {
        EventTriggerType.turn => 0x00,
        EventTriggerType.character => 0x04,
        EventTriggerType.location => 0x08,
        EventTriggerType.chest || EventTriggerType.shop => 0x0C,
      };

  /// 该类型对应的 [EventTriggerKind]（决定条目大小）。
  EventTriggerKind get kind => switch (this) {
        EventTriggerType.turn => EventTriggerKind.turn,
        EventTriggerType.character => EventTriggerKind.character,
        EventTriggerType.location => EventTriggerKind.location,
        EventTriggerType.chest => EventTriggerKind.misc,
        EventTriggerType.shop => EventTriggerKind.misc,
      };
}

/// 事件编辑的结果。
enum EventEditResult {
  applied,
  identical,
  unsupported,
  badArguments,
  noSpace,
  listUnavailable,
  notMine,
}

class EventEditOutcome {
  final EventEditResult result;
  final String message;
  final int listOffset;
  final int scriptOffset;
  final int unitArrayOffset;

  const EventEditOutcome(
    this.result, {
    this.message = '',
    this.listOffset = -1,
    this.scriptOffset = -1,
    this.unitArrayOffset = -1,
  });

  bool get ok =>
      result == EventEditResult.applied || result == EventEditResult.identical;

  Map<String, Object?> toJson() => {
        'ok': ok,
        'result': result.name,
        'message': message,
        if (listOffset >= 0) 'list_offset': listOffset,
        if (scriptOffset >= 0) 'script_offset': scriptOffset,
        if (unitArrayOffset >= 0) 'unit_array_offset': unitArrayOffset,
      };
}

/// 要向事件里追加的一批单位（沿用 [ReinforcementUnit] 的字段语义）。
typedef EventUnits = List<ReinforcementUnit>;

/// 章节事件编辑器。
///
/// ## 安全边界（这条是设计的前提，不要放开）
///
/// 只做两类操作：
/// 1. **在事件列表末尾追加一条条目** + 一处可选的「生成单位」脚本；
/// 2. **删除本工具追加的条目**（靠特征自证，见 [removeLastAdded]）。
///
/// 绝不插入/删除既有脚本里的指令：事件脚本是连续字节码，插一条会让后续
/// `CALL` 的相对位置全部失效。要「在原版没有的地方加一句新台词」，
/// 现在的做法是**追加一条新事件**（例如「第 3 回合起」）并在它的脚本里
/// 写 `DISPLAYTEXT + LOADUNIT`——新事件自带新脚本，既有脚本一个字节不动。
///
/// 追加列表时把**整张旧列表复制到空位**再追加，最后只改事件组里那 4 字节指针，
/// 旧列表原样留在原地：改坏了把指针改回去即可，也可整体 revert。
class ChapterEventEditor {
  final EditableRom edit;

  ChapterEventEditor(this.edit);

  FeRom get rom => edit.liveRom;

  ChapterEvents get events => ChapterEvents(rom);

  UnitPlacement get placement => UnitPlacement(edit);

  bool get _isFe8 {
    final id = rom.table.id;
    return id == 'FE8J' || id == 'FE8U';
  }

  int get _unitEntrySize => _isFe8 ? 20 : 16;

  /// 条目大小按类型走（FE7 的 character 列表是 16 字节）。
  int entrySizeFor(EventTriggerType type) =>
      (rom.table.id == 'FE7J' || rom.table.id == 'FE7U') &&
              type.kind == EventTriggerKind.character
          ? 16
          : 12;

  /// 追加一条「第 N 回合起生成单位」事件。
  ///
  /// [dialogueTextId] 非 0 时，新脚本在生成单位前先 `DISPLAYTEXT` 显示该既有文本记录。
  EventEditOutcome addTurnReinforcement({
    required int chapter,
    required int turn,
    required EventUnits units,
    int dialogueTextId = 0,
  }) {
    return _addUnitsEvent(
      chapter: chapter,
      type: EventTriggerType.turn,
      units: units,
      turn: turn,
      dialogueTextId: dialogueTextId,
    );
  }

  /// 追加一条「角色事件」（指定角色达成条件后生成单位）。
  ///
  /// [charA]/[charB] 是 `EvtListCHAR(pid_a, pid_b)` 的两个角色 ID。
  EventEditOutcome addCharacterEvent({
    required int chapter,
    required int charA,
    int charB = 0,
    required EventUnits units,
    int dialogueTextId = 0,
  }) {
    if (charA < 1 || charA > rom.unitCount) {
      return EventEditOutcome(EventEditResult.badArguments,
          message: '角色 ID 必须在 1..${rom.unitCount}（1 基）');
    }
    return _addUnitsEvent(
      chapter: chapter,
      type: EventTriggerType.character,
      units: units,
      charA: charA,
      charB: charB,
      dialogueTextId: dialogueTextId,
    );
  }

  /// 追加一条「踩到 (x,y) 生成单位」的地点事件。
  EventEditOutcome addLocationEvent({
    required int chapter,
    required int x,
    required int y,
    required EventUnits units,
    int dialogueTextId = 0,
  }) {
    return _addUnitsEvent(
      chapter: chapter,
      type: EventTriggerType.location,
      units: units,
      x: x,
      y: y,
      dialogueTextId: dialogueTextId,
    );
  }

  EventEditOutcome _addUnitsEvent({
    required int chapter,
    required EventTriggerType type,
    required EventUnits units,
    int turn = 0,
    int charA = 0,
    int charB = 0,
    int x = 0,
    int y = 0,
    int dialogueTextId = 0,
  }) {
    if (units.isEmpty) {
      return const EventEditOutcome(EventEditResult.badArguments,
          message: '至少要有一个单位');
    }
    if (dialogueTextId > 0) {
      if (events.displayTextCommand() < 0) {
        return const EventEditOutcome(EventEditResult.unsupported,
            message: '本 ROM 定位不到「显示对话」事件命令，无法给事件带台词');
      }
      if (rom.textEntryOffset(dialogueTextId) < 0) {
        return EventEditOutcome(EventEditResult.badArguments,
            message: '文本记录 #$dialogueTextId 不存在（去掉台词、只加单位即可）');
      }
    }
    // ---- 先校验，再写任何字节（踩过：校验放写后，拒绝了但已污染 ROM）----
    final map = MapReader(rom);
    final mapData = map.available ? map.chapterMap(chapter) : null;
    for (final u in units) {
      if (u.charId < 1 || u.charId > rom.unitCount) {
        return EventEditOutcome(EventEditResult.badArguments,
            message: '角色 ID 必须在 1..${rom.unitCount}（1 基的 unit number）');
      }
      if (u.classId < 0 || u.classId >= rom.classCount) {
        return EventEditOutcome(EventEditResult.badArguments,
            message: '职业 ID 必须在 0..${rom.classCount - 1}');
      }
      if (u.level < 0 || u.level > 31) {
        return const EventEditOutcome(
            EventEditResult.badArguments, message: '等级必须在 0..31');
      }
      if (u.allegiance < 0 || u.allegiance > 2) {
        return const EventEditOutcome(
            EventEditResult.badArguments, message: '阵营必须是 0/1/2');
      }
      if (u.items.length > 4) {
        return const EventEditOutcome(
            EventEditResult.badArguments, message: '每个单位最多带 4 件道具');
      }
      for (final it in u.items) {
        if (it != 0 && it >= rom.itemCount) {
          return EventEditOutcome(EventEditResult.badArguments,
              message: '道具 ID $it 超出道具表（共 ${rom.itemCount} 条）');
        }
      }
      if (mapData != null &&
          (u.x < 0 || u.y < 0 || u.x >= mapData.width || u.y >= mapData.height)) {
        return EventEditOutcome(EventEditResult.badArguments,
            message: '单位坐标 (${u.x},${u.y}) 超出第 $chapter 章地图 '
                '${mapData.width}×${mapData.height}');
      }
    }
    if (type == EventTriggerType.turn && (turn < 1 || turn > 255)) {
      return const EventEditOutcome(
          EventEditResult.badArguments, message: '回合数必须在 1..255');
    }
    if (type == EventTriggerType.location &&
        mapData != null &&
        (x < 0 || y < 0 || x >= mapData.width || y >= mapData.height)) {
      return EventEditOutcome(EventEditResult.badArguments,
          message: '坐标 ($x,$y) 超出本章地图 ${mapData.width}×${mapData.height}');
    }

    final group = placement.eventGroupOffset(chapter);
    if (group <= 0) {
      return EventEditOutcome(EventEditResult.listUnavailable,
          message: '第 $chapter 章没有可读的事件组（对战/试炼章或表尾残留）');
    }

    final entrySize = entrySizeFor(type);
    final oldEntries = _readRawEntries(group, type, entrySize);
    if (oldEntries == null) {
      return const EventEditOutcome(EventEditResult.listUnavailable,
          message: '该章这类事件列表没有正常结束标记，拒绝改动');
    }
    if (oldEntries.length >= 180) {
      return EventEditOutcome(EventEditResult.badArguments,
          message: '该章这类事件已有 ${oldEntries.length} 条，不再追加');
    }

    // ---- 规划空位（一次性算好，避免分段找空位互相重叠）----
    final unitArrayLen = (units.length + 1) * _unitEntrySize;
    // LOADUNIT(8B)+END(4B)=12 字节；带台词时前面多一条 DISPLAYTEXT 记录
    final dispSize = dialogueTextId > 0 ? events.displayTextCommandSize() : 0;
    final scriptLen = 12 + dispSize;
    final newListLen = (oldEntries.length + 1) * entrySize + entrySize;
    final need = unitArrayLen + scriptLen + newListLen + 32;
    final region = _findFreeRegion(need);
    if (region < 0) {
      return EventEditOutcome(EventEditResult.noSpace,
          message: '找不到 $need 字节的连续空位（空白区可能已被占满）');
    }
    final unitArrayAt = region;
    final scriptAt = _align4(unitArrayAt + unitArrayLen);
    final newListAt = _align4(scriptAt + scriptLen);

    // ---- 写：单位数组 → 脚本 → 新列表 → 改指针 ----
    edit.writeBytes(unitArrayAt, _buildUnitArray(units));
    edit.writeBytes(
        scriptAt, _buildLoadUnitScript(0x08000000 + unitArrayAt, dialogueTextId));
    final listBytes = BytesBuilder();
    for (final e in oldEntries) {
      listBytes.add(e);
    }
    listBytes.add(_buildEntry(
      type: type,
      scriptPtr: 0x08000000 + scriptAt,
      turn: turn,
      charA: charA,
      charB: charB,
      x: x,
      y: y,
      entrySize: entrySize,
    ));
    listBytes.add(Uint8List(entrySize)); // 结束标记（全 0）
    edit.writeBytes(newListAt, listBytes.takeBytes());
    edit.writePointer(group + type.groupOffset, newListAt);

    return EventEditOutcome(
      EventEditResult.applied,
      message: '已追加 1 条「${type.label}」事件'
          '（${units.length} 个单位；旧列表原样保留）',
      listOffset: newListAt,
      scriptOffset: scriptAt,
      unitArrayOffset: unitArrayAt,
    );
  }

  /// 读列表原始字节（含「结束标记之前」的所有条目）；结构异常返回 null。
  List<Uint8List>? _readRawEntries(
      int group, EventTriggerType type, int entrySize) {
    final ptr = FeRom.u32(edit.buffer.data, group + type.groupOffset);
    if (ptr == 0 || !FeRom.isPointer(ptr, rom.length)) {
      // 空列表：允许从零开始建（这是最安全的场景）
      return ptr == 0 ? <Uint8List>[] : null;
    }
    final base = FeRom.toOffset(ptr);
    if (base % 4 != 0) return null;
    final out = <Uint8List>[];
    for (var i = 0; i < 200; i++) {
      final at = base + i * entrySize;
      if (at + entrySize > edit.buffer.length) return null;
      final check = FeRom.u32(edit.buffer.data, at);
      if (check == 0) return out;
      if (check == 0xFFFFFFFF) return null;
      out.add(Uint8List.fromList(
          edit.buffer.data.sublist(at, at + entrySize)));
    }
    return null;
  }

  /// 构造一条事件列表条目。
  ///
  /// 布局（三作一致）：`+0` check（列表类型 + 参数）、`+4` script、
  /// `+8` value（`_EvtParams4` 的后两个字节 / 或道具 ID / 商店列表指针）。
  Uint8List _buildEntry({
    required EventTriggerType type,
    required int scriptPtr,
    required int turn,
    required int charA,
    required int charB,
    required int x,
    required int y,
    required int entrySize,
  }) {
    final out = Uint8List(entrySize);
    void put32(int at, int v) {
      out[at] = v & 0xFF;
      out[at + 1] = (v >> 8) & 0xFF;
      out[at + 2] = (v >> 16) & 0xFF;
      out[at + 3] = (v >> 24) & 0xFF;
    }

    // check 低 16 位 = EVT_LIST_CMD_*（列表类型），高 16 位是标志位。
    // **位置/回合等参数全部在 value（第 3 字）里、按字节排**——这是实测出来的：
    //   回合条目 `02 00 00 00 | script | 01 00 00 00`         ← value 低字节 = 回合数
    //   地点条目 `05 00 03 00 | script | 03 02 0f 00`         ← value = x,y,tile
    // 早期把参数塞进 check 高 16 位，会被解析成别的类型（实测：地点事件在 FE6 被读成
    // 「进入区域 (0,0)-(26,9)」、在 FE8 被读成「标志 0x65 置位」）。
    put32(0, type.listCmd);
    put32(4, scriptPtr);
    final extraFlag = type == EventTriggerType.location ? 0x0003 : 0;
    final value = switch (type) {
      // EvtListTurn(turn, turn_max, faction, 0)：a=turn，b=turn_max（0 = 只在第 N 回合）
      EventTriggerType.turn => turn & 0xFF,
      // EvtListCHAR(pid_a, pid_b)：两个角色 ID 占低两字节
      EventTriggerType.character =>
        ((charA & 0xFF)) | ((charB & 0xFF) << 8),
      // EvtListLOCA(x, y, tile)：x,y 在低两字节，tile 在第三字节
      EventTriggerType.location =>
        ((x & 0xFF)) | ((y & 0xFF) << 8) | ((extraFlag & 0xFF) << 16),
      EventTriggerType.chest || EventTriggerType.shop =>
        ((x & 0xFF)) | ((y & 0xFF) << 8),
    };
    // 高 16 位是标志位（实测原版条目这里大多是 0）
    put32(8, value);
    return out;
  }

  /// `DISPLAYTEXT(可选)` + `LOADUNIT(数组)` + `END`。
  Uint8List _buildLoadUnitScript(int arrayPtr, int dialogueTextId) {
    final out = BytesBuilder();
    final displayCmd = dialogueTextId > 0 ? events.displayTextCommand() : -1;
    if (displayCmd >= 0) {
      if (_isFe8) {
        out.add(_u32le(
            (dialogueTextId << 16) | (displayCmd << 8) | (2 << 4)));
      } else {
        final table = events.commandTable();
        if (table != null) {
          final size = events.commandSize(table, displayCmd);
          out.add(_u32le(displayCmd));
          out.add(_u32le(dialogueTextId));
          for (var k = 2; k < size; k++) {
            out.add(_u32le(0));
          }
        }
      }
    }
    if (_isFe8) {
      out.add(_u32le((1 << 16) | (ChapterEvents.cmdLoadUnit << 8) | (4 << 4)));
      out.add(_u32le(arrayPtr));
      out.add(_u32le((ChapterEvents.cmdEnd << 8) | (2 << 4)));
    } else {
      final table = events.commandTable();
      final loadIds = events.loadCommandIds.toList()..sort();
      if (table == null || loadIds.isEmpty) {
        return Uint8List(0);
      }
      out.add(_u32le(loadIds.first));
      out.add(_u32le(arrayPtr));
      out.add(_u32le(0)); // EVT_CMD_END
    }
    return out.takeBytes();
  }

  /// 单位数组（0 结尾），布局与 `UnitPlacement` 一致。
  Uint8List _buildUnitArray(EventUnits units) {
    final out = Uint8List((units.length + 1) * _unitEntrySize);
    final itemsBase = _isFe8 ? 12 : 8;
    for (var i = 0; i < units.length; i++) {
      final u = units[i];
      final at = i * _unitEntrySize;
      out[at] = u.charId & 0xFF;
      out[at + 1] = u.classId & 0xFF;
      out[at + 2] = 0;
      out[at + 3] = ((u.allegiance & 0x03) << 1) | ((u.level & 0x1F) << 3);
      if (_isFe8) {
        final packed = (u.y & 0x3F) << 6 | (u.x & 0x3F);
        out[at + 4] = packed & 0xFF;
        out[at + 5] = (packed >> 8) & 0xFF;
      } else {
        out[at + 4] = u.x & 0xFF;
        out[at + 5] = u.y & 0xFF;
      }
      for (var k = 0; k < 4; k++) {
        out[at + itemsBase + k] = k < u.items.length ? (u.items[k] & 0xFF) : 0;
      }
    }
    return out;
  }

  /// 删除「本工具追加的」最后一条事件。
  ///
  /// 怎么确认是自己追加的？列表被搬到空位后，**只有最后一条**是新增的：
  /// 它前面的条目与新列表头部的旧条目逐字节相同。所以判据是
  /// 「新列表 = 旧列表 + 1 条 + 结束标记」且最后一条的脚本位于空闲区。
  /// 不满足就拒绝（宁可不删，也不删用户/别人加的内容）。
  EventEditOutcome removeLastAdded({
    required int chapter,
    required EventTriggerType type,
  }) {
    final group = placement.eventGroupOffset(chapter);
    if (group <= 0) {
      return const EventEditOutcome(EventEditResult.listUnavailable,
          message: '该章没有事件组');
    }
    final entrySize = entrySizeFor(type);
    final slot = group + type.groupOffset;
    final ptr = FeRom.u32(edit.buffer.data, slot);
    if (ptr == 0 || !FeRom.isPointer(ptr, rom.length)) {
      return const EventEditOutcome(EventEditResult.listUnavailable,
          message: '该章这类事件列表为空');
    }
    final base = FeRom.toOffset(ptr);
    final entries = _readRawEntries(group, type, entrySize);
    if (entries == null || entries.isEmpty) {
      return const EventEditOutcome(EventEditResult.listUnavailable,
          message: '列表结构异常或为空，拒绝删除');
    }
    // 最后一条的脚本必须在「非原版区域」——用脚本指针是否指向本列表所在
    // 连续块来判断：本工具把 [单位数组][脚本][列表] 一次性写在同一个空位区，
    // 所以脚本地址应紧挨在列表之前（距离 ≤ 64KB 且更大地址在列表后）。
    final last = entries.last;
    final scriptPtr = FeRom.u32(last, 4);
    final scriptOff = FeRom.toOffset(scriptPtr);
    final looksOurs = scriptOff > 0 &&
        scriptOff < base &&
        base - scriptOff < 0x10000 &&
        scriptOff != base;
    if (!looksOurs) {
      return const EventEditOutcome(EventEditResult.notMine,
          message: '最后一条事件的脚本不在本工具写过的区域，判断不是本工具追加的，'
              '为安全起见不删除。要回退请用「撤销全部」或快照。');
    }
    // 重建：去掉最后一条
    final kept = entries.sublist(0, entries.length - 1);
    final len = kept.length * entrySize + entrySize;
    final region = _findFreeRegion(len + 16);
    if (region < 0) {
      return EventEditOutcome(EventEditResult.noSpace,
          message: '找不到 ${len + 16} 字节空位来重建列表');
    }
    final newListAt = _align4(region);
    final b = BytesBuilder();
    for (final e in kept) {
      b.add(e);
    }
    b.add(Uint8List(entrySize));
    edit.writeBytes(newListAt, b.takeBytes());
    edit.writePointer(slot, newListAt);
    return EventEditOutcome(
      EventEditResult.applied,
      message: '已删除最后一条「${type.label}」事件（脚本数据留在原地，不影响运行）',
      listOffset: newListAt,
    );
  }

  static List<int> _u32le(int v) =>
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

  static int _align4(int v) => v + ((4 - (v % 4)) % 4);

  /// 找连续空位（取最长的那块，做法同 `EventTemplates._findFreeRegion`）。
  int _findFreeRegion(int need) {
    final view = HexView(edit.buffer);
    const limit = 0x02000000;

    int bestRunOffset(int fill) {
      var from = 0;
      var bestOff = -1;
      var bestLen = 0;
      while (from < edit.buffer.length && from < limit) {
        final run = view.findFreeRun(from, fill: fill, minLength: need + 3);
        if (run == null) break;
        if (run.offset + need + 3 <= limit && run.length > bestLen) {
          bestLen = run.length;
          bestOff = run.offset;
        }
        from = run.offset + run.length;
      }
      return bestOff;
    }

    final ff = bestRunOffset(0xFF);
    if (ff >= 0) return _align4(ff);
    final zero = bestRunOffset(0x00);
    if (zero >= 0) return _align4(zero);
    return -1;
  }
}
