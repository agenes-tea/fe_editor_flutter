import 'chapter_events.dart';
import 'editable_rom.dart';
import 'fe_rom.dart';
import 'unit_placement.dart';

/// 章节事件脚本里被引用的一条对话（文本表 ID）。
class ChapterDialogue {
  final int textId;
  final int address;

  /// 命令字所在文件偏移（十六进制页 / MCP 排查用）。
  const ChapterDialogue(this.textId, this.address);
}

/// 章节对话提取（只读；编辑走 [TextWriter]，见 text_writer.dart）。
///
/// 各版本事件脚本的「显示对话」命令号已逐一在真实 ROM 上验证
/// （探针见 `test/_probe_chapter_dialogs_test.dart`，逐字对到章节 0 的开场白）：
///
/// | 版本 | 命令号 | 文本 ID 位置 |
/// |---|---|---|
/// | FE8J/FE8U | `0x1B`（`EV_CMD_DISPLAYTEXT`，反编译 `eventscript.h`） | 命令字**高 16 位**；负值 = 取事件槽 2（`SETTEXT` 设置） |
/// | FE7J | `0x0D`（主对话）/ `0x17`（带名字插入） | 第 2 字低 16 位 |
/// | FE7U | `0x0D` / `0x18` | 第 2 字低 16 位 |
/// | FE6 | `0x0B/0x0C/0x1B/0x1C/0x1F/0x20`（六个同构的对话显示命令） | 第 2 字低 16 位 |
///
/// 提取范围：该章四类事件列表（回合/角色/地点/其他）+ 开场/结束剧情脚本
/// （`+0x48/+0x4C`，仅 FE7/FE8 有），递归跟 `CALL`（深度 ≤ 3，去重），
/// FE8 额外跟 `gEventSlots[2]` 间接脚本。
///
/// 只收「文本指针表里确实存在」的 ID（`textEntryOffset >= 0`）；
/// 一条都没命中就返回空——宁可少显示，不显示猜出来的。
class ChapterDialogues {
  final EditableRom edit;
  final int chapter;

  /// 按 textId 去重、按出现顺序。
  final List<ChapterDialogue> dialogues;

  ChapterDialogues._(this.edit, this.chapter, this.dialogues);

  /// 提取 [chapter] 章事件脚本引用的全部对话文本 ID。
  static ChapterDialogues of(EditableRom edit, int chapter) {
    final rom = edit.liveRom;
    final ev = ChapterEvents(rom);
    final group = UnitPlacement(edit).eventGroupOffset(chapter);
    if (group <= 0) return ChapterDialogues._(edit, chapter, const []);

    final out = <ChapterDialogue>[];
    final seenIds = <int>{};
    // 用 referencedScripts（不按列表类型过滤）而不是 ev.all：
    // 对话是否被引用与「条目属于哪种触发类型」无关，
    // 按类型严格解析会在边界情况下整段丢掉（见该方法注释）。
    final scripts = <int>[
      ...ev.referencedScripts(group),
      ...ev.sceneScripts(group),
    ];
    final seenScripts = <int>{};

    if (rom.table.id.startsWith('FE8')) {
      for (final s in scripts) {
        _scanFe8(rom, s, out, seenIds, seenScripts, 0, 0);
      }
    } else {
      for (final s in scripts) {
        _scanLegacy(rom, ev, s, out, seenIds, seenScripts, 0);
      }
    }
    return ChapterDialogues._(edit, chapter, out);
  }

  static const int _fe8DisplayText = 0x1B;

  /// 原版三作的对话显示命令号（按版本；改版不保证）。
  static Set<int> _legacyTextCmds(FeRom r) {
    return switch (r.table.id) {
      'FE7J' => const {0x0D, 0x17},
      'FE7U' => const {0x0D, 0x18},
      _ => const {0x0B, 0x0C, 0x1B, 0x1C, 0x1F, 0x20}, // FE6
    };
  }

  /// FE8：命令字自带长度；`0x1B` 的文本 ID 在高 16 位。
  static void _scanFe8(FeRom r, int script, List<ChapterDialogue> out,
      Set<int> seenIds, Set<int> seenScripts, int depth, int slot2) {
    if (depth > 3 || script == 0 || !FeRom.isPointer(script, r.length)) {
      return;
    }
    final start = FeRom.toOffset(script);
    if (!seenScripts.add(start)) return;
    var at = start;
    for (var i = 0; i < 600; i++) {
      if (at + 4 > r.length) break;
      final w = FeRom.u32(r.data, at);
      final cmd = (w >> 8) & 0xFF;
      final len = (w >> 4) & 0xF;
      if (len == 0) break;
      final arg = w >> 16;
      if (cmd == _fe8DisplayText) {
        if (arg < 0) {
          // 负值 = 「显示 gEventSlots[2] 里设过的那个脚本」，跟过去
          if (slot2 != 0 && FeRom.isPointer(slot2, r.length)) {
            _scanFe8(r, slot2, out, seenIds, seenScripts, depth + 1, slot2);
          }
        } else if (arg != 0 &&
            r.textEntryOffset(arg) >= 0 &&
            seenIds.add(arg)) {
          out.add(ChapterDialogue(arg, at));
        }
      }
      if (cmd == ChapterEvents.cmdSetSlot && arg == 2 && len >= 4) {
        slot2 = FeRom.u32(r.data, at + 4);
      }
      if (cmd == ChapterEvents.cmdCall ||
          cmd == ChapterEvents.cmdEnqueueCall) {
        var t = FeRom.u32(r.data, at + 4);
        if (!FeRom.isPointer(t, r.length)) t = slot2;
        _scanFe8(r, t, out, seenIds, seenScripts, depth + 1, slot2);
      }
      if (cmd == ChapterEvents.cmdEnd) break;
      at += 2 * len;
    }
  }

  /// FE6/FE7：命令号在低 16 位，字数查 ROM 自己的 `gEventCmdTable`。
  static void _scanLegacy(
      FeRom r,
      ChapterEvents ev,
      int script,
      List<ChapterDialogue> out,
      Set<int> seenIds,
      Set<int> seenScripts,
      int depth) {
    if (depth > 3 || script == 0 || !FeRom.isPointer(script, r.length)) {
      return;
    }
    final table = ev.commandTable();
    if (table == null) return;
    final start = FeRom.toOffset(script);
    if (!seenScripts.add(start)) return;
    final textCmds = _legacyTextCmds(r);
    var at = start;
    for (var i = 0; i < 600; i++) {
      if (at + 8 > r.length) break;
      final cmd = FeRom.u32(r.data, at) & 0xFFFF;
      if (cmd >= table.count) break;
      final size = ev.commandSize(table, cmd);
      if (textCmds.contains(cmd) && size >= 2) {
        final id = FeRom.u16(r.data, at + 4);
        if (id != 0 && r.textEntryOffset(id) >= 0 && seenIds.add(id)) {
          out.add(ChapterDialogue(id, at));
        }
      }
      if (cmd == 0x0B) {
        final t = FeRom.u32(r.data, at + 4);
        if (FeRom.isPointer(t, r.length)) {
          _scanLegacy(r, ev, t, out, seenIds, seenScripts, depth + 1);
        }
      }
      if (cmd == 0) break;
      at += 4 * size;
    }
  }
}
