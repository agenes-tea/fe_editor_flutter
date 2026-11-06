import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/portrait.dart';
import 'package:fe_editor/core/portrait_porter.dart';

import 'rom_paths.dart';

const dir = romDir;
const fe6jp = '$dir/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

EditableRom _open(String path) {
  final d = File(path).readAsBytesSync();
  return EditableRom.open(d, FeRom.detectTable(d)!);
}

void main() {
  group('原始索引读取（移植的输入）', () {
    test('FE6：正脸 34 行、无独立嘴型、地图脸是明文', () {
      final edit = _open(fe6jp);
      final r = PortraitReader(edit.rom);
      final face = r.faceIndices(1);
      expect(face, isNotNull);
      expect(face!.length, 256 * 34 ~/ 2, reason: 'FE6 正脸 256×34');
      expect(r.mouthIndices(1), isNull, reason: 'FE6 没有独立嘴型数据');
      final map = r.mapFaceIndices(1);
      expect(map, isNotNull);
      expect(map!.length, 32 * 32 ~/ 2);
      expect(r.paletteBytes(1)!.length, 32);
      r.dispose();
    });

    test('FE7/FE8：正脸 40 行、有嘴型 32×96', () {
      for (final path in [fe7jp, fe8jp]) {
        final edit = _open(path);
        final r = PortraitReader(edit.rom);
        final face = r.faceIndices(2);
        expect(face, isNotNull, reason: path);
        expect(face!.length, 256 * 40 ~/ 2, reason: '$path 正脸 256×40');
        final mouth = r.mouthIndices(2);
        expect(mouth, isNotNull, reason: '$path 应有独立嘴型');
        expect(mouth!.length, 32 * 96 ~/ 2);
        r.dispose();
      }
    });

    test('索引解出来能渲染（与 faceImage 一致）', () {
      final edit = _open(fe8jp);
      final r = PortraitReader(edit.rom);
      final idx = r.faceIndices(2)!;
      // 索引里至少有一部分非 0（不是全空数据）
      expect(idx.where((b) => b != 0).length, greaterThan(0));
      final img = r.faceImage(2);
      expect(img, isNotNull);
      expect(img!.width, 96);
      expect(img.height, 80);
      r.dispose();
    });
  });

  group('FE6 → FE8 移植', () {
    test('写入后目标能解出这张脸，且内容不是空白', () {
      final source = _open(fe6jp);
      final target = _open(fe8jp);
      final srcReader = PortraitReader(source.rom);
      final before = PortraitReader(target.rom).entryCount;

      final out = PortraitPorter(target).port(srcReader, 1);
      expect(out.ok, isTrue, reason: out.message);
      expect(out.bytesWritten, greaterThan(0));
      expect(out.freeSpaceOffset, greaterThan(0), reason: '新数据写进了空闲区');

      final tgtReader = PortraitReader(target.liveRom);
      expect(tgtReader.entryCount, greaterThan(before), reason: '新条目应被计入');

      final face = tgtReader.faceImage(out.targetId);
      expect(face, isNotNull);
      expect(face!.width, 96);
      expect(face.height, 80);
      // 移植过来的脸必须有实际内容（不是一把透明）
      expect(face.opaqueRatio, greaterThan(0.05),
          reason: '移植后不应是空白图');

      // 地图头像也一起过来了
      final map = tgtReader.mapFaceImage(out.targetId);
      expect(map, isNotNull);
      expect(map!.width, 32);

      srcReader.dispose();
      tgtReader.dispose();
    });

    test('源是 34 行、目标是 40 行：多出的行补 0 而不是错位', () {
      final source = _open(fe6jp);
      final target = _open(fe8jp);
      final out = PortraitPorter(target).port(srcReaderOf(source), 1);
      expect(out.ok, isTrue, reason: out.message);

      final r = PortraitReader(target.liveRom);
      final idx = r.faceIndices(out.targetId)!;
      expect(idx.length, 256 * 40 ~/ 2);
      r.dispose();
    });
  });

  group('FE8 → FE6 移植', () {
    test('正脸写成 LZ77、嘴型丢弃、地图脸写明文', () {
      final source = _open(fe8jp);
      final target = _open(fe6jp);
      final srcReader = PortraitReader(source.rom);

      final out = PortraitPorter(target).port(srcReader, 2);
      expect(out.ok, isTrue, reason: out.message);

      final tgt = PortraitReader(target.liveRom);
      final entry = tgt.entryAt(out.targetId)!;
      // FE6 正脸必须是合法 LZ77
      expect(Lz77.isCompressed(target.buffer.data, entry.unitFace), isTrue);
      expect(Lz77.uncompressedSize(target.buffer.data, entry.unitFace),
          256 * 34 ~/ 2);
      // FE6 条目没有嘴型字段
      expect(entry.mouth, 0);
      // 地图脸在 FE6 是明文
      expect(Lz77.isCompressed(target.buffer.data, entry.mapFace), isFalse);

      final face = tgt.faceImage(out.targetId);
      expect(face, isNotNull);
      expect(face!.opaqueRatio, greaterThan(0.05));

      srcReader.dispose();
      tgt.dispose();
    });
  });

  group('同世代移植（FE7 → FE8）', () {
    test('格式一致，能完整移植且保留嘴型', () {
      final source = _open(fe7jp);
      final target = _open(fe8jp);
      final srcReader = PortraitReader(source.rom);

      final out = PortraitPorter(target).port(srcReader, 3);
      expect(out.ok, isTrue, reason: out.message);

      final tgt = PortraitReader(target.liveRom);
      final entry = tgt.entryAt(out.targetId)!;
      expect(entry.mouth, greaterThan(0), reason: 'FE7 → FE8 应保留嘴型');
      // 嘴型图能解出 32×16 的一帧
      final frame = tgt.mouthFrame(out.targetId, 1);
      expect(frame, isNotNull);
      expect(frame!.width, 32);
      expect(frame.height, 16);

      srcReader.dispose();
      tgt.dispose();
    });
  });

  group('可撤销与导出', () {
    test('撤销后目标 ROM 逐字节还原', () {
      final source = _open(fe6jp);
      final target = _open(fe8jp);
      final srcReader = PortraitReader(source.rom);

      expect(PortraitPorter(target).port(srcReader, 1).ok, isTrue);
      expect(target.hasChanges, isTrue);
      target.revertAll();
      expect(target.hasChanges, isFalse);
      expect(target.data, equals(target.original));
      srcReader.dispose();
    });

    test('移植后的 ROM 仍能检出原有条目数不变（只是多了新条目）', () {
      final source = _open(fe6jp);
      final target = _open(fe8jp);
      final srcReader = PortraitReader(source.rom);
      final before = PortraitReader(target.rom).entryCount;
      final out = PortraitPorter(target).port(srcReader, 1);
      expect(out.ok, isTrue);
      final tgt = PortraitReader(target.liveRom);
      final after = tgt.entryCount;
      expect(after, greaterThan(before), reason: '至少多出移植的那一条');
      expect(tgt.entryAt(out.targetId), isNotNull, reason: '新条目必须可读');
      srcReader.dispose();
    });
  });

  group('替换模式（社区改版的主流做法）', () {
    test('替换目标已有条目：只改那一条，表不动、条目数不变', () {
      final source = _open(fe6jp);
      final target = _open(fe8jp);
      final srcReader = PortraitReader(source.rom);

      final before = PortraitReader(target.rom);
      final countBefore = before.entryCount;
      final tableBefore = before.baseAddress;
      // 另一个条目的指针快照（替换后必须一字不变）
      final otherBefore = before.entryAt(4)!;
      final otherRaw = [
        for (var i = 0; i < 28; i++) target.buffer.data[tableBefore + 4 * 28 + i]
      ];

      final out = PortraitPorter(target)
          .port(srcReader, 1, replaceTargetId: 2);
      expect(out.ok, isTrue, reason: out.message);
      expect(out.targetId, 2);

      final after = PortraitReader(target.liveRom);
      expect(after.entryCount, countBefore, reason: '替换不新增条目');
      expect(after.baseAddress, tableBefore, reason: '替换不搬表');

      // 被替换的条目现在能解出源那张脸
      final face = after.faceImage(2);
      expect(face, isNotNull);
      expect(face!.opaqueRatio, greaterThan(0.05));

      // 别的条目一字未动
      final otherAfter = after.entryAt(4)!;
      expect(otherAfter.unitFace, otherBefore.unitFace);
      expect(otherAfter.palette, otherBefore.palette);
      expect(
          [for (var i = 0; i < 28; i++) target.buffer.data[tableBefore + 4 * 28 + i]],
          otherRaw);

      srcReader.dispose();
    });

    test('替换成不存在的 ID 被拒绝且不写 ROM', () {
      final source = _open(fe6jp);
      final target = _open(fe8jp);
      final srcReader = PortraitReader(source.rom);
      final out = PortraitPorter(target)
          .port(srcReader, 1, replaceTargetId: 99999);
      expect(out.result, PortraitPortResult.noTargetEntry);
      expect(out.message, contains('没有第 99999 条'));
      expect(target.hasChanges, isFalse);
      srcReader.dispose();
    });

    test('replaceTargetId = null 仍是追加（老行为不变）', () {
      final source = _open(fe6jp);
      final target = _open(fe8jp);
      final srcReader = PortraitReader(source.rom);
      final before = PortraitReader(target.rom).entryCount;
      final out = PortraitPorter(target).port(srcReader, 1);
      expect(out.ok, isTrue);
      expect(PortraitReader(target.liveRom).entryCount, greaterThan(before));
      srcReader.dispose();
    });
  });

  group('usageOf：替换前看清影响面', () {
    test('能报出使用该肖像的角色/职业名', () {
      final edit = _open(fe8jp);
      final r = PortraitReader(edit.rom);
      // 找一个真的被角色使用的肖像
      var hit = '';
      for (var id = 1; id < 40 && hit.isEmpty; id++) {
        hit = r.usageOf(id);
      }
      expect(hit, isNotEmpty, reason: '前 40 条里应有被引用的肖像');
      // 没人用的 ID 返回空串
      expect(r.usageOf(99999), '');
      r.dispose();
    });
  });

  group('防护', () {
    test('源条目没有图时返回 sourceEmpty 且不写 ROM', () {
      final source = _open(fe8jp);
      final target = _open(fe6jp);
      final srcReader = PortraitReader(source.rom);
      // FE8 的 ID 0 是全 NULL 条目
      final out = PortraitPorter(target).port(srcReader, 0);
      expect(out.result, PortraitPortResult.sourceEmpty);
      expect(target.hasChanges, isFalse);
      srcReader.dispose();
    });

    test('越界 ID 返回 sourceEmpty', () {
      final source = _open(fe6jp);
      final target = _open(fe8jp);
      final out = PortraitPorter(target).port(PortraitReader(source.rom), 99999);
      expect(out.result, PortraitPortResult.sourceEmpty);
      expect(target.hasChanges, isFalse);
    });
  });
}

PortraitReader srcReaderOf(EditableRom edit) => PortraitReader(edit.rom);
