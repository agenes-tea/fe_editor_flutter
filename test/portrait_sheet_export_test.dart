import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/portrait.dart';
import 'package:fe_editor/core/portrait_import.dart';

import 'rom_paths.dart';

const dir = romDir;

/// 按「文件大小 + 识别出的版本」挑 ROM（中文文件名不写进源码）。
EditableRom? _open(String versionId, int size) {
  final d = Directory(dir);
  if (!d.existsSync()) return null;
  for (final f in d.listSync().whereType<File>()) {
    if (f.lengthSync() != size) continue;
    final bytes = f.readAsBytesSync();
    final table = FeRom.detectTable(bytes);
    if (table == null || table.id.toString() != versionId) continue;
    return EditableRom.open(bytes, table);
  }
  return null;
}

int _firstWithImage(PortraitReader r) {
  for (var i = 0; i < r.entryCount; i++) {
    if (r.hasImage(i) && r.faceImage(i) != null) return i;
  }
  return -1;
}

void main() {
  group('素材图导出能被再导入识别（导出的图不是内部 sheet）', () {
    for (final spec in [('FE6', 8388608), ('FE7J', 16777216), ('FE8J', 16777216)]) {
      test('${spec.$1}：导出 128×112 且导入端识别为素材图', () {
        final edit = _open(spec.$1, spec.$2);
        if (edit == null) return; // 样张缺失时跳过，不当作失败
        final reader = PortraitReader(edit.liveRom);
        final id = _firstWithImage(reader);
        expect(id, greaterThanOrEqualTo(0), reason: '${spec.$1} 找不到有图的肖像');

        final material = reader.sheetMaterialImage(id);
        expect(material, isNotNull);
        expect(material!.width, PortraitSheetLayout.width,
            reason: '必须是 FEBuilderGBA 布局的 128×112，才能被导入端识别');
        expect(material.height, PortraitSheetLayout.height);

        // 导出图必须全不透明：FE6 的索引 0 是不透明背景色，
        // 若按「索引 0 = 透明」导出，背景会被当成没画，导入后脸部会少一大半。
        for (var i = 3; i < material.pixels.length; i += 4) {
          expect(material.pixels[i], 255, reason: '素材图不允许有透明像素');
        }

        final back = PortraitImporter.convertRgba(
          material.pixels,
          material.width,
          material.height,
          fe6: edit.rom.table.portraitDataSize == 16,
        );
        expect(back.sourceSheet, isTrue,
            reason: '导出的图必须被导入端认成素材图，否则会被缩成一条横条');
        expect(back.faceIndices, isNotEmpty);
        expect(back.paletteBytes.length, 32);
        reader.dispose();
      });
    }
  });

  group('内容版本号：写入 / 撤销后肖像 reader 必须重新取图', () {
    test('写字节后 contentVersion 递增，reader 的 sheet 缓存失效', () {
      final edit = _open('FE7J', 16777216);
      if (edit == null) return;
      final id = _firstWithImage(PortraitReader(edit.liveRom));
      if (id < 0) return;

      final reader = PortraitReader(edit.liveRom);
      final before = reader.sheet(reader.entryAt(id)!)!;
      final v0 = edit.contentVersion;

      // 只改一个无关字节也足以让内容版本号前进
      edit.writeBytes(0x100, [0x00]);
      expect(edit.contentVersion, isNot(v0),
          reason: '写入必须让内容版本号变化，否则图像缓存永远命中旧图');

      final after = reader.sheet(reader.entryAt(id)!);
      expect(after, isNotNull);
      expect(identical(before, after), isFalse,
          reason: '内容变了，sheet 缓存必须重建而不是端出旧对象');
      reader.dispose();
    });

    test('撤销全部后 contentVersion 继续前进（回滚也得让缓存失效）', () {
      final edit = _open('FE7J', 16777216);
      if (edit == null) return;
      final v0 = edit.contentVersion;
      edit.writeBytes(0x100, [0x00]);
      final v1 = edit.contentVersion;
      edit.revertAll();
      expect(edit.contentVersion, isNot(v1));
      expect(v1, isNot(v0));
    });
  });

  group('图像缓存 key 必须区分内容版本', () {
    test('同一 ROM 同一肖像，内容版本不同则 key 不同', () {
      // 这里只验证 key 拼接逻辑本身，不依赖 UI 页面
      final a = _keyOf(12345, 0);
      final b = _keyOf(12345, 1);
      final c = _keyOf(12345, 2);
      expect(a, isNot(b));
      expect(b, isNot(c));
      expect(a, isNot(c));
    });

    test('不同指纹 + 不同代次不会撞 key（旧实现位域重叠会撞）', () {
      // 旧实现是 指纹 * 0x100000 + 代次 * 0x1000000，指纹相差 16 的倍数时
      // 与代次互相抵消，会得到同一个 key。
      final keys = <int>{};
      for (var tag = 1; tag <= 8; tag++) {
        for (var ver = 1; ver <= 8; ver++) {
          keys.add(_keyOf(tag * 16, ver));
        }
      }
      expect(keys.length, 64, reason: '8×8 组组合必须两两不同');
    });
  });
}

/// 复刻 `PortraitImageCache` 的 key 拼接（UI 层单例，纯函数部分直接用）。
int _keyOf(int romTag, int contentVersion) {
  var h = 0x811C9DC5;
  for (final v in [romTag, contentVersion, 0]) {
    var x = v & 0xFFFFFFFF;
    for (var i = 0; i < 4; i++) {
      h ^= x & 0xFF;
      h = (h * 0x01000193) & 0x7FFFFFFF;
      x >>= 8;
    }
  }
  return h * 0x1000 + ((2 & 0xFFF) << 4) + 1;
}
