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
  ///
  /// **必须随内容版本号失效**：写入后表里的指针变了，但 id 没变，
  /// 只按 id 缓存就会一直端出换脸前的图（实测：导入一张脸后撤销全部，
  /// 界面仍是导入的那张）。
  final _sheetCache = <int, TileImage>{};
  static const int _sheetCacheLimit = 24;

  /// 缓存建立时的内容版本号；与 [rom.contentVersion] 不一致时整体丢弃。
  int _cacheVersion = -1;

  /// 与当前内容版本号对齐：数据被改过就丢掉全部派生数据（sheet 与表规模）。
  void _syncVersion() {
    if (_cacheVersion == rom.contentVersion) return;
    _cacheVersion = rom.contentVersion;
    _sheetCache.clear();
    _count = null;
    _base = null;
    _probeCache = null;
  }

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
    _syncVersion();
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
    _syncVersion();
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
      final pointersOk =
          _isPointerOrNull(u0) && _isPointerOrNull(u4) && _isPointerOrNull(u8);
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
    return rom.data[at] |
        (rom.data[at + 1] << 8) |
        (rom.data[at + 2] << 16) |
        (rom.data[at + 3] << 24);
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
    _syncVersion();
    // 先卡表边界：只查「读得进 ROM」会让超界的 id 落在表后面的
    // 其它数据上，解出一张看起来像样的垃圾图（实测 id=9999 能出图）。
    if (id < 0 || id >= entryCount) return null;
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

  int _u16(int at) => at >= 0 && at + 1 < rom.length
      ? rom.data[at] | (rom.data[at + 1] << 8)
      : 0;

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
    _syncVersion();
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
    TileImage.blit(face, pw * 2 + pw ~/ 2, ph * 3, pw ~/ 2, ph * 2, src,
        pw * 5 + pw ~/ 2, 0);
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
    // [frame] 是**外部 1 基帧号**（1..6，与界面、FE6 分支一致）。
    // 内部 y 偏移必须减 1：以前这里直接用 `ph * frame`，既不接受 6
    // （`frame > 5` 直接返回 null，于是第 6 帧永远看不到），
    // 又让每一帧都偏离实际位置一帧（帧 1 读到的其实是第 2 帧）。
    if (frame < 1 || frame > 6) return null;
    final out = TileImage(pw, ph);
    TileImage.blit(out, 0, 0, pw, ph, m, 0, ph * (frame - 1));
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

  /// 完整素材图（256×40 或 FE6 的 256×34），即游戏内部 sheet 本身。
  ///
  /// **这是内部存储格式，不是 FEBuilderGBA 的可再导入素材图**：
  /// 六块脸/肩散放在 sheet 各处的原始位置，人眼看着是碎片。
  /// 想导出能再导回的图用 [sheetMaterialImage]。
  TileImage? fullSheetImage(int id) {
    final e = entryAt(id);
    if (e == null) return null;
    final pal = _palette(e.palette);
    if (pal == null) return null;
    final src = sheet(e);
    if (src == null) return null;
    // sheet 已经是 256×sheetHeight 的 4bpp TileImage，直接返回即可
    return src;
  }

  /// FEBuilderGBA 布局的完整素材图（128×112），可直接导回去。
  ///
  /// 布局与 `ImagePortraitForm.DrawPortraitSeet` / `DrawPortraitSeetFE6`
  /// 逐项对应（GPL-3.0，7743 著），也与本文件 `PortraitSheetLayout` 的
  /// 分区提取互为逆变换：
  ///
  /// ```
  /// (0,0)   96×80  正脸
  /// (96,16) 32×32  地图小头像
  /// (96,48) 32×16  とろん目   （仅 FE7/FE8）
  /// (96,64) 32×16  閉じ目     （仅 FE7/FE8）
  /// (0,80)  96×32  嘴型 2×3 帧（FE6 是 2×2 + 帧5 两半）
  /// ```
  ///
  /// **不能靠 `faceImage` 等已上色的图拼**：那些图把调色板索引 0 画成透明，
  /// 而 FE6 的索引 0 是**不透明背景色**（实测罗伊那张 6 块里 47.8% 是索引 0），
  /// 按透明图拼出来再导入会把背景整块当作「没画」，脸部会少一大半。
  /// 所以这里直接搬 4bpp 索引，只在最后一步上色。
  ///
  /// 取不到图时返回 null。
  TileImage? sheetMaterialImage(int id) {
    final e = entryAt(id);
    if (e == null) return null;
    final pal = _palette(e.palette);
    if (pal == null) return null;
    final faceIdx = faceIndices(id);
    if (faceIdx == null) return null;

    // 先把各块拆成「每像素一个索引」的网格。
    // 一律按 40 行建网格（FE6 只有 34 行数据，其余按索引 0 补满）：
    // 嘴型/眼型的坑位坐标都是按 40 行布局定义的。
    final faceGrid = _unpackSheet(faceIdx, 40);
    final face96 = Uint8List(96 * 80);
    for (final b in _faceBlits) {
      final dstX = b[0], dstY = b[1], w = b[2], h = b[3];
      final srcX = b[4], srcY = b[5];
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          face96[(dstY + y) * 96 + dstX + x] =
              faceGrid[(srcY + y) * 256 + srcX + x];
        }
      }
    }

    const lw = 128;
    const lh = 112;
    final out = Uint8List(lw * lh);
    void paste(Uint8List src, int sw, int sh, int dx, int dy) {
      for (var y = 0; y < sh; y++) {
        for (var x = 0; x < sw; x++) {
          final tx = dx + x, ty = dy + y;
          if (tx < 0 || tx >= lw || ty < 0 || ty >= lh) continue;
          out[ty * lw + tx] = src[y * sw + x];
        }
      }
    }

    paste(face96, 96, 80, 0, 0);

    final mapIdx = mapFaceIndices(id);
    if (mapIdx != null) paste(_unpack4bpp(mapIdx, 32, 32), 32, 32, 96, 16);

    const mouthY = 80;
    if (!isFe6) {
      // 眼型帧与第 7 口在正脸 sheet 右侧：とろん目 (192,0)、(192,16) 閉じ目
      final eyes = Uint8List(32 * 32);
      for (var y = 0; y < 32; y++) {
        for (var x = 0; x < 32; x++) {
          eyes[y * 32 + x] = faceGrid[y * 256 + 192 + x];
        }
      }
      paste(Uint8List.sublistView(eyes, 0, 32 * 16), 32, 16, 96, 48);
      paste(Uint8List.sublistView(eyes, 32 * 16, 32 * 32), 32, 16, 96, 64);

      final mouthIdx = mouthIndices(id);
      if (mouthIdx != null) {
        final mg = _unpack4bpp(mouthIdx, 32, 96);
        for (var f = 0; f < 6; f++) {
          final col = f % 3, row = f ~/ 3;
          paste(Uint8List.sublistView(mg, f * 32 * 16, (f + 1) * 32 * 16), 32,
              16, col * 32, mouthY + row * 16);
        }
      }
      // 第 7 口（右端の口）与它下方那格余白：FEBuilderGBA 会把正脸 sheet
      // 右侧 x=(192..224) 的两格也画进素材图。导回时 `_spreadFe78SheetParts`
      // 会把它们 blit 回 sheet (224,0)/(224,16)，不写这两格就会把它们清零。
      for (var row = 0; row < 2; row++) {
        final cell = Uint8List(32 * 16);
        for (var y = 0; y < 16; y++) {
          for (var x = 0; x < 32; x++) {
            cell[y * 32 + x] = faceGrid[(row * 16 + y) * 256 + 224 + x];
          }
        }
        paste(cell, 32, 16, 96, mouthY + row * 16);
      }
    } else {
      // FE6 嘴型四帧在正脸 sheet 的 (192,0)(224,0)(192,16)(224,16)，
      // 帧 5 的两半在 (0,32) 与 (32,32)（各 32×8）。
      const slots = [
        [192, 0, 0, mouthY, 32, 16],
        [224, 0, 32, mouthY, 32, 16],
        [192, 16, 0, mouthY + 16, 32, 16],
        [224, 16, 32, mouthY + 16, 32, 16],
      ];
      for (final s in slots) {
        final cell = Uint8List(32 * 16);
        for (var y = 0; y < s[5]; y++) {
          for (var x = 0; x < s[4]; x++) {
            cell[y * 32 + x] = faceGrid[(s[1] + y) * 256 + s[0] + x];
          }
        }
        paste(cell, 32, 16, s[2], s[3]);
      }
      // 帧 5：素材图右端「口」两半
      for (var half = 0; half < 2; half++) {
        final cell = Uint8List(32 * 8);
        for (var y = 0; y < 8; y++) {
          for (var x = 0; x < 32; x++) {
            cell[y * 32 + x] = faceGrid[(32 + y) * 256 + half * 32 + x];
          }
        }
        paste(cell, 32, 8, 96, mouthY + half * 8);
      }
    }

    return _colorize(out, pal);
  }

  /// 正脸 96×80 的六块拼图：(dstX, dstY, w, h, srcX, srcY)。
  ///
  /// 与 `faceImage` 的六次 `TileImage.blit`、以及
  /// `PortraitImporter` / FEBuilderGBA `DrawPortraitSeet` 完全一致。
  static const List<List<int>> _faceBlits = [
    [16, 0, 64, 32, 0, 0],
    [16, 32, 64, 32, 64, 0],
    [16, 64, 32, 16, 128, 0],
    [0, 48, 16, 32, 160, 0],
    [48, 64, 32, 16, 128, 16],
    [80, 48, 16, 32, 176, 0],
  ];

  /// 索引网格 → 上色 RGBA。索引 0 在这里也正常上色（不当作透明）——
  /// 素材图是「看得见的整张图」，背景色属于图的一部分。
  TileImage _colorize(Uint8List grid, GbaPalette pal, {int width = 128}) {
    final h = grid.length ~/ width;
    final img = TileImage(width, h);
    for (var i = 0; i < grid.length; i++) {
      final idx = grid[i];
      final c = pal.color(idx);
      img.setPixel(i % width, i ~/ width, (c >> 16) & 0xFF,
          (c >> 8) & 0xFF, c & 0xFF, 0xFF);
    }
    return img;
  }

  /// 256×[height] 的 4bpp sheet → 每像素一个索引的网格（与 `_packGrid` 互逆）。
  ///
  /// FE6 的 sheet 只有 34 行（8704 字节），而网格按 40 行布局：越界部分按
  /// 索引 0 补满。原版 FEBuilderGBA 渲染 FE6 时也是这么处理的
  /// （`ByteToImage16Tile(256, 40)` 读到 34 行之后全是 0）。
  Uint8List _unpackSheet(Uint8List sheet, int height) {
    final grid = Uint8List(256 * height);
    final tilesPerRow = 256 ~/ 8;
    const tileRowBytes = 32 * 32;
    for (var y = 0; y < height; y++) {
      final band = y ~/ 8, rit = y % 8;
      for (var tx = 0; tx < tilesPerRow; tx++) {
        final base = band * tileRowBytes + tx * 32 + rit * 4;
        if (base + 4 > sheet.length) continue;
        for (var k = 0; k < 4; k++) {
          grid[y * 256 + tx * 8 + k * 2] = sheet[base + k] & 0x0F;
          grid[y * 256 + tx * 8 + k * 2 + 1] = (sheet[base + k] >> 4) & 0x0F;
        }
      }
    }
    return grid;
  }

  Uint8List _unpack4bpp(Uint8List data, int width, int height) {
    final grid = Uint8List(width * height);
    final tilesPerRow = width ~/ 8;
    final tileRowBytes = tilesPerRow * 32;
    for (var y = 0; y < height; y++) {
      final band = y ~/ 8, rit = y % 8;
      for (var tx = 0; tx < tilesPerRow; tx++) {
        final base = band * tileRowBytes + tx * 32 + rit * 4;
        if (base + 4 > data.length) continue;
        for (var k = 0; k < 4; k++) {
          grid[y * width + tx * 8 + k * 2] = data[base + k] & 0x0F;
          grid[y * width + tx * 8 + k * 2 + 1] = (data[base + k] >> 4) & 0x0F;
        }
      }
    }
    return grid;
  }


  /// face 字段值 → 肖像表索引。超出表范围或无法映射时返回 null。
  ///
  /// **方向**：`_faceOffset` 定义为「肖像索引 + offset == face」的修正量，
  /// FE6 下它是 -1（即 face = 肖像 + 1），所以反推是 **face + _faceOffset**。
  /// 常量名字容易看反，这里写死成加法并注明；写成减法会让整个列表偏 2 格
  /// （实测封印之剑：罗伊 face=2 → 错拿成肖像 3 珐，而前两个角色直接无图）。
  int? faceToPortraitId(int face) {
    if (face < 0) return null;
    final id = face == 0 ? 0 : face + _faceOffset;
    if (id < 0) return null;
    if (id >= entryCount) return null;
    return hasImage(id) ? id : null;
  }

  /// 肖像 ID → 单位/职业表里的 `face` 字段值（[faceToPortraitId] 的反向）。
  ///
  /// 换脸时必须走它：FE6 的 face 是「肖像索引 + 1」，直接写肖像 ID
  /// 会让整张表偏一格（详见 AGENTS 第 6 节）。
  int portraitToFaceId(int id) => id == 0 ? 0 : id - _faceOffset;

  /// 反查使用该肖像的角色名（单位表优先，其次职业表）。
  String nameFor(int id) {
    final name = _unitNameForFace(id);
    if (name != null && name.isNotEmpty) return name;
    final cname = _classNameForFace(id);
    if (cname != null && cname.isNotEmpty) return cname;
    return '';
  }

  /// 反查使用该肖像的**单位表索引**，没有则 null。
  ///
  /// 与 [nameFor] 用的是同一套 face 偏移规则（FE6 差 1，FE7/FE8 相同）。
  int? unitIndexForFace(int id) {
    final base = rom.unitBase;
    if (base < 0) return null;
    final size = rom.table.unitDataSize;
    final face = id == 0 ? 0 : id - _faceOffset;
    if (face < 0) return null;
    for (var i = 0; i < rom.unitCount; i++) {
      final at = base + i * size;
      if (at + 8 > rom.length) break;
      if (_u16(at + UnitOffsets.portraitId) == face) return i;
    }
    return null;
  }

  /// 反查所有 face 字段引用 [id] 的单位索引列表。
  ///
  /// 与 [unitIndexForFace] 的区别：返回全部匹配（一个肖像可被多个单位共用，如琳有两份出场）。
  List<int> unitIndicesForPortrait(int id) {
    final base = rom.unitBase;
    if (base < 0) return const [];
    final size = rom.table.unitDataSize;
    final face = id == 0 ? 0 : id - _faceOffset;
    if (face < 0) return const [];
    final result = <int>[];
    for (var i = 0; i < rom.unitCount; i++) {
      final at = base + i * size;
      if (at + 8 > rom.length) break;
      if (_u16(at + UnitOffsets.portraitId) == face) result.add(i);
    }
    return result;
  }

  /// 反查使用该「职业卡」肖像的职业表索引，没有则 null。
  int? classIndexForFace(int id) {
    final base = rom.classBase;
    if (base < 0) return null;
    final size = rom.table.classDataSize;
    final face = id == 0 ? 0 : id - _faceOffset;
    if (face < 0) return null;
    for (var i = 0; i < rom.classCount; i++) {
      final at = base + i * size;
      if (at + 10 > rom.length) break;
      if (_u16(at + ClassOffsets.portraitId) == face) return i;
    }
    return null;
  }

  /// 该肖像有没有图（没有图的条目只是占位）。
  bool hasImage(int id) {
    final e = entryAt(id);
    if (e == null) return false;
    return e.unitFace != 0 || e.mapFace != 0 || e.classFace != 0;
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
      final n = rom.unitDisplayName(i);
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
      final n = rom.classDisplayName(i);
      if (n.trim().isNotEmpty) return n.trim();
    }
    return null;
  }

  /// 这张肖像是谁在用的（角色名 + 职业名），用于替换前看清影响面。
  ///
  /// 返回人类可读的一行，例如「艾利乌德（领主）· 还用于 2 个职业」；
  /// 没人用返回空串。只查单位表的正脸字段与职业表的职业卡字段 —— 这两处是
  /// 原版唯一的引用来源（章节单位、事件脚本都引用角色 ID，不直接引用肖像）。
  String usageOf(int id) {
    final unit = unitIndexForFace(id);
    final cls = classIndexForFace(id);
    final users = <String>[];
    if (unit != null) {
      final n = rom.unitDisplayName(unit).trim();
      users.add(n.isEmpty ? '角色 $unit' : n);
    }
    if (cls != null) {
      final n = rom.classDisplayName(cls).trim();
      users.add(n.isEmpty ? '职业 $cls' : n);
    }
    return users.join(' / ');
  }

  void dispose() => _sheetCache.clear();
  // ---------- 原始索引（供跨版本移植用，不做像素重建） ----------
  //
  // 上面的 faceImage / mouthFrame 等都返回**上色后的像素**，而移植需要的是
  // 4bpp 调色板索引本身——索引 0 在像素里是透明，反推不回来。所以这里直接
  // 解出索引字节。

  /// 正脸 sheet 的 4bpp 索引字节（每行 `256/2 = 128` 字节，每字节两像素）。
  ///
  /// 返回长度：FE6 = 4352（34 行），FE7/FE8 = 5120（40 行）。
  /// 取不到返回 null。
  Uint8List? faceIndices(int id) {
    final e = entryAt(id);
    if (e == null || e.unitFace <= 0) return null;
    if (isFe6) {
      final uz = Lz77.decompress(rom.data, e.unitFace);
      if (uz == null || uz.isEmpty) return null;
      // FE6 正脸是 256×34；个别改版/工具可能写成 40 行，多出来的截掉
      const need = 256 * 34 ~/ 2;
      return uz.length > need ? Uint8List.sublistView(uz, 0, need) : uz;
    }
    if (Lz77.isCompressed(rom.data, e.unitFace)) {
      return Lz77.decompress(rom.data, e.unitFace);
    }
    // 明文：4 字节头 + 数据
    final start = e.unitFace + 4;
    final len = _isHalfBody(e.unitFace) ? 256 * 80 ~/ 2 : 256 * 40 ~/ 2;
    if (start + len > rom.length) return null;
    // 明文 sheet 也可能是 34 行（移植写回 FE6 时留了 34 行的 LZ77，
    // 但改版可能直接放明文）；按实际可用长度截断，避免越界。
    return Uint8List.sublistView(rom.data, start, start + len);
  }

  /// 嘴型图的 4bpp 索引字节（32×96，即 4 宽 × 6 帧）。FE6 没有独立嘴型数据，返回 null。
  Uint8List? mouthIndices(int id) {
    if (isFe6) return null;
    final e = entryAt(id);
    if (e == null || e.mouth <= 0 || !_valid(e.mouth)) return null;
    const len = 32 * 96 ~/ 2;
    if (e.mouth + len > rom.length) return null;
    return Uint8List.sublistView(rom.data, e.mouth, e.mouth + len);
  }

  /// 地图头像的 4bpp 索引字节（32×32 = 512 字节）。
  Uint8List? mapFaceIndices(int id) {
    final e = entryAt(id);
    if (e == null || e.mapFace <= 0 || !_valid(e.mapFace)) return null;
    const len = 32 * 32 ~/ 2;
    if (isFe6) {
      if (e.mapFace + len > rom.length) return null;
      return Uint8List.sublistView(rom.data, e.mapFace, e.mapFace + len);
    }
    final uz = Lz77.decompress(rom.data, e.mapFace);
    if (uz == null || uz.length < len) return null;
    return Uint8List.sublistView(uz, 0, len);
  }

  /// 调色板的 32 字节原始数据（16 色 BGR555）。
  Uint8List? paletteBytes(int id) {
    final e = entryAt(id);
    if (e == null || e.palette <= 0 || !_valid(e.palette)) return null;
    if (e.palette + 32 > rom.length) return null;
    return Uint8List.sublistView(rom.data, e.palette, e.palette + 32);
  }
}
