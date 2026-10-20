import 'dart:typed_data';

import 'rom_info.dart';
import 'rom_probe.dart';

/// 版本档案：描述一个 FE 原版/改版的表布局。
///
/// 档案里的槽地址来自 FEBuilderGBA 的 `ROMFE6JP` / `ROMFE7JP` / `ROMFE7U` /
/// `ROMFE8JP` / `ROMFE8U.cs`（GPL-3.0，7743 著）。
///
/// 关键设计：**识别不只看 game code**。改版常常改掉 code（如 BE8E），
/// 所以还要用「哪个档案的指针槽在 ROM 里全部有效」来反推版本。
class RomProfile {
  final String id;
  final String name;
  final bool multibyte;

  /// 指针槽地址（GBA 地址形式，槽里存的是指向数据的指针）。
  final int textPointerSlot;
  final int unitPointerSlot;
  final int classPointerSlot;
  final int itemPointerSlot;
  final int portraitPointerSlot;
  final int maskPointerSlot;
  final int maskPointBaseSlot;

  final int unitMaxCount;
  final int unitDataSize;
  final int classDataSize;
  final int itemDataSize;
  final int portraitDataSize;

  /// 识别时用来打分的槽（顺序即权重）。
  ///
  /// 肖像表对多数改版都有效（改版很少动它），所以权重高。
  final List<int> signatureSlots;

  /// 各表的指针字段偏移，用于基址探测。
  static const List<int> portraitPtrFields = [0, 4, 8, 12, 16];
  static const List<int> fe6PortraitPtrFields = [0, 4, 8];
  static const List<int> unitPtrFields = [44];
  static const List<int> classPtrFields = [56];
  static const List<int> itemPtrFields = [12, 16];

  const RomProfile({
    required this.id,
    required this.name,
    required this.multibyte,
    required this.textPointerSlot,
    required this.unitPointerSlot,
    required this.classPointerSlot,
    required this.itemPointerSlot,
    required this.portraitPointerSlot,
    required this.maskPointerSlot,
    required this.maskPointBaseSlot,
    required this.unitMaxCount,
    required this.unitDataSize,
    required this.classDataSize,
    required this.itemDataSize,
    required this.portraitDataSize,
    required this.signatureSlots,
  });

  /// 肖像表的指针字段（FE6 是 16 字节条目，只有 3 个指针）。
  List<int> get portraitPointerFields =>
      portraitDataSize == 16 ? fe6PortraitPtrFields : portraitPtrFields;

  /// 转成旧的 [RomTable]（供现有代码使用）。
  RomTable toRomTable() => RomTable(
        id: id,
        name: name,
        multibyte: multibyte,
        textPointerSlot: textPointerSlot,
        textRecoverAddress: 0,
        unitPointerSlot: unitPointerSlot,
        unitMaxCount: unitMaxCount,
        unitDataSize: unitDataSize,
        classPointerSlot: classPointerSlot,
        classDataSize: classDataSize,
        itemPointerSlot: itemPointerSlot,
        itemDataSize: itemDataSize,
        maskPointerSlot: maskPointerSlot,
        maskPointBaseSlot: maskPointBaseSlot,
        portraitPointerSlot: portraitPointerSlot,
        portraitDataSize: portraitDataSize,
      );

  /// 该档案在 ROM 里的**结构匹配度**：所有特征槽都必须是有效指针。
  ///
  /// 全部有效 = 1.0；一个都不匹配 = 0.0。
  double structureScore(RomProbe probe) {
    if (signatureSlots.isEmpty) return 0;
    var ok = 0;
    for (final slot in signatureSlots) {
      final v = probe.u32(slot);
      if (RomProbe.isPointer(v)) ok++;
    }
    return ok / signatureSlots.length;
  }
}

/// 全部已知档案。
const romProfiles = <RomProfile>[
  RomProfile(
    id: 'FE6',
    name: '封印之剑 (JP)',
    multibyte: true,
    textPointerSlot: 0x13B10,
    unitPointerSlot: 0x17680,
    classPointerSlot: 0x176E0,
    itemPointerSlot: 0x16410,
    portraitPointerSlot: 0x7FD8,
    maskPointerSlot: 0x6E0,
    maskPointBaseSlot: 0x6DC,
    unitMaxCount: 226,
    unitDataSize: 48,
    classDataSize: 72,
    itemDataSize: 32,
    portraitDataSize: 16,
    signatureSlots: [0x7FD8, 0x17680, 0x176E0, 0x16410],
  ),
  RomProfile(
    id: 'FE7J',
    name: '烈火之剑 (JP)',
    multibyte: true,
    textPointerSlot: 0x13370,
    unitPointerSlot: 0x09AC50,
    classPointerSlot: 0x017CE0,
    itemPointerSlot: 0x164DC,
    portraitPointerSlot: 0x0069C0,
    maskPointerSlot: 0x6E0,
    maskPointBaseSlot: 0x6DC,
    unitMaxCount: 253,
    unitDataSize: 52,
    classDataSize: 84,
    itemDataSize: 36,
    portraitDataSize: 28,
    signatureSlots: [0x0069C0, 0x09AC50, 0x017CE0, 0x164DC],
  ),
  RomProfile(
    id: 'FE7U',
    name: '烈火之剑 (US)',
    multibyte: false,
    textPointerSlot: 0x12CB8,
    unitPointerSlot: 0x9A274,
    classPointerSlot: 0x178F0,
    itemPointerSlot: 0x174D4,
    portraitPointerSlot: 0x006B30,
    maskPointerSlot: 0x6BC,
    maskPointBaseSlot: 0x6B8,
    unitMaxCount: 253,
    unitDataSize: 52,
    classDataSize: 84,
    itemDataSize: 36,
    portraitDataSize: 28,
    signatureSlots: [0x006B30, 0x9A274, 0x178F0, 0x174D4],
  ),
  RomProfile(
    id: 'FE8J',
    name: '圣魔之光石 (JP)',
    multibyte: true,
    textPointerSlot: 0x00A000,
    unitPointerSlot: 0x010650,
    classPointerSlot: 0x017860,
    itemPointerSlot: 0x17568,
    portraitPointerSlot: 0x00542C,
    maskPointerSlot: 0x6E0,
    maskPointBaseSlot: 0x6DC,
    unitMaxCount: 255,
    unitDataSize: 52,
    classDataSize: 84,
    itemDataSize: 36,
    portraitDataSize: 28,
    signatureSlots: [0x00542C, 0x010650, 0x017860, 0x17568],
  ),
  RomProfile(
    id: 'FE8U',
    name: '圣魔之光石 (US)',
    multibyte: false,
    textPointerSlot: 0x00A2A0,
    unitPointerSlot: 0x10108,
    classPointerSlot: 0x017AB8,
    itemPointerSlot: 0x177C0,
    portraitPointerSlot: 0x005524,
    maskPointerSlot: 0x6E0,
    maskPointBaseSlot: 0x6DC,
    unitMaxCount: 255,
    unitDataSize: 52,
    classDataSize: 84,
    itemDataSize: 36,
    portraitDataSize: 28,
    signatureSlots: [0x005524, 0x10108, 0x017AB8, 0x177C0],
  ),
];

/// 按 game code 找档案。改版常改掉 code，所以这里只作**首选**而非唯一依据。
RomProfile? profileByCode(String code) {
  switch (code) {
    case 'AE6J':
    case 'AFEJ':
    case 'BE6J':
      return romProfiles[0];
    case 'AE7J':
    case 'BE7J':
    case 'A7EJ':
      return romProfiles[1];
    case 'AE7E':
    case 'BE7E':
      return romProfiles[2];
    case 'AE8J':
    case 'BE8J':
    case 'A8EJ':
      return romProfiles[3];
    case 'AE8E':
    case 'BE8E':
    case 'A8EE':
      return romProfiles[4];
  }
  return null;
}

/// 按结构匹配度找档案：谁的特征槽**全部**是有效指针，就用谁。
///
/// 这是兼容改版的核心——完全不看 game code，只看 ROM 的实际结构。
/// 实测「火焰纹章-铠甲的呼唤」（BE8E、20MB 重度改版）就是靠这个匹配到 FE8U 的。
RomProfile? profileByStructure(Uint8List d) {
  final probe = RomProbe(d);
  RomProfile? best;
  var bestScore = 0.0;
  for (final p in romProfiles) {
    final s = p.structureScore(probe);
    if (s > bestScore) {
      bestScore = s;
      best = p;
    }
  }
  // 要求全部特征槽都有效才算识别成功（部分匹配容易误判）
  if (best == null || bestScore < 0.999) return null;
  return best;
}
