// 校验打了调试器补丁的 FE8 ROM：文本表完整、单位/职业/道具表仍可读。
// ignore_for_file: avoid_print
import 'dart:io';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/rom_info.dart';

void check(String path) {
  final rom = FeRom(File(path).readAsBytesSync(), fe8Jp);
  print('== $path');
  print('  encoding: ${rom.textEncoding}');
  print('  units=${rom.unitCount} classes=${rom.classCount} items=${rom.itemCount}');
  final n = rom.unitCount;
  var empty = 0;
  for (var i = 0; i < n; i++) {
    if (rom.unitName(i).isEmpty) {
      empty++;
    }
  }
  print('  empty unit names: $empty / $n');
  for (final i in [0, 1, 2]) {
    print('  unit[$i] name="${rom.unitName(i)}" class="${rom.className(i < rom.classCount ? i : 0)}"');
  }
  print('  first 3 class names: ${List.generate(3, (i) => rom.className(i))}');
  print('  first 3 item names: ${List.generate(3, (i) => rom.itemName(i))}');
}

void main(List<String> args) {
  for (final p in args) {
    check(p);
  }
}
