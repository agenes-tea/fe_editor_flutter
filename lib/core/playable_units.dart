import 'fe_rom.dart';
import 'rom_info.dart';
import 'unit_placement.dart';

/// 判断哪些单位是「玩家可操控的角色」。
///
/// ## 为什么不能只看单位表
///
/// 单位表（`CharacterData`）里**没有阵营字段**——阵营写在关卡事件的
/// `UnitDefinition.allegiance` 里（`bmunit.h`：0=蓝方 1=绿方 2=红方），
/// 每个关卡各自配置。所以同一个角色可能前期是敌人、后期被说服加入我方。
/// 要 100% 精确只能解析全部关卡事件脚本里的 `LOAD` 指令，工程量很大，
/// 而且改版会改关卡，解析器反而更脆弱。
///
/// 这里改用**单位表自身的多信号**，在真实 ROM 上校准过。
///
/// ## 判据
///
/// FE8 实测（三个 ROM：日版 / 汉化版 / 圣邪的意志，结果完全一致）：
///
/// | 判据 | 命中数 | 说明 |
/// |---|---|---|
/// | 有支援数据 `pSupportData != 0` | 33 | **最准**：支援系统只给玩家角色配 |
/// | `sort_order != 0`（+0x0A） | 46 | 会把敌方主要角色也算进来 |
/// | `visit_group != 0` | — | 部分我方角色也是 0，不可靠 |
///
/// 「有支援数据」在语义上最贴合：支援对话是玩家角色专属功能，
/// 敌方/NPC 即使在关卡里出现也不会配支援。
///
/// 但**改版可能给敌方也加支援**，所以这里不把它当唯一真理：
/// 同时提供 `sortOrder` 判据，并在 UI 上把两个判据的差异列出来让用户确认。
class PlayableUnits {
  final FeRom rom;

  /// 章节里出场过的角色 number（1 基）。
  ///
  /// 单位表没有阵营字段，「我方」只能靠间接信号推断。支援数据是原版里最稳的信号，
  /// 但改版可能没给主要角色配支援对话（实测 TLP v1.5 的辛格弗雷德支援指针为 0），
  /// 那种情况下支援判据会漏掉主角。调用方可以传入章节静态表里出现过的角色，
  /// 让 [PlayableCriterion.deployed] 把它们算进来。
  final Set<int> deployedNumbers;

  PlayableUnits(this.rom, {this.deployedNumbers = const {}});

  int get _base => rom.unitBase;
  int get _size => rom.table.unitDataSize;

  /// 该单位是否配了支援数据。
  ///
  /// **只看指针不够**：有的改版给单位留了支援指针但 `supportCount = 0`
  /// （实测「铠甲的呼唤」芬瓦尔德 / 阿莱西亚），这种空块不是有效支援。
  bool hasSupportData(int index) {
    final block = _supportBlock(index);
    return block != null;
  }

  /// 读该单位的支援块；无效返回 null。
  ///
  /// 返回 `(offset, count)`：offset 是支援数据在 ROM 里的偏移，
  /// count 是 `supportCount`（`+0x15`，合法值 0..7）。
  ({int offset, int count})? _supportBlock(int index) {
    final b = _base;
    if (b < 0) return null;
    final at = b + index * _size;
    if (at + UnitOffsets.supportPointer + 4 > rom.length) return null;
    final p = FeRom.u32(rom.data, at + UnitOffsets.supportPointer);
    if (p == 0 || !FeRom.isPointer(p, rom.length)) return null;
    final off = FeRom.toOffset(p);
    if (off + 0x16 > rom.length) return null;
    final count = rom.data[off + 0x15];
    if (count == 0 || count > 7) return null;
    return (offset: off, count: count);
  }

  /// 该单位的支援对象列表（单位表 `number` 语义，即 index+1）。
  ///
  /// 已实测对照反编译常量：FE8 艾瑞珂的 7 个对象正是
  /// Ephraim(15)/Seth(2)/Saleh(23)/LArachel(25)/Tana(34)/Innes(11)/Forde(16)。
  List<int> supportPartners(int index) {
    final block = _supportBlock(index);
    if (block == null) return const [];
    return [
      for (var k = 0; k < block.count; k++) rom.data[block.offset + k],
    ];
  }

  /// 单位表 `number` 字段（`u8@4`，从 1 连续递增，恒等于 index+1）。
  int unitNumber(int index) {
    final b = _base;
    if (b < 0) return 0;
    final at = b + index * _size + UnitOffsets.unitId;
    if (at >= rom.length) return 0;
    return rom.data[at];
  }

  /// 「number → 该单位是否有互惠支援」的索引表。
  Map<int, List<int>>? _partnerIndex;

  /// 全表支援互惠索引：number → 对方支援列表。
  ///
  /// 互惠性是**原版数据的硬约束**：A 的列表里有 B，B 的列表里必有 A。
  /// 实测 FE7J / FE8J（含汉化与圣邪）互惠缺失为 0；FE6 有 28 个单向对
  /// （FE6 支援机制特殊，单向对本来就存在，不影响本判据的可用性）。
  Map<int, List<int>> get partnerIndex {
    final cached = _partnerIndex;
    if (cached != null) return cached;
    final map = <int, List<int>>{};
    for (var i = 0; i < rom.unitCount; i++) {
      final block = _supportBlock(i);
      if (block == null) continue;
      map[unitNumber(i)] = supportPartners(i);
    }
    return _partnerIndex = map;
  }

  /// 该单位的支援对象里，有多少个在对方列表里也回指它。
  ///
  /// 原版数据的每个支援对都互惠；改版可能只做了一半（对方没回指），
  /// 这种「半成品支援」不能当作可靠的「我方」证据。
  int reciprocalCount(int index) {
    final number = unitNumber(index);
    final partners = supportPartners(index);
    if (partners.isEmpty) return 0;
    var n = 0;
    for (final p in partners) {
      final back = partnerIndex[p];
      if (back != null && back.contains(number)) n++;
    }
    return n;
  }

  /// 该单位的 `sort_order`（+0x0A）。0 表示「不在图鉴列表里」。
  int sortOrderOf(int index) {
    final b = _base;
    if (b < 0) return 0;
    final at = b + index * _size + UnitOffsets.sortOrder;
    if (at >= rom.length) return 0;
    return rom.data[at];
  }

  /// 最推荐的口径：有支援数据。
  bool isPlayable(int index) => hasSupportData(index);

  /// 事件脚本里以蓝方出场的角色 number（1 基）。
  ///
  /// 懒计算：只有用到 [PlayableCriterion.deployedWithEvents] 时才扫全章事件
  /// （扫描结果在 [UnitPlacement.eventUnitNumbersOf] 里按 ROM 指纹缓存）。
  Set<int>? _eventNumbers;
  Set<int> get eventNumbers =>
      _eventNumbers ??= UnitPlacement.eventUnitNumbersOf(rom);

  /// 按指定口径列出的索引。
  List<int> indices(
      {PlayableCriterion criterion = PlayableCriterion.reciprocal}) {
    final out = <int>[];
    for (var i = 0; i < rom.unitCount; i++) {
      final ok = switch (criterion) {
        PlayableCriterion.reciprocal => reciprocalCount(i) > 0,
        PlayableCriterion.supportData => hasSupportData(i),
        PlayableCriterion.deployed =>
          deployedNumbers.contains(unitNumber(i)) || reciprocalCount(i) > 0,
        PlayableCriterion.deployedWithEvents =>
          deployedNumbers.contains(unitNumber(i)) ||
              eventNumbers.contains(unitNumber(i)) ||
              reciprocalCount(i) > 0,
        PlayableCriterion.sortOrder => sortOrderOf(i) != 0,
        // 自定义名单不在这个类里（见 [custom] 的注释），空即全不选
        PlayableCriterion.custom => false,
        PlayableCriterion.all => true,
      };
      if (ok) out.add(i);
    }
    return out;
  }

  /// 两个判据的差异：`sort_order` 有值但没有支援数据的单位。
  ///
  /// 这批是「敌方主要角色 / 后期可能加入的角色」，给 UI 提示用。
  List<int> ambiguous() => [
        for (var i = 0; i < rom.unitCount; i++)
          if (sortOrderOf(i) != 0 && !hasSupportData(i)) i,
      ];

  /// [targets] 里「看起来像敌方」的索引（有图鉴排序但没有支援数据）。
  ///
  /// 支援对话只给玩家角色配，所以「有排序、没支援」基本可断定是敌方主要角色。
  /// 但在章节静态表或事件脚本里**以蓝方出场过的不算**：烈火按图鉴排序的那批
  /// 大多是可操控角色（玲/威尔/肯特/妮妮安…），作者只是没给他们配双向支援。
  /// 不过滤的话确认弹窗会把玲点成「大概率是敌方」。
  ///
  /// 作用范围是「我方」的几个口径（[reciprocal] / [supportData] / [deployed] /
  /// [deployedWithEvents]）本来就不含这批，结果应为空；只有手动选了
  /// 「按图鉴排序 / 全表」时才会非空——UI 用它把误带的敌人一个个点名。
  List<int> enemySuspects(List<int> targets) {
    final suspects = ambiguous().toSet();
    if (suspects.isEmpty) return const [];
    return targets.where((i) {
      if (!suspects.contains(i)) return false;
      final n = unitNumber(i);
      return !deployedNumbers.contains(n) && !eventNumbers.contains(n);
    }).toList();
  }
}

/// 修改器的作用范围口径。
enum PlayableCriterion {
  /// 支援互惠——至少有一个支援对象回指它。
  ///
  /// 比 [supportData] 更严：能排除「改版加了支援指针但没做对话」
  /// 的半成品支援（实测铠甲的呼唤有 12 个单向对）。原版三作
  /// 与该口径的命中数与 [supportData] 完全一致。
  reciprocal('仅我方角色（推荐）'),

  /// 有支援数据块即可（含空块）——旧行为，宽松。
  supportData('我方（宽松：有支援数据即可）'),

  /// 章节静态表里作为我方出场过（含主线主角），或支援互惠。
  ///
  /// 改版的常见情况：主线主角确实可操控，但作者没给他配支援对话
  /// （实测 TLP v1.5 主角辛格弗雷德 `+0x2C` 与支援数都是 0），
  /// 按 [reciprocal] 会漏掉他，成长率这类预设就「看起来没用」。
  deployed('我方（按章节出场判据）'),

  /// 静态出场 ∪ 事件脚本里以蓝方出场的角色（剧情增援、后期加入的我方）。
  ///
  /// 比 [deployed] 多一层：只靠静态表的改版/章节会把增援里的我方角色漏掉；
  /// 红方（敌军）与绿方（NPC）不计入，否则会出现「连敌人一起加强」。
  deployedWithEvents('我方（按出场，含事件动态）'),

  /// `sort_order != 0`——图鉴排序表里有的都算，含敌方主要角色。
  sortOrder('我方 + 敌方主要角色（按图鉴排序）'),

  /// 玩家手工勾选的名单。
  ///
  /// 这个口径本身不产生任何集合——真正的名单在 [CustomRoster] 里，
  /// 由调用方（修改器页）通过 [RosterScope] 叠加进来。放在枚举里
  /// 只是为了让 UI 的「作用范围」单选组有一个统一的选中值。
  custom('自定义名单（手工勾选）'),

  /// 全表，含 NPC 与占位条目。
  all('全部单位（含敌方与 NPC）');

  final String label;
  const PlayableCriterion(this.label);
}
