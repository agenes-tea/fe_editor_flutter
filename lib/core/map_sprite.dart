import 'dart:typed_data';

import 'fe_rom.dart';
import 'portrait.dart' show Lz77;
import 'tile_image.dart';

/// 站立地图小人的一条表项。
///
/// 结构来自 fireemblem8u 的 `include/unit_icon_data.h`（与真实 ROM 逐字节核对）：
/// ```c
/// typedef struct {
///     unsigned short pattern; // 未知，实测无用
///     unsigned short size;    // 0=16x16 1=16x32 2=32x32
///     char *sheet;            // 图形（LZ77 压缩）
/// } UnitIconWait;
/// ```
/// 8 字节一条，每职业一条（按职业表 `+06` 的 SMSId 索引）。
class MapSpriteEntry {
  final int id;
  final int pattern;
  final int sizeCode;
  final int sheetPointer;

  const MapSpriteEntry({
    required this.id,
    required this.pattern,
    required this.sizeCode,
    required this.sheetPointer,
  });

  /// 单帧尺寸（像素）。
  (int, int) get frameSize => switch (sizeCode) {
        0 => (16, 16),
        1 => (16, 32),
        2 => (32, 32),
        _ => (16, 16),
      };
}

/// 职业的「地图小人」（站立 sprite）读取与渲染。
///
/// **这是地图上那个跟着单位走的小人**，与肖像表里的 mapFace（32×32 头像）
/// 完全是两回事：它有自己的独立表（每职业一条）与 LZ77 图形。
///
/// 表地址是**代码里硬编码的立即数**（没有指针槽），所以只能按版本写死；
/// 改版若搬动了这张表则读不到，此时返回 null 由界面显示占位。
class MapSpriteReader {
  final FeRom rom;
  MapSpriteReader(this.rom);

  /// 各版本的站立表文件偏移（真实 ROM 扫描得到，条目数已与反编译表核对）。
  ///
  /// 判定方式：连续的「u16 pattern(0..8) + u16 size(0..2) + u32 指向 LZ77 图形」
  /// 8 字节条目。条目数：FE6 71 / FE7J 88 / FE7U 88 / FE8J 107，
  /// 与 fireemblem8u 的 `unit_icon_wait_table` 及各作表长一致。
  static const _tableByVersion = <String, int>{
    'FE6': 0x662C14,
    'FE7J': 0xD613B8,
    'FE7U': 0xC99700,
    'FE8J': 0x903E0C,
    'FE8U': 0x8AF880,
  };

  /// 各版本表应有的条目数（用于自动探测时挑「最接近真实长度」的候选）。
  static const _expectedCount = <String, int>{
    'FE6': 71,
    'FE7J': 88,
    'FE7U': 88,
    'FE8J': 107,
    'FE8U': 107,
  };

  /// 各版本的地图小人调色板（4 组 × 16 色：**自军 / 敌军 / 友军 / 行动后灰**）。
  ///
  /// 权威来源：反编译 `bmudisp.c` 的 `ApplyUnitSpritePalettes()`：
  /// `ApplyPalettes(gPal_MapSprite, 0x1C, 4)`，而 `gPal_MapSprite` 在
  /// `data/data_59E8E0.s` 里依次 `.incbin` 四个 32 字节文件：
  /// `unit_icon_pal_player` / `unit_icon_pal_enemy` / `unit_icon_pal_npc` /
  /// `unit_icon_pal_after_action`。与 `GetUnitSpritePalette()` 的
  /// 蓝→0xC、红→0xD、绿→0xE（依次对应前三组）完全吻合。
  ///
  /// **定位方式：拿 `unit_icon_pal_player.agbpal` 的 32 字节原文在 ROM 里搜**，
  /// 命中处 64 字节后必定紧跟 `unit_icon_pal_enemy`，即整块 128 字节。
  /// 这是内容匹配，不是结构猜谜——之前用「4 组色阶结构 + 字面池引用」定位
  /// 得到的 `0x19D06C` 是同一区域里的**图形调色板**（紫粉配色），
  /// 渲染出来颜色全错（v2.1.12～2.3.01 一直如此）。
  ///
  /// 实测地址（四作原版 + 改版均命中，同一版本内各 ROM 一致）：
  ///
  /// | 版本 | 调色板偏移 |
  /// |---|---|
  /// | FE6 | `0x100968` |
  /// | FE7J | `0x1900E8` |
  /// | FE7U | `0x194594` |
  /// | FE8J | `0x5C7340` |
  /// | FE8U | `0x59EE20`（「铠甲的呼唤」「黑暗护符」HoloEmblem 均在此） |
  ///
  /// 改版若搬走数据区，[palette] 会回退到内容扫描（[locatePalette]）。
  static const _paletteByVersion = <String, int>{
    'FE6': 0x100968,
    'FE7J': 0x1900E8,
    'FE7U': 0x194594,
    'FE8J': 0x5C7340,
    'FE8U': 0x59EE20,
  };

  /// FE8 美版布局的玩家调色板原始 32 字节（`unit_icon_pal_player.agbpal`）。
  /// 用于在改版 ROM 里按内容重新定位。
  static const _playerPalette = <int>[
    0x90, 0x42, 0x2B, 0x3D, 0xF2, 0x76, 0xBB, 0x7B, //
    0x8E, 0x31, 0x56, 0x2E, 0xFF, 0x6B, 0xE7, 0x48, //
    0x47, 0x71, 0x85, 0x7E, 0xC3, 0x7F, 0x5D, 0x0C, //
    0xFF, 0x23, 0x30, 0x3A, 0xFF, 0x7F, 0xE8, 0x1C, //
  ];

  /// 表基址：写死地址可用就用它，否则在 ROM 里按结构自动探测。
  ///
  /// 改版常把这张表搬到扩展区（「铠甲的呼唤」实测搬到 `0x106EA18`），
  /// 写死地址读到全 0 → 职业列表缩略图全空。
  late final int _tableBase = _resolveTableBase();

  int _resolveTableBase() {
    final fixed = _tableByVersion[rom.table.id];
    if (fixed != null && _runLength(fixed, limited: true) >= 8) return fixed;
    return _probeTableBase();
  }

  /// 从 [at] 起连续合法条目数（上限 512）。
  int _runLength(int at, {bool limited = false}) {
    var n = 0;
    while (_looksLikeEntry(at + n * 8)) {
      n++;
      if (n > 512) break;
    }
    return n;
  }

  /// 全 ROM 扫表：取连续合法条目最多、且长度最接近该版本预期值的那一段。
  ///
  /// 判据（`_looksLikeEntry`）= `pattern ≤ 8` + `size ≤ 2` + sheet 是有效指针 +
  /// sheet 指向的 LZ77 首字节为 0x10。单个条目极易误报，所以要求连续 ≥40 条。
  int _probeTableBase() {
    final expect = _expectedCount[rom.table.id] ?? 107;
    var best = -1;
    var bestScore = -1;
    for (var at = 0; at + 8 * 40 <= rom.length; at += 2) {
      if (!_looksLikeEntry(at)) continue;
      final n = _runLength(at);
      if (n < 40) continue;
      // 长度越接近预期值越好；明显超长（把后续数据也算进来）要扣分
      final score = n <= expect ? n : expect - (n - expect) * 2;
      if (score > bestScore) {
        bestScore = score;
        best = at;
      }
      at += n * 8; // 跳过已确认的整段，避免逐条重扫
    }
    return best;
  }

  bool get available {
    final b = _tableBase;
    return b > 0 && b + 8 <= rom.length;
  }

  /// 表条目数（遇到非法条目即停）。
  int get count => available ? _runLength(_tableBase) : 0;

  bool _looksLikeEntry(int at) {
    if (at + 8 > rom.length) return false;
    final pattern = _u16(at);
    final size = _u16(at + 2);
    final sheet = _u32(at + 4);
    if (pattern > 8 || size > 2) return false;
    if (!FeRom.isPointer(sheet, rom.length)) return false;
    final off = FeRom.toOffset(sheet);
    return off + 4 <= rom.length && rom.data[off] == 0x10;
  }

  MapSpriteEntry? entry(int index) {
    if (!available) return null;
    final at = _tableBase + index * 8;
    if (!_looksLikeEntry(at)) return null;
    return MapSpriteEntry(
      id: index,
      pattern: _u16(at),
      sizeCode: _u16(at + 2),
      sheetPointer: _u32(at + 4),
    );
  }

  /// 某职业的地图小人（按职业表 `+06` 的 SMSId 索引）。
  MapSpriteEntry? entryForClass(int classIndex) {
    final sms = classSmsId(classIndex);
    if (sms < 0) return null;
    return entry(sms);
  }

  /// 职业表 `+06` 的 SMSId（`ClassData::SMSId`，`GetClassSMSId()` 读它）。
  int classSmsId(int classIndex) {
    final base = rom.classBase;
    if (base < 0) return -1;
    final at = base + classIndex * rom.table.classDataSize;
    if (at + 7 > rom.length) return -1;
    return rom.data[at + 6];
  }

  int _u16(int a) =>
      a >= 0 && a + 2 <= rom.length ? rom.data[a] | (rom.data[a + 1] << 8) : 0;

  int _u32(int a) => FeRom.u32(rom.data, a);

  /// 调色板原始 16 色（第 [group] 组：0 自军 / 1 敌军 / 2 友军 / 3 行动后灰）。
  /// 当前版本无调色板地址、内容也不匹配时返回 null。
  GbaPalette? palette(int group) {
    final at = _paletteOffset();
    if (at < 0) return null;
    final o = at + group.clamp(0, 3) * 32;
    if (o + 32 > rom.length) return null;
    return GbaPalette.fromRom(rom.data, o);
  }

  /// 调色板起始偏移：先用写死的版本地址，不匹配再按内容全 ROM 搜。
  ///
  /// 内容判据是「玩家组 32 字节原文」，比任何结构启发式都硬：
  /// 配色选错的后果是整片错色（v2.1.12~2.3.01 的教训）。
  int _paletteOffset() {
    final fixed = _paletteByVersion[rom.table.id];
    if (fixed != null && _hasPlayerPalette(fixed)) return fixed;
    return locatePalette();
  }

  /// [at] 处的 32 字节是否就是玩家调色板原文。
  bool _hasPlayerPalette(int at) {
    if (at < 0 || at + 32 > rom.length) return false;
    for (var i = 0; i < 32; i++) {
      if (rom.data[at + i] != _playerPalette[i]) return false;
    }
    return true;
  }

  /// 在 ROM 里按内容搜玩家调色板，命中处即 4 组起点；找不到返回 -1。
  int locatePalette() {
    for (var at = 0; at + 32 <= rom.length; at++) {
      if (rom.data[at] != _playerPalette[0]) continue;
      if (_hasPlayerPalette(at)) return at;
    }
    return -1;
  }

  /// 该偏移处是否是地图小人调色板（按内容判定）。
  bool paletteLooksValid(int at) => _hasPlayerPalette(at);

  final _sheetCache = <int, Uint8List>{};
  final _frameCache = <int, TileImage>{};

  /// 解压后的完整图形数据（含多帧，按帧长切分）。
  Uint8List? _sheet(MapSpriteEntry e) {
    final off = FeRom.toOffset(e.sheetPointer);
    final cached = _sheetCache[off];
    if (cached != null) return cached;
    final uz = Lz77.decompress(rom.data, off);
    if (uz == null || uz.isEmpty) return null;
    if (_sheetCache.length > 32) _sheetCache.clear();
    return _sheetCache[off] = uz;
  }

  /// 该地图小人的帧数。图形长度 / 单帧长度即为帧数（实测多为 3 帧）。
  int frameCount(MapSpriteEntry? e) {
    if (e == null) return 0;
    final sheet = _sheet(e);
    if (sheet == null) return 0;
    final (w, h) = e.frameSize;
    final frameBytes = w * h ~/ 2;
    if (frameBytes <= 0) return 0;
    return sheet.length ~/ frameBytes;
  }

  /// 渲染第 [frame] 帧（[paletteGroup] 见 [palette]）。
  ///
  /// 单帧数据是标准的 GBA 4bpp tile 顺序，直接交给 [decode4bpp]
  /// （它已按「8×8 块内按行、块间换行」推进，与地图小人一致）。
  TileImage? frame(MapSpriteEntry? e, {int frame = 0, int paletteGroup = 0}) {
    if (e == null) return null;
    final sheet = _sheet(e);
    if (sheet == null) return null;
    final pal = palette(paletteGroup);
    if (pal == null) return null;
    final (w, h) = e.frameSize;
    final frameBytes = w * h ~/ 2;
    if (frameBytes <= 0) return null;
    final start = frame * frameBytes;
    if (start < 0 || start + frameBytes > sheet.length) return null;

    final key = e.sheetPointer * 64 + (frame & 7) * 4 + (paletteGroup & 3);
    final cached = _frameCache[key];
    if (cached != null) return cached;

    final slice = Uint8List.sublistView(sheet, start, start + frameBytes);
    final img = decode4bpp(slice, 0, w, h, pal);
    if (_frameCache.length > 96) _frameCache.clear();
    return _frameCache[key] = img;
  }

  /// 该地图小人当前是否可渲染（表项 + 图形 + 调色板都齐）。
  bool canRender(MapSpriteEntry? e) =>
      e != null && palette(0) != null && _sheet(e) != null;

  void dispose() {
    _sheetCache.clear();
    _frameCache.clear();
  }
}
