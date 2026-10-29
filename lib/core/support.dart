import 'fe_rom.dart';
import 'rom_info.dart';

/// 属性（Affinity）枚举。
///
/// 存在角色表 `+9`（`CharacterData::affinity`），不是 `+0x28`——
/// `+0x28` 是 4 字节的 `attributes` 标志位，按单字节读永远是 0。
enum Affinity {
  none(0x00, '—'),
  fire(0x01, '炎'),
  thunder(0x02, '雷'),
  wind(0x03, '风'),
  ice(0x04, '冰'),
  dark(0x05, '闇'),
  light(0x06, '光'),
  anima(0x07, '理');

  final int raw;
  final String label;

  const Affinity(this.raw, this.label);

  static Affinity fromRaw(int v) {
    for (final a in Affinity.values) {
      if (a.raw == v) return a;
    }
    return Affinity.none;
  }
}

/// 一次支援关系（角色表 `+0x2C` 指向的 `SupportData`）。
///
/// 结构照 FireEmblemUniverse/fireemblem8u 的 `struct SupportData`
/// （`include/bmreliance.h`），7 字节角色 ID + 7 字节初始值 + 7 字节每回合增长 + 计数：
///
/// ```c
/// u8 characters[7];       // 00
/// u8 supportExpBase[7];   // 07
/// u8 supportExpGrowth[7]; // 0E
/// u8 supportCount;        // 15
/// ```
///
/// 已在 FE6/FE7J/FE7U/FE8J 上逐字节核对（FE8 的艾瑞珂 7 个对象与
/// `SupportData_Eirika` 的 `characters` / `supportExpBase` 完全一致）。
class SupportRelation {
  final int charId;
  final int baseExp;
  final int growth;

  const SupportRelation(this.charId, this.baseExp, this.growth);
}

/// `SupportData` 里可编辑的三组数组。
enum SupportPart {
  /// 支援对象的角色 ID（`characters[i]`）。
  partner,

  /// 初始支援值（`supportExpBase[i]`）。
  base,

  /// 每回合支援增长（`supportExpGrowth[i]`）。
  growth;

  String get label => switch (this) {
        SupportPart.partner => '对象',
        SupportPart.base => '初始值',
        SupportPart.growth => '每回合增长',
      };
}

class SupportTable {
  final FeRom rom;
  const SupportTable(this.rom);

  static const entrySize = 0x16;
  static const maxPartners = 7;

  /// 支援数据的绝对地址（文件偏移）；没有支援数据返回 -1。
  int addressOf(int unitIndex) {
    final base = rom.unitBase;
    if (base < 0) return -1;
    final at = base + unitIndex * rom.table.unitDataSize;
    if (at + UnitOffsets.supportPointer + 4 > rom.length) return -1;
    final p = FeRom.u32(rom.data, at + UnitOffsets.supportPointer);
    if (p == 0 || !FeRom.isPointer(p, rom.length)) return -1;
    final off = p & 0x1FFFFFF;
    if (off + entrySize > rom.length) return -1;
    return off;
  }

  /// 该角色实际配对的支援数（`SupportData::supportCount`）。
  int countOf(int unitIndex) {
    final off = addressOf(unitIndex);
    if (off < 0) return 0;
    final n = rom.data[off + 0x15];
    return n <= maxPartners ? n : maxPartners;
  }

  /// 读单位表第 [unitIndex] 条的支援关系；没有支援数据返回空表。
  List<SupportRelation> relationsOf(int unitIndex) {
    final off = addressOf(unitIndex);
    if (off < 0) return const [];
    final n = countOf(unitIndex);
    return [
      for (var i = 0; i < n; i++)
        SupportRelation(
          rom.data[off + i],
          rom.data[off + 0x07 + i],
          rom.data[off + 0x0E + i],
        ),
    ];
  }

  /// 支援对象的角色 ID 在 `SupportData` 里的偏移。
  static int partnerOffset(int slot) => slot;

  /// 初始支援值（`supportExpBase[i]`）的偏移。
  static int baseOffset(int slot) => 0x07 + slot;

  /// 每回合支援增长（`supportExpGrowth[i]`）的偏移。
  static int growthOffset(int slot) => 0x0E + slot;

  /// 支援对象角色 ID 的合法范围。
  ///
  /// FE 的角色 ID 从 1 起（0 是「无角色」），上界取单位表条目数。
  int get maxCharId => rom.unitCount + 1;

  /// 属性（`+9`）。越界或表未识别时返回 [Affinity.none]。
  Affinity affinityOf(int unitIndex) {
    final base = rom.unitBase;
    if (base < 0) return Affinity.none;
    final at = base + unitIndex * rom.table.unitDataSize + UnitOffsets.affinity;
    if (at >= rom.length) return Affinity.none;
    return Affinity.fromRaw(rom.data[at]);
  }

  /// 支援对象的名字（按角色表 ID 反查）。
  String nameOf(int charId) {
    final n = rom.unitDisplayName(charId - 1).trim();
    return n.isEmpty ? '角色 $charId' : n;
  }
}
