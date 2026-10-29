import 'dart:typed_data';

/// 探测结果。
class TableHit {
  /// 表基址（文件偏移）。
  final int base;

  /// 指针字段的有效率（0..1）。
  final double score;

  /// 参与统计的字段数。
  final int samples;

  const TableHit(this.base, this.score, this.samples);

  @override
  String toString() =>
      'TableHit(base=${base.toRadixString(16)}, score=${score.toStringAsFixed(2)}, samples=$samples)';
}

/// ROM 内的指针与表基址探测。
///
/// 改版（尤其是重度改版）经常把数据表搬到 ROM 的其它位置，但**指针槽通常留在原处**。
/// 本模块负责在「槽值只是候选起点」的前提下，确认真正的表基址。
class RomProbe {
  final Uint8List data;

  RomProbe(this.data);

  int get length => data.length;

  int u32(int at) {
    if (at < 0 || at + 4 > data.length) return 0;
    return data[at] |
        (data[at + 1] << 8) |
        (data[at + 2] << 16) |
        (data[at + 3] << 24);
  }

  /// GBA 指针（0x08xxxxxx..0x09xxxxxx）转文件偏移。
  static int toOffset(int ptr) => ptr & 0x1FFFFFF;

  /// 是否是 GBA 指针。
  static bool isPointer(int v) => v >= 0x08000000 && v < 0x0A000000;

  /// 指针是否「指向 ROM 空间内」。
  ///
  /// 改版可能把数据放在扩展区（ROM 尾部），所以不能简单要求 offset < ROM 长度；
  /// 只要地址落在 GBA 的 32MB 指针空间内就算合法。
  static bool isRomPointer(int v) => isPointer(v);

  /// 指针解引用后是否落在 ROM 实际数据范围内（带一点余量，允许指向尾部结构）。
  bool isResolvable(int ptr) {
    if (!isPointer(ptr)) return false;
    final off = toOffset(ptr);
    return off < length;
  }

  /// 读指针槽，返回数据偏移；不合法返回 -1。
  int pointerAt(int slot) {
    final p = u32(slot);
    if (!isResolvable(p)) return -1;
    return toOffset(p);
  }

  /// 在候选基址处往后看 [look] 条，统计「指针字段落在 ROM 空间内」的比例。
  ///
  /// [pointerFields] 是条目内**指针字段的字节偏移**列表（如 [0, 4, 8]）。
  /// [nullFields] 是**允许为 0 的字段**（0 视作合法）。
  ///
  /// 判据来自实测：正常表的有效率 ≥0.94，误判的表会因为槽值根本不是指针而直接出局。
  TableHit? scoreAt(
    int base,
    int entrySize,
    List<int> pointerFields, {
    int look = 16,
  }) {
    if (base < 0 || base + entrySize > length) return null;
    var hits = 0;
    var total = 0;
    for (var i = 0; i < look; i++) {
      final at = base + i * entrySize;
      if (at + entrySize > length) break;
      for (final f in pointerFields) {
        if (f + 4 > entrySize) continue;
        final v = u32(at + f);
        total++;
        if (v == 0 || isRomPointer(v)) hits++;
      }
    }
    if (total == 0) return null;
    return TableHit(base, hits / total, total);
  }

  /// 在槽值附近找表基址。
  ///
  /// 候选顺序：
  /// 1. 槽值本身（改版只换了指向时命中这里）
  /// 2. 槽值 ± N 个条目（少数版本的槽指向表首前一条 / 指向图像数据）
  ///
  /// 实测：原版与绝大多数改版（哪怕是 20MB 的重度改版）都能在第 1、2 步命中。
  /// 只有「槽值彻底失效且表被搬到别处」时才需要 [scanTables]。
  TableHit? findTable(
    int slot,
    int entrySize,
    List<int> pointerFields, {
    double minScore = 0.7,
    int maxShift = 4,
    int look = 16,
  }) {
    final candidates = <int>[];

    final p = u32(slot);
    if (isResolvable(p)) {
      final base = toOffset(p);
      candidates.add(base);
      for (var n = 1; n <= maxShift; n++) {
        candidates.add(base + n * entrySize);
        candidates.add(base - n * entrySize);
      }
    }

    TableHit? best;
    for (final c in candidates) {
      if (c < 0 || c + entrySize > length) continue;
      final hit = scoreAt(c, entrySize, pointerFields, look: look);
      if (hit == null) continue;
      if (hit.score < minScore) continue;
      if (best == null || hit.score > best.score) best = hit;
    }
    return best;
  }

  /// 全 ROM 扫描，返回可能的表位置（按一致性排序）。
  ///
  /// **重要限制**：GBA ROM 里到处都是指针数组，单纯的「指针有效率」判据
  /// 会产生成百上千个候选，无法唯一定位一张表（实测 FE7J 有 6.8 万个候选）。
  /// 所以扫描结果只能当**候选列表**给用户选，不能自动采纳。
  ///
  /// [minSamples] 是要求至少多少个条目参与统计，避免命中零散数据。
  List<TableHit> scanTables(
    int entrySize,
    List<int> pointerFields, {
    double minScore = 0.7,
    int look = 16,
    int scanStep = 4,
    int minSamples = 6,
    int limit = 64,
  }) {
    final hits = <TableHit>[];
    for (var base = 0; base + entrySize <= length; base += scanStep) {
      final hit = scoreAt(base, entrySize, pointerFields, look: look);
      if (hit == null || hit.score < minScore) continue;
      if (hit.samples < minSamples) continue;
      hits.add(hit);
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.length > limit ? hits.sublist(0, limit) : hits;
  }

  /// 统计「该槽指向的表」的指针有效率，用于版本识别时的结构打分。
  double slotScore(int slot, int entrySize, List<int> pointerFields,
      {int look = 16}) {
    final p = u32(slot);
    if (!isResolvable(p)) return 0;
    final hit = scoreAt(toOffset(p), entrySize, pointerFields, look: look);
    return hit?.score ?? 0;
  }
}
