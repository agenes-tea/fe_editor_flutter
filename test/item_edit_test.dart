import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/item_catalog.dart';
import 'package:fe_editor/core/patch_format.dart';

const dir = '/root/workspace/game-rom';
const fe6cn = '$dir/火焰纹章 - 封印之剑[狼组&火花天龙剑](v20060906)(简)(JP)(64Mb).gba';
const fe7jp = '$dir/0979 - 火炎之纹章-烈火之剑 Fire Emblem - Rekka no Ken(JP)(Nintendo)(128Mb).gba';
const fe7us = '$dir/1235 - 火炎之纹章-烈火之剑 Fire Emblem(US)(Nintendo)(128Mb).gba';
const fe8jp = '$dir/1692 - 火炎之纹章-圣魔之光石 Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba';

EditableRom _open(String path) {
  final data = File(path).readAsBytesSync();
  return EditableRom.open(data, FeRom.detectTable(data)!);
}

EditField _field(EditableRom edit, String label) =>
    itemEditableFieldsFor(fe6: edit.rom.isFe6)
        .firstWhere((f) => f.label == label);

void main() {
  group('道具字段定义', () {
    test('字段覆盖耐久/威力/命中/重量/必杀/射程/单价/等级/图标', () {
      final labels = itemEditableFields.map((f) => f.label).toSet();
      expect(labels, containsAll(<String>{
        '使用次数',
        '威力',
        '命中',
        '重量',
        '必杀',
        '射程',
        '单价',
        '武器等级',
        '图标 ID',
      }));
    });

    test('偏移与 ItemOffsets 一致，且不与其它字段重叠', () {
      final used = <int>[];
      for (final f in itemEditableFields) {
        for (var k = 0; k < f.byteSize; k++) {
          expect(used.contains(f.offset + k), isFalse,
              reason: '${f.label} 的 ${f.offset + k} 被重复占用');
          used.add(f.offset + k);
        }
      }
      // 单价 u16 占 26..27，必须让出来（+27 原来是「高字节」从未被用过）
      expect(used, containsAll([20, 21, 22, 23, 24, 25, 26, 27, 28, 29]));
    });

    test('单价是 u16、射程是 nibble', () {
      final price = itemEditableFields.firstWhere((f) => f.label == '单价');
      expect(price.u16, isTrue);
      expect(price.byteSize, 2);
      expect(price.max, 65535);

      final range = itemEditableFields.firstWhere((f) => f.label == '射程');
      expect(range.nibbles, isTrue);
      expect(range.allowedNibbles, isNotEmpty);
      // 只允许游戏认识的组合
      for (final v in range.allowedNibbles) {
        expect(v, lessThanOrEqualTo(0xFF));
      }
    });

    test('射程合法集合覆盖三作实际出现的码值', () {
      for (final p in [fe6cn, fe7jp, fe7us, fe8jp]) {
        final rom = FeRom(File(p).readAsBytesSync(), FeRom.detectTable(File(p).readAsBytesSync())!);
        final cat = ItemCatalog(rom);
        final allowed =
            itemEditableFields.firstWhere((f) => f.label == '射程').allowedNibbles;
        for (var i = 0; i < cat.count; i++) {
          final e = cat.entryAt(i)!;
          expect(allowed.contains(e.range.raw), isTrue,
              reason: '$p item $i 射程码 0x${e.range.raw.toRadixString(16)}');
        }
      }
    });
  });

  group('道具字段写入', () {
    test('改威力/命中/重量可读回，且只改一个字节', () {
      final edit = _open(fe7jp);
      final cat = ItemCatalog(edit.rom);
      final before = cat.entryAt(4)!;
      final addr = edit.itemAddress(4);

      for (final label in ['威力', '命中', '重量', '必杀', '使用次数']) {
        final f = _field(edit, label);
        final orig = edit.readField(addr, f);
        expect(edit.writeField(addr, f, 77), isTrue);
        expect(edit.readField(addr, f), 77);
        expect(edit.data[addr + f.offset], 77);
        edit.writeField(addr, f, orig);
        expect(edit.readField(addr, f), orig);
      }
      expect(before.might, 13, reason: '银剑威力，测试用样本不能动它');
    });

    test('单价 u16 往返：50000 不会被截断成 80', () {
      final edit = _open(fe7jp);
      final price = _field(edit, '单价');
      final addr = edit.itemAddress(150);
      final orig = edit.readField(addr, price);
      expect(orig, 50000, reason: '覇者の証');

      expect(edit.writeField(addr, price, 12345), isTrue);
      expect(edit.readField(addr, price), 12345);
      // 小端：低字节在前
      expect(edit.data[addr + 26], 12345 & 0xFF);
      expect(edit.data[addr + 27], 12345 >> 8);

      edit.writeField(addr, price, orig);
      expect(edit.readField(addr, price), 50000);
      expect(edit.data[addr + 26], 50000 & 0xFF);
      expect(edit.data[addr + 27], 50000 >> 8);
    });

    test('单价超出 u16 上限会被夹紧', () {
      final edit = _open(fe7jp);
      final price = _field(edit, '单价');
      final addr = edit.itemAddress(1);
      edit.writeField(addr, price, 999999);
      expect(edit.readField(addr, price), 65535);
    });

    test('射程码只接受合法组合', () {
      final edit = _open(fe7jp);
      final range = _field(edit, '射程');
      final addr = edit.itemAddress(1);
      expect(edit.readField(addr, range), 0x11, reason: '铁剑射程1');

      edit.writeField(addr, range, 0x22);
      expect(edit.readField(addr, range), 0x22, reason: '改成射程2-2');
      edit.writeField(addr, range, 0x3F);
      expect(edit.readField(addr, range), 0x3F, reason: '改成射程3-15');
      edit.writeField(addr, range, 0x11);
      expect(edit.readField(addr, range), 0x11);

      // 非法组合：拒绝写入，保持原值
      edit.writeField(addr, range, 0x77);
      expect(edit.readField(addr, range), 0x11);
    });

    test('改道具字段可撤销', () {
      final edit = _open(fe7jp);
      final price = _field(edit, '单价');
      final addr = edit.itemAddress(1);
      final orig = edit.readField(addr, price);
      edit.writeField(addr, price, 4242);
      expect(edit.hasChanges, isTrue);
      edit.revertAll();
      expect(edit.hasChanges, isFalse);
      expect(edit.readField(addr, price), orig);
    });

    test('同值不写，不产生 edits 记录', () {
      final edit = _open(fe7jp);
      final f = _field(edit, '威力');
      final addr = edit.itemAddress(1);
      final orig = edit.readField(addr, f);
      expect(edit.writeField(addr, f, orig), isFalse);
      expect(edit.changedByteCount, 0);
    });

    test('道具改动可生成 UPS 并还原', () {
      final edit = _open(fe7jp);
      edit.writeField(edit.itemAddress(4), _field(edit, '威力'), 250);
      edit.writeField(edit.itemAddress(150), _field(edit, '单价'), 60000);
      final out = edit.buildOutput();
      final patch = UpsPatch.create(edit.original, out);
      final back = UpsPatch.apply(patch, edit.original);
      expect(back, isNotNull);
      expect(back, out);
    });
  });

  group('跨版本', () {
    test('四个版本的字段都能写能读回', () {
      for (final p in [fe6cn, fe7jp, fe7us, fe8jp]) {
        final edit = _open(p);
        final addr = edit.itemAddress(1);
        for (final label in ['威力', '命中', '单价', '射程']) {
          final f = _field(edit, label);
          final orig = edit.readField(addr, f);
          final next = label == '射程' ? 0x11 : orig + 1;
          edit.writeField(addr, f, next);
          expect(edit.readField(addr, f), next, reason: '$p $label');
          edit.writeField(addr, f, orig);
        }
      }
    });

    test('道具条目大小不同，但字段偏移相同', () {
      // FE6 条目 32 字节、FE7/FE8 36 字节；+20~+29 的位置一致。
      // 用相邻两条道具反证：改第 2 条不应影响第 3 条。
      final edit = _open(fe6cn);
      final f = _field(edit, '威力');
      edit.writeField(edit.itemAddress(2), f, 111);
      expect(edit.readField(edit.itemAddress(3), f), isNot(111));
    });
  });
}
