import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/portrait.dart';
import 'package:fe_editor/core/portrait_porter.dart';
import 'package:fe_editor/core/portrait_import.dart';
import 'package:fe_editor/core/tile_image.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/battle_anim.dart' show encodePng;

import 'rom_paths.dart';

void main() {
  group('肖像导入后名称缓存', () {
    test('FE6 导入后 portrait table entry 指向新数据，faceImage 正常渲染', () {
      final bytes = File(
          romDir + '/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba')
          .readAsBytesSync();
      final table = FeRom.detectTable(bytes)!;
      final edit = EditableRom.open(bytes, table);
      final r0 = PortraitReader(edit.liveRom);

      // 确认 entry 1 原本是ロイ
      expect(r0.nameFor(1), contains('ロイ'), reason: 'entry 1 should be Roy before import');
      final oldFace = r0.entryAt(1)!.unitFace;

      // 创建一个测试肖像
      final tile = TileImage(96, 80);
      for (var y = 0; y < 80; y++) {
        for (var x = 0; x < 96; x++) {
          final cx = x - 48, cy = y - 40;
          final dist = (cx*cx + cy*cy).toDouble();
          if (dist < 900) tile.setPixel(x, y, 200, 100, 150, 255);
          else tile.setPixel(x, y, 100, 200, 100, 255);
        }
      }
      final rgba = PngDecoder.decodeRgba(encodePng(tile))!;
      final result = PortraitImporter.convertRgba(rgba, 96, 80, fe6: true);

      // 导入
      final out = PortraitPorter(edit).importFace(result, 1);
      expect(out.ok, isTrue, reason: out.message);

      // 重新读 reader
      final r1 = PortraitReader(edit.liveRom);

      // portrait table entry 1 应指向新数据（不再是旧地址）
      final e1 = r1.entryAt(1);
      expect(e1, isNotNull);
      expect(e1!.unitFace, isNot(oldFace),
          reason: 'portrait table entry should point to new free-space data');

      // faceImage 应正常渲染
      final face = r1.faceImage(1);
      expect(face, isNotNull, reason: 'faceImage returned null after import');
      expect(face!.width, 96);
      expect(face.height, 80);

      r1.dispose();
      r0.dispose();
    });

    test('FE6 导入到空槽：nameFor 返回空字符串（无单位引用）', () {
      final bytes = File(
          romDir + '/0378 - 火炎之纹章-封印之剑 Fire Emblem - Fuuin no Tsurugi(JP)(Nintendo)(64Mb).gba')
          .readAsBytesSync();
      final table = FeRom.detectTable(bytes)!;
      final edit = EditableRom.open(bytes, table);
      final r0 = PortraitReader(edit.liveRom);

      // 找一个有图但 nameFor 为空的空槽
      int emptySlot = -1;
      for (int i = 0; i < r0.entryCount && emptySlot < 0; i++) {
        if (r0.hasImage(i) && r0.nameFor(i).isEmpty) {
          emptySlot = i;
        }
      }
      if (emptySlot < 0) {
        print('No empty slot found, skipping');
        r0.dispose();
        return;
      }

      final tile = TileImage(96, 80);
      for (var y = 0; y < 80; y++) {
        for (var x = 0; x < 96; x++) {
          final cx = x - 48, cy = y - 40;
          final dist = (cx*cx + cy*cy).toDouble();
          if (dist < 900) tile.setPixel(x, y, 200, 100, 150, 255);
          else tile.setPixel(x, y, 100, 200, 100, 255);
        }
      }
      final rgba = PngDecoder.decodeRgba(encodePng(tile))!;
      final result = PortraitImporter.convertRgba(rgba, 96, 80, fe6: true);

      final out = PortraitPorter(edit).importFace(result, emptySlot);
      expect(out.ok, isTrue, reason: out.message);

      // 空槽没有单位引用，nameFor 仍为空
      final r1 = PortraitReader(edit.liveRom);
      expect(r1.nameFor(emptySlot).isEmpty, isTrue,
          reason: 'empty slot should have no name after import');
      r1.dispose();
      r0.dispose();
    });
  });
}
