import 'dart:io';
import 'dart:typed_data';

import 'package:fe_editor/core/disassembler.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/ui/disasm_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _dir = '/root/workspace/game-rom';

/// 反汇编器的**固定回归基线**。
///
/// 期望值全部来自 `arm-none-eabi-objdump -D -b binary -marm`（含 `-M force-thumb`）
/// 对同一机器码的输出，即与 GNU 工具链逐条对齐过。
/// 说明：GBA 是 ARMv4T，objdump 按 ARMv5+ 识别的扩展指令（movw/movt/smmls 等）
/// 不属于本机指令集，不在基线里。
/// 把解码器输出里的制表符对齐去掉，只比语义部分。
String _norm(String s) => s.replaceAll('\t', ' ').replaceAll(RegExp(r' +'), ' ').trim();

void main() {
  DisasmLine decodeArm(int word) {
    final b = Uint8List(4)
      ..[0] = word & 0xFF
      ..[1] = (word >> 8) & 0xFF
      ..[2] = (word >> 16) & 0xFF
      ..[3] = (word >> 24) & 0xFF;
    return ArmDisassembler(b).decode(0, DisasmMode.arm)!;
  }

  DisasmLine decodeThumb(int half) {
    final b = Uint8List(2)
      ..[0] = half & 0xFF
      ..[1] = (half >> 8) & 0xFF;
    return ArmDisassembler(b).decode(0, DisasmMode.thumb)!;
  }

  group('ARM 指令（与 objdump 对齐）', () {
    const cases = <int, String>{
      0xE3A00001: 'mov r0, #1',
      0xE0800001: 'add r0, r0, r1',
      0xE2400005: 'sub r0, r0, #5',
      0xE3500007: 'cmp r0, #7',
      0xE1800201: 'orr r0, r0, r1, lsl #4',
      0xE0000001: 'and r0, r0, r1',
      0xE1A01002: 'mov r1, r2',
      0xE0811002: 'add r1, r1, r2',
      0xE1A01201: 'lsl r1, r1, #4',
      0xE1A00023: 'lsr r0, r3, #32',
      0xE5921000: 'ldr r1, [r2]',
      0xE5821000: 'str r1, [r2]',
      0xE92D4FF0: 'push {r4, r5, r6, r7, r8, r9, sl, fp, lr}',
      0xE8BD4FF0: 'pop {r4, r5, r6, r7, r8, r9, sl, fp, lr}',
      0xE8900006: 'ldm r0, {r1, r2}',
      0xE0000192: 'mul r0, r2, r1',
      0xE0200192: 'mla r0, r2, r1, r0',
      0xE1000090: 'swp r0, r0, [r0]',
      0xE1D200B0: 'ldrh r0, [r2]',
      0xE1C200B0: 'strh r0, [r2]',
      0xE1DF20B0: 'ldrh r2, [pc, #0]',
    };
    cases.forEach((word, expected) {
      test('0x${word.toRadixString(16)}', () {
        // 解码器用制表符对齐助记符与操作数，比对时归一化空白
        expect(_norm(decodeArm(word).text), expected);
      });
    });
  });

  group('Thumb 指令（与 objdump 对齐）', () {
    const cases = <int, String>{
      0x2001: 'movs r0, #1',
      0x2102: 'movs r1, #2',
      0x4478: 'add r0, pc',
      0x4770: 'bx lr',
      0x1C40: 'adds r0, r0, #1',
      0x3004: 'adds r0, #4',
      0x2A00: 'cmp r2, #0',
      0x4290: 'cmp r0, r2',
      0x0080: 'lsls r0, r0, #2',
      0x1080: 'asrs r0, r0, #2',
      0x6800: 'ldr r0, [r0, #0]',
      0x6841: 'ldr r1, [r0, #4]',
      0xB510: 'push {r4, lr}',
      0xBD10: 'pop {r4, pc}',
      0xC8FF: 'ldmia r0, {r0, r1, r2, r3, r4, r5, r6, r7}',
      0xDF00: 'svc 0',
      0x46C0: 'nop',
    };
    cases.forEach((half, expected) {
      test('0x${half.toRadixString(16)}', () {
        expect(_norm(decodeThumb(half).text), expected);
      });
    });
  });

  group('分支目标', () {
    test('Thumb 无条件跳转：PC 相对 + 4', () {
      // 0xE000 在偏移 0：目标 = 0 + 4 + 0*2 = 4
      final b = Uint8List.fromList([0x00, 0xE0, 0, 0]);
      final line = ArmDisassembler(b).decode(0, DisasmMode.thumb)!;
      expect(line.target, 4);
      expect(line.isBranch, isTrue);
      expect(_norm(line.text), 'b.n 0x8000004');
    });

    test('ARM 跳转：PC 相对 + 8 且按字对齐', () {
      // 0xEA000002：imm=2 → 目标 = 0 + 8 + 2*4 = 16
      final b = Uint8List.fromList([0x02, 0x00, 0x00, 0xEA]);
      final line = ArmDisassembler(b).decode(0, DisasmMode.arm)!;
      expect(line.target, 16);
      expect(_norm(line.text), 'b 0x8000010');
    });

    test('条件跳转带条件后缀', () {
      final b = Uint8List.fromList([0x10, 0xD0, 0, 0]);
      final line = ArmDisassembler(b).decode(0, DisasmMode.thumb)!;
      expect(line.text.startsWith('beq'), isTrue, reason: line.text);
    });
  });

  group('字面池取数标注真实值', () {
    test('Thumb ldr r0, [pc, #imm] 附带目标地址与取值', () {
      // offset0: 4801 = ldr r0, [pc, #4] → 目标 (0+4)&~3 + 4 = 8
      final b = Uint8List.fromList([0x01, 0x48, 0, 0, 0x68, 0x47, 0x78, 0x56,
                                    0x34, 0x12, 0, 0]);
      final line = ArmDisassembler(b).decode(0, DisasmMode.thumb)!;
      expect(line.text, contains('[pc, #4]'));
      expect(line.text, contains('0x08000008'));
      // 目标偏移 8 处是 0x1234（小端），后面 0x56 是下一条指令的字节
      expect(line.text, contains('0x00001234'), reason: '标注取到的字');
    });
  });

  group('搜索与分页', () {
    test('按汇编文本搜索能命中多条', () {
      // 两段 ldr r0, [r0]（0x6800）夹一条 movs r0, #1（0x2001）
      final b = Uint8List.fromList([
        0x00, 0x68, 0x01, 0x20, 0x00, 0x68, 0x00, 0x00,
      ]);
      final hits = ArmDisassembler(b).search('ldr r0', DisasmMode.thumb);
      expect(hits, [0, 4], reason: '0x6800 = ldr r0, [r0, #0]');
    });

    test('搜索忽略大小写', () {
      final b = Uint8List.fromList([0x70, 0x47, 0x00, 0x00]);
      expect(ArmDisassembler(b).search('BX LR', DisasmMode.thumb), [0]);
    });

    test('空查询返回空', () {
      final b = Uint8List.fromList([0x70, 0x47]);
      expect(ArmDisassembler(b).search('   ', DisasmMode.thumb), isEmpty);
    });

    test('disassemble 到 ROM 结尾会停下，不越界', () {
      final b = Uint8List.fromList([0x70, 0x47, 0x00]);
      final lines = ArmDisassembler(b).disassemble(0, DisasmMode.thumb, 10);
      expect(lines.length, 1, reason: '只剩 1 条完整指令');
    });
  });

  group('真实 ROM：能反汇编且不崩', () {
    /// 五个版本的真实 ROM 上跑一遍：整段反汇编不抛、搜索有命中。
    test('五个 ROM 的 Thumb/ARM 反汇编都不越界', () {
      final dir =
          Directory(_dir);
      final roms = dir
          .listSync()
          .whereType<File>()
          .where((f) =>
              f.path.contains('1692 -') ||
              f.path.contains('1235') ||
              f.path.contains('0979') ||
              f.path.contains('0378') ||
              f.path.contains('The Last Promise'))
          .toList();
      expect(roms.length, greaterThanOrEqualTo(5));
      for (final f in roms) {
        final data = Uint8List.fromList(f.readAsBytesSync());
        final edit = EditableRom.open(data, FeRom.detectTable(data)!);
        final dis = ArmDisassembler(edit.buffer.data);
        for (final mode in DisasmMode.values) {
          // 从 ROM 开头与中间各翻一屏
          for (final off in [0, 0x1000, 0x100000]) {
            if (off >= dis.length) continue;
            final lines = dis.disassemble(off, mode, 64);
            expect(lines, isNotEmpty, reason: '${f.path} $mode');
            for (final l in lines) {
              expect(l.bytes.length, mode.size);
              expect(l.text, isNotEmpty);
            }
          }
        }
      }
    });

    test('TLP 的 0x1000 处是成形的 Thumb 函数体', () {
      // 该处实测是 ldr [pc,#16] / ldrb / strb / pop 的一段真实代码
      final dir =
          Directory(_dir);
      final f = dir
          .listSync()
          .whereType<File>()
          .firstWhere((e) => e.path.contains('The Last Promise'));
      final data = Uint8List.fromList(f.readAsBytesSync());
      final edit = EditableRom.open(data, FeRom.detectTable(data)!);
      final lines =
          ArmDisassembler(edit.buffer.data).disassemble(0x1000, DisasmMode.thumb, 8);
      final text = lines.map((l) => l.text).join('\n');
      expect(text, contains('ldr'));
      expect(text, contains('pc'));
      expect(lines.where((l) => l.text.contains('???')), isEmpty,
          reason: '真实代码区不应出现未知指令');
    });

    test('搜索能在真实 ROM 里找到大量 push（Thumb 函数序言）', () {
      final dir =
          Directory(_dir);
      final f = dir
          .listSync()
          .whereType<File>()
          .firstWhere((e) => e.path.contains('1692 -'));
      final data = Uint8List.fromList(f.readAsBytesSync());
      final edit = EditableRom.open(data, FeRom.detectTable(data)!);
      final hits = ArmDisassembler(edit.buffer.data)
          .search('push', DisasmMode.thumb, limit: 50);
      expect(hits.length, greaterThan(10));
    });
  });

  group('反汇编页界面', () {
    testWidgets('页面能渲染，并显示加址/机器码/汇编三列', (tester) async {
      final data = File('$_dir/1692 - 火炎之纹章-圣魔之光石 '
              'Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba')
          .readAsBytesSync();
      final edit = EditableRom.open(data, FeRom.detectTable(data)!);
      await tester.pumpWidget(MaterialApp(home: DisasmPage(edit: edit)));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('反汇编查看器'), findsOneWidget);
      expect(find.text('Thumb'), findsOneWidget);
      expect(find.text('ARM'), findsOneWidget);
      expect(find.text('上一屏'), findsOneWidget);
      // 「下一屏」在列表末尾，首屏看不到；滚动到底再断言
      await tester.fling(find.byType(ListView), const Offset(0, -20000), 5000);
      await tester.pumpAndSettle();
      expect(find.text('下一屏'), findsOneWidget);
      // 至少渲染出几条地址（08000000 形式）
      expect(find.textContaining('0800'), findsWidgets);
    });

    testWidgets('切换 ARM/Thumb 不会崩', (tester) async {
      final data = File('$_dir/1692 - 火炎之纹章-圣魔之光石 '
              'Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba')
          .readAsBytesSync();
      final edit = EditableRom.open(data, FeRom.detectTable(data)!);
      await tester.pumpWidget(MaterialApp(home: DisasmPage(edit: edit)));
      await tester.tap(find.text('ARM'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('每个行 ARM 4 字节'.replaceAll('每个行 ', '每行 ')),
          findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('空搜索给出提示而不是崩', (tester) async {
      final data = File('$_dir/1692 - 火炎之纹章-圣魔之光石 '
              'Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba')
          .readAsBytesSync();
      final edit = EditableRom.open(data, FeRom.detectTable(data)!);
      await tester.pumpWidget(MaterialApp(home: DisasmPage(edit: edit)));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byIcon(Icons.search));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('请输入要搜索'), findsOneWidget);
    });
  });

  group('自动识别指令集（跳转时切换用）', () {
    test('Thumb 函数序言能判成 Thumb', () {
      // 0xB510 (push {r4, lr}) 开始，后面是真实 Thumb 指令
      final b = Uint8List.fromList([
        0x10, 0xB5, 0x00, 0x20, 0x01, 0x21, 0x02, 0x22, 0x70, 0x47,
      ]);
      expect(guessModeAt(b, 0), DisasmMode.thumb);
    });

    test('ARM 函数序言能判成 ARM', () {
      // 典型的 ARM 函数体：push {r4, r5, lr} / 几条数据处理 / bx lr
      final words = [
        0xE92D4030, // push {r4, r5, lr}
        0xE1A05000, // mov r5, r0
        0xE3A04001, // mov r4, #1
        0xE2844001, // add r4, r4, #1
        0xE3540005, // cmp r4, #5
        0xBAFFFFFB, // blt -4
        0xE8BD8030, // pop {r4, r5, pc}
        0xE12FFF1E, // bx lr
      ];
      final b = Uint8List(words.length * 4);
      for (var i = 0; i < words.length; i++) {
        final w = words[i];
        b[i * 4] = w & 0xFF;
        b[i * 4 + 1] = (w >> 8) & 0xFF;
        b[i * 4 + 2] = (w >> 16) & 0xFF;
        b[i * 4 + 3] = (w >> 24) & 0xFF;
      }
      expect(guessModeAt(b, 0), DisasmMode.arm);
    });

    test('数据不足时回退到指定模式', () {
      final b = Uint8List.fromList([0, 1, 2]);
      expect(guessModeAt(b, 0, fallback: DisasmMode.arm), DisasmMode.arm);
      expect(guessModeAt(b, 0), DisasmMode.thumb);
    });

    test('真实 ROM：TLP 的 0x1000 判成 Thumb（该处实测是 Thumb 函数体）', () {
      final f = File(
              '$_dir/The Last Promise v1.5汉化版.gba')
          .readAsBytesSync();
      final edit = EditableRom.open(f, FeRom.detectTable(f)!);
      expect(guessModeAt(edit.buffer.data, 0x1000), DisasmMode.thumb);
    });
  });

  group('改机器码（可撤销）', () {
    EditableRom openFe8() {
      final data = File('$_dir/1692 - 火炎之纹章-圣魔之光石 '
              'Fire Emblem - Seima no Kouseki(JP)(Nintendo)(128Mb).gba')
          .readAsBytesSync();
      return EditableRom.open(data, FeRom.detectTable(data)!);
    }

    test('writeInstruction 逐字节写入并记录 edits', () {
      final edit = openFe8();
      final before = edit.buffer.u8(0x1000);
      final changed = edit.writeInstruction(0x1000, [0x70, 0x47]);
      expect(changed, greaterThan(0));
      expect(edit.buffer.u8(0x1000), 0x70);
      expect(edit.buffer.u8(0x1001), 0x47);
      expect(edit.edits, isNotEmpty);
      // 撤销后逐字节还原
      edit.revertAll();
      expect(edit.buffer.u8(0x1000), before);
    });

    test('写完立即生效：反汇编读出的是新指令', () {
      final edit = openFe8();
      // 0x4770 = bx lr
      edit.writeInstruction(0x1000, [0x70, 0x47]);
      final line = ArmDisassembler(edit.buffer.data).decode(0x1000, DisasmMode.thumb)!;
      expect(line.text.replaceAll('\t', ' ').trim(), 'bx lr');
    });

    test('内容相同不产生新改动（幂等）', () {
      final edit = openFe8();
      final cur = [edit.buffer.u8(0x1000), edit.buffer.u8(0x1001)];
      expect(edit.writeInstruction(0x1000, cur), 0);
      expect(edit.edits, isEmpty);
    });

    test('越界写入被拒绝（不崩溃）', () {
      final edit = openFe8();
      expect(edit.writeInstruction(edit.buffer.length - 1, [0, 0]), 0);
      expect(edit.writeInstruction(-1, [0, 0]), 0);
    });
  });

  group('函数追踪（调用链与字面池）', () {
    test('能收集 bl 目标', () {
      final words = [0xE92D4000, 0xEB000000, 0xE12FFF1E];
      final b = Uint8List(16);
      for (var i = 0; i < words.length; i++) {
        b[i * 4] = words[i] & 0xFF;
        b[i * 4 + 1] = (words[i] >> 8) & 0xFF;
        b[i * 4 + 2] = (words[i] >> 16) & 0xFF;
        b[i * 4 + 3] = (words[i] >> 24) & 0xFF;
      }
      final node = traceFunction(b, 0, DisasmMode.arm);
      // bl 在偏移 4，ARM 下目标 = 4 + 8 + 0 = 12
      expect(node.calls, [12]);
    });

    test('Thumb 的 pop {pc} 视为函数结束', () {
      final b = Uint8List.fromList([
        0x10, 0xB5, // push {r4, lr}
        0x00, 0x20, // movs r0, #0
        0x10, 0xBD, // pop {r4, pc}
      ]);
      final node = traceFunction(b, 0, DisasmMode.thumb);
      expect(node.returns, isTrue);
      expect(node.calls, isEmpty);
    });

    test('字面池引用被抓出来', () {
      // ldr r0, [pc, #0] 后跟一个 ASCII 指针值
      // ldr r0, [pc, #4]：目标 = (0+4)&~3 + 4 = 8
      final b = Uint8List.fromList([
        0x01, 0x48, // 0x4801
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x40, 0x00, 0x00, 0x08, // 偏移 8：0x08000040
        0x70, 0x47,
      ]);
      final node = traceFunction(b, 0, DisasmMode.thumb);
      expect(node.literals, hasLength(1));
      expect(node.literals.first.value, 0x08000040);
      // romPointersIn 会把「像 GBA 指针且在 ROM 内」的值挑出来：
      // 这里给一个足够大的虚拟 ROM 长度
      expect(romPointersIn(node, 0x1000000), hasLength(1));
      expect(romPointersIn(node, b.length), isEmpty,
          reason: 'ROM 只有十几字节时 0x08000040 超出范围');
    });

    test('真实 ROM：TLP 0x1000 能追出可点击的调用目标', () {
      final data = File('$_dir/The Last Promise v1.5汉化版.gba').readAsBytesSync();
      final node = traceFunction(data, 0x1000, DisasmMode.thumb);
      // 至少能扫出若干条指令（该处是真实代码），并且调用目标在 ROM 内
      for (final c in node.calls) {
        expect(c, greaterThanOrEqualTo(0));
        expect(c, lessThan(data.length));
      }
      expect(node.literals, isNotEmpty,
          reason: '该函数开头就是 ldr rX, [pc, #N] 读字面池');
    });
  });

  group('地址解析（页面跳转用）', () {
    test('接受 GBA 地址与文件偏移两种写法', () {
      const len = 0x01000000;
      expect(parseRomAddress('8000000', len), 0);
      expect(parseRomAddress('0x08000000', len), 0);
      expect(parseRomAddress('0x1234', len), 0x1234);
      expect(parseRomAddress('1234', len), 0x1234);
      expect(parseRomAddress('', len), isNull);
      expect(parseRomAddress('zzz', len), isNull);
      // 超出 ROM 长度
      expect(parseRomAddress('0x08000000', len), 0);
      expect(parseRomAddress('1FFFFFFFF', len), isNull);
    });
  });
}
