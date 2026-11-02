import 'dart:typed_data';

import 'app_log.dart';
import 'editable_rom.dart';
import 'map_reader.dart';
import 'lz77_compress.dart';

/// 地图砖块写回的结果。
enum MapWriteMode {
  /// 与 ROM 里现有内容逐字节相同，未改动。
  identical,

  /// 已就地覆盖（压缩后不超原占用），指针不动。
  inPlace,

  /// 压缩后比原数据长，就地放不下 —— **拒绝写入**。
  ///
  /// 地图的 plist 索引会被多个章节共享（实测 FE8J 第 0 章与第 84 章共用同一个
  /// map 索引，FE6 有 14 组共享），所以**不能重定位**：改一个指针会连带
  /// 改掉所有共享它的章节。少改几格通常压缩后还能放下；实在放不下时
  /// 让用户知道原因，而不是悄悄改坏别的地图。
  tooLarge,

  /// 该章地图定位不到（表不可用 / plist 索引无效）。
  unavailable,
}

class MapWriteResult {
  final MapWriteMode mode;
  final String message;

  /// 新压缩流的字节数。
  final int newBytes;

  /// 原压缩流占用的字节数（就地写入的上限）。
  final int originalBytes;

  /// 地图数据块的文件偏移（写入位置）；未写入且定位失败时为 -1。
  final int dataOffset;

  MapWriteResult(
    this.mode, {
    this.message = '',
    this.newBytes = 0,
    this.originalBytes = 0,
    this.dataOffset = -1,
  });

  bool get ok =>
      mode == MapWriteMode.identical || mode == MapWriteMode.inPlace;
}

/// chipset（TSA 砖块图形）写回结果，语义与地图砖块一致。
enum ChipsetWriteMode { identical, inPlace, tooLarge, unavailable }

class ChipsetWriteResult {
  final ChipsetWriteMode mode;
  final String message;

  ChipsetWriteResult(this.mode, {this.message = ''});

  bool get ok =>
      mode == ChipsetWriteMode.identical || mode == ChipsetWriteMode.inPlace;
}

/// 地图砖块数据的写回。
///
/// 地图本体是 LZ77 压缩块：`w, h, 然后是 w*h 个 u16 砖块 ID`。
/// 改砖块 → 重新打包 → 压缩 → **就地覆盖**。
///
/// 之所以只做原地写入：地图的 plist 索引在多个章节之间共享（复用的战场），
/// 重指向会把所有共享章节一起改掉。压缩后放不下时按 [MapWriteMode.tooLarge]
/// 拒绝，由界面提示「少改几格」。
class MapWriter {
  final EditableRom edit;
  late final MapReader reader = MapReader(edit.rom);

  MapWriter(this.edit);

  /// 把 [chapter] 的砖块数组写回 ROM。
  ///
  /// [tiles] 长度必须等于该章的 `width * height`：宽高也写在同一条记录里，
  /// 改尺寸会连带影响章节设置表与事件坐标，不属于砖块编辑范围。
  /// 写入走 [EditableRom]，所以记录进 `edits`、可整体撤销。
  MapWriteResult write(int chapter, List<int> tiles) {
    final map = reader.chapterMap(chapter);
    if (map == null) {
      return MapWriteResult(MapWriteMode.unavailable,
          message: '该章地图定位不到');
    }
    if (tiles.length != map.width * map.height) {
      return MapWriteResult(MapWriteMode.unavailable,
          message: '砖块数不符：期望 ${map.width * map.height}，实际 ${tiles.length}');
    }

    final raw = _pack(map.width, map.height, tiles);
    final packed = Lz77Compressor.compress(raw);
    return _writeInPlace(chapter, map.dataOffset, packed);
  }

  /// 打包成解压后的原始字节（宽、高各 1 字节 + 每格 u16 小端）。
  static Uint8List _pack(int width, int height, List<int> tiles) {
    final raw = Uint8List(2 + tiles.length * 2);
    raw[0] = width;
    raw[1] = height;
    for (var i = 0; i < tiles.length; i++) {
      final v = tiles[i] & 0xFFFF;
      raw[2 + i * 2] = v & 0xFF;
      raw[2 + i * 2 + 1] = (v >> 8) & 0xFF;
    }
    return raw;
  }

  /// 改尺寸时的砖块重排：按行主序裁切/补 0。
  ///
  /// 旧 (ow×oh) 的砖块数组重排成新 (nw×nh)：落在新网格内的格子保留旧值，
  /// 超出旧范围的格子补 0（TSA 下标 0 = 该地图本来的第 0 块）。
  /// 旧网格多出的砖块直接丢弃——改小尺寸时这部分不再被引用。
  static List<int> remapTiles(List<int> oldTiles, int ow, int oh,
      int nw, int nh) {
    final out = List<int>.filled(nw * nh, 0);
    for (var y = 0; y < nh; y++) {
      for (var x = 0; x < nw; x++) {
        if (x < ow && y < oh) out[y * nw + x] = oldTiles[y * ow + x];
      }
    }
    return out;
  }

  /// 把该章地图**宽高**与砖块一起写回（与 [write] 同一套就地写入约束）。
  ///
  /// 宽高写在地图数据前两个字节里（游戏加载时现读，章节设置表没有副本），
  /// 改尺寸 = 重打包整条地图记录。[tiles] 长度必须等于 新宽×新高，
  /// 重排用 [remapTiles]。压缩后放不下时与 [write] 一样拒绝（tooLarge）；
  /// 且这张地图被其它章节共用时尺寸会一起变（调用方先用
  /// `MapReader.sharedChapters` 告知用户）。
  MapWriteResult writeSize(int chapter, int newWidth, int newHeight,
      List<int> tiles) {
    final map = reader.chapterMap(chapter);
    if (map == null) {
      return MapWriteResult(MapWriteMode.unavailable,
          message: '该章地图定位不到');
    }
    if (newWidth < 1 || newWidth > 64 || newHeight < 1 || newHeight > 64) {
      return MapWriteResult(MapWriteMode.unavailable,
          message: '宽高必须在 1..64 格（每格 16×16 像素）');
    }
    if (tiles.length != newWidth * newHeight) {
      return MapWriteResult(MapWriteMode.unavailable,
          message: '砖块数不符：期望 ${newWidth * newHeight}，'
              '实际 ${tiles.length}');
    }
    final raw = _pack(newWidth, newHeight, tiles);
    final packed = Lz77Compressor.compress(raw);
    return _writeInPlace(chapter, map.dataOffset, packed);
  }

  /// chipset（TSA 砖块图形）写回：把该章 chipset 的调色板索引数组
  /// 重新编成 4bpp 字节、逐 blob 重压、**就地覆盖**。
  ///
  /// [indices] 是全部 blob 按纵向拼接顺序的索引数组（像素顺序与
  /// `MapReader.chipIndices` 一致，每像素一个 0..15 字节）。
  /// chipset 的 plist 索引与地图一样跨章节共享，重压后变长就整批拒绝
  /// （tooLarge），绝不搬家。
  ChipsetWriteResult writeChipset(int chapter, List<int> indices) {
    final blobs = reader.chipsetBlobs(chapter);
    if (blobs.isEmpty) {
      return ChipsetWriteResult(ChipsetWriteMode.unavailable,
          message: '该章 chipset 图形定位不到（表不可用或解压长度非整块）');
    }
    final expected = blobs.fold(0, (a, b) => a + b.pixelCount);
    if (indices.length != expected) {
      return ChipsetWriteResult(ChipsetWriteMode.unavailable,
          message: '索引数不符：期望 $expected，实际 ${indices.length}');
    }

    // 内容与 ROM 里的一致 → 不写。
    // 不能靠「重压缩字节是否等于原流」判：原版压缩器的匹配选择与我们的
    // 不同，同内容重压出不同流（同长度）很常见，写一遍会白记一堆编辑。
    // 用 liveRom 读当前值（[reader] 是打开时的快照，用户改过的像素读不到）。
    final current = MapReader(edit.liveRom).chipIndices(chapter);
    if (current != null) {
      var same = true;
      for (var i = 0; i < expected; i++) {
        if (current[i] != (indices[i] & 0x0F)) {
          same = false;
          break;
        }
      }
      if (same) return ChipsetWriteResult(ChipsetWriteMode.identical);
    }

    // 先整批校验（任何 blob 放不下都整批拒绝，不写半个）
    final packedList = <Uint8List>[];
    final origLens = <int>[];
    var pos = 0;
    var identicalAll = true;
    for (final b in blobs) {
      final block = indices.sublist(pos, pos + b.pixelCount);
      pos += b.pixelCount;
      final packed = Lz77Compressor.compress(
          encode4bppIndices(block, b.tileRows));
      final origLen = compressedLengthOf(edit.buffer.data, b.offset);
      if (origLen <= 0) {
        return ChipsetWriteResult(ChipsetWriteMode.unavailable,
            message: 'chipset 不是有效的 LZ77 数据（plist #${b.plistIndex}）');
      }
      if (!_sameBytes(b.offset, origLen, packed)) identicalAll = false;
      if (packed.length > origLen) {
        AppLog.instance.log('warn',
            'chipset 写回 第$chapter章 被拒：plist #${b.plistIndex} $origLen→${packed.length}B 放不下（chipset 跨章节共享，不能搬家）');
        return ChipsetWriteResult(ChipsetWriteMode.tooLarge,
            message: '改动后图形变大（$origLen → ${packed.length} 字节），'
                '就地放不下。chipset 由多个章节共用，不能搬家；请减少改动后重试。');
      }
      packedList.add(packed);
      origLens.add(origLen);
    }

    if (identicalAll) {
      return ChipsetWriteResult(ChipsetWriteMode.identical);
    }
    for (var i = 0; i < blobs.length; i++) {
      edit.writeBytes(blobs[i].offset, packedList[i]);
      if (packedList[i].length < origLens[i]) {
        edit.writeBytes(blobs[i].offset + packedList[i].length,
            List<int>.filled(origLens[i] - packedList[i].length, 0));
      }
    }
    AppLog.instance.log('info',
        'chipset 写回 第$chapter章 ${blobs.length} 个 blob 原地覆盖');
    return ChipsetWriteResult(ChipsetWriteMode.inPlace);
  }

  /// 地图/尺寸写回共用的就地写入尾部：校验 → 拒绝/写入 → 尾部归零 → 结果。
  MapWriteResult _writeInPlace(int chapter, int offset, Uint8List packed) {
    final origLen = compressedLengthOf(edit.buffer.data, offset);

    if (origLen > 0 && _sameBytes(offset, origLen, packed)) {
      return MapWriteResult(MapWriteMode.identical,
          newBytes: packed.length, originalBytes: origLen, dataOffset: offset);
    }
    if (origLen <= 0) {
      return MapWriteResult(MapWriteMode.unavailable,
          message: '该章地图不是有效的 LZ77 数据',
          dataOffset: offset);
    }
    if (packed.length > origLen) {
      AppLog.instance.log('warn', '地图写回 第$chapter章 被拒：压缩后 $origLen→${packed.length}B 放不下（地图跨章节共享，不能搬家）');
      return MapWriteResult(MapWriteMode.tooLarge,
          message: '改动后数据变大（$origLen → ${packed.length} 字节），'
              '就地放不下。地图由多个章节共用，不能搬家；请少改几格后重试。',
          newBytes: packed.length,
          originalBytes: origLen,
          dataOffset: offset);
    }

    edit.writeBytes(offset, packed);
    if (packed.length < origLen) {
      // 尾部残留字节归零，避免被后续读取当成旧压缩流的一部分
      edit.writeBytes(
          offset + packed.length, List<int>.filled(origLen - packed.length, 0));
    }
    AppLog.instance.log('info', '地图写回 第$chapter章 原地 $origLen→${packed.length}B @0x${offset.toRadixString(16)}');
    return MapWriteResult(MapWriteMode.inPlace,
        newBytes: packed.length, originalBytes: origLen, dataOffset: offset);
  }

  bool _sameBytes(int offset, int length, Uint8List other) {
    if (length <= 0 || length != other.length) return false;
    final d = edit.buffer.data;
    if (offset + length > d.length) return false;
    for (var i = 0; i < length; i++) {
      if (d[offset + i] != other[i]) return false;
    }
    return true;
  }

  /// LZ77 压缩流在 [offset] 处**实际占用**的字节数（含 4 字节头）。
  ///
  /// `uncompressedSize` 给的是解压后长度，与压缩占用无关，
  /// 所以这里按标志位真实走一遍、直到产出够数。数据不合法返回 -1。
  static int compressedLengthOf(Uint8List d, int offset) {
    if (offset < 0 || offset + 4 > d.length) return -1;
    if (d[offset] != 0x10) return -1;
    final size = d[offset + 1] | (d[offset + 2] << 8) | (d[offset + 3] << 16);
    if (size <= 0) return -1;
    var written = 0;
    var i = offset + 4;
    while (written < size) {
      if (i >= d.length) return -1;
      final flags = d[i++];
      for (var bit = 0x80; bit > 0 && written < size; bit >>= 1) {
        if (i >= d.length) return -1;
        if ((flags & bit) == 0) {
          written++;
          i++;
        } else {
          if (i + 1 >= d.length) return -1;
          final first = d[i];
          i += 2;
          var amount = 3 + (first >> 4);
          if (written + amount > size) amount = size - written;
          written += amount;
        }
      }
    }
    return i - offset;
  }
}
