import 'package:flutter/material.dart';

import '../core/editable_rom.dart';
import '../core/item_catalog.dart';
import '../core/item_flags.dart';
import '../core/item_icon.dart';
import '../core/rom_info.dart';
import 'text_edit_dialog.dart';
import 'unit_page.dart';

/// 道具浏览页：按大类分组，可按种类筛选，点进去看详情。
class ItemListPage extends StatefulWidget {
  final EditableRom edit;
  const ItemListPage({super.key, required this.edit});

  @override
  State<ItemListPage> createState() => _ItemListPageState();
}

class _ItemListPageState extends State<ItemListPage> {
  late final ItemCatalog _catalog = ItemCatalog(widget.edit.liveRom);
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
                    hintText: '搜索道具名 / ID',
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
                    _chip('全部', _filter == null,
                        () => setState(() => _filter = null)),
                    for (final k in ItemKind.values)
                      if (k != ItemKind.unknown)
                        _chip(k.label, _filter == k,
                            () => setState(() => _filter = k)),
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
            // 名称左边是游戏里的 16×16 小图标；取不到就退回 ID 数字
            leading: SizedBox(
              width: 32,
              height: 32,
              child: Center(
                child: ItemIconView(
                  rom: widget.edit.rom,
                  iconId: e.iconId,
                  size: 28,
                  fallback: Text(
                    '${e.id}',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
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
                builder: (_) => ItemDetailPage(
                  catalog: _catalog,
                  entry: e,
                  edit: widget.edit,
                ),
              ),
            ).then((_) => setState(() {})),
          ),
      ],
    );
  }

  bool _match(ItemEntry e) {
    if (_query.isEmpty) return true;
    final name = _catalog.nameOf(e.id);
    if (name.contains(_query)) return true;
    // 数字输入按 ID 匹配：名字搜不到时可以直接用 ID 定位
    final asId = int.tryParse(_query);
    return asId != null && e.id == asId;
  }

  String _subtitle(ItemEntry e) {
    final parts = <String>['ID ${e.id}', e.kind.label];
    if (e.hasDurability) parts.add('次数 ${e.durability}');
    final r = e.weaponRank;
    if (r != WeaponRank.none) parts.add('等级 ${r.label}');
    if (e.kind.group == ItemGroup.weapon) {
      parts.add(e.range.label);
    }
    return parts.join(' · ');
  }
}

/// 道具详情页：只读信息 + 可编辑字段。
class ItemDetailPage extends StatefulWidget {
  final ItemCatalog catalog;
  final ItemEntry entry;
  final EditableRom edit;

  const ItemDetailPage({
    super.key,
    required this.catalog,
    required this.entry,
    required this.edit,
  });

  @override
  State<ItemDetailPage> createState() => _ItemDetailPageState();
}

class _ItemDetailPageState extends State<ItemDetailPage> {
  bool get _canEdit => versionSupportsEditing(widget.edit.rom.table.id);

  @override
  Widget build(BuildContext context) {
    final rom = widget.catalog.rom;
    final bonuses = widget.catalog.statBonuses(widget.entry);
    final classes = widget.catalog.usableClasses(widget.entry);
    final entry = widget.entry;
    final fields = itemEditableFieldsFor(fe6: rom.isFe6);
    // 特性位可编辑，顶部信息卡与勾选区都要读实时 buffer，而不是构造时的快照
    final itemAddr = widget.edit.itemAddress(entry.id);
    final liveFlags = ItemFlags.fromRaw(
        widget.edit.buffer.u32(itemAddr + ItemOffsets.attributes));

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.catalog.nameOf(entry.id).trim().isEmpty
              ? '道具 ${entry.id}'
              : widget.catalog.nameOf(entry.id).trim(),
        ),
        actions: [
          if (_canEdit)
            IconButton(
              icon: const Icon(Icons.drive_file_rename_outline),
              tooltip: '改道具名',
              onPressed: () => _rename(itemAddr),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 顶部放图标原件（16×16 放大 3 倍），方便核对是哪个道具
          Center(
            child: ItemIconView(
              rom: rom,
              iconId: entry.iconId,
              size: 72,
              fallback: const SizedBox.shrink(),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row('道具 ID', '${entry.id}'),
                  _row('种类', entry.kind.label),
                  _row('可装备', liveFlags.weapon ? '是' : '否'),
                  if (liveFlags.setFlags.isNotEmpty)
                    _row('特性', liveFlags.setFlags.join(' · ')),
                  if (entry.useEffectId != 0)
                    _row('使用效果', '效果 ${entry.useEffectId}'),
                  if (entry.weaponEffectId != 0)
                    _row('武器特效', entry.weaponEffectLabel),
                  if (entry.weaponExp != 0) _row('武器经验', '${entry.weaponExp}'),
                  if (entry.hasDurability)
                    _row('商店售价', '${entry.durability * entry.unitPrice}'),
                  _row('图标 ID', '${entry.iconId}'),
                  _row('表地址', '0x${entry.address.toRadixString(16)}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          sectionTitle(context, '可编辑字段'),
          FieldGroupCard(
            fields: fields,
            addr: widget.edit.itemAddress(entry.id),
            edit: widget.edit,
            readOnly: !_canEdit,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 12),
          _itemFlagsCard(itemAddr),
          const SizedBox(height: 12),
          if (!bonuses.isEmpty) ...[
            _section(context, '数值加成（只读）'),
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
            _section(context, '克制职业（${classes.length}，只读）'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final cid in classes)
                      ActionChip(
                        label: Text(
                          _className(rom, cid),
                          style: const TextStyle(fontSize: 11),
                        ),
                        visualDensity: VisualDensity.compact,
                        tooltip: cid > 0 && cid < rom.classCount
                            ? '查看职业 $cid'
                            : null,
                        onPressed: cid > 0 && cid < rom.classCount
                            ? () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ClassEditPage(
                                      edit: widget.edit,
                                      index: cid,
                                    ),
                                  ),
                                )
                            : null,
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
    final n = rom.classDisplayName(cid).trim();
    return n.isEmpty ? '职业 $cid' : n;
  }

  Future<void> _rename(int itemAddr) async {
    final textId = widget.edit.buffer.u16(itemAddr + ItemOffsets.nameTextId);
    final changed = await showTextEditDialog(
      context,
      edit: widget.edit,
      textId: textId,
      title: '改道具名',
    );
    if (changed && mounted) setState(() {});
  }

  /// 特性位（IA_*）开关：道具表 `attributes` u32@+8，按位写。
  ///
  /// 与职业 CA_* 区同一套写法：勾选/取消都走 [EditableRom.writeFlagBit]，
  /// 只动这一位、其余位原样保留，改完点右上角「撤销全部」复原。
  /// 把某把武器的特性（连击 / 逆转武器三角 / 无视防御 / 无限耐久…）
  /// 复制给别的武器就靠这里。位定义与不开放 bit0/1/2 的原因见 [ItemFlagToggles]。
  Widget _itemFlagsCard(int itemAddr) {
    final states = ItemFlagToggles.current(widget.edit, itemAddr);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        sectionTitle(context, '特性（IA_* 标志位）'),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Column(
              children: [
                for (var i = 0; i < ItemFlagToggles.toggles.length; i++)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${ItemFlagToggles.toggles[i].$2}  (${ItemFlagToggles.toggles[i].$3})',
                      style: const TextStyle(fontSize: 13),
                    ),
                    value: states[i],
                    onChanged: !_canEdit
                        ? null
                        : (v) {
                            if (v == null) return;
                            if (widget.edit.writeFlagBit(
                              itemAddr + ItemOffsets.attributes,
                              ItemFlagToggles.toggles[i].$1,
                              v,
                            )) {
                              setState(() {});
                            }
                          },
                  ),
              ],
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            '按位写，不影响其它位；勾「无限耐久」= 本道具游戏里永不损坏（同修改器预设），'
            '改完可点右上角「撤销全部」复原。',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ),
      ],
    );
  }

  Widget _section(BuildContext context, String t) => sectionTitle(context, t);

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
        child: Text(
          '说明：\n'
          '「使用次数 / 耐久」就是游戏里显示的 46/46 的分母。\n'
          '「威力」是武器自身的攻击力，游戏里的「攻击」= 角色力量 + 威力。\n'
          '「命中」「重量」「必杀」都是武器自身数值。\n'
          '「单价」是 u16 字段，商店售价 = 单价 × 耐久（铁剑 10×46 = 460）。\n'
          '「射程」存的是两个半字节（高=最小、低=最大），只能在游戏认识的组合里选。\n'
          '「特性」是 item 表 +8 的 u32 attributes，下方「特性（IA_* 标志位）」区可直接勾选，'
          '勾选「无限耐久」即让本道具游戏里永不损坏；「连击两次」「无视防御」等可复制给别的武器。\n'
          '「克制职业」：该武器对列出的职业有额外伤害效果（兵种克制），并非限制谁能装备。\n'
          '「武器等级」是能装备它的最低熟练度等级，括号内是表里的累计值。',
          style: TextStyle(fontSize: 12, color: Colors.blueGrey),
        ),
      );
}
