import 'dart:typed_data';

import 'fe_rom.dart';
import 'portrait.dart' show Lz77;
import 'tile_image.dart';

/// 章节地图数据。
///
/// 地图本体是 LZ77 压缩的 MAR：前两字节为宽高（单位是 16×16 的砖块），
/// 之后每两字节是一个砖块 ID。砖块 ID 再经 config（TSA）展开成 4 个 8×8 tile。
class ChapterMap {
  final int chapter;

  /// 宽高以「砖块」为单位（每块 16×16 像素）。
  final int width;
  final int height;

  /// 按行优先的砖块 ID，长度 = width × height。
  final List<int> tiles;

  /// 该章地图数据在 ROM 里的文件偏移（LZ77 起点）。
  final int dataOffset;

  const ChapterMap({
    required this.chapter,
    required this.width,
    required this.height,
    required this.tiles,
    required this.dataOffset,
  });

  int tileAt(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) return -1;
    return tiles[y * width + x];
  }

  ChapterMap copyWith({List<int>? tiles}) => ChapterMap(
        chapter: chapter,
        width: width,
        height: height,
        tiles: tiles ?? this.tiles,
        dataOffset: dataOffset,
      );
}

/// 一个地形（由 config 的 TSA 与地形名表共同确定）。
class TerrainInfo {
  final int id;
  final String name;
  const TerrainInfo(this.id, this.name);
}

/// 地图读取与写回。
///
/// 数据来源：FEBuilderGBA 的 `MapSettingForm` / `ImageUtilMap`（GPL-3.0，7743 著）
/// 的地址与 TSA 展开规则；实现为本项目独立重写。
class MapReader {
  final FeRom rom;
  MapReader(this.rom);

  /// 章节表条目大小：FE6 是 68，FE7J/FE8 是 148，**FE7U 是 152**。
  int get _settingSize {
    switch (rom.table.id) {
      case 'FE6':
        return 68;
      case 'FE7U':
        return 152;
    }
    return 148;
  }

  /// 地图设置表里的「事件 plist 索引」字段位置。
  /// 章节条目内「事件 plist 索引」的位置。
  ///
  /// 条目 152 字节（FE7U）比 148 字节版本多一对 `u16`，该字段后移到 +120。
  /// 按 +116 读会拿到 palette 索引（事件列表指到图形数据）。
  int get _eventPlistPos => _settingSize == 152 ? 120 : 116;

  int? _settingBase;

  int get settingBase {
    final cached = _settingBase;
    if (cached != null) return cached;
    final base = _slotPointer(_chapterSettingSlot);
    _settingBase = base;
    return base;
  }

  /// 各版本的地图设置表指针槽。
  int get _chapterSettingSlot {
    switch (rom.table.id) {
      case 'FE6':
        return 0x2BB20;
      case 'FE7J':
        return 0x31A6C;
      case 'FE7U':
        return 0x31580;
      case 'FE8J':
        return 0x0BAB1C;
      case 'FE8U':
        return 0x0B5F98;
    }
    return 0;
  }

  /// 各版本的地图 plist 表指针槽。
  int get _mapPlistSlot {
    switch (rom.table.id) {
      case 'FE6':
        return 0x02BB70;
      case 'FE7J':
        return 0x031ABC;
      case 'FE7U':
        return 0x03159C;
      case 'FE8J':
        return 0x034588;
      case 'FE8U':
        return 0x034680;
    }
    return 0;
  }

  /// 各版本的 obj（地图图形）plist 表指针槽。
  int get _objPlistSlot {
    switch (rom.table.id) {
      case 'FE6':
        return 0x018AE4;
      case 'FE7J':
        return 0x019618;
      case 'FE7U':
        return 0x019230;
      case 'FE8J':
        return 0x019640;
      case 'FE8U':
        return 0x019968;
    }
    return 0;
  }

  /// 各版本的 palette plist 表指针槽。
  int get _palPlistSlot {
    switch (rom.table.id) {
      case 'FE6':
        return 0x018B18;
      case 'FE7J':
        return 0x01964C;
      case 'FE7U':
        return 0x019264;
      case 'FE8J':
        return 0x019674;
      case 'FE8U':
        return 0x01999C;
    }
    return 0;
  }

  /// 各版本的 config（TSA）plist 表指针槽。
  int get _cfgPlistSlot {
    switch (rom.table.id) {
      case 'FE6':
        return 0x018A7C;
      case 'FE7J':
        return 0x0195B0;
      case 'FE7U':
        return 0x0191C8;
      case 'FE8J':
        return 0x0195D8;
      case 'FE8U':
        return 0x019900;
    }
    return 0;
  }

  /// 地形名表指针槽（指向「地形 ID → 文本 id」）。
  int get _terrainNameSlot {
    switch (rom.table.id) {
      case 'FE6':
        return 0x19F24;
      case 'FE7J':
        return 0x19F34;
      case 'FE7U':
        return 0x19F54;
      case 'FE8J':
        return 0x19F24;
      case 'FE8U':
        return 0x19F44;
    }
    return 0;
  }

  int _slotPointer(int slot) {
    if (slot <= 0) return -1;
    return rom.pointerAt(slot);
  }

  bool get available => settingBase > 0;

  int? _chapterCount;

  /// 章节数：遍历地图设置表，直到名字指针连续失效。
  ///
  /// 表尾可能有少数占位条目（名字指针为 0），不能遇到一个就停；
  /// 反过来也不能无限跑，所以「连续 8 个无效」才判定结束。
  int get chapterCount {
    final cached = _chapterCount;
    if (cached != null) return cached;
    if (!available) return _chapterCount = 0;
    var n = 0;
    var miss = 0;
    var lastValid = 0;
    while (n < 400) {
      final at = settingBase + _settingSize * n;
      if (at + _settingSize > rom.length) break;
      if (rom.pointerAt(at) < 0) {
        miss++;
        if (miss >= 8) break;
      } else {
        miss = 0;
        lastValid = n + 1;
      }
      n++;
    }
    return _chapterCount = lastValid;
  }

  /// 该章的 plist 索引集合。
  PlistSet? plistsOf(int chapter) {
    if (chapter < 0 || chapter >= chapterCount) return null;
    final at = settingBase + _settingSize * chapter;
    return PlistSet(
      obj: FeRom.u16(rom.data, at + 4),
      palette: FeRom.u8(rom.data, at + 6),
      config: FeRom.u8(rom.data, at + 7),
      map: FeRom.u8(rom.data, at + 8),
      anime1: FeRom.u8(rom.data, at + 9),
      anime2: FeRom.u8(rom.data, at + 10),
      change: FeRom.u8(rom.data, at + 11),
      event: FeRom.u8(rom.data, at + _eventPlistPos),
    );
  }

  /// plist 表里第 [index] 项指向的数据偏移。
  int _plistEntry(int slot, int index) {
    final base = _slotPointer(slot);
    if (base < 0 || index < 0) return -1;
    final at = base + 4 * index;
    if (at + 4 > rom.length) return -1;
    return rom.pointerAt(at);
  }

  /// 读该章的砖块数据（不渲染）。
  ChapterMap? chapterMap(int chapter) {
    final p = plistsOf(chapter);
    if (p == null || p.map == 0) return null;
    final off = _plistEntry(_mapPlistSlot, p.map);
    if (off < 0) return null;
    final raw = Lz77.decompress(rom.data, off);
    if (raw == null || raw.length < 4) return null;
    final w = raw[0];
    final h = raw[1];
    if (w <= 0 || h <= 0 || w > 64 || h > 64) return null;
    final tiles = <int>[];
    for (var i = 0; i < w * h; i++) {
      final at = 2 + i * 2;
      if (at + 1 >= raw.length) break;
      tiles.add(raw[at] | (raw[at + 1] << 8));
    }
    if (tiles.length != w * h) return null;
    return ChapterMap(
      chapter: chapter,
      width: w,
      height: h,
      tiles: tiles,
      dataOffset: off,
    );
  }

  // ---------- 图形资源 ----------

  int? _chipCacheChapter;
  Uint8List? _chipCache;

  /// 该章 chipset 的原始 4bit 调色板索引（每像素一个字节，0..15）。
  ///
  /// 地图图形是 32 tile 宽（256px）的 4bpp 索引图，高度由解压长度决定；
  /// 不能在这里直接套调色板——每组 tile 用的组由 TSA 指定。
  Uint8List? chipIndices(int chapter) {
    if (_chipCacheChapter == chapter) return _chipCache;
    final p = plistsOf(chapter);
    if (p == null) return null;

    // obj 是 u16，可以带**两套图形**：低字节是主图形，高字节可选第二套
    // （FEBuilderGBA `ImageUtilMap.DrawMapChipOnly`：`obj_plist & 0xFF` 与
    //  `(obj_plist >> 8) & 0xFF`，注释写明「FE8 没有，FE7 有时会配两套」）。
    // 两套是**纵向拼接**成一张 chipset（`objUZ = objUZ + obj2UZ`）。
    //
    // 只读第一套会导致 TSA 里引用第二套的 tile 全部越界 → 那一格什么都不画、
    // 透出页面白底（就是「部分关卡出现白点」的根因；FE7J 第 5/7/9 章等
    // obj=0x1D1C 的章节最明显）。
    final uz = _chipBytes(p.obj);
    if (uz == null || uz.isEmpty) return null;

    // 4bpp：每字节 2 像素；宽度固定 32 tile（256px）
    final height = uz.length * 2 ~/ chipWidth;
    _chipCacheChapter = chapter;
    _chipHeight = height;
    return _chipCache = decode4bppIndices(uz, chipWidth, height);
  }

  /// 取该章 chipset 的解压字节；[obj] 的高字节非 0 时把第二套拼在后面。
  Uint8List? _chipBytes(int obj) {
    final mainOff = _plistEntry(_objPlistSlot, obj & 0xFF);
    if (mainOff < 0) return null;
    final main = Lz77.decompress(rom.data, mainOff);
    if (main == null || main.isEmpty) return null;
    final secondIndex = (obj >> 8) & 0xFF;
    if (secondIndex == 0) return main;
    final secondOff = _plistEntry(_objPlistSlot, secondIndex);
    if (secondOff < 0) return main;
    final second = Lz77.decompress(rom.data, secondOff);
    if (second == null || second.isEmpty) return main;
    return Uint8List.fromList([...main, ...second]);
  }

  int _chipHeight = 0;

  int get chipHeight => _chipHeight;

  static const int chipWidth = 256;

  /// 该章的地图调色板组（16 组 × 16 色）。
  List<GbaPalette>? mapPalettes(int chapter) {
    final p = plistsOf(chapter);
    if (p == null) return null;
    final off = _plistEntry(_palPlistSlot, p.palette);
    if (off < 0) return null;
    final list = <GbaPalette>[];
    for (var g = 0; g < 16; g++) {
      final palette = GbaPalette();
      for (var i = 0; i < 16; i++) {
        final at = off + g * 32 + i * 2;
        if (at + 1 >= rom.length) break;
        final c = rom.data[at] | (rom.data[at + 1] << 8);
        final r = (c & 0x1F) << 3;
        final gg = ((c >> 5) & 0x1F) << 3;
        final b = ((c >> 10) & 0x1F) << 3;
        palette.argb[i] = 0xFF000000 | (r << 16) | (gg << 8) | b;
      }
      list.add(palette);
    }
    return list;
  }

  // ---------- 地形名 ----------

  final _terrainNames = <int, String>{};

  /// 地形名（如「平原」）。
  ///
  /// 地形名表是「地形 ID → 文本 id」，索引 0 是 `815b 815b`（“－－”，不可通行）。
  /// 文本表里存的是**指向字符串的指针**，所以要先解一次引用；
  /// 解不出时回退为 `地形 0xNN`，不返回空串、也不返回乱码。
  String terrainName(int terrainId) {
    final cached = _terrainNames[terrainId];
    if (cached != null) return cached;
    var result =
        '地形 0x${terrainId.toRadixString(16).toUpperCase().padLeft(2, '0')}';
    final base = _slotPointer(_terrainNameSlot);
    if (base >= 0) {
      final at = base + 4 * terrainId;
      final textPtr = rom.pointerAt(at);
      if (textPtr >= 0) {
        // 地形名是**明文双字节码**（如 815b = 「－」），不走 Huffman 解压
        final raw = <int>[];
        for (var i = 0; i < 16 && textPtr + i < rom.length; i++) {
          final b = rom.data[textPtr + i];
          if (b == 0) break;
          raw.add(b);
        }
        final text = _renderShortText(raw);
        if (text.isNotEmpty) result = text;
      }
    }
    _terrainNames[terrainId] = result;
    return result;
  }

  /// 把一段短文本（地形名）渲染成字串；乱码/过长一律回退空串。
  String _renderShortText(List<int> raw) {
    final sb = StringBuffer();
    var i = 0;
    while (i < raw.length && i < 16) {
      final b = raw[i];
      if (b == 0) break;
      if (b < 0x20) {
        i++;
        continue;
      }
      if (b < 0x80) {
        sb.writeCharCode(b);
        i++;
        continue;
      }
      if (i + 1 >= raw.length) break;
      final code = (b << 8) | raw[i + 1];
      final ch = rom.lookupChar(code);
      if (ch == null) return '';
      sb.write(ch);
      i += 2;
    }
    final text = sb.toString();
    // 地形名很短，超过 8 个字基本就是解错了
    if (text.length > 8) return '';
    return text;
  }

  /// 该章 config 里砖块条目数（= 最大合法砖块 ID + 1）。
  int chipCount(int chapter) {
    final cfg = configData(chapter);
    if (cfg == null) return 0;
    return cfg.length ~/ 8;
  }

  Uint8List? _cfgCache;
  int? _cfgCacheChapter;

  /// config（TSA）：每 8 字节描述一个砖块，是 4 个 u16 的 8×8 tile 索引。
  Uint8List? configData(int chapter) {
    if (_cfgCacheChapter == chapter) return _cfgCache;
    final p = plistsOf(chapter);
    if (p == null) return null;
    final off = _plistEntry(_cfgPlistSlot, p.config);
    if (off < 0) return null;
    final uz = Lz77.decompress(rom.data, off);
    _cfgCacheChapter = chapter;
    _cfgCache = uz;
    return uz;
  }

  // ---------- 渲染 ----------

  /// 把该章地图渲染成图像（宽 × 16，高 × 16 像素）。
  ///
  /// [tilesOverride] 用于「编辑后预览」：传入改动过的砖块数组即可。
  TileImage? renderMap(int chapter, {List<int>? tilesOverride}) {
    final map = chapterMap(chapter);
    if (map == null) return null;
    final indices = chipIndices(chapter);
    final cfg = configData(chapter);
    final palettes = mapPalettes(chapter);
    if (indices == null || cfg == null || palettes == null) return null;
    final tiles = tilesOverride ?? map.tiles;
    return renderTiles(indices, chipWidth, chipHeight, cfg, map.width,
        map.height, tiles, palettes);
  }

  /// 用指定 chipset 渲染砖块数组。
  ///
  /// [chipIndices] 是 chipset 的原始 4bit 调色板索引（每个字节一个像素），
  /// [palettes] 是 16 组调色板。TSA 条目的高 4 位选组，所以必须
  /// 「先查索引、再查组」——直接把 chipset 当成 RGB 图绘会串色。
  static TileImage renderTiles(
    Uint8List chipIndices,
    int chipWidth,
    int chipHeight,
    Uint8List config,
    int width,
    int height,
    List<int> tiles,
    List<GbaPalette> palettes,
  ) {
    final img = TileImage(width * 16, height * 16);
    // 先把整张图填成不透明底色。
    //
    // 下面遇到越界 tile / `0xFFFF` 象限时会 `continue`（不画）。若像素 alpha
    // 保持 0，这几格就会透出页面白底——看起来就是地图上若干「白点」。
    // 填成调色板 0 组索引 0 色（地图的底色）后，缺格呈现为底色而不是白块。
    final bg = palettes.isEmpty ? 0xFF000000 : palettes[0].color(0);
    for (var i = 0; i < img.pixels.length; i += 4) {
      img.pixels[i] = (bg >> 16) & 0xFF;
      img.pixels[i + 1] = (bg >> 8) & 0xFF;
      img.pixels[i + 2] = bg & 0xFF;
      img.pixels[i + 3] = 0xFF;
    }
    for (var ty = 0; ty < height; ty++) {
      for (var tx = 0; tx < width; tx++) {
        final index = ty * width + tx;
        if (index >= tiles.length) break;
        // 地图里存的是「以 8×8 tile 为单位」的偏移，每块 16×16 = 4 个 tile，
        // 所以 TSA 下标要除以 4。直接当下标用会越界（FE8 第 0 章有大到 3268 的值）。
        final tsaAt = (tiles[index] ~/ 4) * 8;
        if (tsaAt + 8 > config.length) continue;
        for (var q = 0; q < 4; q++) {
          final entry =
              config[tsaAt + q * 2] | (config[tsaAt + q * 2 + 1] << 8);
          if (entry == 0xFFFF) continue;
          final tileIndex = entry & 0x3FF;
          final hFlip = (entry >> 10) & 1;
          final vFlip = (entry >> 11) & 1;
          var group = (entry >> 12) & 0xF;
          if (group >= palettes.length) group = 0;
          final palette = palettes.isEmpty ? null : palettes[group];

          final srcX = (tileIndex % 32) * 8;
          final srcY = (tileIndex ~/ 32) * 8;
          if (srcX + 8 > chipWidth || srcY + 8 > chipHeight) continue;

          final dstX = tx * 16 + (q % 2) * 8;
          final dstY = ty * 16 + (q ~/ 2) * 8;
          for (var py = 0; py < 8; py++) {
            for (var px = 0; px < 8; px++) {
              final sx = srcX + (hFlip == 1 ? 7 - px : px);
              final sy = srcY + (vFlip == 1 ? 7 - py : py);
              final colorIndex = chipIndices[sy * chipWidth + sx];
              if (colorIndex == 0 && palette != null) {
                // 索引 0 视为透明；地图里用索引 0 表示“不绘制”
              }
              final di = ((dstY + py) * img.width + (dstX + px)) * 4;
              if (palette == null) {
                final v = colorIndex * 16;
                img.pixels[di] = v;
                img.pixels[di + 1] = v;
                img.pixels[di + 2] = v;
                img.pixels[di + 3] = 0xFF;
                continue;
              }
              final argb = palette.color(colorIndex);
              img.pixels[di] = (argb >> 16) & 0xFF;
              img.pixels[di + 1] = (argb >> 8) & 0xFF;
              img.pixels[di + 2] = argb & 0xFF;
              img.pixels[di + 3] = 0xFF;
            }
          }
        }
      }
    }
    return img;
  }
}

/// 4bpp 解码成「调色板索引」数组（每像素一个 0..15 字节）。
///
/// 地图 chipset 是 16 组 × 16 色的索引图，直接套单组调色板会串色，
/// 所以这里只取索引，分组与上色交给 `MapReader.renderTiles`。
Uint8List decode4bppIndices(Uint8List data, int width, int height) {
  final out = Uint8List(width * height);
  var x = 0;
  var y = 0;
  var i = 0;
  final end = width * height ~/ 2;
  while (y < height && i < end && i < data.length) {
    for (var y8 = 0; y8 < 8; y8++) {
      for (var x8 = 0; x8 < 8; x8 += 2) {
        if (i >= end || i >= data.length) return out;
        final b = data[i];
        final px = x + x8;
        final py = y + y8;
        if (px < width && py < height) out[py * width + px] = b & 0x0F;
        if (px + 1 < width && py < height) {
          out[py * width + px + 1] = (b >> 4) & 0x0F;
        }
        i++;
      }
    }
    x += 8;
    if (x >= width) {
      x = 0;
      y += 8;
    }
  }
  return out;
}

/// 一个章节引用的一组 plist 索引。
class PlistSet {
  final int obj;
  final int palette;
  final int config;
  final int map;
  final int anime1;
  final int anime2;
  final int change;
  final int event;

  const PlistSet({
    required this.obj,
    required this.palette,
    required this.config,
    required this.map,
    required this.anime1,
    required this.anime2,
    required this.change,
    required this.event,
  });
}
