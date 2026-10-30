import 'dart:typed_data';

/// 反汇编模式：GBA 是 ARM7TDMI，代码里 ARM 与 Thumb 两套指令集混用。
enum DisasmMode {
  arm('ARM', 4),
  thumb('Thumb', 2);

  final String label;

  /// 单条指令占的字节数。
  final int size;
  const DisasmMode(this.label, this.size);

  DisasmMode get other => this == arm ? thumb : arm;
}

/// 一条反汇编结果。
class DisasmLine {
  /// 文件偏移。
  final int offset;

  /// 原始机器码字节（ARM 4 字节、Thumb 2 字节）。
  final Uint8List bytes;

  /// 反汇编文本，如 `ldr r0, [r1, #0x4]`。
  final String text;

  /// 分支类指令的目标偏移（`b` / `bl` / 条件跳转），否则 -1。
  final int target;

  /// 目标要按哪种指令集解释（跳过去时用）。
  ///
  /// 静态能确定的只有三类：Thumb 的 `bl` 目标必为 Thumb；ARM 的 `bl` 目标也
  /// 是 ARM（除非被 `bx` 转过去）；`bx Rn` 的目标来自寄存器，静态无从得知。
  /// 所以这里用 [ArmDisassembler.guessModeAt] 做「目标处像不像 Thumb」的启发式，
  /// 由调用方（页面）在跳转时决定要不要切。
  final DisasmMode? targetMode;

  const DisasmLine({
    required this.offset,
    required this.bytes,
    required this.text,
    this.target = -1,
    this.targetMode,
  });

  /// GBA 地址形式（0x08xxxxxx）。
  int get address => offset + 0x08000000;

  String get hex =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join();

  bool get isBranch => target >= 0;

  String get addressText =>
      address.toRadixString(16).toUpperCase().padLeft(8, '0');
}

/// ARM7TDMI 反汇编器（ARM + Thumb 两套指令集）。
///
/// 只做**反汇编展示**：把机器码翻译成助记符，不做符号解析、不追踪调用链。
/// 数据区域按同样规则硬解会得到无意义指令（游戏数据被当代码），
/// 这是反汇编器的固有行为——看原始字节请用十六进制视图。
///
/// 编码规则按 ARM 架构参考手册（ARMv4T）实现；
/// 助记符与操作数顺序对齐 GNU objdump 的输出（便于交叉核对）。
class ArmDisassembler {
  final Uint8List data;

  ArmDisassembler(this.data);

  int get length => data.length;

  static int u16(Uint8List d, int at) =>
      (at >= 0 && at + 2 <= d.length) ? d[at] | (d[at + 1] << 8) : 0;

  static int u32(Uint8List d, int at) => (at >= 0 && at + 4 <= d.length)
      ? (d[at] | (d[at + 1] << 8) | (d[at + 2] << 16) | (d[at + 3] << 24)) &
          0xFFFFFFFF
      : 0;

  /// 反汇编一条指令；超出数据结尾返回 null。
  DisasmLine? decode(int offset, DisasmMode mode) {
    if (offset < 0) return null;
    if (mode == DisasmMode.arm) {
      if (offset + 4 > data.length) return null;
      final w = u32(data, offset);
      final d = _arm(w, offset);
      return DisasmLine(
        offset: offset,
        bytes: Uint8List.fromList(data.sublist(offset, offset + 4)),
        text: d.text,
        target: d.target,
      );
    }
    if (offset + 2 > data.length) return null;
    final h = u16(data, offset);
    final d = _thumb(h, offset);
    return DisasmLine(
      offset: offset,
      bytes: Uint8List.fromList(data.sublist(offset, offset + 2)),
      text: d.text,
      target: d.target,
    );
  }

  /// 从 [offset] 起反汇编 [count] 条指令。
  List<DisasmLine> disassemble(int offset, DisasmMode mode, int count) {
    final out = <DisasmLine>[];
    var at = offset;
    for (var i = 0; i < count; i++) {
      final line = decode(at, mode);
      if (line == null) break;
      out.add(line);
      at += mode.size;
    }
    return out;
  }

  /// 按反汇编文本搜索，返回命中行的偏移。
  ///
  /// 反汇编没有固定行首（换一个起点每条指令都变），所以从 [from] 起
  /// 按当前位置逐条解码比对；最多返回 [limit] 条。
  List<int> search(
    String needle,
    DisasmMode mode, {
    int from = 0,
    int limit = 200,
  }) {
    final out = <int>[];
    final q = needle.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (q.isEmpty) return out;
    var at = from < 0 ? 0 : from;
    // 对齐到指令边界，避免从半个指令开始解
    at -= at % mode.size;
    // ignore: unnecessary_statements
    while (at + mode.size <= data.length && out.length < limit) {
      final line = decode(at, mode);
      if (line == null) break;
      // 解码文本用制表符对齐，搜索前统一成单空格，否则「ldr r0」匹配不到「ldr\tr0」
      final hay = line.text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      if (hay.contains(q)) out.add(at);
      at += mode.size;
    }
    return out;
  }

  // ---------- ARM ----------

  static const List<String> _conds = [
    'eq', 'ne', 'cs', 'cc', 'mi', 'pl', 'vs', 'vc',
    'hi', 'ls', 'ge', 'lt', 'gt', 'le', '', '',
  ];

  ({String text, int target}) _arm(int w, int offset) {
    final cond = (w >> 28) & 0xF;
    if (cond == 0xF) {
      // ARMv5 扩展（BLX 等），GBA（ARMv4T）上不存在，按未知处理
      return (
text: '???\t0x${_hexw(w)}', target: -1);
    }
    final cc = _conds[cond];
    final hi = (w >> 25) & 0x7; // bits 27..25
    final top2 = (w >> 26) & 0x3; // bits 27..26

    // 数据处理 + 乘法/交换/半字传送（bits 27..26 == 00）
    //
    // 这一大类里 bit25=1 一律是数据处理（立即数）；bit25=0 时要看 bit4：
    // bit4=1 才是 乘法/交换/半字传送，bit4=0 是寄存器型数据处理。
    if (top2 == 0x0) {
      // bits27..26=00 的分派按 ARM ARM 的位模式：
      //   立即数数据处理            bit25=1
      //   数据处理（寄存器移位）      bit25=0, bit4=0
      //   数据处理（寄存器移位）      bit25=0, bit4=1, bits[6:5]!=00
      //   乘法 / 交换 / 半字传送      bit25=0, bit4=1, bits[6:5]==00
      // 判据是 bits[6:5]（不是 bit7）：`0xE0132051`（ands r2,r3,r1,asr r0）
      // bits[6:5]=10 属于数据处理，而乘法 `0xE0000192` 的 bits[6:5]=00。
      // 先试半字/有符号字节传送：它的判据很窄（bit25=0、bits[7:4] 为
      // 1011/1101/1111、bits[6:5]=00），不会误伤数据处理。
      if (((w >> 25) & 1) == 0) {
        final hw0 = _armHalfword(w, cc, offset);
        if (hw0 != null) return hw0;
      }
      final isDataProc = ((w >> 25) & 1) == 1 ||
          ((w >> 4) & 1) == 0 ||
          (((w >> 5) & 0x3) != 0x0);
      if (!isDataProc) {
        final hw = _armHalfword(w, cc, offset);
        if (hw != null) return hw;
        final mul = _armMultiply(w, cc);
        if (mul != null) return mul;
        // 既不是乘法/交换/半字传送，就仍按数据处理解释
        // （`0xE1A00413` = lsl r0, r3, r4 就是这一类）
        return _armDataProcessing(w, cc, cond);
      }
      return _armDataProcessing(w, cc, cond);
    }

    // 单数据传送（bits 27..26 == 01 → top2 == 0x1，但 top2 只有 2 位，
    // 所以这里要用完整条件：bit27=0 / bit26=1）
    if (((w >> 26) & 0x3) == 0x1) return _armSingleTransfer(w, cc, offset);

    // 块传送（bits 27..25 == 100）
    if (hi == 0x4) {
      final pre = (w >> 24) & 1;
      final up = (w >> 23) & 1;
      final wb = (w >> 21) & 1;
      final load = (w >> 20) & 1;
      final rn = (w >> 16) & 0xF;
      // objdump 的写法：ia 省略后缀；SP 的 ia 存/ib 取写成 push/pop
      // objdump 的后缀：P=1,U=1 → ib；P=1,U=0 → db；P=0,U=1 → ia（省略）；
      // P=0,U=0 → da。GBA 上的 push 就是 STMDB（P=1,U=0）。
      // objdump：ia 且无写回（W=0）时省略后缀（`stm r0, {...}`），
      // ia 带写回才写 `stmia`（`stmia r0!, {...}`）。
      final ia = pre == 0 && up == 1;
      // LDM 的 ia 一律省略（`ldm r0!, {...}`）；STM 只在写回时写 `stmia`。
      final suffix = ia
          ? (load == 1 ? '' : (wb == 1 ? 'ia' : ''))
          : (pre == 1 ? (up == 1 ? 'ib' : 'db') : 'da');
      // bit22（S）在 LDM 里表示恢复用户模式寄存器，objdump 用 ^ 标记
      final userMode = ((w >> 22) & 1) == 1;
      final list = _regList(w & 0xFFFF);
      // push/pop 缩写只用于「满减/满增」：STMDB sp! / LDMIA sp!
      final isPush = load == 0;
      final isPop = load == 1;
      final shorthand = (isPush && pre == 1 && up == 0 && wb == 1) ||
          (isPop && pre == 0 && up == 1 && wb == 1);
      if (rn == 13 && shorthand) {
        final name = isPop ? 'pop' : 'push';
        return (text: '$name$cc\t$list', target: -1);
      }
      final name = load == 1 ? 'ldm' : 'stm';
      return (
        text: '$name$suffix$cc\t${_r(rn)}${wb == 1 ? '!' : ''}, '
            '$list${userMode ? '^' : ''}',
        target: -1,
      );
    }

    // 分支（bits 27..25 == 101）
    if (hi == 0x5) {
      final link = ((w >> 24) & 1) == 1;
      var imm = w & 0xFFFFFF;
      if ((imm & 0x800000) != 0) imm -= 0x1000000;
      final target = offset + 8 + imm * 4;
      final name = link ? 'bl' : 'b';
      return (
text: '$name$cc\t0x${(0x08000000 + target).toRadixString(16)}',
        target: target,
      );
    }

    // 软中断（bits 27..24 == 1111）
    if (((w >> 24) & 0xF) == 0xF) {
      return (
text: 'svc$cc\t0x${(w & 0xFFFFFF).toRadixString(16).padLeft(8, '0')}',
        target: -1,
      );
    }

    // 协处理器 / 未定义
    return (text: '???\t0x${_hexw(w)}', target: -1);
  }

  static const List<String> _dataOps = [
    'and', 'eor', 'sub', 'rsb', 'add', 'adc', 'sbc', 'rsc',
    'tst', 'teq', 'cmp', 'cmn', 'orr', 'mov', 'bic', 'mvn',
  ];

  ({String text, int target}) _armDataProcessing(int w, String cc, int cond) {
    final opcode = (w >> 21) & 0xF;
    final s = ((w >> 20) & 1) == 1;
    final rn = (w >> 16) & 0xF;
    final rd = (w >> 12) & 0xF;
    final imm = ((w >> 25) & 1) == 1;

    final op = _dataOps[opcode];
    // objdump 的顺序是「操作码 + s + 条件」：ands eq → andseq
    final sfx = '${s ? 's' : ''}$cc';

    // 操作数
    String op2;
    var movShiftName = '';
    var movShiftImm = 0;
    if (imm) {
      // objdump 对可放入 8 位立即数的值用有符号十进制（>0x80000000 时为负）
      final v = _rorImm(w);
      op2 = v <= 0xFF ? '#$v' : '#${v > 0x7FFFFFFF ? v - 0x100000000 : v}';
    } else {
      final rm = w & 0xF;
      final regShift = ((w >> 4) & 1) == 1;
      final st = (w >> 5) & 0x3;
      const stNames = ['lsl', 'lsr', 'asr', 'ror'];
      if (regShift) {
        op2 = '${_r(rm)}, ${stNames[st]} ${_r((w >> 8) & 0xF)}';
        movShiftName = stNames[st];
        movShiftImm = -1; // 移位量来自寄存器
      } else {
        final amount = (w >> 7) & 0x1F;
        // 移位量 0 的语义：lsl 不移位、lsr/asr 是 32、ror 是 RRX
        if (amount == 0 && st == 3) {
          op2 = _r(rm);
          movShiftName = 'rrx';
          movShiftImm = 0;
        } else if (amount == 0 && st == 0) {
          op2 = _r(rm);
        } else if (amount == 0 && (st == 1 || st == 2)) {
          op2 = '${_r(rm)}, ${stNames[st]} #32';
          movShiftName = stNames[st];
          movShiftImm = 32;
        } else {
          op2 = '${_r(rm)}, ${stNames[st]} #$amount';
          movShiftName = stNames[st];
          movShiftImm = amount;
        }
      }
    }

    // cmp/cmn/tst/teq 没有目标寄存器，也不用 rn 作第一操作数
    final noRd = opcode >= 0x8 && opcode <= 0xB;
    if (noRd) {
      // cmp r0, r1（objdump 不带 s）
      return (text: '$op$cc\t${_r(rn)}, $op2', target: -1);
    }
    // objdump 把带移位量的 mov 直接显示成移位指令本身
    if (opcode == 0xD && movShiftName.isNotEmpty && !imm) {
      final first = op2.split(', ').first;
      // 移位量 0 的 lsr/asr 是 #32
      final shiftText = movShiftImm == 0 && movShiftName != 'lsl' &&
              movShiftName != 'rrx'
          ? 32
          : movShiftImm;
      if (movShiftName == 'rrx') {
        return (text: 'rrx$sfx\t${_r(rd)}, $first', target: -1);
      }
      if (movShiftImm == -1 || shiftText == -1) {
        // 移位量来自寄存器：mov r0, r3, asr r4 → asr r0, r3, r4
        final reg = op2.split(RegExp(r'\s+')).last;
        return (
          text: '$movShiftName$sfx\t${_r(rd)}, $first, $reg',
          target: -1,
        );
      }
      return (
text: '$movShiftName$sfx\t${_r(rd)}, $first, #$shiftText',
        target: -1,
      );
    }
    // mov r0, r0 且没有 s 就是 nop
    if (opcode == 0xD &&
        !imm &&
        !s &&
        rd == 0 &&
        (w & 0xFFF) == 0 &&
        cc.isEmpty) {
      return (text: 'nop', target: -1);
    }
    if (opcode == 0xD || opcode == 0xF) {
      // mov / mvn 只有目标与操作数
      return (text: '$op$sfx\t${_r(rd)}, $op2', target: -1);
    }
    return (text: '$op$sfx\t${_r(rd)}, ${_r(rn)}, $op2', target: -1);
  }

  ({String text, int target})? _armMultiply(int w, String cc) {
    final bits27to22 = (w >> 22) & 0x3F;
    final bits7to4 = (w >> 4) & 0xF;
    // 乘法（MUL/MLA）与长乘法：bits[7:4] == 1001
    if (bits7to4 == 0x9 && bits27to22 == 0x0) {
      final acc = ((w >> 21) & 1) == 1;
      final s = ((w >> 20) & 1) == 1;
      final rd = (w >> 16) & 0xF;
      final rn = (w >> 12) & 0xF;
      final rs = (w >> 8) & 0xF;
      final rm = w & 0xF;
      final name = acc ? 'mla' : 'mul';
      final args = acc ? 'r$rd, r$rm, r$rs, r$rn' : 'r$rd, r$rm, r$rs';
      return (text: '$name$cc${s ? 's' : ''}\t$args', target: -1);
    }
    if (bits7to4 == 0x9 && ((w >> 23) & 0x1F) == 0x1) {
      final sign = ((w >> 22) & 1) == 1;
      final acc = ((w >> 21) & 1) == 1;
      final s = ((w >> 20) & 1) == 1;
      final rdHi = (w >> 16) & 0xF;
      final rdLo = (w >> 12) & 0xF;
      final rs = (w >> 8) & 0xF;
      final rm = w & 0xF;
      final name = sign
          ? (acc ? 'smlal' : 'smull')
          : (acc ? 'umlal' : 'umull');
      return (
        text: '$name$cc${s ? 's' : ''}\tr$rdLo, r$rdHi, r$rm, r$rs',
        target: -1,
      );
    }
    // 交换：bits[7:4] == 1001 且 bits[27:23] == 00010
    if (bits7to4 == 0x9 && ((w >> 23) & 0x1F) == 0x2) {
      final byte = ((w >> 22) & 1) == 1;
      final rn = (w >> 16) & 0xF;
      final rd = (w >> 12) & 0xF;
      final rm = w & 0xF;
      return (
text: 'swp$cc${byte ? 'b' : ''}\tr$rd, r$rm, [r$rn]',
        target: -1,
      );
    }
    return null;
  }

  /// 半字 / 有符号字节传送（bits[7:4] = 1xx1，排除 1001）。
  ({String text, int target})? _armHalfword(int w, String cc, int offset) {
    final bits27to25 = (w >> 25) & 0x7;
    if (bits27to25 != 0x0) return null;
    final bits7to4 = (w >> 4) & 0xF;
    // bits[7:4] 的 SH 位组合：1011=H、1101=SB、1111=SH（bit7 与 bit4 都为 1）
    if (!const {0xB, 0xD, 0xF}.contains(bits7to4)) return null;
    // 半字传送（ARM ARM A5.2「Extra load/store」）：
    // bit25=0，bits[7:4] 的 bit7 与 bit4 必须都是 1，且 bits[6:5]!=00
    // 时也不是乘法/交换 —— 实测 `0xE1D200B0`（ldrh r0,[r2]）bits[6:5]=01，
    // 所以这里只看 bits[7] 与 bits[4]，不看 bits[6:5]。
    // `0xE1A00413`（lsl）的 bits[7]=0，不会被误判。
    if (((w >> 7) & 1) != 1 || ((w >> 4) & 1) != 1) return null;
    final pre = ((w >> 24) & 1) == 1;
    final up = ((w >> 23) & 1) == 1;
    final imm = ((w >> 22) & 1) == 1;
    final wb = ((w >> 21) & 1) == 1;
    final load = ((w >> 20) & 1) == 1;
    final rn = (w >> 16) & 0xF;
    final rd = (w >> 12) & 0xF;

    final name = switch (bits7to4) {
      0xB => load ? 'ldrh' : 'strh',
      0xD => load ? 'ldrsb' : 'strh',
      _ => load ? 'ldrsh' : 'strh',
    };
    final off = imm ? ((w >> 4) & 0xF0) | (w & 0xF) : 0;
    final offText = imm ? _imm(off) : _r(w & 0xF);
    final negOff = up ? offText : _negOffNum(offText, off);
    final rnText = _r(rn);
    String addr;
    if (pre) {
      addr = (imm && off == 0 && !wb && rn != 0xF)
          ? '[$rnText]'
          : '[$rnText, $negOff]${wb ? '!' : ''}';
    } else {
      addr = '[$rnText], $negOff';
    }
    return (text: '$name$cc\t${_r(rd)}, $addr', target: -1);
  }

  ({String text, int target}) _armSingleTransfer(int w, String cc, int offset) {
    // 单数据传送（LDR/STR）的编码：bits27..26=01，bit25=I（0=立即数偏移，1=寄存器偏移）
    final imm = ((w >> 25) & 1) == 0;
    final pre = ((w >> 24) & 1) == 1;
    final up = ((w >> 23) & 1) == 1;
    final byte = ((w >> 22) & 1) == 1;
    final wb = ((w >> 21) & 1) == 1;
    final load = ((w >> 20) & 1) == 1;
    final rn = (w >> 16) & 0xF;
    final rd = (w >> 12) & 0xF;

    String off;
    var offValue = 0;
    final zeroOffset = imm && (w & 0xFFF) == 0;
    if (imm) {
      offValue = w & 0xFFF;
      off = offValue <= 0xFF
          ? '#$offValue'
          : '#${offValue.toRadixString(16).toUpperCase()}';
    } else {
      final rm = w & 0xF;
      final st = (w >> 5) & 0x3;
      const stNames = ['lsl', 'lsr', 'asr', 'ror'];
      final amount = (w >> 7) & 0x1F;
      final shifted = ((w >> 4) & 1) == 1;
      if (shifted && amount > 0) {
        off = '${_r(rm)}, ${stNames[st]} #$amount';
      } else if (shifted && amount == 0 && (st == 1 || st == 2)) {
        off = '${_r(rm)}, ${stNames[st]} #32';
      } else {
        off = _r(rm);
      }
    }
    // 后索引（P=0）且 W=0 时是用户模式传送，objdump 写作 ldrt/strt
    // LDRT/STRT：P=0（后索引）且 W=1（bit21=1，此时不是写回而是 T 位）
    final tSuffix = (!pre && wb) ? 't' : '';
    final name = (load ? 'ldr' : 'str') + (byte ? 'b' : '') + tSuffix;
    // 字面池读取：PC 相对（U=1），标出真实地址与取到的值
    if (rn == 0xF && imm && pre && up) {
      final base = (offset + 8) & ~3;
      final target = up ? base + offValue : base - offValue;
      return (
        text: '$name$cc\t${_r(rd)}, [pc, ${_imm(target - ((offset + 8) & ~3))}]'
            '${wb ? '!' : ''}'
            '\t@ =0x${_hex(0x08000000 + target)}'
            ' (0x${_hex(u32(data, target))})',
        target: -1,
      );
    }

    final negOff =
        up ? off : (imm ? _negOffNum(off, offValue) : _negOffReg(off));
    final rnText = _r(rn);
    String addr;
    if (pre) {
      if (zeroOffset && !wb) {
        addr = '[$rnText]';
      } else {
        addr = '[$rnText, $negOff]${wb ? '!' : ''}';
      }
    } else {
      addr = '[$rnText], $negOff';
    }
    return (text: '$name$cc\t${_r(rd)}, $addr', target: -1);
  }

  // ---------- Thumb ----------

  ({String text, int target}) _thumb(int h, int offset) {
    // Thumb 的格式按 bits[15:12] 分派（ARM ARM A5.1）。
    // 【关键】`0x4018` 这类 ALU 指令的 op 是 0x4，而 `0x1C40` 是 add 立即数，
    // 所以判断必须看完整的 bits[15:10]，不能只看高 4 位就分支。
    final top = (h >> 12) & 0xF;

    // 格式 1：移位立即数（bits15..13 = 000）
    if ((h >> 13) == 0x0) {
      final sub = (h >> 11) & 0x3;
      if (sub == 0x0) {
        // lsl rd, rs, #imm5（imm5=0 时 objdump 显示 movs）
        final amount = (h >> 6) & 0x1F;
        final rs = (h >> 3) & 0x7;
        final rd = h & 0x7;
        if (amount == 0) return (text: 'movs\tr$rd, r$rs', target: -1);
        return (text: 'lsls\tr$rd, r$rs, #$amount', target: -1);
      }
      if (sub == 0x1) {
        // lsr rd, rs, #imm5（0 视为 32）
        final amount = (h >> 6) & 0x1F;
        final rs = (h >> 3) & 0x7;
        final rd = h & 0x7;
        return (
          text: 'lsrs\tr$rd, r$rs, #${amount == 0 ? 32 : amount}',
          target: -1
        );
      }
      if (sub == 0x2) {
        final amount = (h >> 6) & 0x1F;
        final rs = (h >> 3) & 0x7;
        final rd = h & 0x7;
        return (
text: 'asrs\tr$rd, r$rs, #${amount == 0 ? 32 : amount}',
        target: -1,
      );
      }
    }

    // 格式 2：add/sub rd, rs, #imm3 或 rd, rs, rn（bits15..11 = 00011）
    if ((h >> 11) == 0x3) {
      final imm3 = ((h >> 10) & 1) == 1;
      final isSub = ((h >> 9) & 1) == 1;
      final name = isSub ? 'subs' : 'adds';
      final rs = (h >> 3) & 0x7;
      final rd = h & 0x7;
      if (imm3) {
        return (
text: '$name\tr$rd, r$rs, #${(h >> 6) & 0x7}', target: -1);
      }
      return (text: '$name\tr$rd, r$rs, r${(h >> 6) & 0x7}', target: -1);
    }

    // 格式 3：mov/cmp/add/sub 立即数（bits15..13 = 001）
    if ((h >> 13) == 0x1) {
      final sub = (h >> 11) & 0x3;
      const names = ['movs', 'cmp', 'adds', 'subs'];
      final rd = (h >> 8) & 0x7;
      return (text: '${names[sub]}\tr$rd, #${h & 0xFF}', target: -1);
    }

    // 格式 4：ALU（bits15..10 = 010000）
    if ((h >> 10) == 0x10) {
      final aluOp = (h >> 6) & 0xF;
      final rs = (h >> 3) & 0x7;
      final rd = h & 0x7;
      const names = [
        'ands', 'eors', 'lsls', 'lsrs', 'asrs', 'adcs', 'sbcs', 'rors',
        'tst', 'negs', 'cmp', 'cmn', 'orrs', 'muls', 'bics', 'mvns',
      ];
      return (text: '${names[aluOp]}\tr$rd, r$rs', target: -1);
    }

    // 格式 5：高寄存器操作 / BX（bits15..10 = 010001）
    if ((h >> 10) == 0x11) {
      if (h == 0x46C0) return (text: 'nop', target: -1);
      final sub = (h >> 8) & 0x3;
      final rs = (h >> 3) & 0xF;
      final rd = (h & 0x7) | (((h >> 7) & 1) << 3);
      if (sub == 0x3) {
        final rm = (h >> 3) & 0xF;
        return (text: 'bx\t${_r(rm)}', target: -1);
      }
      const names = ['add', 'cmp', 'mov'];
      return (text: '${names[sub]}\t${_r(rd)}, ${_r(rs)}', target: -1);
    }

    // 格式 6：PC 相对取数（bits15..11 = 01001）
    if ((h >> 11) == 0x09) {
      final rd = (h >> 8) & 0x7;
      final imm = (h & 0xFF) * 4;
      final base = (offset + 4) & ~3;
      final target = base + imm;
      return (
        text: 'ldr\tr$rd, [pc, #$imm]\t@ =0x0${(0x08000000 + target).toRadixString(16)}'
            ' (0x${_hex(u32(data, target))})',
        target: -1,
      );
    }

    // 格式 7/8：寄存器偏移的装/存（bits15..12 = 0101）
    if (top == 0x5) {
      final ro = (h >> 6) & 0x7;
      final rb = (h >> 3) & 0x7;
      final rd = h & 0x7;
      final name = _thumbLoadStore(h);
      return (
text: '$name\tr$rd, [r$rb, r$ro]', target: -1);
    }

    // 格式 9：立即数偏移的装/存（ARM ARM A5.1 表 5.3）
    //   bits[15:11]  指令
    //   01100        STR
    //   01101        LDR
    //   01110        STRB
    //   01111        LDRB
    //   10000        STRH
    //   10001        LDRH
    // 其余（0111x/1001x 之外）不属于本格式。偏移 scale：字节类 ×1，其余 ×4。
    if (top >= 0x6 && top <= 0x9) {
      final key = (h >> 11) & 0x1F;
      final byteOp = key == 0x0E || key == 0x0F;
      final halfOp = key == 0x10 || key == 0x11;
      if (!byteOp && !halfOp && key != 0x0C && key != 0x0D) {
        return (text: '???\t0x${_hexh(h)}', target: -1);
      }
      final load = key == 0x0D || key == 0x0F || key == 0x11;
      final name = halfOp
          ? (load ? 'ldrh' : 'strh')
          : (byteOp
              ? (load ? 'ldrb' : 'strb')
              : (load ? 'ldr' : 'str'));
      final imm = (h >> 6) & 0x1F;
      final off = byteOp ? imm : imm * 4;
      final rb = (h >> 3) & 0x7;
      final rd = h & 0x7;
      return (text: '$name\tr$rd, [r$rb, #$off]', target: -1);
    }

    // 格式 10：SP 相对装/存（bits15..12 = 1001）
    if (top == 0x9) {
      final load = ((h >> 11) & 1) == 1;
      final rd = (h >> 8) & 0x7;
      final imm = (h & 0xFF) * 4;
      return (
        text: '${load ? 'ldr' : 'str'}\tr$rd, [sp, #$imm]',
        target: -1,
      );
    }

    // 格式 11：add rd, pc/sp, #imm（bits15..12 = 1010）
    if (top == 0xA) {
      final sp = ((h >> 11) & 1) == 1;
      final rd = (h >> 8) & 0x7;
      final imm = (h & 0xFF) * 4;
      return (
text: 'add\t${_r(rd)}, ${sp ? 'sp' : 'pc'}, #$imm',
        target: -1,
      );
    }

    // 格式 12/13：调整 SP / 压栈出栈（bits15..12 = 1011）
    if (top == 0xB) {
      if ((h & 0xFF00) == 0xB000) {
        final neg = ((h >> 7) & 1) == 1;
        final imm = (h & 0x7F) * 4;
        return (
text: '${neg ? 'sub' : 'add'}\tsp, #$imm', target: -1);
      }
      if ((h & 0xF600) == 0xB400) {
        final pop = ((h >> 11) & 1) == 1;
        final regs = _thumbRegList(h & 0xFF,
            extra: ((h >> 8) & 1) == 1 ? (pop ? 'pc' : 'lr') : null);
        return (text: '${pop ? 'pop' : 'push'}\t$regs', target: -1);
      }
      if (h == 0xBF00) return (text: 'nop', target: -1);
      if (h == 0x46C0) return (text: 'nop', target: -1);
      if ((h & 0xFF00) == 0xBE00) {
        return (
          text: 'bkpt\t0x${(h & 0xFF).toRadixString(16).padLeft(4, '0')}',
        target: -1,
      );
      }
      return (
text: '???\t0x${_hexh(h)}', target: -1);
    }

    // 格式 14：多寄存器装/存（bits15..12 = 1100）
    if (top == 0xC) {
      final load = ((h >> 11) & 1) == 1;
      final rb = (h >> 8) & 0x7;
      final list = _thumbRegList(h & 0xFF);
      return (
        // objdump 对 Thumb 的 ldmia/stmia 都不写 `!`（写回是隐含的），
        // 只有空寄存器列表时才补上（`ldmia r0!, {}`）
        text: '${load ? 'ldmia' : 'stmia'}\t${_r(rb)}'
            '${list == '{}' ? '!' : ''}, $list',
        target: -1,
      );
    }

    // 格式 15：条件分支 / SWI（bits15..12 = 1101）
    if (top == 0xD) {
      final cond = (h >> 8) & 0xF;
      if (cond == 0xF) {
        return (
text: 'svc\t${h & 0xFF}',
        target: -1,
      );
      }
      if (cond == 0xE) {
        return (text: 'udf\t#${h & 0xFF}', target: -1);
      }
      var imm = h & 0xFF;
      if ((imm & 0x80) != 0) imm -= 0x100;
      final target = offset + 4 + imm * 2;
      const cnames = [
        'beq', 'bne', 'bcs', 'bcc', 'bmi', 'bpl', 'bvs', 'bvc',
        'bhi', 'bls', 'bge', 'blt', 'bgt', 'ble',
      ];
      return (
        text: '${cnames[cond]}.n\t0x${(0x08000000 + target).toRadixString(16)}',
        target: target,
      );
    }

    // 格式 16/17：无条件分支（bits15..11 = 11100）
    if ((h >> 11) == 0x1C) {
      var imm = h & 0x7FF;
      if ((imm & 0x400) != 0) imm -= 0x800;
      final target = offset + 4 + imm * 2;
      return (
text: 'b.n\t0x${(0x08000000 + target).toRadixString(16)}',
        target: target,
      );
    }

    // 格式 18/19：长分支（BL 两条半字）
    // 第一半 11110 + 高位偏移，第二半 11111 + 低位偏移；目标 = PC + 偏移。
    if ((h >> 11) == 0x1E) {
      final next = u16(data, offset + 2);
      if ((next >> 11) == 0x1F) {
        var hi = h & 0x7FF;
        if ((hi & 0x400) != 0) hi -= 0x800;
        final lo = next & 0x7FF;
        final target = offset + 4 + (hi << 12) + (lo << 1);
        return (
text: 'bl\t0x${(0x08000000 + target).toRadixString(16)}',
        target: target,
      );
      }
      // 没有配对的第二半：如实显示原始码
      return (text: '0x${_hexh(h)}\t\t@ 长跳转前半（无配对）', target: -1);
    }
    if ((h >> 11) == 0x1F) {
      return (text: '0x${_hexh(h)}\t\t@ 长跳转后半（无配对）', target: -1);
    }

    return (text: '???\t0x${_hexh(h)}', target: -1);
  }

  /// 格式 7/8 的助记符：bits[11:9] 决定 op（000=STR 001=STRH 010=STRB
  /// 011=LDRSB 100=LDR 101=LDRH 110=LDRB 111=LDRSH）。
  static String _thumbLoadStore(int h) {
    switch ((h >> 9) & 0x7) {
      case 0x0:
        return 'str';
      case 0x1:
        return 'strh';
      case 0x2:
        return 'strb';
      case 0x3:
        return 'ldrsb';
      case 0x4:
        return 'ldr';
      case 0x5:
        return 'ldrh';
      case 0x6:
        return 'ldrb';
      default:
        return 'ldrsh';
    }
  }

  ({String text, int target}) _thumbShiftAddSub(int h) {
    final sub = (h >> 11) & 0x3;
    if (sub == 0x0 || sub == 0x1) {
      // 左移 / 右移（逻辑、算术）
      final st = sub == 0x0 ? 0 : ((h >> 10) & 0x1) + 1; // 0=lsl 1=lsr 2=asr
      const names = ['lsl', 'lsr', 'asr'];
      final amount = (h >> 6) & 0x1F;
      final rs = (h >> 3) & 0x7;
      final rd = h & 0x7;
      final shown = amount == 0 && st != 0 ? 32 : amount;
      return (text: '${names[st]}s\tr$rd, r$rs, #$shown', target: -1);
    }
    // add/sub 寄存器或 3 位立即数
    final imm3 = ((h >> 10) & 1) == 1;
    final isSub = ((h >> 9) & 1) == 1;
    final name = isSub ? 'sub' : 'add';
    final rs = (h >> 3) & 0x7;
    final rd = h & 0x7;
    if (imm3) {
      return (text: '${name}s\tr$rd, r$rs, #${(h >> 6) & 0x7}', target: -1);
    }
    return (text: '${name}s\tr$rd, r$rs, r${(h >> 6) & 0x7}', target: -1);
  }

  ({String text, int target}) _thumbAlu(int h) {
    final aluOp = (h >> 6) & 0xF;
    final rs = (h >> 3) & 0x7;
    final rd = h & 0x7;
    const names = [
      'and', 'eor', 'lsl', 'lsr', 'asr', 'adc', 'sbc', 'ror',
      'tst', 'neg', 'cmp', 'cmn', 'orr', 'mul', 'bic', 'mvn',
    ];
    final name = names[aluOp];
    // 移位类 ALU（lsl/lsr/asr/ror）按 objdump 的写法带 s
    final withS = aluOp != 0x8 && aluOp != 0xA && aluOp != 0xB;
    final sfx = withS ? 's' : '';
    return (text: '$name$sfx\tr$rd, r$rs', target: -1);
  }

  ({String text, int target}) _thumbHiReg(int h) {
    final sub = (h >> 8) & 0x3;
    final rs = (h >> 3) & 0xF;
    final rd = (h & 0x7) | (((h >> 7) & 1) << 3);
    switch (sub) {
      case 0x0:
        return (text: 'add\tr$rd, r$rs', target: -1);
      case 0x1:
        return (text: 'cmp\tr$rd, r$rs', target: -1);
      case 0x2:
        return (text: 'mov\tr$rd, r$rs', target: -1);
      default:
        return (text: 'bx\tr$rs', target: -1);
    }
  }

  ({String text, int target}) _thumbLoadStoreReg(int h) {
    final isByte = ((h >> 12) & 1) == 1;
    final isSign = ((h >> 9) & 1) == 1;
    final isLoad = ((h >> 11) & 1) == 1;
    final ro = (h >> 6) & 0x7;
    final rb = (h >> 3) & 0x7;
    final rd = h & 0x7;
    final name = isSign
        ? (isByte ? 'ldrsb' : 'ldrsh')
        : '${isLoad ? 'ldr' : 'str'}${isByte ? 'b' : ''}';
    return (text: '$name\tr$rd, [r$rb, r$ro]', target: -1);
  }

  ({String text, int target}) _thumbLongBranch(int h, int offset, bool hi) {
    final next = h & 0x7FF;
    var v = next;
    if ((v & 0x400) != 0) v -= 0x800;
    // BL 由两条半字组成；这里只表示第一半，不强行算完整目标
    return (
      text: 'bl\t\t@ 长跳转（${hi ? '第 2' : '第 1'} 半）',
      target: -1,
    );
  }

  // ---------- 格式化 ----------

  /// 寄存器的惯用名（objdump 用 sp/lr/pc 而不是 r13/r14/r15）。
  static String _r(int i) => switch (i) {
        10 => 'sl',
        11 => 'fp',
        12 => 'ip',
        13 => 'sp',
        14 => 'lr',
        15 => 'pc',
        _ => 'r$i',
      };

  static String _regList(int list) {
    final regs = <String>[];
    for (var i = 0; i < 16; i++) {
      if ((list & (1 << i)) != 0) regs.add(_r(i));
    }
    return '{${regs.join(', ')}}';
  }

  static String _thumbRegList(int list, {String? extra}) {
    final regs = <String>[];
    for (var i = 0; i < 8; i++) {
      if ((list & (1 << i)) != 0) regs.add('r$i');
    }
    if (extra != null) regs.add(extra);
    return '{${regs.join(', ')}}';
  }

  static int _rorImm(int w) {
    final imm = w & 0xFF;
    final rot = ((w >> 8) & 0xF) * 2;
    if (rot == 0) return imm;
    return ((imm >> rot) | (imm << (32 - rot))) & 0xFFFFFFFF;
  }

  /// 8 位十六进制（地址、机器码）
  /// 把偏移写成 objdump 风格：正数 `#12`，负数 `#-12`。
  static String _negateOff(String off, int? value) {
    if (!off.startsWith('#')) return off;
    final body = off.substring(1);
    return body.startsWith('-') ? off : '#-$body';
  }

  /// 寄存器偏移取负：`r0` → `-r0`。
  static String _negOffReg(String off) => '-$off';

  /// 把偏移文本取负：`#12`/`#0xC` → `#-12`/`#-0xC`；寄存器偏移原样返回。
  static String _negOffNum(String off, int value) {
    if (!off.startsWith('#')) return off;
    if (value <= 0xFF) return '#-$value';
    return '#-0x${value.toRadixString(16).toUpperCase()}';
  }

  /// 8 位十六进制（地址、原始字）。
  static String _hex(int? v) =>
      (v ?? 0).toRadixString(16).toUpperCase().padLeft(8, '0');

  /// 小立即数：objdump 用 `#0x4`（不超过 4 位十六进制）。
  static String _imm(int v) {
    if (v >= 0 && v <= 9) return '#$v';
    if (v <= 255) return '#0x${v.toRadixString(16).toUpperCase()}';
    return '#0x${v.toRadixString(16).toUpperCase()}';
  }

  static String _hexw(int w) => w.toRadixString(16).padLeft(8, '0');

  static String _hexh(int h) => h.toRadixString(16).padLeft(4, '0');

  static String _gba(int offset) =>
      (offset + 0x08000000).toRadixString(16).toUpperCase().padLeft(8, '0');
}

/// 解析用户输入的地址：接受 `8000000`、`0x08000000`（GBA 地址）与
/// 纯十六进制文件偏移。超出 ROM 长度返回 null。
///
/// 反汇编页的「跳转」与十六进制页共用同一种输入习惯。
int? parseRomAddress(String raw, int romLength) {
  var s = raw.trim().toLowerCase();
  if (s.isEmpty) return null;
  if (s.startsWith('0x')) s = s.substring(2);
  s = s.replaceAll(RegExp(r'[^0-9a-f]'), '');
  if (s.isEmpty) return null;
  final v = int.tryParse(s, radix: 16);
  if (v == null) return null;
  if (v >= 0x08000000 && v < 0x08000000 + romLength) return v - 0x08000000;
  if (v >= 0 && v < romLength) return v;
  return null;
}

/// 猜测 [offset] 处是 Thumb 还是 ARM 代码（启发式，用于跳转时自动切换）。
///
/// 判据（按可靠性排序，命中即返回）：
/// 1. **指令密度**：分别按两种模式解 24 条，统计「合法且有意义的比例」
///    （`???` / `udf` / 明显的非法编码算坏）。真实代码区的合法率通常在 90%+，
///    错模式会明显掉下来。
/// 2. **函数序言/尾声特征**：Thumb 常见 `push {..., lr}`（`0xB5xx`）与
///    `bx lr`（`0x4770`）；ARM 常见 `push`（`0xE92D4xxx`）与 `bx lr`（`0xE12FFF1E`）。
/// 3. 打平时回退到 [fallback]。
DisasmMode guessModeAt(Uint8List data, int offset, {DisasmMode? fallback}) {
  // 数据不够判断（不足 8 字节，解不出 6 条）时直接用调用方给的回退值
  if (offset < 0 || offset + 8 > data.length) {
    return fallback ?? DisasmMode.thumb;
  }
  final dis = ArmDisassembler(data);
  double score(DisasmMode m) {
    final lines = dis.disassemble(offset, m, 24);
    if (lines.length < 6) return 0;
    var good = 0;
    for (final l in lines) {
      final t = l.text;
      if (t.startsWith('???')) continue;
      if (t.startsWith('udf') || t.contains('无配对')) continue;
      good += 1;
    }
    return good / lines.length;
  }

  final thumbScore = score(DisasmMode.thumb);
  final armScore = score(DisasmMode.arm);

  // 特征加成：序言/尾声越典型，加分越多
  double bonus(DisasmMode m) {
    var b = 0.0;
    for (var i = 0; i < 6; i++) {
      final line = dis.decode(offset + i * m.size, m);
      if (line == null) break;
      final t = line.text;
      if (m == DisasmMode.thumb) {
        if (t.startsWith('push') && t.contains('lr')) b += 0.15;
        if (t.startsWith('bx lr') || t.startsWith('bx\tlr')) b += 0.1;
      } else {
        if (t.startsWith('push') || t.contains('stmdb sp!')) b += 0.15;
        if (t.contains('bx lr') || t == 'bx\tlr') b += 0.1;
      }
    }
    return b;
  }

  final t = thumbScore + bonus(DisasmMode.thumb);
  final a = armScore + bonus(DisasmMode.arm);
  if ((t - a).abs() < 0.05) return fallback ?? DisasmMode.thumb;
  return t > a ? DisasmMode.thumb : DisasmMode.arm;
}

/// Thumb 的 `bl` 目标偏移（去掉最低位），供页面跳转用。
int thumbBranchTarget(int offset, int half) {
  var imm = half & 0x7FF;
  if ((imm & 0x400) != 0) imm -= 0x800;
  return offset + 4 + imm * 2;
}

/// 一次「从函数入口往回跟」的结果：调用了谁、被谁调用、引用了哪些数据。
class CallGraphNode {
  final int offset;

  /// 该函数里 `bl`/`bx` 的目标（去重、按出现顺序）。
  final List<int> calls;

  /// 字面池读取的地址与取值（如字符串指针、跳转表）。
  final List<({int addr, int value})> literals;

  /// 该函数里直接 `bx lr` 返回，说明是一个完整函数。
  final bool returns;

  const CallGraphNode({
    required this.offset,
    required this.calls,
    required this.literals,
    required this.returns,
  });
}

/// 从 [offset] 起线性扫一段代码，收集调用目标与字面池引用。
///
/// 这是**启发式**而非真正的反编译：
/// - 遇到 `bx lr` / `pop {..., pc}` / `b` 到自身以外（尾调用）就认为函数结束；
/// - `bl` 目标记进 [CallGraphNode.calls]（若是 Thumb 地址会去掉最低位）；
/// - `ldr rX, [pc, #N]` 记进 literals（值看起来像 GBA/常量池指针的会标出来）。
///
/// 不做「被谁调用」的反向扫描——那需要全 ROM 扫描并区分代码/数据，
/// 在改版上误报太多，收益不如直接把调用链摊开看。
CallGraphNode traceFunction(
  Uint8List data,
  int offset,
  DisasmMode mode, {
  int maxInstructions = 400,
}) {
  final dis = ArmDisassembler(data);
  final calls = <int>[];
  final literals = <({int addr, int value})>[];
  var returns = false;

  for (var i = 0; i < maxInstructions; i++) {
    final at = offset + i * mode.size;
    final line = dis.decode(at, mode);
    if (line == null) break;
    final t = line.text;
    if (line.target >= 0) {
      // 分支：bl 是调用（记下来），其它是控制流跳转
      if (t.startsWith('bl')) {
        final target = mode == DisasmMode.thumb
            ? (line.target & ~1)
            : line.target;
        if (target >= 0 && target < data.length && !calls.contains(target)) {
          calls.add(target);
        }
      }
    }
    // 字面池：文本里有 `@ =0x.....` 标注
    // 文本形如 `ldr r0, [pc, #4]\t@ =0x08000008 (0x12345678)`
    final m = RegExp(r'@\s*=0x([0-9A-Fa-f]+)').firstMatch(t);
    if (m != null) {
      final addr = int.parse(m.group(1)!, radix: 16) - 0x08000000;
      final val = _u32At(data, addr);
      if (!literals.any((l) => l.addr == addr)) {
        literals.add((addr: addr, value: val));
      }
    }
    // 函数结束判据
    if (t.startsWith('bx lr') || t.startsWith('pop') && t.contains('pc')) {
      returns = true;
      break;
    }
    // 无条件 b 到自身以外：多半是尾调用，视为函数结束
    if (mode == DisasmMode.thumb && t.startsWith('b.n') && line.target >= 0) {
      if (line.target < offset || line.target > at) break;
    }
  }
  return CallGraphNode(
    offset: offset,
    calls: calls,
    literals: literals,
    returns: returns,
  );
}

int _u32At(Uint8List d, int at) => ArmDisassembler.u32(d, at);

/// 从字面池里挑出「看起来像数据指针」的项（GBA 地址或 ROM 内偏移）。
List<({int addr, int value})> romPointersIn(CallGraphNode node, int romLength) =>
    node.literals
        .where((l) =>
            (l.value >= 0x08000000 && l.value < 0x08000000 + romLength) ||
            (l.value >= 0 && l.value < romLength && l.value > 0x1000))
        .toList();
