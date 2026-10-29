import 'package:flutter/material.dart';

import '../core/editable_rom.dart';
import '../core/class_flags.dart';
import '../core/fe_rom.dart';
import '../core/map_sprite.dart';
import '../core/portrait.dart';
import '../core/rom_info.dart';
import '../core/support.dart';
import '../core/tile_image.dart';
import 'portrait_page.dart';
import 'text_edit_dialog.dart';

/// 字段编辑行：± 按钮 + 数值（带档位字母）+ 点击直接输入。
///
/// 角色页、职业页与道具页共用。`steps` 为空的字段走 ±1，不为空时只在合法档位间跳
/// （武器熟练度是累计值，停在档位之间游戏里会显示成上一级）。
///
/// 两种特殊语义：
/// - `u16`：值按 16 位显示与输入（道具的单价）
/// - `nibbles`：值是「高半字节=最小、低半字节=最大」的射程码，
///   ± 只在合法组合间跳，输入也只在合法集合里选
class FieldTile extends StatelessWidget {
  final EditField field;
  final int value;
  final ValueChanged<int> onChanged;
  final bool readOnly;

  const FieldTile({
    super.key,
    required this.field,
    required this.value,
    required this.onChanged,
    this.readOnly = false,
  });

  /// 界面上显示的值。射程码显示成「1-2」这种形式。
  String get _display {
    final rank = field.labelFor(value);
    final base = field.nibbles ? EditField.formatNibble(value) : '$value';
    return rank == null ? base : '$base  $rank';
  }

  /// 下一个合法值（射程码走合法集合，其它走 ±1 / 档位）。
  int? get _up {
    if (field.nibbles) {
      final allowed = field.allowedNibbles;
      for (final v in allowed) {
        if (v > value) return v;
      }
      return null;
    }
    if (field.steps != null) return field.stepUp(value);
    return value < field.max ? value + 1 : null;
  }

  int? get _down {
    if (field.nibbles) {
      final allowed = field.allowedNibbles;
      for (var i = allowed.length - 1; i >= 0; i--) {
        if (allowed[i] < value) return allowed[i];
      }
      return null;
    }
    if (field.steps != null) return field.stepDown(value);
    return value > field.min ? value - 1 : null;
  }

  @override
  Widget build(BuildContext context) {
    final shown = _display;
    if (readOnly) {
      return ListTile(
        dense: true,
        title: Text(field.label),
        trailing: Text(
          shown,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      );
    }
    final up = _up;
    final down = _down;
    return ListTile(
      dense: true,
      title: Text(field.label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline, size: 20),
            onPressed: down != null ? () => onChanged(down) : null,
          ),
          SizedBox(
            width: field.nibbles ? 60 : 76,
            child: Text(
              shown,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline, size: 20),
            onPressed: up != null ? () => onChanged(up) : null,
          ),
        ],
      ),
      onTap: () => _editDirect(context),
    );
  }

  Future<void> _editDirect(BuildContext context) async {
    // 射程码用下拉选，不让人手输——只有游戏认识的组合才有意义。
    if (field.nibbles) {
      final picked = await showDialog<int>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(field.label),
          children: [
            for (final v in field.allowedNibbles)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, v),
                child: Text(
                  '${EditField.formatNibble(v)}'
                  '${v == value ? '（当前）' : ''}',
                ),
              ),
          ],
        ),
      );
      if (picked != null) onChanged(picked);
      return;
    }

    final ctrl = TextEditingController(text: '$value');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(field.label),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.numberWithOptions(signed: true),
          autofocus: true,
          decoration: InputDecoration(
            helperText: field.stepsHint ?? field.rangeHint,
            helperMaxLines: 3,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final parsed = int.tryParse(ctrl.text.trim());
              Navigator.pop(ctx, parsed);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (v != null) onChanged(v);
  }
}

/// 结构地址说明条。
Widget addressNote(int addr) {
  return Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.blue.shade50,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Colors.blue.shade200),
    ),
    child: Text(
      '结构地址 0x${addr.toRadixString(16).padLeft(8, '0').toUpperCase()}　'
      '改动只作用于内存副本，导出时才写文件。',
      style: TextStyle(color: Colors.blue.shade900, fontSize: 12),
    ),
  );
}

/// 一组字段的编辑卡片。
class FieldGroupCard extends StatelessWidget {
  final List<EditField> fields;
  final int addr;
  final EditableRom edit;
  final bool readOnly;
  final VoidCallback onChanged;

  const FieldGroupCard({
    super.key,
    required this.fields,
    required this.addr,
    required this.edit,
    required this.readOnly,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          children: [
            for (final f in fields)
              FieldTile(
                field: f,
                value: edit.readField(addr, f),
                readOnly: readOnly,
                onChanged: (v) {
                  edit.writeField(addr, f, v);
                  onChanged();
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// 小节标题。
Widget sectionTitle(BuildContext context, String text, {Widget? trailing}) {
  return Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 6, left: 4, right: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        if (trailing != null) trailing,
      ],
    ),
  );
}

// ---------- 职业 ----------

/// 职业列表。角色详情页点击职业时也会跳到这里（并直接打开指定职业）。
class ClassListPage extends StatefulWidget {
  final EditableRom edit;
  final int? initialIndex;

  const ClassListPage({super.key, required this.edit, this.initialIndex});

  @override
  State<ClassListPage> createState() => _ClassListPageState();
}

class _ClassListPageState extends State<ClassListPage> {
  late final PortraitReader _reader = PortraitReader(widget.edit.rom);
  late final MapSpriteReader _sprites = MapSpriteReader(widget.edit.rom);
  late List<String> _names = _build();
  String _query = '';

  List<String> _build() {
    final rom = widget.edit.liveRom;
    return [
      for (var i = 0; i < rom.classCount; i++)
        _orPlaceholder(rom.classDisplayName(i)),
    ];
  }

  @override
  void initState() {
    super.initState();
    final start = widget.initialIndex;
    if (start != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open(start));
    }
  }

  @override
  void dispose() {
    _reader.dispose();
    _sprites.dispose();
    super.dispose();
  }

  void _open(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ClassEditPage(edit: widget.edit, index: index),
      ),
    ).then((_) => setState(() => _names = _build()));
  }

  @override
  Widget build(BuildContext context) {
    final rom = widget.edit.liveRom;
    final q = _query.trim();
    final items = <int>[
      for (var i = 0; i < _names.length; i++)
        if (q.isEmpty || _names[i].contains(q)) i,
    ];
    return Scaffold(
      appBar: AppBar(title: Text('职业 (${_names.length})')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              decoration: const InputDecoration(
                isDense: true,
                hintText: '搜索职业名',
                prefixIcon: Icon(Icons.search, size: 20),
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, k) {
                final i = items[k];
                // 优先显示地图小人（这才是地图上跑的那个），取不到再回退地图头像
                final sprite = _sprites.entryForClass(i);
                final img = _sprites.frame(sprite);
                final pid = rom.classPortraitId(i);
                final mapFace =
                    img == null && pid >= 0 ? _reader.mapFaceImage(pid) : null;
                return ListTile(
                  leading: SizedBox(
                    width: 40,
                    height: 40,
                    child: img != null
                        ? PortraitView(
                            tile: img,
                            cacheKey: PortraitImageCache.instance
                                .keyFor(0x4000 + (sprite!.id & 0xFFF), 9),
                            width: 40,
                            height: 40,
                          )
                        : mapFace != null
                            ? PortraitView(
                                tile: mapFace,
                                cacheKey:
                                    PortraitImageCache.instance.keyFor(pid, 7),
                                width: 40,
                                height: 40,
                              )
                            : CircleAvatar(
                                radius: 18,
                                child: Text('$i',
                                    style: const TextStyle(fontSize: 12)),
                              ),
                  ),
                  title: Text(_names[i]),
                  subtitle: Text('ID $i', style: const TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(i),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class ClassEditPage extends StatefulWidget {
  final EditableRom edit;
  final int index;

  const ClassEditPage({super.key, required this.edit, required this.index});

  @override
  State<ClassEditPage> createState() => _ClassEditPageState();
}

class _ClassEditPageState extends State<ClassEditPage> {
  late final int _addr = widget.edit.classAddress(widget.index);
  late final PortraitReader _reader = PortraitReader(widget.edit.rom);
  late final MapSpriteReader _sprites = MapSpriteReader(widget.edit.rom);
  bool get _canEdit => versionSupportsEditing(widget.edit.rom.table.id);

  Future<void> _rename() async {
    final textId = widget.edit.buffer.u16(_addr + ClassOffsets.nameTextId);
    final changed = await showTextEditDialog(
      context,
      edit: widget.edit,
      textId: textId,
      title: '改职业名',
    );
    if (changed && mounted) setState(() {});
  }

  @override
  void dispose() {
    _reader.dispose();
    _sprites.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rom = widget.edit.liveRom;
    final all = classEditableFieldsFor(fe6: rom.isFe6);
    final name = rom.classDisplayName(widget.index).trim();

    final pid = rom.classPortraitId(widget.index);
    final mapFace = pid >= 0 ? _reader.mapFaceImage(pid) : null;
    final classCard = pid >= 0 ? _reader.classCardImage(pid) : null;
    final spriteEntry = _sprites.entryForClass(widget.index);
    final sprite = _sprites.frame(spriteEntry);

    // 字段分四组摆，一屏 30 多行挤在一起看不清
    List<EditField> pick(Set<String> labels) =>
        all.where((f) => labels.contains(f.label)).toList();

    final basic = pick({
      '移动力',
      '体格',
      'HP',
      '力量',
      '技巧',
      '速度',
      '防御',
      '魔防',
    });
    final caps = pick({
      'HP上限',
      '力量上限',
      '技巧上限',
      '速度上限',
      '防御上限',
      '魔防上限',
      '体格上限',
    });
    final growth = pick({
      'HP成长',
      '力量成长',
      '技巧成长',
      '速度成长',
      '防御成长',
      '魔防成长',
    });
    final promo = pick({
      '转职HP加成',
      '转职力量加成',
      '转职技巧加成',
      '转职速度加成',
      '转职防御加成',
      '转职魔防加成',
    });
    final ranks = all.where((f) => f.label.endsWith('熟练度')).toList();

    final groups = <(String, List<EditField>)>[
      ('基础值', basic),
      ('能力上限', caps),
      ('成长率', growth),
      ('转职加成', promo),
      ('武器熟练度', ranks),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(name.isEmpty ? '职业 ${widget.index}' : name),
        actions: [
          if (_canEdit)
            IconButton(
              icon: const Icon(Icons.drive_file_rename_outline),
              tooltip: '改职业名',
              onPressed: _rename,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _classImageHeader(mapFace, classCard, pid, sprite, spriteEntry),
          for (final (title, fields) in groups)
            if (fields.isNotEmpty) ...[
              sectionTitle(context, title),
              FieldGroupCard(
                fields: fields,
                addr: _addr,
                edit: widget.edit,
                readOnly: !_canEdit,
                onChanged: () => setState(() {}),
              ),
            ],
          _classFlagsCard(),
          const SizedBox(height: 12),
          addressNote(_addr),
        ],
      ),
    );
  }

  /// 特性位（CA_*）开关：职业表 `attributes` u32@40，按位写。
  ///
  /// 位含义与写入口径见 [ClassFlags]（反编译 CA_* 枚举 + 真实 ROM 逐位核对）。
  Widget _classFlagsCard() {
    if (!ClassFlags.supported(widget.edit.rom.table.classDataSize)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          '本版本职业条目的特性位位置未验证（FE6 的 +40 是武器熟练度区），'
          '特性开关不开放。',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      );
    }
    final states = ClassFlags.current(widget.edit, _addr);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        sectionTitle(context, '特性（CA_* 标志位）'),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Column(
              children: [
                for (var i = 0; i < ClassFlags.toggles.length; i++)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${ClassFlags.toggles[i].$2}  (${ClassFlags.toggles[i].$3})',
                      style: const TextStyle(fontSize: 13),
                    ),
                    value: states[i],
                    onChanged: (v) {
                      if (!_canEdit || v == null) return;
                      if (widget.edit.writeFlagBit(
                        _addr + ClassOffsets.attributes,
                        ClassFlags.toggles[i].$1,
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
            '按位写，不影响其它位；改完可点右上角「撤销全部」复原。',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ),
      ],
    );
  }

  /// 职业顶部图区：地图小人（地图上实际跑的那个）、地图头像、职业卡。
  /// 三者都没有时显示占位说明。
  Widget _classImageHeader(TileImage? mapFace, TileImage? card, int pid,
      TileImage? sprite, MapSpriteEntry? spriteEntry) {
    if (sprite == null && mapFace == null && card == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text('此职业没有地图小人 / 地图头像 / 职业卡（肖像 ID $pid）',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 24,
        runSpacing: 12,
        children: [
          if (sprite != null)
            Column(
              children: [
                // 地图小人多为 16x16，放大到 80 便于看细节（像素风邻近缩放）
                PortraitView(
                  tile: sprite,
                  cacheKey: PortraitImageCache.instance
                      .keyFor(0x4000 + (spriteEntry!.id & 0xFFF), 9),
                  width: 80,
                  height: (sprite.height * 80 / sprite.width).toDouble(),
                ),
                Text('地图小人 ${sprite.width}×${sprite.height}',
                    style: const TextStyle(fontSize: 11)),
              ],
            ),
          if (mapFace != null)
            Column(
              children: [
                PortraitView(
                  tile: mapFace,
                  cacheKey: PortraitImageCache.instance.keyFor(pid, 7),
                  width: 80,
                  height: 80,
                ),
                Text('地图头像', style: const TextStyle(fontSize: 11)),
              ],
            ),
          if (card != null)
            Column(
              children: [
                PortraitView(
                  tile: card,
                  cacheKey: PortraitImageCache.instance.keyFor(pid, 8),
                  width: 100,
                  height: 100,
                ),
                Text('职业卡', style: const TextStyle(fontSize: 11)),
              ],
            ),
        ],
      ),
    );
  }
}

String _orPlaceholder(String s) {
  final t = s.trim();
  return t.isEmpty ? '（未命名）' : t;
}

// ---------- 角色 ----------

class UnitListPage extends StatefulWidget {
  final EditableRom edit;

  const UnitListPage({super.key, required this.edit});

  @override
  State<UnitListPage> createState() => _UnitListPageState();
}

class _UnitListPageState extends State<UnitListPage> {
  late final PortraitReader _reader = PortraitReader(widget.edit.rom);
  late List<String> _names = _build();
  String _query = '';

  List<String> _build() {
    final rom = widget.edit.liveRom;
    // ID 恒等于表内偏移：不跳过空条目，否则改版作者按 ID 找数据会错位。
    return [
      for (var i = 0; i < rom.unitCount; i++)
        _orPlaceholder(rom.unitDisplayName(i)),
    ];
  }

  @override
  void dispose() {
    _reader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rom = widget.edit.liveRom;
    final items = <int>[
      for (var i = 0; i < _names.length; i++)
        if (_query.isEmpty || _names[i].contains(_query)) i,
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text('角色 (${_names.length})'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              decoration: const InputDecoration(
                isDense: true,
                hintText: '搜索角色名',
                prefixIcon: Icon(Icons.search, size: 20),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
        ),
      ),
      body: ListView.separated(
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, k) {
          final i = items[k];
          final cid = unitClassId(rom, i);
          final cname = cid >= 0 ? rom.classDisplayName(cid).trim() : '';
          final face = portraitFaceOf(rom, i);
          final faceId = _reader.faceToPortraitId(face);
          final img = faceId == null ? null : _reader.faceImage(faceId);
          return ListTile(
            leading: SizedBox(
              width: 40,
              height: 40,
              child: img == null
                  ? CircleAvatar(
                      radius: 18,
                      child: Text('${i + 1}',
                          style: const TextStyle(fontSize: 12)),
                    )
                  : PortraitView(
                      tile: img,
                      cacheKey: PortraitImageCache.instance.keyFor(faceId!, 1),
                      width: 40,
                      height: 40,
                    ),
            ),
            title: Text(_names[i]),
            subtitle: Text(
              'ID $i · 职业 ${cname.isEmpty ? (cid >= 0 ? '$cid' : '—') : cname}',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => UnitEditPage(
                  edit: widget.edit,
                  index: i,
                  reader: _reader,
                ),
              ),
            ).then((_) => setState(() => _names = _build())),
          );
        },
      ),
    );
  }
}

/// 单位表 +5 是该单位的职业 ID。
int unitClassId(FeRom rom, int index) => rom.unitClassId(index);

/// 单位表 +6 是 u16 的肖像 face 值。
int portraitFaceOf(FeRom rom, int index) {
  final base = rom.unitBase;
  if (base < 0) return -1;
  final at = base + index * rom.table.unitDataSize;
  if (at + 8 > rom.length) return -1;
  return FeRom.u16(rom.data, at + 6);
}

/// 单位详情：肖像 + 职业 + 数值，三者放同一页。
class UnitEditPage extends StatefulWidget {
  final EditableRom edit;
  final int index;
  final PortraitReader? reader;

  const UnitEditPage({
    super.key,
    required this.edit,
    required this.index,
    this.reader,
  });

  @override
  State<UnitEditPage> createState() => _UnitEditPageState();
}

class _UnitEditPageState extends State<UnitEditPage> {
  late final PortraitReader _reader =
      widget.reader ?? PortraitReader(widget.edit.rom);
  late final bool _ownsReader = widget.reader == null;
  late final int _addr = widget.edit.unitAddress(widget.index);
  bool get _canEdit => versionSupportsEditing(widget.edit.rom.table.id);

  Future<void> _rename() async {
    final textId = widget.edit.buffer.u16(_addr + UnitOffsets.nameTextId);
    final changed = await showTextEditDialog(
      context,
      edit: widget.edit,
      textId: textId,
      title: '改角色名',
    );
    if (changed && mounted) setState(() {});
  }

  @override
  void dispose() {
    if (_ownsReader) _reader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rom = widget.edit.liveRom;
    final all = unitEditableFieldsFor(fe6: rom.isFe6);
    final stats = all.where((f) => !f.label.endsWith('熟练度')).toList();
    final ranks = all.where((f) => f.label.endsWith('熟练度')).toList();
    final supportTable = SupportTable(rom);
    final affinity = supportTable.affinityOf(widget.index);
    final supports = supportTable.relationsOf(widget.index);

    final face = portraitFaceOf(rom, widget.index);
    final portraitId = face >= 0 ? _reader.faceToPortraitId(face) : null;
    final faceImg = portraitId == null ? null : _reader.faceImage(portraitId);

    final cid = unitClassId(rom, widget.index);
    final cname = cid >= 0 ? rom.classDisplayName(cid).trim() : '';
    final name = rom.unitDisplayName(widget.index).trim();

    return Scaffold(
      appBar: AppBar(
        title: Text(name.isEmpty ? '角色 ${widget.index}' : name),
        actions: [
          if (_canEdit)
            IconButton(
              icon: const Icon(Icons.drive_file_rename_outline),
              tooltip: '改角色名',
              onPressed: _rename,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _UnitHeader(
            face: faceImg,
            cacheKey: PortraitImageCache.instance.keyFor(portraitId ?? -1, 2),
            faceId: portraitId,
            className: cname,
            classId: cid,
            canOpenClass: cid > 0 && cid < rom.classCount,
            onOpenClass: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ClassEditPage(edit: widget.edit, index: cid),
                ),
              );
            },
            onOpenPortrait: portraitId == null
                ? null
                : () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PortraitDetailPage(
                          reader: _reader,
                          id: portraitId,
                          name: _reader.nameFor(portraitId),
                        ),
                      ),
                    );
                  },
          ),
          sectionTitle(context, '基础数值 / 成长率'),
          FieldGroupCard(
            fields: stats,
            addr: _addr,
            edit: widget.edit,
            readOnly: !_canEdit,
            onChanged: () => setState(() {}),
          ),
          sectionTitle(context, '属性 / 支援'),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const SizedBox(
                        width: 72,
                        child: Text('属性', style: TextStyle(color: Colors.grey)),
                      ),
                      Text(
                        affinity.label,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  if (supports.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        '无支援数据',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    )
                  else ...[
                    const SizedBox(height: 8),
                    for (var slot = 0; slot < supports.length; slot++)
                      _SupportRow(
                        edit: widget.edit,
                        unitIndex: widget.index,
                        slot: slot,
                        nameOf: supportTable.nameOf,
                        readOnly: !_canEdit,
                        onChanged: () => setState(() {}),
                        onOpenPartner: (charId) {
                          final idx = charId - 1;
                          if (idx < 0 || idx >= widget.edit.rom.unitCount) {
                            return;
                          }
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => UnitEditPage(
                                edit: widget.edit,
                                index: idx,
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ],
              ),
            ),
          ),
          sectionTitle(context, '武器熟练度'),
          FieldGroupCard(
            fields: ranks,
            addr: _addr,
            edit: widget.edit,
            readOnly: !_canEdit,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 12),
          addressNote(_addr),
        ],
      ),
    );
  }
}

/// 一条支援关系：对象名 + 初始值 + 每回合增长，都可编辑。
class _SupportRow extends StatelessWidget {
  final EditableRom edit;
  final int unitIndex;
  final int slot;
  final String Function(int charId) nameOf;
  final bool readOnly;
  final VoidCallback onChanged;
  final ValueChanged<int>? onOpenPartner;

  const _SupportRow({
    required this.edit,
    required this.unitIndex,
    required this.slot,
    required this.nameOf,
    required this.readOnly,
    required this.onChanged,
    this.onOpenPartner,
  });

  /// 角色 ID 上界：单位表条目数（表内偏移恒等于 ID）。
  int get _maxCharId => edit.rom.unitCount;

  Future<void> _pickPartner(BuildContext context, int current) async {
    final ctrl = TextEditingController(text: '$current');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('支援对象角色 ID'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.numberWithOptions(signed: true),
          autofocus: true,
          decoration: InputDecoration(
            helperText: '角色 ID 1 ~ $_maxCharId',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final parsed = int.tryParse(ctrl.text.trim());
              Navigator.pop(ctx, parsed);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (v != null && !readOnly) {
      edit.writeSupport(unitIndex, slot, SupportPart.partner, v);
      onChanged();
    }
  }

  Future<void> _editValue(
    BuildContext context,
    SupportPart part,
    int current,
  ) async {
    if (readOnly) return;
    final ctrl = TextEditingController(text: '$current');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${part.label}（0 ~ 255）'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.numberWithOptions(signed: true),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final parsed = int.tryParse(ctrl.text.trim());
              Navigator.pop(ctx, parsed);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (v != null) {
      edit.writeSupport(unitIndex, slot, part, v);
      onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final partner = edit.readSupport(unitIndex, slot, SupportPart.partner);
    final base = edit.readSupport(unitIndex, slot, SupportPart.base);
    final growth = edit.readSupport(unitIndex, slot, SupportPart.growth);
    final label = partner >= 0 ? nameOf(partner) : '（空槽位）';
    final canOpen =
        onOpenPartner != null && partner > 0 && partner <= _maxCharId;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: readOnly ? null : () => _pickPartner(context, partner),
                  child: Row(
                    children: [
                      Expanded(child: Text(label)),
                      Text(
                        'ID $partner',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),
              if (canOpen)
                IconButton(
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  tooltip: '查看该角色',
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () => onOpenPartner!(partner),
                ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: readOnly
                      ? null
                      : () => _editValue(context, SupportPart.base, base),
                  child: _SupportValueCell('初始值', base),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  onTap: readOnly
                      ? null
                      : () => _editValue(context, SupportPart.growth, growth),
                  child: _SupportValueCell('每回合增长', growth),
                ),
              ),
            ],
          ),
          const Divider(height: 12),
        ],
      ),
    );
  }
}

class _SupportValueCell extends StatelessWidget {
  final String label;
  final int value;

  const _SupportValueCell(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        Text(
          '$value',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}

class _UnitHeader extends StatelessWidget {
  final TileImage? face;
  final int cacheKey;
  final int? faceId;
  final String className;
  final int classId;
  final bool canOpenClass;
  final VoidCallback onOpenClass;
  final VoidCallback? onOpenPortrait;

  const _UnitHeader({
    required this.face,
    required this.cacheKey,
    required this.faceId,
    required this.className,
    required this.classId,
    required this.canOpenClass,
    required this.onOpenClass,
    this.onOpenPortrait,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: onOpenPortrait,
              child: SizedBox(
                width: 96,
                height: 80,
                child: face == null
                    ? const Center(
                        child: Icon(Icons.image_not_supported,
                            size: 28, color: Colors.grey),
                      )
                    : PortraitView(
                        tile: face!,
                        cacheKey: cacheKey,
                        width: 96,
                        height: 80,
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    className.isEmpty ? '（职业未识别）' : className,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '职业 ID $classId',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: canOpenClass ? onOpenClass : null,
                        icon: const Icon(Icons.shield, size: 16),
                        label: const Text('查看职业'),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: onOpenPortrait,
                        icon: const Icon(Icons.face, size: 16),
                        label: Text(faceId == null ? '无肖像' : '肖像 $faceId'),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
