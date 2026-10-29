import 'dart:convert';

import 'fe_rom.dart';
import 'playable_units.dart';

/// 自定义角色名单：玩家手动勾选的一批角色 ID。
///
/// ## ID 语义（**最容易搞错的地方**）
///
/// 单位表里有两套「ID」，本项目历史上被它们坑过一次（v2.3.07 的名字整体偏一位）：
///
/// | 语义 | 取值 | 本项目里的名字 |
/// |---|---|---|
/// | **表内索引** | 0 起，**索引 0 是第一个角色（主角）** | `unitName(i)` / `indices()` 返回的 `i` |
/// | **单位 `number`** | 1 起，= 表内索引 + 1 | `PlacedUnit.charId` / 支援对象 / `pid` |
///
/// 角色列表页显示的「ID i」是**表内索引**（0 起），这一点玩家天天在看，
/// 所以**对外的共享格式统一用表内索引**；内部要转成 `number` 时显式 +1，
/// 转换点只有本文件的两处（[toNumbers] / [fromNumbers]）。
///
/// **0 是合法角色，不是空槽**：实测五个 ROM 的索引 0 都是自军主角
/// （艾利乌德 / 艾瑞珂 / 罗伊 / 阿纳金 / 辛格弗雷德前的阿纳金），`number`=1。
/// 所以名单里**允许且应当**包含 0；早先误以为「0 是空槽」而滤掉它，
/// 会导致主角永远改不到。
class CustomRoster {
  /// 参与修改的角色**表内索引**（0 起），已排序去重。
  final Set<int> indices;

  const CustomRoster(this.indices);

  static const CustomRoster empty = CustomRoster({});

  bool get isEmpty => indices.isEmpty;

  int get length => indices.length;

  bool containsIndex(int i) => indices.contains(i);

  /// 转成单位 `number`（1 起），供 [PlayableUnits] 之类的接口使用。
  Set<int> get toNumbers => {for (final i in indices) i + 1};

  /// 从单位 `number` 集合还原（1 起 → 索引 0 起）。
  static CustomRoster fromNumbers(Iterable<int> numbers) =>
      CustomRoster({for (final n in numbers) n - 1});

  CustomRoster toggle(int index) {
    final next = {...indices};
    if (!next.remove(index)) next.add(index);
    return CustomRoster(next);
  }

  CustomRoster withAll(Iterable<int> list) =>
      CustomRoster({...indices, ...list});

  CustomRoster withoutAll(Iterable<int> list) =>
      CustomRoster({...indices}..removeAll(list));

  CustomRoster inverted(int count) =>
      CustomRoster({for (var i = 0; i < count; i++) if (!indices.contains(i)) i});

  /// 导出给玩家复制的文本：逗号分隔的**表内索引**，如 `1,2,5,12,48`。
  ///
  /// 不含 JSON、不含前缀——玩家要贴进群或评论区，越短越好。
  String exportText() {
    final sorted = indices.toList()..sort();
    return sorted.join(',');
  }

  /// 生成带版本指纹的分享码（`FE_<fpr>_<ids>`），避免贴错 ROM 的名单被误用。
  String exportShareCode(FeRom rom) {
    final fpr = (rom.fingerprint & 0xFFFF).toRadixString(16).padLeft(4, '0');
    return 'FE_${fpr}_${exportText()}';
  }

  /// 从任意文本里提取 ID 列表——这是**最防呆**的一环：
  ///
  /// 玩家可能贴 `1,2,5`、`我用的 ID 是：1, 2, 5`、`FE_1a2b_1,2,5`，
  /// 甚至带换行与中文说明。所以这里只做一件事：抽出全部数字串。
  ///
  /// 但纯 `RegExp(r'\d+')` 有个坑：`FE_1a2b_1,2,5` 里的指纹 `1a2b` 会被拆成
  /// `1` 和 `2` 混进名单。所以先剥掉 `FE_<hex>_` 前缀，再抽数字。
  static List<int> parseIds(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return const [];
    // 剥掉分享码前缀（FE_1a2b_ 或 fe-1a2b-）
    text = text.replaceFirst(
      RegExp(r'FE[_-][0-9a-fA-F]{1,8}[_-]', caseSensitive: false),
      '',
    );
    final out = <int>[];
    for (final m in RegExp(r'\d+').allMatches(text)) {
      final v = int.tryParse(m.group(0)!);
      if (v != null) out.add(v);
    }
    return out;
  }

  /// 解析并过滤非法 ID。
  ///
  /// [unitCount] 是单位表条目数：合法索引是 `0 .. unitCount-1`。
  /// **0 是合法角色**（各作索引 0 都是自军主角），不能滤掉。
  ///
  /// 返回去重后的列表与「被丢弃的数量」，让 UI 能如实告诉用户
  /// 「识别到 44 个，其中 3 个超出范围已忽略」。
  static ({List<int> ids, int dropped}) parseAndFilter(
    String raw, {
    required int unitCount,
  }) {
    final parsed = parseIds(raw);
    final seen = <int>{};
    var dropped = 0;
    for (final v in parsed) {
      if (v < 0 || v >= unitCount) {
        dropped++;
        continue;
      }
      seen.add(v);
    }
    final ids = seen.toList()..sort();
    return (ids: ids, dropped: dropped);
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'ids': (indices.toList()..sort()),
      };

  static CustomRoster fromJson(Object? json, {required int unitCount}) {
    if (json is! Map) return empty;
    final ids = json['ids'];
    if (ids is! List) return empty;
    final out = <int>{};
    for (final e in ids) {
      if (e is! int) continue;
      // 0 是合法角色（索引 0 = 首位自军主角），只挡负数与越界
      if (e < 0 || e >= unitCount) continue;
      out.add(e);
    }
    return CustomRoster(out);
  }

  String toJsonString() => jsonEncode(toJson());

  @override
  String toString() => 'CustomRoster(${indices.length} 个)';
}

/// 把玩家自定义名单接进判据：在某个自动判据的结果上「叠加/剔除」。
///
/// 行为约定（与 UI 文案一致）：
/// - 自动判据先算出基础集合；
/// - 玩家的自定义名单**整体覆盖**基础集合，而不是做并集——
///   否则「取消勾选敌方角色」这件事做不到。
/// 所以真正生效的是 [effective]，[base] 只在「自定义名单为空」时兜底。
class RosterScope {
  final PlayableCriterion criterion;
  final CustomRoster custom;

  const RosterScope({required this.criterion, this.custom = CustomRoster.empty});

  bool get usesCustom => !custom.isEmpty;

  /// 实际参与修改的表内索引（升序）。
  ///
  /// **0 是空槽，永远排除**（界面也不列它）；超出 unitCount 的同样丢弃。
  List<int> effective(PlayableUnits pu) {
    // **0 是合法角色**（各作索引 0 都是自军主角），不要滤掉；
    // 只挡越界。（本项目没有「索引 0 = 空槽」这种约定。）
    if (usesCustom) {
      return custom.indices
          .where((i) => i >= 0 && i < pu.rom.unitCount)
          .toList()
        ..sort();
    }
    return pu.indices(criterion: criterion);
  }

  /// UI 上显示的说明文字。
  String describe(PlayableUnits pu) {
    if (usesCustom) {
      return '自定义名单（${custom.length} 个角色）';
    }
    return criterion.label;
  }
}
