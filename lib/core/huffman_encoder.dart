import 'dart:typed_data';

import 'fe_rom.dart';

/// 用 **ROM 自带的 Huffman 树** 把「已解码的原始字节」重新压缩成位流。
///
/// 思路：`FeRom.decodeTextBytes` 是「位流 → 逐位查树 → 叶子码 → 展开成字节」。
/// 编码就是它的逆：把树从根遍历一遍，记下「字节序列 → 叶子位路径」，
/// 再用动态规划把目标字节序列切成一串叶子，拼出位串（LSB-first 打包），
/// 末尾补上终止叶（低字节为 0 的叶子）的路径。
///
/// 这样得到的位流，用 ROM 自己的 `decodeTextBytes` 能解回同样的字节——
/// 不依赖任何版本的软编码表，改版搬过树也能用。往返测试是唯一的正确性保证。
class HuffmanEncoder {
  final FeRom rom;
  HuffmanEncoder(this.rom);

  /// 单字节叶子：byte -> 位路径。
  final Map<int, List<int>> _single = {};

  /// 双字节叶子：(b0 | b1<<8) -> 位路径（与解码展开顺序一致）。
  final Map<int, List<int>> _double = {};

  /// 终止叶（code 低字节为 0）的位路径。
  List<int>? _terminator;

  bool _built = false;

  void _build() {
    if (_built) return;
    _built = true;
    final data = rom.data;
    final treeBase = rom.huffmanTreeBase;
    final root = rom.huffmanTreeDataBase;

    void walk(int td, List<int> path) {
      if (path.length > 64) return; // 防坏树递归
      final v = FeRom.u32(data, td);
      if ((v & 0x80000000) != 0) {
        final code = v & 0xFFFF;
        // 解码器把「code<=0 或低字节为 0」当终止叶
        if (code <= 0 || (code & 0xFF) == 0) {
          _terminator ??= List<int>.from(path);
          return;
        }
        // 展开顺序与 decodeTextBytes 一致：先低字节、后高字节
        if (code > 0xFF) {
          final key = (code & 0xFF) | (((code >> 8) & 0xFF) << 8);
          _double.putIfAbsent(key, () => List<int>.from(path));
        } else {
          _single.putIfAbsent(code, () => List<int>.from(path));
        }
        return;
      }
      final c0 = FeRom.u16(data, td);
      final c1 = FeRom.u16(data, td + 2);
      walk(treeBase + c0 * 4, [...path, 0]);
      walk(treeBase + c1 * 4, [...path, 1]);
    }

    walk(root, const []);
  }

  /// 树是否可用（能建出叶子表与终止叶）。
  bool get available {
    _build();
    return _terminator != null && (_single.isNotEmpty || _double.isNotEmpty);
  }

  /// 目标字节里是否有无法覆盖的字节（找不到对应叶子）。用于写入前的可编码性判断。
  bool canEncode(List<int> bytes) => encodeBytes(bytes) != null;

  /// 把已解码的原始字节序列编码成压缩位流（LSB-first 打包，末尾带终止叶）。
  /// 若某个字节无法用叶子覆盖则返回 null。
  Uint8List? encodeBytes(List<int> bytes) {
    _build();
    final term = _terminator;
    if (term == null) return null;
    final n = bytes.length;

    // 记忆化 DFS：memo[i] = 从 i 编码到结尾的完整位路径（含终止叶）
    final memo = List<List<int>?>.filled(n + 1, null);
    final solved = List<bool>.filled(n + 1, false);

    List<int>? dfs(int i) {
      if (i == n) return term;
      if (solved[i]) return memo[i];
      solved[i] = true;
      // 先试双字节（更长匹配优先，减少位串长度）
      if (i + 1 < n) {
        final p = _double[bytes[i] | (bytes[i + 1] << 8)];
        if (p != null) {
          final rest = dfs(i + 2);
          if (rest != null) return memo[i] = [...p, ...rest];
        }
      }
      final p1 = _single[bytes[i]];
      if (p1 != null) {
        final rest = dfs(i + 1);
        if (rest != null) return memo[i] = [...p1, ...rest];
      }
      memo[i] = null;
      return null;
    }

    final bits = dfs(0);
    if (bits == null) return null;

    final out = <int>[];
    var cur = 0;
    var cnt = 0;
    for (final b in bits) {
      if (b != 0) cur |= 1 << cnt;
      cnt++;
      if (cnt == 8) {
        out.add(cur);
        cur = 0;
        cnt = 0;
      }
    }
    if (cnt > 0) out.add(cur); // 末尾不足一字节补 0
    return Uint8List.fromList(out);
  }
}
