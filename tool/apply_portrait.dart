// 把 AI 生成的 96×80 肖像替换到 GBA 火纹 ROM 的既有肖像条目。
//
// 用法：dart run tool/apply_portrait.dart <索引图.json> <rom.gba> <输出.gba> <肖像id>
//
// 核心原理：
//   - portrait sheet 是 256×40 的 4bpp tile 图（明文，非 LZ77）
//   - faceImage 从 sheet 的 6 个矩形区域读数据拼成 96×80 正脸
//   - 我们只修改这 6 个区域，其余数据（备用表情帧等）保持原样
//   - **原地写回**，不改变指针位置

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _portraitSlot = <String, int>{
  'FE6': 0x7FD8, 'FE7J': 0x69C0, 'FE7U': 0x6B30,
  'FE8J': 0x542C, 'FE8U': 0x5524,
};
const _classSlot = <String, int>{
  'FE6': 0x176E0, 'FE7J': 0x17CE0, 'FE7U': 0x178F0,
  'FE8J': 0x17860, 'FE8U': 0x17AB8,
};
const _portraitEntrySize = {'FE6': 16, 'FE7J': 28, 'FE7U': 28, 'FE8J': 28, 'FE8U': 28};

/// 解 4bpp 成索引图
List<List<int>> decode4bpp(Uint8List data, int width, int height) {
  final out = List.generate(height, (_) => List<int>.filled(width, 0));
  var i = 0, x = 0, y = 0;
  while (y < height && i + 1 <= data.length) {
    for (var y8 = 0; y8 < 8; y8++) {
      for (var x8 = 0; x8 < 8; x8 += 2) {
        if (i + 1 >= data.length) break;
        final b = data[i++];
        final px = x + x8, py = y + y8;
        if (px < width && py < height) out[py][px] = b & 0xF;
        if (px + 1 < width && py < height) out[py][px + 1] = (b >> 4) & 0xF;
      }
    }
    x += 8;
    if (x >= width) { x = 0; y += 8; }
  }
  return out;
}

/// 打包索引图为 4bpp
Uint8List pack4bpp(List<List<int>> idx, int width, int height) {
  final out = <int>[];
  for (var ty = 0; ty < height; ty += 8) {
    for (var tx = 0; tx < width; tx += 8) {
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x += 2) {
          final px = tx + x, py = ty + y;
          var lo = 0, hi = 0;
          if (py < height && px < width) lo = idx[py][px] & 0xF;
          if (py < height && px + 1 < width) hi = idx[py][px + 1] & 0xF;
          out.add(lo | (hi << 4));
        }
      }
    }
  }
  return Uint8List.fromList(out);
}

/// 读原 portrait 数据（明文或 LZ77）
Uint8List _readPortraitData(Uint8List rom, int ptr) {
  final off = ptr & 0x1FFFFFF;
  if (off + 4 > rom.length) return Uint8List(0);
  if (rom[off] == 0x10) {
    // LZ77 压缩
    final size = rom[off + 1] | (rom[off + 2] << 8) | (rom[off + 3] << 16);
    return _lz77Decompress(rom, off) ?? Uint8List(0);
  } else {
    // 明文：跳过 4 字节头
    return rom.sublist(off + 4, off + 4 + 256 * 40 ~/ 2);
  }
}

Uint8List? _lz77Decompress(Uint8List d, int off) {
  if (d[off] != 0x10) return null;
  final size = d[off + 1] | (d[off + 2] << 8) | (d[off + 3] << 16);
  final out = <int>[];
  var i = off + 4;
  while (out.length < size && i < d.length) {
    final flags = d[i++];
    for (var b = 0; b < 8 && out.length < size; b++) {
      if (flags & (1 << b) != 0) {
        if (i + 1 >= d.length) break;
        final b1 = d[i++], b2 = d[i++];
        final len = (b1 >> 4) + 3;
        final disp = (((b1 & 0xF) << 8) | b2) + 1;
        final start = out.length - disp;
        if (start < 0) break;
        for (var k = 0; k < len; k++) out.add(out[start + k]);
      } else {
        if (i >= d.length) break;
        out.add(d[i++]);
      }
    }
  }
  return Uint8List.fromList(out);
}

void main(List<String> args) {
  if (args.length < 4) {
    throw ArgumentError('用法: apply_portrait.dart <索引图.json> <rom.gba> <输出.gba> <肖像id>');
  }
  final json = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final rom = File(args[1]).readAsBytesSync();
  final outPath = args[2];
  final id = int.parse(args[3]);

  final w = json['width'] as int, h = json['height'] as int;
  if (w != 96 || h != 80) throw StateError('索引图必须是 96x80，当前 ${w}x$h');
  final faceIdx = (json['indices'] as List).map((r) => (r as List).cast<int>()).toList();
  final palRgb = (json['palette_rgb'] as List).map((c) => c as List).toList();
  // JSON 里若已带编码好的 BGR555（量化脚本产出的就是），直接用它，避免二次转换。
  final palRaw = (json['palette_bgr555'] as List?)?.cast<int>();

  // 检测版本
  String version = 'FE8J';
  for (final v in ['FE8J', 'FE8U', 'FE7J', 'FE7U', 'FE6']) {
    final cs = _classSlot[v]!;
    if (cs + 4 > rom.length) continue;
    final ptr = rom[cs] | (rom[cs + 1] << 8) | (rom[cs + 2] << 16) | (rom[cs + 3] << 24);
    if (ptr >= 0x08000000 && ptr < 0x0FFFFFFF) { version = v; break; }
  }
  print('ROM 版本: $version');

  final slot = _portraitSlot[version]!;
  final ptr = rom[slot] | (rom[slot + 1] << 8) | (rom[slot + 2] << 16) | (rom[slot + 3] << 24);
  final tableBase = ptr & 0x1FFFFFF;
  final entrySize = _portraitEntrySize[version]!;
  final entryAt = tableBase + id * entrySize;
  print('肖像表 @0x${tableBase.toRadixString(16)}，条目 $id @0x${entryAt.toRadixString(16)}');

  // 读原 portrait 数据
  final origPtr = rom[entryAt] | (rom[entryAt + 1] << 8) |
      (rom[entryAt + 2] << 16) | (rom[entryAt + 3] << 24);
  final origOff = origPtr & 0x1FFFFFF;
  final origData = _readPortraitData(rom, origPtr);
  print('原 portrait 数据 @0x${origOff.toRadixString(16)} (${origData.length} 字节)');

  // 解成 256x40 索引图
  final sheet = decode4bpp(origData, 256, 40);

  // faceImage 的 6 次 blit 对应关系（dst ← src）：
  //   A: face(16,0)..(79,31)  ← sheet(0,0)     64×32
  //   B: face(16,32)..(79,63) ← sheet(64,0)    64×32
  //   C: face(16,64)..(47,79) ← sheet(128,0)   32×16
  //   D: face(0,48)..(15,79)  ← sheet(160,0)   16×32
  //   E: face(48,64)..(79,79) ← sheet(128,16)  32×16
  //   F: face(80,48)..(95,79) ← sheet(176,0)   16×32
  void overlay(int dstX, int dstY, int w, int h, int srcX, int srcY) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final fx = dstX + x, fy = dstY + y;
        if (fx < 0 || fx >= 96 || fy < 0 || fy >= 80) continue;
        final sx = srcX + x, sy = srcY + y;
        if (sx < 0 || sx >= 256 || sy < 0 || sy >= 40) continue;
        sheet[sy][sx] = faceIdx[fy][fx];
      }
    }
  }
  overlay(16, 0,  64, 32, 0,   0);
  overlay(16, 32, 64, 32, 64,  0);
  overlay(16, 64, 32, 16, 128, 0);
  overlay(0,  48, 16, 32, 160, 0);
  overlay(48, 64, 32, 16, 128, 16);
  overlay(80, 48, 16, 32, 176, 0);
  print('已覆盖 6 块 face 区域');

  // 打包写回
  final packed = pack4bpp(sheet, 256, 40);
  
  // 检查格式：原版是明文还是 LZ77？
  final isLZ77 = rom[origOff] == 0x10;
  if (isLZ77) {
    // LZ77 压缩写回
    final compressed = _lz77Compress(packed);
    if (compressed.length > packed.length) {
      print('警告: 压缩后反而更大 (${packed.length}→${compressed.length})，改用明文');
      // 明文写回：4字节头 + 原始数据
      final header = Uint8List(4)..[0]=0x00..[1]=0x04..[2]=0x10..[3]=0x00;
      final newData = Uint8List(header.length + packed.length);
      newData.setRange(0, header.length, header);
      newData.setRange(header.length, newData.length, packed);
      rom.setRange(origOff, origOff + newData.length, newData);
    } else {
      rom.setRange(origOff, origOff + compressed.length, compressed);
    }
  } else {
    // 明文写回：4字节头 + 原始数据
    final header = Uint8List(4)..[0]=0x00..[1]=0x04..[2]=0x10..[3]=0x00;
    final newData = Uint8List(header.length + packed.length);
    newData.setRange(0, header.length, header);
    newData.setRange(header.length, newData.length, packed);
    rom.setRange(origOff, origOff + newData.length, newData);
  }
  print('已写回 portrait 数据（原地覆盖）');

  // 调色板：如果提供了新调色板，也原地写回
  if (palRgb.isNotEmpty) {
    final palPtr = rom[entryAt + 8] | (rom[entryAt + 9] << 8) |
        (rom[entryAt + 10] << 16) | (rom[entryAt + 11] << 24);
    final palOff = palPtr & 0x1FFFFFF;
    if (palOff + 32 <= rom.length) {
      for (var i = 0; i < 16; i++) {
        final int bgr;
        if (palRaw != null && i < palRaw.length) {
          bgr = palRaw[i] & 0x7FFF;
        } else {
          final c = i < palRgb.length ? (palRgb[i] as List).cast<int>() : [0, 0, 0];
          // GBA 15bit：bit0-4=R / bit5-9=G / bit10-14=B；取高 5 位（>>3）
          bgr = (c[0] >> 3) | ((c[1] >> 3) << 5) | ((c[2] >> 3) << 10);
        }
        rom[palOff + i * 2] = bgr & 0xFF;
        rom[palOff + i * 2 + 1] = (bgr >> 8) & 0xFF;
      }
      print('已更新调色板 @0x${palOff.toRadixString(16)}');
    }
  }

  File(outPath).writeAsBytesSync(rom);
  print('已写出 $outPath');
}

/// 简单 LZ77 压缩（与 FEBuilderGBA 兼容）
Uint8List _lz77Compress(Uint8List data) {
  final out = <int>[0x10];
  final size = data.length;
  out.addAll([size & 0xFF, (size >> 8) & 0xFF, (size >> 16) & 0xFF]);
  const window = 0x1000, maxMatch = 18, minMatch = 3;
  final head = <int, int>{};
  final prev = List<int>.filled(data.length, -1);
  int keyAt(int i) => data[i] | (data[i + 1] << 8) | (data[i + 2] << 16);
  void insert(int i) {
    if (i + 2 >= data.length) return;
    final k = keyAt(i);
    prev[i] = head[k] ?? -1;
    head[k] = i;
  }
  var i = 0;
  while (i < data.length) {
    final flagAt = out.length;
    out.add(0);
    var flags = 0;
    for (var bit = 0; bit < 8 && i < data.length; bit++) {
      var bestLen = 0, bestDist = 0;
      if (i + 2 < data.length) {
        var cand = head[keyAt(i)] ?? -1;
        var guard = 0;
        while (cand >= 0 && i - cand <= window && guard++ < 256) {
          var len = 0;
          while (len < maxMatch && i + len < data.length && data[cand + len] == data[i + len]) len++;
          if (len > bestLen) { bestLen = len; bestDist = i - cand; }
          cand = prev[cand];
        }
      }
      if (bestLen >= minMatch) {
        flags |= 1 << bit;
        final disp = bestDist - 1;
        out.add(((bestLen - minMatch) << 4) | ((disp >> 8) & 0xF));
        out.add(disp & 0xFF);
        for (var k = 0; k < bestLen; k++) insert(i + k);
        i += bestLen;
      } else {
        insert(i);
        out.add(data[i]);
        i++;
      }
    }
    out[flagAt] = flags;
  }
  return Uint8List.fromList(out);
}
