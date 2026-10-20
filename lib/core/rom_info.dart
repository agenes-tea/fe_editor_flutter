/// FE6/FE7/FE8 ROM 的地址表。
///
/// 数值来源：FEBuilderGBA（GPL-3.0）的 ROMFE6JP / ROMFE7JP / ROMFE7U /
/// ROMFE8JP / ROMFE8U.cs 偏移表，仅作数据参考，实现为本项目独立重写。
library;

class RomTable {
  final String id;
  final String name;
  final bool multibyte;

  /// 指针槽地址（不是数据本身，需要读 u32 再转成文件偏移）
  final int textPointerSlot;
  final int textRecoverAddress;
  final int unitPointerSlot;
  final int unitMaxCount;
  final int unitDataSize;
  final int classPointerSlot;
  final int classDataSize;
  final int itemPointerSlot;
  final int itemDataSize;
  final int maskPointerSlot;
  final int maskPointBaseSlot;

  /// 肖像表指针槽（GBA 地址形式，需解一次引用）。0 表示该版本无肖像表。
  final int portraitPointerSlot;

  /// 肖像表条目大小：FE7/FE8 = 28，FE6 = 16。
  final int portraitDataSize;

  const RomTable({
    required this.id,
    required this.name,
    required this.multibyte,
    required this.textPointerSlot,
    required this.textRecoverAddress,
    required this.unitPointerSlot,
    required this.unitMaxCount,
    required this.unitDataSize,
    required this.classPointerSlot,
    required this.classDataSize,
    required this.itemPointerSlot,
    required this.itemDataSize,
    required this.maskPointerSlot,
    required this.maskPointBaseSlot,
    this.portraitPointerSlot = 0,
    this.portraitDataSize = 0,
  });

  /// 肖像表条目内的指针字段偏移（用于基址探测）。
  ///
  /// FE7/FE8 的 28 字节条目有 5 个指针（正脸 / 地图脸 / 调色板 / 嘴型 / 职业卡），
  /// FE6 的 16 字节条目只有 3 个。
  List<int> get portraitPointerFields =>
      portraitDataSize == 16 ? const [0, 4, 8] : const [0, 4, 8, 12, 16];
}

const fe6Jp = RomTable(
  id: 'FE6',
  name: '封印之剑 (JP)',
  multibyte: true,
  textPointerSlot: 0x13B10,
  textRecoverAddress: 0xF635C,
  unitPointerSlot: 0x17680,
  unitMaxCount: 226,
  unitDataSize: 48,
  classPointerSlot: 0x176E0,
  classDataSize: 72,
  itemPointerSlot: 0x16410,
  itemDataSize: 32,
  maskPointerSlot: 0x6E0,
  maskPointBaseSlot: 0x6DC,
  portraitPointerSlot: 0x7FD8,
  portraitDataSize: 16,
);

const fe7Jp = RomTable(
  id: 'FE7J',
  name: '烈火之剑 (JP)',
  multibyte: true,
  textPointerSlot: 0x13370,
  textRecoverAddress: 0xBBB370,
  unitPointerSlot: 0x09AC50,
  unitMaxCount: 253,
  unitDataSize: 52,
  classPointerSlot: 0x017CE0,
  classDataSize: 84,
  itemPointerSlot: 0x164DC,
  itemDataSize: 36,
  maskPointerSlot: 0x6E0,
  maskPointBaseSlot: 0x6DC,
  portraitPointerSlot: 0x0069C0,
  portraitDataSize: 28,
);

const fe7Us = RomTable(
  id: 'FE7U',
  name: '烈火之剑 (US)',
  multibyte: false,
  textPointerSlot: 0x12CB8,
  textRecoverAddress: 0xB808AC,
  unitPointerSlot: 0x9A274,
  unitMaxCount: 253,
  unitDataSize: 52,
  classPointerSlot: 0x178F0,
  classDataSize: 84,
  itemPointerSlot: 0x174D4,
  itemDataSize: 36,
  maskPointerSlot: 0x6BC,
  maskPointBaseSlot: 0x6B8,
  portraitPointerSlot: 0x006B30,
  portraitDataSize: 28,
);

const fe8Jp = RomTable(
  id: 'FE8J',
  name: '圣魔之光石 (JP)',
  multibyte: true,
  textPointerSlot: 0x00A000,
  textRecoverAddress: 0x14D08C,
  unitPointerSlot: 0x010650,
  unitMaxCount: 255,
  unitDataSize: 52,
  classPointerSlot: 0x017860,
  classDataSize: 84,
  itemPointerSlot: 0x17568,
  itemDataSize: 36,
  maskPointerSlot: 0x6E0,
  maskPointBaseSlot: 0x6DC,
  portraitPointerSlot: 0x00542C,
  portraitDataSize: 28,
);

const fe8Us = RomTable(
  id: 'FE8U',
  name: '圣魔之光石 (US)',
  multibyte: false,
  textPointerSlot: 0x00A2A0,
  textRecoverAddress: 0x15D48C,
  unitPointerSlot: 0x10108,
  unitMaxCount: 255,
  unitDataSize: 52,
  classPointerSlot: 0x017AB8,
  classDataSize: 84,
  itemPointerSlot: 0x177C0,
  itemDataSize: 36,
  maskPointerSlot: 0x6E0,
  maskPointBaseSlot: 0x6DC,
  portraitPointerSlot: 0x005524,
  portraitDataSize: 28,
);

/// FE7 的 unit/class 结构字段偏移（相对条目基址）。
/// 来源：FEBuilderGBA UnitForm.cs / ClassForm.cs 的 addr+N 用法。
class UnitOffsets {
  static const nameTextId = 0;
  static const descTextId = 2;

  /// unit ID（u8），从 1 开始连续递增。
  static const unitId = 4;

  /// 肖像 ID（u16）。FE6/FE7/FE8 都在 +6。
  static const portraitId = 6;
  static const level = 11;
  static const baseHp = 12;
  static const baseStr = 13;
  static const baseSkill = 14;
  static const baseSpeed = 15;
  static const baseDef = 16;
  static const baseRes = 17;
  static const baseLuck = 18;
  static const swordRank = 20;
  static const lanceRank = 21;
  static const axeRank = 22;
  static const bowRank = 23;
  static const staffRank = 24;
  static const animaRank = 25;
  static const lightRank = 26;
  static const darkRank = 27;
  static const growHp = 28;
  static const growStr = 29;
  static const growSkill = 30;
  static const growSpeed = 31;
  static const growDef = 32;
  static const growRes = 33;
  static const growLuck = 34;
  static const affinity = 40;
  static const supportPointer = 44;
  static const talkGroup = 48;
}

class ClassOffsets {
  static const nameTextId = 0;
  static const descTextId = 2;

  /// class number（u8），从 1 开始连续递增。
  static const classNumber = 4;
  static const promotionClass = 5;
  static const moveIcon = 6;

  /// 职业卡肖像 ID（u16）。FE6/FE7/FE8 都在 +8。
  static const portraitId = 8;
  static const baseHp = 11;
  static const baseStr = 12;
  static const baseSkill = 13;
  static const baseSpeed = 14;
  static const baseDef = 15;
  static const baseRes = 16;
  static const growHp = 27;
  static const growStr = 28;
  static const growSkill = 29;
  static const growSpeed = 30;
  static const growDef = 31;
  static const growRes = 32;
  static const growLuck = 33;
  static const move = 37;
  static const con = 41;
  static const swordRank = 44;
}

class ItemOffsets {
  static const nameTextId = 0;
  static const descTextId = 2;

  /// item ID（u8），从 0 开始连续递增（ID 0 是空槽）。
  static const itemId = 6;

  static const iconId = 29;
}
