import 'dart:typed_data';

import 'editable_rom.dart';
import 'app_log.dart';
import 'fe_rom.dart';
import 'hex_view.dart';
import 'lz77_compress.dart';
import 'portrait.dart';

/// 一次肖像移植的结果。
enum PortraitPortResult {
  /// 新条目已写入目标 ROM。
  ok,

  /// 源 ROM 这张肖像没有图（空条目 / 解码失败）。
  sourceEmpty,

  /// 目标 ROM 的肖像表定位不到，或表尾没有可用槽位。
  noTargetEntry,

  /// 目标 ROM 找不到足够的连续空闲区。
  noSpace,

  /// 目标版本不支持写肖像。
  unsupported,
}

class PortraitPortOutcome {
  final PortraitPortResult result;
  final String message;

  /// 新条目在目标肖像表里的索引。
  final int targetId;

  /// 新条目地址。
  final int entryAddress;

  final int bytesWritten;

  /// 新数据块写入的空闲区起始偏移；-1 表示未使用空闲区。
  final int freeSpaceOffset;

  const PortraitPortOutcome(
    this.result, {
    this.message = '',
    this.targetId = -1,
    this.entryAddress = -1,
    this.bytesWritten = 0,
    this.freeSpaceOffset = -1,
  });

  bool get ok => result == PortraitPortResult.ok;
}

/// 跨版本肖像移植。
///
/// **不能直接搬压缩块**——三作的数据格式不同（实测封印之剑与圣魔之光石）：
///
/// | 数据 | FE6 | FE7 / FE8 |
/// |---|---|---|
/// | 正脸 | LZ77，解压 256×34（4352 B） | 明文，`00 04 10 00` 头 + 256×40（5120 B） |
/// | 嘴型 | 无独立数据（四帧画在正脸右侧） | 明文 32×96（6 帧） |
/// | 地图头像 | **明文** 32×32 | **LZ77** 32×32 |
/// | 调色板 | 16 色 BGR555，32 B | 同 |
///
/// 所以移植路径是：**取源的 4bpp 调色板索引 → 按目标格式重新打包 → 写目标空闲区**。
/// 索引原样搬运、调色板整块复制，所以换版本不会掉色（像素值就是索引，
/// 不存在「颜色语义」差异）。
///
/// 已知取舍：FE7/FE8 → FE6 时嘴型数据无处安放（FE6 的嘴型在正脸 sheet 右侧，
/// 由 `mouthX/mouthY` 定位），移植过去的脸完整但没有嘴型动画；
/// FE6 → FE7/FE8 同理没有嘴型数据，`mouth` 指针置 0。
class PortraitPorter {
  final EditableRom target;

  PortraitPorter(this.target);

  FeRom get _live => target.liveRom;

  /// 目标版本是不是 FE6。
  ///
  /// 用**打开时的表快照**判断，不用实时视图：写完之后表被搬到新位置，
  /// 重新探测的 `baseAddress` 与条目规模都不该影响「这份 ROM 是哪一作」。
  bool get _targetIsFe6 => target.rom.table.portraitDataSize == 16;

  /// 目标版本是否可写。
  bool get writable =>
      target.rom.table.portraitPointerSlot > 0 &&
      target.rom.table.portraitDataSize > 0;

  /// 把 [source] 第 [sourceId] 张肖像移植进目标 ROM。
  ///
  /// [replaceTargetId] 非 null 时**替换**目标 ROM 已有的这一条肖像（就地改写它的
  /// 四个指针），而不是追加新条目。社区改版的主流做法是「替换旧职业/旧角色」，
  /// 因为新增条目要动整张表、还可能撞上存档位宽限制（见第 26 节）。
  PortraitPortOutcome port(PortraitReader source, int sourceId,
      {int? replaceTargetId}) {
    if (!writable) {
      return const PortraitPortOutcome(PortraitPortResult.unsupported,
          message: '该版本没有可写入的肖像表');
    }

    final srcEntry = source.entryAt(sourceId);
    final face = source.faceIndices(sourceId);
    final palette = source.paletteBytes(sourceId);
    if (srcEntry == null || face == null || palette == null) {
      return const PortraitPortOutcome(PortraitPortResult.sourceEmpty,
          message: '源 ROM 这张肖像没有可用的图像数据');
    }

    final faceBytes = _encodeFace(face);
    final mouthBytes = _encodeMouth(source, sourceId);
    final mapBytes = _encodeMapFace(source, sourceId);

    final table = PortraitReader(_live).baseAddress;
    if (table < 0) {
      return const PortraitPortOutcome(PortraitPortResult.noTargetEntry,
          message: '目标 ROM 的肖像表定位不到');
    }
    final count = PortraitReader(_live).entryCount;
    final entrySize = target.rom.table.portraitDataSize;

    if (replaceTargetId != null) {
      return _replace(replaceTargetId, count, table, entrySize, faceBytes,
          mouthBytes, mapBytes, palette, srcEntry);
    }

    // 表尾紧跟别的数据（实测三作都如此），表内也没有可用空槽
    // （唯一的全 NULL 条目是 ID 0，那个位置有语义，不能占）。
    // 所以把**整张表**复制到空闲区、新条目接在副本后面，再改指针槽指向新表。
    final tableBytes = count * entrySize;
    final dataBytes = faceBytes.length +
        mouthBytes.length +
        mapBytes.length +
        palette.length +
        32; // 余量，避免紧贴已有数据
    final slot = count;

    // 数据与副本表一起规划在一块连续区域里，顺序：数据 → 表副本。
    // 分开各找一块空地会重叠——踩过：两次 _findRegion 都返回同一片 0xFF 区，
    // 结果表副本被肖像数据覆盖，指针槽指过去读到的是像素。
    final need = dataBytes + tableBytes + entrySize + 32;
    final region = _findRegion(need);
    if (region < 0) {
      return PortraitPortOutcome(PortraitPortResult.noSpace,
          message: '目标 ROM 找不到 $need 字节的连续空闲区');
    }
    final tableRegion = region + dataBytes;

    var cursor = region;
    final faceAt = cursor;
    target.writeBytes(cursor, faceBytes);
    cursor += faceBytes.length;

    var mouthAt = 0;
    if (mouthBytes.isNotEmpty) {
      mouthAt = cursor;
      target.writeBytes(cursor, mouthBytes);
      cursor += mouthBytes.length;
    }

    var mapAt = 0;
    if (mapBytes.isNotEmpty) {
      mapAt = cursor;
      target.writeBytes(cursor, mapBytes);
      cursor += mapBytes.length;
    }

    final palAt = cursor;
    target.writeBytes(palAt, palette);
    cursor += palette.length;

    // 复制整张旧表到新位置（内容逐字节保留），新条目接在其后全 0 处
    final d = target.buffer.data;
    final oldTable = Uint8List.fromList(
        d.sublist(table, table + tableBytes));
    target.writeBytes(tableRegion, oldTable);
    final entryAt = tableRegion + slot * entrySize;
    _writeEntry(entryAt, faceAt, mouthAt, mapAt, palAt, srcEntry);

    // 指针槽改指新表：全项目只有 portrait_pointer 这一个入口引用肖像表
    final slotAddr = target.rom.table.portraitPointerSlot;
    final oldPtr = FeRom.u32(target.buffer.data, slotAddr);
    if (!target.writePointer(slotAddr, tableRegion)) {
      return const PortraitPortOutcome(PortraitPortResult.noTargetEntry,
          message: '无法把肖像表指针改指到新位置');
    }

    final newPtr = 0x08000000 + tableRegion;
    AppLog.instance.log('info', '肖像移植：新条目 #$slot，写 ${cursor - region}B 到空位 0x${region.toRadixString(16)}，'
        '肖像表指针 0x${oldPtr.toRadixString(16)}→0x${newPtr.toRadixString(16)}');
    return PortraitPortOutcome(
      PortraitPortResult.ok,
      targetId: slot,
      entryAddress: entryAt,
      bytesWritten: cursor - region,
      freeSpaceOffset: region,
    );
  }

  /// 替换目标 ROM 第 [targetId] 条肖像的四块数据。
  ///
  /// 只改这一条条目的指针，**不动表本身**——所以不会影响其它任何肖像，
  /// 也不需要搬表。这是风险最低的移植方式。
  ///
  /// 原数据本体保留在原处不删（GBA ROM 没有真正的删除；留着既省事也更安全，
  /// 因为可能有别的地方（如职业卡、halfbody）意外引用了同一块）。
  PortraitPortOutcome _replace(
    int targetId,
    int count,
    int table,
    int entrySize,
    List<int> faceBytes,
    List<int> mouthBytes,
    List<int> mapBytes,
    Uint8List palette,
    PortraitEntry srcEntry,
  ) {
    if (targetId < 0 || targetId >= count) {
      return PortraitPortOutcome(PortraitPortResult.noTargetEntry,
          message: '目标 ROM 没有第 $targetId 条肖像（共 $count 条）');
    }

    final need = faceBytes.length +
        mouthBytes.length +
        mapBytes.length +
        palette.length +
        32;
    final region = _findRegion(need);
    if (region < 0) {
      return PortraitPortOutcome(PortraitPortResult.noSpace,
          message: '目标 ROM 找不到 $need 字节的连续空闲区');
    }

    var cursor = region;
    final faceAt = cursor;
    target.writeBytes(cursor, faceBytes);
    cursor += faceBytes.length;

    var mouthAt = 0;
    if (mouthBytes.isNotEmpty) {
      mouthAt = cursor;
      target.writeBytes(cursor, mouthBytes);
      cursor += mouthBytes.length;
    }

    var mapAt = 0;
    if (mapBytes.isNotEmpty) {
      mapAt = cursor;
      target.writeBytes(cursor, mapBytes);
      cursor += mapBytes.length;
    }

    final palAt = cursor;
    target.writeBytes(palAt, palette);
    cursor += palette.length;

    final entryAt = table + targetId * entrySize;
    _writeEntry(entryAt, faceAt, mouthAt, mapAt, palAt, srcEntry);

    final bytes = cursor - region;
    AppLog.instance.log('info', '肖像移植：替换条目 #$targetId，新数据写 $bytes 字节到空位 0x${region.toRadixString(16)}');
    return PortraitPortOutcome(
      PortraitPortResult.ok,
      targetId: targetId,
      entryAddress: entryAt,
      bytesWritten: bytes,
      freeSpaceOffset: region,
    );
  }

  /// 目标 FE6 → LZ77；目标 FE7/FE8 → `00 04 10 00` + 明文 256×40。
  ///
  /// 源 FE6 的 sheet 只有 34 行，目标需要 40 行：多出的 6 行补 0
  /// （对应「脸下方」与「右侧备用眼型」区域，原版这些位置本来就大量为 0）。
  List<int> _encodeFace(Uint8List faceIndices) {
    const rowBytes = 128; // 256 / 2
    if (_targetIsFe6) {
      const need = rowBytes * 34;
      final data = Uint8List(need);
      final copy = faceIndices.length < need ? faceIndices.length : need;
      data.setRange(0, copy, faceIndices);
      return Lz77Compressor.compress(data);
    }
    final need = rowBytes * 40;
    final data = Uint8List(need);
    final copy = faceIndices.length < need ? faceIndices.length : need;
    data.setRange(0, copy, faceIndices);
    return [0x00, 0x04, 0x10, 0x00, ...data];
  }

  /// 嘴型：源 FE6 没有独立数据 → 空；源 FE7/FE8 原样搬运 32×96 索引。
  List<int> _encodeMouth(PortraitReader source, int id) {
    final mouth = source.mouthIndices(id);
    if (mouth == null) return const [];
    // 目标 FE6 没有嘴型字段，写了也没人引用——直接不写，省空间
    if (_targetIsFe6) return const [];
    return mouth.toList();
  }

  /// 地图头像：目标 FE6 明文；FE7/FE8 LZ77。
  List<int> _encodeMapFace(PortraitReader source, int id) {
    final map = source.mapFaceIndices(id);
    if (map == null) return const [];
    if (_targetIsFe6) return map.toList();
    return Lz77Compressor.compress(map);
  }

  void _writeEntry(int at, int face, int mouth, int map, int pal,
      PortraitEntry src) {
    List<int> ptr(int offset) {
      final v = offset > 0 ? 0x08000000 + offset : 0;
      return [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
    }

    target.writeBytes(at, ptr(face));
    target.writeBytes(at + 4, ptr(map));
    target.writeBytes(at + 8, ptr(pal));
    if (_targetIsFe6) {
      // FE6 条目 16 字节：+12/+13 是嘴型坐标，+14/+15 保留
      target.writeBytes(at + 12, [src.mouthX, src.mouthY, 0, 0]);
      return;
    }
    target.writeBytes(at + 12, ptr(mouth));
    // +16 是职业卡（本工具不移植，置 0）
    target.writeBytes(at + 16, const [0, 0, 0, 0]);
    target.writeBytes(at + 20, [
      src.mouthX,
      src.mouthY,
      src.eyeX,
      src.eyeY,
      src.state,
      0,
      src.mugExceed,
      0,
    ]);
  }

  /// 找一段放得下 [need] 字节的空闲区：优先最长 0xFF 块，其次 0x00 块。
  /// 与文本/地图写回同一策略，起点 4 字节对齐、偏移 < 32MB。
  int _findRegion(int need) {
    const limit = 0x02000000;
    final view = HexView(target.buffer);

    int bestRun(int fill) {
      var from = 0;
      var bestOff = -1;
      var bestLen = 0;
      while (from < target.buffer.length && from < limit) {
        final run = view.findFreeRun(from, fill: fill, minLength: need);
        if (run == null) break;
        final aligned = run.offset + ((4 - (run.offset % 4)) % 4);
        if (aligned + need <= run.offset + run.length && run.length > bestLen) {
          bestLen = run.length;
          bestOff = aligned;
        }
        from = run.offset + run.length;
      }
      return bestOff;
    }

    final ff = bestRun(0xFF);
    if (ff >= 0) return ff;
    return bestRun(0x00);
  }
}
