import 'editable_rom.dart';
import 'fe_rom.dart';
import 'item_catalog.dart';
import 'playable_units.dart';
import 'rom_info.dart';
import 'support.dart';
import 'custom_roster.dart';
import 'support_range.dart';
import 'unit_placement.dart';

/// 修改项的生效对象。
enum CheatTarget {
  unit('角色'),
  classTable('职业'),
  item('道具'),
  support('支援'),
  battleRule('规则');

  final String label;
  const CheatTarget(this.label);
}

/// 支援等级 A 所需的支援点数。
///
/// 反编译 `bmreliance.c` 的 `GetUnitSupportLevel()` 实际判定：
/// ```
/// exp > 240 -> A      exp > 160 -> B
/// exp >  80 -> C      否则        -> 无
/// ```
/// 所以 A 级必须 **> 240**（写 241~255）。之前按「A=160」写成 200，
/// 落到 B 区间，游戏里显示 B —— 这是错的。
/// 取 250 而不是 255：留一点余量，避免某些实现把 255 当成「未初始化」。
const int kSupportLevelAExp = 250;

/// `supportExpGrowth` 的单回合增长上限（u8）。原版多为 1~4。
const int kSupportGrowthMax = 255;

/// 支援加成距离的候选值（曼哈顿距离）。
///
/// 原版是 3；地图 15×10 两角相距 14+9=23，所以 30 已覆盖全屏，
/// 60 覆盖任何战斗地图。
const kSupportRangeFullscreen = 30;
const kSupportRangeBattlefield = 63;

/// 道具表 `attributes` 里「无限耐久」的位。
///
/// 反编译 `bmitem.h`：`IA_UNBREAKABLE = (1 << 3)`。
/// `GetItemAfterUse()` 见到这一位置位就直接返回原道具（不扣耐久），
/// `GetItemMaxUses()` 返回 0xFF（游戏内显示为 `--`）。
/// 原版就靠它实现「最终之暗」「火龙石」这类永不损坏的道具，
/// 所以这不是 hack，而是游戏自带机制。
const int kItemFlagUnbreakable = 3;

/// 一个可批量应用的修改项。
///
/// 它是纯数据：界面上把它渲染成一张卡片，点应用时交给 [applyCheat] 执行。
/// 想加新修改项只需往 [cheatPresets] 里加数据，不用改 UI。
class CheatPreset {
  final String id;
  final String title;
  final String description;
  final CheatTarget target;

  /// 字段标签 → 目标值。标签必须与 `unitEditableFieldsFor` /
  /// `classEditableFieldsFor` 里的 label 完全一致。
  final Map<String, int> values;

  /// 是否允许用户改「作用范围」（仅我方 / 含敌方 / 全表）。
  ///
  /// 职业类修改项作用在整张职业表上，没有阵营概念，所以为 false。
  final bool scopeSelectable;

  /// 是否在修改器界面显示（社区版暂时隐藏的部分选项设为 false）。
  final bool visible;

  const CheatPreset({
    required this.id,
    required this.title,
    required this.description,
    required this.target,
    required this.values,
    this.scopeSelectable = true,
    this.visible = true,
  });
}

/// 一次批量应用的结果。
class CheatResult {
  /// 实际发生改变的条目数。
  final int changedEntries;

  /// 实际写入的字节数。
  final int changedBytes;

  /// 由于找不到字段等原因被跳过的说明。
  final List<String> skipped;

  const CheatResult({
    required this.changedEntries,
    required this.changedBytes,
    required this.skipped,
  });
}

/// 内置修改项清单。
///
/// 全部作用于「我方角色」——默认口径是「有支援数据」，
/// 见 [PlayableUnits]。用户可以改成含敌方/全表。
const cheatPresets = <CheatPreset>[
  CheatPreset(
    id: 'unit_max_growth',
    title: '我方角色成长率拉满',
    description: '7 项成长率全部设为 100%',
    target: CheatTarget.unit,
    values: {
      'HP成长': 100,
      '力量成长': 100,
      '技巧成长': 100,
      '速度成长': 100,
      '防御成长': 100,
      '魔防成长': 100,
      '幸运成长': 100,
    },
  ),
  CheatPreset(
    id: 'unit_strong_stats',
    title: '我方角色属性强化',
    description: 'HP / 力量 / 技巧 / 速度 / 防御 / 魔防 / 幸运 / 体格 全部设为 20',
    target: CheatTarget.unit,
    values: {
      'HP': 20,
      '力量': 20,
      '技巧': 20,
      '速度': 20,
      '防御': 20,
      '魔防': 20,
      '幸运': 20,
      '体格': 20,
    },
  ),
  CheatPreset(
    id: 'unit_max_weapon_rank',
    title: '我方角色武器熟练度 S',
    description: '8 项武器熟练度全部设为 S（FE6 自动改用 FE6 档位）。'
        '注意：熟练度会影响命中 / 必杀结算，可能改变部分战斗动画的判定结果',
    target: CheatTarget.unit,
    // 值在运行时按版本替换，见 _maxRankValue。
    values: {},
  ),
  CheatPreset(
    id: 'unit_growth_200',
    title: '我方角色成长率 200%',
    description: '7 项成长率全部设为 200%，升级时几乎每项必加',
    target: CheatTarget.unit,
    values: {
      'HP成长': 200,
      '力量成长': 200,
      '技巧成长': 200,
      '速度成长': 200,
      '防御成长': 200,
      '魔防成长': 200,
      '幸运成长': 200,
    },
  ),
  CheatPreset(
    id: 'class_exp_denominator_1',
    title: '三倍经验（全职业）',
    description: '把全部职业的经验分母改为 1。'
        '原版多数职业是 3，分母越小单次战斗经验越多——1 即约为原版的 3 倍。'
        '注意：只影响「升级所需战斗」的节奏，我方成长率拉满配合效果最佳',
    target: CheatTarget.classTable,
    values: {'经验分母': 1},
    scopeSelectable: false,
  ),
  CheatPreset(
    id: 'class_caps_50',
    title: '职业能力上限 50',
    description: '把全部职业的能力上限改为 50（HP 上限为 60）。'
        '受原版存档机制限制，上限过高的属性在实机里存不下、会按 sbyte 截断，'
        '所以取 50 / HP 60 这类游戏内可稳定存储的值。'
        '与「成长率 200%」预设配合才能让角色突破职业天花板',
    target: CheatTarget.classTable,
    values: {
      'HP上限': 60,
      '力量上限': 50,
      '技巧上限': 50,
      '速度上限': 50,
      '防御上限': 50,
      '魔防上限': 50,
      '体格上限': 50,
    },
    scopeSelectable: false,
  ),
  CheatPreset(
    id: 'item_all_unbreakable',
    title: '全部道具无限耐久',
    description: '把所有道具（武器 / 杂项 / 杖）设为永不损坏，'
        '效果等同原版的最终之暗、火龙石，游戏内耐久显示为 --',
    target: CheatTarget.item,
    values: {},
    scopeSelectable: false,
  ),
  CheatPreset(
    id: 'item_weapon_unbreakable',
    title: '仅武器装备无限耐久',
    description: '只给武器与魔道书设无限耐久，不动伤药 / 钥匙 / 转职道具',
    target: CheatTarget.item,
    values: {},
    scopeSelectable: false,
  ),
  CheatPreset(
    id: 'support_all_a',
    title: '我方全员支援 A',
    description: '把我方每个角色的全部支援对象初始值设为 A 级（$kSupportLevelAExp 点）。'
        '同时把每回合增长设为上限，站在一起很快升满。'
        '注意：支援等级会决定结局里的双人配对，改满可能影响结局',
    target: CheatTarget.support,
    values: {},
    scopeSelectable: true,
  ),
  CheatPreset(
    id: 'support_range_30',
    title: '支援距离 30 格（全屏）',
    description: '把支援加成的生效距离从原版 3 格改成 30 格。'
        '距离是「横纵坐标差之和」（曼哈顿距离），30 格已覆盖 15×10 常规地图全屏',
    target: CheatTarget.battleRule,
    values: {},
    scopeSelectable: false,
  ),
  CheatPreset(
    id: 'support_range_60',
    title: '支援距离 63 格（覆盖任意战场）',
    description: '把支援加成距离改成 63 格。32×32 大图两角相距 31+31=62，'
        '63 足以覆盖任何战斗地图',
    target: CheatTarget.battleRule,
    values: {},
    scopeSelectable: false,
  ),
  CheatPreset(
    id: 'support_growth_max',
    title: '我方支援增长拉满',
    description: '只把每回合支援增长设为 $kSupportGrowthMax，不改初始值——'
        '支援等级仍按实际战斗慢慢累积，想保留养成感时用这个',
    target: CheatTarget.support,
    values: {},
    scopeSelectable: true,
  ),
];

/// S 档位的累计值。FE6 与 FE7/FE8 这套阈值不同（见 [WeaponRank]）。
int maxRankValue({required bool fe6}) => WeaponRank.s.valueFor(fe6: fe6);

/// 该预设实际要写入的「字段标签 → 值」。
///
/// 熟练度这类与版本相关的值在这里解析，避免把常量写死在 [cheatPresets] 里。
Map<String, int> resolveValues(CheatPreset preset, {required bool fe6}) {
  if (preset.id == 'unit_max_weapon_rank') {
    return {
      for (final t in WeaponType.values)
        '${t.label}熟练度': maxRankValue(fe6: fe6),
    };
  }
  return preset.values;
}

/// 该预设会影响的条目数（用于 UI 预览，不实际写入）。
///
/// [criterion] 仅对 `CheatTarget.unit` 生效；职业表与道具表没有阵营概念。
int cheatEntryCount(
  CheatPreset preset,
  FeRom rom, {
  PlayableCriterion criterion = PlayableCriterion.reciprocal,
  PlayableUnits? playable,
  CustomRoster? custom,
}) {
  final pu = playable ?? playableUnitsOf(rom);
  final scope = RosterScope(
    criterion: criterion,
    custom: custom ?? CustomRoster.empty,
  );
  return switch (preset.target) {
    CheatTarget.unit => scope.effective(pu).length,
    CheatTarget.classTable => rom.classCount,
    CheatTarget.item => _itemTargets(preset, rom).length,
    // 支援：有支援数据条目的玩家角色数（SupportTable 在 EditableRom 里，
    // 这里只按「我方角色」估算，UI 的确认框里会再显示实际改写条数）
    CheatTarget.support => scope.effective(pu).length,
    CheatTarget.battleRule => 1,
  };
}

/// 构造带「章节出场名单」的 [PlayableUnits]。
///
/// [PlayableCriterion.deployed] 需要章节静态表里的我方单位，而 `PlayableUnits`
/// 只有 `FeRom`；这里包一层，让调用方不必自己拼。
PlayableUnits playableUnitsOf(FeRom rom) => PlayableUnits(
      rom,
      deployedNumbers: UnitPlacement.deployedNumbersOf(rom),
    );

/// 「仅武器」预设的道具种类集合：剑 0 / 枪 1 / 斧 2 / 弓 3 / 理 5 / 光 6 / 闇 7。
///
/// 不含杖（4）：杖是消耗品，无限耐久的实际效果在游戏里未验证过；
/// 也不含道具（9）、舞娘指轮（0xC）、龙石（0xB）等特殊类。
const _weaponKinds = {0, 1, 2, 3, 5, 6, 7};

/// 该道具预设要作用到的道具索引。
List<int> _itemTargets(CheatPreset preset, FeRom rom) {
  final base = rom.itemBase;
  if (base < 0) return const [];
  final size = rom.table.itemDataSize;
  final out = <int>[];
  for (var i = 0; i < rom.itemCount; i++) {
    final at = base + i * size;
    if (at + size > rom.length) break;
    // ID 0 是空槽，没有名字也没意义
    if (FeRom.u8(rom.data, at + ItemOffsets.itemId) == 0) continue;
    if (preset.id == 'item_weapon_unbreakable') {
      if (!_weaponKinds.contains(FeRom.u8(rom.data, at + ItemOffsets.kind))) {
        continue;
      }
    }
    out.add(i);
  }
  return out;
}

/// 应用一个修改项。
///
/// 全部通过 [EditableRom.writeField] 写入，因此自动具备：
/// 值域夹紧、同值不写、记入 `edits`、可被 `revertAll()` 整体撤销。
///
/// [criterion] 控制 unit 类预设的作用范围，默认「仅我方角色」。
CheatResult applyCheat(
  EditableRom edit,
  CheatPreset preset, {
  PlayableCriterion criterion = PlayableCriterion.reciprocal,
  PlayableUnits? playable,
  CustomRoster? custom,
}) {
  final rom = edit.rom;
  final fe6 = rom.isFe6;
  final pu = playable ?? playableUnitsOf(rom);
  final scope = RosterScope(
    criterion: criterion,
    custom: custom ?? CustomRoster.empty,
  );
  final values = resolveValues(preset, fe6: fe6);

  final fields = switch (preset.target) {
    CheatTarget.unit => unitEditableFieldsFor(fe6: fe6),
    CheatTarget.classTable => classEditableFieldsFor(fe6: fe6),
    // 道具预设不靠数值字段，走标志位
    CheatTarget.item => const <EditField>[],
    // 支援走 SupportData 结构，字段在 writeSupport 里按 part 指定
    CheatTarget.support => const <EditField>[],
    // 规则类直接改指令字节
    CheatTarget.battleRule => const <EditField>[],
  };

  // 标签 → 字段定义；找不到的记进 skipped，避免静默漏改
  final resolved = <EditField, int>{};
  final skipped = <String>[];
  values.forEach((label, value) {
    final match = fields.where((f) => f.label == label);
    if (match.isEmpty) {
      skipped.add('找不到字段「$label」');
      return;
    }
    resolved[match.first] = value;
  });

  // 要作用的条目索引
  final List<int> targets;
  final int Function(int) baseOf;
  switch (preset.target) {
    case CheatTarget.unit:
      targets = scope.effective(pu);
      baseOf = (i) => edit.unitAddress(i);
      break;
    case CheatTarget.classTable:
      targets = [for (var i = 0; i < rom.classCount; i++) i];
      baseOf = (i) => edit.classAddress(i);
      break;
    case CheatTarget.item:
      targets = _itemTargets(preset, rom);
      baseOf = (i) => edit.itemAddress(i);
      break;
    case CheatTarget.battleRule:
      targets = [0];
      baseOf = (i) => 0;
      break;
    case CheatTarget.support:
      // 支援只给玩家角色配；判据与角色类预设一致
      targets = scope
          .effective(pu)
          .where((i) => edit.supportAddress(i) >= 0)
          .toList();
      baseOf = (i) => edit.supportAddress(i);
      break;
  }

  final bytesBefore = edit.changedByteCount;
  var changedEntries = 0;

  // 道具的无限耐久是**标志位**，不是数值字段：只置那一位，其余位原样保留
  if (preset.target == CheatTarget.item) {
    for (final i in targets) {
      final addr = baseOf(i) + ItemOffsets.attributes;
      if (edit.writeFlagBit(addr, kItemFlagUnbreakable, true)) changedEntries++;
    }
    return CheatResult(
      changedEntries: changedEntries,
      changedBytes: edit.changedByteCount - bytesBefore,
      skipped: skipped,
    );
  }

  // 规则类：改写「支援加成距离」那条 cmp 的立即数
  if (preset.target == CheatTarget.battleRule) {
    final range = SupportRange(rom);
    final at = range.locate();
    if (at < 0) {
      skipped.add('找不到支援距离判定指令（改版可能搬过代码）');
    } else {
      final want = preset.id == 'support_range_60'
          ? kSupportRangeBattlefield
          : kSupportRangeFullscreen;
      final before = edit.buffer.u16(at);
      final after = (before & 0xFF00) | (want & 0xFF);
      if (before != after) {
        edit.buffer.writeU16(at, after);
        edit.edits.add(ByteEdit(at, before & 0xFF, after & 0xFF));
        edit.edits
            .add(ByteEdit(at + 1, (before >> 8) & 0xFF, (after >> 8) & 0xFF));
        changedEntries = 1;
      }
    }
    return CheatResult(
      changedEntries: changedEntries,
      changedBytes: edit.changedByteCount - bytesBefore,
      skipped: skipped,
    );
  }

  // 支援：按 SupportData 的 7 个槽位写初始值 / 每回合增长
  if (preset.target == CheatTarget.support) {
    final setBase = preset.id == 'support_all_a';
    final setGrowth =
        preset.id == 'support_all_a' || preset.id == 'support_growth_max';
    for (final i in targets) {
      var touched = false;
      for (var slot = 0; slot < SupportTable.maxPartners; slot++) {
        final partner = edit.readSupport(i, slot, SupportPart.partner);
        if (partner <= 0) continue; // 空槽位（没有这个支援对象）
        if (setBase &&
            edit.writeSupport(i, slot, SupportPart.base, kSupportLevelAExp)) {
          touched = true;
        }
        if (setGrowth &&
            edit.writeSupport(i, slot, SupportPart.growth, kSupportGrowthMax)) {
          touched = true;
        }
      }
      if (touched) changedEntries++;
    }
    return CheatResult(
      changedEntries: changedEntries,
      changedBytes: edit.changedByteCount - bytesBefore,
      skipped: skipped,
    );
  }

  for (final i in targets) {
    final addr = baseOf(i);
    var touched = false;
    resolved.forEach((field, value) {
      if (edit.writeField(addr, field, value)) touched = true;
    });
    if (touched) changedEntries++;
  }

  return CheatResult(
    changedEntries: changedEntries,
    changedBytes: edit.changedByteCount - bytesBefore,
    skipped: skipped,
  );
}
