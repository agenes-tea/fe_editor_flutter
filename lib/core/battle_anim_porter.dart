import 'dart:typed_data';

import 'app_log.dart';
import 'battle_anim.dart';
import 'editable_rom.dart';
import 'fe_rom.dart';
import 'hex_view.dart';
import 'lz77_compress.dart';
import 'portrait.dart' show Lz77;

/// 战斗动画移植的结果。
enum AnimPortResult {
  ok,

  /// 源 ROM 的这条动画读不出可移植的数据。
  sourceEmpty,

  /// 目标 ROM 没有战斗动画表。
  unsupported,

  /// 目标条目 ID 无效（替换模式）。
  noSuchEntry,

  /// 目标 ROM 找不到足够的连续空闲区。
  noSpace,
}

class AnimPortOutcome {
  final AnimPortResult result;
  final String message;

  /// 写入后的条目索引（替换时为被替换的那个）。
  final int targetId;

  final int entryAddress;

  /// 复制过来的图形 sheet 数量与总字节数。
  final int sheets;
  final int bytesWritten;

  /// 新数据块写入的空闲区起始偏移；-1 表示未使用空闲区。
  final int freeSpaceOffset;

  const AnimPortOutcome(
    this.result, {
    this.message = '',
    this.targetId = -1,
    this.entryAddress = -1,
    this.sheets = 0,
    this.bytesWritten = 0,
    this.freeSpaceOffset = -1,
  });

  bool get ok => result == AnimPortResult.ok;
}

/// 战斗动画移植。
///
/// **不做逐帧编辑**（那会让代码与风险都爆炸），只做「整包搬运」：
/// 把一条动画需要的全部数据块原样复制到目标 ROM 的空闲区，
/// 再让目标条目指向这份副本。
///
/// 一条动画的完整数据 = 4 块 + N 张图形 sheet：
///
/// | 数据 | 说明 |
/// |---|---|
/// | `script` | LZ77，帧记录流（12 个模式的切分点由 `modes` 给出） |
/// | `modes` | 明文 12 个 u32，各模式在 script 解压数据里的起点 |
/// | `oam_r` / `oam_l` | LZ77，OAM 部件表（左右朝向各一份） |
/// | `palette` | LZ77，4 组 × 16 色 |
/// | 图形 sheet | 每个 `script` 帧带一个指针，LZ77，256×64，16 色 |
///
/// **脚本与 OAM 原样搬运、不重新生成**：FE6/7 与 FE8 的脚本指令集不同，
/// 但指令流本身是自洽的（帧记录 + 等待 + 结束标记），
/// 目标引擎照着自己那套解释器读就能跑——前提是两作的帧记录格式一致，
/// 这一点已在 `BattleAnimReader.framesOf` 的解析逻辑上验证过（三作用同一套解析）。
///
/// **图形 sheet 必须按**「目标里已存在的 sheet 指针」去重复用**：
/// 同一条动画的多个模式经常共用同一张 sheet，逐个复制会把体积放大好几倍。
class BattleAnimPorter {
  final EditableRom target;

  BattleAnimPorter(this.target);

  /// 目标 ROM 是否支持写战斗动画。
  bool get writable => target.rom.table.battleAnimPointerSlot > 0;

  /// 把 [source] 第 [sourceId] 条动画移植到目标。
  ///
  /// [replaceTargetId] 非 null 时替换目标已有的这一条；否则在表尾追加。
  AnimPortOutcome port(BattleAnimReader source, int sourceId,
      {int? replaceTargetId}) {
    if (!writable) {
      return AnimPortOutcome(AnimPortResult.unsupported,
          message: '该版本没有战斗动画表');
    }
    final entry = source.entry(sourceId);
    if (entry == null) {
      return AnimPortOutcome(AnimPortResult.sourceEmpty,
          message: '源 ROM 没有第 $sourceId 条动画');
    }

    // 1) 收集源端全部数据块（解压后的原始字节）
    final script = source.scriptData(entry);
    if (script == null || script.isEmpty) {
      return AnimPortOutcome(AnimPortResult.sourceEmpty,
          message: '源动画的脚本读不出来');
    }
    final modes = _modesBytes(source, entry);
    if (modes == null) {
      return AnimPortOutcome(AnimPortResult.sourceEmpty,
          message: '源动画的模式切分表读不出来');
    }
    final oamR = _block(source, entry.oamRightToLeft);
    final oamL = _block(source, entry.oamLeftToRight);
    final palette = _block(source, entry.palette);
    if (oamR == null || oamL == null || palette == null) {
      return AnimPortOutcome(AnimPortResult.sourceEmpty,
          message: '源动画的 OAM 或调色板读不出来');
    }

    // 2) 先把脚本里的 sheet 指针改写成"即将写入的新偏移"占位值之前，
    //    必须先知道自己会被写到哪 —— 所以这里先复制一份可改的脚本副本，
    //    等区域定下来后再回填（见第 6 步）。
    final scriptCopy = Uint8List.fromList(script);

    // 3) 收集用到的全部图形 sheet（按源偏移去重）
    final sheetSources = <int, Uint8List>{};
    for (final m in source.modesOf(entry)) {
      for (final f in source.framesOf(entry, m)) {
        final off = FeRom.toOffset(f.graphics);
        if (off <= 0 || sheetSources.containsKey(off)) continue;
        final uz = Lz77.decompress(source.rom.data, off);
        if (uz == null || uz.isEmpty) continue;
        sheetSources[off] = uz;
      }
    }

    // 3) 先校验目标表与槽位（必须在写任何字节之前做，
    //    否则「拒绝」也会把数据块写进空闲区，等于污染了 ROM）
    final reader = BattleAnimReader(target.liveRom);
    final tableBase = reader.base;
    if (tableBase <= 0) {
      return AnimPortOutcome(AnimPortResult.unsupported,
          message: '目标 ROM 的战斗动画表定位不到');
    }
    final count = reader.count;
    final entrySize = reader.entrySize;
    var slot = count;
    if (replaceTargetId != null) {
      if (replaceTargetId < 0 || replaceTargetId >= count) {
        return AnimPortOutcome(AnimPortResult.noSuchEntry,
            message: '目标 ROM 没有第 $replaceTargetId 条动画（共 $count 条）');
      }
      slot = replaceTargetId;
    } else if (tableBase + (count + 1) * entrySize > target.buffer.length) {
      return AnimPortOutcome(AnimPortResult.noSpace,
          message: '目标动画表后面放不下新条目');
    }

    // 4) 规划总占用（用未压缩的最坏情况找空闲区）
    final rawBlocks = <String, Uint8List>{
      'modes': modes,
      'oam_r': oamR,
      'oam_l': oamL,
      'palette': palette,
      for (final e in sheetSources.entries)
        'sheet@0x${e.key.toRadixString(16)}': e.value,
    };
    var need = 64;
    for (final e in rawBlocks.entries) {
      need += (e.key == 'modes' ? e.value.length : Lz77Compressor.compress(e.value).length) + 4;
    }
    need += Lz77Compressor.compress(scriptCopy).length + 64;
    final region = _findRegion(need);
    if (region < 0) {
      return AnimPortOutcome(AnimPortResult.noSpace,
          message: '目标 ROM 找不到 $need 字节的连续空闲区');
    }

    // 5) 排布 + 回填脚本里的 sheet 指针。
    //
    // 脚本是压缩块，**不能直接改压缩流里的字节**，只能：改解压态副本 →
    // 重新压缩 → 位置可能变化 → 再改再压，直到指针与最终位置一致。
    // 压缩长度随指针值微变，所以用「固定估算长度」排布 + 最多几轮收敛。
    // modes 是**明文** 48 字节（12 个 u32），不能压缩：压缩后表头会被当成
    // 数据读，12 个切分点全错（踩过：目标只解析出 2 个模式、帧数从 22 变 18）。
    final packed = <String, Uint8List>{
      for (final e in rawBlocks.entries)
        e.key: e.key == 'modes' ? e.value : Lz77Compressor.compress(e.value),
    };
    // 脚本按「和原脚本等长」预留，写完再按实际长度落位（不会超过预留）
    final scriptBudget = Lz77Compressor.compress(scriptCopy).length + 32;

    var scriptBytes = Lz77Compressor.compress(scriptCopy);
    var placed = <String, int>{};
    var cursor = region;
    // 脚本放最后，避免它长度变化影响其它块的位置
    for (final e in packed.entries) {
      placed[e.key] = cursor;
      cursor += e.value.length + ((4 - (e.value.length % 4)) % 4);
    }
    final scriptAt = cursor;

    // 迭代：按 settled 位置回填脚本指针，重压缩，直到脚本长度不再变化
    for (var round = 0; round < 4; round++) {
      final gba = <int, int>{};
      for (final srcOff in sheetSources.keys) {
        final at = placed['sheet@0x${srcOff.toRadixString(16)}'];
        if (at != null) gba[srcOff] = 0x08000000 + at;
      }
      _repointSheetsInBuffer(scriptCopy, gba);
      final next = Lz77Compressor.compress(scriptCopy);
      if (next.length == scriptBytes.length) {
        scriptBytes = next;
        break;
      }
      scriptBytes = next;
    }
    if (scriptAt + scriptBytes.length > region + need) {
      return AnimPortOutcome(AnimPortResult.noSpace,
          message: '脚本实际长度超出预留空间（${scriptBytes.length} > $scriptBudget）');
    }

    // 6) 真正写入
    cursor = region;
    for (final e in packed.entries) {
      final at = placed[e.key]!;
      target.writeBytes(at, e.value);
    }
    target.writeBytes(scriptAt, scriptBytes);
    placed['script'] = scriptAt;
    cursor = scriptAt + scriptBytes.length;
    if (need < cursor - region) need = cursor - region;

    // 7) 写表条目

    final entryAt = tableBase + slot * entrySize;
    // 缩写沿用源端的（12 字节 ASCII，不足补 0）
    final abbr = Uint8List(12);
    for (var i = 0; i < 12 && i < entry.abbr.length; i++) {
      abbr[i] = entry.abbr.codeUnitAt(i) & 0xFF;
    }
    target.writeBytes(entryAt, abbr);
    target.writeBytes(entryAt + 12, _u32(0x08000000 + placed['modes']!));
    target.writeBytes(entryAt + 16, _u32(0x08000000 + placed['script']!));
    target.writeBytes(
        entryAt + 20, _u32(0x08000000 + placed['oam_r']!));
    target.writeBytes(
        entryAt + 24, _u32(0x08000000 + placed['oam_l']!));
    target.writeBytes(
        entryAt + 28, _u32(0x08000000 + placed['palette']!));

    final bytes = cursor - region;
    AppLog.instance.log('info', '动画移植：第$slot条，搬 $bytes 字节到空位 0x${region.toRadixString(16)}（含 $sheetSources.length 张图形）');
    return AnimPortOutcome(
      AnimPortResult.ok,
      targetId: slot,
      entryAddress: entryAt,
      sheets: sheetSources.length,
      bytesWritten: bytes,
      freeSpaceOffset: region,
    );
  }

  /// 就地把**解压态**脚本副本里每个帧记录的 sheet 指针换成目标里的新位置。
  ///
  /// 帧记录格式与 `BattleAnimReader.framesOf` 一致：4 字节一条，
  /// `kind == 0x86`（帧记录）时后面紧跟 4 字节 graphics 指针 + 4 字节 oamOffset。
  /// 注意这里改的是解压态副本，改完还要重新压缩才能写进 ROM。
  void _repointSheetsInBuffer(Uint8List script, Map<int, int> gbaOf) {
    var i = 0;
    while (i + 4 <= script.length) {
      final kind = script[i + 3];
      if (kind == 0x86) {
        if (i + 12 > script.length) break;
        final old = FeRom.u32(script, i + 4);
        final newPtr = gbaOf[FeRom.toOffset(old)];
        if (newPtr != null) {
          final b = _u32(newPtr);
          for (var k = 0; k < 4; k++) {
            script[i + 4 + k] = b[k];
          }
        }
        i += 12;
        continue;
      }
      if (kind == 0x80) break;
      i += 4;
    }
  }

  /// 读模式切分表（明文 12 个 u32）。
  Uint8List? _modesBytes(BattleAnimReader source, BattleAnimEntry e) {
    final off = FeRom.isPointer(e.modes, source.rom.length)
        ? FeRom.toOffset(e.modes)
        : -1;
    if (off < 0 || off + 48 > source.rom.length) return null;
    return Uint8List.sublistView(source.rom.data, off, off + 48);
  }

  /// 读一块 LZ77 数据并解压；取不到返回 null。
  Uint8List? _block(BattleAnimReader source, int pointer) {
    if (!FeRom.isPointer(pointer, source.rom.length)) return null;
    return Lz77.decompress(source.rom.data, FeRom.toOffset(pointer));
  }

  List<int> _u32(int v) =>
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

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
