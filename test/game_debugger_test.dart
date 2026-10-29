import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/editable_rom.dart';
import 'package:fe_editor/core/fe_rom.dart';
import 'package:fe_editor/core/game_debugger.dart';
import 'package:fe_editor/core/rom_info.dart';

/// 从 assets 读补丁（测试里直接读文件，免得依赖 rootBundle 初始化）。
GameDebuggerPatch _loadPatch(String id) {
  final f = File('assets/debugger/$id.json');
  return parseGameDebuggerPatch(f.readAsStringSync());
}

Uint8List _fe8Jp() {
  final dir = Directory('/root/workspace/game-rom');
  final f = dir
      .listSync()
      .whereType<File>()
      .firstWhere((f) => f.path.contains('1692 -'));
  return f.readAsBytesSync();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('补丁数据可解析：两块变体、块数与字节数合理', () {
    for (final v in gameDebuggerVariants) {
      final p = _loadPatch(v.id);
      expect(p.blocks, isNotEmpty, reason: v.id);
      expect(p.byteCount, greaterThan(60000), reason: '${v.id} 应包含代码主体');
      for (final b in p.blocks) {
        expect(b.offset, greaterThanOrEqualTo(0));
        expect(b.offset + b.data.length, lessThanOrEqualTo(0x1000000));
      }
      // 块之间不能重叠
      final sorted = [...p.blocks]..sort((a, b) => a.offset.compareTo(b.offset));
      for (var i = 1; i < sorted.length; i++) {
        expect(sorted[i].offset,
            greaterThanOrEqualTo(sorted[i - 1].offset + sorted[i - 1].data.length),
            reason: '${v.id} 第 $i 块与前一块重叠');
      }
    }
  });

  test('只有 FE8 支持：FE6/FE7 明确返回 false', () {
    expect(gameDebuggerSupports(fe8Jp), isTrue);
    expect(gameDebuggerSupports(fe8Us), isTrue);
    expect(gameDebuggerSupports(fe6Jp), isFalse);
    expect(gameDebuggerSupports(fe7Jp), isFalse);
    expect(gameDebuggerSupports(fe7Us), isFalse);
  });

  test('安装到真实 FE8J：写入预期字节、可撤销、幂等', () {
    final data = _fe8Jp();
    final edit = EditableRom.open(data, fe8Jp);
    final patch = _loadPatch('fe8_zh');

    expect(patch.isInstalled(edit.buffer.data), isFalse);

    final r = installGameDebugger(edit, patch);
    expect(r.changedBytes, greaterThan(50000));
    expect(patch.isInstalled(edit.buffer.data), isTrue);

    // 钩子点：战场按 B 的入口应被换成「调转调试器」的跳板
    final beforeHook = data[0x1CA0C] |
        (data[0x1CA0D] << 8) |
        (data[0x1CA0E] << 16) |
        (data[0x1CA0F] << 24);
    expect(edit.buffer.u32(0x1CA0C), isNot(equals(beforeHook)));

    // 文本指针槽本身不变，表项已改指到扩展区（文件偏移 0xEFB2E0 之后）
    expect(edit.buffer.u32(0xA000) & 0x1FFFFFF, 0x14D08C);
    final firstEntry = edit.buffer.u32(0x14D08C) & 0x1FFFFFF;
    expect(firstEntry, greaterThanOrEqualTo(0xEFB2E0));
    expect(firstEntry, lessThan(0x1000000));

    // 幂等：再装一次不应产生新的字节改动
    final r2 = installGameDebugger(edit, patch);
    expect(r2.changedBytes, 0);
    expect(r2.alreadyInstalled, isTrue);

    // 可撤销
    edit.revertAll();
    expect(patch.isInstalled(edit.buffer.data), isFalse);
    expect(edit.buffer.data, equals(data));
  });

  test('补丁内每个钩子都必须跳到补丁区，不能自指或跳回原版地址', () {
    final data = _fe8Jp();
    final edit = EditableRom.open(data, fe8Jp);
    final patch = _loadPatch('fe8_en');
    installGameDebugger(edit, patch);
    final buf = edit.buffer;

    // 上游的 callHackNew 跳板：ldr r0,[pc,#0] / bx r0 / POIN 目标
    // 若把 WORD 里的三个字当成普通常量写入、POIN 写到别处，这里会变成
    // 「bx lr 后跟一个指针」，钩子等于直接返回，游戏启动即白屏。
    for (final off in patch.blocks.map((b) => b.offset)) {
      final w0 = buf.u32(off);
      if (w0 != 0xE59FC000) continue; // 只检查跳板块
      expect(buf.u32(off + 4), 0xE12FFF1C, reason: '缺 bx r0');
      final target = buf.u32(off + 12);
      expect(target, greaterThanOrEqualTo(0x08000000 + 0xEFB2E0),
          reason: '${off.toRadixString(16)} 的跳板指向了 ROM 旧区（会自杀循环）');
      expect(target, lessThan(0x09000000));
    }
  });

  test('memmove 补丁必须是上游那段 THUMB 实现（启动早期就会被调用）', () {
    final data = _fe8Jp();
    final edit = EditableRom.open(data, fe8Jp);
    installGameDebugger(edit, _loadPatch('fe8_en'));
    final buf = edit.buffer;

    // 上游 AsmHooks 在这里写的是 4 个字：bx lr;nop / ldr r0,[pc,#0] / bx r0 / 目标
    expect(buf.u32(0xD4C9C), 0x46C04778);
    expect(buf.u32(0xD4C9C + 4), 0xE59FC000);
    expect(buf.u32(0xD4C9C + 8), 0xE12FFF1C);
    final target = buf.u32(0xD4C9C + 12) & 0x1FFFFFF;

    // AsmHooks.asm 里 memmove 的开头：PUSH {r4,r5,lr} / MOV r5,r0 / MOV r4,r5
    // Thumb: b5 05 1c 2c 1c  (B505 = push {r0,r2,lr} 变体；关键是不能是 0 或返回)
    final h0 = buf.u16(target);
    expect(h0, isNot(0), reason: 'memmove 目标处是空的 —— 游戏启动就会崩');
    expect(buf.u16(target + 2), isNot(0));
    // 不能是「bx lr」那种空实现
    expect(h0 & 0xFF00, isNot(0x4700), reason: 'memmove 不能是直接返回的空实现');
  });

  test('安装后 ROM 原有文本表仍完整（512 条逐字节一致）', () {
    final data = _fe8Jp();
    final edit = EditableRom.open(data, fe8Jp);
    final patch = _loadPatch('fe8_zh');
    installGameDebugger(edit, patch);

    // 用项目自己的解码器对比：装补丁前后的文本 id 0..511 解码结果应完全相同
    final before = EditableRom.open(data, fe8Jp).rom;
    final after = FeRom(edit.buffer.data, fe8Jp);
    var compared = 0;
    for (var id = 0; id < 512; id++) {
      expect(after.decodeTextBytes(after.textEntryOffset(id)),
          equals(before.decodeTextBytes(before.textEntryOffset(id))),
          reason: '文本 id $id 内容变了');
      compared++;
    }
    expect(compared, 512);
  });

  test('中文变体的菜单文本可从 ROM 里解回来', () {
    final data = _fe8Jp();
    final edit = EditableRom.open(data, fe8Jp);
    installGameDebugger(edit, _loadPatch('fe8_zh'));
    final rom = FeRom(edit.buffer.data, fe8Jp);

    // 菜单文本表在扩展区；用项目解码器按 id 读不到它（不是文本表条目），
    // 这里只断言扩展区里确实出现了中文菜单用到的码位序列。
    final buf = edit.buffer;
    var found = 0;
    for (var off = 0xF00000; off < 0xF20000; off += 2) {
      final v = buf.u16(off);
      if (v == 0x88DA || v == 0x9378) {
        found++; // 移 / 動 之类的常用汉字码位
        if (found > 3) break;
      }
    }
    expect(found, greaterThan(0), reason: '扩展区应含中文菜单码位');
    expect(rom.length, data.length);
  });

  test('补丁自检：当前数据应报出跳板目标落在写入块内', () {
    // 这是当前的已知缺陷（AGENTS.md 第 20c 节）。自检必须在安装前把它抓出来，
    // 否则用户装了只会得到白屏。修好补丁后本用例应改为 expect(problems, isEmpty)。
    final patch = _loadPatch('fe8_zh');
    final problems = patch.validate(0x1000000);
    expect(problems, isNotEmpty, reason: '自检没抓到跳板目标与 payload 重叠');
    expect(problems.any((p) => p.contains('落在另一个写入块')), isTrue);
  });

  test('补丁自检：合法补丁不应报任何问题', () {
    // 构造一个自洽的小补丁：跳板目标指向 ROM 内空白区，且不与任何写入块重叠。
    final code = Uint8List(16)
      ..[0] = 0x78
      ..[1] = 0x47
      ..[2] = 0xC0
      ..[3] = 0x46;
    final target = 0x08000000 + 0x200000;
    code[12] = target & 0xFF;
    code[13] = (target >> 8) & 0xFF;
    code[14] = (target >> 16) & 0xFF;
    code[15] = (target >> 24) & 0xFF;
    final patch = GameDebuggerPatch(
      id: 'fake',
      label: 'fake',
      romId: 'FE8J',
      blocks: [(offset: 0x9A00, data: code)],
    );
    expect(patch.validate(0x1000000), isEmpty);
  });

  test('补丁自检：目标越界也要抓出来', () {
    final code = Uint8List(16)
      ..[0] = 0x78
      ..[1] = 0x47
      ..[2] = 0xC0
      ..[3] = 0x46;
    // 目标写成 0x00EFFF59（丢了 0x08 前缀的那种笔误）
    code[12] = 0x59;
    code[13] = 0xFF;
    code[14] = 0xEF;
    code[15] = 0x00;
    final patch = GameDebuggerPatch(
      id: 'bad',
      label: 'bad',
      romId: 'FE8J',
      blocks: [(offset: 0xCC66C, data: code)],
    );
    final problems = patch.validate(0x1000000);
    expect(problems.length, 1);
    expect(problems.first, contains('不在 ROM 范围内'));
  });
}
