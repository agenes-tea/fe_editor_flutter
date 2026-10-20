import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'core/editable_rom.dart';
import 'core/fe_rom.dart';
import 'core/file_picker_service.dart';
import 'core/hex_view.dart';
import 'core/patch_format.dart';
import 'core/patch_library.dart';
import 'core/text_browser.dart';
import 'core/text_codec.dart';
import 'core/zh_table.dart';
import 'core/zh_tables_data.dart';
import 'ui/item_page.dart';
import 'ui/portrait_page.dart';
import 'ui/table_address_page.dart';

void main() {
  runApp(const FeEditorApp());
}

class FeEditorApp extends StatelessWidget {
  const FeEditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '火纹改版工具',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E5C8A)),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _fileName;
  EditableRom? _edit;
  String? _error;

  FeRom? get _rom => _edit?.rom;

  Future<void> _pickRom() async {
    setState(() => _error = null);
    try {
      final path = await pickRomFile();
      if (path == null) return;
      final data = await File(path).readAsBytes();
      await _load(data, path.split('/').last);
    } catch (e) {
      setState(() => _error = '打开失败：$e');
    }
  }

  Future<void> _load(Uint8List data, String name) async {
    final table = FeRom.detectTable(data);
    if (table == null) {
      final code = data.length >= 0xB0
          ? String.fromCharCodes(data.sublist(0xAC, 0xB0))
          : '????';
      setState(() {
        _edit = null;
        _error = '无法识别此 ROM（game code: $code）。\n'
            '支持：封印之剑 FE6、烈火之剑 FE7（日/美）、圣魔之光石 FE8（日/美）。';
      });
      return;
    }
    final edit = EditableRom.open(data, table);
    await _maybeAttachZhTable(edit);
    setState(() {
      _edit = edit;
      _fileName = name;
      _error = null;
    });
  }

  /// 汉化版若是「Huffman + 中文码表」（如狼组封印之剑），
  /// 标准解码会失败；这里自动挂载对应 .tbl 并切换渲染方式。
  Future<void> _maybeAttachZhTable(EditableRom edit) async {
    final rom = edit.rom;
    if (rom.textEncoding != FeTextEncoding.unknown) return;
    final id = rom.table.id;
    final Map<int, String>? embedded = switch (id) {
      'FE6' => zhTblFE6,
      'FE7J' || 'FE7U' => zhTblFE7,
      'FE8J' || 'FE8U' => zhTblFE8,
      _ => null,
    };
    if (embedded != null) {
      final tbl = ZhTable(embedded);
      rom.zhTable = tbl;
      if (rom.zhTableMatchRatio() >= 0.5) return;
      rom.zhTable = null;
    }
    // 兜底：尝试 assets（便于以后换表而不重新编译）
    try {
      final tbl = await ZhTable.loadFromAssets('assets/tbl/$id.tbl');
      if (tbl == null) return;
      rom.zhTable = tbl;
      if (rom.zhTableMatchRatio() >= 0.5) return;
      rom.zhTable = null;
    } catch (_) {
      // 没有码表，保持 unknown
    }
  }

  @override
  Widget build(BuildContext context) {
    final rom = _rom;
    return Scaffold(
      appBar: AppBar(
        title: const Text('火纹改版工具'),
        actions: [
          if (rom != null)
            IconButton(
              tooltip: '导出',
              icon: const Icon(Icons.save_alt),
              onPressed: _showExportSheet,
            ),
          if (rom != null)
            IconButton(
              tooltip: '关闭 ROM',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                _edit = null;
                _fileName = null;
              }),
            ),
        ],
      ),
      body: rom == null ? _buildEmpty() : _buildLoaded(),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.videogame_asset, size: 96, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            const Text('选择一个 GBA ROM',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              '支持 封印之剑（FE6）、烈火之剑（FE7 日/美）、\n圣魔之光石（FE8 日/美）',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _pickRom,
              icon: const Icon(Icons.folder_open),
              label: const Text('选择 ROM 文件'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Text(_error!, style: TextStyle(color: Colors.red.shade900)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLoaded() {
    final edit = _edit!;
    final rom = edit.rom;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_fileName ?? '',
                    style: const TextStyle(fontSize: 13, color: Colors.grey)),
                const SizedBox(height: 8),
                Text(rom.table.name,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                _kv('游戏代码', rom.gameCode),
                _kv('头部标题', rom.headerTitle),
                _kv('ROM 大小', '${(rom.length / 1048576).toStringAsFixed(1)} MB'),
                _kv('文本解码', _textStatus(rom)),
                if (edit.hasChanges)
                  _kv('已修改', '${edit.changedByteCount} 字节'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (!rom.textEncodingHealthy && rom.zhTable == null)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.shade300),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber, color: Colors.orange.shade800, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '未能识别此 ROM 的文本编码（汉化/改版重写过文本引擎），'
                    '角色和职业名会显示异常。数值字段不受影响。'
                    '\n检测详情：$_textDetail',
                    style: TextStyle(color: Colors.orange.shade900, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        if (!versionSupportsEditing(rom.table.id))
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blueGrey.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blueGrey.shade200),
            ),
            child: Text(
              '当前版本（${rom.table.id}）的字段级编辑暂未开放，'
              '可使用只读浏览、十六进制编辑与补丁库。',
              style: TextStyle(color: Colors.blueGrey.shade800, fontSize: 13),
            ),
          ),
        _section('游戏数据', [
          _tile('角色', Icons.person, '单位表：等级 / 属性 / 成长率（可编辑）', () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => UnitListPage(edit: edit)),
            ).then((_) => setState(() {}));
          }),
          _tile('职业', Icons.shield, '职业表：移动 / 体格 / 基础值 / 成长率（可编辑）', () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ClassListPage(edit: edit)),
            ).then((_) => setState(() {}));
          }),
          _tile('道具', Icons.inventory_2, '按种类分组：剑枪斧弓 / 魔法 / 消耗品 / 特殊', () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ItemListPage(edit: edit)),
            );
          }),
        ]),
        _section('素材预览', [
          _tile('肖像', Icons.face, '全部角色肖像 / 地图头像 / 职业卡（只读）', () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => PortraitListPage(edit: edit)),
            );
          }),
          _tile('文本', Icons.article, 'ROM 内全部对话与字符串（含中文）', () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => TextBrowserPage(edit: edit)),
            );
          }),
        ]),
        _section('工具', [
          _tile('补丁库', Icons.extension, 'FEBuilderGBA 社区补丁，一键安装', () async {
            final changed = await Navigator.push<bool>(
              context,
              MaterialPageRoute(builder: (_) => PatchListPage(edit: edit)),
            );
            if (changed == true && mounted) setState(() {});
          }),
          _tile('十六进制', Icons.code, '按地址查看与修改任意字节、搜索', () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => HexEditorPage(edit: edit)),
            ).then((_) => setState(() {}));
          }),
          _tile('空位搜索', Icons.search, '查找连续空白区域', () async {
            final result = await Navigator.push<({int offset, int length})>(
              context,
              MaterialPageRoute(builder: (_) => FreeSpacePage(edit: edit)),
            );
            if (result != null && mounted) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => HexEditorPage(edit: edit, initialOffset: result.offset),
                ),
              ).then((_) => setState(() {}));
            }
          }),
          _tile('表地址', Icons.table_chart, '手动指定各数据表的基址（改版兼容）', () async {
            final changed = await Navigator.push<bool>(
              context,
              MaterialPageRoute(builder: (_) => TableAddressPage(edit: edit)),
            );
            if (changed == true && mounted) setState(() {});
          }),
        ]),
      ],
    );
  }

  String get _textDetail {
    final rom = _rom;
    if (rom == null) return '';
    final ratio = rom.zhTableMatchRatio().toStringAsFixed(2);
    return 'Huffman/SJIS=${rom.sjisSampleRatio().toStringAsFixed(2)}、'
        '明文GBK=${rom.gbkSampleRatio().toStringAsFixed(2)}、'
        '码表=$ratio';
  }

  String _textStatus(FeRom rom) {
    if (!rom.textAvailable) return '不可用';
    switch (rom.textEncoding) {
      case FeTextEncoding.huffmanSjis:
        return '正常（日文）';
      case FeTextEncoding.plainGbk:
        return '正常（中文·明文）';
      case FeTextEncoding.huffmanZhTbl:
        return '正常（中文·码表 ${rom.zhTable?.table.length ?? 0} 字）';
      case FeTextEncoding.unknown:
        if (rom.zhTable != null) return '正常（中文·码表 ${rom.zhTable!.table.length} 字）';
        return '异常（改版文本引擎）';
    }
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(width: 80, child: Text(k, style: const TextStyle(color: Colors.grey))),
            Expanded(child: Text(v)),
          ],
        ),
      );

  /// 主页分区：标题 + 网格。
  Widget _section(String title, List<Widget> tiles) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
                letterSpacing: 1.2,
              ),
            ),
          ),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 0.78,
            children: tiles,
          ),
        ],
      ),
    );
  }

  /// 网格单元：图标 + 标题 + 一行说明。
  Widget _tile(String title, IconData icon, String sub, VoidCallback onTap) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 30),
              const SizedBox(height: 8),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 4),
              Text(
                sub,
                maxLines: 3,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10.5, color: Colors.grey, height: 1.3),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showExportSheet() {
    final edit = _edit!;
    if (!edit.hasChanges) {
      _toast('还没有任何修改，导出的是未改动的内容');
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.memory),
              title: const Text('保存修改后的 GBA'),
              subtitle: Text('${(edit.data.length / 1048576).toStringAsFixed(1)} MB'),
              onTap: () {
                Navigator.pop(ctx);
                _exportGba(edit);
              },
            ),
            ListTile(
              leading: const Icon(Icons.description),
              title: const Text('导出 UPS 补丁'),
              subtitle: const Text('推荐，体积小且不限地址范围'),
              onTap: () {
                Navigator.pop(ctx);
                _exportPatch(edit, ups: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('导出 IPS 补丁'),
              subtitle: const Text('仅支持 16MB 以内地址'),
              onTap: () {
                Navigator.pop(ctx);
                _exportPatch(edit, ups: false);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportGba(EditableRom edit) async {
    final base = (_fileName ?? 'rom.gba').replaceAll(RegExp(r'\.gba$', caseSensitive: false), '');
    final name = '${base}_modified.gba';
    try {
      final saved = await saveFile(name, edit.data);
      if (!mounted) return;
      _toast(saved == null ? '已取消' : '已保存 $name');
    } catch (e) {
      if (!mounted) return;
      _toast('保存失败：$e');
    }
  }

  Future<void> _exportPatch(EditableRom edit, {required bool ups}) async {
    final base = (_fileName ?? 'rom.gba').replaceAll(RegExp(r'\.gba$', caseSensitive: false), '');
    final out = edit.buildOutput();
    if (ups) {
      final patch = UpsPatch.create(edit.original, out);
      final ok = await _savePatch('${base}_modified.ups', patch);
      if (!mounted) return;
      _toast(ok == null ? '已取消' : '已导出 UPS（${_size(patch.length)}）');
      return;
    }
    final patch = IpsPatch.create(edit.original, out);
    if (patch == null) {
      if (!mounted) return;
      _toast('修改超出 IPS 可表达范围（0xFFFFFF 之后），请改用 UPS');
      return;
    }
    final ok = await _savePatch('${base}_modified.ips', patch);
    if (!mounted) return;
    _toast(ok == null ? '已取消' : '已导出 IPS（${_size(patch.length)}）');
  }

  Future<String?> _savePatch(String name, Uint8List bytes) async {
    try {
      return await saveFile(name, bytes);
    } catch (e) {
      if (mounted) _toast('导出失败：$e');
      return null;
    }
  }

  String _size(int bytes) =>
      bytes < 1024 ? '$bytes B' : '${(bytes / 1024).toStringAsFixed(1)} KB';

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }
}

// ---------- 通用列表 ----------

class _Row {
  final int index;
  final String name;
  _Row(this.index, this.name);
}

// ---------- 角色 ----------

class UnitListPage extends StatefulWidget {
  final EditableRom edit;
  const UnitListPage({super.key, required this.edit});

  @override
  State<UnitListPage> createState() => _UnitListPageState();
}

class _UnitListPageState extends State<UnitListPage> {
  late List<_Row> _items = _build();

  List<_Row> _build() {
    final rom = widget.edit.rom;
    final items = <_Row>[];
    // ID 恒等于表内偏移：不跳过空条目，否则改版作者按 ID 找数据会错位。
    for (var i = 0; i < rom.unitCount; i++) {
      final name = rom.unitName(i).trim();
      items.add(_Row(i, name.isEmpty ? '（未命名）' : name));
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('角色 (${_items.length})')),
      body: ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, idx) {
          final r = _items[idx];
          return ListTile(
            leading: CircleAvatar(child: Text('${r.index + 1}')),
            title: Text(r.name),
            subtitle: Text('ID ${r.index}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => UnitEditPage(edit: widget.edit, index: r.index),
              ),
            ).then((_) => setState(() => _items = _build())),
          );
        },
      ),
    );
  }
}

class UnitEditPage extends StatefulWidget {
  final EditableRom edit;
  final int index;
  const UnitEditPage({super.key, required this.edit, required this.index});

  @override
  State<UnitEditPage> createState() => _UnitEditPageState();
}

class _UnitEditPageState extends State<UnitEditPage> {
  late final int _addr = widget.edit.unitAddress(widget.index);
  bool get _canEdit => versionSupportsEditing(widget.edit.rom.table.id);

  @override
  Widget build(BuildContext context) {
    final edit = widget.edit;
    final rom = edit.rom;
    return Scaffold(
      appBar: AppBar(title: Text(rom.unitName(widget.index))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  for (final f in unitEditableFields)
                    _FieldTile(
                      field: f,
                      value: edit.readField(_addr, f),
                      readOnly: !_canEdit,
                      onChanged: (v) {
                        setState(() => edit.writeField(_addr, f, v));
                      },
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _addressNote(_addr),
        ],
      ),
    );
  }
}

// ---------- 职业 ----------

class ClassListPage extends StatefulWidget {
  final EditableRom edit;
  const ClassListPage({super.key, required this.edit});

  @override
  State<ClassListPage> createState() => _ClassListPageState();
}

class _ClassListPageState extends State<ClassListPage> {
  late List<_Row> _items = _build();

  List<_Row> _build() {
    final rom = widget.edit.rom;
    final items = <_Row>[];
    for (var i = 0; i < rom.classCount; i++) {
      final name = rom.className(i).trim();
      items.add(_Row(i, name.isEmpty ? '（未命名）' : name));
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('职业 (${_items.length})')),
      body: ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, idx) {
          final r = _items[idx];
          return ListTile(
            leading: CircleAvatar(child: Text('${r.index}')),
            title: Text(r.name),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ClassEditPage(edit: widget.edit, index: r.index),
              ),
            ).then((_) => setState(() => _items = _build())),
          );
        },
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
  bool get _canEdit => versionSupportsEditing(widget.edit.rom.table.id);

  @override
  Widget build(BuildContext context) {
    final edit = widget.edit;
    final rom = edit.rom;
    return Scaffold(
      appBar: AppBar(title: Text(rom.className(widget.index))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  for (final f in classEditableFields)
                    _FieldTile(
                      field: f,
                      value: edit.readField(_addr, f),
                      readOnly: !_canEdit,
                      onChanged: (v) {
                        setState(() => edit.writeField(_addr, f, v));
                      },
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _addressNote(_addr),
        ],
      ),
    );
  }
}

// ---------- 字段行 ----------

class _FieldTile extends StatelessWidget {
  final EditField field;
  final int value;
  final ValueChanged<int> onChanged;
  final bool readOnly;

  const _FieldTile({
    required this.field,
    required this.value,
    required this.onChanged,
    this.readOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    if (readOnly) {
      return ListTile(
        dense: true,
        title: Text(field.label),
        trailing: Text(
          '$value',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      );
    }
    return ListTile(
      dense: true,
      title: Text(field.label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline, size: 20),
            onPressed: value > field.min ? () => onChanged(value - 1) : null,
          ),
          SizedBox(
            width: 44,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline, size: 20),
            onPressed: value < field.max ? () => onChanged(value + 1) : null,
          ),
        ],
      ),
      onTap: () => _editDirect(context),
    );
  }

  Future<void> _editDirect(BuildContext context) async {
    final ctrl = TextEditingController(text: '$value');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(field.label),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            helperText: '范围 ${field.min} ~ ${field.max}',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
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

Widget _addressNote(int addr) {
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

// ---------- 十六进制编辑器 ----------

class HexEditorPage extends StatefulWidget {
  final EditableRom edit;
  final int initialOffset;
  const HexEditorPage({super.key, required this.edit, this.initialOffset = 0});

  @override
  State<HexEditorPage> createState() => _HexEditorPageState();
}

class _HexEditorPageState extends State<HexEditorPage> {
  static const double _rowHeight = 22;
  late final HexView _view = HexView(widget.edit.buffer);
  late final ScrollController _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  int _highlight = -1;

  @override
  void initState() {
    super.initState();
    if (widget.initialOffset > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpTo(widget.initialOffset));
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _jumpTo(int offset) {
    final row = offset ~/ HexView.bytesPerRow;
    final target = row * _rowHeight;
    if (_scroll.hasClients) {
      _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
    }
    setState(() => _highlight = row);
  }

  Future<void> _gotoDialog() async {
    final ctrl = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('跳转到地址'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '十六进制，如 0xC4C158'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    if (input == null) return;
    final cleaned = input.trim().replaceAll(RegExp(r'^0[xX]'), '').replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    final v = int.tryParse(cleaned, radix: 16);
    if (v == null || v < 0 || v >= _view.buffer.length) {
      _toast('地址无效');
      return;
    }
    _jumpTo(v);
  }

  void _search() {
    final pattern = parseHex(_searchCtrl.text);
    if (pattern == null) {
      _toast('请输入偶数位的十六进制，如 12 34 AB');
      return;
    }
    final hits = _view.search(pattern);
    if (hits.isEmpty) {
      _toast('未找到');
      return;
    }
    _jumpTo(hits.first);
    _toast('找到 ${hits.length} 处，已跳到第一处');
  }

  Future<void> _editByte(int offset) async {
    final current = _view.buffer.u8(offset);
    final ctrl = TextEditingController(
      text: current.toRadixString(16).padLeft(2, '0').toUpperCase(),
    );
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('修改 0x${offset.toRadixString(16).toUpperCase()}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            helperText: '两位十六进制，00 ~ FF',
            prefixText: '0x',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (v == null) return;
    final parsed = int.tryParse(v.trim().replaceAll(RegExp(r'^0[xX]'), ''), radix: 16);
    if (parsed == null || parsed < 0 || parsed > 0xFF) {
      _toast('请输入 00 ~ FF');
      return;
    }
    final before = _view.buffer.u8(offset);
    if (before == parsed) return;
    _view.buffer.writeU8(offset, parsed);
    widget.edit.edits.add(ByteEdit(offset, before, parsed));
    setState(() {});
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('十六进制编辑器'),
        actions: [
          IconButton(
            tooltip: '跳转地址',
            icon: const Icon(Icons.my_location),
            onPressed: _gotoDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '搜索十六进制，如 12 34 AB',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: _search,
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemExtent: _rowHeight,
              itemCount: _view.rowCount,
              itemBuilder: (_, row) {
                final isHit = row == _highlight;
                return GestureDetector(
                  onTap: () => _jumpTo(_view.rowOffset(row)),
                  child: Container(
                    color: isHit ? theme.colorScheme.primaryContainer : null,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        Text(
                          _view.offsetLabel(row),
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _view.hexAt(row),
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                          ),
                        ),
                        Text(
                          _view.asciiAt(row),
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            color: theme.colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '点击行跳转；要精确改某个字节，输入地址后用下方按钮',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                  ),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final ctrl = TextEditingController(
                      text: _highlight >= 0
                          ? _view.rowOffset(_highlight).toRadixString(16).toUpperCase()
                          : '',
                    );
                    final input = await showDialog<String>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('改字节'),
                        content: TextField(
                          controller: ctrl,
                          autofocus: true,
                          decoration: const InputDecoration(hintText: '地址（十六进制）'),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, ctrl.text),
                            child: const Text('下一步'),
                          ),
                        ],
                      ),
                    );
                    if (input == null) return;
                    final cleaned = input
                        .trim()
                        .replaceAll(RegExp(r'^0[xX]'), '')
                        .replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
                    final addr = int.tryParse(cleaned, radix: 16);
                    if (addr == null || addr < 0 || addr >= _view.buffer.length) {
                      _toast('地址无效');
                      return;
                    }
                    await _editByte(addr);
                  },
                  icon: const Icon(Icons.edit, size: 16),
                  label: const Text('改字节'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- 空位搜索 ----------

class _FreeHit {
  final int offset;
  final int length;
  const _FreeHit(this.offset, this.length);
}

class FreeSpacePage extends StatefulWidget {
  final EditableRom edit;
  const FreeSpacePage({super.key, required this.edit});

  @override
  State<FreeSpacePage> createState() => _FreeSpacePageState();
}

class _FreeSpacePageState extends State<FreeSpacePage> {
  final _minCtrl = TextEditingController(text: '1024');
  bool _fillFF = true;
  List<_FreeHit> _hits = [];
  bool _searched = false;

  @override
  void dispose() {
    _minCtrl.dispose();
    super.dispose();
  }

  void _run() {
    final minLen = int.tryParse(_minCtrl.text.trim()) ?? 1024;
    if (minLen <= 0) {
      _toast('最小长度必须大于 0');
      return;
    }
    final view = HexView(widget.edit.buffer);
    final hits = <_FreeHit>[];
    var from = 0;
    final fill = _fillFF ? 0xFF : 0x00;
    while (from < view.buffer.length && hits.length < 300) {
      final run = view.findFreeRun(from, fill: fill, minLength: minLen);
      if (run == null) break;
      hits.add(_FreeHit(run.offset, run.length));
      from = run.offset + run.length;
    }
    setState(() {
      _hits = hits;
      _searched = true;
    });
    if (hits.isEmpty) _toast('没找到 >= $minLen 字节的连续空位');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('空位搜索')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _minCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: '最小长度（字节）',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: true, label: Text('FF')),
                        ButtonSegment(value: false, label: Text('00')),
                      ],
                      selected: {_fillFF},
                      onSelectionChanged: (s) => setState(() => _fillFF = s.first),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _run,
                    icon: const Icon(Icons.search),
                    label: const Text('开始搜索'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _hits.isEmpty
                ? Center(
                    child: Text(
                      _searched ? '没有结果' : '设置条件后开始搜索',
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  )
                : ListView.separated(
                    itemCount: _hits.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final h = _hits[i];
                      return ListTile(
                        leading: CircleAvatar(child: Text('${i + 1}')),
                        title: Text(
                          '0x${h.offset.toRadixString(16).padLeft(8, '0').toUpperCase()}',
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        subtitle: Text('${h.length} 字节'
                            '（${(h.length / 1024).toStringAsFixed(1)} KB）'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.pop(
                          context,
                          (offset: h.offset, length: h.length),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------- 补丁库 ----------

class PatchListPage extends StatefulWidget {
  final EditableRom edit;
  const PatchListPage({super.key, required this.edit});

  @override
  State<PatchListPage> createState() => _PatchListPageState();
}

class _PatchListPageState extends State<PatchListPage> {
  PatchLibrary? _lib;
  bool _loading = true;
  String? _error;
  bool _changed = false;
  final _filter = TextEditingController();

  String get _assetDir => 'assets/patches/${widget.edit.rom.table.id}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final lib = await PatchLibrary.loadFromAssets(_assetDir);
      if (!mounted) return;
      setState(() {
        _lib = lib;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('补丁库')),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('加载补丁库失败：$_error'),
        ),
      );
    }
    final lib = _lib!;
    if (lib.patches.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '这个版本（${widget.edit.rom.table.id}）暂无内置补丁。\n'
            '目前收录了 FEBuilderGBA 中「固定字节写入」类补丁。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ),
      );
    }

    final q = _filter.text.trim().toLowerCase();
    final list = q.isEmpty
        ? lib.patches
        : lib.patches.where((p) =>
            p.name.toLowerCase().contains(q) ||
            p.info.toLowerCase().contains(q)).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _filter,
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索补丁（共 ${lib.patches.length} 个）',
              prefixIcon: const Icon(Icons.search, size: 20),
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final p = list[i];
              final installed = isPatchInstalled(p, widget.edit.data);
              return ListTile(
                leading: Icon(
                  installed ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: installed ? Colors.green : Colors.grey,
                ),
                title: Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: p.info.isEmpty
                    ? null
                    : Text(p.info.split('\n').first,
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12)),
                trailing: installed
                    ? const Text('已安装', style: TextStyle(fontSize: 12, color: Colors.green))
                    : TextButton(
                        onPressed: () => _install(p),
                        child: const Text('安装'),
                      ),
                onTap: () => _showDetail(p),
              );
            },
          ),
        ),
      ],
    );
  }

  void _showDetail(FePatch p) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(p.name),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (p.info.isNotEmpty) Text(p.info),
              if (p.author.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('作者：${p.author}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ],
              const SizedBox(height: 12),
              Text('写入位置：${p.writes.length} 处',
                  style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          if (!isPatchInstalled(p, widget.edit.data))
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _install(p);
              },
              child: const Text('安装'),
            ),
        ],
      ),
    );
  }

  Future<void> _install(FePatch p) async {
    final e = widget.edit;
    final before = Uint8List.fromList(e.data);
    final result = await applyPatch(p, e.data);
    if (!mounted) return;
    if (!result.ok) {
      e.data.setAll(0, before);
      _toast(result.message);
      return;
    }
    for (final u in result.undo) {
      if (u.before.length == 1) {
        e.edits.add(ByteEdit(u.offset, u.before[0], e.data[u.offset]));
      } else {
        for (var i = 0; i < u.before.length; i++) {
          e.edits.add(ByteEdit(
            u.offset + i,
            u.before[i],
            e.data[u.offset + i],
          ));
        }
      }
    }
    setState(() => _changed = true);
    _toast('已安装 ${p.name}');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }
}

// ---------- 文本查看器 ----------

class TextBrowserPage extends StatefulWidget {
  final EditableRom edit;
  const TextBrowserPage({super.key, required this.edit});

  @override
  State<TextBrowserPage> createState() => _TextBrowserPageState();
}

class _TextBrowserPageState extends State<TextBrowserPage> {
  late final TextBrowser _browser = TextBrowser(widget.edit.rom);
  final _filter = TextEditingController();
  List<_TextRow> _rows = [];
  int _total = 0;
  bool _done = false;

  /// 每批渲染条数。全量渲染 FE7J 约 0.3s（JVM），真机会更慢，
  /// 分块加载让首屏立即可见，滚动时后台增量补齐。
  static const int _batchSize = 250;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  bool _matchesFilter(String text) =>
      _filter.text.trim().isEmpty || text.contains(_filter.text.trim());

  Future<void> _loadMore() async {
    if (_done) return;
    final start = _total;
    final end = start + _batchSize;
    final batch = <_TextRow>[];
    for (var id = start; id < end && id < _browser.maxId; id++) {
      final text = _browser.render(id);
      if (text.trim().isEmpty) continue;
      batch.add(_TextRow(id, text));
    }
    if (!mounted) return;
    setState(() {
      _rows.addAll(batch);
      _total = end;
      if (end >= _browser.maxId) _done = true;
    });
    // 还有剩余且用户在看，继续后台补齐（让出帧保持流畅）
    if (!_done) {
      await Future<void>.delayed(Duration.zero);
      if (mounted) _loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_done ? '文本 ($_rowsCount)' : '文本 (加载中 $_rowsCount…)')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _filter,
              decoration: const InputDecoration(
                isDense: true,
                hintText: '搜索文本内容',
                prefixIcon: Icon(Icons.search, size: 20),
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(child: _buildList(_rows)),
        ],
      ),
    );
  }

  int get _rowsCount {
    final q = _filter.text.trim();
    if (q.isEmpty) return _rows.length;
    return _rows.where((r) => r.text.contains(q)).length;
  }

  Widget _buildList(List<_TextRow> rows) {
    final q = _filter.text.trim();
    final list = q.isEmpty
        ? rows
        : rows.where((r) => r.text.contains(q)).toList();
    return ListView.separated(
      itemCount: list.length + (_done ? 0 : 1),
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        if (i >= list.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final r = list[i];
        return ListTile(
          dense: true,
          leading: SizedBox(
            width: 52,
            child: Text(
              r.id.toRadixString(16).toUpperCase().padLeft(4, '0'),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          title: Text(
            r.text.replaceAll('\\n', ' '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
          onTap: () => _showFull(r),
        );
      },
    );
  }

  void _showFull(_TextRow r) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('文本 0x${r.id.toRadixString(16).toUpperCase().padLeft(4, '0')}'),
        content: SingleChildScrollView(
          child: SelectableText(r.text, style: const TextStyle(fontSize: 14, height: 1.5)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }
}

class _TextRow {
  final int id;
  final String text;
  const _TextRow(this.id, this.text);
}
