import 'fe_rom.dart';

/// 支援加成距离（`GetUnitSupportBonuses` 里的距离判定）。
///
/// 原版逻辑（反编译 `bmrel.c`）：
/// ```c
/// if (!(gBmSt.gameStateBits & 0x40)) {
///     if (RECT_DISTANCE(unit->xPos, unit->yPos, other->xPos, other->yPos)
///             > SUPPORT_BONUSES_MAX_DISTANCE)   // = 3
///         continue;
/// }
/// ```
/// `RECT_DISTANCE` 是**横纵坐标差的绝对值之和**（曼哈顿距离），
/// 不是「九宫格」那种含对角线的范围。
///
/// Thumb 编译后是四连指令：
/// ```
/// subs r0, r2, r3      ; |dx| 或差值
/// adds r0, r1, r0      ; + |dy|
/// cmp  r0, #3          ; SUPPORT_BONUSES_MAX_DISTANCE
/// bgt  ...             ; 超过则跳过
/// ```
/// 这个四连形态在正版 ROM 里**唯一命中**（FE6/FE7J/FE7U/FE8J 均已核对），
/// 所以用它做定位特征，改版搬过代码也能找到。
class SupportRange {
  final FeRom rom;
  const SupportRange(this.rom);

  /// `cmp rX, #imm` 的 Thumb 编码：0x2800 | (reg << 8) | imm。
  static int _cmpImm(int reg, int imm) =>
      0x2800 | ((reg & 7) << 8) | (imm & 0xFF);

  /// 定位「距离比较」那条 `cmp` 指令的文件偏移；找不到返回 -1。
  ///
  /// 判据：`subs`(0x1A00) + `adds reg,reg`(0x1800) + `cmp #N` + `bgt/ble` 连续四条，
  /// 其中 `cmp` 的寄存器与前面的 `adds` 目标一致。
  int locate() => _locateIn(rom.data);

  int _locateIn(List<int> d) {
    int u16(int at) => d[at] | (d[at + 1] << 8);
    var fallback = -1;
    for (var o = 0; o + 8 <= d.length - 1; o += 2) {
      final h0 = u16(o);
      if ((h0 & 0xFE00) != 0x1A00) continue; // subs rX, rY, rZ
      final h1 = u16(o + 2);
      if ((h1 & 0xFE00) != 0x1800) continue; // adds rX, rY, rZ
      final h2 = u16(o + 4);
      if ((h2 & 0xF800) != 0x2800) continue; // cmp rX, #imm
      final h3 = u16(o + 6);
      if ((h3 & 0xF000) != 0xD000) continue; // 条件跳转
      final cond = (h3 >> 8) & 0xF;
      // bgt(0xC) 对应 `> N`；ble(0xD) 对应 `<= N`（有的编译结果反过来）
      if (cond != 0xC && cond != 0xD) continue;
      // cmp 的目标寄存器要和 adds 的目标一致（同一条距离累加链）
      final cmpReg = (h2 >> 8) & 7;
      final addReg = (h1 >> 8) & 7;
      if (cmpReg != addReg) continue;
      // 原版这里比的是 3（SUPPORT_BONUSES_MAX_DISTANCE）。
      // 特征相同的还有别的距离判定（实测 FE7J 另有一处比 10），
      // 所以优先返回立即数为 3 的那处，找不到再退回第一处命中。
      if ((h2 & 0xFF) == 3) return o + 4;
      if (fallback < 0) fallback = o + 4;
    }
    return fallback;
  }

  /// 读当前距离阈值；定位失败返回 -1。
  ///
  /// 注意：[rom] 是**打开 ROM 时的快照**，改完再读会拿到旧值。
  /// 因此这个方法只用于「读取原版当前值」；校验修改结果请用 [readDistanceAt]
  /// 传入可编辑副本的 buffer（见 `EditableRom.buffer`）。
  int readDistance() {
    final at = locate();
    if (at < 0) return -1;
    return rom.data[at] & 0xFF;
  }

  /// 读【指定位置】的距离阈值。
  ///
  /// 校验「改完之后」的值时必须用它：改完立即数已不是 3，
  /// 再按特征重新定位会落到别的同形判定上（实测 FE7J 另有一处比 10）。
  int readDistanceAt(List<int> data, int at) {
    if (at < 0 || at + 1 >= data.length) return -1;
    return data[at] & 0xFF;
  }

  /// 目标阈值。
  ///
  /// 采用**曼哈顿距离**：地图 15×10 时，两角相距 (14+9)=23，
  /// 所以 30 已覆盖全屏常规地图，60 足够覆盖任何战斗地图（含 32×32 的大图）。
  static bool isValid(int v) => v >= 1 && v <= 255;
}
