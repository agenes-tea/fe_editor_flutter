// 把 Python 侧量化好的 4bpp 索引图打包成 GBA 火纹的地图小人（map sprite），
// 写进 ROM 空位，并把目标职业的 SMS 表项指过去。
//
// **刻意只依赖 dart:io / dart:typed_data**：项目的 core 层里 tile_image.dart
// 引了 dart:ui（Flutter），一旦 import 就只能靠 flutter test 跑，
// 而 flutter test 里调 exit()/长任务容易把测试进程搞崩。工具链保持纯 Dart
// 才能 `dart run` 直接跑。LZ77 压缩这里本地实现（与 lz77_compress.dart 同算法）。
//
// 用法：
//   dart run tool/apply_map_sprite.dart <索引图.json> <rom.gba> <输出.gba> <职业索引>

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ---------- 版本相关的表地址（与 lib/core/map_sprite.dart 保持一致）----------
const _tableByVersion = <String, int>{
  'FE6': 0x662C14,
  'FE7J': 0xD613B8,
  'FE7U': 0xC99700,
  'FE8J': 0x903E0C,
  'FE8U': 0x8AF880,
};

// 职业表指针槽（与 lib/core/rom_info.dart 的 classPointerSlot 一致）
const _classPointerSlot = <String, int>{
  'FE6': 0x176E0,
  'FE7J': 0x17CE0,
  'FE7U': 0x178F0,
  'FE8J': 0x17860,
  'FE8U': 0x17AB8,
};

/// 4bpp 索引 → GBA tile 顺序字节。
///
/// **最容易写错的一步**：不是按行连续，而是每 8×8 一个 tile、tile 内按行、
/// 行内低半字节在左。按行打包会得到整张错位的图。
Uint8List pack4bpp(List<List<int>> indices, int width, int height) {
  final out = <int>[];
  // **顺序必须与 decode4bpp 完全一致**：先横向铺满一行 8×8 tile，再换下一行。
  // 反过来（按 tile 块纵向堆叠）会让整张图错位——踩过，渲染出来是噪点。
  for (var ty = 0; ty < height; ty += 8) {
    for (var tx = 0; tx < width; tx += 8) {
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x += 2) {
          final px = tx + x;
          final py = ty + y;
          var lo = 0, hi = 0;
          if (py < height && px < width) lo = indices[py][px] & 0xF;
          if (py < height && px + 1 < width) hi = indices[py][px + 1] & 0xF;
          out.add(lo | (hi << 4));
        }
      }
    }
  }
  return Uint8List.fromList(out);
}

// ---------- LZ77（GBA BIOS 格式，与项目 lz77_compress.dart 同算法）----------
Uint8List lz77(Uint8List data) {
  final out = <int>[0x10];
  final size = data.length;
  out.add(size & 0xFF);
  out.add((size >> 8) & 0xFF);
  out.add((size >> 16) & 0xFF);

  const window = 0x1000;
  const maxMatch = 18;
  const minMatch = 3;

  // 哈希链索引：以 3 字节为键记录出现位置，避免 O(n^2) 全扫（512 字节也会卡住）
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
      var bestLen = 0;
      var bestDist = 0;
      if (i + 2 < data.length) {
        var cand = head[keyAt(i)] ?? -1;
        var guard = 0;
        while (cand >= 0 && i - cand <= window && guard++ < 256) {
          var len = 0;
          while (len < maxMatch &&
              i + len < data.length &&
              data[cand + len] == data[i + len]) {
            len++;
          }
          if (len > bestLen) {
            bestLen = len;
            bestDist = i - cand;
          }
          cand = prev[cand];
        }
      }
      if (bestLen >= minMatch) {
        flags |= 1 << bit;
        final disp = bestDist - 1;
        out.add(((bestLen - minMatch) << 4) | ((disp >> 8) & 0xF));
        out.add(disp & 0xFF);
        for (var k = 0; k < bestLen; k++) {
          insert(i + k);
        }
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

/// 把我们量化出的 16 色映射到游戏**现有的**自军调色板上。
///
/// 为什么必须这么做：地图小人的调色板是**全局 4 组**（自军/敌军/友军/行动后灰），
/// 被所有单位共用。直接覆盖会让全军换色——不可接受。
/// 所以反过来：把我们的每个颜色替换成游戏调色板里最接近的那个，
/// 图形索引跟着改。代价是颜色会偏（16 色硬凑 16 色），但角色能认出、
/// 且不会影响其他任何单位。
({List<List<int>> indices, double avgError}) remapToGamePalette(
  List<List<int>> rows,
  List<int> myPalBgr,
  List<int> gamePalBgr,
) {
  int r(int c) => (c & 0x1F) << 3;
  int g(int c) => ((c >> 5) & 0x1F) << 3;
  int b(int c) => ((c >> 10) & 0x1F) << 3;
  double dist(int a, int bb) {
    final dr = r(a) - r(bb), dg = g(a) - g(bb), db = b(a) - b(bb);
    return (dr * dr + dg * dg + db * db) / 3;
  }

  // 索引 0 是透明，两边都跳过
  final map = <int, int>{0: 0};
  var totalErr = 0.0;
  var n = 0;
  for (var mi = 1; mi < myPalBgr.length; mi++) {
    var best = 1;
    var bestD = double.infinity;
    for (var gi = 1; gi < 16; gi++) {
      final d = dist(myPalBgr[mi], gamePalBgr[gi]);
      if (d < bestD) {
        bestD = d;
        best = gi;
      }
    }
    map[mi] = best;
    totalErr += bestD;
    n++;
  }
  final out = [
    for (final row in rows) [for (final v in row) map[v] ?? 0]
  ];
  return (indices: out, avgError: n == 0 ? 0 : totalErr / n);
}

// ---------- 入口 ----------
void main(List<String> args) {
  if (args.length < 4) {
    throw ArgumentError(
        '用法: apply_map_sprite.dart <索引图.json> <rom.gba> <输出.gba> <职业索引>');
  }
  final json = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final romPath = args[1];
  final outPath = args[2];
  final classIndex = int.parse(args[3]);

  final w = json['width'] as int;
  final h = json['height'] as int;
  final rows = (json['indices'] as List).map((r) => (r as List).cast<int>()).toList();
  final palBgr = (json['palette_bgr555'] as List).cast<int>();

  final rom = File(romPath).readAsBytesSync();
  final version = _detectVersion(rom);
  print('ROM 版本: $version');
  final tableBase = _tableByVersion[version];
  if (tableBase == null) throw StateError('没有 $version 的地图小人表地址');

  final classBase = _classTableOffset(rom, version);
  print('职业表基址: 0x${classBase.toRadixString(16)}');

  // 读目标职业的 SMSId（ClassData +6）
  final size = version == 'FE6' ? 72 : 84;
  final smsId = rom[classBase + classIndex * size + 6];
  final entryAt = tableBase + smsId * 8;
  print('职业 $classIndex -> SMSId $smsId, 表项 0x${entryAt.toRadixString(16)}');

  final sizeCode = switch ((w, h)) {
    (16, 16) => 0,
    (16, 32) => 1,
    (32, 32) => 2,
    _ => throw StateError('尺寸必须是 16x16 / 16x32 / 32x32，当前 ${w}x$h'),
  };

  // 把我们的颜色重映射到游戏自军调色板上（关键一步，见函数注释）
  final gamePalAt = _unitPaletteOffset(version);
  final gamePal = <int>[];
  for (var i = 0; i < 16; i++) {
    gamePal.add(rom[gamePalAt + i * 2] | (rom[gamePalAt + i * 2 + 1] << 8));
  }
  final remapped = remapToGamePalette(rows, palBgr, gamePal);
  print('已重映射到游戏调色板（16 色），平均色差 ${remapped.avgError.toStringAsFixed(1)}');

  // 打包 + 压缩。
  // **必须填满整个 sheet 的所有帧**：原条目可能是 3 帧（32×32 时 512×3=1536 字节），
  // 只写第 0 帧的话，游戏切到其它帧就问出花屏。
  final oneFrame = pack4bpp(remapped.indices, w, h);
  final frameCount = _frameCountOf(rom, entryAt);
  final packed = Uint8List.fromList(
      List.generate(frameCount, (_) => oneFrame).expand((x) => x).toList());
  final comp = lz77(packed);
  print('图形 ${packed.length} 字节（$frameCount 帧）-> 压缩后 ${comp.length} 字节');

  final gfxAt = _findFree(rom, comp.length);
  if (gfxAt < 0) throw StateError('找不到放图形的空位');
  rom.setRange(gfxAt, gfxAt + comp.length, comp);

  // 改表项：pattern=0 / sizeCode / sheet 指针
  rom[entryAt] = 0;
  rom[entryAt + 1] = 0;
  rom[entryAt + 2] = sizeCode & 0xFF;
  rom[entryAt + 3] = 0;
  final ptr = 0x08000000 + gfxAt;
  rom[entryAt + 4] = ptr & 0xFF;
  rom[entryAt + 5] = (ptr >> 8) & 0xFF;
  rom[entryAt + 6] = (ptr >> 16) & 0xFF;
  rom[entryAt + 7] = (ptr >> 24) & 0xFF;

  // 调色板：**不能覆盖游戏全局的那 4 组**（自军/敌军/友军/灰）——
  // 那是所有单位共用的，改了会让全军换色。
  // 正确做法是把我们的 16 色映射到游戏现有调色板上（见 remapToGamePalette）。

  File(outPath).writeAsBytesSync(rom);
  print('已写出 $outPath');
}

// 地图小人的 4 组调色板（自军/敌军/友军/行动后灰）
int _unitPaletteOffset(String version) => switch (version) {
      'FE6' => 0x100968,
      'FE7J' => 0x1900E8,
      'FE7U' => 0x194594,
      'FE8J' => 0x5C7340,
      'FE8U' => 0x59EE20,
      _ => -1,
    };

/// 版本识别：按「职业表指针槽是否指向合法表 + 该表首条 number 是否为 0」判定。
///
/// 不要用 ROM 长度猜——FE8J 和 FE8U 都是 16MB，长度完全一样（踩过：
/// 猜成 FE8U 后职业表基址算出 0x34d001，读出的 SMSId 是 247，全是垃圾）。
String _detectVersion(Uint8List d) {
  for (final version in ['FE8J', 'FE8U', 'FE7J', 'FE7U', 'FE6']) {
    final slot = _classPointerSlot[version];
    if (slot == null || slot + 4 > d.length) continue;
    final ptr = d[slot] | (d[slot + 1] << 8) | (d[slot + 2] << 16) | (d[slot + 3] << 24);
    if (ptr < 0x08000000) continue;
    final base = ptr & 0x1FFFFFF;
    if (base + 8 > d.length) continue;
    // 表首 id 0 是空槽（ClassData +4 number == 0）
    if (d[base + 4] != 0) continue;
    final table = _tableByVersion[version];
    if (table == null || table + 8 > d.length) continue;
    // 地图小人表首条也要像条目：size<=2 且 sheet 指针合法
    final sc = d[table + 2] | (d[table + 3] << 8);
    final sh = d[table + 4] | (d[table + 5] << 8) | (d[table + 6] << 16) | (d[table + 7] << 24);
    if (sc > 2 || sh < 0x08000000) continue;
    return version;
  }
  throw StateError('识别不出 ROM 版本');
}

int _classTableOffset(Uint8List d, String version) {
  final slot = _classPointerSlot[version];
  if (slot == null) throw StateError('没有 $version 的职业表槽位');
  final ptr = d[slot] | (d[slot + 1] << 8) | (d[slot + 2] << 16) | (d[slot + 3] << 24);
  return ptr & 0x1FFFFFF;
}

/// 原 sheet 有几帧（解压长度 / 单帧字节数）。
///
/// 只填一帧会导致游戏切到其它帧时花屏，所以先量出原条目实际占多少帧。
int _frameCountOf(Uint8List d, int entryAt) {
  final ptr = d[entryAt + 4] |
      (d[entryAt + 5] << 8) |
      (d[entryAt + 6] << 16) |
      (d[entryAt + 7] << 24);
  if (ptr < 0x08000000) return 1;
  final off = ptr & 0x1FFFFFF;
  if (off + 4 > d.length || d[off] != 0x10) return 1;
  final size = d[off + 1] | (d[off + 2] << 8) | (d[off + 3] << 16);
  final sc = d[entryAt + 2] | (d[entryAt + 3] << 8);
  final (fw, fh) = switch (sc) { 0 => (16, 16), 1 => (16, 32), _ => (32, 32) };
  final perFrame = fw * fh ~/ 2;
  final n = perFrame == 0 ? 1 : (size + perFrame - 1) ~/ perFrame;
  return n.clamp(1, 8);
}

int _findFree(Uint8List d, int size) {
  // 从中间往后找一段够长的连续 0。**只要求段内全 0**，
  // 不额外留前后空隙——实测 FE8J 原版最大的连续空白只有 3952 字节（@0xfe3090），
  // 之前要求「前后各 4 字节也空」会一直找不到。
  var i = 0x800000 & ~3;
  while (i + size <= d.length) {
    if (d[i] != 0) {
      i++;
      continue;
    }
    var run = 0;
    while (i + run < d.length && d[i + run] == 0) {
      run++;
    }
    if (run >= size) return i;
    i += run;
  }
  return -1;
}
