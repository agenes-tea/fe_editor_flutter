import 'chapter_events.dart';
import 'editable_rom.dart';
import 'fe_rom.dart';
import 'map_reader.dart';
import 'portrait.dart';
import 'rom_info.dart';
import 'support.dart';
import 'unit_placement.dart';

/// 一条体检结论的严重程度。
enum HealthLevel {
  /// 游戏大概率起不来 / 数据已损坏，必须修。
  error,

  /// 能跑但很可能不是想要的效果（例如坐标落在图外）。
  warn,

  /// 只是信息（该版本本来就没有这张表等）。
  info,
}

/// 一条体检结论。
class HealthIssue {
  final HealthLevel level;
  final String area;
  final String message;

  /// 相关条目索引（有就填，便于界面点过去）。
  final int? entry;

  const HealthIssue(this.level, this.area, this.message, {this.entry});

  Map<String, Object?> toJson() => {
        'level': level.name,
        'area': area,
        'message': message,
        if (entry != null) 'entry': entry,
      };

  @override
  String toString() => '[$area] $message';
}

/// 体检报告。
class HealthReport {
  final List<HealthIssue> issues;

  const HealthReport(this.issues);

  Iterable<HealthIssue> get errors =>
      issues.where((i) => i.level == HealthLevel.error);

  Iterable<HealthIssue> get warnings =>
      issues.where((i) => i.level == HealthLevel.warn);

  bool get ok => errors.isEmpty;

  int get errorCount => errors.length;

  int get warningCount => warnings.length;

  Map<String, Object?> toJson() => {
        'ok': ok,
        'error_count': errorCount,
        'warning_count': warningCount,
        'problems': [for (final e in errors) e.message],
        'warnings': [for (final w in warnings) w.message],
        'issues': [for (final i in issues) i.toJson()],
      };
}

/// ROM 结构体检：静态可判定的那些错。
///
/// 不做「模拟游戏跑一遍」这种深度校验，只抓改变数据后最容易踩的坑：
/// 表基址/条目数被写坏、ID 不再连续（表边界判定失效的根因）、
/// 单位默认职业越界、支援对象越界、章节单位坐标落在图外。
///
/// 同一份代码给界面（体检报告页）与 MCP 的 validate 工具用——
/// 两套各写一份会出现「AI 说没问题、界面报错」。
class RomHealth {
  final EditableRom edit;

  RomHealth(this.edit);

  FeRom get rom => edit.liveRom;

  /// 跑完所有检查。[deep] 为 false 时跳过耗时的逐条扫描（大地图/事件）。
  HealthReport run({bool deep = true}) {
    final out = <HealthIssue>[];
    _checkTables(out);
    if (rom.unitBase > 0 && rom.unitCount > 0) {
      _checkUnitIds(out);
      _checkUnitDefaultClass(out);
    }
    if (rom.classBase > 0 && rom.classCount > 0) _checkClassIds(out);
    if (rom.itemBase > 0 && rom.itemCount > 0) {
      _checkItemIds(out);
      _checkItemPointers(out);
    }
    if (deep) {
      _checkSupports(out);
      _checkChapterUnits(out);
    }
    _checkPortraits(out);
    _checkText(out);
    return HealthReport(out);
  }

  /// 表基址、条目数、表尾是否在 ROM 内。
  void _checkTables(List<HealthIssue> out) {
    void check(String name, int base, int count, int size, int slot) {
      if (slot <= 0) {
        out.add(HealthIssue(HealthLevel.info, name, '$name：该版本没有这张表，跳过'));
        return;
      }
      if (base <= 0) {
        out.add(HealthIssue(HealthLevel.error, name, '$name：表基址无效（$base）'));
        return;
      }
      if (count <= 0) {
        out.add(HealthIssue(
            HealthLevel.error, name, '$name：条目数为 0（表被写坏或指针失效）'));
        return;
      }
      final end = base + count * size;
      if (end > rom.length) {
        out.add(HealthIssue(
          HealthLevel.error,
          name,
          '$name：表尾 0x${end.toRadixString(16)} 超出 ROM 大小 '
              '0x${rom.length.toRadixString(16)}',
        ));
      }
    }

    check('单位表', rom.unitBase, rom.unitCount, rom.table.unitDataSize,
        rom.table.unitPointerSlot);
    check('职业表', rom.classBase, rom.classCount, rom.table.classDataSize,
        rom.table.classPointerSlot);
    check('道具表', rom.itemBase, rom.itemCount, rom.table.itemDataSize,
        rom.table.itemPointerSlot);
  }

  /// 单位表 `u8@4` 必须从 1 连续递增——表边界判定靠的就是它。
  void _checkUnitIds(List<HealthIssue> out) {
    final d = edit.buffer;
    final base = rom.unitBase;
    final size = rom.table.unitDataSize;
    for (var i = 0; i < rom.unitCount; i++) {
      final at = base + i * size + UnitOffsets.unitId;
      final id = d.u8(at);
      if (id != i + 1) {
        out.add(HealthIssue(
          HealthLevel.error,
          '单位表',
          '第 $i 条的 unit ID 是 $id（应为 ${i + 1}）——表边界判定会在这里提前结束',
          entry: i,
        ));
        return;
      }
    }
  }

  void _checkClassIds(List<HealthIssue> out) {
    final d = edit.buffer;
    final base = rom.classBase;
    final size = rom.table.classDataSize;
    // 职业 ID 从 0 起连续（ID 0 空槽）
    for (var i = 0; i < rom.classCount; i++) {
      final id = d.u8(base + i * size + ClassOffsets.classNumber);
      if (id != i) {
        out.add(HealthIssue(
          HealthLevel.warn,
          '职业表',
          '第 $i 条的 class number 是 $id（应为 $i）',
          entry: i,
        ));
        return;
      }
    }
  }

  void _checkItemIds(List<HealthIssue> out) {
    final d = edit.buffer;
    final base = rom.itemBase;
    final size = rom.table.itemDataSize;
    for (var i = 0; i < rom.itemCount; i++) {
      final id = d.u8(base + i * size + ItemOffsets.itemId);
      if (id != i) {
        out.add(HealthIssue(
          HealthLevel.warn,
          '道具表',
          '第 $i 条的 item ID 是 $id（应为 $i）',
          entry: i,
        ));
        return;
      }
    }
  }

  /// 单位的默认职业必须落在职业表内，否则进游戏会读垃圾。
  void _checkUnitDefaultClass(List<HealthIssue> out) {
    final d = edit.buffer;
    final base = rom.unitBase;
    final size = rom.table.unitDataSize;
    final classCount = rom.classCount;
    if (classCount <= 0) return;
    var bad = 0;
    int? firstBad;
    for (var i = 0; i < rom.unitCount; i++) {
      final cid = d.u8(base + i * size + 5);
      // 0 表示「用角色默认职业」的写法只出现在事件动态单位；
      // 单位表里 0 是合法的空职业（FE6 常见），不算错。
      if (cid >= classCount) {
        bad++;
        firstBad ??= i;
      }
    }
    if (bad > 0) {
      out.add(HealthIssue(
        HealthLevel.error,
        '单位表',
        '$bad 个角色的默认职业 ID ≥ 职业表条目数（$classCount）'
            '${firstBad != null ? '，第一个是第 $firstBad 条' : ''}',
        entry: firstBad,
      ));
    }
  }

  /// 道具的两个指针（数值加成表 / 克制职业列表）必须可用。
  void _checkItemPointers(List<HealthIssue> out) {
    final d = edit.buffer;
    final base = rom.itemBase;
    final size = rom.table.itemDataSize;
    var bad = 0;
    int? firstBad;
    for (var i = 0; i < rom.itemCount; i++) {
      final at = base + i * size;
      if (at + size > d.length) break;
      // ID 0 是空槽，没有指针
      if (d.u8(at + ItemOffsets.itemId) == 0) continue;
      for (final off in [
        ItemOffsets.statBonusPointer,
        ItemOffsets.usableClassPointer,
      ]) {
        final p = d.u32(at + off);
        if (p == 0) continue;
        if (!FeRom.isPointer(p, rom.length)) {
          bad++;
          firstBad ??= i;
          break;
        }
      }
    }
    if (bad > 0) {
      out.add(HealthIssue(
        HealthLevel.warn,
        '道具表',
        '$bad 个道具的指针指向 ROM 外（第一个是第 $firstBad 条）',
        entry: firstBad,
      ));
    }
  }

  /// 支援对象 ID 必须落在单位表内。支援 ID 是 1 基的 `number`。
  void _checkSupports(List<HealthIssue> out) {
    final table = SupportTable(rom);
    final unitCount = rom.unitCount;
    if (unitCount <= 0) return;
    var bad = 0;
    int? firstBad;
    for (var i = 0; i < unitCount; i++) {
      final at = table.addressOf(i);
      if (at < 0) continue;
      final n = table.countOf(i);
      for (var s = 0; s < n; s++) {
        final partner = edit.buffer.u8(at + SupportTable.partnerOffset(s));
        if (partner == 0) continue;
        if (partner > unitCount) {
          bad++;
          firstBad ??= i;
          break;
        }
      }
    }
    if (bad > 0) {
      out.add(HealthIssue(
        HealthLevel.warn,
        '支援',
        '$bad 个角色的支援对象 ID 超出单位表范围（第一个是第 $firstBad 条）',
        entry: firstBad,
      ));
    }
  }

  /// 章节初始单位：坐标必须落在本章地图内，角色/职业/道具 ID 必须有效。
  void _checkChapterUnits(List<HealthIssue> out) {
    final placement = UnitPlacement(edit);
    final map = MapReader(rom);
    final chapters = placement.chapterCount;
    if (chapters <= 0) return;
    final unitCount = rom.unitCount;
    final classCount = rom.classCount;
    final itemCount = rom.itemCount;

    var badUnit = 0;
    var badPos = 0;
    int? firstBadChapter;
    final examples = <String>[];

    for (var ch = 0; ch < chapters; ch++) {
      // 对战/试炼塔与脏条目里的「单位」不是剧情出场单位，
      // 它们的坐标与 ID 本来就不受本章地图约束（与 playable_units 同口径跳过）。
      if (placement.isArenaChapter(ch)) continue;
      final m = map.available ? map.chapterMap(ch) : null;
      // 地图读不出来的条目无法校验坐标，也无法确认它是否真是章节
      // （FE8J 章节表尾部会多扫出几条残留数据）。
      if (m == null) continue;
      for (final slot in UnitSlot.values) {
        if (!placement.slotSupported(slot)) continue;
        final units = placement.units(ch, slot);
        for (final u in units) {
          if (u.isEmpty) continue;
          var bad = false;
          if (u.charId > unitCount) {
            badUnit++;
            bad = true;
          }
          if (u.classId >= classCount) {
            badUnit++;
            bad = true;
          }
          for (final it in u.items) {
            if (it != 0 && itemCount > 0 && it >= itemCount) {
              badUnit++;
              bad = true;
            }
          }
          if (u.x >= m.width || u.y >= m.height) {
            badPos++;
            if (examples.length < 3) {
              examples.add('第 $ch 章 ${slot.label} (${u.x},${u.y})');
            }
          }
          if (bad) firstBadChapter ??= ch;
        }
      }
    }

    if (badUnit > 0) {
      out.add(HealthIssue(
        HealthLevel.error,
        '章节单位',
        '$badUnit 处章节单位的角色/职业/道具 ID 越界'
            '${firstBadChapter != null ? '，第一个出现在第 $firstBadChapter 章' : ''}',
        entry: firstBadChapter,
      ));
    }
    if (badPos > 0) {
      out.add(HealthIssue(
        HealthLevel.warn,
        '章节单位',
        '$badPos 处章节单位坐标落在地图外'
            '${examples.isNotEmpty ? '（${examples.join('、')}）' : ''}',
        entry: firstBadChapter,
      ));
    }
  }

  void _checkPortraits(List<HealthIssue> out) {
    final reader = PortraitReader(rom);
    if (!reader.available) {
      out.add(HealthIssue(HealthLevel.info, '肖像表', '该版本没有可读的肖像表'));
      return;
    }
    if (reader.entryCount <= 0) {
      out.add(HealthIssue(HealthLevel.error, '肖像表', '肖像表条目数为 0'));
    }
    reader.dispose();
  }

  void _checkText(List<HealthIssue> out) {
    if (!rom.textAvailable) {
      out.add(HealthIssue(
          HealthLevel.info, '文本', '文本不可用（该 ROM 的文本引擎未识别）'));
      return;
    }
    var readable = 0;
    final n = rom.unitCount < 50 ? rom.unitCount : 50;
    for (var i = 0; i < n; i++) {
      if (rom.unitDisplayName(i).trim().isNotEmpty) readable++;
    }
    if (n > 0 && readable == 0) {
      out.add(HealthIssue(
          HealthLevel.error, '文本', '前 $n 个单位名全部解不出（文本引擎或指针被写坏）'));
    }
  }

  /// 改动摘要：按区域统计改了哪些条目（diff 面板用）。
  static Map<String, Object?> summarizeEdits(EditableRom edit) {
    final base = edit.original;
    final cur = edit.buffer.data;
    final byArea = <String, List<int>>{};
    final rom = edit.rom;

    void classify(int offset) {
      final range = _rangeOf(rom, offset);
      final list = byArea.putIfAbsent(range, () => []);
      list.add(offset);
    }

    var total = 0;
    final n = base.length < cur.length ? base.length : cur.length;
    for (var i = 0; i < n; i++) {
      if (base[i] == cur[i]) continue;
      total++;
      classify(i);
    }
    return {
      'total_bytes': total,
      'areas': {
        for (final e in byArea.entries)
          e.key: {'bytes': e.value.length, 'first_offset': e.value.first},
      },
    };
  }

  static String _rangeOf(FeRom rom, int offset) {
    bool inside(int base, int count, int size) =>
        base > 0 && count > 0 && offset >= base && offset < base + count * size;
    if (inside(rom.unitBase, rom.unitCount, rom.table.unitDataSize)) {
      return '单位表';
    }
    if (inside(rom.classBase, rom.classCount, rom.table.classDataSize)) {
      return '职业表';
    }
    if (inside(rom.itemBase, rom.itemCount, rom.table.itemDataSize)) {
      return '道具表';
    }
    return '其他';
  }
}

/// 章节事件里的事件组能否读出（体检时顺带确认）。
bool eventGroupLooksValid(EditableRom edit, int chapter) {
  final at = UnitPlacement(edit).eventGroupOffset(chapter);
  if (at <= 0) return false;
  final ev = ChapterEvents(edit.rom);
  return ev.all(at).isNotEmpty;
}
