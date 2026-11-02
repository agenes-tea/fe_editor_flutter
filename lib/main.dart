import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'core/app_log.dart';
import 'core/app_settings.dart';
import 'core/app_meta.dart';
import 'core/editable_rom.dart';
import 'core/rom_session.dart';
import 'core/mcp_service.dart';
import 'core/rom_workspace.dart';
import 'core/feature_flags.dart';
import 'core/fe_rom.dart';
import 'core/file_picker_service.dart';
import 'core/external_workspace.dart';
import 'core/hex_view.dart';
import 'core/recipe.dart';
import 'core/rom_health.dart';
import 'ui/disasm_page.dart';
import 'core/patch_format.dart';
import 'core/patch_apply.dart';
import 'core/text_browser.dart';
import 'core/text_codec.dart';
import 'core/text_writer.dart';
import 'core/text_find_replace.dart';
import 'ui/text_edit_dialog.dart';
import 'ui/about_page.dart';
import 'ui/battle_anim_page.dart';
import 'ui/battle_anim_port_page.dart';
import 'ui/cheat_page.dart';
import 'ui/item_page.dart';
import 'ui/settings_page.dart';
import 'ui/simulator_page.dart';
import 'ui/log_page.dart';
import 'ui/chapter_page.dart';
import 'ui/portrait_page.dart';
import 'ui/portrait_port_page.dart';
import 'ui/health_page.dart';
import 'ui/rom_session_bar.dart';
import 'ui/table_address_page.dart';
import 'ui/unit_page.dart';
import 'ui/workspace_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 先装日志与未捕获异常钩子，再做别的
  AppLog.instance.install(version: appVersion);
  await AppSettings.instance.load();
  // 外部工作区：目录授权跟着系统持久化，这里只把「上次选的目录」读回来
  await ExternalWorkspace.instance.load();
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
  /// 已打开的 ROM 集合（可同时多个：跨版本移植要源/目标共存）。
  final RomWorkspace _workspace = RomWorkspace();

  String? _error;

  RomSession? get _active => _workspace.active;

  EditableRom? get _edit => _active?.rom;

  String? get _fileName => _active?.fileName;

  FeRom? get _rom => _active?.rom.rom;

  @override
  void initState() {
    super.initState();
    _workspace.addListener(_onWorkspace);
    // MCP 请求随时可能到达（包括 App 在后台时），所以工作区一建好就绑定。
    McpService.instance.install(_workspace);
  }

  @override
  void dispose() {
    _workspace.removeListener(_onWorkspace);
    _workspace.dispose();
    super.dispose();
  }

  void _onWorkspace() {
    if (mounted) setState(() {});
  }

  /// 从外部工作区挑一个 ROM 打开。
  ///
  /// 工作区设好后这是最常用的入口：目录已授权，直接列文件点开，
  /// 不再每次走系统文件选择器。
  Future<void> _openFromWorkspace() async {
    setState(() => _error = null);
    final picked = await Navigator.push<WorkspaceRom>(
      context,
      MaterialPageRoute(builder: (_) => const WorkspacePage()),
    );
    if (picked == null) return;
    final data = await ExternalWorkspace.instance.readRom(picked.name);
    if (data == null) {
      setState(() => _error = '读取工作区 ROM 失败：${picked.name}');
      return;
    }
    await _open(data, picked.name);
  }

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
      await _open(data, path.split('/').last);
    } catch (e) {
      AppLog.instance.log('error', '打开 ROM 失败: $e');
      setState(() => _error = '打开失败：$e');
    }
  }

  /// 打开一个 ROM。已经是打开状态的同一份 ROM 只切换过去，不重复占用内存。
  Future<void> _open(Uint8List data, String name) async {
    final before = _workspace.sessions.length;
    final session = await _workspace.open(data, name);
    if (session == null) {
      final code = data.length >= 0xB0
          ? String.fromCharCodes(data.sublist(0xAC, 0xB0))
          : '????';
      AppLog.instance
          .log('error', '无法识别 ROM $name code=$code size=${data.length}');
      setState(() {
        _error = '无法识别此 ROM（game code: $code）。\n'
            '支持：封印之剑 FE6、烈火之剑 FE7（日/美）、圣魔之光石 FE8（日/美）。';
      });
      return;
    }
    if (_workspace.sessions.length == before) {
      AppLog.instance.log('info', 'ROM $name 已打开，切换到该会话');
      return;
    }
    AppLog.instance.log(
        'info',
        '打开 ROM $name ${data.length}B '
            'code=${session.liveRom.gameCode} table=${session.versionId} '
            'text=${session.liveRom.textEncoding} 已打开 ${_workspace.sessions.length} 个');
  }

  @override
  Widget build(BuildContext context) {
    final session = _active;
    return Scaffold(
      appBar: AppBar(
        title: Text(session == null
            ? '火纹改版工具'
            : '火纹改版工具  ${session.versionId}'),
        actions: [
          IconButton(
            tooltip: ExternalWorkspace.instance.configured
                ? '工作区（${ExternalWorkspace.instance.dir!.name}）'
                : '外部工作区',
            icon: const Icon(Icons.folder_special),
            onPressed: _openFromWorkspace,
          ),
          IconButton(
            tooltip: '打开另一个 ROM',
            icon: const Icon(Icons.library_add),
            onPressed: _pickRom,
          ),
          if (session != null)
            IconButton(
              tooltip: '导出',
              icon: const Icon(Icons.save_alt),
              onPressed: _showExportSheet,
            ),
          if (session != null)
            IconButton(
              tooltip: '关闭当前 ROM',
              icon: const Icon(Icons.close),
              onPressed: () => _workspace.close(session),
            ),
        ],
      ),
      body: session == null ? _buildEmpty() : _buildLoaded(),
    );
  }

  /// 会话切换栏：同时打开多个 ROM 时，在顶部列出每一个（点一下切过去）。
  Widget _sessionBar() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: RomSessionBar(
        sessions: _workspace.sessions,
        activeId: _workspace.active?.id,
        onSelect: _workspace.activate,
        onClose: _workspace.close,
      ),
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
            if (ExternalWorkspace.instance.configured) ...[
              FilledButton.icon(
                onPressed: _openFromWorkspace,
                icon: const Icon(Icons.folder_special),
                label: Text('从工作区打开（${ExternalWorkspace.instance.dir!.name}）'),
              ),
              const SizedBox(height: 8),
            ] else ...[
              FilledButton.icon(
                onPressed: _openFromWorkspace,
                icon: const Icon(Icons.folder_special),
                label: const Text('设置工作区（以后不用每次选 ROM）'),
              ),
              const SizedBox(height: 8),
            ],
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
    final session = _active!;
    final edit = session.rom;
    final rom = edit.rom;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_workspace.sessions.length > 1) _sessionBar(),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(session.fileName,
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
          // 移植需要至少两个 ROM；只有一个时也给入口，页面里会提示
          _tile('肖像移植', Icons.compare_arrows,
              '把一张脸搬到另一个已打开的 ROM（跨版本自动转格式）', () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PortraitPortPage(
                  sessions: _workspace.sessions,
                  current: session,
                ),
              ),
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
          _tile('动画移植', Icons.movie_filter,
              '把一条战斗动画整包搬到另一个已打开的 ROM', () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => BattleAnimPortPage(
                  sessions: _workspace.sessions,
                  current: session,
                ),
              ),
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
          _tile('模拟', Icons.show_chart, '成长曲线 / 战斗推演 / 改前 vs 改后', () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => SimulatorPage(edit: edit)),
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
          _tile('ROM 体检', Icons.health_and_safety_outlined,
              '检查表结构、ID 连续性与章节单位是否越界', () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => HealthPage(edit: edit)),
            );
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
            ListTile(
              leading: const Icon(Icons.playlist_add_check),
              title: const Text('导入配方'),
              subtitle: const Text('应用别人或 AI 导出的修改配方，应用后自动体检'),
              onTap: () {
                Navigator.pop(ctx);
                _importRecipe(edit);
              },
            ),
            ListTile(
              leading: const Icon(Icons.healing_outlined),
              title: const Text('应用补丁'),
              subtitle: const Text('导入 .ips/.ups 补丁文件（需针对这份原版 ROM 生成）'),
              onTap: () {
                Navigator.pop(ctx);
                _applyPatch(edit);
              },
            ),
            ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: const Text('用模拟器打开'),
              subtitle: const Text('分享改后的 GBA，选 mGBA 等模拟器直接看效果'),
              onTap: () {
                Navigator.pop(ctx);
                _shareToEmulator(edit);
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

  /// 应用补丁：选 .ips/.ups → 对原版快照应用 → 确认后按差异区写回 buffer →
  /// 自动浅体检。补丁必须针对**未改动的原版 ROM** 生成：会话里有未保存
  /// 改动时直接拒绝（改了再打补丁，两层改动会互相覆盖）。
  Future<void> _applyPatch(EditableRom edit) async {
    final path = await pickPatchFile();
    if (!mounted) return;
    if (path == null) {
      _toast('未应用：已取消选择');
      return;
    }
    List<int> patchBytes;
    try {
      patchBytes = File(path).readAsBytesSync();
    } catch (e) {
      _toast('读补丁文件失败：$e');
      return;
    }
    if (edit.hasChanges) {
      _toast('会话里有未保存的改动：先「撤销全部修改」再打补丁'
          '（补丁是针对原版 ROM 生成的）');
      return;
    }
    final result = applyPatch(Uint8List.fromList(patchBytes), edit.original);
    if (!mounted) return;
    if (!result.ok) {
      AppLog.instance.log('warn', '补丁应用失败：${result.message}');
      _toast(result.message);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('应用 ${result.kind} 补丁？'),
        content: Text(
          '将改动 ${result.changedBytes} 字节。\n'
          '写入后可用顶栏「撤销全部修改」整体还原；'
          '应用后会自动跑一次浅体检。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('应用')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    // 按连续差异区写回 buffer（每字节都记进 edits，可整体撤销）
    final a = edit.original;
    final b = result.newRom!;
    var i = 0;
    var regions = 0;
    while (i < a.length) {
      if (a[i] == b[i]) {
        i++;
        continue;
      }
      final start = i;
      while (i < a.length && a[i] != b[i]) i++;
      edit.writeBytes(start, b.sublist(start, i));
      regions++;
    }
    final report = RomHealth(edit).run(deep: false);
    AppLog.instance.log(
        'info', '应用${result.kind}补丁：${result.changedBytes}B / $regions 个差异区');
    if (!mounted) return;
    setState(() {});

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(report.ok ? '补丁已应用' : '补丁已应用（体检有问题）'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${result.kind} 补丁，改动 ${result.changedBytes} 字节'),
              if (report.ok)
                const Text('自动体检：未发现问题')
              else
                Text('自动体检：${report.errorCount} 处问题、'
                    '${report.warningCount} 处警告'),
              Text('不满意可顶栏「撤销全部修改」整体还原（补丁写入也是一次编辑）。',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              if (mounted) {
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => HealthPage(edit: edit)));
              }
            },
            child: const Text('看完整体检'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  /// 「用模拟器打开」：把当前（改后）ROM 分享到系统，让用户选模拟器（mGBA 等）
  /// 直接打开看效果。不集成模拟器引擎——那是另一量级的工程；
  /// 分享面板是「改完立刻看」最短的一跳。
  Future<void> _shareToEmulator(EditableRom edit) async {
    final base = (_fileName ?? 'rom.gba')
        .replaceAll(RegExp(r'\.gba$', caseSensitive: false), '');
    final err = await shareGbaRom('${base}_modified.gba', edit.data);
    if (!mounted) return;
    if (err == null) {
      AppLog.instance.log('info', '分享 ROM 给模拟器 ${edit.data.length}B');
      _toast('已分享，请在面板里选一个模拟器（如 mGBA）打开');
    } else {
      _toast(err);
    }
  }

  /// 导入配方：选配方 JSON → 预览 → 快照 → 应用 → 自动浅体检。
  ///
  /// 配方两层：语义层（预设/字段，按名字重新解析，同版本可用）与
  /// 字节层（chunks，指纹一致才重放，原值对不上的分段逐条跳过）。
  /// 应用前快照，结果弹窗里可一键回退。
  Future<void> _importRecipe(EditableRom edit) async {
    final text = await pickRecipeFile();
    if (!mounted) return;
    if (text == null) {
      _toast('未应用：已取消选择');
      return;
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      AppLog.instance.log('warn', '配方导入失败：不是合法 JSON');
      _toast('配方文件不是合法 JSON');
      return;
    }
    if (decoded is! Map) {
      _toast('配方文件格式错：顶层必须是 JSON 对象');
      return;
    }
    final session = _active;
    if (session == null) return;

    final romInfo = (decoded['rom'] as Map?)?.cast<String, Object?>();
    final version = romInfo?['version']?.toString();
    final fingerprint = (romInfo?['fingerprint'] as num?)?.toInt();
    final chunks = [
      for (final c in (decoded['chunks'] as List?) ?? const <Object>[])
        (c as Map).cast<String, Object?>(),
    ];
    final parsed = parseSemantic(decoded['semantic']);

    final versionOk = version == null || version == session.versionId;
    final fpOk = fingerprint == null || fingerprint == session.fingerprint;

    // 预览与确认
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入配方'),
        content: SingleChildScrollView(
          child: Text(
            '来源：${version ?? '未知版本'}'
            '${romInfo?['file'] == null ? '' : ' / ${romInfo!['file']}'}\n'
            '字节层：${chunks.length} 段${fpOk ? '' : '（指纹不一致，全部跳过）'}\n'
            '语义层：${_describeSemantic(parsed)}'
            '${parsed.problems.isEmpty ? '' : '\n注意：${parsed.problems.join('；')}'}'
            '${versionOk ? '' : '\n版本不匹配（$version ≠ ${session.versionId}），会被拒绝'}',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: versionOk ? () => Navigator.pop(ctx, true) : null,
            child: const Text('应用'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    // 应用前快照，结果弹窗里可一键回退
    final snap = session.snapshots.take(edit, label: 'import_recipe');
    final result = applyRecipe(
      edit,
      semantic: parsed.hasContent ? parsed : null,
      chunks: chunks,
      version: version,
      expectedFingerprint: fingerprint,
    );
    // 自动浅体检（跳过耗时的大地图/事件扫描）
    final report = RomHealth(edit).run(deep: false);
    AppLog.instance.log(
        'info',
        '应用配方：语义层 ${result.semanticChangedBytes}B / '
        '字节层 ${result.bytesChangedBytes}B / 跳过 ${result.skippedChunks} 段');
    if (!mounted) return;
    setState(() {});

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(result.problems.isEmpty ? '配方已应用' : '配方已应用（有问题）'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('改动 ${result.totalChangedBytes} 字节'
                  '（语义 ${result.semanticChangedBytes} / 字节 ${result.bytesChangedBytes}）'),
              if (report.ok)
                const Text('自动体检：未发现问题')
              else
                Text('自动体检：${report.errorCount} 处问题、'
                    '${report.warningCount} 处警告'),
              for (final p in result.problems) Text('· $p'),
              for (final p in parsed.problems) Text('· $p'),
              Text('不满意可点「回退本次导入」',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              session.snapshots.restore(edit, snap);
              Navigator.pop(ctx);
            },
            child: const Text('回退本次导入'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              if (mounted) {
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => HealthPage(edit: edit)));
              }
            },
            child: const Text('看完整体检'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  /// 预览弹窗里对语义层的一句话描述。
  String _describeSemantic(ParsedRecipe p) {
    if (!p.hasContent) return '无';
    final parts = <String>[];
    for (final x in p.semantic['presets'] as List? ?? const <Object>[]) {
      final m = x as Map;
      final targets = m['targets'];
      parts.add('预设「${m['id']}」${targets == null ? '' : '→ $targets'}');
    }
    for (final key in const ['units', 'items', 'classes']) {
      final entries = p.semantic[key] as Map?;
      if (entries != null && entries.isNotEmpty) {
        parts.add('$key ${entries.length} 个目标的字段修改');
      }
    }
    return parts.isEmpty ? '无' : parts.join('；');
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
          title: Text(_done ? '文本 ($_rowsCount)' : '文本 (加载中 $_rowsCount…)'),
          actions: [
            IconButton(
              icon: const Icon(Icons.find_replace, size: 20),
              tooltip: '全 ROM 查找/替换',
              onPressed: _writer.supported ? _openFindReplace : null,
            ),
          ]),
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

  /// 全 ROM 查找/替换：替换后整体重建列表（条目可能重定位，
  /// 旧的行缓存不可信）。
  void _openFindReplace() {
    final writer = _writer;
    final fr = TextFindReplace(writer);
    showDialog<void>(
      context: context,
      builder: (_) => _FindReplaceDialog(
        writer: writer,
        fr: fr,
        onReplaced: () {
          _rows.clear();
          _filter.clear();
          _total = 0;
          _done = false;
          _loadMore();
          setState(() {});
        },
      ),
    );
  }
}

class _TextRow {
  final int id;
  final String text;
  const _TextRow(this.id, this.text);
}

/// 全 ROM 文本查找/替换对话框。
///
/// 「查找」先列出命中条目（带文本预览），「替换全部」才真正写回；
/// 写回走 [TextFindReplace]（与单条编辑同一通道，可整体撤销）。
class _FindReplaceDialog extends StatefulWidget {
  final TextWriter writer;
  final TextFindReplace fr;

  /// 有实际替换发生时回调（调用方重建列表）。
  final VoidCallback onReplaced;

  const _FindReplaceDialog({
    required this.writer,
    required this.fr,
    required this.onReplaced,
  });

  @override
  State<_FindReplaceDialog> createState() => _FindReplaceDialogState();
}

class _FindReplaceDialogState extends State<_FindReplaceDialog> {
  final _findCtrl = TextEditingController();
  final _repCtrl = TextEditingController();
  bool _busy = false;
  List<int> _matches = const [];
  String? _summary;

  @override
  void dispose() {
    _findCtrl.dispose();
    _repCtrl.dispose();
    super.dispose();
  }

  String _previewText(int id) {
    final t = (widget.writer.currentText(id) ?? '').replaceAll('\n', ' ');
    return t.length > 40 ? '${t.substring(0, 40)}…' : t;
  }

  Future<void> _search() async {
    final f = _findCtrl.text.trim();
    if (f.isEmpty) return;
    setState(() {
      _busy = true;
      _summary = null;
    });
    await Future<void>.delayed(Duration.zero); // 让转圈先画出来
    final m = widget.fr.search(f);
    if (!mounted) return;
    setState(() {
      _matches = m;
      _busy = false;
    });
  }

  Future<void> _replace() async {
    final f = _findCtrl.text.trim();
    if (f.isEmpty) return;
    setState(() => _busy = true);
    final r = widget.fr.replaceAll(f, _repCtrl.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _matches = const [];
      _summary = '改了 ${r.changed} 条 · 未变 ${r.identical} 条 · '
          '失败 ${r.failures.length} 条'
          '${r.failures.isEmpty ? '' : '\n${r.failures.take(3).join('\n')}'
          '${r.failures.length > 3 ? '\n等 ${r.failures.length} 条' : ''}'}';
      if (r.changed > 0) widget.onReplaced();
    });
  }

  @override
  Widget build(BuildContext context) {
    final canReplace =
        _summary != null || (_matches.isNotEmpty && _repCtrl.text.isNotEmpty);
    return AlertDialog(
      title: const Text('全 ROM 查找 / 替换'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _findCtrl,
              decoration: const InputDecoration(
                isDense: true,
                labelText: '查找内容',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _search(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _repCtrl,
              decoration: const InputDecoration(
                isDense: true,
                labelText: '替换为（留空 = 删除）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton(
                  onPressed: _busy ? null : _search,
                  child: const Text('查找'),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _busy ? null : (canReplace ? _replace : null),
                  child: const Text('替换全部'),
                ),
                if (_busy) ...[
                  const SizedBox(width: 12),
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
            if (_summary != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_summary!, style: const TextStyle(fontSize: 12)),
              ),
            if (_matches.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  '命中 ${_matches.length} 条：',
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.primary),
                ),
              ),
              for (final id in _matches.take(5))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '0x${id.toRadixString(16).toUpperCase().padLeft(4, '0')}：'
                    '${_previewText(id)}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (_matches.length > 5)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('…共 ${_matches.length} 条',
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ),
            ],
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                '替换覆盖全部命中条目。改完可点主页「撤销全部」回退。',
                style: TextStyle(fontSize: 11, color: Colors.blueGrey),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
