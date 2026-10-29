#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mini-EA build for the Vesly debugger (FE8 first).

Pass 1 (layout): parse statements, compute unit sizes & label offsets (relative).
Pass 2 (emit):   assign free-space starts (4-aligned, sequential), resolve labels/POINs,
                  write everything into a ROM copy, extend the Huffman tree, re-encode text.

Unit model (EA semantics, verified against Installer.event + lyn payloads):
  - free units: placed sequentially in free space, 4-byte aligned
  - ORG $hex:          new fixed unit
  - ORG CURRENTOFFSET+N: relative jump inside current unit (no new unit)
  - ORG <expr w/ labels>: new unit whose target is computed at emit time (no free slot)
  - labels start new free units only at top level (outside PUSH context)
  - POIN value: CURRENTOFFSET expressions are offset-space (+0x08000000 on write);
                labels / symtab / 0x8... constants are GBA-absolute (raw write)
"""
import re, os

GBA_BASE = 0x08000000

def u16(b, o): return int.from_bytes(b[o:o+2], 'little')
def u32(b, o): return int.from_bytes(b[o:o+4], 'little')

EVENT_OPS = {'CHECK_EVENTID', 'BNE', 'ENUF', 'ENUT', 'GOTO', 'ENDA', 'SVAL',
             'TUTORIALTEXTBOXSTART', 'TEXTSHOW', 'TEXTEND', 'REMA', 'NOFADE',
             'SETSAVESLOTFLAG'}

class Unit:
    __slots__ = ('fixed', 'data', 'pos', 'start', 'poin_jobs', 'string_jobs',
                 'org_expr', 'org_ref', 'labels_here', 'lit_jobs', 'kind')
    def __init__(self, fixed=None):
        self.fixed = fixed
        self.data = bytearray()
        self.pos = 0
        self.start = None
        self.poin_jobs = []      # (offset, [targets])
        self.string_jobs = []    # (offset, text, tbl)
        self.org_expr = None     # computed target expression
        self.org_ref = None      # (ref_unit, ref_pos) for CURRENTOFFSET in org_expr
        self.labels_here = []    # (name, offset)
        self.lit_jobs = []       # (offset, int value, nbytes) for WORD/SHORT/BYTE literals
        self.kind = 'fixed' if fixed is not None else 'free'

class BE:
    def __init__(self, rom, free_base, symtab, defines):
        self.rom = rom
        self.free_base = free_base
        self.symtab = dict(symtab)      # symbol -> GBA absolute address
        self.defines = dict(defines)
        self.tbls = {}
        self.units = []
        self.labels = {}                # name -> GBA absolute (set at emit)
        self.log = []
        self.cur = None
        self.ctx = []
        self.macro_params = {}
        self._collect_macro_params(0)

    # ---------- preprocessor ----------
    def preprocess(self, text, base_dir):
        lines = []
        stack = []
        for raw in text.split('\n'):
            s = raw.strip()
            if s.startswith('//') or s.startswith('@'):
                continue
            s = re.sub(r'//.*$', '', s).rstrip()   # drop inline comments
            m = re.match(r'#\s*define\s+([A-Za-z_]\w*)\s*\(([^)]*)\)', s)
            if m and all(stack):
                self.macro_params[m.group(1)] = [x.strip() for x in m.group(2).split(',') if x.strip()]
            m = re.match(r'#\s*define\s+([A-Za-z_]\w*)\s*(.*)$', s)
            if m and all(stack):
                self.defines[m.group(1)] = m.group(2).strip()
                continue
            if m:
                continue   # define in an inactive branch: ignore entirely
            m = re.match(r'#\s*include\s+"?([^"\s]+)"?\s*$', s)
            if m:
                if not all(stack):
                    continue
                path = os.path.join(base_dir, m.group(1))
                lines.extend(self.preprocess(open(path, encoding='utf8', errors='replace').read(),
                                              os.path.dirname(path)))
                continue
            m = re.match(r'#\s*inctbl\s+"?(\w+)"?\s+"?([^"\s]+)"?\s*$', s)
            if m:
                if all(stack):
                    self.load_tbl(m.group(1), os.path.join(base_dir, m.group(2)))
                continue
            m = re.match(r'#\s*ifdef\s+(\w+)', s)
            if m: stack.append(m.group(1) in self.defines); continue
            m = re.match(r'#\s*ifndef\s+(\w+)', s)
            if m: stack.append(m.group(1) not in self.defines); continue
            m = re.match(r'#\s*else\b', s)
            if m:
                if stack:
                    stack[-1] = not stack[-1]
                continue
            m = re.match(r'#\s*endif\b', s)
            if m:
                if stack: stack.pop()
                continue
            if all(stack):
                lines.append(s)
        return lines

    def _collect_macro_params(self, depth):
        pass

    def load_tbl(self, name, path):
        tbl = {}
        with open(path, encoding='utf8', errors='replace') as f:
            for line in f:
                s = line.rstrip('\n')
                if '=' not in s: continue
                k, v = s.split('=', 1)
                tbl[int(k.strip(), 16)] = v
        self.tbls[name] = tbl

    # ---------- statement parsing ----------
    def parse_files(self, *paths):
        all_stmts = []
        for p in paths:
            base = os.path.dirname(p)
            lines = self.preprocess(open(p, encoding='utf8', errors='replace').read(), base)
            stmts = []
            for line in lines:
                if not line: continue
                parts = []
                cur = ''
                for pp in line.split(';'):
                    cur += pp + ';'
                    if cur.count('"') % 2 == 0:
                        parts.append(cur[:-1]); cur = ''
                if cur:
                    parts.append(cur)
                for pp in parts:
                    pp = pp.strip()
                    if not pp: continue
                    stmts.append(pp)
            expanded = []
            for st in stmts:
                m = re.match(r'^([A-Za-z_]\w*)\((.*)\)$', st)
                if m and m.group(1) in self.macro_params:
                    body = self.defines[m.group(1)].strip()
                    body = re.sub(r'^\([^)]*\)\s*', '', body)   # drop (params) prefix
                    if body.startswith('"') and body.endswith('"'):
                        body = body[1:-1]
                    pnames = self.macro_params[m.group(1)]
                    avals = self._split_args(m.group(2))
                    for pn, av in zip(pnames, avals):
                        body = re.sub(r'\b%s\b' % re.escape(pn), lambda _m, av=av: av, body)
                    for sub in re.split(';', body):
                        sub = sub.strip()
                        if sub:
                            expanded.append(sub)
                    continue
                expanded.append(st)
            out = []
            for st in expanded:
                m = re.match(r'^([A-Za-z_]\w*):(.*)$', st)
                if m:
                    out.append(('label', m.group(1), m.group(2).strip()))
                else:
                    out.append(('stmt', st))
            all_stmts.extend(out)
        return all_stmts

    @staticmethod
    def _split_args(s):
        args = []; depth = 0; cur = ''; q = False
        for ch in s:
            if ch == '"': q = not q
            elif ch == '(' and not q: depth += 1
            elif ch == ')' and not q: depth -= 1
            if ch == ',' and depth == 0 and not q:
                args.append(cur.strip()); cur = ''
            else:
                cur += ch
        args.append(cur.strip())
        return args

    # ---------- expression evaluator (offset-space; CURRENTOFFSET = file offset) ----------
    def eval(self, expr, curpos):
        expr = expr.strip()
        m = re.match(r'^(CURRENTOFFSET)([+\-])(.+)$', expr)
        if m:
            v = self.eval(m.group(3), curpos)
            return (curpos + v) if m.group(2) == '+' else (curpos - v)
        if expr.startswith('CURRENTOFFSET'):
            return curpos
        if expr.startswith('(') and expr.endswith(')') and self._bal(expr):
            return self.eval(expr[1:-1], curpos)
        # C precedence: | lowest; then + -; then * /; then >>; then &
        i = self._findtop(expr, '|', first=True)
        if i > 0:
            return self.eval(expr[:i], curpos) | self.eval(expr[i+1:], curpos)
        i = self._findtop(expr, '*', first=True)
        if i > 0:
            return self.eval(expr[:i], curpos) * self.eval(expr[i+1:], curpos)
        i = self._findtop(expr, '/', first=True)
        if i > 0:
            return self.eval(expr[:i], curpos) // self.eval(expr[i+1:], curpos)
        i = self._findtop(expr, '>>', first=True)
        if i > 0:
            return (self.eval(expr[:i], curpos) >> self.eval(expr[i+2:], curpos)) & 0xFFFFFFFF
        i = self._findtop(expr, '&', first=True)
        if i > 0:
            return self.eval(expr[:i], curpos) & self.eval(expr[i+1:], curpos)
        i = self._findtop(expr, '+', first=False)
        if i > 0:
            return self.eval(expr[:i], curpos) + self.eval(expr[i+1:], curpos)
        i = self._findtop(expr, '-', first=False)
        if i > 0:
            return self.eval(expr[:i], curpos) - self.eval(expr[i+1:], curpos)
        if re.match(r'^\$[0-9a-fA-F]+$', expr): return int(expr[1:], 16)
        if re.match(r'^0x[0-9a-fA-F]+$', expr): return int(expr[2:], 16)
        if re.match(r'^-?\d+$', expr): return int(expr)
        sym = expr
        # 脚本内定义的 label 必须优先于外部 sym：C 代码会把原版函数重定义成
        # 补丁区里的新实现（BmMain_StartPhase 等），若先查 symtab 就会把钩子
        # 指回原地址 —— 钩子跳自己，游戏启动即死循环/白屏。
        if sym in self.labels:
            return self.labels[sym]      # stored as file offset
        if sym in self.symtab:
            return self.symtab[sym]      # stored as file offset
        if sym in self.defines:
            v = self.defines[sym]
            if v.startswith('"') and v.endswith('"'):
                return self.eval(v[1:-1], curpos)      # plain symbol alias
            if not v.startswith('"'):
                vv = self.eval(v, curpos)
                if vv >= GBA_BASE:
                    vv -= GBA_BASE
                return vv
        raise KeyError('unresolved symbol %r' % sym)

    def _bal(self, s):
        d = 0
        for c in s:
            if c == '(': d += 1
            elif c == ')': d -= 1
        return d == 0

    def _findtop(self, s, opch, first=False):
        d = 0; last = -1; q = False
        i = 0
        n = len(opch)
        while i < len(s):
            c = s[i]
            if c == '"': q = not q; i += 1; continue
            if q:
                i += 1
                continue
            if c == '(':
                d += 1; i += 1; continue
            if c == ')':
                d -= 1; i += 1; continue
            if d == 0 and s[i:i+n] == opch:
                if first: return i
                last = i
                i += n
                continue
            i += 1
        return last

    # ---------- pass 1: layout ----------
    def stmt_size(self, st, cur):
        toks = st.split()
        h = toks[0].upper()
        if h == 'WORD': return 4 * (len(toks) - 1)
        if h == 'SHORT': return 2 * (len(toks) - 1)
        if h == 'BYTE': return len(toks) - 1
        if h == 'POIN':
            if len(toks) < 2:
                raise ValueError('POIN without target: %s' % st)
            return 4 * (len(toks) - 1)
        if h == 'FILL':
            return self.eval(toks[1], 0)
        if h == 'STRING':
            m = re.match(r'STRING\s+"((?:[^"\\]|\\.)*)"\s*(?:"([^"]*)")?', st)
            text = m.group(1); tbl = m.group(2)
            cur.string_jobs.append((cur.pos, text, tbl))
            codes = self.str_codes(text, tbl)
            return 4 * max(1, len(codes))     # upper bound; actual set at emit
        if h.startswith('FILL'):
            m = re.match(r'^FILL\((.+?)\)\s*$', st)
            return self.eval(m.group(1) if m else toks[1], 0)
        if h == 'LABEL':
            return 0
        if h in ('GOTO', 'CHECK_EVENTID', 'BNE', 'ENUF', 'ENUT', 'ENDA', 'SVAL',
                 'TUTORIALTEXTBOXSTART', 'TEXTSHOW', 'TEXTEND', 'REMA', 'NOFADE',
                 'SETSAVESLOTFLAG'):
            return 3
        if h == 'LABEL':
            return 0
        raise ValueError('unknown directive %r' % st[:60])

    def str_codes(self, text, tblname):
        tbl = self.tbls.get(tblname, {}) if tblname else {}
        codes = []
        for ch in text:
            if ch == '\\':
                codes.append(0x01)
                continue
            if tbl:
                found = None
                for code, disp in tbl.items():
                    if ch in disp:
                        found = code
                        break
                if found is None:
                    raise KeyError('char %r not in table %s' % (ch, tblname))
                codes.append(found)
            else:
                codes.append(ord(ch) & 0xFFFF)
        return codes

    def layout(self, stmts):
        for st in stmts:
            if st[0] == 'label':
                if self.cur is None:
                    self.cur = self.new_unit()
                    if self.ctx:
                        self._pushed_unit = self.cur
                pend = getattr(self, '_pending_org_label', None)
                if pend is not None and pend[0] is self.cur:
                    self.cur.labels_here.append((st[1], pend[1]))
                    self._pending_org_label = None
                else:
                    self.cur.labels_here.append((st[1], self.cur.pos))
                continue
            s = st[1]
            h = s.split()[0].upper()
            if h == 'PUSH':
                # 每个 PUSH 开一个新块（上游这是一段独立代码）。
                # 块内可能有一串 `ORG CURRENTOFFSET+N;标签:`：它们只定位标签，
                # 不推进写入位置；POP 之后写的数据就落在同一块的起点之后。
                self.ctx.append(self.cur)
                if self.cur is not None:
                    self._last_unit = self.cur
                self._pending_org_label = None
                self._cursor_rel = 0
                self.cur = None          # 懒建：等第一条真正写数据的语句再建单位，
                self._pushed_unit = None  # 避免 PUSH 后跟 ORG $hex 时留下空块
                continue
            if h == 'POP':
                # POP 之后的数据仍写进「本次 PUSH 开的那个块」，
                # 位置就是该块当前长度（标签定位不占用长度）。
                if self.ctx:
                    prev = self.ctx.pop()
                    u = getattr(self, '_pushed_unit', None)
                    if u is None:
                        # PUSH 段里没有标签（例如只有 ORG $hex），回到外层上下文
                        self.cur = prev
                    else:
                        self._pushed_unit = None
                        # 标签链只是给块内各函数定位；真正的数据从**块起点**开始连续写。
                        # （校验：上游该块标签链末端 0xb5ed，而数据体实长 0xba04，
                        #  说明标签是索引、不是数据起点。）
                        u.pos = 0
                        self.cur = u
                continue
            if h == 'ORG':
                expr = s[3:].strip()
                if expr.startswith('$') or re.match(r'^0x[0-9a-fA-F]+$', expr):
                    self.cur = self.new_unit(int(expr.lstrip('$').lstrip('0x'), 16))
                    continue
                if expr.startswith('CURRENTOFFSET'):
                    # `ORG CURRENTOFFSET+N;标签:` 把「标签游标」前进 N（累加），
                    # 本身不写字节、也不决定写入位置。上游用一连串这样的语句给
                    # 一段连续代码的各函数打标签；数据从最后一个位置开始写。
                    m = re.match(r'^CURRENTOFFSET([+\-])(.*)$', expr)
                    rel = self.eval(m.group(2), 0)
                    if m.group(1) == '-':
                        rel = -rel
                    if self.cur is None:
                        self.cur = self.new_unit()
                        self._pushed_unit = self.cur
                    self._cursor_rel = getattr(self, '_cursor_rel', 0) + rel
                    self._pending_org_label = (self.cur, self._cursor_rel)
                    continue
                # symbol-expression ORG: new unit, target computed at emit (offset space)
                m = re.match(r'^\s*(\w+)\s*\+\s*\(2\s*\*\s*\(\(CURRENTOFFSET\s*-\s*\(9\s*\*\s*4\)\)\s*-\s*(\w+)\)\s*/\s*9\)\s*$', expr)
                u = Unit()
                if m:
                    # MenuCommand1 pattern: target = labels[m.group(1)] + 8 * item_index
                    # item_index = (ref_pos - label2_flow_offset - 36) // 36  (flow-relative)
                    u.org_expr = ('menutab', m.group(1), m.group(2))
                    u.org_ref = (self.cur, self.cur.pos if self.cur is not None else 0)
                else:
                    u.org_expr = expr
                    u.org_ref = (self.cur, self.cur.pos if self.cur is not None else 0)
                if u.org_ref[0] is None:
                    # 流参照块已结束（PUSH 后置空）：退回用「最近一个已结束块」
                    u.org_ref = (self._last_unit, u.org_ref[1])
                self.units.append(u)
                self.cur = u
                continue
            if self.cur is None:
                self.cur = self.new_unit()
            if h == 'ALIGN':
                n = int(s.split()[1])
                while self.cur.pos % n:
                    self.cur.data.append(0)
                    self.cur.pos += 1
                continue
            # EA 的 `WORD $46C04778 $E59FC000 $E12FFF1C` 里最后一个 WORD 其实是
            # callHackNew 的跳板，而紧跟的 `POIN 目标` 是它的参数——不是独立语句。
            # 原引擎把二者合起来写：WORD 三个字 + POIN 一个字（共 16 字节）。
            m = re.match(r'^WORD\s+\$?([0-9a-fA-F]+)\s+\$?([0-9a-fA-F]+)\s+\$?([0-9a-fA-F]+)\s*$', s)
            if m:
                self.cur.lit_jobs.append(
                    (self.cur.pos, [('raw', int(m.group(i), 16)) for i in (1, 2, 3)], 4, 0xFFFFFFFF, self.cur.pos))
                self.cur.data.extend(b'\x00' * 12)
                self.cur.pos += 12
                continue
            size = self.stmt_size(s, self.cur)
            toks = s.split()
            h0 = toks[0].upper()
            if h0 == 'POIN':
                self.cur.poin_jobs.append((self.cur.pos, toks[1:]))
            elif h0 in ('WORD', 'SHORT', 'BYTE'):
                nbytes = 4 if h0 == 'WORD' else (2 if h0 == 'SHORT' else 1)
                mask = 0xFFFFFFFF if h0 == 'WORD' else (0xFFFF if h0 == 'SHORT' else 0xFF)
                exprs = []
                for tok in toks[1:]:
                    t0 = tok.strip()
                    if re.match(r'^\$[0-9a-fA-F]+$', t0):
                        exprs.append(('raw', int(t0[1:], 16) & mask))
                    elif re.match(r'^-?\d+$', t0):
                        # EA 的数值字面量按十六进制解析（$28 == 28 == 0x28）
                        exprs.append(('raw', int(t0, 16) & mask))
                    else:
                        exprs.append(('expr', tok))
                self.cur.lit_jobs.append((self.cur.pos, exprs, nbytes, mask, self.cur.pos))
                self.cur.data.extend(b'\x00' * size)
                self.cur.pos += size
                continue
            self.cur.data.extend(b'\x00' * size)
            self.cur.pos += size

    def new_unit(self, fixed=None):
        u = Unit(fixed)
        self.units.append(u)
        return u

    # ---------- pass 2: emit ----------
    def emit(self, rom_out, text_encoder):
        # 1. free-space assignment
        fc = self.free_base
        for u in self.units:
            if u.fixed is not None:
                u.start = u.fixed
            elif u.org_expr is not None:
                continue
            else:
                u.start = fc
                fc += (max(u.pos, len(u.data)) + 3) & ~3
        # 2. labels -> file offsets (org_expr units deferred to step 3)
        for u in self.units:
            if u.org_expr is not None and u.fixed is None:
                continue
            for name, off in u.labels_here:
                self.labels[name] = u.start + off
        # 3. org_expr targets (their own labels resolved after start is known)
        for u in self.units:
            if u.org_expr is not None and u.fixed is None:
                ref_unit, ref_pos = u.org_ref
                curpos = (ref_unit.start + ref_pos) if ref_unit is not None else ref_pos
                if isinstance(u.org_expr, tuple) and u.org_expr[0] == 'menutab':
                    # MenuCommand1 的第 N 个菜单项：把 name/desc 两个指针写到
                    # gDebuggerMenuText + 8*N。N 由「本项在菜单数组里的序位」决定，
                    # 序位可以用 ref 块内标签的相对地址推出（每项固定 36 字节）。
                    _tag, l1, l2 = u.org_expr
                    base2 = self.labels.get(l2)
                    if base2 is None:
                        off2 = next((o for n, o in (ref_unit.labels_here if ref_unit else [])
                                     if n == l2), None)
                        base2 = (ref_unit.start if ref_unit and ref_unit.start is not None else 0) + (off2 or 0)
                    flow = (ref_unit.start if ref_unit and ref_unit.start is not None else 0) + ref_pos
                    idx = max(0, (flow - base2 - 36) // 36)
                    u.start = self.labels[l1] + 8 * idx
                else:
                    u.start = self.eval(u.org_expr, curpos)
                for name, off in u.labels_here:
                    self.labels[name] = u.start + off
        # 4. write
        for u in self.units:
            base = u.start
            rom_out[base:base + len(u.data)] = u.data
            for off, targets in u.poin_jobs:
                curpos = base + off
                for i, t in enumerate(targets):
                    if re.match(r'^(\$[0-9a-fA-F]+|0x[0-9a-fA-F]+|-?\d+)' + '$', t.strip()):
                        val = self.eval(t, curpos)             # raw literal
                    else:
                        val = GBA_BASE + self.eval(t, curpos)  # offset-space -> GBA pointer
                    p = base + off + i * 4
                    rom_out[p:p+4] = (val & 0xFFFFFFFF).to_bytes(4, 'little')
            for off, exprs, nbytes, mask, _ref in u.lit_jobs:
                p = base + off
                curpos = base + off
                for i, kind_v in enumerate(exprs):
                    if kind_v[0] == 'raw':
                        v = kind_v[1]
                    else:
                        v = self.eval(kind_v[1], curpos) & mask
                    rom_out[p+i*nbytes : p+i*nbytes+nbytes] = (v & mask).to_bytes(nbytes, 'little')
            for off, text, tbl in u.string_jobs:
                enc = text_encoder.encode(text, tbl)
                p = base + off
                rom_out[p:p+len(enc)] = enc
