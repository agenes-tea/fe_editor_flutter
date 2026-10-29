import 'fe_rom.dart';
import 'rom_info.dart';

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

/// 武器等级（item 表 +28 / unit 表 +20..27 / class 表 +44..51）。
///
/// FE 用**熟练度累计值**表示武器等级，达到阈值升一级。
/// 两套阈值，不能混用（实测逐条比对 ROM 得出）：
///
/// | 等级 | FE7/FE8 | FE6 |
/// |---|---|---|
/// | 无 | 0x00 | 0x00 |
/// | E | 0x01 | 0x01 |
/// | D | 0x1F | 0x33 |
/// | C | 0x47 | 0x65 |
/// | B | 0x79 | 0x97 |
/// | A | 0xB5 | 0xC9 |
/// | S | 0xFB | 0xFB |
///
/// FE6 的档位间隔是 50（0x32），FE7/FE8 是等级越高间隔越大。
enum WeaponRank {
  none(0x00, 0x00, '—'),
  e(0x01, 0x01, 'E'),
  d(0x1F, 0x33, 'D'),
  c(0x47, 0x65, 'C'),
  b(0x79, 0x97, 'B'),
  a(0xB5, 0xC9, 'A'),
  s(0xFB, 0xFB, 'S');

  final int threshold;
  final int fe6Threshold;
  final String label;

  const WeaponRank(this.threshold, this.fe6Threshold, this.label);

  /// 该等级在该版本下的累计值。
  int valueFor({required bool fe6}) => fe6 ? fe6Threshold : threshold;

  /// 按熟练度累计值反推等级。
  static WeaponRank fromValue(int v, {bool fe6 = false}) {
    var best = WeaponRank.none;
    for (final r in WeaponRank.values) {
      if (v >= r.valueFor(fe6: fe6)) best = r;
    }
    return best;
  }
}

/// 武器种类（熟练度在结构体里按剑/枪/斧/弓/杖/理/光/暗 顺序连续存放）。
enum WeaponType {
  sword('剑'),
  lance('枪'),
  axe('斧'),
  bow('弓'),
  staff('杖'),
  anima('理'),
  light('光'),
  dark('暗');

  final String label;
  const WeaponType(this.label);
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

  static ItemRange fromRaw(int v) =>
      _table[v] ??
      ItemRange(v, 0, 0, '未知 (0x${v.toRadixString(16).toUpperCase()})');
}

/// item 表 +8 的 `attributes`（**u32**，不是 u8）。
///
/// 位含义取自 FireEmblemUniverse/fireemblem8u 的 `include/bmitem.h`
/// 里的 `enum { IA_* }`，并在 FE6/FE7J/FE7U/FE8J 四份真实 ROM 上逐条核对过
/// （勇者系武器的 bit5、杖的 bit2、神器类 bit3 全部命中）。
///
/// 早期版本只读 `+8` 这一个字节，读到的是 u32 的最低字节，
/// 于是 bit8 以上（逆转武器三角、特效无效等）永远读不出来。
class ItemFlags {
  /// 完整的 u32 attributes。
  final int raw;

  /// bit0 IA_WEAPON：可用作武器（占装备位）。
  final bool weapon;

  /// bit1 IA_MAGIC：魔法。
  final bool magic;

  /// bit2 IA_STAFF：杖。
  final bool staff;

  /// bit3 IA_UNBREAKABLE：无限耐久。
  final bool unbreakable;

  /// bit4 IA_UNSELLABLE：不可出售。
  final bool unsellable;

  /// bit5 IA_BRAVE：连击两次（勇者系）。
  final bool brave;

  /// bit6 IA_MAGICDAMAGE：用魔防计算伤害。
  final bool magicDamage;

  /// bit7 IA_UNCOUNTERABLE：无法被反击。
  final bool uncounterable;

  /// bit8 IA_REVERTTRIANGLE：逆转武器三角（レイピア等）。
  final bool reverseTriangle;

  /// bit14 IA_NEGATE_FLYING：无视飞行特效。
  final bool negateFlying;

  /// bit15 IA_NEGATE_CRIT：必杀无效。
  final bool negateCrit;

  /// bit16 IA_UNUSABLE：不能使用。
  final bool unusable;

  /// bit17 IA_NEGATE_DEFENSE：无视防御（ルーンソード等）。
  final bool negateDefense;

  const ItemFlags(
    this.raw, {
    required this.weapon,
    required this.magic,
    required this.staff,
    required this.unbreakable,
    required this.unsellable,
    required this.brave,
    required this.magicDamage,
    required this.uncounterable,
    required this.reverseTriangle,
    required this.negateFlying,
    required this.negateCrit,
    required this.unusable,
    required this.negateDefense,
  });

  factory ItemFlags.fromRaw(int v) => ItemFlags(
        v,
        weapon: (v & 0x01) != 0,
        magic: (v & 0x02) != 0,
        staff: (v & 0x04) != 0,
        unbreakable: (v & 0x08) != 0,
        unsellable: (v & 0x10) != 0,
        brave: (v & 0x20) != 0,
        magicDamage: (v & 0x40) != 0,
        uncounterable: (v & 0x80) != 0,
        reverseTriangle: (v & 0x100) != 0,
        negateFlying: (v & 0x4000) != 0,
        negateCrit: (v & 0x8000) != 0,
        unusable: (v & 0x10000) != 0,
        negateDefense: (v & 0x20000) != 0,
      );

  /// 已置位的特性名（用于详情页展示）。
  List<String> get setFlags => [
        if (weapon) '武器',
        if (magic) '魔法',
        if (staff) '杖',
        if (unbreakable) '无限耐久',
        if (unsellable) '不可出售',
        if (brave) '连击两次',
        if (magicDamage) '魔法伤害',
        if (uncounterable) '无法反击',
        if (reverseTriangle) '逆转武器三角',
        if (negateFlying) '无视飞行特效',
        if (negateCrit) '必杀无效',
        if (unusable) '不能使用',
        if (negateDefense) '无视防御',
      ];
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

  /// 使用次数 / 耐久（+20）。
  ///
  /// 游戏内显示成「46/46」：分母就是这个字段，分子是当前剩余次数。
  /// 0 表示无限（消耗品里的伤药等）或该字段不适用。
  final int durability;

  /// 威力 / 攻击（+21）。
  ///
  /// 游戏里的「攻击」= 角色力量 + 这个值，所以看起来会比它大。
  final int might;

  /// 命中（+22）。
  final int hit;

  /// 重量（+23）。
  final int weight;

  /// 必杀（+24）。
  final int crit;

  /// 射程编码（+25）。
  final ItemRange range;

  /// 单价（+26，**u16**）。商店售价 = 耐久 × 单价（铁剑 46×10 = 460）。
  ///
  /// 早期版本按 u8 读，只拿到低字节：覇者の証（50000）会显示成 80。
  final int unitPrice;

  /// 武器等级熟练度累计值（+28）。
  final int weaponRankValue;

  /// 图标 id（+29）。
  final int iconId;

  /// 使用效果 ID（+30，`bmitem.h` useEffectId）：0=无，非 0 为使用效果表下标。
  final int useEffectId;

  /// 武器特效（+31，`bmitem.h` weaponEffectId）：0 无 / 1 毒 / 2 吸血 / 3 减半 /
  /// 4 魔剑 / 5 石化（FE8 专有）。
  final int weaponEffectId;

  /// 使用武器获得的经验（+32，`bmitem.h` weaponExp）；FE6 条目只有 32 字节，置 0。
  final int weaponExp;

  /// 数值加成表指针（+12），0 表示没有。
  final int statBonusPointer;

  /// 克制职业列表指针（+16），0 表示没有。列表里每字节一个职业 ID、0 结尾，
  /// 含义是「该武器对这些职业有额外伤害（兵种克制）」，并非限制谁能装备。
  final int usableClassPointer;

  /// 熟练度阈值按 FE6 的档位取值（FE6 与 FE7/FE8 不同）。
  final bool fe6;

  const ItemEntry({
    required this.id,
    required this.address,
    required this.nameTextId,
    required this.kind,
    required this.flags,
    required this.durability,
    required this.might,
    required this.hit,
    required this.weight,
    required this.crit,
    required this.range,
    required this.unitPrice,
    required this.weaponRankValue,
    required this.iconId,
    required this.useEffectId,
    required this.weaponEffectId,
    required this.weaponExp,
    required this.statBonusPointer,
    required this.usableClassPointer,
    required this.fe6,
  });

  /// 武器特效显示名（反编译 `WEAPON_EFFECT_*` 枚举；FE8 多一个「石化」）。
  String get weaponEffectLabel {
    const names = ['无', '毒', '吸血', '减半', '魔剑', '石化'];
    if (weaponEffectId < names.length) return names[weaponEffectId];
    return '未知($weaponEffectId)';
  }

  /// 使用效果显示（无名字表，按下标展示）。
  String get useEffectLabel => useEffectId == 0 ? '无' : '效果 $useEffectId';

  /// 武器等级。
  WeaponRank get weaponRank => WeaponRank.fromValue(weaponRankValue, fe6: fe6);

  bool get isEquippable => flags.weapon;

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

  /// 熟练度阈值按 FE6 的档位取值。
  bool get isFe6 => rom.isFe6;

  int _u8(int at) => at >= 0 && at < rom.length ? rom.data[at] : 0;

  int _u16(int at) => at >= 0 && at + 1 < rom.length
      ? rom.data[at] | (rom.data[at + 1] << 8)
      : 0;

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
      kind: ItemKind.fromRaw(_u8(at + ItemOffsets.kind)),
      flags: ItemFlags.fromRaw(_u32(at + ItemOffsets.attributes)),
      durability: _u8(at + ItemOffsets.durability),
      might: _u8(at + ItemOffsets.might),
      hit: _u8(at + ItemOffsets.hit),
      weight: _u8(at + ItemOffsets.weight),
      crit: _u8(at + ItemOffsets.crit),
      range: ItemRange.fromRaw(_u8(at + ItemOffsets.range)),
      unitPrice: _u16(at + ItemOffsets.unitPrice),
      weaponRankValue: _u8(at + ItemOffsets.weaponRank),
      iconId: _u8(at + ItemOffsets.iconId),
      useEffectId: _u8(at + ItemOffsets.useEffect),
      weaponEffectId: _u8(at + ItemOffsets.weaponEffect),
      // FE6 条目 32 字节，+32 会读进下一条，置 0
      weaponExp: size >= 36 ? _u8(at + ItemOffsets.weaponExp) : 0,
      statBonusPointer: _u32(at + ItemOffsets.statBonusPointer),
      usableClassPointer: _u32(at + ItemOffsets.usableClassPointer),
      fe6: rom.isFe6,
    );
  }

  /// 显示用的道具名（汉化版返回正式译名）。
  String nameOf(int id) => rom.itemDisplayName(id);

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

  /// 克制职业 ID 列表（item 表 +16 指向，每字节一个职业 ID、0 结尾）。
  /// 语义是「该武器对这些职业有额外伤害（兵种克制）」，并非限制装备。
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
