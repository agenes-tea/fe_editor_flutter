import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../core/app_log.dart';
import '../core/editable_rom.dart';
import '../core/game_debugger.dart';

/// 游戏内调试器安装页。
///
/// 与「修改器」里那些按字段写入的预设不同，这类功能要往 ROM 的固定地址
/// 打一整段补丁（钩子、代码、数据表、扩展后的 Huffman 树），
/// 所以单独一页，装之前把作用与限制讲清楚。
class GameDebuggerPage extends StatefulWidget {
  final EditableRom edit;

  const GameDebuggerPage({super.key, required this.edit});

  @override
  State<GameDebuggerPage> createState() => _GameDebuggerPageState();
}

class _GameDebuggerPageState extends State<GameDebuggerPage> {
  String _variant = gameDebuggerVariants.first.id;
  GameDebuggerPatch? _patch;
  bool _loading = false;
  String? _error;

  /// 补丁自检发现的问题（空表示通过）。
  List<String> _problems = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _supported => gameDebuggerSupports(widget.edit.rom.table);

  Future<void> _load() async {
    if (!_supported) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json =
          await rootBundle.loadString('assets/debugger/$_variant.json');
      if (!mounted) return;
      final patch = parseGameDebuggerPatch(json);
      setState(() {
        _patch = patch;
        _problems = patch.validate(widget.edit.buffer.length);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '读取补丁数据失败：$e';
        _loading = false;
      });
    }
  }

  Future<void> _install() async {
    final patch = _patch;
    if (patch == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('安装游戏内调试器'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('将写入 ${patch.blocks.length} 个补丁块 / '
                  '${patch.byteCount} 字节到 ROM。'),
              const SizedBox(height: 8),
              const Text(
                '装好后在战斗地图上按 B 呼出菜单；\n'
                'L + 上 + 左 可开关调试器（关闭后按 B 不再响应）。',
              ),
              const SizedBox(height: 8),
              Text(
                '改动只作用于内存副本，可随时撤销；导出 ROM 时才落盘。',
                style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade700),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('安装')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final r = installGameDebugger(widget.edit, patch);
    AppLog.instance.log(
      'info',
      '游戏内调试器（$_variant）：写入 ${r.changedBytes} 字节，'
          '已安装块 ${r.alreadyInstalledBlocks}/${r.totalBlocks}',
    );
    setState(() {});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(r.alreadyInstalled
            ? '这套补丁此前已安装，没有新的改动'
            : '已安装：写入 ${r.changedBytes} 字节'),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final edit = widget.edit;
    final patch = _patch;
    final installed = patch?.isInstalled(edit.buffer.data) ?? false;

    return Scaffold(
      appBar: AppBar(title: const Text('游戏内调试器')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (!_supported)
            _warning(
              '当前 ROM 是 ${edit.rom.table.id}，暂不支持。\n'
              '该调试器把代码写进固定 ROM 地址，只对布局一致的原版 FE8 有效'
              '（改版 ROM 地址会漂移）。',
            )
          else
            _warning(
              '这是「装进 ROM、在游戏里运行」的调试器，不是数值预设。'
              '它会在战场上呼出菜单，直接改当前章节的金币 / 回合 / 单位属性、'
              '载入单位、编辑地图与陷阱等。',
            ),
          const SizedBox(height: 8),
          if (_supported) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('菜单语言', style: Theme.of(context).textTheme.titleSmall),
                    for (final v in gameDebuggerVariants)
                      RadioListTile<String>(
                        value: v.id,
                        groupValue: _variant,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        onChanged: (val) {
                          if (val == null) return;
                          setState(() {
                            _variant = val;
                            _patch = null;
                          });
                          _load();
                        },
                        title:
                            Text(v.label, style: const TextStyle(fontSize: 14)),
                        subtitle:
                            Text(v.note, style: const TextStyle(fontSize: 11)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('状态', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Text(
                        '当前版本安装后游戏无法启动（白屏/黑屏），已知会破坏文本引擎。\n'
                        '请勿在主 ROM 上安装，仅供排查使用。',
                        style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: Colors.red.shade900),
                      ),
                    ),
                    if (_problems.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('补丁自检：发现 ${_problems.length} 处必然导致崩溃的写入',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.orange.shade900)),
                            const SizedBox(height: 4),
                            for (final p in _problems.take(3))
                              Text('· $p',
                                  style: TextStyle(
                                      fontSize: 11,
                                      height: 1.4,
                                      color: Colors.orange.shade900)),
                            if (_problems.length > 3)
                              Text('· 其余 ${_problems.length - 3} 处略',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.orange.shade900)),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    if (_loading)
                      const Text('正在读取补丁数据…', style: TextStyle(fontSize: 13))
                    else if (_error != null)
                      Text(_error!,
                          style: TextStyle(
                              fontSize: 13, color: Colors.red.shade700))
                    else if (patch != null) ...[
                      Text(
                        installed ? '已安装（补丁字节与目标 ROM 一致）' : '尚未安装',
                        style: TextStyle(
                          fontSize: 13,
                          color: installed
                              ? Colors.green.shade800
                              : Colors.orange.shade900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                          '补丁块 ${patch.blocks.length} 个 / ${patch.byteCount} 字节',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.red.shade700,
                          ),
                          onPressed: _loading ? null : _install,
                          icon:
                              const Icon(Icons.warning_amber_rounded, size: 18),
                          label: Text(installed ? '重新安装（已知不可用）' : '仍然安装（有风险）'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            _usageCard(),
          ],
          const SizedBox(height: 8),
          _credits(),
        ],
      ),
    );
  }

  Widget _usageCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('装好之后怎么用', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              const Text(
                '· 战斗地图上按 B 呼出菜单（光标处的单位即被操作对象）\n'
                '· L / R 切换选中的单位\n'
                '· 左 / 右 或菜单里的「页码」切换页面\n'
                '· L + 上 + 左 可整体开关调试器（关闭后按 B 不再响应）',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 8),
              Text(
                '注意：部分功能（无敌、自动演出、敌军控制）会改写原版函数的行为，'
                '只在本局生效，不写存档。',
                style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade700),
              ),
            ],
          ),
        ),
      );

  Widget _credits() => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('作者与来源', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              const Text(
                'Vesly 的「This is a message from Lord Nergal. I await you on the dread isle.」\n'
                '（社区简称 Nergal 调试器 / TiaMfLNiAyotDI）\n'
                '源码：github.com/Veslyquix/ASM（Debugger 目录，GPL-3.0）',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 6),
              Text(
                '本工具只把它的补丁数据重新打包成可离线安装的形式，'
                '未修改调试器本体行为。',
                style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade700),
              ),
            ],
          ),
        ),
      );

  Widget _warning(String text) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.blue.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.blue.shade200),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 12.5, height: 1.5, color: Colors.blue.shade900)),
      );
}
