import 'package:flutter/material.dart';

import '../core/editable_rom.dart';
import '../core/item_catalog.dart';

/// 道具浏览页：按大类分组，可按种类筛选，点进去看详情。
class ItemListPage extends StatefulWidget {
  final EditableRom edit;
  const ItemListPage({super.key, required this.edit});

  @override
  State<ItemListPage> createState() => _ItemListPageState();
}

class _ItemListPageState extends State<ItemListPage> {
  late final ItemCatalog _catalog = ItemCatalog(widget.edit.rom);
  ItemKind? _filter;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final groups = _catalog.grouped();
    var total = 0;
    for (final g in groups.values) {
      total += g.length;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('道具 ($total)'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(96),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: TextField(
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '搜索道具名',
                    prefixIcon: Icon(Icons.search, size: 20),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
              ),
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    _chip('全部', _filter == null, () => setState(() => _filter = null)),
                    for (final k in ItemKind.values)
                      if (k != ItemKind.unknown)
                        _chip(k.label, _filter == k, () => setState(() => _filter = k)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      body: ListView(
        children: [
          for (final entry in groups.entries)
            if (_filter == null || _filter!.group == entry.key)
              _groupSection(entry.key, entry.value),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Widget _groupSection(ItemGroup group, List<ItemEntry> items) {
    final shown = items.where(_match).toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            '${group.label} (${shown.length})',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        for (final e in shown)
          ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 14,
              child: Text(
                '${e.id}',
                style: const TextStyle(fontSize: 11),
              ),
            ),
            title: Text(
              _catalog.nameOf(e.id).trim().isEmpty
                  ? '（未命名）'
                  : _catalog.nameOf(e.id).trim(),
              style: const TextStyle(fontSize: 14),
            ),
            subtitle: Text(
              _subtitle(e),
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ItemDetailPage(catalog: _catalog, entry: e),
              ),
            ),
          ),
      ],
    );
  }

  bool _match(ItemEntry e) {
    if (_query.isEmpty) return true;
    final name = _catalog.nameOf(e.id);
    return name.contains(_query);
  }

  String _subtitle(ItemEntry e) {
    final parts = <String>['ID ${e.id}', e.kind.label];
    if (e.hasDurability) parts.add('次数 ${e.durability}');
    if (_catalog.hasWeaponRank) {
      final r = e.weaponRank;
      if (r != WeaponRank.none) parts.add('等级 ${r.label}');
    }
    if (e.kind.group == ItemGroup.weapon) {
      parts.add(e.range.label);
    }
    return parts.join(' · ');
  }
}

/// 道具详情页。
class ItemDetailPage extends StatelessWidget {
  final ItemCatalog catalog;
  final ItemEntry entry;

  const ItemDetailPage({
    super.key,
    required this.catalog,
    required this.entry,
  });

  @override
  Widget build(BuildContext context) {
    final rom = catalog.rom;
    final bonuses = catalog.statBonuses(entry);
    final classes = catalog.usableClasses(entry);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          catalog.nameOf(entry.id).trim().isEmpty
              ? '道具 ${entry.id}'
              : catalog.nameOf(entry.id).trim(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row('道具 ID', '${entry.id}'),
                  _row('种类', entry.kind.label),
                  _row('可装备', entry.flags.equippable ? '是' : '否'),
                  if (entry.flags.vanishAfterUse) _row('使用后消失', '是'),
                  if (entry.flags.uniqueWeapon) _row('专用武器', '是'),
                  if (entry.flags.noDrop) _row('不可丢弃', '是'),
                  if (entry.hasDurability) _row('使用次数 / 耐久', '${entry.durability}'),
                  if (entry.kind.group == ItemGroup.weapon) ...[
                    _row('重量', '${entry.weight}'),
                    _row('命中', '${entry.hit}'),
                    _row('威力', '${entry.might}'),
                    _row('助', '${entry.assist}'),
                    _row('回避', '${entry.avoid}'),
                    _row('射程', entry.range.label),
                    if (catalog.hasWeaponRank) ...[
                      _row('武器等级', entry.weaponRank.label),
                      _row('熟练度累计值',
                          '0x${entry.weaponRankValue.toRadixString(16).toUpperCase()}'),
                    ],
                  ],
                  _row('图标 ID', '${entry.iconId}'),
                  _row('表地址', '0x${entry.address.toRadixString(16)}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (!bonuses.isEmpty) ...[
            _section(context, '数值加成'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final b in bonuses.entries)
                      _row(b.$1, b.$2 > 0 ? '+${b.$2}' : '${b.$2}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (classes.isNotEmpty) ...[
            _section(context, '可使用职业（${classes.length}）'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final cid in classes)
                      Chip(
                        label: Text(
                          _className(rom, cid),
                          style: const TextStyle(fontSize: 11),
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          _note(),
        ],
      ),
    );
  }

  static String _className(dynamic rom, int cid) {
    final n = rom.className(cid).trim();
    return n.isEmpty ? '职业 $cid' : n;
  }

  Widget _section(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 4),
        child: Text(
          t,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: Text(k, style: const TextStyle(color: Colors.grey)),
            ),
            Expanded(child: Text(v)),
          ],
        ),
      );

  Widget _note() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.blueGrey.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.blueGrey.shade200),
        ),
        child: const Text(
          '说明：\n'
          '「使用次数 / 耐久」就是游戏里显示的 46/46 的分母。\n'
          '「威力」是武器自身的攻击力，游戏里的「攻击」= 角色力量 + 威力。\n'
          '「命中」「重量」「助」「回避」都是武器自身数值。\n'
          '上面显示的数值都是表里的真实数据。',
          style: TextStyle(fontSize: 12, color: Colors.blueGrey),
        ),
      );
}
