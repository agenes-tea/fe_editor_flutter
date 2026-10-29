#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build the Vesly debugger install into a FE8 ROM (vanilla 16MB).

v1 scope:
  - full menu (en build uses the stock strings; zh build uses overrides + SJIS codes)
  - Huffman tree extended with the needed char codes; ALL 512 text entries re-encoded
  - flag-tutorial event (DebuggerFlagEvent) is inert: 3-byte stub, never executed
"""
import re, glob, os, sys, hashlib
from build import BE, GBA_BASE
from huff import Tree, u16, u32, build_tree, serialize

ROMDIR = '/root/workspace/game-rom'
SYSYM = '/tmp/csk.sym'
DBG = '/tmp/vesly_asm/Debugger'

def load_symtab(path):
    tab = {}
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2 and re.match(r'^[0-9a-fA-F]{8}$', parts[0]):
                tab[parts[1]] = int(parts[0], 16) - 0x08000000
    return tab

class Encoder:
    def __init__(self, newtree, be):
        self.t = newtree
        self.be = be
    def encode(self, text, tblname):
        codes = self.be.str_codes(text, tblname)
        return self.t.encode_codes(codes)

def main(zh=False):
    if zh:
        from zh_texts import remap
        src_inst = open(DBG + '/Installer.event').read()
        open(DBG + '/Installer_zh_temp.event', 'w').write(remap(src_inst))
        inst_path = DBG + '/Installer_zh_temp.event'
    else:
        inst_path = DBG + '/Installer.event'
    rompath = [p for p in glob.glob(ROMDIR + '/*.gba') if p.startswith(ROMDIR + '/1692 -')][0]
    rom = open(rompath, 'rb').read()
    assert len(rom) == 0x1000000, len(rom)
    symtab = load_symtab(SYSYM)

    # ---- old tree & text table ----
    tree_off = u32(rom, 0x6E0) & 0x1FFFFFF
    # slot 0x6DC -> holder u32; holder holds a pointer to the root u32 (double deref).
    # Verified on 1692: slot=0x0814D088, holder@0x14D088=0x0814D084, root u32@0x14D084.
    holder_off = u32(rom, 0x6DC) & 0x1FFFFFF
    data_off = u32(rom, holder_off) & 0x1FFFFFF
    old_tree = Tree.extract(rom, tree_off, data_off)
    tp = u32(rom, 0xA000) & 0x1FFFFFF
    N = 512
    old_codes = []
    for i in range(N):
        p = u32(rom, tp + i*4) & 0x1FFFFFF
        old_codes.append(old_tree.decode_codes(rom, p, len(rom)) if p else [])
    old_leaves = set(old_tree.code_paths().keys())
    print('old tree leaves: %d, total old codes: %d' % (len(old_leaves), sum(len(c) for c in old_codes)))

    # ---- build engine ----
    be = BE(rom, free_base=0xEFB2E0, symtab=symtab, defines={'_FE8_': '1'})
    stmts = be.parse_files(inst_path)
    if zh:
        import codecs
        from zh_texts import zh_chars_used
        zhchars = zh_chars_used()
        missing = [ch for ch in zhchars
                   if codecs.encode(ch, 'cp932') is None]
        for ch in list(zhchars):
            try:
                b = codecs.encode(ch, 'cp932')
                code = b[0]*256 + b[1] if len(b) == 2 else b[0]
                be.tbls.setdefault('fe8TR', {})[code] = ch
            except UnicodeEncodeError:
                print('WARN: char %r not cp932-encodable, will fail STRING' % ch)
    be.layout(stmts)

    # label pre-check
    label_names = set()
    for u in be.units:
        for name, _off in u.labels_here:
            label_names.add(name)
    known = label_names | set(symtab)
    unknown = set()
    for u in be.units:
        for off, targets in u.poin_jobs:
            for t in targets:
                for b in t.split():
                    b = b.strip('()').split('|')[0].strip()
                    if re.match(r'^(\$|0x|-?\d)', b) or b.startswith('CURRENTOFFSET'):
                        continue
                    if b in known or b in be.defines:
                        continue
                    unknown.add(b)
    print('unknown symbols after layout:', sorted(unknown))
    assert not unknown, unknown

    # ---- new tree: old leaves + codes used by the menu strings ----
    allcodes = set()
    for u in be.units:
        for off, text, tbl in u.string_jobs:
            allcodes.update(be.str_codes(text, tbl))
    newcodes = old_leaves | allcodes
    print('new tree codes: %d (added %d)' % (len(newcodes), len(allcodes - old_leaves)))
    newarr, rootc = build_tree(sorted(newcodes))
    treebytes = serialize(newarr, rootc)

    # ---- free-space guard: one contiguous FF region for payload + tree + entries ----
    FREE = 0xEFB2E0
    be.free_base = FREE
    fc = FREE
    for u in be.units:
        if u.fixed is None and u.org_expr is None:
            fc += (max(u.pos, len(u.data)) + 3) & ~3
    payload_end = fc
    # treebytes = [root u32][node array ...] (serialize() already emits the root first)
    root_off_new = payload_end
    tree_off_new = root_off_new + 4          # treebytes = [root u32][nodes], node array follows
    holder_off_new = (root_off_new + len(treebytes) + 3) & ~3
    entry_base = (holder_off_new + 16) & ~3
    tree_region_end = entry_base + 0x8000
    assert tree_region_end <= 0xFFE000, hex(tree_region_end)
    assert all(b == 0xFF for b in rom[payload_end:tree_region_end]), 'free region not all FF'

    # ---- emit payload into ROM copy ----
    rom_out = bytearray(rom)
    rom_out[root_off_new:root_off_new + len(treebytes)] = treebytes
    rom_out[holder_off_new:holder_off_new + 4] = (GBA_BASE + root_off_new).to_bytes(4, 'little')
    new_tree = Tree(newarr, rootc, tree_off_new, root_off_new)
    enc = Encoder(new_tree, be)
    be.emit(rom_out, enc)

    # ---- re-encode all text entries into the entry region (4-aligned, zero-padded) ----
    off = entry_base
    for i in range(N):
        data = new_tree.encode_codes(old_codes[i]) if old_codes[i] else b'\x00' * 8
        end = (off + len(data) + 3) & ~3
        rom_out[off:end] = b'\x00' * (end - off)
        rom_out[off:off + len(data)] = data
        rom_out[tp + i*4: tp + i*4 + 4] = (GBA_BASE + off).to_bytes(4, 'little')
        off = end
    print('entry region: %s .. %s (%d bytes)' % (hex(entry_base), hex(off), off - entry_base))

    # ---- patch tree slots ----
    # slots keep the original indirection depth: 0x6E0 -> node array, 0x6DC -> holder -> root u32
    rom_out[0x6E0:0x6E4] = (GBA_BASE + tree_off_new).to_bytes(4, 'little')
    rom_out[0x6DC:0x6E0] = (GBA_BASE + holder_off_new).to_bytes(4, 'little')

    # ---- verify: full re-decode of all entries with new tree ----
    ok = bad = 0
    for i in range(N):
        p = u32(rom_out, tp + i*4) & 0x1FFFFFF
        c = new_tree.decode_codes(rom_out, p, len(rom_out))
        if c == old_codes[i]:
            ok += 1
        else:
            bad += 1
            if bad < 5:
                print('MISMATCH entry %d: old %r new %r' % (i, old_codes[i][:8], c[:8]))
    print('entry re-verify: ok %d / bad %d' % (ok, bad))
    assert bad == 0

    # ---- verify: menu text via gDebuggerMenuText table (game path) ----
    loc = {}
    for u in be.units:
        for name, off in u.labels_here:
            loc[name] = u.start + off
    inv = {}
    for code, disp in be.tbls.get('fe8TR', {}).items():
        for ch in disp:
            inv[ch] = code
    gt = loc['gDebuggerMenuText']
    shown = 0
    for i in range(20):
        p = u32(rom_out, gt + i*4) & 0x1FFFFFF
        if p == 0:
            continue
        codes = new_tree.decode_codes(rom_out, p, len(rom_out))
        back = ''.join(('\\' if c == 1 else chr(c)) for c in codes if c in inv or c == 1)
        print('  menu slot %d: %s' % (i, back[:60]))
        shown += 1
        if shown >= 8:
            break

    # ---- verify: hooks ----
    hooklist = [0x9A00, 0x15450, 0x160D0, 0x1ED58, 0x2A9A8, 0x328B0,
                0x39718, 0x397B0, 0x69AFC, 0x85374, 0xB3D84, 0xB3E18, 0xCC66C, 0x1CA0C]
    for h in hooklist:
        print('  hook @ %s: %s' % (hex(h), rom_out[h:h+12].hex()))

    # ---- independent re-read exactly as the game does (slots -> tree -> text) ----
    t_off2 = u32(rom_out, 0x6E0) & 0x1FFFFFF
    h_off2 = u32(rom_out, 0x6DC) & 0x1FFFFFF
    r_off2 = u32(rom_out, h_off2) & 0x1FFFFFF
    root2 = (u16(rom_out, r_off2), u16(rom_out, r_off2 + 2))
    treesz = max(max(idx) for idx, _ in [(i, 0) for i in range(0)]) if False else None
    rd = Tree.extract(rom_out, t_off2, r_off2)
    assert rd.root == rootc, ('root mismatch', rd.root, rootc)
    tp2 = u32(rom_out, 0xA000) & 0x1FFFFFF
    bad2 = 0
    for i in range(N):
        p = u32(rom_out, tp2 + i*4) & 0x1FFFFFF
        if rd.decode_codes(rom_out, p, len(rom_out)) != old_codes[i]:
            bad2 += 1
    print('game-path re-read: root %r, text mismatch entries %d' % (root2, bad2))
    assert bad2 == 0

    # ---- save + diff stats ----
    outpath = '/tmp/mini_ea/fe8j_debugger_%s.gba' % ('zh' if zh else 'en')
    import sys
    if len(sys.argv) > 2 and sys.argv[2] == 'zh':
        outpath = '/tmp/mini_ea/fe8j_debugger_zh.gba'
    open(outpath, 'wb').write(rom_out)
    diffs = sum(1 for a, b in zip(rom, rom_out) if a != b)
    print('bytes changed: %d -> %s' % (diffs, outpath))
    print('ROM sha1:', hashlib.sha1(bytes(rom_out)).hexdigest())

if __name__ == '__main__':
    main(zh=('zh' in sys.argv))
