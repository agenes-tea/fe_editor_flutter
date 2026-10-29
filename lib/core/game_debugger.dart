import 'dart:convert';
import 'dart:typed_data';

import 'editable_rom.dart';
import 'rom_info.dart';

/// 游戏内调试器（Vesly 的 TiaMfLNiAyotDI，社区称「Nergal 调试器」）安装器。
///
/// 该调试器原本是 Event Assembler + C（devkitARM）工程，编译产物是一串
/// 「往固定地址写字节」的补丁。这里把补丁数据内嵌成 assets/debugger/*.json，
/// 安装时逐块写入 [EditableRom] 的工作副本，因此：
///   - 与手工改字段走同一套流程，可整体撤销、可导出 UPS/IPS；
///   - 不依赖任何第三方插件。
///
/// 数据由 `tool/debugger_patch/`（mini-EA 构建器）从上游源码重新生成。
class GameDebuggerPatch {
  /// 补丁版本标识，同时用于 assets 文件名。
  final String id;

  /// 界面显示名。
  final String label;

  /// 适用的 ROM 版本（[RomTable.id]）。
  final String romId;

  /// 补丁块：文件偏移 → 字节。
  final List<({int offset, Uint8List data})> blocks;

  const GameDebuggerPatch({
    required this.id,
    required this.label,
    required this.romId,
    required this.blocks,
  });

  /// 命中 / 写入的字节总数。
  int get byteCount => blocks.fold(0, (n, b) => n + b.data.length);

  /// 已安装的块数（逐字节比对，全部一致才算已装）。
  int installedBlocks(Uint8List target) {
    var n = 0;
    for (final b in blocks) {
      if (b.offset + b.data.length > target.length) continue;
      var same = true;
      for (var i = 0; i < b.data.length; i++) {
        if (target[b.offset + i] != b.data[i]) {
          same = false;
          break;
        }
      }
      if (same) n++;
    }
    return n;
  }

  bool isInstalled(Uint8List target) =>
      installedBlocks(target) == blocks.length;

  /// 补丁自检：找出「写入后必然让游戏崩溃」的确定性缺陷。
  ///
  /// 只做**能在静态数据上判定**的检查，不猜运行期行为：
  /// - ARM 跳板 `7847c04600c09fe51cff2fe1` 之后的 u32 目标必须是 ROM 内合法 GBA 指针；
  /// - 目标若落在本次写入的字节范围内，说明跳板会跳进别人的数据里。
  ///
  /// 返回人类可读的问题列表；空列表表示通过。
  List<String> validate(int romLength) {
    final problems = <String>[];
    final written = <int, ({int start, int end})>{};
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      written[i] = (start: b.offset, end: b.offset + b.data.length);
    }

    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      if (b.data.length < 16) continue;
      if (b.data[0] != 0x78 ||
          b.data[1] != 0x47 ||
          b.data[2] != 0xC0 ||
          b.data[3] != 0x46) {
        continue;
      }
      final target = b.data[12] |
          (b.data[13] << 8) |
          (b.data[14] << 16) |
          (b.data[15] << 24);
      if (target < 0x08000000 || target >= 0x08000000 + romLength) {
        problems.add('跳板 @0x${b.offset.toRadixString(16).toUpperCase()} '
            '目标 0x${target.toRadixString(16).padLeft(8, '0').toUpperCase()} '
            '不在 ROM 范围内');
        continue;
      }
      final targetOffset = target - 0x08000000;
      for (final entry in written.entries) {
        if (entry.key == i) continue;
        final r = entry.value;
        if (targetOffset >= r.start && targetOffset < r.end) {
          problems.add('跳板 @0x${b.offset.toRadixString(16).toUpperCase()} '
              '目标 0x${target.toRadixString(16).toUpperCase()} '
              '落在另一个写入块 0x${r.start.toRadixString(16).toUpperCase()} 内部');
          break;
        }
      }
    }
    return problems;
  }
}

/// 调试器构建配置：语言 × 说明。
class GameDebuggerVariant {
  final String id;
  final String label;
  final String note;
  const GameDebuggerVariant(this.id, this.label, this.note);
}

/// 可选语言。中文版沿用日版字模（cp932 码位），菜单名与说明都已汉化。
const gameDebuggerVariants = <GameDebuggerVariant>[
  GameDebuggerVariant('fe8_zh', '中文菜单', '菜单与说明已汉化，用日版字模渲染'),
  GameDebuggerVariant('fe8_en', '英文菜单', '上游原版文本（ASCII，与原帖截图一致）'),
];

/// 支持的 ROM：目前只有 FE8 日版/美版（16MB 原版布局）。
///
/// 该补丁把代码写进固定 ROM 地址（钩子点、`.rodata` 槽位），
/// 因此**只对布局完全一致的原版 FE8 有效**；改版 ROM 地址漂移，不适用。
bool gameDebuggerSupports(RomTable table) =>
    table.id == 'FE8J' || table.id == 'FE8U';

/// 从 assets 解析一份补丁。
GameDebuggerPatch parseGameDebuggerPatch(String json) {
  final m = jsonDecode(json) as Map<String, dynamic>;
  final blocks = <({int offset, Uint8List data})>[];
  for (final item in (m['blocks'] as List)) {
    final pair = item as List;
    blocks.add((
      offset: pair[0] as int,
      data: Uint8List.fromList(_hexToBytes(pair[1] as String)),
    ));
  }
  return GameDebuggerPatch(
    id: m['rom'] as String,
    label: m['rom'] as String,
    romId: m['rom'] as String,
    blocks: blocks,
  );
}

List<int> _hexToBytes(String hex) {
  final out = List<int>.filled(hex.length ~/ 2, 0);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// 安装结果。
class GameDebuggerInstallResult {
  /// 实际改动的字节数。
  final int changedBytes;

  /// 安装前就已一致的块数（用于「重复安装」提示）。
  final int alreadyInstalledBlocks;

  final int totalBlocks;

  const GameDebuggerInstallResult({
    required this.changedBytes,
    required this.alreadyInstalledBlocks,
    required this.totalBlocks,
  });

  bool get alreadyInstalled => alreadyInstalledBlocks == totalBlocks;
}

/// 把补丁写入可编辑 ROM。
///
/// 只走 [RomBuffer] 的写入接口，并把每个被改动的字节记进 [EditableRom.edits]，
/// 所以「撤销全部」能把这套补丁完整撤掉，导出 UPS 时也只会包含真实差异。
GameDebuggerInstallResult installGameDebugger(
    EditableRom edit, GameDebuggerPatch patch) {
  final buf = edit.buffer;
  final already = patch.installedBlocks(buf.data);
  var changed = 0;
  for (final block in patch.blocks) {
    for (var i = 0; i < block.data.length; i++) {
      final addr = block.offset + i;
      final before = buf.u8(addr);
      final after = block.data[i];
      if (before == after) continue;
      buf.writeU8(addr, after);
      changed++;
    }
  }
  return GameDebuggerInstallResult(
    changedBytes: changed,
    alreadyInstalledBlocks: already,
    totalBlocks: patch.blocks.length,
  );
}
