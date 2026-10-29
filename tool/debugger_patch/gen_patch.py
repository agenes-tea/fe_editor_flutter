#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 assets/debugger/*.json（FE8 调试器补丁数据）。

用法：python3 gen_patch.py <上游 Debugger 目录> <sym 文件> <原版 FE8J rom> <输出目录>
"""
import re, json, sys, codecs, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build import BE, GBA_BASE
from huff import Tree, u32, build_tree, serialize
from zh_texts import remap, zh_chars_used

FREE_BASE = 0xEFB2E0       # 0xEFB2E0..0xFFE000 是一整块 0xFF
N_TEXT = 512

def load_sym(path):
    tab = {}
    for line in open(path):
        p = line.split()
        if len(p) >= 2 and re.match(r'^[0-9a-fA-F]{8}$', p[0]):
            tab[p[1]] = int(p[0], 16) - 0x08000000
    return tab

def build(rom, dbg, symtab, zh):
    inst = os.path.join(dbg, 'Installer.event')
    if zh:
        tmp = os.path.join(dbg, 'Installer_zh_tmp.event')
        open(tmp, 'w').write(remap(open(inst).read()))
        inst = tmp
    be = BE(rom, FREE_BASE, symtab, {'_FE8_': '1'})
    stmts = be.parse_files(inst)
    if zh:
        tbl = be.tbls.setdefault('fe8TR', {})
        for ch in zh_chars_used():
            b = codecs.encode(ch, 'cp932')
            tbl[b[0] * 256 + b[1] if len(b) == 2 else b[0]] = ch
    be.layout(stmts)

    tree_off = u32(rom, 0x6E0) & 0x1FFFFFF
    holder = u32(rom, 0x6DC) & 0x1FFFFFF
    data_off = u32(rom, holder) & 0x1FFFFFF
    old = Tree.extract(rom, tree_off, data_off)
    tp = u32(rom, 0xA000) & 0x1FFFFFF
    olds = [old.decode_codes(rom, u32(rom, tp + i * 4) & 0x1FFFFFF, len(rom))
            if u32(rom, tp + i * 4) else [] for i in range(N_TEXT)]

    codes = set(old.code_paths().keys())
    for u in be.units:
        for _off, t, tb in u.string_jobs:
            codes.update(be.str_codes(t, tb))
    arr, rc = build_tree(sorted(codes))
    tbytes = serialize(arr, rc)

    fc = FREE_BASE
    for u in be.units:
        if u.fixed is None and u.org_expr is None:
            fc += (max(u.pos, len(u.data)) + 3) & ~3
    root = fc
    troot = root + 4
    hold = (root + len(tbytes) + 3) & ~3
    entry = (hold + 16) & ~3

    out = bytearray(rom)
    out[root:root + len(tbytes)] = tbytes
    out[hold:hold + 4] = (GBA_BASE + root).to_bytes(4, 'little')
    nt = Tree(arr, rc, troot, root)
    class Enc:
        def encode(self, text, tbl):
            return nt.encode_codes(be.str_codes(text, tbl))
    be.emit(out, Enc())
    off = entry
    for i in range(N_TEXT):
        d = nt.encode_codes(olds[i]) if olds[i] else b'\x00' * 8
        e = (off + len(d) + 3) & ~3
        out[off:e] = b'\x00' * (e - off)
        out[off:off + len(d)] = d
        out[tp + i * 4:tp + i * 4 + 4] = (GBA_BASE + off).to_bytes(4, 'little')
        off = e
    out[0x6E0:0x6E4] = (GBA_BASE + troot).to_bytes(4, 'little')
    out[0x6DC:0x6E0] = (GBA_BASE + hold).to_bytes(4, 'little')

    # ---- 自验：按游戏路径重新读槽位 → 解全部文本 ----
    t2 = u32(out, 0x6E0) & 0x1FFFFFF
    h2 = u32(out, 0x6DC) & 0x1FFFFFF
    r2 = u32(out, h2) & 0x1FFFFFF
    chk = Tree.extract(out, t2, r2)
    assert chk.root == rc, (chk.root, rc)
    for i in range(N_TEXT):
        got = (chk.decode_codes(out, u32(out, tp + i * 4) & 0x1FFFFFF, len(out))
               if u32(out, tp + i * 4) else [])
        assert got == olds[i], '文本 %d 变了' % i
    # 钩子必须指向补丁区
    for h in (0x9a00, 0x15450, 0x160d0, 0x1ed58, 0x2a9a8, 0x328b0, 0x39718,
              0x397b0, 0x69afc, 0x85374, 0xb3d84, 0xb3e18, 0xcc66c, 0xd4c9c):
        tgt = u32(out, h + 12)
        assert tgt >= GBA_BASE + FREE_BASE, (hex(h), hex(tgt))

    diff = [i for i in range(len(rom)) if rom[i] != out[i]]
    runs = []
    s = p = diff[0]
    for i in diff[1:]:
        if i - p > 32:
            runs.append((s, p + 1)); s = i
        p = i
    runs.append((s, p + 1))
    return [[a, out[a:b].hex()] for a, b in runs], out

def main():
    dbg, sympath, rompath, outdir = sys.argv[1:5]
    rom = open(rompath, 'rb').read()
    symtab = load_sym(sympath)
    for zh, name in ((False, 'fe8_en'), (True, 'fe8_zh')):
        blocks, out = build(rom, dbg, symtab, zh)
        open(os.path.join(outdir, name + '.json'), 'w').write(
            json.dumps({'rom': '1692-FE8J', 'blocks': blocks}, separators=(',', ':')))
        print('%s: %d 块 / %d 字节' % (name, len(blocks),
                                     sum(len(b[1]) // 2 for b in blocks)))

if __name__ == '__main__':
    main()
