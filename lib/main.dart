import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'core/app_log.dart';
import 'core/app_settings.dart';
import 'core/app_meta.dart';
import 'core/editable_rom.dart';
import 'core/feature_flags.dart';
import 'core/fe_rom.dart';
import 'core/file_picker_service.dart';
import 'core/hex_view.dart';
import 'ui/disasm_page.dart';
import 'core/patch_format.dart';
import 'core/text_browser.dart';
import 'core/text_codec.dart';
import 'core/text_writer.dart';
import 'ui/text_edit_dialog.dart';
import 'core/zh_table.dart';
import 'core/zh_tables_data.dart';
import 'ui/about_page.dart';
import 'ui/battle_anim_page.dart';
import 'ui/cheat_page.dart';
import 'ui/item_page.dart';
import 'ui/settings_page.dart';
import 'ui/log_page.dart';
import 'ui/chapter_page.dart';
import 'ui/portrait_page.dart';
import 'ui/table_address_page.dart';
import 'ui/unit_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 先装日志与未捕获异常钩子，再做别的
  AppLog.instance.install(version: appVersion);
  await AppSettings.instance.load();
  AppLog.instance.attachFile();
  runApp(const FeEditorApp());
}

class FeEditorApp extends StatefulWidget {
  const FeEditorApp({super.key});

  @override
  State<FeEditorApp> createState() => _FeEditorAppState();
}

class _FeEditorAppState extends State<FeEditorApp> {
  static const Color _seed = Color(0xFF2E5C8A);

  // 当前主题模式（0=跟随系统 / 1=浅色 / 2=暗色），来自持久化设置。
  int _modeIndex = AppSettings.instance.themeModeIndex;

  @override
  void initState() {
    super.initState();
    AppSettings.instance.themeNotifier.addListener(_onThemeMode);
  }

  @override
  void dispose() {
    AppSettings.instance.themeNotifier.removeListener(_onThemeMode);
    super.dispose();
  }

  void _onThemeMode() {
    if (!mounted) return;
    setState(() => _modeIndex = AppSettings.instance.themeModeIndex);
  }

  static ThemeMode _resolveMode(int i) => switch (i) {
        1 => ThemeMode.light,
        2 => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  static ThemeData get _lightTheme => ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      );

  static ThemeData get _darkTheme => ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        // 页面底色调成近黑，卡片（surface）略浅，层次感对齐参考图。
        scaffoldBackgroundColor: const Color(0xFF0E1013),
      );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '火纹改版工具',
      debugShowCheckedModeBanner: false,
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: _resolveMode(_modeIndex),
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
      // native 把 content:// 桥接成可读写路径时会在 cacheDir 留一份整份 ROM 副本。
      // 读进内存后即删除，避免每开一个 ROM 都在缓存里积一份、空间持续膨胀。
      try {
        await File(path).delete();
      } catch (_) {
        // 删除失败不影响已读入内存的 ROM
      }
      await _load(data, path.split('/').last);
    } catch (e) {
      AppLog.instance.log('error', '打开 ROM 失败: $e');
      setState(() => _error = '打开失败：$e');
    }
  }

  Future<void> _load(Uint8List data, String name) async {
    final table = FeRom.detectTable(data);
    if (table == null) {
      final code = data.length >= 0xB0
          ? String.fromCharCodes(data.sublist(0xAC, 0xB0))
          : '????';
      AppLog.instance
          .log('error', '无法识别 ROM $name code=$code size=${data.length}');
      setState(() {
        _edit = null;
        _error = '无法识别此 ROM（game code: $code）。\n'
            '支持：封印之剑 FE6、烈火之剑 FE7（日/美）、圣魔之光石 FE8（日/美）。';
      });
      return;
    }
    final edit = EditableRom.open(data, table);
    await _maybeAttachZhTable(edit);
    // 换 ROM 必须换缓存命名空间，否则新 ROM 会直接显示上一个 ROM 的肖像
    PortraitImageCache.instance.bindRom(edit.rom.fingerprint);
    AppLog.instance.log(
        'info',
        '打开 ROM $name ${data.length}B '
            'code=${edit.rom.gameCode} table=${table.id} text=${edit.rom.textEncoding}');
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
            TextButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LogViewerPage()),
                );
              },
              icon: const Icon(Icons.notes, size: 18),
              label: const Text('查看应用日志'),
            ),
            TextButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => AboutPage()),
                );
              },
              icon: const Icon(Icons.info_outline, size: 18),
              label: const Text('关于 / 更新日志'),
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
                child:
                    Text(_error!, style: TextStyle(color: Colors.red.shade900)),
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
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                _kv('游戏代码', rom.gameCode),
                _kv('头部标题', rom.headerTitle),
                _kv('ROM 大小',
                    '${(rom.length / 1048576).toStringAsFixed(1)} MB'),
                _kv('文本解码', _textStatus(rom)),
                if (edit.hasChanges) _kv('已修改', '${edit.changedByteCount} 字节'),
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
                Icon(Icons.warning_amber,
                    color: Colors.orange.shade800, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '未能识别此 ROM 的文本编码（汉化/改版重写过文本引擎），'
                    '角色和职业名会显示异常。数值字段不受影响。'
                    '\n检测详情：$_textDetail',
                    style:
                        TextStyle(color: Colors.orange.shade900, fontSize: 13),
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
              '可使用只读浏览与十六进制编辑。',
              style: TextStyle(color: Colors.blueGrey.shade800, fontSize: 13),
            ),
          ),
        _section('游戏数据', [
          _tile('角色', Icons.person, '肖像 · 职业 · 数值成长（整合页）', () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => UnitListPage(edit: edit)),
            ).then((_) => setState(() {}));
          }),
          _tile('职业', Icons.shield, '职业表：移动力 / 体格 / 基础值 / 成长率', () {
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
          if (Features.chapter)
            _tile('章节', Icons.map, '地形与初始单位：地图上直接看小人，点格子看地形', () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => ChapterPage(edit: edit)),
              ).then((_) => setState(() {}));
            }),
        ]),
        _section('素材预览', [
          _tile('肖像', Icons.face, '按角色浏览：正脸 / 眼型 / 嘴型 / 地图头像', () {
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
          _tile('战斗动画', Icons.sports_martial_arts, '战斗画面动画：逐帧浏览、调色板与导出', () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => BattleAnimListPage(edit: edit)),
            );
          }),
        ]),
        _section('工具', [
          _tile('修改器', Icons.auto_fix_high, '全局角色强化等批量一键修改', () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => CheatListPage(edit: edit)),
            ).then((_) => setState(() {}));
          }),
          _tile('十六进制', Icons.code, '按地址查看与修改任意字节、搜索', () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => HexEditorPage(edit: edit)),
            ).then((_) => setState(() {}));
          }),
          _tile('反汇编', Icons.memory, 'ARM/Thumb 机器码反汇编，可跳转与搜索', () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => DisasmPage(edit: edit)),
            );
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
                  builder: (_) =>
                      HexEditorPage(edit: edit, initialOffset: result.offset),
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
          _tile('设置', Icons.settings, '覆盖模式等保存选项', () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ).then((_) => setState(() {}));
          }),
          _tile('日志', Icons.notes, '错误与操作记录，可复制发给我们排查', () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LogViewerPage()),
            );
          }),
          _tile('关于', Icons.info_outline, '应用信息、更新日志、开源致谢', () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const AboutPage(),
              ),
            );
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
        return '正常（中文·明文 GBK）';
      case FeTextEncoding.plainUtf8:
        return '正常（中文·明文 UTF-8）';
      case FeTextEncoding.huffmanZhTbl:
        return '正常（中文·码表 ${rom.zhTable?.table.length ?? 0} 字）';
      case FeTextEncoding.unknown:
        if (rom.zhTable != null) {
          return '正常（中文·码表 ${rom.zhTable!.table.length} 字）';
        }
        return '异常（改版文本引擎）';
    }
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
                width: 80,
                child: Text(k, style: const TextStyle(color: Colors.grey))),
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
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 4),
              Text(
                sub,
                maxLines: 3,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 10.5, color: Colors.grey, height: 1.3),
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
              subtitle:
                  Text('${(edit.data.length / 1048576).toStringAsFixed(1)} MB'),
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
    final base = (_fileName ?? 'rom.gba')
        .replaceAll(RegExp(r'\.gba$', caseSensitive: false), '');
    final name = '${base}_modified.gba';

    // 覆盖模式：写回「打开 ROM」时选中的原文件，不产生新文件。
    if (AppSettings.instance.overwriteMode) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('直接覆盖原 ROM？'),
          content: Text(
            '会用当前修改后的内容覆盖「$_fileName」。\n\n'
            '原文件将被改写且无法撤销，请确认之前已做好备份。',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style:
                  FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
              child: const Text('覆盖'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      try {
        final uri = await overwriteSourceRom(edit.data);
        AppLog.instance.log('info', '覆盖保存 $_fileName ${edit.data.length}B');
        if (!mounted) return;
        _toast(uri == null ? '覆盖失败：没有可写回的源文件' : '已覆盖 $_fileName');
      } catch (e) {
        AppLog.instance.log('error', '覆盖 $_fileName 失败: $e');
        if (!mounted) return;
        _toast('覆盖失败：$e');
      }
      return;
    }

    try {
      final saved = await saveFile(name, edit.data);
      if (!mounted) return;
      if (saved != null) {
        AppLog.instance.log('info', '导出 GBA $name ${edit.data.length}B');
      }
      _toast(saved == null ? '已取消' : '已保存 $name');
    } catch (e) {
      AppLog.instance.log('error', '导出 GBA $name 失败: $e');
      if (!mounted) return;
      _toast('保存失败：$e');
    }
  }

  Future<void> _exportPatch(EditableRom edit, {required bool ups}) async {
    final base = (_fileName ?? 'rom.gba')
        .replaceAll(RegExp(r'\.gba$', caseSensitive: false), '');
    final out = edit.buildOutput();
    if (ups) {
      final patch = UpsPatch.create(edit.original, out);
      final ok = await _savePatch('${base}_modified.ups', patch);
      if (!mounted) return;
      if (ok != null) {
        AppLog.instance.log('info', '导出 UPS ${patch.length}B');
      }
      _toast(ok == null ? '已取消' : '已导出 UPS（${_size(patch.length)}）');
      return;
    }
    final patch = IpsPatch.create(edit.original, out);
    if (patch == null) {
      AppLog.instance.log('warn', 'IPS 导出失败：修改超出 0xFFFFFF 范围');
      if (!mounted) return;
      _toast('修改超出 IPS 可表达范围（0xFFFFFF 之后），请改用 UPS');
      return;
    }
    final ok = await _savePatch('${base}_modified.ips', patch);
    if (!mounted) return;
    if (ok != null) {
      AppLog.instance.log('info', '导出 IPS ${patch.length}B');
    }
    _toast(ok == null ? '已取消' : '已导出 IPS（${_size(patch.length)}）');
  }

  Future<String?> _savePatch(String name, Uint8List bytes) async {
    try {
      return await saveFile(name, bytes);
    } catch (e) {
      AppLog.instance.log('error', '导出补丁 $name 失败: $e');
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

// ---------- 十六进制编辑器 ----------

class HexEditorPage extends StatefulWidget {
  final EditableRom edit;
  final int initialOffset;
  const HexEditorPage({super.key, required this.edit, this.initialOffset = 0});

  @override
  State<HexEditorPage> createState() => _HexEditorPageState();
}

class _HexEditorPageState extends State<HexEditorPage> {
  static const double _rowHeight = 26;
  late final HexView _view = HexView(widget.edit.buffer);
  late final ScrollController _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  int _highlight = -1;

  /// 当前每行字节数（按屏幕宽度自适应，避免换行被裁掉）
  int _perRow = 8;

  /// 已修改过的字节偏移（界面高亮显示）
  final Set<int> _dirty = {};

  /// 当前选中待编辑的字节偏移（-1 = 未选中）
  int _selected = -1;

  /// 正在输入的十六进制（0~2 位，输入满 2 位即写回）
  String _input = '';

  @override
  void initState() {
    super.initState();
    if (widget.initialOffset > 0) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _jumpTo(widget.initialOffset));
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 根据可用宽度算每行能排几个字节（地址 8 字符 + 每字节 3 字符）
  int _calcPerRow(double maxWidth) {
    // 地址列 ≈ 66px，每字节单元 ≈ 30px
    final usable = maxWidth - 66;
    final n = (usable / 30).floor();
    return n.clamp(4, 16);
  }

  void _jumpTo(int offset) {
    final row = offset ~/ _perRow;
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
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    if (input == null) return;
    final cleaned = input
        .trim()
        .replaceAll(RegExp(r'^0[xX]'), '')
        .replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
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

  /// 选中某个字节以编辑（配合底部数字键盘输入，输入满 2 位自动写回）。
  void _select(int offset) {
    setState(() {
      _selected = offset;
      _input = '';
    });
  }

  /// 数字键盘 0~F：向选中字节追加一位，凑满两位即写回。
  void _pad(String digit) {
    if (_selected < 0) return;
    final next = _input + digit;
    if (next.length < 2) {
      setState(() => _input = next);
      return;
    }
    _input = '';
    _commitByte(int.parse(next, radix: 16));
  }

  void _deselect() {
    setState(() {
      _selected = -1;
      _input = '';
    });
  }

  /// 写回选中字节的值（同值不写；记录 edits 以便撤销）。
  void _commitByte(int val) {
    final offset = _selected;
    if (offset < 0) return;
    final before = _view.buffer.u8(offset);
    if (before == val) return;
    _view.buffer.writeU8(offset, val);
    widget.edit.edits.add(ByteEdit(offset, before, val));
    _dirty.add(offset);
    setState(() {});
  }

  String get _valDisplay {
    if (_selected < 0) return '——';
    if (_input.isNotEmpty) return _input.padRight(2, ' ');
    return _view.buffer
        .u8(_selected)
        .toRadixString(16)
        .padLeft(2, '0')
        .toUpperCase();
  }

  String get _posDisplay {
    if (_selected < 0) return '——';
    return '0x${_selected.toRadixString(16).toUpperCase()}';
  }

  String get _gbaDisplay {
    if (_selected < 0) return '——';
    return '0x${(_selected + 0x08000000).toRadixString(16).toUpperCase()}';
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 当前关注的位置：优先选中的字节，其次视口顶部那一行。
  int get _focusOffset {
    if (_selected >= 0) return _selected;
    if (_scroll.hasClients) {
      final row = (_scroll.offset / _rowHeight).floor();
      final at = row * _perRow;
      return at.clamp(0, _view.buffer.length - 1);
    }
    return widget.initialOffset;
  }

  /// 把当前位置交给反汇编页（按 Thumb 打开，游戏里大多数函数是 Thumb）。
  void _openDisassembler() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            DisasmPage(edit: widget.edit, initialOffset: _focusOffset),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('十六进制编辑器'),
        actions: [
          IconButton(
            tooltip: '从当前位置反汇编',
            icon: const Icon(Icons.memory),
            onPressed: _openDisassembler,
          ),
          IconButton(
            tooltip: '跳转地址',
            icon: const Icon(Icons.my_location),
            onPressed: _gotoDialog,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final perRow = _calcPerRow(constraints.maxWidth);
          if (perRow != _perRow) {
            // 宽度变化时重排行宽，保持滚动位置大致不变
            final anchor = _scroll.hasClients
                ? (_scroll.offset / _rowHeight).round() * _perRow
                : 0;
            _perRow = perRow;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!_scroll.hasClients) return;
              final target = (anchor ~/ _perRow) * _rowHeight;
              _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
            });
          }
          final rowCount = (_view.buffer.length + _perRow - 1) ~/ _perRow;
          return Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                  itemCount: rowCount,
                  itemBuilder: (_, row) {
                    final isHit = row == _highlight;
                    final start = row * _perRow;
                    return Container(
                      color: isHit ? theme.colorScheme.primaryContainer : null,
                      padding: const EdgeInsets.only(left: 6, right: 6),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 60,
                            child: Text(
                              (start)
                                  .toRadixString(16)
                                  .padLeft(8, '0')
                                  .toUpperCase(),
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                          for (var i = 0; i < _perRow; i++)
                            if (start + i < _view.buffer.length)
                              _byteCell(start + i, theme)
                            else
                              const SizedBox(width: 26),
                        ],
                      ),
                    );
                  },
                ),
              ),
              _editBar(theme),
            ],
          );
        },
      ),
    );
  }

  /// 底部编辑区：状态栏（Val/Pos/GBA/Size）+ 十六进制数字键盘。
  Widget _editBar(ThemeData theme) {
    final scheme = theme.colorScheme;
    final sizeHex = '0x${_view.buffer.length.toRadixString(16).toUpperCase()}';
    final enabled = _selected >= 0;
    return Container(
      color: scheme.surfaceContainerHighest,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Text(
                      'Val: $_valDisplay  ·  Pos: $_posDisplay'
                      '  ·  GBA: $_gbaDisplay  ·  Size: $sizeHex  ·  [HEX]',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: enabled ? scheme.primary : Colors.grey.shade600,
                      ),
                    ),
                  ),
                ),
                if (enabled)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: '取消选择',
                    onPressed: _deselect,
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Column(
              children: [
                _padRow(const ['0', '1', '2', '3', '4', '5', '6', '7'], theme),
                const SizedBox(height: 4),
                _padRow(const ['8', '9', 'A', 'B', 'C', 'D', 'E', 'F'], theme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 数字键盘的一行（未选中时灰显，选中时可点）。
  Widget _padRow(List<String> digits, ThemeData theme) {
    final enabled = _selected >= 0;
    final scheme = theme.colorScheme;
    return Row(
      children: [
        for (final d in digits)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: InkWell(
                onTap: enabled ? () => _pad(d) : null,
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Text(
                    d,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: enabled
                          ? scheme.primary
                          : scheme.onSurface.withValues(alpha: 0.35),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 单个字节：显示两位十六进制，点击选中后在底部键盘输入改值；改过的字节用底色标出。
  Widget _byteCell(int offset, ThemeData theme) {
    final v = _view.buffer.u8(offset);
    final text = v.toRadixString(16).padLeft(2, '0').toUpperCase();
    final isDirty = _dirty.contains(offset);
    final isSel = _selected == offset;
    return InkWell(
      onTap: () => _select(offset),
      borderRadius: BorderRadius.circular(3),
      child: Container(
        width: 26,
        height: 20,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(3),
          color: isSel
              ? theme.colorScheme.primaryContainer
              : (isDirty ? theme.colorScheme.tertiaryContainer : null),
          border: isSel
              ? Border.all(color: theme.colorScheme.primary, width: 1.5)
              : null,
        ),
        child: Text(
          text,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            fontWeight: v == 0 ? FontWeight.normal : FontWeight.w600,
            color: v == 0
                ? Colors.grey.shade500
                : (isSel ? theme.colorScheme.onPrimaryContainer : null),
          ),
        ),
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
                      onSelectionChanged: (s) =>
                          setState(() => _fillFF = s.first),
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

// ---------- 文本查看器 ----------

class TextBrowserPage extends StatefulWidget {
  final EditableRom edit;
  const TextBrowserPage({super.key, required this.edit});

  @override
  State<TextBrowserPage> createState() => _TextBrowserPageState();
}

class _TextBrowserPageState extends State<TextBrowserPage> {
  // 文本写入器（只对明文 UTF-8/GBK 生效），同时提供读实时 buffer 的 FeRom 视图
  late final TextWriter _writer = TextWriter(widget.edit);
  late final TextBrowser _browser = TextBrowser(_writer.rom);
  final _filter = TextEditingController();
  final List<_TextRow> _rows = [];
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
      appBar: AppBar(
          title: Text(_done ? '文本 ($_rowsCount)' : '文本 (加载中 $_rowsCount…)')),
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
    final list =
        q.isEmpty ? rows : rows.where((r) => r.text.contains(q)).toList();
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
    final canEdit = _writer.supported && _writer.entryEditable(r.id);
    final title =
        '文本 0x${r.id.toRadixString(16).toUpperCase().padLeft(4, '0')}';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(r.text,
                  style: const TextStyle(fontSize: 14, height: 1.5)),
              if (!canEdit) ...[
                const SizedBox(height: 10),
                Text(
                  '此 ROM 的文本引擎未识别，暂不支持写入。',
                  style:
                      TextStyle(fontSize: 11, color: Theme.of(ctx).hintColor),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (canEdit)
            FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final changed = await showTextEditDialog(
                  context,
                  edit: widget.edit,
                  textId: r.id,
                  title: '编辑 $title',
                );
                if (changed && mounted) {
                  _refreshRow(r.id);
                  setState(() {});
                }
              },
              child: const Text('编辑'),
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  /// 编辑后刷新列表里那一行的文本（读实时 buffer）。
  void _refreshRow(int id) {
    final i = _rows.indexWhere((row) => row.id == id);
    if (i < 0) return;
    _rows[i] = _TextRow(id, _browser.render(id));
  }
}

class _TextRow {
  final int id;
  final String text;
  const _TextRow(this.id, this.text);
}
