import 'dart:typed_data';

import 'chapter_events.dart';
import 'editable_rom.dart';
import 'fe_rom.dart';
import 'hex_view.dart';
import 'map_reader.dart';
import 'unit_placement.dart';

/// 模板应用的结果。
enum EventTemplateResult {
  /// 已写入（搬动了事件列表指针）。
  applied,

  /// 内容与现有脚本完全一致，无需改动。
  identical,

  /// 该版本不支持这个模板。
  unsupported,

  /// 找不到足够大的连续空位。
  noSpace,

  /// 参数越界（坐标、角色/职业/回合数）。
  badArguments,

  /// 目标事件列表定位失败。
  listUnavailable,
}

class EventTemplateOutcome {
  final EventTemplateResult result;
  final String message;

  /// 新脚本所在的文件偏移（搬动后）。
  final int scriptOffset;

  /// 新事件列表所在的文件偏移。
  final int listOffset;

  /// 单位数组所在的文件偏移。
  final int unitArrayOffset;

  final int bytesWritten;

  const EventTemplateOutcome(
    this.result, {
    this.message = '',
    this.scriptOffset = -1,
    this.listOffset = -1,
    this.unitArrayOffset = -1,
    this.bytesWritten = 0,
  });

  bool get ok => result == EventTemplateResult.applied ||
      result == EventTemplateResult.identical;
}

/// 要放进模板里的一个增援单位。
class ReinforcementUnit {
  /// 角色 ID（单位表 `number` 语义，**1 基**）。
  final int charId;

  /// 职业 ID（0 基）；0 表示用角色默认职业。
  final int classId;
  final int level;
  final int x;
  final int y;

  /// 阵营：0 我方 / 1 友军 / 2 敌方。
  final int allegiance;

  /// 携带道具 ID（最多 4 个，0 表示空）。
  final List<int> items;

  const ReinforcementUnit({
    required this.charId,
    required this.classId,
    required this.level,
    required this.x,
    required this.y,
    required this.allegiance,
    this.items = const [],
  });
}

/// 事件模板生成器（当前只有「回合增援」一种）。
///
/// ## 为什么不改现有脚本
///
/// 事件脚本是连续字节码：插入一条指令会让后面所有 `CALL` 的相对位置失效。
/// 所以这里走的是**只增加、不改动既有脚本**的路线：
///
/// 1. 在空位区写一个新的单位数组（`UnitDefinition` 数组，0 结尾）；
/// 2. 写一个新的脚本片段：`LOADUNIT(数组)` + `END`；
/// 3. 把目标事件列表**整表复制**到空位，末尾追加一条新条目 + 结束标记；
/// 4. 只改事件组里那一个 4 字节列表指针，指向新表。
///
/// 事件列表每个事件组各自独立（实测圣魔/烈火/封印前 12 章无共享），
/// 所以重指只影响本章；旧列表原样留在原地，改坏了只要把指针改回去。
///
/// 三种方言的字节形态（都在真实 ROM 上核对过）：
/// - **FE8**：命令字 `(arg<<16)|(cmd<<8)|(len<<4)|sub`，`len` 含命令字本身，
///   所以 `LOADUNIT` 是 `cmd=0x2C, len=4`，参数（数组指针）紧跟一个字；
///   结束是 `cmd=0x01, len=2`，即 `0x00000120`。
/// - **FE6/FE7**：线性 32 位字流，命令号在低 16 位，参数紧跟其后，
///   每条命令占几个字查 ROM 自己的 `gEventCmdTable`；
///   `LOADUNIT` 占 2 字，结束是命令字 `0`。
class EventTemplates {
  final EditableRom edit;

  EventTemplates(this.edit);

  FeRom get rom => edit.liveRom;

  ChapterEvents get events => ChapterEvents(rom);

  UnitPlacement get placement => UnitPlacement(edit);

  bool get _isFe8 {
    final id = rom.table.id;
    return id == 'FE8J' || id == 'FE8U';
  }

  int get _unitEntrySize => _isFe8 ? 20 : 16;

  /// 回合列表在事件组内的偏移。
  static const int turnListOffset = 0x00;

  /// 增援只往「回合列表」追加，所以条目大小固定用 turn 列表的 12 字节
  /// （FE7 只有 char 列表是 16，见 `ChapterEvents._entrySizeFor`）。
  int get _eventEntrySize => 12;

  /// 在事件列表里追加一条「第 N 回合增援」。
  ///
  /// [chapter] 章节索引（0 基）；[turn] 1..255；[units] 至少一个。
  /// [dialogueTextId] 可选：不为 0 时，新事件的脚本在生成单位**之前**先
  /// `DISPLAYTEXT` 显示该既有文本记录（让「新事件能带台词」）；本 ROM 定位不到
  /// 显示命令时返回 [EventTemplateResult.unsupported]。
  EventTemplateOutcome addReinforcement({
    required int chapter,
    required int turn,
    required List<ReinforcementUnit> units,
    int dialogueTextId = 0,
  }) {
    if (units.isEmpty) {
      return const EventTemplateOutcome(
          EventTemplateResult.badArguments, message: '至少要有一个增援单位');
    }
    if (turn < 1 || turn > 255) {
      return const EventTemplateOutcome(
          EventTemplateResult.badArguments, message: '回合数必须在 1..255');
    }
    if (dialogueTextId > 0) {
      if (events.displayTextCommand() < 0) {
        return const EventTemplateOutcome(EventTemplateResult.unsupported,
            message: '本 ROM 定位不到「显示对话」事件命令，无法给事件带台词');
      }
      if (rom.textEntryOffset(dialogueTextId) < 0) {
        return EventTemplateOutcome(EventTemplateResult.badArguments,
            message: '文本记录 #$dialogueTextId 不存在（去掉台词、只加增援即可）');
      }
    }
    final map = MapReader(rom);
    final mapData = map.available ? map.chapterMap(chapter) : null;
    final unitCount = rom.unitCount;
    final classCount = rom.classCount;
    final itemCount = rom.itemCount;
    for (final u in units) {
      if (u.charId < 1 || u.charId > unitCount) {
        return EventTemplateOutcome(EventTemplateResult.badArguments,
            message: '角色 ID 必须在 1..$unitCount（1 基的 unit number）');
      }
      if (u.classId < 0 || u.classId >= classCount) {
        return EventTemplateOutcome(EventTemplateResult.badArguments,
            message: '职业 ID 必须在 0..${classCount - 1}');
      }
      if (u.level < 0 || u.level > 31) {
        return const EventTemplateOutcome(
            EventTemplateResult.badArguments, message: '等级必须在 0..31');
      }
      if (u.allegiance < 0 || u.allegiance > 2) {
        return const EventTemplateOutcome(
            EventTemplateResult.badArguments, message: '阵营必须是 0/1/2');
      }
      if (mapData != null && (u.x < 0 || u.y < 0 || u.x >= mapData.width || u.y >= mapData.height)) {
        return EventTemplateOutcome(EventTemplateResult.badArguments,
            message: '坐标 (${u.x},${u.y}) 超出第 $chapter 章地图 '
                '${mapData.width}×${mapData.height}');
      }
      for (final it in u.items) {
        if (it != 0 && itemCount > 0 && it >= itemCount) {
          return EventTemplateOutcome(EventTemplateResult.badArguments,
              message: '道具 ID $it 超出道具表（共 $itemCount 条）');
        }
      }
      if (u.items.length > 4) {
        return const EventTemplateOutcome(
            EventTemplateResult.badArguments, message: '每个单位最多带 4 件道具');
      }
    }

    final group = placement.eventGroupOffset(chapter);
    if (group <= 0) {
      return EventTemplateOutcome(EventTemplateResult.listUnavailable,
          message: '第 $chapter 章没有可读的事件组（对战/试炼章或表尾残留）');
    }
    final listPtr = FeRom.u32(edit.buffer.data, group + turnListOffset);
    if (listPtr == 0 || !FeRom.isPointer(listPtr, rom.length)) {
      return const EventTemplateOutcome(EventTemplateResult.listUnavailable,
          message: '该章没有回合事件列表');
    }
    final oldList = FeRom.toOffset(listPtr);

    // 读出旧列表（含结束标记前的内容）并确认容量
    final entrySize = _eventEntrySize;
    final oldEntries = <Uint8List>[];
    var terminated = false;
    for (var i = 0; i < 200; i++) {
      final at = oldList + i * entrySize;
      if (at + entrySize > edit.buffer.length) break;
      final check = FeRom.u32(edit.buffer.data, at);
      if (check == 0) {
        terminated = true;
        break;
      }
      oldEntries.add(Uint8List.fromList(
          edit.buffer.data.sublist(at, at + entrySize)));
    }
    if (!terminated) {
      return const EventTemplateOutcome(EventTemplateResult.listUnavailable,
          message: '该章回合事件列表没有正常结束标记，拒绝改动');
    }
    if (oldEntries.length >= 190) {
      return EventTemplateOutcome(EventTemplateResult.badArguments,
          message: '该章回合事件已有 ${oldEntries.length} 条，不再追加');
    }

    // ---- 规划新数据（一次性算好，避免分段找空地互相重叠）----
    final scriptBytes = _buildScript(0, dialogueTextId); // 先占位算长度，真正指针稍后回填
    final unitArrayLen = (units.length + 1) * _unitEntrySize; // +1 是 0 结尾
    final newListLen = (oldEntries.length + 1) * entrySize + 4;
    final need = unitArrayLen + scriptBytes.length + newListLen + 16;
    final region = _findFreeRegion(need);
    if (region < 0) {
      return EventTemplateOutcome(EventTemplateResult.noSpace,
          message: '找不到 $need 字节的连续空位（移植类操作都会先找空位，'
              '这个 ROM 的空白区可能已被占满）');
    }

    // 布局：[单位数组][脚本][新列表]
    final unitArrayAt = region;
    final scriptAt = _align4(unitArrayAt + unitArrayLen);
    final newListAt = _align4(scriptAt + scriptBytes.length);

    // 1) 单位数组
    final arrayBytes = _buildUnitArray(units);
    // 2) 脚本（此时知道数组地址）
    final script = _buildScript(0x08000000 + unitArrayAt, dialogueTextId);
    // 3) 新列表 = 旧条目 + 新条目 + 结束标记
    final listBytes = BytesBuilder();
    for (final e in oldEntries) {
      listBytes.add(e);
    }
    listBytes.add(_buildEntry(
      turn: turn,
      scriptPtr: 0x08000000 + scriptAt,
    ));
    listBytes.add(const [0, 0, 0, 0]);

    if (unitArrayAt + arrayBytes.length > scriptAt ||
        scriptAt + script.length > newListAt) {
      return const EventTemplateOutcome(EventTemplateResult.noSpace,
          message: '空位规划失败（内部对齐错误）');
    }

    edit.writeBytes(unitArrayAt, arrayBytes);
    edit.writeBytes(scriptAt, script);
    edit.writeBytes(newListAt, listBytes.takeBytes());
    edit.writePointer(group + turnListOffset, newListAt);

    return EventTemplateOutcome(
      EventTemplateResult.applied,
      message: '已在第 $chapter 章追加「第 $turn 回合」增援 ${units.length} 人',
      scriptOffset: scriptAt,
      listOffset: newListAt,
      unitArrayOffset: unitArrayAt,
      bytesWritten: arrayBytes.length + script.length + listBytes.length,
    );
  }

  /// 构造「第 [turn] 回合」的事件条目。
  ///
  /// 条目统一 12 字节：`_EvtParams2(TURN, flag)` + 脚本体 + `_EvtParams4(参数)`。
  /// `EvtListTurn(flag, scr, turn, turn_max, faction)` 的参数是
  /// `_EvtParams4(turn, turn_max, faction, 0)`，所以回合数写在 `value` 的低字节，
  /// `turn_max` 写 0（= 只在第 N 回合触发一次）。
  Uint8List _buildEntry({required int turn, required int scriptPtr}) {
    // 低 16 位是列表条目类型 `EVT_LIST_CMD_TURN`(2)，高 16 位是 ent_flag（0）
    final out = Uint8List(_eventEntrySize);
    void put32(int at, int v) {
      out[at] = v & 0xFF;
      out[at + 1] = (v >> 8) & 0xFF;
      out[at + 2] = (v >> 16) & 0xFF;
      out[at + 3] = (v >> 24) & 0xFF;
    }

    put32(0, 0x02);
    put32(4, scriptPtr);
    put32(8, turn);
    // FE7 条目 16 字节：末尾 4 字节是 `EvtListTurn` 宏里的 `EventListScr 0`
    // （已由 Uint8List 初始化为 0，这里写明意图）
    return out;
  }

  /// 构造脚本：`LOADUNIT(数组指针)` + `END`。
  /// [dialogueTextId] 非 0 时在生成单位前先 `DISPLAYTEXT`（让新事件能带台词）。
  Uint8List _buildScript(int arrayPtr, int dialogueTextId) {
    final out = BytesBuilder();
    final displayCmd = dialogueTextId > 0 ? events.displayTextCommand() : -1;
    if (displayCmd >= 0) {
      if (_isFe8) {
        // 文本 ID 在命令字高 16 位，len=2（一个命令字）
        out.add(_u32le((dialogueTextId << 16) | (displayCmd << 8) | (2 << 4)));
      } else {
        // 命令号在低 16 位，参数（文本 ID）紧跟，补零到 size*4 字节
        final table = events.commandTable()!;
        final size = events.commandSize(table, displayCmd);
        out.add(_u32le(displayCmd));
        out.add(_u32le(dialogueTextId));
        for (var k = 2; k < size; k++) {
          out.add(_u32le(0));
        }
      }
    }
    if (_isFe8) {
      // (restriction<<16) | (cmd<<8) | (len<<4) | sub
      // restriction = 1：与实测的「敌方增援」写法一致
      out.add(_u32le((1 << 16) | (ChapterEvents.cmdLoadUnit << 8) | (4 << 4)));
      out.add(_u32le(arrayPtr));
      out.add(_u32le((ChapterEvents.cmdEnd << 8) | (2 << 4)));
    } else {
      final table = events.commandTable();
      final loadIds = events.loadCommandIds.toList()..sort();
      if (table == null || loadIds.isEmpty) {
        throw StateError('该 ROM 的 LOADUNIT 命令号定位失败');
      }
      final loadId = loadIds.first;
      out.add(_u32le(loadId));
      out.add(_u32le(arrayPtr));
      out.add(_u32le(0)); // EVT_CMD_END
    }
    return out.takeBytes();
  }

  /// 构造单位数组（0 结尾）。
  ///
  /// 条目布局与 `UnitPlacement` 一致：`+0` pid、`+1` classId、
  /// `+3` 阵营(bit1-2)+等级(bit3-7)、FE8 坐标打包在 `+4` 的 u16、
  /// 道具在 `+12`（FE8）/`+8`（FE6/FE7）。
  Uint8List _buildUnitArray(List<ReinforcementUnit> units) {
    final out = Uint8List((units.length + 1) * _unitEntrySize);
    final itemsBase = _isFe8 ? 12 : 8;
    for (var i = 0; i < units.length; i++) {
      final u = units[i];
      final at = i * _unitEntrySize;
      out[at] = u.charId & 0xFF;
      out[at + 1] = u.classId & 0xFF;
      out[at + 2] = 0; // leader
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
    // 最后一条全 0 即终止符（数组已初始化为 0）
    return out;
  }

  static List<int> _u32le(int v) =>
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

  static int _align4(int v) => v + ((4 - (v % 4)) % 4);

  /// 找连续空位并 4 字节对齐；找不到返回 -1。
  ///
  /// 先列全部候选，再**取最长的那一块**（同样做法见 [TextWriter._findFreeSlot]）：
  /// 随手拿第一个洞会在紧邻其它数据的缝隙里写字节，后面再追加数据就更容易
  /// 撞车；取最大的块（通常是 ROM 末尾那片未用区）安全得多。
  int _findFreeRegion(int need) {
    final view = HexView(edit.buffer);
    const limit = 0x02000000;

    int bestRunOffset(int fill, int minNeed) {
      var from = 0;
      var bestOff = -1;
      var bestLen = 0;
      while (from < edit.buffer.length && from < limit) {
        final run = view.findFreeRun(from, fill: fill, minLength: minNeed);
        if (run == null) break;
        if (run.offset + minNeed <= limit && run.length > bestLen) {
          bestLen = run.length;
          bestOff = run.offset;
        }
        from = run.offset + run.length;
      }
      return bestOff;
    }

    // 多要 3 字节给对齐留余地
    final ff = bestRunOffset(0xFF, need + 3);
    if (ff >= 0) return _align4(ff);
    final zero = bestRunOffset(0x00, need + 3);
    if (zero >= 0) return _align4(zero);
    return -1;
  }
}
