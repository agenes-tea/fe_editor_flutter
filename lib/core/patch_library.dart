import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle, AssetManifest;

/// FEBuilderGBA 补丁（PATCH_*.txt + 二进制块）的解析与应用。
///
/// 支持范围：只处理「简单补丁」——用 `BIN:地址=文件` 写入固定字节。
/// 不含 `$宏`（$FREEAREA / $GREP）、EA、TEXT、COPY、JUMP 等需要
/// 地址协商或汇编的指令；遇到这类补丁会在解析阶段标记为不支持。
class FePatch {
  final String name;
  final String dirPath;
  final String info;
  final String author;

  /// 已安装判定：偏移 -> 期望字节。全部匹配即视为已打补丁。
  final List<PatchCheck> checks;

  /// 写入操作：偏移 + 数据文件（相对补丁目录）
  final List<PatchWrite> writes;

  /// 不支持的原因；为 null 表示可安装
  final String? unsupportedReason;

  /// 补丁是否来自 APK 内置 assets（而不是文件系统目录）
  final bool asset;

  FePatch({
    required this.name,
    required this.dirPath,
    required this.info,
    required this.author,
    required this.checks,
    required this.writes,
    this.unsupportedReason,
    this.asset = false,
  });

  bool get installable => unsupportedReason == null && writes.isNotEmpty;

  /// 读入所有二进制块后返回可直接写入的字节。
  Future<List<({int offset, Uint8List data})>> loadWrites() async {
    final out = <({int offset, Uint8List data})>[];
    for (final w in writes) {
      final key = '$dirPath/${w.fileName}';
      Uint8List bytes;
      if (asset) {
        bytes = await _loadAsset(key);
      } else {
        final file = File(key);
        if (!await file.exists()) continue;
        bytes = await file.readAsBytes();
      }
      if (w.absolute) {
        bytes = _normalizeAbsoluteRefs(bytes, w.offset);
      }
      if (w.relocateTo != null) {
        bytes = _relocateLdr(bytes, w.offset, w.relocateTo!);
      }
      out.add((offset: w.offset, data: bytes));
    }
    return out;
  }


  /// 补丁块若以完整 GBA 地址引用自身或邻近位置，需要改成实际落点的地址。
  ///
  /// 例：FE6 的 48command_hack 写着 `BIN:0x08053DD4=...bin`，块内含
  /// `0x0804A768` 这种绝对地址；按偏移写入时必须同步换成所在块的新地址。
  static Uint8List _normalizeAbsoluteRefs(Uint8List src, int blockOffset) {
    final data = Uint8List.fromList(src);
    final blockPtr = blockOffset + 0x08000000;
    for (var i = 0; i + 4 <= data.length; i += 4) {
      final v = data[i] | (data[i + 1] << 8) | (data[i + 2] << 16) | (data[i + 3] << 24);
      if (v >= 0x08000000 && v < 0x0A000000) {
        // 指向 ROM 之外的绝对地址保持不变；指向块内/块后的按相对位置修正
        final rel = v - blockPtr;
        if (rel >= 0 && rel < data.length) {
          final nv = blockPtr + rel;
          data[i] = nv & 0xFF;
          data[i + 1] = (nv >> 8) & 0xFF;
          data[i + 2] = (nv >> 16) & 0xFF;
          data[i + 3] = (nv >> 24) & 0xFF;
        }
      }
    }
    return data;
  }

  /// 移植自 FEBuilderGBA 的 ChangeAddress：
  /// 把补丁块里 LDR 字面量中指向原地址区间的指针，改写到新地址。
  static Uint8List _relocateLdr(Uint8List src, int allocOffset, int baseOffset) {
    final data = Uint8List.fromList(src);
    final basePtr = baseOffset + 0x08000000;
    final allocPtr = allocOffset + 0x08000000;
    final end = basePtr + data.length;
    for (var i = 0; i + 4 <= data.length; i += 4) {
      final v = data[i] | (data[i + 1] << 8) | (data[i + 2] << 16) | (data[i + 3] << 24);
      if (v >= basePtr && v <= end) {
        final nv = allocPtr + (v - basePtr);
        data[i] = nv & 0xFF;
        data[i + 1] = (nv >> 8) & 0xFF;
        data[i + 2] = (nv >> 16) & 0xFF;
        data[i + 3] = (nv >> 24) & 0xFF;
      }
    }
    return data;
  }
}

class PatchCheck {
  final int offset;
  final Uint8List expected;
  const PatchCheck(this.offset, this.expected);
}

class PatchWrite {
  final int offset;
  final String fileName;

  /// `BIN:地址:N=文件` 里的 N：把块内指针从「地址」重定位到 N
  final int? relocateTo;

  /// 补丁里该地址写成完整 GBA 地址（0x08xxxxxx）而非文件偏移；
  /// 这种写法下块内的自引用也会是绝对地址。
  final bool absolute;

  const PatchWrite(
    this.offset,
    this.fileName, {
    this.relocateTo,
    this.absolute = false,
  });
}

/// 从 assets 读取。打包后文件名里的空格等字符可能被 URL 编码
/// （如 `A B.txt` 存成 `A%20B.txt`），两种 key 都试一下。
Future<Uint8List> _loadAsset(String key) async {
  try {
    final data = await rootBundle.load(key);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (_) {
    final encoded = key.split('/').map(Uri.encodeComponent).join('/');
    if (encoded == key) rethrow;
    final data = await rootBundle.load(encoded);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}

/// 补丁库：扫描一个目录下的所有 PATCH_*.txt。
class PatchLibrary {
  final List<FePatch> patches = [];
  int unsupportedCount = 0;

  /// 从文件系统目录加载（桌面 / 测试用）。
  static Future<PatchLibrary> load(String rootDir) async {
    final lib = PatchLibrary();
    final dir = Directory(rootDir);
    if (!await dir.exists()) return lib;

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final base = entity.uri.pathSegments.last;
      if (!base.startsWith('PATCH_') || !base.endsWith('.txt')) continue;
      final patch = await _parseFile(entity.path, () => entity.readAsBytes());
      if (patch == null) continue;
      if (patch.installable) {
        lib.patches.add(patch);
      } else {
        lib.unsupportedCount++;
      }
    }
    lib.patches.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return lib;
  }

  /// 从 Flutter assets 加载（APK 内使用）。
  ///
  /// 安卓上 assets 不是真实文件路径，只能通过 AssetManifest 枚举再按 key 读。
  static Future<PatchLibrary> loadFromAssets(String versionDir) async {
    final lib = PatchLibrary();
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final prefix = '$versionDir/';

    final keys = manifest
        .listAssets()
        .where((k) => k.startsWith(prefix) && k.endsWith('.txt'))
        .where((k) => k.split('/').last.startsWith('PATCH_'))
        .toList();

    for (final key in keys) {
      FePatch? patch;
      try {
        patch = await _parseFile(
          key,
          () => _loadAsset(key),
          assetKey: key,
        );
      } catch (_) {
        patch = null;
      }
      if (patch == null) continue;
      if (patch.installable) {
        lib.patches.add(patch);
      } else {
        lib.unsupportedCount++;
      }
    }
    lib.patches.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return lib;
  }

  static Future<FePatch?> _parseFile(
    String path,
    Future<Uint8List> Function() read, {
    String? assetKey,
  }) async {
    late String text;
    try {
      text = utf8.decode(await read(), allowMalformed: true);
    } catch (_) {
      return null;
    }
    if (text.startsWith('\uFEFF')) text = text.substring(1);

    final dirPath = assetKey != null
        ? assetKey.substring(0, assetKey.lastIndexOf('/'))
        : File(path).parent.path;
    final checks = <PatchCheck>[];
    final writes = <PatchWrite>[];
    var info = '';
    var author = '';
    String? reason;

    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('//')) continue;

      if (line.startsWith('INFO.zh=')) {
        if (info.isEmpty) info = _cleanInfo(line.substring(8));
        continue;
      }
      if (line.startsWith('INFO.en=')) {
        if (info.isEmpty) info = _cleanInfo(line.substring(8));
        continue;
      }
      if (line.startsWith('INFO=')) {
        if (info.isEmpty) info = _cleanInfo(line.substring(5));
        continue;
      }
      if (line.startsWith('AUTHOR=')) {
        author = line.substring(7).trim();
        continue;
      }
      if (line.startsWith('PATCHED_IF:')) {
        final c = _parseCheck(line.substring(11));
        if (c != null) checks.add(c);
        continue;
      }
      if (line.startsWith('BIN:')) {
        final w = _parseWrite(line.substring(4));
        if (w == null) {
          reason ??= '含不支持的地址写法（宏或非固定地址）';
        } else {
          writes.add(w);
        }
        continue;
      }
      // 其它会改变 ROM 结构的指令：不支持
      if (RegExp(r'^(EA|TEXT|TEXTADV|TEXT_IMPORT|COPY|JUMP|EXTENDS|SLIDE|CLEAR|UNINSTALL|STRUCT|IMAGE|BINP|BINAP|BINF|CSV|ASM|ASSERT|SWITCH|W0|W2|W4|B0|B1|B2|B3|B4|B5):')
          .hasMatch(line)) {
        reason ??= '使用了需要汇编/资源处理的指令';
      }
    }

    final baseName = path.split('/').last;
    final name = baseName
        .replaceFirst('PATCH_', '')
        .replaceFirst(RegExp(r'\.txt$'), '');
    final dirName = dirPath.split('/').last;
    // 补丁名取文件名；文件名与目录名不一致时补上目录名，
    // 否则不同目录下的同名补丁（项目内有多个版本）会重名。
    final displayName = name.isEmpty
        ? dirName
        : (name.toLowerCase() == dirName.toLowerCase() ? name : '$name（$dirName）');

    return FePatch(
      name: displayName,
      dirPath: dirPath,
      asset: assetKey != null,
      info: info,
      author: author,
      checks: checks,
      writes: writes,
      unsupportedReason: reason,
    );
  }

  static PatchCheck? _parseCheck(String body) {
    final eq = body.indexOf('=');
    if (eq <= 0) return null;
    final addrStr = body.substring(0, eq).trim();
    final bytesStr = body.substring(eq + 1);
    final addr = _parseAddr(addrStr);
    if (addr == null) return null;
    final bytes = <int>[];
    for (final m in RegExp(r'0x([0-9A-Fa-f]{1,2})').allMatches(bytesStr)) {
      bytes.add(int.parse(m.group(1)!, radix: 16));
    }
    if (bytes.isEmpty) return null;
    return PatchCheck(addr, Uint8List.fromList(bytes));
  }

  static PatchWrite? _parseWrite(String body) {
    final eq = body.indexOf('=');
    if (eq <= 0) return null;
    var left = body.substring(0, eq).trim();
    var fileName = body.substring(eq + 1).trim();
    // 去掉行尾注释
    final comment = fileName.indexOf('//');
    if (comment >= 0) fileName = fileName.substring(0, comment).trim();

    int? relocateTo;
    final colon = left.indexOf(':');
    if (colon > 0) {
      final n = left.substring(colon + 1).trim();
      relocateTo = _parseAddr(n);
      left = left.substring(0, colon).trim();
      if (relocateTo == null) return null;
    }
    final offset = _parseAddr(left);
    if (offset == null) return null;
    return PatchWrite(
      offset,
      fileName,
      relocateTo: relocateTo,
      absolute: _isAbsoluteAddr(left),
    );
  }

  /// 只接受纯数字地址（0x 前缀或裸十六进制）；含 `$` 的宏一律视为不支持。
  ///
  /// 补丁文件里两种写法都存在：FE7 多为文件偏移（如 0x6642），
  /// FE6 部分用完整 GBA 地址（如 0x8053DD4），需要统一成偏移。
  static int? _parseAddr(String s) {
    var t = s.trim();
    if (t.isEmpty || t.startsWith(r'$')) return null;
    if (t.toLowerCase().startsWith('0x')) t = t.substring(2);
    if (t.isEmpty) return null;
    final v = int.tryParse(t, radix: 16);
    if (v == null || v < 0) return null;
    if (v >= 0x08000000) return v - 0x08000000;
    return v;
  }

  /// 地址字符串是否写成完整 GBA 地址（>= 0x08000000）。
  /// 用于把里面指向自身块的指针也一起换算。
  static bool _isAbsoluteAddr(String s) {
    var t = s.trim();
    if (t.isEmpty || t.startsWith(r'$')) return false;
    if (t.toLowerCase().startsWith('0x')) t = t.substring(2);
    final v = int.tryParse(t, radix: 16);
    return v != null && v >= 0x08000000;
  }

  static String _cleanInfo(String s) {
    return s
        .replaceAll(r'\r\n', '\n')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\r', '\n')
        .trim();
  }
}

/// 安装结果
class PatchApplyResult {
  final bool ok;
  final String message;

  /// 实际写入的字节区间，用于撤销
  final List<({int offset, Uint8List before})> undo;

  const PatchApplyResult(this.ok, this.message, [this.undo = const []]);
}

/// 判断补丁是否已安装。
///
/// 有 `PATCHED_IF` 时以它为准；没有时退回「所有写入块是否已经就位」，
/// 否则那些不带判定行的补丁会被反复重复安装。
Future<bool> isPatchInstalledAsync(FePatch patch, Uint8List rom) async {
  if (patch.checks.isNotEmpty) return isPatchInstalled(patch, rom);
  final blocks = await patch.loadWrites();
  if (blocks.isEmpty) return false;
  for (final b in blocks) {
    if (b.offset + b.data.length > rom.length) return false;
    for (var i = 0; i < b.data.length; i++) {
      if (rom[b.offset + i] != b.data[i]) return false;
    }
  }
  return true;
}

/// 判断补丁是否已安装。
bool isPatchInstalled(FePatch patch, Uint8List rom) {
  if (patch.checks.isEmpty) return false;
  for (final c in patch.checks) {
    if (c.offset + c.expected.length > rom.length) return false;
    for (var i = 0; i < c.expected.length; i++) {
      if (rom[c.offset + i] != c.expected[i]) return false;
    }
  }
  return true;
}

/// 应用补丁（就地修改 [rom]）。
Future<PatchApplyResult> applyPatch(FePatch patch, Uint8List rom) async {
  if (!patch.installable) {
    return PatchApplyResult(false, patch.unsupportedReason ?? '该补丁不受支持');
  }
  if (await isPatchInstalledAsync(patch, rom)) {
    return const PatchApplyResult(false, '该补丁已经安装过了');
  }

  final blocks = await patch.loadWrites();
  if (blocks.isEmpty) {
    return const PatchApplyResult(false, '补丁数据文件缺失');
  }

  // 先检查是否会越界，避免写一半
  for (final b in blocks) {
    if (b.offset < 0 || b.offset + b.data.length > rom.length) {
      return PatchApplyResult(
        false,
        '需要写入 0x${b.offset.toRadixString(16).toUpperCase()} 起的 '
        '${b.data.length} 字节，超出 ROM 范围',
      );
    }
  }

  final undo = <({int offset, Uint8List before})>[];
  for (final b in blocks) {
    undo.add((offset: b.offset, before: Uint8List.fromList(rom.sublist(b.offset, b.offset + b.data.length))));
    rom.setRange(b.offset, b.offset + b.data.length, b.data);
  }
  return PatchApplyResult(true, '已写入 ${blocks.length} 个块', undo);
}

/// 撤销一次安装。
void undoPatch(List<({int offset, Uint8List before})> undo, Uint8List rom) {
  for (final u in undo) {
    if (u.offset + u.before.length <= rom.length) {
      rom.setRange(u.offset, u.offset + u.before.length, u.before);
    }
  }
}
