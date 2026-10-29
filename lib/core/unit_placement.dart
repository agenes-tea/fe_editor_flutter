import 'dart:typed_data';

import 'chapter_events.dart';
import 'editable_rom.dart';
import 'fe_rom.dart';

/// 单位所属阵营（对应 `UnitDefinition.allegiance` 两位）。
enum Allegiance {
  player('自军', 0),
  ally('友军', 1),
  enemy('敌军', 2);

  final String label;
  final int code;
  const Allegiance(this.label, this.code);

  static Allegiance fromCode(int code) {
    for (final a in values) {
      if (a.code == code) return a;
    }
    return Allegiance.enemy;
  }
}

/// 章节里配置的一个初始单位（`UnitDefinition`）。
///
/// FE6/FE7 每条 16 字节、FE8 每条 20 字节：FE8 多了「移动后坐标」指针。
/// `+3` 是成长值字节，按位域拆成：bit0 自动成长、bit1-2 阵营、bit3-7 等级。
/// **阵营与等级同字节**，写入必须按位合并，整字节覆盖会把等级清零。
class PlacedUnit {
  /// 该条目在 ROM 里的地址（文件偏移）。
  final int addr;
  final bool isFe8;

  /// 角色 **number**（u8@0，反编译 `UnitDefinition::pid`）。
  ///
  /// **1 基**：0 表示空槽，其余取值是单位表 `number` 字段的值
  /// （= 表内索引 + 1）。查角色表要减 1（见 [unitIndex]），
  /// 否则名字会整体偏一位（实测 FE7 第 0 章第一个人显示成雷万而不是琳）。
  /// 职业 ID（+1）本身就是 0 基索引，不需要换算。
  final int charId;

  /// 角色在单位表里的索引（表内偏移恒等于列表 ID）。
  int get unitIndex => charId - 1;

  final int classId;
  final int leaderId;
  final bool autoGrow;
  final Allegiance allegiance;
  final int level;
  final int x;
  final int y;

  /// 移动后坐标（FE8 可能有多段，这里只取最后一段用于显示）。
  final List<({int x, int y})> movePath;
  final List<int> items;
  final List<int> ai;

  const PlacedUnit({
    required this.addr,
    required this.isFe8,
    required this.charId,
    required this.classId,
    required this.leaderId,
    required this.autoGrow,
    required this.allegiance,
    required this.level,
    required this.x,
    required this.y,
    required this.movePath,
    required this.items,
    required this.ai,
  });

  bool get isEmpty => charId == 0;
}

/// 章节初始单位入口。
///
/// 槽位语义按反编译的 `chapterdata.h` / `chapterinfo.h`（火纹社区各版反编译仓库）：
/// - FE7/FE8 事件组（`ChapterEventGroup`）：`+0x28/+0x2C` 我方普通/困难；
///   `+0x30..+0x44` 是 6 个遭遇战槽（我方遭遇 1-3 / 敌方遭遇 1-3），**仅 FE8**——
///   该区域在 FE7 是填充，`+0x38` 起是剧情事件指针，当作单位读会解出
///   越界坐标（这就是早期把 `+0x3C` 当「遭遇战敌方」展示的越界数据根因）。
///   FE8 原版里 12 章配置了遭遇战（六个槽都有单位、敌军阵营位=2），
///   其余章节为 NULL；剧情中生成的敌人仍由事件脚本 `LOAD` 指令生成。
/// - FE6（`ChapterEventInfo`，见 `chapterinfo.h`）：`+0x10/+0x14` 直接挂红/蓝
///   两路 16 字节 `UnitInfo` 数组（pid==0 结尾），不需要解析事件脚本。
enum UnitSlot {
  playerNormal('我方（普通）', 0x28),
  playerHard('我方（困难）', 0x2C),
  encounterPlayer1('遭遇我方 1', 0x30),
  encounterPlayer2('遭遇我方 2', 0x34),
  encounterPlayer3('遭遇我方 3', 0x38),
  encounterEnemy1('遭遇敌方 1', 0x3C),
  encounterEnemy2('遭遇敌方 2', 0x40),
  encounterEnemy3('遭遇敌方 3', 0x44),
  blueUnits('蓝方（我军）', 0x14),
  redUnits('红方（敌军）', 0x10);

  final String label;

  /// 事件组内的偏移；FE6 两个入口是 `ChapterEventInfo` 内的偏移，数值恰好相同。
  /// 遭遇 6 槽在 FE7 同区域是填充 + 剧情事件指针（当单位读会解出越界坐标），
  /// 仅 FE8 有效；FE8 原版有遭遇战的章节（第 4/7/11/13/17/18/24/26/30/31 等）
  /// 六个槽都有数据，其余章节为 NULL。
  final int offset;

  bool get isEncounter =>
      this == encounterPlayer1 ||
      this == encounterPlayer2 ||
      this == encounterPlayer3 ||
      this == encounterEnemy1 ||
      this == encounterEnemy2 ||
      this == encounterEnemy3;

  bool get isFe6Units => this == redUnits || this == blueUnits;

  const UnitSlot(this.label, this.offset);
}

/// 章节初始单位的读写。
class UnitPlacement {
  final EditableRom edit;
  UnitPlacement(this.edit);

  FeRom get rom => edit.rom;

  bool get isFe8 => _isFe8Table;

  /// 条目大小：FE8 = 20，FE6/FE7 = 16。
  int get entrySize => _isFe8Table ? 20 : 16;

  bool get _isFe8Table => rom.table.id == 'FE8J' || rom.table.id == 'FE8U';

  bool get _isFe6 => rom.table.id == 'FE6';

  /// 地图设置表指针槽。
  int get _chapterSettingSlot {
    switch (rom.table.id) {
      case 'FE6':
        return 0x2BB20;
      case 'FE7J':
        return 0x31A6C;
      case 'FE7U':
        return 0x31580;
      case 'FE8J':
        return 0x0BAB1C;
      case 'FE8U':
        return 0x0B5F98;
    }
    return 0;
  }

  /// 事件 plist 表指针槽。
  int get _eventPlistSlot {
    switch (rom.table.id) {
      case 'FE6':
        return 0x02BBCC;
      case 'FE7J':
        return 0x031B18;
      case 'FE7U':
        return 0x0315D4;
      case 'FE8J':
        return 0x0345E4;
      case 'FE8U':
        return 0x0346DC;
    }
    return 0;
  }

  int get _settingSize {
    switch (rom.table.id) {
      case 'FE6':
        return 68;
      case 'FE7U':
        return 152;
    }
    return 148;
  }

  /// 章节条目内「事件 plist 索引」的位置。
  ///
  /// FE7U 的条目是 152 字节（比 FE7J/FE8 的 148 多一对 `u16`），
  /// 该字段随之从 +116 后移到 +120。实测按 +116 读会拿到 palette 索引，
  /// 事件组指到图形数据上——章节单位整体读错（TLP 同为 152 字节条目，同样受影响）。
  int get _eventPlistPos => _settingSize == 152 ? 120 : 116;

  int? _settingBase;

  int get settingBase {
    final cached = _settingBase;
    if (cached != null) return cached;
    final slot = _chapterSettingSlot;
    final v = slot > 0 ? _pointerAt(slot) : -1;
    return _settingBase = v;
  }

  int? _chapterCount;

  int get chapterCount {
    final cached = _chapterCount;
    if (cached != null) return cached;
    if (settingBase <= 0) return _chapterCount = 0;
    var n = 0;
    var miss = 0;
    var lastValid = 0;
    while (n < 400) {
      final at = settingBase + _settingSize * n;
      if (at + _settingSize > _d.length) break;
      if (_pointerAt(at) < 0) {
        miss++;
        if (miss >= 8) break;
      } else {
        miss = 0;
        lastValid = n + 1;
      }
      n++;
    }
    return _chapterCount = lastValid;
  }

  /// 当前可编辑数据。
  ///
  /// 读取必须走这里而不是 `rom.data`：`rom.data` 是打开时的原始快照，
  /// 修改后读它会拿到旧值（踩过：改完坐标再读仍是原值）。
  Uint8List get _d => edit.buffer.data;

  int _u8(int at) => edit.buffer.u8(at);
  int _u16(int at) => edit.buffer.u16(at);
  int _u32(int at) => edit.buffer.u32(at);

  /// 事件组基址（文件偏移）；不可用时返回 -1。
  ///
  /// FE6 不走事件 plist：它的事件组是 `ChapterAssets[idx]` 指向的
  /// `ChapterEventInfo`（4 个事件列表 + 红/蓝单位 + 过关脚本）。
  /// 照 FE7/FE8 的 plist 读会拿到别的结构（实测 FE6 第 1 章读出 50 条
  /// 「地点事件」，script 指到图形数据）。
  int eventGroupOffset(int chapter) {
    if (chapter < 0 || chapter >= chapterCount) return -1;
    if (_isFe6) return _fe6EventGroupOffset(chapter);
    final settingAt = settingBase + _settingSize * chapter;
    final eventPlist = _u8(settingAt + _eventPlistPos);
    final plistBase = _pointerAt(_eventPlistSlot);
    if (plistBase < 0) return -1;
    final at = plistBase + 4 * eventPlist;
    if (at + 4 > _d.length) return -1;
    return _pointerAt(at);
  }

  int _pointerAt(int slot) {
    if (slot < 0 || slot + 4 > _d.length) return -1;
    final v = _u32(slot);
    if (!FeRom.isPointer(v, _d.length)) return -1;
    final off = FeRom.toOffset(v);
    return off < _d.length ? off : -1;
  }

  /// 某个入口的单位列表起始偏移；该入口为空时返回 -1。
  int slotOffset(int chapter, UnitSlot slot) {
    if (slot.isFe6Units) return _fe6SlotOffset(chapter, slot);
    final ev = eventGroupOffset(chapter);
    if (ev < 0) return -1;
    final at = ev + slot.offset;
    if (at + 4 > _d.length) return -1;
    final v = _u32(at);
    if (!FeRom.isPointer(v, _d.length)) return -1;
    return FeRom.toOffset(v);
  }

  /// 该入口是否在本作里存在。
  ///
  /// 五作单位入口都在静态表里，区别只在版本：
  /// - 遭遇 6 槽仅 FE8（FE7 同区域是填充 + 剧情事件指针）；
  /// - 红/蓝两路仅 FE6（`ChapterEventInfo` 专属布局）；
  /// - 我方普通/困难两路仅 FE7/FE8。
  bool slotSupported(UnitSlot slot) {
    if (slot.isFe6Units) return _isFe6;
    if (slot.isEncounter) return _isFe8Table;
    return !_isFe6;
  }

  /// 默认入口：我方（普通）不可用时（FE6）回退到本作第一个可用入口。
  UnitSlot get defaultSlot => slotSupported(UnitSlot.playerNormal)
      ? UnitSlot.playerNormal
      : UnitSlot.values.firstWhere(slotSupported);

  /// 读一个入口的全部单位。
  ///
  /// 带**坐标合理性过滤**：FE 的地图最大 32×32，坐标超出 0..32 的条目必然
  /// 不是真实单位（FE7 某些入口会读到无关数据）。这样即使某个入口的偏移
  /// 判错，也只是「少显示」而不会在屏幕上画出错位小人。
  List<PlacedUnit> units(int chapter, UnitSlot slot) {
    final start = slotOffset(chapter, slot);
    if (start < 0) return const [];
    final out = <PlacedUnit>[];
    for (var i = 0; i < 64; i++) {
      final at = start + entrySize * i;
      if (at + entrySize > _d.length) break;
      if (_u8(at) == 0) break;
      final u = _readUnit(at);
      if (u.x < 0 || u.y < 0 || u.x > 32 || u.y > 32) continue;
      out.add(u);
    }
    return out;
  }

  /// 按条目地址读一个单位（供编辑页刷新用）。
  PlacedUnit? unitAt(int addr) {
    if (addr < 0 || addr + entrySize > _d.length) return null;
    if (_u8(addr) == 0) return null;
    return _readUnit(addr);
  }

  PlacedUnit _readUnit(int at) {
    final grow = _u8(at + 3);
    final autoGrow = (grow & 1) != 0;
    final allegiance = Allegiance.fromCode((grow >> 1) & 0x03);
    final level = (grow >> 3) & 0x1F;

    int x;
    int y;
    final path = <({int x, int y})>[];
    if (_isFe8Table) {
      final packed = _u16(at + 4);
      x = packed & 0x3F;
      y = (packed >> 6) & 0x3F;
      final count = _u8(at + 7);
      final ptr = _u32(at + 8);
      if (count > 0 && FeRom.isPointer(ptr, _d.length)) {
        final base = FeRom.toOffset(ptr);
        for (var i = 0; i < count && i < 20; i++) {
          final p = base + i * 8;
          if (p + 2 > _d.length) break;
          final v = _u16(p);
          path.add((x: v & 0x3F, y: (v >> 6) & 0x3F));
        }
      }
    } else {
      x = _u8(at + 4);
      y = _u8(at + 5);
      final ax = _u8(at + 6);
      final ay = _u8(at + 7);
      if (ax != x || ay != y) path.add((x: ax, y: ay));
    }

    // 条目大小不同，尾段偏移不同（FE8 条目 20 字节、FE6/FE7 16 字节）：
    // items@+12/+8、ai@+16/+12。曾按 FE8 布局通读，FE7/FE6 把 AI 显示成道具、
    // 把下一条单位的头部显示成 AI（反编译 UnitDefinition 已核对）。
    final itemsBase = _isFe8Table ? 12 : 8;
    final aiBase = _isFe8Table ? 16 : 12;
    final items = <int>[for (var i = 0; i < 4; i++) _u8(at + itemsBase + i)];
    final ai = <int>[for (var i = 0; i < 4; i++) _u8(at + aiBase + i)];

    return PlacedUnit(
      addr: at,
      isFe8: _isFe8Table,
      charId: _u8(at),
      classId: _u8(at + 1),
      leaderId: _u8(at + 2),
      autoGrow: autoGrow,
      allegiance: allegiance,
      level: level,
      x: x,
      y: y,
      movePath: path,
      items: items,
      ai: ai,
    );
  }

  // ---------- FE6：ChapterInfo / ChapterAssets / ChapterEventInfo ----------

  /// `ChapterInfo` 条目内 `asset_event_info` 字段（`+0x3A`，`unknown_types.h`）。
  static const int _assetEventInfoPos = 0x3A;

  int? _fe6AssetsBase;

  /// FE6：`ChapterAssets` 指针表基址（文件偏移）；不可用时返回 -1。
  ///
  /// `ChapterAssets[idx]` 指向 0x1C 字节 `ChapterEventInfo`（`chapterinfo.h`）：
  /// 4 个事件列表指针 + `units_red@+0x10` + `units_blue@+0x14`。
  /// 首选 fe6j 反编译符号表给的偏移 `0x664398`（`ChapterAssets` @ 0x8664398，
  /// laqieer/fe-info `json/fe6/data.json`；原版与狼组汉化实测同址，恰好是
  /// `ChapterInfoTable` 44 条目之后）。验不过再在 ±64KB 内按 68 字节条目对齐
  /// 回退扫描（防改版搬表；68 对齐可排除指针表内部错位 4 字节的假候选）。
  /// 验不过再往后按 68 字节条目对齐扫描（防改版搬表；对齐保证指针表不错位
  /// 4 字节——错位后 `ChapterAssets[idx]` 整体偏一格，读出来的是世界地图
  /// 变体的单位表，数值看着像对的但全偏）。
  int _fe6AssetsBaseFor() {
    final cached = _fe6AssetsBase;
    if (cached != null) return cached;
    final n = _fe6ChapterCount();
    if (n == 0) return _fe6AssetsBase = -1;
    if (_fe6AssetsValid(0x664398, n)) return _fe6AssetsBase = 0x664398;
    // 回退：从章节表往后逐个 68 字节条目找（对齐保证不会错位读指针表）。
    final base = settingBase;
    for (var k = 1;
        base + _settingSize * k + 4 <= _d.length && k <= 1024;
        k++) {
      final cand = base + _settingSize * k;
      if (cand != 0x664398 && _fe6AssetsValid(cand, n)) {
        return _fe6AssetsBase = cand;
      }
    }
    return _fe6AssetsBase = -1;
  }

  /// FE6 章节数：连续的「debug_name 为可打印串」条目（原版 44 条；
  /// 不能只数「条目头是合法指针」——`ChapterAssets[0]` 自己就是合法指针，
  /// 会被误数成第 45 条）。
  int _fe6ChapterCount() {
    final base = settingBase;
    if (base <= 0) return 0;
    var n = 0;
    while (n < 512) {
      final at = base + _settingSize * n;
      if (at + _settingSize > _d.length) break;
      if (!_fe6DebugNameLooksValid(_u32(at))) break;
      n++;
    }
    return n;
  }

  bool _fe6DebugNameLooksValid(int ptr) {
    if (!FeRom.isPointer(ptr, _d.length)) return false;
    final o = FeRom.toOffset(ptr);
    for (var i = 0; i < 8; i++) {
      final at = o + i;
      if (at >= _d.length) return false;
      final b = _u8(at);
      if (b == 0) return i > 0; // 3~8 字节的 NUL 结尾串
      if (b < 0x20 || b > 0x7E) return false;
    }
    return false;
  }

  int _fe6SlotOffset(int chapter, UnitSlot slot) {
    final epi = _fe6EventGroupOffset(chapter);
    if (epi < 0) return -1;
    final up = _u32(epi + slot.offset);
    if (!FeRom.isPointer(up, _d.length)) return -1;
    return FeRom.toOffset(up);
  }

  /// FE6 的 `ChapterEventInfo` 基址（文件偏移）：`ChapterAssets[asset_event_info]`。
  ///
  /// 章节表的尾部（试炼塔/对战等非剧情条目）`asset_event_info` 是脏值，
  /// 解出来会指向别的数据（实测某章读出 87 条事件），所以要先校验结构：
  /// 4 个列表指针必须为 0 或合法指针，且每个列表首条的 cmd（低 16 位）
  /// 在 `EVT_LIST_CMD_*`（0..0x0D）范围内。
  int _fe6EventGroupOffset(int chapter) {
    final assets = _fe6AssetsBaseFor();
    if (assets < 0) return -1;
    final settingAt = settingBase + _settingSize * chapter;
    if (settingAt + _assetEventInfoPos > _d.length) return -1;
    final idx = _u8(settingAt + _assetEventInfoPos);
    final at = assets + 4 * idx;
    if (at + 4 > _d.length) return -1;
    final v = _u32(at);
    if (!FeRom.isPointer(v, _d.length)) return -1;
    final o = FeRom.toOffset(v);
    if (o + 0x1C > _d.length) return -1;
    for (var f = 0; f < 4; f++) {
      final p = _u32(o + 4 * f);
      if (p == 0) continue;
      if (!FeRom.isPointer(p, _d.length)) return -1;
      final listAt = FeRom.toOffset(p);
      if (listAt + 4 > _d.length) return -1;
      if ((_u32(listAt) & 0xFFFF) > 0x0D) return -1;
    }
    return o;
  }

  /// 校验一个候选 `ChapterAssets` 指针表：前若干章的 `asset_event_info`
  /// 解出的 `ChapterEventInfo` 结构完整，且至少一路单位数组可读。
  bool _fe6AssetsValid(int assets, int chapterN) {
    var checked = 0;
    var sawUnits = false;
    for (var i = 0; i < chapterN && checked < 8; i++) {
      final idx = _u8(settingBase + _settingSize * i + _assetEventInfoPos);
      final at = assets + 4 * idx;
      if (at + 4 > _d.length) return false;
      final v = _u32(at);
      if (v == 0) continue;
      if (!FeRom.isPointer(v, _d.length)) return false;
      final o = FeRom.toOffset(v);
      if (o + 0x1C > _d.length) return false;
      for (var f = 0; f < 4; f++) {
        final p = _u32(o + f * 4);
        if (p != 0 && !FeRom.isPointer(p, _d.length)) return false;
      }
      for (final f in const [0x10, 0x14]) {
        final p = _u32(o + f);
        if (p == 0) continue;
        if (!FeRom.isPointer(p, _d.length)) return false;
        if (!_fe6UnitArrayValid(FeRom.toOffset(p))) return false;
        sawUnits = true;
      }
      checked++;
    }
    return sawUnits;
  }

  /// 16 字节 `UnitInfo` 数组：pid==0 结尾，坐标合理。
  bool _fe6UnitArrayValid(int start) {
    for (var i = 0; i < 32; i++) {
      final e = start + 16 * i;
      if (e + 16 > _d.length) return false;
      if (_u8(e) == 0) break;
      if (_u8(e + 4) > 32 || _u8(e + 5) > 32) return false;
    }
    return true;
  }

  /// 全部章节里「作为我方出场过」的角色 number（1 基，与 [PlacedUnit.charId] 同语义）。
  ///
  /// 单位表没有阵营字段，但章节的初始单位配置里有：把这些条目收集起来，
  /// 就是「至少能被我操控一次」的角色集合——比「有支援数据」更贴近实际出场。
  /// 改版常见「主线主角没配支援对话」（实测 TLP v1.5 的辛格弗雷德支援指针为 0），
  /// 按支援判据会把他排除在外，成长率类预设就对他无效。
  ///
  /// 只读「我方（普通/困难）」与 FE6 蓝方这几组静态入口：遭遇战槽是敌军配置，
  /// 阵营位不可靠；红方（FE6）/剧情脚本生成的增援不在静态表里（后者无法覆盖）。
  Set<int> deployedUnitNumbers() => deployedNumbersOf(edit.rom);

  /// 同一份扫描的只读入口（供只需要 `FeRom` 的调用方使用，如修改器）。
  static Set<int> deployedNumbersOf(FeRom rom) {
    final up = UnitPlacement(EditableRom.open(rom.data, rom.table));
    final out = <int>{};
    final slots = <UnitSlot>[
      if (up.slotSupported(UnitSlot.playerNormal)) UnitSlot.playerNormal,
      if (up.slotSupported(UnitSlot.playerHard)) UnitSlot.playerHard,
      if (up.slotSupported(UnitSlot.blueUnits)) UnitSlot.blueUnits,
    ];
    for (var ch = 0; ch < up.chapterCount; ch++) {
      // 对战/试炼塔/斗技场章节（debug_name 以 T / R / C / H 开头）里的「我方」
      // 是临时生成的对战对手或 NPC，不是剧情可控角色，不能算进名单
      // （实测 FE8J 会把「対戦相手」当成我方角色）。
      if (up.isArenaChapter(ch)) continue;
      for (final slot in slots) {
        for (final u in up.units(ch, slot)) {
          if (u.charId > 0) out.add(u.charId);
        }
      }
    }
    return out;
  }

  /// 事件脚本里以**我方（蓝方）**身份出场的角色 `number`（1 基）。
  ///
  /// 与 [deployedNumbersOf] 同口径（跳过对战/试炼塔章节），只是把来源扩到事件脚本的
  /// `LOADUNIT`：剧情增援、后期加入我都会在这一层。
  /// **只收蓝方**（`allegiance == 0`）——红方是敌军、绿方是不可操控的 NPC，
  /// 算进来会让「成长率拉满」连敌人一起加强。
  ///
  /// 扫全章事件不便宜（烈火三千多个事件条目），所以按 ROM 指纹缓存。
  static final Map<int, Set<int>> _eventNumbersCache = {};

  static Set<int> eventUnitNumbersOf(FeRom rom) {
    final key = rom.fingerprint;
    final cached = _eventNumbersCache[key];
    if (cached != null) return cached;
    final up = UnitPlacement(EditableRom.open(rom.data, rom.table));
    final ce = ChapterEvents(rom);
    final out = <int>{};
    for (var ch = 0; ch < up.chapterCount; ch++) {
      if (up.isArenaChapter(ch)) continue;
      final ev = up.eventGroupOffset(ch);
      if (ev <= 0) continue;
      for (final e in ce.all(ev)) {
        for (final u in ce.loadedUnits(e.script)) {
          if (u.allegiance == 0 && u.charId > 0) out.add(u.charId);
        }
      }
    }
    return _eventNumbersCache[key] = out;
  }

  /// 该章是否是对战/试炼塔章节。
  ///
  /// 章节条目的 `+0` 是 debug_name 指针（`L00` / `T01)00` / `R05` / `C00` 等）。
  /// 剧情章节以 L（琳篇）/ E（艾利乌德篇等）/ I（外传）开头，
  /// 对战与试炼塔类以 T / R / C / H 开头。
  ///
  /// 条目数扫到表尾之后会出现「debug_name 不是可打印串」的脏条目
  /// （实测 FE8J 下标 79/85 就是这样，里面装的是带大量 `対戦相手` 的
  /// 对战用单位表），这种也一并当作不可用。
  bool isArenaChapter(int chapter) {
    if (chapter < 0 || chapter >= chapterCount) return true;
    final nameOff = _pointerAt(settingBase + _settingSize * chapter);
    if (nameOff < 0) return true;
    final c = _u8(nameOff);
    // 不是可打印 ASCII 字母/数字 → 脏条目
    final printable =
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A);
    if (!printable) return true;
    // T=对战, R=试炼塔, C=斗技场, H=隐藏关
    return c == 0x54 || c == 0x52 || c == 0x43 || c == 0x48;
  }

  // ---------- 写入 ----------

  /// 改坐标。
  bool setPosition(PlacedUnit unit, int x, int y) {
    if (x < 0 || y < 0 || x > 63 || y > 63) return false;
    if (_isFe8Table) {
      final at = unit.addr + 4;
      final before = edit.buffer.u16(at);
      final ext = (before >> 12) & 0xF;
      final packed = (ext << 12) | ((y & 0x3F) << 6) | (x & 0x3F);
      if (packed == before) return false;
      edit.buffer.writeU16(at, packed);
      edit.edits.add(ByteEdit(at, before, packed));
      return true;
    }
    final changed1 = _writeU8(unit.addr + 4, x);
    final changed2 = _writeU8(unit.addr + 5, y);
    return changed1 || changed2;
  }

  /// 改等级（bit3-7），保留自动成长与阵营位。
  bool setLevel(PlacedUnit unit, int level) {
    if (level < 0 || level > 31) return false;
    final at = unit.addr + 3;
    final before = edit.buffer.u8(at);
    final after = (before & 0x07) | ((level & 0x1F) << 3);
    if (after == before) return false;
    edit.buffer.writeU8(at, after);
    edit.edits.add(ByteEdit(at, before, after));
    return true;
  }

  /// 改阵营（bit1-2），保留等级位。
  bool setAllegiance(PlacedUnit unit, Allegiance allegiance) {
    final at = unit.addr + 3;
    final before = edit.buffer.u8(at);
    final after = (before & 0xF9) | ((allegiance.code & 0x03) << 1);
    if (after == before) return false;
    edit.buffer.writeU8(at, after);
    edit.edits.add(ByteEdit(at, before, after));
    return true;
  }

  /// 改职业。
  bool setClass(PlacedUnit unit, int classId) =>
      _writeU8(unit.addr + 1, classId);

  /// 改队长。
  bool setLeader(PlacedUnit unit, int leaderId) =>
      _writeU8(unit.addr + 2, leaderId);

  /// 改第 [index] 个道具位（FE8 条目 20 字节在 `+12`，FE6/FE7 条目 16 字节在 `+8`）。
  bool setItem(PlacedUnit unit, int index, int itemId) {
    if (index < 0 || index > 3) return false;
    final base = _isFe8Table ? 12 : 8;
    return _writeU8(unit.addr + base + index, itemId);
  }

  bool _writeU8(int at, int value) {
    if (at < 0 || at >= _d.length) return false;
    final before = edit.buffer.u8(at);
    final after = value & 0xFF;
    if (before == after) return false;
    edit.buffer.writeU8(at, after);
    edit.edits.add(ByteEdit(at, before, after));
    return true;
  }

  /// 该入口为空时的说明。
  String emptyHint(UnitSlot slot) {
    if (slot.isEncounter) {
      return '该章没有遭遇战单位配置。'
          '\n有遭遇战的章节（如第 4/7/11 章）敌军就配在这组槽里；'
          '剧情中生成的敌人由事件脚本 `LOAD` 指令生成，不在此列表。';
    }
    if (slot.isFe6Units) {
      return '该章没有${slot.label}单位。';
    }
    return '该入口没有配置我方单位。';
  }
}
