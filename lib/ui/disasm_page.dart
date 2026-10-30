import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/disassembler.dart';
import '../core/editable_rom.dart';

/// 反汇编查看器（只读）。
///
/// 按 GBA 地址列出「地址 / 机器码 / 汇编」，支持：
/// - ARM / Thumb 切换（GBA 是 ARM7TDMI，代码里两套指令集混用）
/// - 跳转到任意地址（十六进制输入，接受 0x08000000 形式）
/// - 按汇编文本搜索（如 `ldr r0`、`bl`）
/// - 点击带分支目标的指令跳到目标（跟随 `b` / `bl`）
///
/// 只读：改机器码请用十六进制编辑器（那里有可撤销的写入通道）。
class DisasmPage extends StatefulWidget {
  final EditableRom edit;

  /// 初始位置（文件偏移）；0 表示从 ROM 开头。
  final int initialOffset;

  const DisasmPage({super.key, required this.edit, this.initialOffset = 0});

  @override
  State<DisasmPage> createState() => _DisasmPageState();
}

class _DisasmPageState extends State<DisasmPage> {
  static const int _visibleCount = 400;

  late final ArmDisassembler _dis = ArmDisassembler(widget.edit.buffer.data);
  late final ScrollController _scroll = ScrollController();
  final _gotoCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();

  DisasmMode _mode = DisasmMode.thumb;
  late int _base = widget.initialOffset;

  /// 跳转/点分支时是否按目标处的内容自动切 ARM/Thumb（v2.3.11）。
  bool _autoMode = true;

  /// 搜索命中（文件偏移）
  List<int> _hits = const [];
  int _hitIndex = 0;

  /// 正在改机器码的行（文件偏移）；-1 表示未选中
  int _editing = -1;

  /// 正在输入的十六进制（0..2 位，满 2 位即写回）
  String _input = '';

  @override
  void initState() {
    super.initState();
    // 先按内容猜一次模式（游戏从 Thumb 开始执行，但数据区不一定）
    _mode = guessModeAt(_dis.length > 0 ? _dis.data : Uint8List(0), _base,
        fallback: DisasmMode.thumb);
    _base -= _base % _mode.size;
  }

  @override
  void dispose() {
    _scroll.dispose();
    _gotoCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  List<DisasmLine> get _lines =>
      _dis.disassemble(_base, _mode, _visibleCount);

  void _jumpTo(int offset, {bool autoMode = true}) {
    if (offset < 0) offset = 0;
    var mode = _mode;
    if (_autoMode && autoMode) {
      mode = guessModeAt(_dis.data, offset, fallback: _mode);
    }
    final maxOffset = _dis.length - mode.size;
    if (offset > maxOffset) offset = maxOffset < 0 ? 0 : maxOffset;
    setState(() {
      _mode = mode;
      _base = offset - offset % mode.size;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _gotoDialog() async {
    _gotoCtrl.text = (_base + 0x08000000).toRadixString(16).toUpperCase();
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('跳转到地址'),
        content: TextField(
          controller: _gotoCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '如 08000000 或 0x1234',
            helperText: '支持 GBA 地址（08xxxxxx）与文件偏移',
          ),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-FxX]')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _gotoCtrl.text),
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    if (input == null) return;
    final off = parseRomAddress(input, _dis.length);
    if (off == null) {
      _toast('地址无效（需在 ROM 范围内）');
      return;
    }
    _jumpTo(off);
  }

  void _search() {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) {
      _toast('请输入要搜索的汇编写法，如 ldr r0 或 bl');
      return;
    }
    final hits = _dis.search(q, _mode, from: _base);
    setState(() {
      _hits = hits;
      _hitIndex = 0;
    });
    if (hits.isEmpty) {
      _toast('没找到「$q」');
      return;
    }
    _jumpTo(hits.first);
  }

  void _nextHit() {
    if (_hits.isEmpty) {
      _toast('先搜索一次');
      return;
    }
    final next = (_hitIndex + 1) % _hits.length;
    setState(() => _hitIndex = next);
    _jumpTo(_hits[next]);
  }

  /// 从当前基点追踪一层函数结构：调用的子函数 + 字面池引用的数据。
  Future<void> _traceDialog() async {
    final node = traceFunction(_dis.data, _base, _mode);
    final ptrs = romPointersIn(node, _dis.length);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('函数 0x${(_base + 0x08000000).toRadixString(16).toUpperCase()}'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  node.returns
                      ? '扫到返回指令，是一个完整函数'
                      : '未扫到返回指令（可能被截断或不是函数入口）',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 10),
                Text('调用的子函数（${node.calls.length}）',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold)),
                if (node.calls.isEmpty)
                  const Text('（没有 bl 调用）', style: TextStyle(fontSize: 12)),
                for (final c in node.calls.take(20))
                  InkWell(
                    onTap: () {
                      Navigator.pop(ctx);
                      _jumpTo(c);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text(
                        '→ 0x${(c + 0x08000000).toRadixString(16).toUpperCase()}',
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: Theme.of(ctx).colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                Text('字面池引用的数据（${node.literals.length}）',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold)),
                if (ptrs.isEmpty && node.literals.isEmpty)
                  const Text('（没有字面池读取）', style: TextStyle(fontSize: 12)),
                for (final l in node.literals.take(20))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '=0x${l.value.toRadixString(16).toUpperCase().padLeft(8, '0')}'
                      ' @0x${(l.addr + 0x08000000).toRadixString(16).toUpperCase()}',
                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    final theme = Theme.of(context);
    final hitSet = _hits.toSet();
    return Scaffold(
      appBar: AppBar(
        title: const Text('反汇编查看器'),
        actions: [
          IconButton(
            tooltip: '追踪当前函数（调用了谁、引用了哪些数据）',
            icon: const Icon(Icons.account_tree_outlined),
            onPressed: _traceDialog,
          ),
          IconButton(
            tooltip: '跳转地址',
            icon: const Icon(Icons.my_location),
            onPressed: _gotoDialog,
          ),
          IconButton(
            tooltip: '回到开头',
            icon: const Icon(Icons.vertical_align_top),
            onPressed: () => _jumpTo(0),
          ),
          if (widget.edit.hasChanges)
            IconButton(
              tooltip: '撤销全部机器码修改',
              icon: const Icon(Icons.undo),
              onPressed: () => setState(() {
                widget.edit.revertAll();
                _editing = -1;
                _input = '';
              }),
            ),
        ],
      ),
      body: Column(
        children: [
          _toolbar(),
          if (_hits.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              color: theme.colorScheme.surfaceContainerHighest,
              child: Text(
                '「${_searchCtrl.text.trim()}」命中 ${_hits.length} 处'
                '（第 ${_hitIndex + 1} 处）',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          Expanded(child: _list(lines, hitSet)),
          _editBar(),
        ],
      ),
    );
  }

  Widget _toolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        children: [
          Row(
            children: [
              SegmentedButton<DisasmMode>(
                segments: const [
                  ButtonSegment(value: DisasmMode.thumb, label: Text('Thumb')),
                  ButtonSegment(value: DisasmMode.arm, label: Text('ARM')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) {
                  final m = s.first;
                  setState(() {
                    _mode = m;
                    _hits = const [];
                  });
                  _jumpTo(_base);
                },
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '0x${(_base + 0x08000000).toRadixString(16).toUpperCase()}'
                  ' · ${_mode.size} 字节/条',
                  style: const TextStyle(fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // 自动识别：跳转时按目标处的内容切 ARM/Thumb
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: _autoMode ? '自动识别指令集：开' : '自动识别指令集：关',
                icon: Icon(
                  _autoMode ? Icons.auto_mode : Icons.auto_mode_outlined,
                  size: 18,
                ),
                onPressed: () => setState(() => _autoMode = !_autoMode),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '搜索汇编，如 ldr r0 / bl / mov',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filledTonal(
                visualDensity: VisualDensity.compact,
                onPressed: _search,
                icon: const Icon(Icons.search),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '下一个命中',
                onPressed: _nextHit,
                icon: const Icon(Icons.keyboard_arrow_down),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String mName(DisasmMode m) => m.label;

  Widget _list(List<DisasmLine> lines, Set<int> hits) {
    final theme = Theme.of(context);
    final maxOffset = _dis.length - _mode.size;
    return ListView.builder(
      controller: _scroll,
      itemCount: lines.length + 2,
      itemBuilder: (ctx, i) {
        // 首尾各留一行「上一屏 / 下一屏」，方便翻页
        if (i == 0) {
          return _navTile(
            icon: Icons.keyboard_arrow_up,
            label: '上一屏',
            enabled: _base > 0,
            onTap: () {
              final step = _visibleCount * _mode.size;
              _jumpTo((_base - step).clamp(0, maxOffset < 0 ? 0 : maxOffset));
            },
          );
        }
        if (i == lines.length + 1) {
          return _navTile(
            icon: Icons.keyboard_arrow_down,
            label: '下一屏',
            enabled: _base + lines.length * _mode.size <= maxOffset,
            onTap: () {
              final step = _visibleCount * _mode.size;
              _jumpTo((_base + step).clamp(0, maxOffset < 0 ? 0 : maxOffset));
            },
          );
        }
        final line = lines[i - 1];
        final isHit = hits.contains(line.offset);
        return Material(
          color: isHit ? theme.colorScheme.primaryContainer : null,
          child: InkWell(
            onTap: line.isBranch
                ? () => _jumpTo(line.target)
                : () => _selectLine(line),
            onLongPress: () => _selectLine(line),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 74,
                    child: Text(
                      line.addressText,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  SizedBox(
                    // ARM 是 8 个十六进制字符，Thumb 是 4 个；按模式给宽度，
                    // 否则 8 位会折成两行（实测机型上很明显）
                    width: _mode == DisasmMode.arm ? 62 : 34,
                    child: _hexCell(line),
                  ),
                  Expanded(
                    child: Text(
                      line.text,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: line.isBranch ? Colors.blue.shade700 : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 机器码单元格：逐字节可点（选中后底部键盘可改值）。
  ///
  /// 未选中该行时只显示文本，不响应点击（避免误触）。
  Widget _hexCell(DisasmLine line) {
    final editingThis = _editing == line.offset;
    final scheme = Theme.of(context).colorScheme;
    if (!editingThis) {
      return Text(
        line.hex,
        maxLines: 1,
        softWrap: false,
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < line.bytes.length; i++)
          GestureDetector(
            onTap: () => _pickByte(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: i == _editByte
                    ? scheme.primaryContainer
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
              child: Text(
                line.bytes[i]
                    .toRadixString(16)
                    .padLeft(2, '0')
                    .toUpperCase(),
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: i == _editByte ? scheme.primary : null,
                  fontWeight: i == _editByte ? FontWeight.bold : null,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 底部编辑条：选中某条指令后出现，用数字键盘改机器码。
  Widget _editBar() {
    if (_editing < 0) return const SizedBox.shrink();
    final line = _dis.decode(_editing, _mode);
    if (line == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final byteCount = line.bytes.length;
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
                      '改机器码 · 0x${line.addressText}'
                      ' · 第 ${_editByte + 1}/$byteCount 字节'
                      '${_input.isEmpty ? '' : ' · 输入 $_input'}',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: '取消编辑',
                  onPressed: () => setState(() {
                    _editing = -1;
                    _input = '';
                  }),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Column(
              children: [
                _padRow(const ['0', '1', '2', '3', '4', '5', '6', '7']),
                const SizedBox(height: 4),
                _padRow(const ['8', '9', 'A', 'B', 'C', 'D', 'E', 'F']),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '改错就点右上角撤销图标整体还原；也可导出 UPS 补丁后再比对',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _padRow(List<String> digits) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (final d in digits)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: InkWell(
                onTap: () => _pad(d),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  height: 42,
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
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _navTile({
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: enabled ? null : Colors.grey),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: enabled ? null : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 选中/取消某条指令（长按进入改机器码）。
  void _selectLine(DisasmLine line) {
    setState(() {
      if (_editing == line.offset) {
        _editing = -1;
        _input = '';
      } else {
        _editing = line.offset;
        _input = '';
      }
    });
  }

  /// 点选某个机器码字节（第 [index] 个）并准备输入。
  void _pickByte(int index) {
    if (_editing < 0) return;
    setState(() {
      _editByte = index;
      _input = '';
    });
  }

  /// 当前正在改的字节序号（0 起）。
  int _editByte = 0;

  /// 数字键盘输入一位：满两位写回并跳到下一个字节。
  void _pad(String hex) {
    if (_editing < 0) return;
    final line = _dis.decode(_editing, _mode);
    if (line == null) return;
    final digits = '$_input$hex';
    if (digits.length < 2) {
      setState(() => _input = digits);
      return;
    }
    final value = int.tryParse(digits, radix: 16);
    if (value == null) return;
    final bytes = line.bytes.toList();
    if (_editByte >= bytes.length) return;
    bytes[_editByte] = value;
    final changed = widget.edit.writeInstruction(_editing, bytes);
    setState(() {
      _input = '';
      if (changed > 0) {
        // 写成功后自动移到下一个字节；到末尾就停在最后一个
        if (_editByte < bytes.length - 1) _editByte++;
      }
    });
    if (changed == 0) _toast('该值与原值相同，未写入');
  }

  void _copyLine(DisasmLine line) {
    Clipboard.setData(ClipboardData(
      text: '${line.addressText}  ${line.hex}  ${line.text}',
    ));
    _toast('已复制该行');
  }
}
