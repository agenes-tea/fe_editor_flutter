import 'disassembler.dart';
import 'fe_rom.dart';

/// 章节事件的**触发条件**种类。
///
/// 依据 `fireemblem8u` 的 `include/eventscript.h`（`event_cmd_idx` 与
/// `EVSUBCMD_*` 枚举）：事件列表条目是 32 位字流，第一个字是「检查命令」，
/// 低 4 位为子命令，具体语义随所在列表（`+0x00`=回合起、`+0x04`=角色、
/// `+0x08`=地点、`+0x0C`=其他）而不同。
enum EventTriggerKind {
  turn('回合'),
  character('角色'),
  location('地点'),
  misc('其他'),
  beginning('开场剧情'),
  ending('结束剧情'),
  unknown('未识别');

  final String label;
  const EventTriggerKind(this.label);
}

/// 一个章节事件（事件列表里的一条）。
///
/// 条目结构（`struct EventInfo`，FE8 为 12 字节，FE7 为 16 字节）：
/// ```
/// 00 u32 检查命令（低 4 位子命令，高 16 位参数）
/// 04 u32 触发后执行的事件脚本指针
/// 08 u32 附加参数（回合数 / 角色 ID / 坐标打包 / 条件值）
/// ```
/// 列表以「检查命令 == 0」的条目结束。
class ChapterEvent {
  /// 条目地址（文件偏移）。
  final int addr;
  final EventTriggerKind kind;

  /// 原始检查命令字（低 4 位是子命令）。
  final int check;

  /// 触发后执行的脚本地址（GBA 地址）；0 表示无脚本。
  final int script;

  /// 附加参数（原始值）。
  final int value;

  /// 人类可读的触发条件，如「第 3 回合起」「角色 5 阵亡后」「访问 (5,7)」。
  final String condition;

  const ChapterEvent({
    required this.addr,
    required this.kind,
    required this.check,
    required this.script,
    required this.value,
    required this.condition,
  });
}

/// 事件列表里的一条增援/出击指令（`EV_CMD_LOADUNIT`）。
///
/// 脚本格式（`eventscript.h`）：每个字 `(cmd << 8) | (len << 4) | sub`，
/// `len` 是**该指令占用的字数（含命令字本身）**，参数紧跟其后。
/// `EvtLoadUnit1(restriction, units)` 展开成两个 32 位字：
/// 命令字（cmd=0x2C、len=4、sub=0）与「单位数组指针」。
class LoadUnitCommand {
  /// 指令地址（文件偏移）。
  final int addr;

  /// 敌军/友军限制参数（`EVSUBCMD_LOAD1..4` 的 sub 对应 0..3，参数是 bit 位组）。
  final int restriction;

  /// `EventListScr` 单位数组的 GBA 地址；0 表示只做数量/概率设置。
  final int unitArray;

  const LoadUnitCommand({
    required this.addr,
    required this.restriction,
    required this.unitArray,
  });
}

/// 事件里 `LOADUNIT` 加载的一个单位（`struct UnitDefinition`）。
class LoadedUnit {
  final int addr;

  /// 角色 ID（`charIndex`，单位表 `number` 语义）。
  final int charId;
  final int classId;
  final int allegiance;
  final int level;
  final int x;
  final int y;
  final List<int> items;

  const LoadedUnit({
    required this.addr,
    required this.charId,
    required this.classId,
    required this.allegiance,
    required this.level,
    required this.x,
    required this.y,
    required this.items,
  });

  /// 表内索引（`pid` 是 1 基）。
  int get unitIndex => charId - 1;
}

/// 章节事件读取（触发条件 + 增援/出击指令）。
///
/// 只做「读出来给人看」：改事件脚本涉及重算长度与指针，界面暂不提供写回。
class ChapterEvents {
  final FeRom rom;

  ChapterEvents(this.rom);

  /// FE8 的命令号（`eventscript.h` 的 `EV_CMD_*`）。
  static const int cmdLoadUnit = 0x2C;
  static const int cmdEnd = 0x01;
  static const int cmdCall = 0x0A;
  static const int cmdEnqueueCall = 0x0B;
  static const int cmdSetSlot = 0x05;

  /// 事件组槽位（`ChapterEventGroup`，`chapterdata.h`）。
  ///
  /// 前四项（`+0x00..+0x0C`）是**事件列表**（`struct EventInfo` 数组）；
  /// `+0x48/+0x4C`（beginning/endingSceneEvents）是**直接指向事件脚本**的
  /// 指针，不是列表，所以不归 [all] 处理（拿当列表读会解出一堆垃圾）。
  static const List<({int offset, EventTriggerKind kind})> _lists = [
    (offset: 0x00, kind: EventTriggerKind.turn),
    (offset: 0x04, kind: EventTriggerKind.character),
    (offset: 0x08, kind: EventTriggerKind.location),
    (offset: 0x0C, kind: EventTriggerKind.misc),
    (offset: 0x48, kind: EventTriggerKind.beginning),
    (offset: 0x4C, kind: EventTriggerKind.ending),
  ];

  /// 开场/结束剧情脚本的指针（不是列表）。
  ///
  /// FE6 的 `ChapterEventInfo` 只到 `+0x18`（过关脚本），没有这两个槽，
  /// 往后读会拿到相邻结构。
  List<int> sceneScripts(int eventGroup) {
    if (rom.table.id == 'FE6') return const [];
    final out = <int>[];
    for (final off in const [0x48, 0x4C]) {
      if (eventGroup <= 0 || eventGroup + off + 4 > rom.length) continue;
      final p = FeRom.u32(rom.data, eventGroup + off);
      if (FeRom.isPointer(p, rom.length)) out.add(p);
    }
    return out;
  }

  /// 事件条目大小：FE7 为 16 字节（`check/script/value/pad`），FE6/FE8 为 12 字节。
  ///
  /// 实测：FE7U `0xca0540` 起是 `02 00 00 00 | 40 7a ca 08 | 01 00 00 00 | 00 00 00 00`
  /// 每 16 字节一条（按 12 读第 2 条就会读到 value 的 0 → 只解出 1 条）；
  /// FE8J `0xa5a6b0` 起是 `02 00 00 00 | 4c 13 a6 08 | 01 00 80 00` 每 12 字节一条。
  /// FE6 与 FE8 同为 12 字节（`eventscript.h` 的 `EvtListTurn` 展开成 3 个字），
  /// 实测 FE6J 第 0 章回合列表 `0x86677bc`：`00000002 | 0866b9d0 | 00000001` 紧接
  /// `00000002 | 0866bbd0 | 00000002`（16 字节步进会读到下一条的 cmd 当 value）。
  int get _entrySize {
    final id = rom.table.id;
    return id == 'FE7J' || id == 'FE7U' ? 16 : 12;
  }

  /// 读一整张事件列表；[listOffset] 是事件组内的槽偏移。
  ///
  /// 列表以「`check` 为 0 的条目」结束：FE8 的结束标记只占 4 字节
  /// （下一张列表的指针恰好等于它之后 4 字节），FE7 的列表之间有间隔，
  /// 所以两种版本都只认「头一个字为 0」而不看整条。
  ///
  /// **FE7 的列表首条会多出 4 字节头**（实测 FE7U loc 列表 `0xca05cc` 处是
  /// `05 00 03 00 | 01 00 00 00 | 03 02 0f 00 | 00 00 00 00` 四条 u16 开头的
  /// 头部，真正的条目从 `+0x10` 起）；用「`script` 必须是合法指针」筛掉头部
  /// 与没有脚本的条件项，避免把头部当成一条事件。
  List<ChapterEvent> readList(int eventGroup, int listOffset,
      EventTriggerKind kind) {
    if (eventGroup <= 0 || eventGroup + listOffset + 4 > rom.length) {
      return const [];
    }
    final p = FeRom.u32(rom.data, eventGroup + listOffset);
    if (p == 0 || !FeRom.isPointer(p, rom.length)) return const [];
    final base = FeRom.toOffset(p);
    final size = _entrySize;
    final out = <ChapterEvent>[];
    for (var i = 0; i < 128; i++) {
      final at = base + i * size;
      if (at + 12 > rom.length) break;
      final check = FeRom.u32(rom.data, at);
      if (check == 0) break;
      final script = FeRom.u32(rom.data, at + 4);
      final value = FeRom.u32(rom.data, at + 8);
      if (!FeRom.isPointer(script, rom.length)) continue;
      out.add(ChapterEvent(
        addr: at,
        kind: kind,
        check: check,
        script: script,
        value: value,
        condition: describe(check, value, kind),
      ));
    }
    return out;
  }

  /// 读该章的四个事件列表（回合/角色/地点/其他）。
  ///
  /// 开场与结束剧情不在这里——它们是脚本指针，用 [sceneScripts] 取。
  List<ChapterEvent> all(int eventGroup) {
    final out = <ChapterEvent>[];
    for (final l in _lists.take(4)) {
      out.addAll(readList(eventGroup, l.offset, l.kind));
    }
    return out;
  }

  /// 把检查命令翻译成可读的条件描述。
  ///
  /// 子命令语义来自反编译的 `EvCheck*` 函数表：回合数在 `value` 的低字节，
  /// 角色/地点类按位打包，条件反转用一个高位标志（`0x80000000` 等）。
  String describe(int check, int value, EventTriggerKind kind) {
    final sub = check & 0xF;
    final low = value & 0xFF;
    switch (kind) {
      case EventTriggerKind.turn:
        // EvCheck02_TURN：0=绝对回合, 1=每隔 N 回合, 2=我方回合起, 3=敌方回合起…
        switch (sub) {
          case 0x2:
            return '第 $low 回合起';
          case 0x3:
            return '每 $low 回合';
          case 0x8:
            return '敌方回合开始（第 $low 回合起）';
          case 0x0:
            return '我方回合开始（第 $low 回合起）';
        }
        return '回合条件 0x${sub.toRadixString(16)}（参数 $low）';
      case EventTriggerKind.character:
        final pid = value & 0xFF;
        final flag = (value >> 8) & 0xFF;
        if (pid == 0) return '角色事件（子命令 0x${sub.toRadixString(16)}）';
        return '角色 $pid（标志 0x${flag.toRadixString(16)}）';
      case EventTriggerKind.location:
        // 坐标打包：低 6 位 x、次 6 位 y（同 UnitDefinition 的打包方式）
        final x = value & 0x3F;
        final y = (value >> 6) & 0x3F;
        return '地点 ($x, $y)（子命令 0x${sub.toRadixString(16)}）';
      case EventTriggerKind.misc:
        return '其他条件 0x${sub.toRadixString(16)}（参数 0x${value.toRadixString(16)}）';
      case EventTriggerKind.beginning:
        return '开场剧情';
      case EventTriggerKind.ending:
        return '结束剧情';
      case EventTriggerKind.unknown:
        return '未识别';
    }
  }

  /// 解析一段事件脚本，列出所有 `LOADUNIT`（含 `CALL` 子脚本里的）。
  ///
  /// 返回空列表表示这段脚本没有增援——注意「没有 LOADUNIT」不等于
  /// 「没有敌人」：多数敌军配在章节的静态单位表里（`UnitPlacement`），
  /// 这里只覆盖「剧情中途生成」的那部分。
  ///
  /// 两种方言（编码完全不同，按版本分支）：
  /// - **FE8**：每个 32 位字 `(arg0<<16) | (cmd<<8) | (len<<4) | sub`，
  ///   `len` 是**16 位半字数**（含命令字本身，见 `event.h` 的 `EVT_CMD_LEN`
  ///   与 `_EvtCmd`），所以步进是 `2*len` 字节——按 4 字节字步进会多跳一倍，
  ///   这是旧实现漏掉大量 `LOADUNIT` 的根因。
  /// - **FE6/FE7**：线性 32 位字流，命令号在**低 16 位**，每条命令占几个字
  ///   由 ROM 自己的 `gEventCmdTable`（8 字节：处理函数指针 + 字数）给出，
  ///   见 [commandTable]。
  List<LoadUnitCommand> loadUnits(int scriptPtr) {
    final out = <LoadUnitCommand>[];
    final seen = <int>{};
    if (_isFe8) {
      _scanFe8Script(scriptPtr, out, seen, 0, 0);
    } else {
      _scanLegacyScript(scriptPtr, out, seen, 0);
    }
    return out;
  }

  bool get _isFe8 {
    final id = rom.table.id;
    return id == 'FE8J' || id == 'FE8U';
  }

  /// 该脚本（含子脚本）加载的全部单位。
  ///
  /// 按版本区分条目大小：FE8 的 `UnitDefinition` 是 20 字节（坐标打包在
  /// `+4` 的 u16，items 在 `+12`），FE7/FE6 是 16 字节（x@+4 y@+5，items@+8）。
  /// 阵营位在 `+3` 的 bit1-2，等级在 bit3-7（与 [PlacedUnit] 同构）。
  List<LoadedUnit> loadedUnits(int scriptPtr) {
    final out = <LoadedUnit>[];
    for (final cmd in loadUnits(scriptPtr)) {
      if (cmd.unitArray == 0) continue;
      _readUnitArray(cmd.unitArray, out);
    }
    return out;
  }

  void _readUnitArray(int ptr, List<LoadedUnit> out) {
    if (!FeRom.isPointer(ptr, rom.length)) return;
    final base = FeRom.toOffset(ptr);
    final isFe8 = _isFe8;
    final size = isFe8 ? 20 : 16;
    final itemsBase = isFe8 ? 12 : 8;
    final units = <LoadedUnit>[];
    var terminated = false;
    for (var i = 0; i < 64; i++) {
      final at = base + i * size;
      if (at + size > rom.length) break;
      final pid = FeRom.u8(rom.data, at);
      if (pid == 0) {
        terminated = true;
        break;
      }
      final grow = FeRom.u8(rom.data, at + 3);
      int x;
      int y;
      if (isFe8) {
        final packed = FeRom.u16(rom.data, at + 4);
        x = packed & 0x3F;
        y = (packed >> 6) & 0x3F;
      } else {
        x = FeRom.u8(rom.data, at + 4);
        y = FeRom.u8(rom.data, at + 5);
      }
      units.add(LoadedUnit(
        addr: at,
        charId: pid,
        classId: FeRom.u8(rom.data, at + 1),
        allegiance: (grow >> 1) & 0x03,
        level: (grow >> 3) & 0x1F,
        x: x,
        y: y,
        items: [
          for (var k = 0; k < 4; k++) FeRom.u8(rom.data, at + itemsBase + k)
        ],
      ));
    }
    // 有的 `LOADUNIT` 参数其实是事件槽/图形指针（反编译里 `(int)ud < 0` 会回退到
    // `gEventSlots[2]`），解出来的字节看着像单位但坐标/职业完全不合理。
    // 只要有一条不满足基本约束，就整组丢弃，宁可少显示也不误导。
    // 数组必须以 `pid == 0` 结尾：跑满上限还没收尾说明这不是单位数组。
    if (!terminated || units.isEmpty) return;
    final classCount = rom.classCount;
    final itemCount = rom.itemCount;
    for (final u in units) {
      if (u.x > 32 || u.y > 32) return;
      if (u.charId > rom.unitCount) return;
      if (classCount > 0 && u.classId >= classCount) return;
      for (final it in u.items) {
        if (it != 0 && itemCount > 0 && it >= itemCount) return;
      }
    }
    out.addAll(units);
  }

  /// FE8 的事件脚本：命令字自带长度，`CALL` 可能通过事件槽 2 间接调用。
  ///
  /// `EvtSetSlot(2, script)` 把子脚本存进 `gEventSlots[2]`，随后
  /// `CALL -1`（`0xFFFFFFFF`）就是「调槽 2 里那个脚本」——第 0 章的增援
  /// 正是这么写的（`0x8a6134c`：设槽 2 = `0x8a611dc`，再 CALL `0x8a601f8`）。
  /// 静态扫描把「设槽」的值沿调用链传下去，否则第一层就停住、一条也看不到。
  void _scanFe8Script(int scriptPtr, List<LoadUnitCommand> out, Set<int> seen,
      int depth, int slot2) {
    if (depth > 3) return;
    if (scriptPtr == 0 || !FeRom.isPointer(scriptPtr, rom.length)) return;
    final start = FeRom.toOffset(scriptPtr);
    if (!seen.add(start)) return;
    var at = start;
    for (var i = 0; i < 400; i++) {
      if (at + 4 > rom.length) break;
      final word = FeRom.u32(rom.data, at);
      final cmd = (word >> 8) & 0xFF;
      final len = (word >> 4) & 0xF;
      if (len == 0) break;
      if (cmd == cmdSetSlot) {
        // EvtSetSlot(slot, value)：arg0 是槽号，值在下一个字
        if ((word >> 16) == 2 && len >= 4) {
          slot2 = FeRom.u32(rom.data, at + 4);
        }
      } else if (cmd == cmdLoadUnit) {
        // EvtLoadUnit1..4：arg0 是 restriction，单位数组在下一个字
        final raw = FeRom.u32(rom.data, at + 4);
        final ptr = FeRom.isPointer(raw, rom.length) ? raw : slot2;
        out.add(LoadUnitCommand(
          addr: at,
          restriction: word >> 16,
          unitArray: FeRom.isPointer(ptr, rom.length) ? ptr : 0,
        ));
      } else if (cmd == cmdCall || cmd == cmdEnqueueCall) {
        var target = FeRom.u32(rom.data, at + 4);
        if (!FeRom.isPointer(target, rom.length)) target = slot2;
        if (FeRom.isPointer(target, rom.length)) {
          _scanFe8Script(target, out, seen, depth + 1, slot2);
        }
      }
      if (cmd == cmdEnd) break;
      at += 2 * len;
    }
  }

  /// FE6/FE7 的事件脚本：命令号的字数查 ROM 自己的命令表。
  void _scanLegacyScript(int scriptPtr, List<LoadUnitCommand> out,
      Set<int> seen, int depth) {
    final table = commandTable();
    if (table == null) return;
    if (depth > 3) return;
    if (scriptPtr == 0 || !FeRom.isPointer(scriptPtr, rom.length)) return;
    final start = FeRom.toOffset(scriptPtr);
    if (!seen.add(start)) return;
    final loadIds = _loadCommandIds(table);
    var at = start;
    for (var i = 0; i < 400; i++) {
      if (at + 8 > rom.length) break;
      final cmd = FeRom.u32(rom.data, at) & 0xFFFF;
      if (cmd >= table.count) break;
      final size = commandSize(table, cmd);
      if (loadIds.contains(cmd)) {
        final arg = FeRom.u32(rom.data, at + 4);
        out.add(LoadUnitCommand(
          addr: at,
          restriction: 0,
          unitArray: FeRom.isPointer(arg, rom.length) ? arg : 0,
        ));
      }
      if (cmd == 0) break; // EVT_CMD_END
      at += 4 * size;
    }
  }

  /// FE6/FE7 的 `gEventCmdTable`：8 字节一项 `{处理函数, 该命令占用的字数}`。
  ///
  /// 表在 ROM 里，所以改版也能直接用；定位靠「一长串『代码指针 + 1..8 的字数』」
  /// （FE6J 100 项 / FE7J 236 项 / FE7U 232 项，实测均能唯一命中）：
  /// 反编译 `data/data_event.s` 的 `gEventCmdTable` 与 ROM 逐项一致。
  /// 引擎侧用法见 FE7 的 `event-engine.s`：`cmd = *(u16*)script`，
  /// 处理完 `script += table[cmd].size * 4`。
  ({int offset, int count})? commandTable() {
    // FE8 的命令自带长度字段，没有这张表；扫出来的只会是别的指针数组。
    if (_isFe8) return null;
    if (_cmdTableReady) return _cmdTable;
    _cmdTableReady = true;
    const minCount = 40;
    var bestOffset = -1;
    var bestCount = 0;
    for (var a = 0; a + 8 * minCount <= rom.length; a += 4) {
      if (!FeRom.isPointer(FeRom.u32(rom.data, a), rom.length)) continue;
      var n = 0;
      while (a + 8 * (n + 1) <= rom.length) {
        final p = FeRom.u32(rom.data, a + 8 * n);
        final s = FeRom.u32(rom.data, a + 8 * n + 4);
        if (!FeRom.isPointer(p, rom.length) || s < 1 || s > 8) break;
        n++;
        if (n >= 400) break;
      }
      if (n > bestCount) {
        bestCount = n;
        bestOffset = a;
      }
    }
    if (bestCount < minCount) return null;
    return _cmdTable = (offset: bestOffset, count: bestCount);
  }

  /// 命令 [cmd] 占用的字数（含命令字本身）。
  int commandSize(({int offset, int count}) table, int cmd) {
    if (cmd < 0 || cmd >= table.count) return 1;
    final s = FeRom.u32(rom.data, table.offset + 8 * cmd + 4);
    return s < 1 ? 1 : (s > 16 ? 16 : s);
  }

  /// 反汇编处理函数，按「读 `proc->script` → 取参数指针 → 存进 `proc->unit_info`」
  /// 的签名找出 `LOADUNIT` 的命令号。
  ///
  /// 各作命今号不同（FE6 `0x12/0x13`、FE7J `0x30/0x31`、FE7U `0x32/0x33`），
  /// 差两号是因为 FE7U 在前部多了两条背景命令——硬编码容易错位，
  /// 所以优先从 ROM 反推。
  ///
  /// - FE7：`ldr rX, [rY,#0x30]` → `ldr rX, [rX,#4]` → `str rX, [rY,#0x44]`
  ///   （`EventProc.script@0x30` / `.unit_info@0x44`，见 FE7J `event.h`）
  /// - FE6：`ldr rX, [rY,#0x30]` → `ldr rX, [rX,#0]` → `str rX, [rY,#0x3c]`
  ///   （FE6J `event.h` 的 `EventProc.unit_info@0x3C`）
  Set<int> _loadCommandIds(({int offset, int count}) table) {
    if (_loadIdsReady) return _loadIds;
    _loadIdsReady = true;
    final found = <int>{};
    final dis = ArmDisassembler(rom.data);
    for (var cmd = 0; cmd < table.count; cmd++) {
      if (commandSize(table, cmd) != 2) continue;
      final handler = FeRom.u32(rom.data, table.offset + 8 * cmd);
      if (!FeRom.isPointer(handler, rom.length)) continue;
      final off = FeRom.toOffset(handler & ~1);
      if (off + 32 > rom.length) continue;
      final text = dis
          .disassemble(off, DisasmMode.thumb, 12)
          .map((l) => l.text)
          .join('\n');
      if (!text.contains('#0x30]')) continue;
      if (!text.contains('#0x44]') && !text.contains('#0x3c]')) continue;
      found.add(cmd);
    }
    if (found.isEmpty) found.addAll(_defaultLoadCommandIds);
    return _loadIds = found;
  }

  /// 签名匹配失败时的兜底：原版三作的 `LOADUNIT` 命令号。
  List<int> get _defaultLoadCommandIds => switch (rom.table.id) {
        'FE6' => const [0x12, 0x13],
        'FE7J' => const [0x30, 0x31],
        'FE7U' => const [0x32, 0x33],
        _ => const [],
      };

  /// 本 ROM 的 `LOADUNIT` 命令号。
  ///
  /// FE8 固定 `0x2C`（`EV_CMD_LOADUNIT`）；FE6/FE7 从 ROM 命令表按签名反推。
  Set<int> get loadCommandIds {
    if (_isFe8) return const {cmdLoadUnit};
    final table = commandTable();
    if (table == null) return const {};
    return _loadCommandIds(table);
  }

  ({int offset, int count})? _cmdTable;
  bool _cmdTableReady = false;
  Set<int> _loadIds = const {};
  bool _loadIdsReady = false;
}
