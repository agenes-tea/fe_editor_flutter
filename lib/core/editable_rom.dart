import 'dart:typed_data';

import 'fe_rom.dart';
import 'rom_buffer.dart';
import 'rom_info.dart';

/// 可编辑字段的元数据。
class EditField {
  final String label;
  final int offset;
  final int min;
  final int max;

  const EditField(this.label, this.offset, {this.min = 0, this.max = 255});
}

/// 支持字段编辑的版本。
///
/// FE6（狼组汉化）与 FE8（日版/汉化）均已实测：字段偏移与 FE7 一致
/// （等级@11、属性@12..18、成长率@28..34），日汉两版逐字节对照无误。
bool versionSupportsEditing(String tableId) =>
    tableId == 'FE7J' || tableId == 'FE7U' || tableId == 'FE6' ||
    tableId == 'FE8J' || tableId == 'FE8U';

/// FE7 单位（角色）的数值字段。名字/文本字段不在其中——汉化版文本引擎
/// 不兼容，写入会破坏 ROM，等文本引擎确定后再做。
const unitEditableFields = <EditField>[
  EditField('等级', UnitOffsets.level, min: 1, max: 60),
  EditField('HP', UnitOffsets.baseHp),
  EditField('力量', UnitOffsets.baseStr),
  EditField('技巧', UnitOffsets.baseSkill),
  EditField('速度', UnitOffsets.baseSpeed),
  EditField('防御', UnitOffsets.baseDef),
  EditField('魔防', UnitOffsets.baseRes),
  EditField('幸运', UnitOffsets.baseLuck),
  EditField('HP成长', UnitOffsets.growHp, max: 100),
  EditField('力量成长', UnitOffsets.growStr, max: 100),
  EditField('技巧成长', UnitOffsets.growSkill, max: 100),
  EditField('速度成长', UnitOffsets.growSpeed, max: 100),
  EditField('防御成长', UnitOffsets.growDef, max: 100),
  EditField('魔防成长', UnitOffsets.growRes, max: 100),
  EditField('幸运成长', UnitOffsets.growLuck, max: 100),
];

/// FE7 职业的数值字段。
const classEditableFields = <EditField>[
  EditField('移动力', ClassOffsets.move, max: 15),
  EditField('体格', ClassOffsets.con, max: 25),
  EditField('HP', ClassOffsets.baseHp),
  EditField('力量', ClassOffsets.baseStr),
  EditField('技巧', ClassOffsets.baseSkill),
  EditField('速度', ClassOffsets.baseSpeed),
  EditField('防御', ClassOffsets.baseDef),
  EditField('魔防', ClassOffsets.baseRes),
  EditField('HP成长', ClassOffsets.growHp, max: 100),
  EditField('力量成长', ClassOffsets.growStr, max: 100),
  EditField('技巧成长', ClassOffsets.growSkill, max: 100),
  EditField('速度成长', ClassOffsets.growSpeed, max: 100),
  EditField('防御成长', ClassOffsets.growDef, max: 100),
  EditField('魔防成长', ClassOffsets.growRes, max: 100),
];

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
  final FeRom rom;
  final Uint8List original;
  late final RomBuffer buffer;

  final List<ByteEdit> edits = [];

  EditableRom._(this.rom, this.original) {
    buffer = RomBuffer(Uint8List.fromList(original));
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

  int classAddress(int index) => rom.classBase + index * rom.table.classDataSize;

  int itemAddress(int index) => rom.itemBase + rom.table.itemDataSize * index;

  /// 读字段当前值
  int readField(int baseAddr, EditField f) => buffer.u8(baseAddr + f.offset);

  /// 写字段；值超出范围会被夹紧。返回是否实际改变。
  bool writeField(int baseAddr, EditField f, int value) {
    final v = value.clamp(f.min, f.max);
    final addr = baseAddr + f.offset;
    if (!buffer.inRange(addr, 1)) return false;
    final before = buffer.u8(addr);
    if (before == v) return false;
    buffer.writeU8(addr, v);
    edits.add(ByteEdit(addr, before, v));
    return true;
  }

  /// 撤销所有修改，回到原始数据。
  void revertAll() {
    buffer.data.setAll(0, original);
    edits.clear();
  }

  /// 生成与原始 ROM 的完整对比数据（用于产出补丁/新 ROM）。
  Uint8List buildOutput() => Uint8List.fromList(buffer.data);
}
