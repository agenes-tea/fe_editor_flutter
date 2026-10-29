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

  /// 战斗动画表指针槽（GBA 地址形式，需解一次引用）。0 表示该版本无此表。
  final int battleAnimPointerSlot;

  /// 战斗动画表条目大小，五个版本都是 32 字节。
  final int battleAnimDataSize;

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
    this.battleAnimPointerSlot = 0,
    this.battleAnimDataSize = 0,
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
  battleAnimPointerSlot: 0x4B0F8,
  battleAnimDataSize: 32,
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
  battleAnimPointerSlot: 0x0549DC,
  battleAnimDataSize: 32,
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
  battleAnimPointerSlot: 0x0541F4,
  battleAnimDataSize: 32,
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
  battleAnimPointerSlot: 0x05A97C,
  battleAnimDataSize: 32,
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
  battleAnimPointerSlot: 0x059BD8,
  battleAnimDataSize: 32,
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

  /// 体格（u8，有符号读）。
  ///
  /// 实测 FE7J 取值 0..4（少数条目是 253/255，即 -3/-1 的奖励值），
  /// 是相对职业体格的增减量，不是角色体格的绝对值。
  static const con = 19;

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

  /// 属性（Affinity，0x00 无 / 0x01 炎 / 0x02 雷 / 0x03 风 / 0x04 冰 /
  /// 0x05 闇 / 0x06 光 / 0x07 理）。
  ///
  /// 反编译 `CharacterData` 里是 `/* 09 */ u8 affinity;`。
  /// **注意不是 +0x28**：`0x28` 是 4 字节的 `attributes` 标志位，
  /// 按单字节读永远是 0（FE7J 全 253 条实测）。
  static const affinity = 9;

  /// 图鉴排序序号（`CharacterData::sort_order`，`/* 0A */`）。
  ///
  /// 0 表示「不出现在图鉴列表」——FE8 里占位条目（对战对手）
  /// 和敌方 NPC 都是 0，玩家角色从 1 起编号。
  /// 但注意：敌方主要角色也有非 0 值（实测 FE8 列表占 34..43），
  /// 所以它只能当「候选范围」而不是「我方角色」的判据。
  static const sortOrder = 10;

  /// 4 字节标志位（已识别地）：bit0 移动后可再行动、bit1 再行动（跳舞）等。
  static const attributes = 40;

  static const supportPointer = 44;
  static const talkGroup = 48;

  /// 武器熟练度（8 项连续：剑/枪/斧/弓/杖/理/光/暗），FE6/FE7/FE8 同一位置。
  static const weaponRanks = <int>[
    swordRank,
    lanceRank,
    axeRank,
    bowRank,
    staffRank,
    animaRank,
    lightRank,
    darkRank,
  ];
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

  /// 体格（u8）。实测 FE7J：领主 7、重骑士 13、剑士 8。
  static const con = 17;

  /// 移动力（u8）。实测 FE7J：领主 5、利基亚骑士 7、重骑士 4。
  ///
  /// **不要与 `+7` 的「移动速度」搞混**：`+7` 只允许 0/1，
  /// 2 以上会让地图上的移动动画画错（`ClassForm.MakeCheckError` 专门检查这一点）。
  static const move = 18;

  // ---------- 能力上限（0x13..0x19，共 7 项，有符号）----------
  // 反编译：`/* 13 */ s8 maxHP;` 起。之前界面没暴露这些字段。
  static const maxHp = 19;
  static const maxStr = 20;
  static const maxSkill = 21;
  static const maxSpeed = 22;
  static const maxDef = 23;
  static const maxRes = 24;
  static const maxCon = 25;

  static const growHp = 27;
  static const growStr = 28;
  static const growSkill = 29;
  static const growSpeed = 30;
  static const growDef = 31;
  static const growRes = 32;
  static const growLuck = 33;

  // ---------- 转职加成（0x22..0x27，共 6 项）----------
  static const promoHp = 34;
  static const promoStr = 35;
  static const promoSkill = 36;
  static const promoSpeed = 37;
  static const promoDef = 38;
  static const promoRes = 39;

  /// 经验公式的分母（反编译 `ClassData::classRelativePower`，`/* 1A */`）。
  ///
  /// `GetUnitRoundExp()`：`(31 - 等级差) / classRelativePower`。
  /// 原版多数职业为 3（FE8 实测 86/100），改成 1 即三倍经验。
  /// **三个版本都在 +0x1A**：FE6 的职业表布局特殊（JInfo，条目 72 字节），
  /// 但 `power_level` 同样在 0x1A（fireemblem6j `include/unit.h` 实读确认）。
  static const classRelativePower = 0x1A;

  /// 特性标志位。反编译里 `attributes` 在 0x28，而 FE7/FE8 实际把
  /// 飞行 / 上位职业 / 可出击这些标志存在 **+37（特性2）与 +41（特性3）**。
  ///
  /// 注意 `+37` 同时也是 `promotionSpd` 的字节位（0x25）—— 这两个常量
  /// 指向同一字节但语义不同，别混用。标志位**不是数值字段**：
  /// 早期版本把 +37 当移动力、+41 当体格读，界面上就出现 0、1、37 这类异常值
  /// （`ClassForm.cs` 用 `addr+41` 读标志位可证）。
  static const flags2 = 37;
  static const flags3 = 41;

  /// 特性标志位（**u32**，+40=0x28）：CA_* 全枚举（`bmunit.h`，三作同表），
  /// 逐位定义见 `class_flags.dart` 的 [ClassFlags]。
  /// 与 `flags2`/`flags3` 是同一区域的两种视角（字节对 vs u32），语义以 CA_* 为准。
  static const attributes = 40;

  static const swordRank = 44;

  /// 8 项武器熟练度的起始偏移。
  ///
  /// **FE6 的职业条目只有 72 字节，熟练度在 +40**（FEBuilderGBA
  /// `ClassFE6Form.GetWeaponLevel` 读 +40..+47）；FE7/FE8 是 +44..+51
  /// （`ClassForm` 的 `L_44_WEAPON` 起）。搞混会读到别的字段。
  static int weaponRankOffset(bool isFe6) => isFe6 ? 40 : swordRank;
}

class ItemOffsets {
  static const nameTextId = 0;
  static const descTextId = 2;

  /// item ID（u8），从 0 开始连续递增（ID 0 是空槽）。
  static const itemId = 6;

  /// 种类（u8）：00=剣 01=槍 02=斧 03=弓 04=杖 05=理 06=光 07=闇…
  static const kind = 7;

  /// attributes 标志位（**u32**），位含义见 `ItemFlags`。
  static const attributes = 8;

  /// 数值加成表指针（12 字节）。
  static const statBonusPointer = 12;

  /// 克制职业 ID 列表指针（该武器对这些职业有额外伤害，非装备限制）。
  static const usableClassPointer = 16;

  /// 使用次数 / 耐久（u8）。
  static const durability = 20;

  /// 威力（u8）。
  static const might = 21;

  /// 命中（u8）。
  static const hit = 22;

  /// 重量（u8）。
  static const weight = 23;

  /// 必杀（u8）。
  static const crit = 24;

  /// 射程码（u8，两个半字节：高=最小射程，低=最大射程）。
  static const range = 25;

  /// 单价（**u16**）。
  static const unitPrice = 26;

  /// 武器等级熟练度累计值（u8）。
  static const weaponRank = 28;

  /// 图标 ID（u8）。
  static const iconId = 29;

  /// 使用效果 ID（u8，+30，`bmitem.h` useEffectId）：0=无，非 0 为使用效果表下标
  ///（伤药 / 复活 / 强化等，无名字表，按原样显示数字）。
  static const useEffect = 30;

  /// 武器特效（u8，+31，`bmitem.h` weaponEffectId）：0 无 / 1 毒 / 2 吸血 / 3 减半 /
  /// 4 魔剑（FE8 多 5 石化）。
  static const weaponEffect = 31;

  /// 使用武器获得的经验（u8，+32，`bmitem.h` weaponExp）。
  ///
  /// FE6 条目只有 32 字节，读到这个字段会越进下一条；`ItemCatalog.entryAt`
  /// 对 FE6 置 0。
  static const weaponExp = 32;
}
