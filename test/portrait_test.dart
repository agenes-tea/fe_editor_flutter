import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/portrait.dart';
import 'package:fe_editor/core/rom_info.dart';
import 'package:fe_editor/core/tile_image.dart';
import 'package:fe_editor/core/zh_table.dart';
import 'package:fe_editor/core/zh_tables_data.dart';

const dir = '/root/workspace/game-rom';
const fe6jp = '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const fe6cn = '$dir/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe7us = '$dir/1235 - 火炎之纹章-烈火之剑 Fire Emblem(US)(Nintendo)(128Mb).gba';
const fe7cn = '$dir/火焰纹章 - 烈火之剑[Superxyj](简)(JP)(145.61Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';
const fe8cn = '$dir/火炎之纹章-圣魔之光石汉化.gba';

FeRom _open(String path) {
  final data = File(path).readAsBytesSync();
  final table = FeRom.detectTable(data);
  expect(table, isNotNull, reason: path);
  return FeRom(data, table!);
}

void main() {
  group('LZ77', () {
    test('非法数据不被误判为压缩', () {
      final rom = _open(fe7jp);
      // 0x0000 处是 GBA 头部，不是 LZ77
      expect(Lz77.isCompressed(rom.data, 0), isFalse);
      expect(Lz77.uncompressedSize(rom.data, 0), 0);
      expect(Lz77.decompress(rom.data, 0), isNull);
      expect(Lz77.decompress(rom.data, rom.length - 2), isNull);
    });

    test('已知数据解压长度与内容正确', () {
      // 手工构造：3 字节全字面量
      final src = Uint8List.fromList([
        0x10, 0x03, 0x00, 0x00, // 头：size=3
        0x00, // flags：8 个字面量
        0xAA, 0xBB, 0xCC,
      ]);
      final out = Lz77.decompress(src, 0)!;
      expect(out, [0xAA, 0xBB, 0xCC]);
    });

    test('解压长度越界时拒绝', () {
      final bad = Uint8List.fromList([0x10, 0xFF, 0xFF, 0xFF, 0x00]);
      expect(Lz77.decompress(bad, 0), isNull);
    });
  });

  group('4bpp 解码', () {
    test('tile 顺序：同一字节的两个像素水平相邻', () {
      final pal = GbaPalette();
      pal.argb[1] = 0xFFFF0000;
      pal.argb[2] = 0xFF00FF00;
      // 8x8 一个 tile，第一字节 0x21 → 低 4 位=1(红) 在左，高 4 位=2(绿) 在右
      final data = Uint8List.fromList([0x21, 0x00, 0x00, 0x00]);
      final img = decode4bpp(data, 0, 8, 8, pal);
      expect(img.width, 8);
      expect(img.height, 8);
      // (0,0) 红、(1,0) 绿；后续像素全 0 → 透明
      expect(img.alpha(0, 0), 255);
      expect(img.pixels[0], 0xFF); // R
      expect(img.pixels[1], 0x00); // G
      expect(img.alpha(1, 0), 255);
      expect(img.pixels[4], 0x00); // R
      expect(img.pixels[5], 0xFF); // G
      expect(img.alpha(2, 0), 0);
      // 第二行在第一个 tile 内的同一行偏移 +8
      expect(img.alpha(0, 1), 0);
    });

    test('索引 0 恒透明', () {
      final pal = GbaPalette();
      final data = Uint8List.fromList([0x00, 0x00, 0x00, 0x00]);
      final img = decode4bpp(data, 0, 8, 8, pal);
      expect(img.opaqueRatio, 0);
    });

    test('块内推进：连续字节填充同一 8x8 tile 的各行', () {
      final pal = GbaPalette();
      pal.argb[1] = 0xFF000000;
      // 32 字节全为 0x11 → 整个 8x8 tile 都是索引 1
      final data = Uint8List.fromList(List<int>.filled(32, 0x11));
      final img = decode4bpp(data, 0, 8, 8, pal);
      expect(img.opaqueRatio, 1.0);
      expect(img.alpha(7, 7), 255);
    });

    test('blit 越界安全', () {
      final dst = TileImage(8, 8);
      final src = TileImage(4, 4);
      TileImage.blit(dst, 6, 6, 8, 8, src, 0, 0);
      TileImage.blit(dst, -4, -4, 8, 8, src, 0, 0);
      expect(dst.width, 8);
    });
  });

  group('肖像表（真实 ROM）', () {
    test('5 个版本的肖像表都能定位且有足量条目', () {
      final cases = {
        'FE6': fe6jp,
        'FE6CN': fe6cn,
        'FE7J': fe7jp,
        'FE7U': fe7us,
        'FE7CN': fe7cn,
        'FE8J': fe8jp,
        'FE8CN': fe8cn,
      };
      for (final e in cases.entries) {
        final rom = _open(e.value);
        final r = PortraitReader(rom);
        expect(r.available, isTrue, reason: e.key);
        expect(r.entryCount, greaterThan(50), reason: e.key);
        r.dispose();
      }
    });

    test('肖像表地址与 FEBuilderGBA 一致', () {
      expect(fe6Jp.portraitPointerSlot, 0x7FD8);
      expect(fe6Jp.portraitDataSize, 16);
      expect(fe7Jp.portraitPointerSlot, 0x0069C0);
      expect(fe7Jp.portraitDataSize, 28);
      expect(fe7Us.portraitPointerSlot, 0x006B30);
      expect(fe8Jp.portraitPointerSlot, 0x00542C);
      expect(fe8Us.portraitPointerSlot, 0x005524);
    });

    test('正脸拼装：尺寸正确且有合理的不透明占比', () {
      for (final path in [fe6jp, fe7jp, fe7us, fe8jp]) {
        final rom = _open(path);
        final r = PortraitReader(rom);
        var checked = 0;
        for (var id = 0; id < r.entryCount && checked < 3; id++) {
          final face = r.faceImage(id);
          if (face == null) continue;
          expect(face.width, 96, reason: path);
          expect(face.height, 80, reason: path);
          // 解析错会几乎全透明；没挖透明会几乎全不透明
          expect(face.opaqueRatio, greaterThan(0.05), reason: '$path#$id');
          expect(face.opaqueRatio, lessThan(0.95), reason: '$path#$id');
          checked++;
        }
        expect(checked, greaterThan(0), reason: path);
        r.dispose();
      }
    });

    test('正脸是连贯图像而不是交错条纹（tile 顺序回归）', () {
      // 交错条纹的特征：相邻列的像素几乎处处不同。
      // 正确解码的肖像相邻列大量相同（大片同色区域）。
      for (final path in [fe6jp, fe7jp]) {
        final rom = _open(path);
        final r = PortraitReader(rom);
        var checked = 0;
        for (var id = 0; id < r.entryCount && checked < 3; id++) {
          final face = r.faceImage(id);
          if (face == null) continue;
          var same = 0;
          var total = 0;
          for (var y = 0; y < face.height; y++) {
            for (var x = 0; x + 1 < face.width; x++) {
              final i = (y * face.width + x) * 4;
              if (face.pixels[i + 3] == 0) continue;
              total++;
              if (face.pixels[i] == face.pixels[i + 4] &&
                  face.pixels[i + 1] == face.pixels[i + 5] &&
                  face.pixels[i + 2] == face.pixels[i + 6]) {
                same++;
              }
            }
          }
          if (total > 100) {
            // 正确解码时同色相邻像素应占多数
            expect(same / total, greaterThan(0.30), reason: '$path#$id');
            checked++;
          }
        }
        expect(checked, greaterThan(0), reason: path);
        r.dispose();
      }
    });

    test('地图头像 32×32、职业卡 80×80', () {
      final rom = _open(fe7jp);
      final r = PortraitReader(rom);
      var maps = 0;
      var cards = 0;
      for (var id = 0; id < r.entryCount && (maps < 2 || cards < 2); id++) {
        final m = r.mapFaceImage(id);
        if (m != null) {
          expect(m.width, 32);
          expect(m.height, 32);
          maps++;
        }
        final c = r.classCardImage(id);
        if (c != null) {
          expect(c.width, 80);
          expect(c.height, 80);
          cards++;
        }
      }
      expect(maps, greaterThan(0));
      expect(cards, greaterThan(0));
      r.dispose();
    });

    test('FE6 走 16 字节条目路径，嘴型帧来自 sheet', () {
      final rom = _open(fe6jp);
      final r = PortraitReader(rom);
      expect(r.isFe6, isTrue);
      expect(r.entryCount, greaterThan(50));
      var frames = 0;
      for (var id = 0; id < r.entryCount && frames < 2; id++) {
        final e = r.entryAt(id);
        if (e == null || e.unitFace == 0) continue;
        expect(e.mouth, 0);
        final f = r.mouthFrame(id, 1);
        if (f != null) {
          expect(f.width, 32);
          expect(f.height, 16);
          frames++;
        }
      }
      expect(frames, greaterThan(0));
      r.dispose();
    });

    test('汉化版能出图（若表被重定位则至少不崩）', () {
      for (final path in [fe6cn, fe7cn, fe8cn]) {
        final rom = _open(path);
        final r = PortraitReader(rom);
        // 条目表本身是地址表，与文本引擎无关，汉化版通常仍可读
        expect(r.available, isTrue, reason: path);
        final face = r.faceImage(0);
        if (face != null) {
          expect(face.width, 96);
          expect(face.height, 80);
        }
        r.dispose();
      }
    });

    test('名字反查：单位表命中的肖像返回该单位名', () {
      final rom = _open(fe7jp);
      final r = PortraitReader(rom);
      // unit 0 的 portraitId 指向的肖像应反查出 Eliwood 的日文名
      final portraitId = rom.data[rom.unitBase + UnitOffsets.portraitId];
      final name = r.nameFor(portraitId);
      expect(name, isNotEmpty);
      r.dispose();
    });

    test('名字反查：FE6 汉化版 肖像 0..9 依次是山贼/罗伊/克莱丽奈…', () {
      // FE6 的 face 编号从 1 起（face=0 是山贼那张通用敌人脸），
      // 所以肖像 1 才是罗伊。名称对不上会让整个列表错位一位。
      // 用汉化版验证（FE6 日版的文本引擎已被汉化组改写，解不出名字）。
      final rom = _open(fe6cn);
      rom.zhTable = ZhTable(zhTblFE6);
      final r = PortraitReader(rom);
      final expectNames = ['山贼', '罗伊', '克莱丽奈', '珐', '辛', '苏', '戴扬', '巴斯', '鲍斯', '道格拉斯'];
      for (var i = 0; i < expectNames.length; i++) {
        expect(r.nameFor(i), expectNames[i], reason: 'FE6 肖像 $i');
      }
      r.dispose();
    });

    test('名字反查：FE6 日版（文本解不出名字时不应报错）', () {
      final rom = _open(fe6jp);
      final r = PortraitReader(rom);
      // 日版 FE6 的文本引擎已失效，名字可能为空，但不能抛异常
      for (var i = 0; i < r.entryCount; i++) {
        r.nameFor(i);
      }
      r.dispose();
    });

    test('名字反查：FE7 肖像 2 是艾利乌德（不偏移）', () {
      final rom = _open(fe7jp);
      final r = PortraitReader(rom);
      expect(r.nameFor(2), 'エリウッド');
      r.dispose();
    });

    test('名字反查：FE8 肖像 2 是艾利克', () {
      final rom = _open(fe8jp);
      final r = PortraitReader(rom);
      expect(r.nameFor(2), 'エイリーク');
      r.dispose();
    });

    test('名字反查：不会误取道具名（face 必须按 u16 读）', () {
      // u8 读 face 会把 0x0103 截成 0x03，匹配到别的肖像，
      // 于是把道具名（射程 / 远程恢复杖）当成角色名显示出来。
      for (final path in [fe7jp, fe8jp]) {
        final rom = _open(path);
        final r = PortraitReader(rom);
        for (var i = 0; i < r.entryCount; i++) {
          final n = r.nameFor(i);
          expect(n, isNot(contains('射程')));
          expect(n, isNot(contains('远程恢复杖')));
          expect(n, isNot(contains('闪电魔法')));
        }
        r.dispose();
      }
    });

    test('肖像表 ID 0 是合法条目（不能被跳过）', () {
      // FE7/FE8 的 ID 0 是全 NULL 条目（市民 / 对战相手），
      // 跳过它会让后面所有 ID 后移一位。
      for (final path in [fe7jp, fe8jp]) {
        final rom = _open(path);
        final r = PortraitReader(rom);
        final e0 = r.entryAt(0);
        expect(e0, isNotNull, reason: path);
        // ID 1 才是第一张有图的肖像
        expect(r.entryAt(1)!.unitFace, isNot(0), reason: path);
        r.dispose();
      }
    });
  });
}
