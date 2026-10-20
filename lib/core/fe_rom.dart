import 'dart:convert';
import 'dart:typed_data';

import 'rom_info.dart';
import 'rom_profile.dart';
import 'sjis_table.dart';
import 'gbk_table.dart';
import 'text_codec.dart';
import 'zh_table.dart';

/// FE GBA ROM 的读取层。
///
/// 关键概念：
/// - GBA ROM 映射在 0x08000000..0x0A000000，文件偏移 = 地址 - 0x08000000；
/// - 表地址通常是「指针槽」：槽里存的是指向数据的 GBA 指针，需要再解一次；
/// - 文本不是明文，是 Huffman 压缩的字符码流。
class FeRom {
  final Uint8List data;
  final RomTable table;

  /// 中文码表（汉化版 Huffman 文本用）；可后置设置。
  ZhTable? zhTable;

  FeRom(this.data, this.table);

  int get length => data.length;

  static bool _isSafeOffset(int v) => v >= 0 && v < 0x02000000;

  static int u8(Uint8List d, int a) => (a >= 0 && a < d.length) ? d[a] : 0;

  static int u16(Uint8List d, int a) {
    if (a < 0 || a + 2 > d.length) return 0;
    return d[a] | (d[a + 1] << 8);
  }

  static int u32(Uint8List d, int a) {
    if (a < 0 || a + 4 > d.length) return 0;
    return d[a] | (d[a + 1] << 8) | (d[a + 2] << 16) | (d[a + 3] << 24);
  }

  /// GBA 指针（0x08xxxxxx）转文件偏移
  static int toOffset(int ptr) => ptr & 0x1FFFFFF;

  static bool isPointer(int v) => v >= 0x08000000 && v < 0x0A000000;

  /// 读指针槽，返回数据偏移；不合法则返回 -1
  int pointerAt(int slot) {
    final p = u32(data, slot);
    if (!isPointer(p)) return -1;
    final off = toOffset(p);
    return _isSafeOffset(off) ? off : -1;
  }

  /// 双重间接：指针槽 -> 指针 -> 指针
  int doublePointerAt(int slot) {
    final a = pointerAt(slot);
    if (a < 0) return -1;
    return pointerAt(a);
  }

  // ---------- 版本识别 ----------

  /// 用 game code（0xAC..0xAF）识别 ROM 版本。
  ///
  /// 标准 ROM：FE6 = AE6J、FE7 日 = AE7J、FE7 美 = AE7E、
  /// FE8 日 = AE8J、FE8 美 = AE8E。
  ///
  /// 改版常常改掉 code（如「火焰之纹章-铠甲的呼唤」是 BE8E），
  /// 所以 code 对不上时会退到**结构匹配**——看哪个版本的指针槽在 ROM 里全部有效。
  static RomTable? detectTable(Uint8List d) {
    if (d.length < 0xC0) return null;
    final code = String.fromCharCodes(d.sublist(0xAC, 0xB0));
    final byCode = profileByCode(code);
    if (byCode != null) {
      // code 命中还要用结构复核，避免改版碰巧复用了别的 code
      final t = byCode.toRomTable();
      if (_pointerLooksValid(d, t)) return t;
    }
    final byStructure = profileByStructure(d);
    if (byStructure != null) return byStructure.toRomTable();
    return _detectByTitle(d);
  }

  /// 按头部标题（0xA0..0xAC）匹配 FE6/FE7/FE8，并用指针表有效性交叉验证。
  static RomTable? _detectByTitle(Uint8List d) {
    final end = 0xA0 + 12;
    if (d.length < end) return null;
    final bytes = d.sublist(0xA0, end);
    final cut = bytes.indexOf(0);
    final raw = cut >= 0 ? bytes.sublist(0, cut) : bytes;
    final title = ascii.decode(raw, allowInvalid: true).toUpperCase();
    if (!title.contains('FIREEMBLEM')) return null;

    final digit = title.contains('6')
        ? '6'
        : title.contains('7')
            ? '7'
            : title.contains('8')
                ? '8'
                : null;
    if (digit == null) return null;

    final candidates = digit == '6'
        ? [fe6Jp]
        : digit == '7'
            ? [fe7Jp, fe7Us]
            : [fe8Jp, fe8Us];
    for (final t in candidates) {
      if (_pointerLooksValid(d, t)) return t;
    }
    return candidates.first;
  }

  /// 文本指针槽与单位表指针槽都能解出合法偏移，才认为地址表匹配。
  static bool _pointerLooksValid(Uint8List d, RomTable t) {
    int read32(int a) {
      if (a < 0 || a + 4 > d.length) return 0;
      return d[a] | (d[a + 1] << 8) | (d[a + 2] << 16) | (d[a + 3] << 24);
    }

    bool ok(int slot) {
      final v = read32(slot);
      if (!isPointer(v)) return false;
      final off = toOffset(v);
      return off > 0 && off < d.length;
    }

    return ok(t.textPointerSlot) && ok(t.unitPointerSlot);
  }

  String get gameCode =>
      length >= 0xB0 ? String.fromCharCodes(data.sublist(0xAC, 0xB0)) : '????';

  String get headerTitle {
    if (length < 0xAC) return '';
    final end = 0xA0 + 12;
    final bytes = data.sublist(0xA0, end);
    final cut = bytes.indexOf(0);
    final raw = cut >= 0 ? bytes.sublist(0, cut) : bytes;
    return ascii.decode(raw, allowInvalid: true).trim();
  }

  // ---------- 文本解码 ----------

  /// 树节点表（FEBuilderGBA 中 mask_pointer，单次解引用）
  late final int _treeBase = _resolveTreeBase();

  /// 字符数据表（mask_point_base_pointer，双重解引用）
  late final int _treeDataBase = _resolveTreeDataBase();

  late final int _textBase = _resolveTextBase();

  int _resolveTreeBase() {
    final p = pointerAt(table.maskPointerSlot);
    return p > 0 ? p : table.maskPointerSlot;
  }

  int _resolveTreeDataBase() {
    final p = doublePointerAt(table.maskPointBaseSlot);
    if (p > 0) return p;
    // 少数改版把树根槽直接指向数据，退回单次解引用
    return _resolveTreeBase();
  }

  int _resolveTextBase() {
    final p = pointerAt(table.textPointerSlot);
    if (p > 0) return p;
    return table.textRecoverAddress;
  }

  bool get textAvailable =>
      _treeBase >= 0 && _treeDataBase >= 0 && _textBase > 0;

  /// 取文本 id 对应的 Huffman 压缩数据偏移
  int textEntryOffset(int textId) {
    if (textId < 0 || textId >= 0x7FFF) return -1;
    final slot = _textBase + textId * 4;
    return pointerAt(slot);
  }

  /// 解压一段 Huffman 文本，返回原始字节（FE7J 是 Shift-JIS）
  Uint8List decodeTextBytes(int addr) {
    final out = <int>[];
    var td = _treeDataBase;
    var p = addr;
    while (p + 4 <= length) {
      var bit = u32(data, p);
      if (bit == 0) {
        if (p + 8 > length || u32(data, p + 4) == 0) break;
      }
      p++;
      var terminated = false;
      for (var i = 0; i < 8; i++) {
        final tree = u16(data, td + ((bit & 1) * 2));
        td = _treeBase + tree * 4;
        bit >>= 1;
        final v = u32(data, td);
        if ((v & 0x80000000) != 0) {
          td = _treeDataBase;
          final code = v & 0xFFFF;
          if (code <= 0 || (code & 0xFF) == 0) {
            terminated = true;
            break;
          }
          if (code > 0xFF) {
            out.add(code & 0xFF);
            out.add((code >> 8) & 0xFF);
          } else {
            out.add(code);
          }
        }
      }
      if (terminated || bit == 0) break;
    }
    return Uint8List.fromList(out);
  }

  /// 解码为显示用字符串。
  ///
  /// 汉化改版常把文本表整体搬到 ROM 尾部并改成明文 GBK（不走 Huffman），
  /// 所以标准解码不健康时会退回明文读取。
  String decodeText(int textId) {
    if (textEncoding == FeTextEncoding.huffmanSjis) {
      final addr = textEntryOffset(textId);
      if (addr < 0) return '';
      final raw = decodeTextBytes(addr);
      if (raw.isEmpty) return '';
      return _bytesToDisplay(raw);
    }
    if (textEncoding == FeTextEncoding.plainGbk) {
      final addr = textEntryOffset(textId);
      if (addr < 0) return '';
      return GbkCodec.decode(_plainSlice(addr));
    }
    // unknown（汉化版 Huffman+码表）：挂了码表就走 Huffman 解码 + tbl 渲染
    if (zhTable != null) {
      final addr = textEntryOffset(textId);
      if (addr < 0) return '';
      final raw = decodeTextBytes(addr);
      if (raw.isEmpty) return '';
      return zhTable!.decode(raw);
    }
    return '';
  }

  /// 明文文本：从 [addr] 读到 0x00 或控制字符为止（上限 256 字节）。
  Uint8List _plainSlice(int addr) {
    var end = addr;
    final limit = addr + 256;
    while (end < limit && end < length && data[end] != 0) {
      end++;
    }
    return Uint8List.fromList(data.sublist(addr, end));
  }

  String _bytesToDisplay(Uint8List raw) {
    // 中文码表优先（汉化版）
    final t = zhTable;
    if (t != null) {
      return t.decode(raw);
    }
    final cleaned = <int>[];
    for (final b in raw) {
      if (b == 0x00 || b == 0x1F) break;
      cleaned.add(b);
    }
    if (cleaned.isEmpty) return '';
    try {
      if (table.multibyte) {
        return _sjisDecode(Uint8List.fromList(cleaned));
      }
      return latin1.decode(Uint8List.fromList(cleaned)).trim();
    } catch (_) {
      return latin1.decode(raw, allowInvalid: true).trim();
    }
  }

  /// 文本编码方式：标准 Huffman+SJIS，还是汉化版的明文 GBK。
  ///
  /// 汉化组（如 Superxyj 烈火之剑）的做法是把文本指针整体改指向 ROM 尾部
  /// 新加的区域，并把内容从 Huffman 压缩改成明文 GBK，因此这里要分两路探测。
  late final FeTextEncoding textEncoding = _detectTextEncoding();

  /// 文本引擎是否可用（任一编码方式识别成功即可）。
  bool get textEncodingHealthy => textEncoding != FeTextEncoding.unknown;

  FeTextEncoding _detectTextEncoding() {
    if (!textAvailable) return FeTextEncoding.unknown;
    final huffmanSane = _sampleRatio((raw) => _looksLikeText(raw));
    if (huffmanSane >= 0.5) return FeTextEncoding.huffmanSjis;

    // Huffman 不成立时，按明文 GBK 抽样判定（汉化版）
    final gbkSane = _sampleRatio(
      (raw) => raw.isNotEmpty && GbkCodec.looksLikeGbk(raw),
      plain: true,
    );
    if (gbkSane >= 0.5) return FeTextEncoding.plainGbk;

    return FeTextEncoding.unknown;
  }

  /// 若有中文码表，判断 Huffman 字节流是否按该码表渲染更好。
  /// 由外部（UI 层）在加载码表后调用并决定是否切换编码。
  bool zhTableFits(Uint8List raw) {
    final t = zhTable;
    return t != null && t.looksLikeTblText(raw);
  }

  /// 抽样判断当前 ROM 的 Huffman 文本与中文码表的匹配率。
  double zhTableMatchRatio() {
    final t = zhTable;
    if (t == null) return 0;
    return _sampleRatio(t.looksLikeTblText);
  }

  /// Huffman+SJIS 路径的健康比例（诊断用）。
  double sjisSampleRatio() =>
      textAvailable ? _sampleRatio((raw) => _looksLikeText(raw)) : 0;

  /// 明文 GBK 路径的健康比例（诊断用）。
  double gbkSampleRatio() => textAvailable
      ? _sampleRatio(
          (raw) => raw.isNotEmpty && GbkCodec.looksLikeGbk(raw),
          plain: true,
        )
      : 0;

  /// 抽样 60 条文本，返回「看起来正常」的比例。
  double _sampleRatio(bool Function(Uint8List raw) check, {bool plain = false}) {
    var checked = 0;
    var sane = 0;
    for (var id = 0; id < 0x2000 && checked < 60; id++) {
      final addr = textEntryOffset(id);
      if (addr < 0) continue;
      final raw = plain ? _plainSlice(addr) : decodeTextBytes(addr);
      if (raw.isEmpty) continue;
      checked++;
      if (check(raw)) sane++;
    }
    if (checked == 0) return 0;
    return sane / checked;
  }

  /// 严格判定：整条文本必须几乎完全由可打印 ASCII 或合法 SJIS 双字节构成。
  ///
  /// 乱码里会掺入孤立字节与不可打印控制码，用「整条高占比」而
  /// 不是「有几个合法字符」来区分，否则改版乱码也会误判为正常。
  bool _looksLikeText(Uint8List raw) {
    if (raw.isEmpty) return false;
    var units = 0;
    var bad = 0;
    var i = 0;
    while (i < raw.length && units < 48) {
      final b = raw[i];
      if (b == 0x00 || b == 0x1F) break;
      units++;
      if (b >= 0x20 && b < 0x7F) {
        i++;
        continue;
      }
      if (table.multibyte && i + 1 < raw.length) {
        final code = (b << 8) | raw[i + 1];
        if (sjisDoubleByte.containsKey(code)) {
          i += 2;
          continue;
        }
      }
      bad++;
      i++;
    }
    if (units < 2) return false;
    return bad * 10 <= units;
  }

  static String _sjisDecode(Uint8List bytes) => SjisCodec().decode(bytes);

  // ---------- 表 ----------

  bool get isFe6 => table.id == 'FE6';

  /// 手动指定的表基址（文件偏移）。-1 表示用自动探测结果。
  ///
  /// 有些重度改版会把表搬到 ROM 其它位置**并且**不保留原指针槽，
  /// 这时自动探测无能为力，只能由用户指定。
  /// 键：'unit' / 'class' / 'item' / 'portrait'
  final Map<String, int> tableBaseOverrides = {};

  /// FE6 的 unit_pointer 指向的是一个指针数组，真正的单位表在数组之后。
  /// FEBuilderGBA 的处理：`ReInit(p32(unit_pointer) + unit_datasize)`。
  int get unitBase {
    final override = tableBaseOverrides['unit'];
    if (override != null) return override;
    final base = pointerAt(table.unitPointerSlot);
    if (base < 0) return -1;
    return isFe6 ? base + table.unitDataSize : base;
  }

  int get classBase =>
      tableBaseOverrides['class'] ?? pointerAt(table.classPointerSlot);
  int get itemBase =>
      tableBaseOverrides['item'] ?? pointerAt(table.itemPointerSlot);

  /// 直接取文本 id 的 Huffman 原始字节（供文本浏览器做控制码级渲染）。
  Uint8List decodeTextBytesAt(int textId) {
    final addr = textEntryOffset(textId);
    if (addr < 0) return Uint8List(0);
    if (textEncoding == FeTextEncoding.plainGbk) {
      return _plainSlice(addr);
    }
    return decodeTextBytes(addr);
  }

  /// 查双字节字符码的显示字符（按当前编码走不同表）。
  String? lookupChar(int code) {
    final t = zhTable;
    if (t != null) return t.table[code];
    if (textEncoding == FeTextEncoding.plainGbk) {
      final u = gbkDoubleByte[code];
      return u != null ? String.fromCharCode(u) : null;
    }
    final u = sjisDoubleByte[code];
    return u != null ? String.fromCharCode(u) : null;
  }

  String unitName(int index) {
    final base = unitBase;
    if (base < 0) return '';
    final addr = base + index * table.unitDataSize;
    if (addr + 2 > length) return '';
    return decodeText(u16(data, addr + UnitOffsets.nameTextId));
  }

  // ---------- 表边界 ----------
  //
  // 判停规则照搬 FEBuilderGBA 的 InputFormRef callback，否则会把表后面的
  // 其它数据当成条目读出来（职业/道具表后面紧跟着别的结构）。

  /// 职业表有效条目数。
  ///
  /// 职业表的 `u8@4` 是 **class number**，从 0 开始连续递增
  /// （ID 0 是空槽，class number 也是 0）。
  /// 一旦不再等于 i，说明已经读到表外的数据了。
  ///
  /// FEBuilderGBA 的规则是「class number 非 0」，但那对「中间有空槽」的表
  /// 会提前截断；用连续性判据更准，也和单位表一致。
  int get classCount {
    final base = classBase;
    if (base < 0) return 0;
    var n = 0;
    for (var i = 0; i <= 0xFF; i++) {
      final addr = base + i * table.classDataSize;
      if (addr + table.classDataSize > length) break;
      if (data[addr + ClassOffsets.classNumber] != i) break;
      n = i + 1;
    }
    return n;
  }

  /// 道具表有效条目数。
  ///
  /// 道具表的 `u8@6` 是 **item ID**，从 0 开始连续递增（ID 0 是空槽）。
  /// 一旦不再等于 i，说明已经读到表外的数据了。
  ///
  /// FEBuilderGBA 用的是「`addr+12` 与 `addr+16` 都是指针或 NULL」，
  /// 但那对「中间有空槽」的表会提前截断；用 ID 连续性更准。
  int get itemCount {
    final base = itemBase;
    if (base < 0) return 0;
    var n = 0;
    for (var i = 0; i <= 0xFF; i++) {
      final addr = base + i * table.itemDataSize;
      if (addr + table.itemDataSize > length) break;
      if (data[addr + ItemOffsets.itemId] != i) break;
      n = i + 1;
    }
    return n;
  }

  /// 角色表有效条目数。
  ///
  /// 单位表的 `u8@4` 是 **unit ID**，从 1 开始连续递增
  /// （FEBuilderGBA 的 `FELint.CheckID(id, i+1, ...)` 就是校验这一点）。
  /// 一旦 ID 不再等于 i+1，说明已经读到表外的数据了。
  ///
  /// 不用「名字为空」判停——改版里常有未命名素材，那不是表的边界。
  int get unitCount {
    final base = unitBase;
    if (base < 0) return 0;
    var n = 0;
    for (var i = 0; i < table.unitMaxCount; i++) {
      final addr = base + i * table.unitDataSize;
      if (addr + table.unitDataSize > length) break;
      if (data[addr + UnitOffsets.unitId] != i + 1) break;
      n = i + 1;
    }
    return n;
  }

  String className(int index) {
    final base = classBase;
    if (base < 0) return '';
    final addr = base + index * table.classDataSize;
    if (addr + 2 > length) return '';
    return decodeText(u16(data, addr + ClassOffsets.nameTextId));
  }

  String itemName(int index) {
    final base = itemBase;
    if (base < 0) return '';
    final addr = base + index * table.itemDataSize;
    if (addr + 2 > length) return '';
    return decodeText(u16(data, addr + ItemOffsets.nameTextId));
  }
}

/// Shift-JIS 解码器（单字节 ASCII/半角片假名 + 双字节表）。
class SjisCodec {
  String decode(Uint8List bytes) {
    final sb = StringBuffer();
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b < 0x80) {
        sb.writeCharCode(b);
        i++;
        continue;
      }
      if (b >= 0xA1 && b <= 0xDF) {
        // 半角片假名
        sb.writeCharCode(0xFF61 + (b - 0xA1));
        i++;
        continue;
      }
      if (i + 1 >= bytes.length) {
        i++;
        continue;
      }
      final code = (b << 8) | bytes[i + 1];
      final u = sjisDoubleByte[code];
      if (u != null) {
        sb.writeCharCode(u);
      }
      i += 2;
    }
    return sb.toString();
  }
}
