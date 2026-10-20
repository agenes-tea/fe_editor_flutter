import 'fe_rom.dart';

/// 道具种类（item 表 +7 字段）。
///
/// 枚举值照搬 FEBuilderGBA `ItemForm` 的 `L_7_COMBO` 下拉项
/// （GPL-3.0，7743 著）：
/// `00=剣 01=槍 02=斧 03=弓 04=杖 05=理 06=光 07=闇 09=道具 0B=竜石・魔物専用 0C=指輪 11=火竜石 12=踊る用指輪`
enum ItemKind {
  sword(0x00, '剑', ItemGroup.weapon),
  lance(0x01, '枪', ItemGroup.weapon),
  axe(0x02, '斧', ItemGroup.weapon),
  bow(0x03, '弓', ItemGroup.weapon),
  staff(0x04, '杖', ItemGroup.weapon),
  anima(0x05, '理魔法', ItemGroup.weapon),
  light(0x06, '光魔法', ItemGroup.weapon),
  dark(0x07, '闇魔法', ItemGroup.weapon),
  consumable(0x09, '消耗品', ItemGroup.consumable),
  monsterOnly(0x0B, '龙石 / 魔物专用', ItemGroup.special),
  ring(0x0C, '指环', ItemGroup.special),
  fireDragonStone(0x11, '火龙石', ItemGroup.special),
  dancingRing(0x12, '跳跃指环', ItemGroup.special),
  unknown(0xFF, '未知', ItemGroup.other);

  final int raw;
  final String label;
  final ItemGroup group;

  const ItemKind(this.raw, this.label, this.group);

  static ItemKind fromRaw(int v) {
    for (final k in ItemKind.values) {
      if (k.raw == v) return k;
    }
    return ItemKind.unknown;
  }
}

/// 道具大类，用于列表分组。
enum ItemGroup {
  weapon('武器'),
  consumable('消耗品'),
  special('特殊道具'),
  other('其它');

  final String label;
  const ItemGroup(this.label);
}

/// 武器等级（item 表 +28）。
///
/// FE 用**熟练度累计值**表示武器等级，达到阈值升一级。
/// 取值只有 7 种（实测 FE7J/FE7U/FE8J 完全一致）：
/// 无=0x00、E=0x01、D=0x1F、C=0x47、B=0x79、A=0xB5、S=0xFB。
///
/// **FE6 的道具表布局不同，+28 不是武器等级**（实测取值杂散），
/// 所以 FE6 不显示等级。
enum WeaponRank {
  none(0x00, '—'),
  e(0x01, 'E'),
  d(0x1F, 'D'),
  c(0x47, 'C'),
  b(0x79, 'B'),
  a(0xB5, 'A'),
  s(0xFB, 'S');

  final int threshold;
  final String label;

  const WeaponRank(this.threshold, this.label);

  /// 按熟练度累计值反推等级。
  static WeaponRank fromValue(int v) {
    var best = WeaponRank.none;
    for (final r in WeaponRank.values) {
      if (v >= r.threshold) best = r;
    }
    return best;
  }
}

/// 射程编码（item 表 +25）。
///
/// 码值含义照搬 FEBuilderGBA `ItemForm` 的 `L_25_COMBO`：
/// `00=0 11=射程1(剣) 12=射程1-2(魔法) 13=射程1-3 22=射程2-2(弓) 23=射程2-3(長弓)
///  3A=射程3-10(サンダーストーム) 3F=射程3-15(ロングアーチ) 10=魔法/2  FF=全体(ラトナ)`
class ItemRange {
  final int raw;

  /// 最小射程（0 表示无意义）。
  final int minRange;

  /// 最大射程。
  final int maxRange;

  /// 显示用描述。
  final String label;

  const ItemRange(this.raw, this.minRange, this.maxRange, this.label);

  static const Map<int, ItemRange> _table = {
    0x00: ItemRange(0x00, 0, 0, '0'),
    0x10: ItemRange(0x10, 1, 2, '魔法 / 2'),
    0x11: ItemRange(0x11, 1, 1, '射程 1'),
    0x12: ItemRange(0x12, 1, 2, '射程 1-2'),
    0x13: ItemRange(0x13, 1, 3, '射程 1-3'),
    0x22: ItemRange(0x22, 2, 2, '射程 2-2'),
    0x23: ItemRange(0x23, 2, 3, '射程 2-3'),
    0x3A: ItemRange(0x3A, 3, 10, '射程 3-10'),
    0x3F: ItemRange(0x3F, 3, 15, '射程 3-15'),
    0xFF: ItemRange(0xFF, 0xFF, 0xFF, '全体'),
  };

  static ItemRange fromRaw(int v) => _table[v] ??
      ItemRange(v, 0, 0, '未知 (0x${v.toRadixString(16).toUpperCase()})');
}

/// item 表 +8 的标志位。
///
/// FEBuilderGBA 只把它们叫「特性1～4」，没有语义说明。以下含义由**实测归纳**
/// （FE7J 全 158 个道具逐条统计得到）：
///
/// | 位 | 含义 | 实测 |
/// |---|---|---|
/// | bit0 | 可装备 | 剑/枪/斧/弓/魔法=1，杖=0，消耗品=0，指环=0 |
/// | bit1 | 特殊 | 少见 |
/// | bit2 | 使用后消失 | 杖=1（杖是消耗型武器），消耗品 2 个为 1 |
/// | bit3 | 不可丢弃 / 特殊 | 少用 |
/// | bit4 | 专用武器 | 少用 |
/// | bit5 | 防具 / 特殊 | 少用 |
/// | bit7 | 特殊 | 少用 |
///
/// 重要：**杖（type=0x04）的 bit0 是 0**——它是「消耗型武器」，
/// 用完消失但不占装备位，所以「bit0=可装备」不能反推「是武器」。
class ItemFlags {
  final int raw;

  /// bit0：可装备（占装备位）。
  final bool equippable;

  /// bit2：使用后消失（杖是消耗型武器）。
  final bool vanishAfterUse;

  /// bit4：专用武器。
  final bool uniqueWeapon;

  /// bit5：特殊。
  final bool special;

  /// bit7：不可丢弃之类。
  final bool noDrop;

  const ItemFlags(
    this.raw, {
    required this.equippable,
    required this.vanishAfterUse,
    required this.uniqueWeapon,
    required this.special,
    required this.noDrop,
  });

  factory ItemFlags.fromRaw(int v) => ItemFlags(
        v,
        equippable: (v & 0x01) != 0,
        vanishAfterUse: (v & 0x04) != 0,
        uniqueWeapon: (v & 0x10) != 0,
        special: (v & 0x20) != 0,
        noDrop: (v & 0x80) != 0,
      );
}

/// 道具的一个条目（只读解析结果）。
///
/// 字段布局经实测确认，**FE6 / FE7 / FE8 完全一致**
/// （FE6 条目 32 字节，FE7/FE8 36 字节，但 +7~+29 的位置相同）。
class ItemEntry {
  final int id;
  final int address;

  /// 名字文本 id。
  final int nameTextId;

  /// 种类（+7）。
  final ItemKind kind;

  /// +8 的标志位。
  final ItemFlags flags;

  /// **使用次数 / 耐久**（+20）。
  ///
  /// 游戏内显示成「46/46」：分母就是这个字段，分子是当前剩余次数。
  /// 0 表示无限（消耗品里的伤药等）或该字段不适用。
  final int durability;

  /// 重量（+21）。
  final int weight;

  /// 命中（+22）。
  final int hit;

  /// 威力（+23）。
  ///
  /// 游戏里的「攻击」= 角色力量 + 这个值，所以看起来会比它大。
  final int might;

  /// 助（+24）。
  final int assist;

  /// 射程编码（+25）。
  final ItemRange range;

  /// 回避（+26）。
  final int avoid;

  /// 武器等级熟练度累计值（+28）。**仅 FE7/FE8 有意义**（FE6 布局不同）。
  final int weaponRankValue;

  /// 图标 id（+29）。
  final int iconId;

  /// 数值加成表指针（+12），0 表示没有。
  final int statBonusPointer;

  /// 有效职业列表指针（+16），0 表示没有。
  final int usableClassPointer;

  const ItemEntry({
    required this.id,
    required this.address,
    required this.nameTextId,
    required this.kind,
    required this.flags,
    required this.durability,
    required this.weight,
    required this.hit,
    required this.might,
    required this.assist,
    required this.range,
    required this.avoid,
    required this.weaponRankValue,
    required this.iconId,
    required this.statBonusPointer,
    required this.usableClassPointer,
  });

  /// 武器等级。FE6 的道具表没有这个字段，返回「—」。
  WeaponRank get weaponRank => WeaponRank.fromValue(weaponRankValue);

  bool get isEquippable => flags.equippable;

  /// 消耗品有「使用次数」的概念：装备品不会因使用而消失。
  bool get isConsumable => kind.group == ItemGroup.consumable;

  /// 该道具是否有使用次数限制。
  bool get hasDurability => durability > 0;
}

/// 数值加成表（item 表 +12 指向，12 字节）。
///
/// 顺序与 FEBuilderGBA `ItemStatBonusesForm.GetValues` 一致：
/// HP / 攻击 / 技巧 / 速度 / 防御 / 魔防 / 幸运 / 移动 / 体力
class ItemStatBonuses {
  final int hp;
  final int str;
  final int skill;
  final int speed;
  final int def;
  final int res;
  final int luck;
  final int move;
  final int body;

  const ItemStatBonuses(
    this.hp,
    this.str,
    this.skill,
    this.speed,
    this.def,
    this.res,
    this.luck,
    this.move,
    this.body,
  );

  static const empty = ItemStatBonuses(0, 0, 0, 0, 0, 0, 0, 0, 0);

  bool get isEmpty =>
      hp == 0 &&
      str == 0 &&
      skill == 0 &&
      speed == 0 &&
      def == 0 &&
      res == 0 &&
      luck == 0 &&
      move == 0 &&
      body == 0;

  /// 有增益的条目（用于 UI 展示）。
  List<(String, int)> get entries {
    final out = <(String, int)>[];
    void add(String label, int v) {
      if (v != 0) out.add((label, v));
    }

    add('HP', hp);
    add('攻击', str);
    add('技巧', skill);
    add('速度', speed);
    add('防御', def);
    add('魔防', res);
    add('幸运', luck);
    add('移动', move);
    add('体力', body);
    return out;
  }
}

/// 道具表读取。
class ItemCatalog {
  final FeRom rom;

  ItemCatalog(this.rom);

  int get _base => rom.itemBase;

  int get count => rom.itemCount;

  /// 该版本的道具表是否有「武器等级」字段（+28）。
  ///
  /// FE7/FE8 有（+28 是熟练度累计值）；**FE6 的道具表布局不同，+28 是别的值**。
  bool get hasWeaponRank => !rom.isFe6;

  int _u8(int at) => at >= 0 && at < rom.length ? rom.data[at] : 0;

  int _u16(int at) =>
      at >= 0 && at + 1 < rom.length ? rom.data[at] | (rom.data[at + 1] << 8) : 0;

  int _u32(int at) {
    if (at < 0 || at + 3 >= rom.length) return 0;
    return rom.data[at] |
        (rom.data[at + 1] << 8) |
        (rom.data[at + 2] << 16) |
        (rom.data[at + 3] << 24);
  }

  /// 解析第 [id] 条。表外或越界返回 null。
  ItemEntry? entryAt(int id) {
    final base = _base;
    if (base < 0) return null;
    final size = rom.table.itemDataSize;
    final at = base + id * size;
    if (at < 0 || at + size > rom.length) return null;
    return ItemEntry(
      id: id,
      address: at,
      nameTextId: _u16(at),
      kind: ItemKind.fromRaw(_u8(at + 7)),
      flags: ItemFlags.fromRaw(_u8(at + 8)),
      durability: _u8(at + 20),
      weight: _u8(at + 21),
      hit: _u8(at + 22),
      might: _u8(at + 23),
      assist: _u8(at + 24),
      range: ItemRange.fromRaw(_u8(at + 25)),
      avoid: _u8(at + 26),
      weaponRankValue: _u8(at + 28),
      iconId: _u8(at + 29),
      statBonusPointer: _u32(at + 12),
      usableClassPointer: _u32(at + 16),
    );
  }

  String nameOf(int id) => rom.itemName(id);

  /// 数值加成表。
  ItemStatBonuses statBonuses(ItemEntry e) {
    final p = e.statBonusPointer;
    if (p == 0) return ItemStatBonuses.empty;
    final o = p & 0x1FFFFFF;
    if (o + 12 > rom.length) return ItemStatBonuses.empty;
    int v(int k) => rom.data[o + k];
    return ItemStatBonuses(
      v(0),
      v(1),
      v(2),
      v(3),
      v(4),
      v(5),
      v(6),
      v(7),
      v(8),
    );
  }

  /// 有效职业 ID 列表（item 表 +16 指向，每字节一个 class ID，0 结尾）。
  List<int> usableClasses(ItemEntry e) {
    final p = e.usableClassPointer;
    if (p == 0) return const [];
    final o = p & 0x1FFFFFF;
    if (o >= rom.length) return const [];
    final out = <int>[];
    for (var i = 0; i < 256; i++) {
      final at = o + i;
      if (at >= rom.length) break;
      final v = rom.data[at];
      if (v == 0) break;
      out.add(v);
    }
    return out;
  }

  /// 按大类分组的条目。
  Map<ItemGroup, List<ItemEntry>> grouped() {
    final map = <ItemGroup, List<ItemEntry>>{};
    for (final g in ItemGroup.values) {
      map[g] = [];
    }
    // ID 0 是空槽（各字段全 0），种别会读成「剑」，必须排除
    for (var i = 1; i < count; i++) {
      final e = entryAt(i);
      if (e == null) continue;
      map[e.kind.group]!.add(e);
    }
    // 空组不显示
    map.removeWhere((_, v) => v.isEmpty);
    return map;
  }
}
