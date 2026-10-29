import 'dart:io' show ZLibCodec;
import 'dart:typed_data';
import 'fe_rom.dart';
import 'portrait.dart' show Lz77;
import 'tile_image.dart';

/// 战斗动画一览里的一条：32 字节结构体。
///
/// 布局来自 fireemblem8u 的 `include/banim_data.h`：
/// ```c
/// struct BattleAnim {
///     char abbr[12];   // 00
///     int * modes;     // 0C
///     char * script;   // 10
///     char * oam_r;    // 14
///     char * oam_l;    // 18
///     char * pal;      // 1C
/// };
/// ```
/// 五个指针里 `modes` 与 `script`/`oam_r`/`oam_l`/`pal` 都在真实 ROM 上逐个验证过。
class BattleAnimEntry {
  final int id;

  /// 12 字节 ASCII 缩写，如 `lorm_sp1`（领主·男·枪1）。
  final String abbr;

  final int modes;
  final int script;
  final int oamRightToLeft;
  final int oamLeftToRight;
  final int palette;

  const BattleAnimEntry({
    required this.id,
    required this.abbr,
    required this.modes,
    required this.script,
    required this.oamRightToLeft,
    required this.oamLeftToRight,
    required this.palette,
  });
}

/// 战斗动画里的一个模式。索引 0..11 对应游戏内的 12 种动作。
///
/// 名字取 fireemblem8u 的 `banim_script.inc` 符号后缀。
class AnimMode {
  final int index;
  final String label;

  /// 该模式在 `script` 解压数据里的帧区间 [start, end)。
  final int start;
  final int end;

  const AnimMode(this.index, this.label, this.start, this.end);

  int get length => end - start;
}

/// `script` 解压数据里的一条帧记录（4 字节对齐的记录流）。
///
/// 记录以第 4 字节区分类型：
/// - `0x86` 图像帧：前 2 字节是等待时长，+4 是图形指针，+8 是 OAM 起始偏移
/// - `0x85` 命令（音乐、延时、循环等）
/// - `0x80` 模式终帧
class AnimFrame {
  final int offset;
  final int wait;

  /// 图形 sheet 的 GBA 指针。
  final int graphics;

  /// OAM 数据在 `oam_r` 解压结果里的起始偏移。
  final int oamOffset;

  const AnimFrame(this.offset, this.wait, this.graphics, this.oamOffset);
}

/// 战斗动画读取、模式拆分与帧渲染。
///
/// 数据来源：fireemblem8u 的 `banim_data.h` / `banim_pointer.h` 结构定义，
/// 加上 FEBuilderGBA `ImageUtilOAM.cs`（GPL-3.0，7743 著）的 OAM 绘制规则；
/// 实现为本项目独立重写，未搬运 C# 代码。
class BattleAnimReader {
  final FeRom rom;
  BattleAnimReader(this.rom);

  /// 屏幕尺寸：GBA 战斗画面在 FE 里按 31×20 个 8px tile 渲染。
  static const int screenWidth = 248;
  static const int screenHeight = 160;

  /// 图形 sheet 尺寸：256×64，16 色。
  static const int sheetWidth = 256;
  static const int sheetHeight = 64;

  /// OAM 部件贴到屏幕时加的基准偏移（与参考实现一致）。
  static const int _oamBaseX = 0x94;
  static const int _oamBaseY = 0x58;

  /// 模式名。索引是**从 0 起**的内部编号，标签对应地表示第 1~12 号模式。
  ///
  /// 名称来自 FEBuilderGBA 的 `battleanime_mode_ALL.zh.txt`（与日文原文逐条对应）：
  /// 01 攻击命中 03 攻击必杀 05 间接攻击 06 间接必杀 07 被近战攻击回避
  /// 08 被间接攻击回避 09 近战待机 0A 待机 0B 间接待机 0C 攻击失误。
  ///
  /// **02 和 04 没有对应条目**：它们是模式 01/03 的武器图层，
  /// 游戏里与 01/03 成对使用，所以这里一并渲染但不单独展示。
  static const List<String> modeLabels = [
    '攻击命中',
    '攻击命中（武器图层）',
    '攻击必杀',
    '攻击必杀（武器图层）',
    '间接攻击',
    '间接必杀',
    '被近战攻击回避',
    '被间接攻击回避',
    '近战待机',
    '待机',
    '间接待机',
    '攻击失误',
  ];

  /// 与 [modeLabels] 对应：这些模式是相邻模式的合成图层，不单独展示。
  static bool isWeaponLayer(int index) => index == 1 || index == 3;

  bool get available => rom.table.battleAnimPointerSlot > 0;

  int? _base;

  /// 表基址（文件偏移）；不可用时返回 -1。
  int get base {
    final cached = _base;
    if (cached != null) return cached;
    final slot = rom.table.battleAnimPointerSlot;
    final v = slot > 0 ? rom.pointerAt(slot) : -1;
    _base = v;
    return v;
  }

  int get entrySize =>
      rom.table.battleAnimDataSize == 0 ? 32 : rom.table.battleAnimDataSize;

  int? _count;

  /// 条目数。
  ///
  /// 边界靠「缩写是可打印 ASCII 且 script 指针有效」判定——表里没有 ID 字段，
  /// 不能像单位表那样靠 ID 连续性。实测 FE6/FE7/FE8 = 122/162/201。
  int get count {
    final cached = _count;
    if (cached != null) return cached;
    if (base <= 0) return _count = 0;
    var n = 0;
    while (true) {
      final at = base + entrySize * n;
      if (at + entrySize > rom.length) break;
      if (!_looksLikeEntry(at)) break;
      n++;
      if (n > 512) break;
    }
    return _count = n;
  }

  bool _looksLikeEntry(int at) {
    var printable = 0;
    for (var i = 0; i < 12; i++) {
      final b = rom.data[at + i];
      if (b == 0) break;
      if (b < 0x20 || b > 0x7E) return false;
      printable++;
    }
    if (printable < 5) return false;
    // 四个数据指针槽都必须是有效 GBA 指针（这里传的是槽地址）
    return _slotOffset(at + 16) > 0 &&
        _slotOffset(at + 20) > 0 &&
        _slotOffset(at + 24) > 0 &&
        _slotOffset(at + 28) > 0;
  }

  List<BattleAnimEntry>? _entries;

  List<BattleAnimEntry> get entries {
    final cached = _entries;
    if (cached != null) return cached;
    final list = <BattleAnimEntry>[];
    for (var i = 0; i < count; i++) {
      final at = base + entrySize * i;
      var name = <int>[];
      for (var k = 0; k < 12; k++) {
        final b = rom.data[at + k];
        if (b == 0) break;
        name.add(b);
      }
      list.add(BattleAnimEntry(
        id: i,
        abbr: String.fromCharCodes(name),
        modes: FeRom.u32(rom.data, at + 12),
        script: FeRom.u32(rom.data, at + 16),
        oamRightToLeft: FeRom.u32(rom.data, at + 20),
        oamLeftToRight: FeRom.u32(rom.data, at + 24),
        palette: FeRom.u32(rom.data, at + 28),
      ));
    }
    return _entries = list;
  }

  BattleAnimEntry? entry(int id) {
    if (id < 0 || id >= count) return null;
    return entries[id];
  }

  /// GBA 指针值解成文件偏移；越界或不是合法指针时返回 -1。
  int _ptrToOffset(int pointer) {
    if (!FeRom.isPointer(pointer, rom.length)) return -1;
    final off = FeRom.toOffset(pointer);
    return off < rom.length ? off : -1;
  }

  /// 读 [slot] 处存的 GBA 指针并解成文件偏移（槽形式：结构体里的指针字段）。
  int _slotOffset(int slot) {
    if (slot < 0 || slot + 4 > rom.length) return -1;
    return _ptrToOffset(FeRom.u32(rom.data, slot));
  }

  /// 结构体里的指针字段：字段值已经是数据地址，直接转偏移。
  int _fieldOffset(int pointer) => _ptrToOffset(pointer);

  // ---------- 模式 ----------

  /// 12 个模式的帧区间。
  ///
  /// `modes` 指向固定 12 个 u32，是 `script` **解压后**数据的切分点；
  /// 最后一个模式的结束位置就是解压长度（表里只有 12 项，没有第 13 项终止值）。
  List<AnimMode> modesOf(BattleAnimEntry e) {
    final modesOff = _fieldOffset(e.modes);
    final scriptOff = _fieldOffset(e.script);
    if (modesOff < 0 || scriptOff < 0) return const [];
    final scriptLength = Lz77.uncompressedSize(rom.data, scriptOff);
    if (scriptLength <= 0) return const [];
    final starts = <int>[];
    for (var i = 0; i < 12; i++) {
      starts.add(FeRom.u32(rom.data, modesOff + i * 4));
    }
    final out = <AnimMode>[];
    for (var i = 0; i < 12; i++) {
      final start = starts[i];
      final end = i + 1 < 12 ? starts[i + 1] : scriptLength;
      if (start > scriptLength || end > scriptLength || end < start) continue;
      out.add(AnimMode(i, modeLabels[i], start, end));
    }
    return out;
  }

  final _scriptCache = <int, Uint8List>{};

  /// 取 `script` 解压后的字节流（按指针缓存，单条动画只解一次）。
  Uint8List? scriptData(BattleAnimEntry e) {
    final off = _fieldOffset(e.script);
    if (off < 0) return null;
    final cached = _scriptCache[off];
    if (cached != null) return cached;
    final uz = Lz77.decompress(rom.data, off);
    if (uz == null) return null;
    if (_scriptCache.length > 8) _scriptCache.clear();
    return _scriptCache[off] = uz;
  }

  /// 该模式下的全部图像帧。
  List<AnimFrame> framesOf(BattleAnimEntry e, AnimMode mode) {
    final script = scriptData(e);
    if (script == null) return const [];
    final out = <AnimFrame>[];
    var i = mode.start;
    while (i + 4 <= mode.end && i + 4 <= script.length) {
      final kind = script[i + 3];
      if (kind == 0x86) {
        if (i + 12 > script.length) break;
        out.add(AnimFrame(
          i,
          script[i] | (script[i + 1] << 8),
          FeRom.u32(script, i + 4),
          FeRom.u32(script, i + 8),
        ));
        i += 12;
        continue;
      }
      if (kind == 0x80) break;
      i += 4;
    }
    return out;
  }

  // ---------- 渲染 ----------

  final _oamCache = <int, Uint8List>{};
  final _sheetCache = <int, TileImage>{};

  /// OAM 数据（按指针缓存，供同一条动画的多帧复用）。
  Uint8List? _oamData(int pointer) {
    final off = _fieldOffset(pointer);
    if (off < 0) return null;
    final cached = _oamCache[off];
    if (cached != null) return cached;
    final uz = Lz77.decompress(rom.data, off);
    if (uz == null) return null;
    if (_oamCache.length > 8) _oamCache.clear();
    return _oamCache[off] = uz;
  }

  /// 调色板原始字节：4 组 × 16 色 × 2 字节。
  Uint8List? _paletteData(BattleAnimEntry e) {
    final off = _fieldOffset(e.palette);
    if (off < 0) return null;
    return Lz77.decompress(rom.data, off);
  }

  /// 取第 [group] 组调色板（0=自军 1=敌军 2=友军 3=灰色）。
  GbaPalette? paletteOf(BattleAnimEntry e, int group) {
    final data = _paletteData(e);
    if (data == null || data.length < 32) return null;
    final g = group.clamp(0, (data.length ~/ 32) - 1);
    final pal = GbaPalette();
    for (var i = 0; i < 16; i++) {
      final o = g * 32 + i * 2;
      if (o + 1 >= data.length) break;
      final c = data[o] | (data[o + 1] << 8);
      final r = (c & 0x1F) << 3;
      final g6 = ((c >> 5) & 0x1F) << 3;
      final b = ((c >> 10) & 0x1F) << 3;
      pal.argb[i] = 0xFF000000 | (r << 16) | (g6 << 8) | b;
    }
    return pal;
  }

  /// 渲染一张图形 sheet（256×64）。
  ///
  /// 缓存键必须**带上调色板组**：同一张 sheet 在自军/敌军/友军/灰色四种配色下
  /// 像素完全不同，只按图形指针做键会让换组后仍显示上一组的颜色。
  TileImage? sheetOf(
      int graphicsPointer, GbaPalette palette, int paletteGroup) {
    final off = _fieldOffset(graphicsPointer);
    if (off < 0) return null;
    final key = off * 4 + (paletteGroup & 3);
    final cached = _sheetCache[key];
    if (cached != null) return cached;
    final uz = Lz77.decompress(rom.data, off);
    if (uz == null) return null;
    final img = decode4bpp(uz, 0, sheetWidth, sheetHeight, palette);
    if (_sheetCache.length > 12) _sheetCache.clear();
    return _sheetCache[key] = img;
  }

  /// 渲染一帧到 248×160 的屏幕画布。
  ///
  /// [mode] 为 1/3（近战攻击/必杀）时会叠加紧随其后的模式（2/4）——游戏里
  /// 武器图层是分开存在后面那个模式里的，只画一个会缺武器。
  TileImage? renderFrame(
    BattleAnimEntry e,
    AnimMode mode,
    int frameIndex, {
    int paletteGroup = 0,
  }) {
    final palette = paletteOf(e, paletteGroup);
    if (palette == null) return null;
    final oam = _oamData(e.oamRightToLeft);
    if (oam == null) return null;

    final frames = framesOf(e, mode);
    if (frameIndex < 0 || frameIndex >= frames.length) return null;

    final canvas = _blank();
    final drawn =
        _drawFrame(canvas, e, frames[frameIndex], palette, oam, paletteGroup);
    if (!drawn) return null;

    // 模式 01/03（索引 0/2）的武器在紧随其后的图层里，需要合绘。
    if (!isWeaponLayer(mode.index)) {
      final modes = modesOf(e);
      if (mode.index + 1 < modes.length && isWeaponLayer(mode.index + 1)) {
        final over = framesOf(e, modes[mode.index + 1]);
        if (frameIndex < over.length) {
          _drawFrame(canvas, e, over[frameIndex], palette, oam, paletteGroup);
        }
      }
    }
    return canvas;
  }

  TileImage _blank() => TileImage(screenWidth, screenHeight);

  bool _drawFrame(
    TileImage canvas,
    BattleAnimEntry e,
    AnimFrame frame,
    GbaPalette palette,
    Uint8List oam,
    int paletteGroup,
  ) {
    final sheet = sheetOf(frame.graphics, palette, paletteGroup);
    if (sheet == null) return false;
    _drawOam(canvas, sheet, oam, frame.oamOffset);
    return true;
  }

  /// OAM 指令流：每条 12 字节，首字节 0x01 表示结束。
  ///
  /// 部件要**逆序**贴——参考实现明确按 translist 倒序绘制，
  /// 正序会让后面的部件被前面的盖住（武器被身体挡住之类）。
  void _drawOam(TileImage canvas, TileImage sheet, Uint8List oam, int start) {
    final parts = <_OamPart>[];
    var i = start;
    while (i + 12 <= oam.length) {
      if (oam[i] == 1) break;
      // 仿射矩阵定义项（第 2、3 字节都是 0xFF），本实现不参与贴图
      if (oam[i + 2] == 0xFF && oam[i + 3] == 0xFF) {
        i += 12;
        continue;
      }
      if (oam[i] != 0) break;

      final align = oam[i + 1];
      final area = oam[i + 3];
      final size = _areaToTiles(align, area);
      final sheetX = (oam[i + 4] & 0x1F) * 8;
      final sheetY = ((oam[i + 4] & 0xE0) >> 5) * 8;
      var imageX = (oam[i + 6] | (oam[i + 7] << 8));
      if (imageX >= 0x8000) imageX -= 0x10000;
      var imageY = (oam[i + 8] | (oam[i + 9] << 8));
      if (imageY >= 0x8000) imageY -= 0x10000;
      imageX += _oamBaseX;
      imageY += _oamBaseY;
      if (imageX >= 256) imageX = imageX & 0xFF;

      parts.add(_OamPart(
        width: size.$1 * 8,
        height: size.$2 * 8,
        sheetX: sheetX,
        sheetY: sheetY,
        imageX: imageX,
        imageY: imageY,
        hFlip: (area & 0x20) != 0,
        vFlip: (area & 0x10) != 0,
      ));
      i += 12;
    }

    for (var k = parts.length - 1; k >= 0; k--) {
      final p = parts[k];
      _blit(canvas, sheet, p);
    }
  }

  void _blit(TileImage dst, TileImage src, _OamPart p) {
    for (var y = 0; y < p.height; y++) {
      for (var x = 0; x < p.width; x++) {
        final sx = p.sheetX + (p.hFlip ? p.width - 1 - x : x);
        final sy = p.sheetY + (p.vFlip ? p.height - 1 - y : y);
        if (sx < 0 || sy < 0 || sx >= src.width || sy >= src.height) continue;
        final si = (sy * src.width + sx) * 4;
        // 调色板索引 0 = 透明，不能覆盖已有像素
        if (src.pixels[si + 3] == 0) continue;
        final dx = p.imageX + x;
        final dy = p.imageY + y;
        if (dx < 0 || dy < 0 || dx >= dst.width || dy >= dst.height) continue;
        final di = (dy * dst.width + dx) * 4;
        dst.pixels[di] = src.pixels[si];
        dst.pixels[di + 1] = src.pixels[si + 1];
        dst.pixels[di + 2] = src.pixels[si + 2];
        dst.pixels[di + 3] = src.pixels[si + 3];
      }
    }
  }

  /// `align` 与 `area` 的高 2 位共同决定部件是几个 8×8 tile。
  static (int, int) _areaToTiles(int align, int area) {
    final a = align & 0xC0;
    final r = area & 0xC0;
    const horizontal = 0x40;
    const vertical = 0x80;
    if (r == 0xC0) {
      if (a == vertical) return (4, 8);
      if (a == horizontal) return (8, 4);
      return (8, 8);
    }
    if (r == 0x80) {
      if (a == vertical) return (2, 4);
      if (a == horizontal) return (4, 2);
      return (4, 4);
    }
    if (r == 0x40) {
      if (a == vertical) return (1, 4);
      if (a == horizontal) return (4, 1);
      return (2, 2);
    }
    if (a == vertical) return (1, 2);
    if (a == horizontal) return (2, 1);
    return (1, 1);
  }
}

class _OamPart {
  final int width;
  final int height;
  final int sheetX;
  final int sheetY;
  final int imageX;
  final int imageY;
  final bool hFlip;
  final bool vFlip;

  const _OamPart({
    required this.width,
    required this.height,
    required this.sheetX,
    required this.sheetY,
    required this.imageX,
    required this.imageY,
    required this.hFlip,
    required this.vFlip,
  });
}

/// 把 [TileImage] 编码成 PNG。
///
/// 只用到 `dart:io` 的 zlib，不需要第三方依赖；战斗动画导出走这条路，
/// 因为 Flutter 的 `ui.Image` 转字节是异步且依赖渲染管线，导出纯逻辑层更稳。
Uint8List encodePng(TileImage image) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  final ihdr = ByteData(13)
    ..setUint32(0, image.width)
    ..setUint32(4, image.height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6) // color type: RGBA
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);

  // 每行前置一个 filter 字节（0 = None）
  final raw = Uint8List(image.height * (image.width * 4 + 1));
  var w = 0;
  for (var y = 0; y < image.height; y++) {
    raw[w++] = 0;
    final rowStart = y * image.width * 4;
    raw.setRange(w, w + image.width * 4, image.pixels, rowStart);
    w += image.width * 4;
  }

  final builder = BytesBuilder(copy: false);
  builder.add(signature);
  builder.add(_chunk('IHDR', ihdr.buffer.asUint8List()));
  builder.add(_chunk('IDAT', Uint8List.fromList(_zlib.encode(raw))));
  builder.add(_chunk('IEND', Uint8List(0)));
  return builder.toBytes();
}

final _zlib = ZLibCodec(level: 6);

List<int> _chunk(String type, Uint8List data) {
  final out = BytesBuilder(copy: false);
  final length = ByteData(4)..setUint32(0, data.length);
  out.add(length.buffer.asUint8List());
  final typeBytes = type.codeUnits;
  out.add(typeBytes);
  out.add(data);
  final crcInput = Uint8List(typeBytes.length + data.length)
    ..setRange(0, typeBytes.length, typeBytes)
    ..setRange(typeBytes.length, typeBytes.length + data.length, data);
  final crc = ByteData(4)..setUint32(0, _crc32(crcInput));
  out.add(crc.buffer.asUint8List());
  return out.toBytes();
}

int _crc32(Uint8List bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
      crc &= 0xFFFFFFFF;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
