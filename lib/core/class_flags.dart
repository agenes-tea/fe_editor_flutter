import 'editable_rom.dart';
import 'rom_info.dart';

/// 职业表 `attributes`（u32@40，见 [ClassOffsets.attributes]）的特性位定义。
///
/// 位含义取火纹社区反编译的 `CA_*` 枚举（fireemblem8u `include/bmunit.h`，
/// 「Character/Class attributes」，三作同一张表），并已在真实 ROM 上逐位核对：
/// CA_PROMOTED=8（上级职业）、CA_MOUNTED=10（陆坐骑）、CA_WYVERN=11（飞龙）、
/// CA_PEGASUS=12（天马）、CA_LORD=13（君主）、CA_FEMALE=14、CA_BOSS=15、
/// CA_MAXLEVEL10=19。
///
/// **只有 84 字节条目的版本（FE7/FE8）能写**：FE6 职业条目 72 字节，
/// `+40` 起是武器熟练度累计值（见 [ClassOffsets.weaponRankOffset]），
/// 按 CA_* 位写会直接改坏熟练度。
class ClassFlags {
  /// 可开关的位：（绝对位号, 中文名, 反编译枚举名）。
  static const List<(int, String, String)> toggles = [
    (8, '上级职业', 'CA_PROMOTED'),
    (10, '坐骑（陆骑）', 'CA_MOUNTED'),
    (11, '飞龙', 'CA_WYVERN'),
    (12, '天马', 'CA_PEGASUS'),
    (13, '君主', 'CA_LORD'),
    (14, '女性', 'CA_FEMALE'),
    (15, 'BOSS', 'CA_BOSS'),
    (19, '最大等级 10', 'CA_MAXLEVEL10'),
  ];

  /// 该版本的职业条目能不能按 CA_* 位写（条目 84 字节：FE7/FE8）。
  static bool supported(int classDataSize) => classDataSize == 84;

  /// 某职业当前的全部 CA_* 位（按 [toggles] 的顺序返回）。
  static List<bool> current(EditableRom edit, int addr) {
    final v = edit.buffer.u32(addr + ClassOffsets.attributes);
    return [for (final (bit, _, _) in toggles) (v >> bit) & 1 == 1];
  }

  /// 读某一位。
  static bool bit(EditableRom edit, int addr, int bit) =>
      (edit.buffer.u32(addr + ClassOffsets.attributes) >> bit) & 1 == 1;
}
