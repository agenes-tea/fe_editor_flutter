import 'editable_rom.dart';
import 'rom_info.dart';

/// 道具表 `attributes`（**u32**@+8，见 [ItemOffsets.attributes]）里可开关的特性位。
///
/// 位含义取 fireemblem8u `include/bmitem.h` 的 `enum { IA_* }`，已在真实 ROM
/// 上逐位核对（`test/item_test.dart` 锁住勇者系 bit5、克武器 bit8、杖 bit2）。
/// 与职业 CA_* 特性区（`class_flags.dart`）同一套写法：`writeFlagBit` 按位写，
/// 只动这一位、其余位原样保留，可整体撤销。
///
/// **不开放 bit0/1/2（武器/魔法/杖类型位）**：这几位定义的是道具本身的性质
/// （占不占装备位、算不算杖），改它们等于把剑变成杖，不是「给武器加特性」
/// 的意图；也不开放 bit16（不能使用）。其余战斗相关位都可开关，
/// 把某把武器的特性复制给别的武器就靠勾这些。
class ItemFlagToggles {
  /// 可开关的位：（绝对位号, 中文名, 反编译枚举名）。
  ///
  /// 顺序即 UI 上从上到下的展示顺序，bit3（无限耐久）放最前——
  /// 它是用户最常改的一个（单道具变无限）。
  static const List<(int, String, String)> toggles = [
    (3, '无限耐久', 'IA_UNBREAKABLE'),
    (4, '不可出售', 'IA_UNSELLABLE'),
    (5, '连击两次', 'IA_BRAVE'),
    (6, '魔法伤害', 'IA_MAGICDAMAGE'),
    (7, '无法反击', 'IA_UNCOUNTERABLE'),
    (8, '逆转武器三角', 'IA_REVERTTRIANGLE'),
    (14, '无视飞行特效', 'IA_NEGATE_FLYING'),
    (15, '必杀无效', 'IA_NEGATE_CRIT'),
    (17, '无视防御', 'IA_NEGATE_DEFENSE'),
  ];

  /// 某道具当前全部可开关位的状态（按 [toggles] 顺序返回）。
  static List<bool> current(EditableRom edit, int itemAddr) {
    final v = edit.buffer.u32(itemAddr + ItemOffsets.attributes);
    return [for (final (bit, _, _) in toggles) (v >> bit) & 1 == 1];
  }

  /// 读某一位。
  static bool bit(EditableRom edit, int itemAddr, int bit) =>
      (edit.buffer.u32(itemAddr + ItemOffsets.attributes) >> bit) & 1 == 1;
}
