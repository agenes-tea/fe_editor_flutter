import 'dart:typed_data';

import 'fe_rom.dart';
import 'rom_info.dart';
import 'rom_probe.dart';
import 'tile_image.dart';

/// GBA LZ77 解压。实现照搬 FEBuilderGBA `LZ77.decompress`
/// （GPL-3.0，7743 著），含越界与损坏数据的保护。
class Lz77 {
  static const int maxUncompressed = 0x14000;

  /// [at] 处是否为合法 LZ77 压缩数据（头 0x10 + 24 位长度）。
  static bool isCompressed(Uint8List d, int at) {
    return uncompressedSize(d, at) > 0;
  }

  static int uncompressedSize(Uint8List d, int at) {
    if (at < 0 || at + 4 > d.length) return 0;
    if (d[at] != 0x10) return 0;
    final size = d[at + 1] | (d[at + 2] << 8) | (d[at + 3] << 16);
    if (size < 3 || size > maxUncompressed) return 0;
    return size;
  }

  /// 解压 [at] 处的数据；数据不合法或损坏时返回 null。
  static Uint8List? decompress(Uint8List d, int at) {
    final size = uncompressedSize(d, at);
    if (size == 0) return null;
    final out = Uint8List(size);
    var write = 0;
    var i = at + 4;
    while (write < size) {
      if (i >= d.length) return null;
      final flags = d[i];
      i++;
      for (var bit = 0x80; bit > 0; bit >>= 1) {
        if (write >= size) break;
        if (i >= d.length) return null;
        if ((flags & bit) == 0) {
          out[write++] = d[i];
          i++;
          continue;
        }
        final first = d[i];
        i++;
        if (i >= d.length) return null;
        final second = d[i];
        i++;
        var amount = 3 + (first >> 4);
        final offset = ((first & 0x0F) << 8) | second;
        if (write + amount > size) amount = size - write;
        if (write <= offset) continue;
        for (var k = 0; k < amount; k++, write++) {
          out[write] = out[write - offset - 1];
        }
      }
    }
    return out;
  }
}

/// 肖像表的一个条目。
///
/// FE7/FE8 为 28 字节：unit_face / map_face / palette / mouth / class_face
/// 五个指针槽，加 mouth_x/y、eye_x/y、state、mug_exceed 四个字节。
/// FE6 为 16 字节：只有前三个指针槽和 mouth_x/y。
class PortraitEntry {
  final int id;
  final int unitFace;
  final int mapFace;
  final int palette;
  final int mouth;
  final int classFace;
  final int mouthX;
  final int mouthY;
  final int eyeX;
  final int eyeY;
  final int state;
  final int mugExceed;

  const PortraitEntry({
    required this.id,
    required this.unitFace,
    required this.mapFace,
    required this.palette,
    required this.mouth,
    required this.classFace,
    required this.mouthX,
    required this.mouthY,
    required this.eyeX,
    required this.eyeY,
    required this.state,
    required this.mugExceed,
  });
}

/// 肖像表读取与图像拼装。
///
/// 数据来源：FEBuilderGBA `ImagePortraitForm.cs` / `ImagePortraitFE6Form.cs`
/// （GPL-3.0，7743 著）。
class PortraitReader {
  final FeRom rom;

  /// 条目数探测结果缓存；-1 表示表不可用。
  int? _count;

  /// 正脸 sheet 缓存（按条目 id），避免滑动时反复解压。
  final _sheetCache = <int, TileImage>{};
  static const int _sheetCacheLimit = 24;

  PortraitReader(this.rom);

  bool get isFe6 => rom.isFe6;

  bool get available => rom.table.portraitPointerSlot > 0;

  int? _base;

  /// 表基址。
  ///
  /// 一般就是槽值解引用的地址（与 FEBuilderGBA 的
  /// `InputFormRef` BaseAddress = `p32(portrait_pointer)` 一致），
  /// 但 **FE6 / FE7U 例外**：它们的槽指向的不是表，
  /// 而是一段压缩图像数据（0x52b26377 之类，既不是指针也不是 NULL）。
  ///
  /// 表首 ID 0 各版本不同，但都是**合法条目**：
  /// - FE7/FE8：全 NULL 条目（市民 / 对战对手），没有图。
  /// - FE6：山贼那张通用敌人脸，有图。
  ///
  /// 关键：**不能因为 ID 0 看起来「无效」就跳过它**——那会让所有 ID 后移一位，
  /// 名字与图像就对不上了。
  int get _slotBase {
    final cached = _base;
    if (cached != null) return cached;
    final override = rom.tableBaseOverrides['portrait'];
    if (override != null) {
      _base = override;
      return override;
    }
    final hit = _probe.findTable(
      rom.table.portraitPointerSlot,
      _dataSize,
      rom.table.portraitPointerFields,
    );
    _base = hit?.base ?? -1;
    return _base!;
  }

  /// 肖像表基址（文件偏移），-1 表示未探测到。
  int get baseAddress => _slotBase;

  RomProbe get _probe => _probeCache ??= RomProbe(rom.data);
  RomProbe? _probeCache;

  int get _dataSize => rom.table.portraitDataSize;

  /// 表内条目数。判停规则同 FEBuilderGBA：连续 NULL 条目达到阈值即停。
  int get entryCount {
    final cached = _count;
    if (cached != null) return cached;
    if (!available) {
      _count = 0;
      return 0;
    }
    final base = _slotBase;
    final size = _dataSize;
    if (base < 0 || base + size > rom.length) {
      _count = 0;
      return 0;
    }
    final nullLimit = isFe6 ? 10 : 1000;
    var nulls = 0;
    var n = 0;
    final maxId = 0x400;
    for (var i = 0; i < maxId; i++) {
      final at = base + i * size;
      if (at + size > rom.length) break;
      final u0 = _u32(at);
      final u4 = _u32(at + 4);
      final u8 = _u32(at + 8);
      final pointersOk = _isPointerOrNull(u0) && _isPointerOrNull(u4) && _isPointerOrNull(u8);
      if (!pointersOk) break;
      if (u0 == 0 && u4 == 0 && u8 == 0) {
        nulls++;
        if (nulls >= nullLimit) break;
      } else {
        nulls = 0;
      }
      n = i + 1;
    }
    _count = n;
    return n;
  }

  int _u32(int at) {
    if (at < 0 || at + 4 > rom.length) return 0;
    return rom.data[at] | (rom.data[at + 1] << 8) | (rom.data[at + 2] << 16) | (rom.data[at + 3] << 24);
  }

  static bool _isPointerOrNull(int v) =>
      v == 0 || (v >= 0x08000000 && v < 0x0A000000);

  int _entryAddress(int id) {
    final base = _slotBase;
    if (base < 0) return -1;
    final at = base + id * _dataSize;
    if (at + _dataSize > rom.length) return -1;
    return at;
  }

  PortraitEntry? entryAt(int id) {
    final at = _entryAddress(id);
    if (at < 0) return null;
    final unitFace = FeRom.toOffset(_u32(at));
    final mapFace = FeRom.toOffset(_u32(at + 4));
    final palette = FeRom.toOffset(_u32(at + 8));
    final mouth = isFe6 ? 0 : FeRom.toOffset(_u32(at + 12));
    final classFace = isFe6 ? 0 : FeRom.toOffset(_u32(at + 16));
    return PortraitEntry(
      id: id,
      unitFace: unitFace,
      mapFace: mapFace,
      palette: palette,
      mouth: mouth,
      classFace: classFace,
      mouthX: _u8(at + (isFe6 ? 12 : 20)),
      mouthY: _u8(at + (isFe6 ? 13 : 21)),
      eyeX: isFe6 ? 0 : _u8(at + 22),
      eyeY: isFe6 ? 0 : _u8(at + 23),
      state: isFe6 ? 0 : _u8(at + 24),
      mugExceed: isFe6 ? 0 : _u8(at + 26),
    );
  }

  int _u8(int at) => at >= 0 && at < rom.length ? rom.data[at] : 0;

  int _u16(int at) =>
      at >= 0 && at + 1 < rom.length ? rom.data[at] | (rom.data[at + 1] << 8) : 0;

  bool _valid(int offset) => offset > 0 && offset < rom.length;

  GbaPalette? _palette(int offset) {
    if (!_valid(offset)) return null;
    if (offset + 32 > rom.length) return null;
    return GbaPalette.fromRom(rom.data, offset);
  }

  /// 无压缩 256×40 sheet（跳过 4 字节头）。
  TileImage? _rawSheet(int offset, GbaPalette pal, int height) {
    if (!_valid(offset) || offset + 4 > rom.length) return null;
    return decode4bpp(rom.data, offset + 4, 32 * 8, height, pal);
  }

  TileImage? _lz77Sheet(int offset, GbaPalette pal, int height) {
    final uz = Lz77.decompress(rom.data, offset);
    if (uz == null || uz.isEmpty) return null;
    return decode4bpp(uz, 0, 32 * 8, height, pal);
  }

  /// 取条目的完整 sheet（含缓存）。FE6 恒为 LZ77。
  TileImage? sheet(PortraitEntry e) {
    final cached = _sheetCache[e.id];
    if (cached != null) return cached;
    final pal = _palette(e.palette);
    if (pal == null) return null;
    TileImage? sheet;
    if (isFe6) {
      sheet = _lz77Sheet(e.unitFace, pal, 5 * 8);
    } else if (Lz77.isCompressed(rom.data, e.unitFace)) {
      sheet = _lz77Sheet(e.unitFace, pal, 5 * 8);
    } else {
      final half = _isHalfBody(e.unitFace);
      sheet = _rawSheet(e.unitFace, pal, half ? 10 * 8 : 5 * 8);
    }
    if (sheet == null) return null;
    if (_sheetCache.length >= _sheetCacheLimit) _sheetCache.clear();
    _sheetCache[e.id] = sheet;
    return sheet;
  }

  /// halfbody 扩展肖像：头 4 字节为 00 04 20 00。
  bool _isHalfBody(int offset) {
    if (offset < 0 || offset + 4 > rom.length) return false;
    return rom.data[offset] == 0x00 &&
        rom.data[offset + 1] == 0x04 &&
        rom.data[offset + 2] == 0x20 &&
        rom.data[offset + 3] == 0x00;
  }

  bool isHalfBody(int id) {
    final e = entryAt(id);
    if (e == null) return false;
    return !isFe6 && _isHalfBody(e.unitFace);
  }

  /// 96×80 标准正脸。sheet 为 null 时返回 null。
  TileImage? faceImage(int id) {
    final e = entryAt(id);
    if (e == null) return null;
    final src = sheet(e);
    if (src == null) return null;
    final face = TileImage(12 * 8, 10 * 8);
    const pw = 8 * 4;
    const ph = 8 * 2;
    TileImage.blit(face, pw ~/ 2, 0, pw * 2, ph * 2, src, 0, 0);
    TileImage.blit(face, pw ~/ 2, ph * 2, pw * 2, ph * 2, src, pw * 2, 0);
    TileImage.blit(face, pw ~/ 2, ph * 4, pw, ph, src, pw * 4, 0);
    TileImage.blit(face, 0, ph * 3, pw ~/ 2, ph * 2, src, pw * 5, 0);
    TileImage.blit(face, pw + pw ~/ 2, ph * 4, pw, ph, src, pw * 4, ph);
    TileImage.blit(face, pw * 2 + pw ~/ 2, ph * 3, pw ~/ 2, ph * 2, src, pw * 5 + pw ~/ 2, 0);
    return face;
  }

  /// 嘴型帧：frame 0..6（FE7/FE8 用独立 mouth 图，FE6 用 sheet 内四帧）。
  TileImage? mouthFrame(int id, int frame) {
    final e = entryAt(id);
    if (e == null) return null;
    final pal = _palette(e.palette);
    if (pal == null) return null;
    const pw = 8 * 4;
    const ph = 8 * 2;
    if (isFe6) {
      final src = sheet(e);
      if (src == null) return null;
      final out = TileImage(pw, ph);
      switch (frame) {
        case 1:
          TileImage.blit(out, 0, 0, pw, ph, src, 192, 0);
          break;
        case 2:
          TileImage.blit(out, 0, 0, pw, ph, src, 224, 0);
          break;
        case 3:
          TileImage.blit(out, 0, 0, pw, ph, src, 192, 16);
          break;
        case 4:
          TileImage.blit(out, 0, 0, pw, ph, src, 224, 16);
          break;
        case 5:
          // 帧 5 在 sheet 里横跨两行，拆成上下两半分别取
          TileImage.blit(out, 0, 0, pw, ph ~/ 2, src, 0, 32);
          TileImage.blit(out, 0, ph ~/ 2, pw, ph ~/ 2, src, 32, 32);
          break;
        default:
          return null;
      }
      return out;
    }
    final mouth = e.mouth;
    if (!_valid(mouth)) return null;
    final m = decode4bpp(rom.data, mouth, pw, ph * 6, pal);
    if (frame < 0 || frame > 5) return null;
    final out = TileImage(pw, ph);
    TileImage.blit(out, 0, 0, pw, ph, m, 0, ph * frame);
    return out;
  }

  /// 半目 / 闭眼。来源是 sheet 右侧的备用眼型。
  TileImage? eyeFrame(int id, {required bool closed}) {
    final e = entryAt(id);
    if (e == null) return null;
    final src = sheet(e);
    if (src == null) return null;
    const pw = 8 * 4;
    const ph = 8 * 2;
    final out = TileImage(pw, ph);
    TileImage.blit(out, 0, 0, pw, ph, src, 32 * 8 - pw * 2, closed ? ph : 0);
    return out;
  }

  /// 32×32 地图头像。
  TileImage? mapFaceImage(int id) {
    final e = entryAt(id);
    if (e == null) return null;
    final pal = _palette(e.palette);
    if (pal == null) return null;
    if (e.mapFace == 0 || !_valid(e.mapFace)) return null;
    if (isFe6) {
      return decode4bpp(rom.data, e.mapFace, 4 * 8, 4 * 8, pal);
    }
    final uz = Lz77.decompress(rom.data, e.mapFace);
    if (uz == null || uz.isEmpty) return null;
    return decode4bpp(uz, 0, 4 * 8, 4 * 8, pal);
  }

  /// 80×80 职业卡（仅 FE7/FE8 有该字段）。
  TileImage? classCardImage(int id) {
    if (isFe6) return null;
    final e = entryAt(id);
    if (e == null) return null;
    final pal = _palette(e.palette);
    if (pal == null) return null;
    if (e.classFace == 0 || !_valid(e.classFace)) return null;
    final uz = Lz77.decompress(rom.data, e.classFace);
    if (uz == null || uz.isEmpty) return null;
    return decode4bpp(uz, 0, 10 * 8, 10 * 8, pal);
  }

  /// 反查使用该肖像的角色名（单位表优先，其次职业表）。
  String nameFor(int id) {
    final name = _unitNameForFace(id);
    if (name != null && name.isNotEmpty) return name;
    final cname = _classNameForFace(id);
    if (cname != null && cname.isNotEmpty) return cname;
    return '';
  }

  /// 单位表里 face 字段的取值集合。
  late final Set<int> _unitFaceValues = _collectUnitFaces();

  Set<int> _collectUnitFaces() {
    final s = <int>{};
    final base = rom.unitBase;
    if (base < 0) return s;
    for (var i = 0; i < rom.unitCount; i++) {
      final at = base + i * rom.table.unitDataSize;
      if (at + 8 > rom.length) break;
      s.add(_u16(at + UnitOffsets.portraitId));
    }
    return s;
  }

  /// face 字段到肖像索引的固定偏移。
  ///
  /// - **FE6**：face 从 1 起编（face=0 是山贼那张通用敌人脸），
  ///   肖像索引 = face - 1。
  /// - **FE7/FE8**：face 与肖像索引一一对应。
  ///
  /// 区分方法：FE6 的 face 值是**连续**的（2,3,4,5…，角色按序编号），
  /// FE7/FE8 的 face 值**稀疏**（2,12,22,35…，因为一人有多套素材）。
  int? _faceOffsetCache;

  int get _faceOffset {
    final cached = _faceOffsetCache;
    if (cached != null) return cached;
    var run = 0;
    while (_unitFaceValues.contains(run + 2)) {
      run++;
    }
    // 连续段越长越像 FE6 那种「一个角色一套肖像」；稀疏的是 FE7/FE8
    final offset = run >= 8 ? -1 : 0;
    _faceOffsetCache = offset;
    return offset;
  }

  String? _unitNameForFace(int id) {
    final base = rom.unitBase;
    if (base < 0) return null;
    final size = rom.table.unitDataSize;
    // FE6：肖像 0 是山贼那张通用敌人脸，对应 face=0 的那批单位；
    // 肖像 N (N>=1) 对应 face = N+1。
    final face = id == 0 ? 0 : id - _faceOffset;
    if (face < 0) return null;
    for (var i = 0; i < rom.unitCount; i++) {
      final at = base + i * size;
      if (at + 8 > rom.length) break;
      // face 是 u16：用 u8 读会把 0x0103 截成 0x03，匹配到错误的肖像
      if (_u16(at + UnitOffsets.portraitId) != face) continue;
      final n = rom.unitName(i);
      if (n.trim().isNotEmpty) return n.trim();
    }
    return null;
  }

  String? _classNameForFace(int id) {
    final base = rom.classBase;
    if (base < 0) return null;
    final size = rom.table.classDataSize;
    // 职业表的 @8 指向的是**职业卡**肖像，与单位表的正脸肖像同属一个 ID 空间，
    // 但编号起点规则一致（FE6 差 1，FE7/FE8 相同）。
    final face = id == 0 ? 0 : id - _faceOffset;
    if (face < 0) return null;
    for (var i = 0; i < rom.classCount; i++) {
      final at = base + i * size;
      if (at + 10 > rom.length) break;
      if (_u16(at + ClassOffsets.portraitId) != face) continue;
      final n = rom.className(i);
      if (n.trim().isNotEmpty) return n.trim();
    }
    return null;
  }

  void dispose() => _sheetCache.clear();
}
