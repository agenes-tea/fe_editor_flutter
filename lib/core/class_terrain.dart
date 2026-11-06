import 'editable_rom.dart';
import 'fe_rom.dart';

/// 职业的地形相关表：**移动消耗**与**地形修正**（回避 / 防御 / 魔防）。
///
/// 这些表在 `ClassData` 里存的是**指针**，同一张表常被多个职业共享
/// （实测 FE8J 领主与佣兵的移动消耗表都指向 `0x0885FD60`），
/// 所以改一处会影响所有共享该表的职业。这是游戏本来的数据组织方式，
/// 界面上要让用户看到，不能悄悄改。
///
/// ## 偏移来源（`fireemblem8u` 的 `include/bmunit.h`，权威反编译）
/// ```
/// /* 38 */ const s8 * pMovCostTable[3];      // standard, rain, snow
/// /* 44 */ const s8 * pTerrainAvoidLookup;
/// /* 48 */ const s8 * pTerrainDefenseLookup;
/// /* 4C */ const s8 * pTerrainResistanceLookup;
/// ```
/// 本文件用**十进制字节偏移**（与 [ClassOffsets] 一致），即 56/60/64 与 68/72/76。
///
/// **FE6 的职业条目只有 72 字节**，装不下 `pBattleAnimDef` 之后那一串：
/// 实测 FE6J 是 `+52` 移动消耗、`+56/60/64` 三张地形修正，没有雨/雪的
/// 第二三张移动表。差异按**条目大小**判定，不按作品名硬写。
///
/// ## 表长度
/// 地形修正表实测 **65 项**（FE8J 三张表间距正好 65 字节，地形名表条目数也是 65）。
/// 移动消耗表的实际数组更长，但索引范围同样是地形 ID，统一按 65 项展示与写入。
class ClassTerrain {
  final EditableRom edit;

  ClassTerrain(this.edit);

  FeRom get rom => edit.liveRom;
  bool get isFe6 => rom.table.classDataSize == 72;

  /// 地形 ID 的展示上限（含）。
  static const terrainCount = 65;

  /// 移动消耗表的指针槽偏移：FE7/FE8 三张（晴/雨/雪），FE6 一张。
  List<int> get movCostOffsets => isFe6 ? const [52] : const [56, 60, 64];

  /// 三张地形修正表的指针槽偏移：回避 / 防御 / 魔防。
  List<int> get lookupOffsets => isFe6 ? const [56, 60, 64] : const [68, 72, 76];

  static const movCostLabels = ['移动消耗（晴）', '移动消耗（雨）', '移动消耗（雪）'];
  static const lookupLabels = ['地形回避', '地形防御', '地形魔防'];

  /// 该职业某指针槽指向的文件偏移；不是合法指针时返回 -1。
  int pointerTarget(int classId, int slotOffset) {
    final at = _entryOffset(classId);
    if (at < 0) return -1;
    return rom.pointerAt(at + slotOffset);
  }

  int _entryOffset(int classId) {
    final base = rom.classBase;
    if (base < 0 || classId < 0 || classId >= rom.classCount) return -1;
    return base + classId * rom.table.classDataSize;
  }

  /// 读某项（0 基地形 ID）；取不到返回 null。
  ///
  /// 值是 **s8**：`-1` 表示该地形不可通行（移动消耗）或没有修正。
  int? valueAt(int classId, int slotOffset, int terrainId) {
    if (terrainId < 0 || terrainId > terrainCount) return null;
    final at = pointerTarget(classId, slotOffset);
    if (at < 0 || at + terrainId >= rom.length) return null;
    final raw = FeRom.u8(rom.data, at + terrainId);
    return raw >= 128 ? raw - 256 : raw;
  }

  /// 改某项，返回 1（已写）/ 0（值相同）/ -1（不可写）。
  ///
  /// **原地覆盖，不搬表**：同一张表被多个职业共享，搬家会让别的职业指向旧地址。
  int setValue(int classId, int slotOffset, int terrainId, int value) {
    if (terrainId < 0 || terrainId > terrainCount) return -1;
    final at = pointerTarget(classId, slotOffset);
    if (at < 0 || at + terrainId >= edit.buffer.length) return -1;
    final v = value & 0xFF;
    final before = edit.buffer.u8(at + terrainId);
    if (before == v) return 0;
    edit.buffer.writeU8(at + terrainId, v);
    edit.edits.add(ByteEdit(at + terrainId, before, v));
    return 1;
  }

  /// 共享同一张表的其它职业索引（不含自己）。用于界面提示影响面。
  List<int> sharersOf(int classId, int slotOffset) {
    final mine = pointerTarget(classId, slotOffset);
    if (mine < 0) return const [];
    final out = <int>[];
    for (var i = 0; i < rom.classCount; i++) {
      if (i == classId) continue;
      if (pointerTarget(i, slotOffset) == mine) out.add(i);
    }
    return out;
  }
}
