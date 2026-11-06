import 'dart:typed_data';

import 'editable_rom.dart';
import 'app_log.dart';
import 'fe_rom.dart';
import 'hex_view.dart';
import 'lz77_compress.dart';
import 'portrait.dart';
import 'portrait_import.dart';
import 'rom_info.dart' show UnitOffsets;

/// 肖像写回诊断日志（App 内「日志」页可看，方便手机端排查）。
void _diag(String msg) => AppLog.instance.log('info', '肖像: $msg');

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

/// 一次肖像导入的结果。
enum PortraitImportOutcome {
  /// 写入成功。
  ok,

  /// 目标 ROM 没有这条肖像。
  noTargetEntry,

  /// 找不到足够的连续空闲区。
  noSpace,

  /// 目标版本不支持写肖像。
  unsupported,
}

class PortraitImportWriteResult {
  final PortraitImportOutcome result;
  final String message;
  final int targetId;
  final int entryAddress;
  final int bytesWritten;
  final int freeSpaceOffset;

  /// 写回后**实际生效**的表情处理方式（可能与用户选的不同的情况：
  /// FE6 上没有嘴型指针，选「无嘴型」只能退回「固定」）。
  final PortraitFrameMode mouthMode;
  final PortraitFrameMode blinkMode;

  const PortraitImportWriteResult(
    this.result, {
    this.message = '',
    this.targetId = -1,
    this.entryAddress = -1,
    this.bytesWritten = 0,
    this.freeSpaceOffset = -1,
    this.mouthMode = PortraitFrameMode.real,
    this.blinkMode = PortraitFrameMode.real,
  });

  bool get ok => result == PortraitImportOutcome.ok;

  /// 用户选的效果没能完整实现时给出的说明（空串＝没有偏差）。
  String get frameNote {
    if (!ok) return '';
    final notes = <String>[];
    if (blinkMode == PortraitFrameMode.none) {
      notes.add('封印之剑没有眨眼帧，这一项不适用');
    }
    if (mouthMode == PortraitFrameMode.fixed) {
      notes.add('嘴型已固定（所有帧用同一块画面，游戏里嘴不动）');
    }
    return notes.join('；');
  }
}

/// [syncUnitFaces] 的单条变更记录。
class PortraitSyncChange {
  final int unitIndex;
  final String unitName;
  final int faceBefore;
  final int faceAfter;
  const PortraitSyncChange({
    required this.unitIndex,
    required this.unitName,
    required this.faceBefore,
    required this.faceAfter,
  });
}

/// [syncUnitFaces] 的汇总结果。
class PortraitSyncResult {
  final int changedCount;
  final List<PortraitSyncChange> changes;
  final String? error;
  const PortraitSyncResult(this.changedCount, this.changes, this.error);
  bool get ok => error == null;
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
        32; // 余量，避免紧贴已有数据；也包容对齐造成的碎片
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

    var cursor = region;
    final faceAt = cursor;
    target.writeBytes(cursor, faceBytes);
    cursor = _align4(cursor + faceBytes.length);

    var mouthAt = 0;
    if (mouthBytes.isNotEmpty) {
      mouthAt = cursor;
      target.writeBytes(cursor, mouthBytes);
      cursor = _align4(cursor + mouthBytes.length);
    }

    var mapAt = 0;
    if (mapBytes.isNotEmpty) {
      mapAt = cursor;
      target.writeBytes(cursor, mapBytes);
      cursor = _align4(cursor + mapBytes.length);
    }

    final palAt = cursor;
    target.writeBytes(palAt, palette);
    cursor = _align4(cursor + palette.length);

    // 表副本接在**实际写完后**的位置（对齐可能多推几个字节）
    final tableRegion = cursor;
    cursor += tableBytes + entrySize;

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
    cursor = _align4(cursor + faceBytes.length);

    var mouthAt = 0;
    if (mouthBytes.isNotEmpty) {
      mouthAt = cursor;
      target.writeBytes(cursor, mouthBytes);
      cursor = _align4(cursor + mouthBytes.length);
    }

    var mapAt = 0;
    if (mapBytes.isNotEmpty) {
      mapAt = cursor;
      target.writeBytes(cursor, mapBytes);
      cursor = _align4(cursor + mapBytes.length);
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
  ///
  /// FE6 的嘴型四帧在写回前已由 `PortraitImporter.withMouthFrames`
  /// 按新脸重铺，这里**不能再去清那片区域**——清了就等于把新嘴抹掉，
  /// 游戏只能拿索引 0（背景色）去贴嘴部。
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

  /// 用原条目的调色板索引 0 重建新调色板。
  ///
  /// FE6 把索引 0 当**不透明背景色**（罗伊是绿灰 #78a070），而正脸 6 块里
  /// 近一半像素是索引 0。导入时把索引 0 写成黑色 → 游戏里就是「黑底 +
  /// 人物」，看着就是花屏。所以必须沿用原条目的索引 0。
  ///
  /// **未用到的高位索引也必须填成这个背景色，不能留 0（黑）**：
  /// 导入图往往只用 2~6 色，剩下的索引全是 0 → 黑色。引擎会用这些索引
  /// 去画新脸没覆盖到的格子（下部、嘴型帧边角），于是一整片黑斑。
  Uint8List _paletteWithOriginalIndex0(Uint8List fresh, int usedColors) {
    final old = _originalPaletteIndex0;
    if (old == null) return fresh;
    final out = Uint8List.fromList(fresh);
    // 第 0 格恒用原条目的背景色
    if (out.length >= 2) {
      out[0] = old & 0xFF;
      out[1] = (old >> 8) & 0xFF;
    }
    // `usedColors` 之后的格子是补位（全是 0 = 黑）。只动这些，别碰真实用到的颜色。
    for (var i = usedColors; i < 16; i++) {
      final at = i * 2;
      if (at + 1 >= out.length) break;
      out[at] = old & 0xFF;
      out[at + 1] = (old >> 8) & 0xFF;
    }
    return out;
  }

  /// 原条目的调色板索引 0（BGR555 原始 16 位值）；无原条目时为 null。
  int? _originalPaletteIndex0;

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

  /// 把外部图片生成的肖像数据写入目标 ROM 的第 [targetId] 条肖像。
  ///
  /// 写入三块：**正脸、调色板、32×32 地图小头像**；嘴型与眨眼帧按
  /// [data] 自带的 [PortraitFrameMode] 处理（见 [PortraitImportResult.mouthMode]）。
  ///
  /// 为什么表情必须一起处理：嘴型图与眼睛帧跟正脸**共用同一套 16 色调色板**，
  /// 只换正脸会让旧嘴型/旧眼睛套上新颜色（串色）。
  /// 旧素材本体保留在原处不删（GBA ROM 没有真删除；留着便于回滚）。
  ///
  /// [fixedExpression] 是旧接口的单一开关，现已改为从 [data] 推导；
  /// 保留它只为不破坏老调用点：传 `false` 时强行用 [PortraitFrameMode.real]。
  PortraitImportWriteResult importFace(
    PortraitImportResult data,
    int targetId, {
    bool? fixedExpression,
    bool replaceMapFace = true,
  }) {
    final mouthMode = fixedExpression == false
        ? PortraitFrameMode.real
        : data.mouthMode;
    if (!writable) {
      return const PortraitImportWriteResult(PortraitImportOutcome.unsupported,
          message: '该版本没有可写入的肖像表');
    }
    final reader = PortraitReader(_live);
    final count = reader.entryCount;
    final table = reader.baseAddress;
    if (table < 0) {
      return const PortraitImportWriteResult(
          PortraitImportOutcome.noTargetEntry,
          message: '目标 ROM 的肖像表定位不到');
    }
    if (targetId < 0 || targetId >= count) {
      return PortraitImportWriteResult(PortraitImportOutcome.noTargetEntry,
          message: '目标 ROM 没有第 $targetId 条肖像（共 $count 条）');
    }
    // 原条目记录的 eyeX/eyeY 指出了这张脸的五官位置，用它给小头像取景
    final oldEntry = reader.entryAt(targetId);
    final originalPalette = reader.paletteBytes(targetId);
    if (originalPalette != null && originalPalette.length >= 2) {
      _originalPaletteIndex0 = originalPalette[0] | (originalPalette[1] << 8);
    }
    reader.dispose();

    // FE6 的嘴型帧画在正脸 sheet 里（x≥192 四格 + 帧 5 的两半），
    // 游戏按条目的 mouthX/mouthY 把其中一帧叠到脸上。换脸时不重画这四格，
    // 游戏就会把**旧角色的嘴**贴到新脸上——这正是「换完脸后嘴部开始花」的真因。
    var resolved = data;
    if (replaceMapFace && data.mapFaceIndices != null && oldEntry != null) {
      final anchor = PortraitMapAnchor.fromEntry(oldEntry);
      if (anchor.valid) {
        // 用原条目的眼睛位置重算小头像裁切（主脸数据不变）
        resolved = PortraitImporter.convertFromIndices(
          data,
          anchor: anchor,
        );
      }
    }
    // FE6 的嘴型帧画在正脸 sheet 里，游戏按条目的 mouthX/mouthY 叠到脸上。
    // 必须按**这条目标肖像**的坐标重铺，否则游戏会贴旧角色的嘴。
    // 只在 real 档重铺：fixed 档要的正是「同一块内容」；none 档在 FE6 上
    // 做不到（没有嘴型指针），退回 fixed 并在下方告知用户。
    if (_targetIsFe6) {
      resolved = PortraitImporter.withMouthFrames(
        resolved,
        mouthX: oldEntry?.mouthX,
        mouthY: oldEntry?.mouthY,
      );
    }
    _diag(
        '导入条目 #$targetId: 素材图=${data.sourceSheet ? '完整素材图(含帧排)' : '普通图片'} '
        '目标=${_targetIsFe6 ? 'FE6' : 'FE7/8'} 用色=${data.usedColors} '
        '硬凑=${data.hardMapped} 透明=${(data.transparentRatio * 100).toStringAsFixed(0)}% '
        '嘴型=${mouthMode.name} 眨眼=${resolved.blinkMode.name} '
        '嘴帧=${data.mouthIndices != null ? '有' : '无'}（眼帧随正脸 sheet 写入）'
        'mouthXY=(${oldEntry?.mouthX},${oldEntry?.mouthY}) eyeXY=(${oldEntry?.eyeX},${oldEntry?.eyeY})');
    final faceBytes = _encodeFace(resolved.faceIndices);
    final mapBytes = (replaceMapFace && resolved.mapFaceIndices != null)
        ? _encodeMapFaceIndices(resolved.mapFaceIndices!)
        : const <int>[];
    // FE7/FE8 的嘴型是独立 32×96：有数据就写（real / fixed 两档都会带数据），
    // 没有就置指针 0（＝真正没有嘴型）。眨眼帧在正脸 sheet 右侧，
    // 已随 faceIndices 一起写入，无需单独处理。
    final mouthBytes = (!_targetIsFe6 && resolved.mouthIndices != null)
        ? resolved.mouthIndices!.toList()
        : const <int>[];

    final need = faceBytes.length +
        resolved.paletteBytes.length +
        mapBytes.length +
        mouthBytes.length +
        32;
    final region = _findRegion(need);
    if (region < 0) {
      return PortraitImportWriteResult(PortraitImportOutcome.noSpace,
          message: '目标 ROM 找不到 $need 字节的连续空闲区');
    }

    var cursor = region;
    final faceAt = cursor;
    target.writeBytes(cursor, faceBytes);
    cursor = _align4(cursor + faceBytes.length);

    var mapAt = 0;
    if (mapBytes.isNotEmpty) {
      mapAt = cursor;
      target.writeBytes(cursor, mapBytes);
      cursor = _align4(cursor + mapBytes.length);
    }

    var mouthAt = 0;
    if (mouthBytes.isNotEmpty) {
      mouthAt = cursor;
      target.writeBytes(cursor, mouthBytes);
      cursor = _align4(cursor + mouthBytes.length);
    }

    final palAt = cursor;
    target.writeBytes(palAt,
        _paletteWithOriginalIndex0(resolved.paletteBytes, resolved.usedColors));
    cursor += resolved.paletteBytes.length;

    final entrySize = target.rom.table.portraitDataSize;
    final entryAt = table + targetId * entrySize;

    // 正脸与调色板换成新数据
    target.writeBytes(entryAt, _ptr(0x08000000 + faceAt));
    target.writeBytes(entryAt + 8, _ptr(0x08000000 + palAt));

    // 地图小头像：换新数据；没给新头像时保留原指针
    if (mapAt > 0) {
      target.writeBytes(entryAt + 4, _ptr(0x08000000 + mapAt));
    }

    if (_targetIsFe6) {
      // FE6 条目 16B：+12/+13 是嘴型定位（8 像素格），**保留原值不动**。
      // 嘴型四帧已在写回前按新脸重画（`withMouthFrames`），所以游戏
      // 叠上去的就是新脸的嘴部。改这两个字节反而会让引擎去 sheet 外取图。
      //
      // 这里也是「FE6 没有嘴型指针」的落点：用户想要「无嘴型」时做不到，
      // 只能做成「固定」（对齐原版伊冬那种做法），结果里会记下实际生效的档。
    } else if (mouthAt > 0) {
      // 有嘴型数据（real 是素材图的真帧，fixed 是同一块重复 6 次）：
      // 写入嘴型指针，说话时按帧播放。两者与正脸共用同一套调色板，不串色。
      target.writeBytes(entryAt + 12, _ptr(0x08000000 + mouthAt));
    } else {
      // FE7/FE8 条目 28B：+12 嘴型指针置 0 = 没有嘴型帧
      target.writeBytes(entryAt + 12, const [0, 0, 0, 0]);
      // 眼睛/嘴型坐标也推回合法小值：指针已空，理论上不会被读；
      // 但部分改版/引擎分支仍会拿这两个字节算偏移，0xFF 会越界。
      target.writeBytes(entryAt + 20, const [2, 6, 24, 24]);
    }

    final bytes = cursor - region;
    _diag('写入条目 #$targetId: 正脸 ${faceBytes.length}B@0x${faceAt.toRadixString(16)} '
        '调色板@0x${palAt.toRadixString(16)} '
        '${mapAt > 0 ? '小头像 ${mapBytes.length}B@0x${mapAt.toRadixString(16)} ' : ''}'
        '空位@0x${region.toRadixString(16)} 共 ${cursor - region}B');
    return PortraitImportWriteResult(
      PortraitImportOutcome.ok,
      targetId: targetId,
      entryAddress: entryAt,
      bytesWritten: bytes,
      freeSpaceOffset: region,
      mouthMode: _targetIsFe6
          // FE6 没有嘴型指针：无论用户选 real/fixed/none，
          // 实际效果都是「按条目的嘴部坐标贴同一块画面」。
          ? PortraitFrameMode.fixed
          : (mouthAt > 0 ? mouthMode : PortraitFrameMode.none),
      blinkMode: _targetIsFe6 ? PortraitFrameMode.none : resolved.blinkMode,
    );
  }

  /// 肖像导入后同步：找出所有 face 字段引用 [portraitId] 的单位，
  /// 将其 face 值更新为 [newPortraitId] 对应的 face 值。
  ///
  /// 用于「写错条目」时的补救：若用户本意是改 #22（琳）却误改了 #1，
  /// 可调用此方法把所有 face = portraitToFaceId(1) 的单位改为
  /// face = portraitToFaceId(22)。
  ///
  /// 返回更新了 N 个单位；[dryRun=true] 时只报告不写入。
  PortraitSyncResult syncUnitFaces(int portraitId, int newPortraitId, {bool dryRun = false}) {
    final rom = target.liveRom;
    final size = rom.table.unitDataSize;
    final base = rom.unitBase;
    if (base < 0 || size <= 0) {
      return PortraitSyncResult(0, const [], '无法获取单位表基址');
    }
    final oldFace = PortraitReader(rom).portraitToFaceId(portraitId);
    final newFace = PortraitReader(rom).portraitToFaceId(newPortraitId);
    if (oldFace < 0 || newFace < 0) {
      return PortraitSyncResult(0, const [], 'portraitId 换算失败');
    }
    final changes = <PortraitSyncChange>[];
    for (var i = 0; i < rom.unitCount; i++) {
      final addr = base + i * size + UnitOffsets.portraitId;
      if (addr + 2 > target.buffer.length) continue;
      final current = target.buffer.u16(addr);
      if (current != oldFace) continue;
      final name = rom.unitDisplayName(i).trim();
      if (!dryRun) {
        target.writeBytes(addr, [newFace & 0xFF, (newFace >> 8) & 0xFF]);
      }
      changes.add(PortraitSyncChange(unitIndex: i, unitName: name, faceBefore: current, faceAfter: newFace));
    }
    _diag('syncUnitFaces: $portraitId→$newPortraitId ($oldFace→$newFace)，匹配 ${changes.length} 个单位${dryRun ? '（dry_run）' : ''}');
    return PortraitSyncResult(changes.length, changes, null);
  }
  /// 32×32 小头像索引 → 目标格式字节（FE6 明文 512B；FE7/FE8 LZ77）。
  List<int> _encodeMapFaceIndices(Uint8List indices) {
    if (_targetIsFe6) {
      if (indices.length < 512) {
        final padded = Uint8List(512)..setRange(0, indices.length, indices);
        return padded.toList();
      }
      return indices.sublist(0, 512).toList();
    }
    return Lz77Compressor.compress(indices);
  }

  static List<int> _ptr(int v) =>
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

  /// 找一段放得下 [need] 字节的空闲区：优先最长 0xFF 块，其次 0x00 块。
  /// 与文本/地图写回同一策略，起点 4 字节对齐、偏移 < 32MB。
  int findRegion(int need) => _findRegion(need);

  /// 同 [_findRegion]，公开给「肖像导入」使用（同一套选址策略）。
  /// 把偏移对齐到 4 字节。
  ///
  /// GBA 的调色板是 16 位 BGR555，硬件按 halfword 读取；4bpp 图形同理。
  /// 写入地址落到奇数时，游戏会把每两个颜色错开一个字节读，
  /// 整张图变成彩色噪点；而 App 是自己按字节读的，两边不一致，
  /// 于是出现「App 里正常、游戏里花屏」。
  static int _align4(int v) => (v + 3) & ~3;

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
