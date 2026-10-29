import 'editable_rom.dart';
import 'fe_rom.dart';
import 'unit_placement.dart';

/// 章节陷阱（`TrapData` 数组）。
///
/// 结构取火纹社区反编译（fe8u `include/bmtrap.h` + `bmtrick.h`）：
/// ```
/// 00 u8 type     01 u8 x     02 u8 y
/// 03 u8 subtype  04 u8 turn_counter  05 u8 turn
/// ```
/// 指针在事件组 `traps(+0x20)` / `extraTrapsInHard(+0x24)` 两个槽上。
/// **FE8 条目 6 字节、`type==0` 结尾**（全部章节实测验证过，原版 8 章有数据，
/// 如第 18/31 章的哥尔工蛋 59 个、第 54 章火地板 41 个；重度改版「铠甲的呼唤」
/// 同槽位数据仍在）。**FE7 条目 8 字节且数组头 8 字节是未定名元数据，
/// 记录结构未验证——不画标记，只提示有数据**（宁可少给，也不给错数据）。
/// FE6 的事件组没有这两个槽。
class ChapterTrap {
  final int type;
  final int x;
  final int y;
  final int subtype;
  final int turnCounter;
  final int turn;

  const ChapterTrap({
    required this.type,
    required this.x,
    required this.y,
    required this.subtype,
    required this.turnCounter,
    required this.turn,
  });

  /// 类型名（`bmtrick.h` TRAP_* 枚举；未知类型显示数字）。
  String get label => ChapterTraps.typeName(type);
}

class ChapterTraps {
  final EditableRom edit;
  ChapterTraps(this.edit);

  FeRom get rom => edit.rom;

  /// 本版本的陷阱记录可解码（FE8：6 字节条目实测；FE7 条目 8 字节且头部
  /// 结构未定名 → 不给标记；FE6 无槽）。
  bool get supported => rom.table.id == 'FE8J' || rom.table.id == 'FE8U';

  /// 本版本有 traps 指针槽（FE7 有槽但记录未解码，FE6 没有槽）。
  bool get hasSlot => rom.table.id != 'FE6';

  /// 普通模式陷阱（事件组 +0x20）。
  List<ChapterTrap> traps(int chapter) => _read(chapter, 0x20);

  /// 困难模式追加陷阱（事件组 +0x24）。
  List<ChapterTrap> hardTraps(int chapter) => _read(chapter, 0x24);

  /// 该章 traps 槽是否非空（含不可解码的版本，用于界面提示）。
  bool chapterHasTraps(int chapter) {
    if (!hasSlot) return false;
    final ev = UnitPlacement(edit).eventGroupOffset(chapter);
    if (ev < 0) return false;
    final v = edit.buffer.u32(ev + 0x20);
    return FeRom.isPointer(v, edit.buffer.length);
  }

  List<ChapterTrap> _read(int chapter, int slot) {
    if (!supported) return const [];
    final ev = UnitPlacement(edit).eventGroupOffset(chapter);
    if (ev < 0) return const [];
    final d = edit.buffer.data;
    final v = edit.buffer.u32(ev + slot);
    if (!FeRom.isPointer(v, d.length)) return const [];
    var at = FeRom.toOffset(v);
    final out = <ChapterTrap>[];
    // 6 字节条目，type==0 结尾；最多读 256 条防病态数据
    for (var i = 0; i < 256; i++) {
      if (at + 6 > d.length) break;
      final type = d[at];
      if (type == 0) break;
      final x = d[at + 1];
      final y = d[at + 2];
      // 坐标合理性过滤（地图最大 32×32，宽松到 63）
      if (x <= 63 && y <= 63) {
        out.add(
          ChapterTrap(
            type: type,
            x: x,
            y: y,
            subtype: d[at + 3],
            turnCounter: d[at + 4],
            turn: d[at + 5],
          ),
        );
      }
      at += 6;
    }
    return out;
  }

  /// TRAP_* 枚举（fe8u `include/bmtrick.h`；14/15/16 与 8/9 是运行时派生值，
  /// 静态表里不会出现，未列入）。
  static const Map<int, String> _typeNames = {
    1: '弹弓',
    2: '障碍',
    3: '地图变化',
    4: '火地板',
    5: '毒气',
    6: '地图变化2',
    7: '光箭',
    10: '火把',
    11: '地雷',
    12: '哥尔工蛋',
    13: '光符',
  };

  static String typeName(int type) => _typeNames[type] ?? '类型 $type';
}
