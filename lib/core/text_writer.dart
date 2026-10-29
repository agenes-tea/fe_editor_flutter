import 'dart:convert';
import 'dart:typed_data';

import 'editable_rom.dart';
import 'fe_rom.dart';
import 'gbk_table.dart';
import 'hex_view.dart';
import 'huffman_encoder.dart';
import 'sjis_table.dart';
import 'text_codec.dart';
import 'text_control.dart';
import 'zh_table.dart';

/// 文本写入的几种结果。
enum TextWriteMode {
  /// 新内容与原内容逐字节相同，未改动。
  identical,

  /// 等长：原地覆盖。
  inPlace,

  /// 变短：原地写 + 提前放结束符 0x00（后面残留字节被解码器忽略）。
  shorter,

  /// 变长：写到空位并把指针表重指过去。
  relocated,

  /// 变长但没有可用空位（或未允许重定位）。
  tooLong,

  /// 该 ROM 的文本引擎不支持写入（真·未识别）。
  unsupportedEngine,

  /// 该条目无法读取（保留给兼容）。
  hasControlCodes,

  /// 有字符无法按该 ROM 的编码表示（如 GBK 码表 / Huffman 树里没有的字）。
  charNotEncodable,

  /// 指针表里找不到该条目。
  missing,
}

/// 一次文本写入的结果。[ok] 为 true 表示已写入或无需写入。
class TextWriteResult {
  final TextWriteMode mode;
  final String message;
  final int originalBytes;
  final int newBytes;

  /// 重定位后的新偏移；原地写入时为 -1。
  final int newOffset;

  const TextWriteResult(
    this.mode, {
    this.message = '',
    this.originalBytes = 0,
    this.newBytes = 0,
    this.newOffset = -1,
  });

  bool get ok =>
      mode == TextWriteMode.identical ||
      mode == TextWriteMode.inPlace ||
      mode == TextWriteMode.shorter ||
      mode == TextWriteMode.relocated;
}

/// 文本写入（阶段三）。
///
/// 支持三类引擎：
/// - **明文 UTF-8**（重度改版，如「铠甲的呼唤」）
/// - **明文 GBK**（汉化改版，如 Superxyj 烈火）
/// - **Huffman**（日版 SJIS / 汉化中文码表）：用 [HuffmanEncoder] 走 ROM 自带树逆编码，
///   并以「解压→编码→解压」往返测试保证正确性。
///
/// 读写都走 [EditableRom.buffer]（同一份可撤销的副本），因此重定位改了指针后
/// 立刻能读回新内容；`EditableRom.rom` 是打开时的快照，不适合做实时读取。
///
/// 写入策略（由安全到激进）：
/// 1. **等长**：原地覆盖，最安全，不动任何指针。
/// 2. **变短**：原地写并在更早处放 0x00，后面残留字节被解码器忽略。
/// 3. **变长**：找一段空闲（选**最长**的 0xFF 块，通常就是 ROM 末尾空白）写入新文本，
///    再把指针表 `textBase + id*4` 重指过去。偏移必须 < 32MB（`toOffset` 只保留 25 位）。
/// 4. Huffman 引擎无法原地比较长度，统一走重定位。
///
/// **控制码**（换行 / 按键 / 颜色 / 变量等）通过 [TextControlCodec] 编成
/// `〔XX〕` / `〔XX:AABB〕` 占位符，用户可以连同文本一起编辑、保留它们即可。
class TextWriter {
  final EditableRom edit;

  /// 一份读**实时 buffer** 的 FeRom 视图（用于解析指针表与条目字节）。
  /// 带上原 ROM 的中文码表（汉化 Huffman 解码/编码靠它）。
  late final FeRom rom = FeRom(edit.buffer.data, edit.rom.table)
    ..zhTable = edit.rom.zhTable;

  late final HuffmanEncoder _encoder = HuffmanEncoder(rom);

  TextWriter(this.edit);

  bool get isUtf8 => rom.textEncoding == FeTextEncoding.plainUtf8;
  bool get isGbk => rom.textEncoding == FeTextEncoding.plainGbk;

  /// 标准卡带的 Huffman + Shift-JIS。
  bool get isHuffmanSjis => rom.textEncoding == FeTextEncoding.huffmanSjis;

  /// 汉化 Huffman + 中文码表。
  ///
  /// 注意：真实汉化 ROM（狼组封印 / 圣魔汉化）的 `textEncoding` 是 **unknown**
  /// （走「unknown + zhTable」这条路），不是 `huffmanZhTbl` 枚举值；两者都算。
  bool get isHuffmanZhTbl =>
      rom.textEncoding == FeTextEncoding.huffmanZhTbl ||
      (rom.textEncoding == FeTextEncoding.unknown && rom.zhTable != null);

  bool get isHuffman => isHuffmanSjis || isHuffmanZhTbl;

  /// 是否可写：明文 UTF-8 / 明文 GBK / Huffman（SJIS 或中文码表）。
  bool get supported => isUtf8 || isGbk || isHuffman;

  /// 供界面展示的引擎名。
  String get engineLabel => isUtf8
      ? '明文 UTF-8'
      : isGbk
          ? '明文 GBK'
          : isHuffmanSjis
              ? 'Huffman + SJIS'
              : isHuffmanZhTbl
                  ? 'Huffman + 中文码表'
                  : '（不支持写入）';

  // ---- 编码 ----

  /// GBK 逆查表：unicode 码位 -> GBK 双字节码（懒构建，全表只建一次）。
  static Map<int, int>? _gbkReverseCache;
  static Map<int, int> get _gbkReverse {
    var m = _gbkReverseCache;
    if (m == null) {
      m = <int, int>{};
      gbkDoubleByte.forEach((code, uni) => m!.putIfAbsent(uni, () => code));
      _gbkReverseCache = m;
    }
    return m;
  }

  /// SJIS 逆查表：unicode -> 双字节 SJIS 码（大端，如 0x82CD）。懒构建。
  static Map<int, int>? _sjisReverseCache;
  static Map<int, int> get _sjisReverse {
    var m = _sjisReverseCache;
    if (m == null) {
      m = <int, int>{};
      sjisDoubleByte.forEach((code, uni) => m!.putIfAbsent(uni, () => code));
      _sjisReverseCache = m;
    }
    return m;
  }

  /// 中文码表逆查表（表实例 -> unicode -> 码）。
  static final Map<ZhTable, Map<int, int>> _zhReverseCache = {};
  static Map<int, int> _zhReverseFor(ZhTable t) {
    return _zhReverseCache.putIfAbsent(t, () {
      final m = <int, int>{};
      t.table.forEach((code, str) {
        if (str.isEmpty) return;
        m.putIfAbsent(str.codeUnitAt(0), () => code);
      });
      return m;
    });
  }

  /// 把字符串编码成该 ROM 解压后的**原始字节**。无法编码的字符返回 null。
  Uint8List? encode(String s) {
    if (isUtf8) return Uint8List.fromList(utf8.encode(s));
    if (isGbk) {
      final out = <int>[];
      for (final cu in s.codeUnits) {
        if (cu < 0x80) {
          out.add(cu);
          continue;
        }
        final code = _gbkReverse[cu];
        if (code == null) return null;
        out.add((code >> 8) & 0xFF);
        out.add(code & 0xFF);
      }
      return Uint8List.fromList(out);
    }
    if (isHuffmanSjis) {
      final out = <int>[];
      for (final cu in s.codeUnits) {
        if (cu < 0x80) {
          out.add(cu);
          continue;
        }
        if (cu >= 0xFF61 && cu <= 0xFF9F) {
          out.add(0xA1 + (cu - 0xFF61));
          continue;
        }
        final code = _sjisReverse[cu];
        if (code == null) return null;
        out.add((code >> 8) & 0xFF);
        out.add(code & 0xFF);
      }
      return Uint8List.fromList(out);
    }
    if (isHuffmanZhTbl) {
      final t = rom.zhTable;
      if (t == null) return null;
      final rev = _zhReverseFor(t);
      final out = <int>[];
      for (final cu in s.codeUnits) {
        if (cu < 0x80) {
          out.add(cu);
          continue;
        }
        final code = rev[cu];
        if (code == null) return null;
        out.add((code >> 8) & 0xFF);
        out.add(code & 0xFF);
      }
      return Uint8List.fromList(out);
    }
    return null;
  }

  /// 把一段「纯文本」字节按该 ROM 的编码解成字符串（不 trim，供编辑框与分段解码）。
  String decodeExact(Uint8List bytes) {
    if (isUtf8) {
      try {
        return utf8.decode(bytes);
      } on FormatException {
        return Utf8Codec.decode(bytes);
      }
    }
    if (isHuffmanSjis) return _decodeSjisNoTrim(bytes);
    if (isHuffmanZhTbl) return rom.zhTable?.decode(bytes) ?? '';
    // GBK
    final sb = StringBuffer();
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b == 0x00) break;
      if (b < 0x80) {
        sb.writeCharCode(b);
        i++;
        continue;
      }
      if (i + 1 >= bytes.length) break;
      final code = (b << 8) | bytes[i + 1];
      final u = gbkDoubleByte[code];
      if (u != null) sb.writeCharCode(u);
      i += 2;
    }
    return sb.toString();
  }

  /// SJIS 解码（不 trim；控制码终止）。
  String _decodeSjisNoTrim(Uint8List bytes) {
    final sb = StringBuffer();
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b == 0x00 || b < 0x20) break;
      if (b < 0x80) {
        sb.writeCharCode(b);
        i++;
        continue;
      }
      if (b >= 0xA1 && b <= 0xDF) {
        sb.writeCharCode(0xFF61 + (b - 0xA1));
        i++;
        continue;
      }
      if (i + 1 >= bytes.length) break;
      final code = (b << 8) | bytes[i + 1];
      final u = sjisDoubleByte[code];
      if (u != null) sb.writeCharCode(u);
      i += 2;
    }
    return sb.toString();
  }

  bool _sameList(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 条目解压后的原始字节（到 0x00 为止，不含 0x00）；找不到返回 null。
  Uint8List? entryBytes(int id) {
    if (!supported) return null;
    if (rom.textEntryOffset(id) < 0) return null;
    return rom.decodeTextBytesAt(id);
  }

  /// 该条当前的可编辑文本（编辑框预填用）；不可编辑时返回 null。
  ///
  /// 控制码以 `〔XX〕` / `〔XX:AABB〕` 占位展示，便于连同换行/按键等一起编辑。
  String? currentText(int id) {
    final raw = entryBytes(id);
    if (raw == null) return null;
    return TextControlCodec.decode(raw, decodeExact);
  }

  /// 该条能否编辑：引擎可写且指针有效即可。
  /// 含控制码的对话现在也能编——控制码用 `〔XX〕` 占位符保留。
  bool entryEditable(int id) => supported && entryBytes(id) != null;

  /// 写一条文本。成功时改动已记入 [EditableRom.edits]，可用 `revertAll` 撤销。
  ///
  /// [allowRelocate] 为 false 时，需要重定位的写入直接返回 [TextWriteMode.tooLong]。
  TextWriteResult write(
    int id,
    String text, {
    bool allowRelocate = true,
  }) {
    if (!supported) {
      return TextWriteResult(
        TextWriteMode.unsupportedEngine,
        message: '该 ROM 的文本引擎未识别，暂不支持写入',
      );
    }
    final off = rom.textEntryOffset(id);
    if (off < 0) {
      return const TextWriteResult(TextWriteMode.missing, message: '找不到该条目的指针');
    }
    final orig = rom.decodeTextBytesAt(id);
    final origLen = orig.length;

    // 控制码占位还原 + 文本编码 → 目标原始字节
    final raw = TextControlCodec.encode(text, encode);
    if (raw == null) {
      return TextWriteResult(
        TextWriteMode.charNotEncodable,
        message: isHuffman
            ? '有字符无法用该 ROM 的 Huffman 码表表示'
            : isGbk
                ? '有字符不在 GBK 码表里'
                : '编码失败',
        originalBytes: origLen,
      );
    }
    if (_sameList(orig, raw)) {
      return TextWriteResult(TextWriteMode.identical,
          originalBytes: origLen, newBytes: raw.length);
    }

    // Huffman：用 ROM 自带树重新压缩 → 重定位写入（无法原地比较长度）
    if (isHuffman) {
      if (!_encoder.available) {
        return TextWriteResult(TextWriteMode.unsupportedEngine,
            message: '无法从该 ROM 建立 Huffman 编码树', originalBytes: origLen);
      }
      final enc = _encoder.encodeBytes(raw);
      if (enc == null) {
        return TextWriteResult(TextWriteMode.charNotEncodable,
            message: '有字符不在该 ROM 的 Huffman 树里', originalBytes: origLen);
      }
      if (!allowRelocate) {
        return TextWriteResult(TextWriteMode.tooLong,
            message: 'Huffman 文本需重定位写入',
            originalBytes: origLen,
            newBytes: enc.length);
      }
      // 末尾多留 8 字节：解码器读末字节时要求 p+4 <= length
      final slot = _findFreeSlot(enc.length + 8);
      if (slot < 0) {
        return TextWriteResult(TextWriteMode.tooLong,
            message: '找不到容纳 ${enc.length + 8} 字节的空位',
            originalBytes: origLen,
            newBytes: enc.length);
      }
      edit.writeBytes(slot, enc);
      edit.writeBytes(slot + enc.length, const [0, 0, 0, 0, 0, 0, 0, 0]);
      _repoint(id, slot);
      return TextWriteResult(TextWriteMode.relocated,
          originalBytes: origLen, newBytes: enc.length, newOffset: slot);
    }

    // 明文：等长 / 变短原地写，变长重定位
    if (raw.length <= origLen) {
      edit.writeBytes(off, raw);
      edit.writeBytes(off + raw.length, const [0x00]);
      return TextWriteResult(
        raw.length == origLen ? TextWriteMode.inPlace : TextWriteMode.shorter,
        originalBytes: origLen,
        newBytes: raw.length,
      );
    }
    if (!allowRelocate) {
      return TextWriteResult(TextWriteMode.tooLong,
          message: '文本变长（$origLen → ${raw.length} 字节），未允许重定位',
          originalBytes: origLen,
          newBytes: raw.length);
    }
    final slot = _findFreeSlot(raw.length + 1);
    if (slot < 0) {
      return TextWriteResult(TextWriteMode.tooLong,
          message: '找不到容纳 ${raw.length + 1} 字节的空位',
          originalBytes: origLen,
          newBytes: raw.length);
    }
    edit.writeBytes(slot, raw);
    edit.writeBytes(slot + raw.length, const [0x00]);
    _repoint(id, slot);
    return TextWriteResult(TextWriteMode.relocated,
        originalBytes: origLen, newBytes: raw.length, newOffset: slot);
  }

  /// 找一段空闲写入 [need] 字节。
  ///
  /// **更稳妥的选择**：在 32MB 偏移范围内，选**最长**的连续 0xFF 空闲块
  /// （通常是 ROM 末尾那片未用空白，比随手拿一个小洞安全得多）；
  /// 没有 0xFF 块时才退而用最长的 0x00 块。
  /// 偏移必须 < 32MB（`FeRom.toOffset` 只保留 25 位，超出会指错）。
  int _findFreeSlot(int need) {
    const limit = 0x02000000;
    final view = HexView(edit.buffer);

    int bestRun(int fill) {
      var from = 0;
      var bestOff = -1;
      var bestLen = 0;
      while (from < edit.buffer.length && from < limit) {
        final run = view.findFreeRun(from, fill: fill, minLength: need);
        if (run == null) break;
        if (run.offset + need <= limit && run.length > bestLen) {
          bestLen = run.length;
          bestOff = run.offset;
        }
        from = run.offset + run.length;
      }
      return bestOff;
    }

    final ff = bestRun(0xFF);
    if (ff >= 0) return ff;
    return bestRun(0x00);
  }

  /// 把指针表第 [id] 个槽重指到 [offset]。
  void _repoint(int id, int offset) {
    final slot = rom.textTableBase + id * 4;
    final gba = 0x08000000 + offset;
    edit.writeBytes(slot, [
      gba & 0xFF,
      (gba >> 8) & 0xFF,
      (gba >> 16) & 0xFF,
      (gba >> 24) & 0xFF,
    ]);
  }
}
