import 'dart:typed_data';

import 'fe_rom.dart';
import 'item_catalog.dart';
import 'rom_buffer.dart';
import 'rom_info.dart';
import 'support.dart';

/// 可编辑字段的元数据。
class EditField {
  final String label;
  final int offset;
  final int min;
  final int max;

  /// 该字段的合法档位（非空时 ± 按档位跳，不走 ±1）。
  ///
  /// 武器熟练度就是这么存的：它不是「等级 1~7」，而是累计值
  /// （FE7/FE8：01/1F/47/79/B5/FB，FE6：01/33/65/97/C9/FB），
  /// 值不在档位上游戏内就显示成上一级。
  final List<int>? steps;

  /// 与 `steps` 一一对应的等级字母（用于在数值旁显示「D」）。
  final List<String>? stepLabels;

  /// 按**有符号**字节解释（sbyte）。
  ///
  /// 单位/职业的基础属性与体格都是这个语义：FE 里属性掉到负值
  /// （如被减益）就存成 0xFF，按无符号读会显示成 255。
  /// FEBuilderGBA 对应读取方式是 `(int)(sbyte)Program.ROM.u8(addr + N)`。
  final bool signed;

  /// 按**小端 u16** 读写（占 2 字节）。
  ///
  /// 道具表的「单价」就是这么存的（`/* 1A */ u16 costPerUse;`）——
  /// 按 u8 读写会截断低字节以外的部分，覇者の証 50000 会变 80。
  final bool u16;

  /// 按「两个半字节」读写：高半字节是最小值、低半字节是最大值。
  ///
  /// 道具表的射程码就是这个布局（`0x11`=射程1、`0x12`=1-2、`0x3F`=3-15），
  /// 只有合法组合才有意义，不能用普通数值编辑。
  final bool nibbles;

  /// `nibbles` 字段的合法取值（高 4 位 = 最小射程，低 4 位 = 最大射程）。
  final List<int>? nibbleValues;

  const EditField(
    this.label,
    this.offset, {
    this.min = 0,
    this.max = 255,
    this.steps,
    this.stepLabels,
    this.signed = false,
    this.u16 = false,
    this.nibbles = false,
    this.nibbleValues,
  });

  /// 该字段占几个字节。
  int get byteSize => u16 ? 2 : 1;

  /// `nibbles` 字段的合法取值（无定义时返回空表）。
  List<int> get allowedNibbles => nibbleValues ?? const [];

  /// 按「最小~最大」形式展示 nibble 值。
  static String formatNibble(int v) => '${(v >> 4) & 0xF}-${v & 0xF}';

  /// 当前值对应的档位标签（无档位定义时返回 null）。
  String? labelFor(int value) {
    final s = steps;
    final l = stepLabels;
    if (s == null || l == null) return null;
    var best = 0;
    for (var i = 0; i < s.length; i++) {
      if (value >= s[i]) best = i;
    }
    return l[best];
  }

  /// 上/下一个档位；`value` 不在档位上时取最近的合法档。
  int? stepUp(int value) {
    final s = steps;
    if (s == null) return null;
    for (final v in s) {
      if (v > value) return v;
    }
    return null;
  }

  int? stepDown(int value) {
    final s = steps;
    if (s == null) return null;
    for (var i = s.length - 1; i >= 0; i--) {
      if (s[i] < value) return s[i];
    }
    return null;
  }

  /// 输入框里给用户看的档位说明。
  String? get stepsHint {
    final s = steps;
    final l = stepLabels;
    if (s == null || l == null) return null;
    return [
      for (var i = 0; i < s.length; i++) '${l[i]}=${s[i]}',
    ].join('  ');
  }

  /// 输入框里给用户看的值域说明。
  String get rangeHint => u16
      ? '范围 $min ~ $max'
      : nibbles
          ? '合法射程码：${allowedNibbles.map(formatNibble).join('  ')}'
          : '范围 $min ~ $max';
}

/// 支持字段编辑的版本。
///
/// FE6（狼组汉化）与 FE8（日版/汉化）均已实测：字段偏移与 FE7 一致
/// （等级@11、属性@12..18、成长率@28..34），日汉两版逐字节对照无误。
bool versionSupportsEditing(String tableId) =>
    tableId == 'FE7J' ||
    tableId == 'FE7U' ||
    tableId == 'FE6' ||
    tableId == 'FE8J' ||
    tableId == 'FE8U';

/// 8 项武器熟练度字段（剑/枪/斧/弓/杖/理/光/暗）。
List<EditField> _weaponRankFields(int startOffset, {required bool fe6}) => [
      for (var i = 0; i < WeaponType.values.length; i++)
        EditField(
          '${WeaponType.values[i].label}熟练度',
          startOffset + i,
          steps: [
            for (final r in WeaponRank.values) r.valueFor(fe6: fe6),
          ],
          stepLabels: [
            for (final r in WeaponRank.values) r.label,
          ],
        ),
    ];

/// 基础属性/体格这类有符号字段的合理范围。
const _signedMin = -128;
const _signedMax = 127;

/// 单位（角色）的数值字段。名字/文本字段不在其中——汉化版文本引擎
/// 不兼容，写入会破坏 ROM，等文本引擎确定后再做。
///
/// 熟练度在 unit 表 +20..+27（FE6/FE7/FE8 同一位置）。
List<EditField> unitEditableFieldsFor({required bool fe6}) => [
      const EditField('等级', UnitOffsets.level, min: 1, max: 60),
      const EditField('HP', UnitOffsets.baseHp,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('力量', UnitOffsets.baseStr,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('技巧', UnitOffsets.baseSkill,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('速度', UnitOffsets.baseSpeed,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('防御', UnitOffsets.baseDef,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('魔防', UnitOffsets.baseRes,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('幸运', UnitOffsets.baseLuck,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('体格', UnitOffsets.con,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('HP成长', UnitOffsets.growHp, max: 255),
      const EditField('力量成长', UnitOffsets.growStr, max: 255),
      const EditField('技巧成长', UnitOffsets.growSkill, max: 255),
      const EditField('速度成长', UnitOffsets.growSpeed, max: 255),
      const EditField('防御成长', UnitOffsets.growDef, max: 255),
      const EditField('魔防成长', UnitOffsets.growRes, max: 255),
      const EditField('幸运成长', UnitOffsets.growLuck, max: 255),
      ..._weaponRankFields(UnitOffsets.swordRank, fe6: fe6),
    ];

/// 职业的数值字段。
///
/// 熟练度位置 **FE6 在 +40，FE7/FE8 在 +44**（见 `ClassOffsets.weaponRankOffset`）。
List<EditField> classEditableFieldsFor({required bool fe6}) => [
      const EditField('移动力', ClassOffsets.move, max: 15),
      const EditField('体格', ClassOffsets.con, max: 25),
      const EditField('HP', ClassOffsets.baseHp,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('力量', ClassOffsets.baseStr,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('技巧', ClassOffsets.baseSkill,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('速度', ClassOffsets.baseSpeed,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('防御', ClassOffsets.baseDef,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('魔防', ClassOffsets.baseRes,
          min: _signedMin, max: _signedMax, signed: true),
      // 能力上限（ClassData 0x13..0x19）。改高它才能突破职业自身的属性天花板，
      // 否则只改基础值在升级时仍会被压回去。
      const EditField('HP上限', ClassOffsets.maxHp,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('力量上限', ClassOffsets.maxStr,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('技巧上限', ClassOffsets.maxSkill,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('速度上限', ClassOffsets.maxSpeed,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('防御上限', ClassOffsets.maxDef,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('魔防上限', ClassOffsets.maxRes,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('体格上限', ClassOffsets.maxCon,
          min: _signedMin, max: _signedMax, signed: true),
      const EditField('HP成长', ClassOffsets.growHp, max: 255),
      const EditField('力量成长', ClassOffsets.growStr, max: 255),
      const EditField('技巧成长', ClassOffsets.growSkill, max: 255),
      const EditField('速度成长', ClassOffsets.growSpeed, max: 255),
      const EditField('防御成长', ClassOffsets.growDef, max: 255),
      const EditField('魔防成长', ClassOffsets.growRes, max: 255),
      // 转职加成（ClassData 0x22..0x27）：转职时额外获得的基础值。
      // 注意 0x25 与 flags2 同址，这里按数值用。
      const EditField('转职HP加成', ClassOffsets.promoHp, max: 100),
      const EditField('转职力量加成', ClassOffsets.promoStr, max: 100),
      const EditField('转职技巧加成', ClassOffsets.promoSkill, max: 100),
      const EditField('转职速度加成', ClassOffsets.promoSpeed, max: 100),
      const EditField('转职防御加成', ClassOffsets.promoDef, max: 100),
      const EditField('转职魔防加成', ClassOffsets.promoRes, max: 100),
      // 经验公式分母。改小 = 升级更快（1 = 原版 3 倍经验）。
      // 上限保持 5：原版最大值就是 5，再大没有意义。
      const EditField('经验分母', ClassOffsets.classRelativePower, min: 1, max: 5),
      ..._weaponRankFields(
        ClassOffsets.weaponRankOffset(fe6),
        fe6: fe6,
      ),
    ];

/// FE7/FE8 的单位字段（现有测试与调用方的便捷入口）。
final unitEditableFields = List<EditField>.unmodifiable(
  unitEditableFieldsFor(fe6: false),
);

/// 道具表的可编辑字段。
///
/// 布局 FE6/FE7/FE8 在 +7~+29 完全一致（条目大小不同但字段位置相同），
/// 见 `ItemOffsets` 与 `test/item_test.dart` 的逐条断言。
///
/// 单价是 **u16**（`bmitem.h` 的 `/* 1A */ u16 costPerUse;`），
/// 按 u8 写会把覇者の証的 50000 截成 80，所以这里用 `u16: true`。
/// 射程码是两个半字节（高=最小、低=最大），只能取游戏认识的 8 种组合，
/// 因此单独用 `nibbles` 而不是普通数值。
List<EditField> itemEditableFieldsFor({required bool fe6}) => [
      EditField('使用次数', ItemOffsets.durability, max: 255),
      EditField('威力', ItemOffsets.might, max: 255),
      EditField('命中', ItemOffsets.hit, max: 255),
      EditField('重量', ItemOffsets.weight, max: 255),
      EditField('必杀', ItemOffsets.crit, max: 255),
      const EditField(
        '射程',
        ItemOffsets.range,
        nibbles: true,
        nibbleValues: [
          0x00,
          0x10,
          0x11,
          0x12,
          0x13,
          0x22,
          0x23,
          0x3A,
          0x3F,
          0xFF
        ],
      ),
      const EditField('单价', ItemOffsets.unitPrice,
          min: 0, max: 65535, u16: true),
      EditField(
        '武器等级',
        ItemOffsets.weaponRank,
        steps: [
          for (final r in WeaponRank.values) r.valueFor(fe6: fe6),
        ],
        stepLabels: [
          for (final r in WeaponRank.values) r.label,
        ],
      ),
      EditField('图标 ID', ItemOffsets.iconId, max: 255),
    ];

/// 道具字段的便捷入口（FE7/FE8）。
final itemEditableFields = List<EditField>.unmodifiable(
  itemEditableFieldsFor(fe6: false),
);

/// FE7/FE8 的职业字段。
final classEditableFields = List<EditField>.unmodifiable(
  classEditableFieldsFor(fe6: false),
);

/// 一次字段修改记录，用于撤销与差异展示。
class ByteEdit {
  final int offset;
  final int before;
  final int after;

  const ByteEdit(this.offset, this.before, this.after);

  bool get changed => before != after;
}

/// 可写的 ROM 工作副本。
///
/// 所有写入都记录到 [edits]，既能撤销，也能据此生成 IPS/UPS 补丁。
class EditableRom {
  /// 打开时的**原始 ROM 快照**（供按特征定位的扫描逻辑用，如支援距离）。
  /// 名字/文本的实时显示请用 [liveRom]（它和 [buffer] 同一份数组）。
  final FeRom rom;
  final Uint8List original;
  late final RomBuffer buffer;
  late final SupportTable _support;

  /// 读**实时 buffer** 的 ROM 视图（与 [buffer] 同一份数组）。
  /// 文本/名字被修改后，页面靠它拿到最新值——不能拿 [rom]（那是原始快照，
  /// 改了名字仍显示旧值；同时扫描类逻辑必须用原始快照，两者分离）。
  late final FeRom liveRom = FeRom(buffer.data, rom.table);

  final List<ByteEdit> edits = [];

  EditableRom._(this.rom, this.original) {
    buffer = RomBuffer(Uint8List.fromList(original));
    _support = SupportTable(rom);
  }

  factory EditableRom.open(Uint8List data, RomTable table) {
    final copy = Uint8List.fromList(data);
    return EditableRom._(FeRom(copy, table), Uint8List.fromList(data));
  }

  /// 当前（可能已修改）的数据
  Uint8List get data => buffer.data;

  bool get hasChanges => edits.any((e) => e.changed);

  int get changedByteCount => edits.where((e) => e.changed).length;

  // ---------- 单位 ----------

  int unitAddress(int index) => rom.unitBase + index * rom.table.unitDataSize;

  int classAddress(int index) =>
      rom.classBase + index * rom.table.classDataSize;

  int itemAddress(int index) => rom.itemBase + rom.table.itemDataSize * index;

  /// 读字段当前值。
  ///
  /// `signed` 字段按 sbyte 解释（0xFF → -1），`u16` 按小端 16 位读。
  int readField(int baseAddr, EditField f) {
    if (f.u16) {
      final v = buffer.u16(baseAddr + f.offset);
      return v;
    }
    final raw = buffer.u8(baseAddr + f.offset);
    return f.signed && raw >= 0x80 ? raw - 0x100 : raw;
  }

  /// 写字段；值超出范围会被夹紧。返回是否实际改变。
  ///
  /// `u16` 字段写 2 字节，其它写 1 字节；同一个字节被不同字段占用时
  /// 后写的会覆盖先写的（射程码与它前后的字段不重叠，见 item 表布局）。
  bool writeField(int baseAddr, EditField f, int value) {
    if (f.nibbles) {
      // 必须落在合法射程码集合里，否则**拒绝写入**。
      // 静默夹紧到相邻合法值是危险的：调用方以为写成了 0x77，
      // 实际 ROM 里变成 0x00（该道具失去射程）。
      if (f.allowedNibbles.isEmpty) return false;
      if (!f.allowedNibbles.contains(value)) return false;
      final addr = baseAddr + f.offset;
      if (!buffer.inRange(addr, 1)) return false;
      final before = buffer.u8(addr);
      if (before == value) return false;
      buffer.writeU8(addr, value);
      edits.add(ByteEdit(addr, before, value));
      return true;
    }
    final v = value.clamp(f.min, f.max);
    final addr = baseAddr + f.offset;
    final size = f.byteSize;
    if (!buffer.inRange(addr, size)) return false;
    final before = size == 2 ? buffer.u16(addr) : buffer.u8(addr);
    final raw = v < 0 ? v + 0x100 : v;
    if (before == raw) return false;
    if (size == 2) {
      buffer.writeU16(addr, raw);
    } else {
      buffer.writeU8(addr, raw);
    }
    edits.add(ByteEdit(addr, before, raw));
    return true;
  }

  /// 整条指令写入（反汇编页用）：把 [bytes] 逐字节写进 [offset]。
  ///
  /// 与 [writeField] 不同，这里**不做值域夹紧**——机器码是任意位模式，
  /// 夹紧只会写坏指令。所有字节都记进 `edits`，可整体撤销。
  /// 返回实际改了几个字节（0 表示内容相同、未写入）。
  int writeInstruction(int offset, List<int> bytes) {
    if (offset < 0 || offset + bytes.length > buffer.length) return 0;
    var changed = 0;
    for (var i = 0; i < bytes.length; i++) {
      final at = offset + i;
      final before = buffer.u8(at);
      final after = bytes[i] & 0xFF;
      if (before == after) continue;
      buffer.writeU8(at, after);
      edits.add(ByteEdit(at, before, after));
      changed++;
    }
    return changed;
  }

  /// 从 [offset] 起逐字节写入 [bytes]（文本等任意数据用，不做值域夹紧）。
  /// 与 [writeInstruction] 同等语义，仅命名更贴切。
  /// 返回实际改了几个字节（0 表示内容相同、未写入）。
  int writeBytes(int offset, List<int> bytes) =>
      writeInstruction(offset, bytes);

  /// 设置 u32 字段里的某一个标志位（只改这一位，其余位原样保留）。
  ///
  /// 道具表的 `attributes` 是 4 字节标志位，bit8 以上还有逆转武器三角、
  /// 无视防御等含义——按字节整块覆盖会把它们一起抹掉，所以只能按位改。
  /// 返回是否实际改变。
  bool writeFlagBit(int addr, int bit, bool on) {
    if (bit < 0 || bit > 31) return false;
    if (!buffer.inRange(addr, 4)) return false;
    final before = buffer.u32(addr);
    final mask = 1 << bit;
    final after = on ? (before | mask) : (before & ~mask);
    if (after == before) return false;
    buffer.writeU32(addr, after);
    edits.add(ByteEdit(addr, before, after));
    return true;
  }

  /// 撤销所有修改，回到原始数据。
  void revertAll() {
    buffer.data.setAll(0, original);
    edits.clear();
  }

  // ---------- 支援 ----------

  /// 支援数据的基址（`SupportData` 起点），没有支援数据返回 -1。
  int supportAddress(int unitIndex) => _support.addressOf(unitIndex);

  /// 读支援槽位的当前值。
  ///
  /// [kind] 决定读哪一组：'partner' 角色 ID、'base' 初始支援值、
  /// 'growth' 每回合增长。槽位越界返回 -1。
  int readSupport(int unitIndex, int slot, SupportPart kind) {
    final base = supportAddress(unitIndex);
    if (base < 0 || slot < 0 || slot >= SupportTable.maxPartners) return -1;
    final at = base +
        switch (kind) {
          SupportPart.partner => SupportTable.partnerOffset(slot),
          SupportPart.base => SupportTable.baseOffset(slot),
          SupportPart.growth => SupportTable.growthOffset(slot),
        };
    return buffer.u8(at);
  }

  /// 写支援槽位。
  ///
  /// 角色 ID 夹紧到 `1 ~ 单位表条目数`（FE 的角色 ID 从 1 起，
  /// 且不能超过表内实际条目数），数值类夹紧到 0~255。
  bool writeSupport(int unitIndex, int slot, SupportPart kind, int value) {
    final base = supportAddress(unitIndex);
    if (base < 0 || slot < 0 || slot >= SupportTable.maxPartners) return false;
    final at = base +
        switch (kind) {
          SupportPart.partner => SupportTable.partnerOffset(slot),
          SupportPart.base => SupportTable.baseOffset(slot),
          SupportPart.growth => SupportTable.growthOffset(slot),
        };
    if (!buffer.inRange(at, 1)) return false;
    final before = buffer.u8(at);
    final v = switch (kind) {
      // 角色 ID：1 起，上界是单位表条目数（表内偏移恒等于 ID）
      SupportPart.partner => value.clamp(1, rom.unitCount),
      _ => value.clamp(0, 255),
    };
    if (before == v) return false;
    buffer.writeU8(at, v);
    edits.add(ByteEdit(at, before, v));
    return true;
  }

  /// 生成与原始 ROM 的完整对比数据（用于产出补丁/新 ROM）。
  Uint8List buildOutput() => Uint8List.fromList(buffer.data);
}
