#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SRR Huffman tree: extract / decode / rebuild / encode.

ROM layout (与 fe_rom.dart 的 decodeTextBytes 严格一致，已在 1692 上逐字节核对):
  slot 0x6E0 → 节点数组基址 treeBase
  slot 0x6DC → holder u32；holder 指向 root u32（两级间接）
  root u32 @ dataBase: [child0 u16, child1 u16]
  节点 = u32 @ treeBase + idx*4：
      v & 0x80000000 != 0  → 叶子，code = v & 0xFFFF
      否则                  → 内部节点，children = (v & 0xFFFF, v >> 16)

  **叶子标志在 u32 的最高位**（高 16 位全为 1），不是 right 的 bit15。
  用 right & 0x8000 判断会把全部节点误认成叶子（原树只解析出 2 个节点）。

解码：u32 分块、LSB-first、每字节 8 位；叶子 code 为 0 或低字节为 0 时终止。
"""
import heapq

def u16(b, o): return int.from_bytes(b[o:o+2], 'little')
def u32(b, o): return int.from_bytes(b[o:o+4], 'little')

LEAF_MASK = 0x80000000

class Tree:
    def __init__(self, nodes, root, tree_off, data_off):
        self.nodes = nodes      # [(left, right)] 内部节点；right==-1 表示叶子，left=code
        self.root = root        # (c0, c1) 节点索引
        self.tree_off = tree_off
        self.data_off = data_off

    @classmethod
    def extract(cls, rom, tree_off, data_off):
        c0, c1 = u16(rom, data_off), u16(rom, data_off + 2)
        reach = set()
        stack = [c0, c1]
        while stack:
            idx = stack.pop()
            if idx in reach:
                continue
            v = u32(rom, tree_off + idx * 4)
            reach.add(idx)
            if not (v & LEAF_MASK):
                stack += [v & 0xFFFF, (v >> 16) & 0xFFFF]
        nodes = [None] * (max(reach) + 1)
        for idx in reach:
            v = u32(rom, tree_off + idx * 4)
            if v & LEAF_MASK:
                nodes[idx] = (v & 0xFFFF, -1)          # leaf
            else:
                nodes[idx] = (v & 0xFFFF, (v >> 16) & 0xFFFF)
        return cls(nodes, (c0, c1), tree_off, data_off)

    # ---- 用旧树解码 → code 序列 ----
    def decode_codes(self, rom, addr, romlen):
        codes = []
        td = self.data_off
        p = addr
        while p + 4 <= romlen:
            bit = u32(rom, p)
            if bit == 0:
                if p + 8 > romlen or u32(rom, p + 4) == 0:
                    break
            p += 1
            term = False
            for _ in range(8):
                node_idx = u16(rom, td + ((bit & 1) * 2))
                nd = self.tree_off + node_idx * 4
                v = u32(rom, nd)
                bit >>= 1
                td = nd
                if v & LEAF_MASK:
                    code = v & 0xFFFF
                    if code == 0 or (code & 0xFF) == 0:
                        term = True
                        break
                    codes.append(code)
                    td = self.data_off
            if term or bit == 0:
                break
        return codes

    # ---- code → 比特路径 ----
    def code_paths(self):
        paths = {}
        def rec(idx, bits):
            code, right = self.nodes[idx]
            if right < 0:
                paths[code] = bits
                return
            rec(code, bits + [0])
            rec(right, bits + [1])
        c0, c1 = self.root
        rec(c0, [0]); rec(c1, [1])
        return paths

    def encode_codes(self, codes):
        """codes → 字节流：LSB-first 打包，末尾补 0x0000 终止符。"""
        paths = self.code_paths()
        out = bytearray()
        acc = 0; nbits = 0
        for c in list(codes) + [0x0000]:
            bits = paths.get(c)
            if bits is None:
                raise KeyError('code %04x missing from tree' % c)
            for b in bits:
                acc |= b << nbits
                nbits += 1
                if nbits == 8:
                    out.append(acc & 0xFF); acc = 0; nbits = 0
        if nbits:
            out.append(acc & 0xFF)
        return bytes(out)

def build_tree(code_multiset):
    """Huffman 建树。返回 (nodes, root_children)。

    nodes 里内部节点是 (left, right) 索引对，叶子是 (code, -1)。
    """
    h = []
    children = {}
    counter = [0]
    for c in code_multiset:
        heapq.heappush(h, (1, 0, c))
    if len(h) == 1:
        code = h[0][2]
        return [(code, -1)], (0, 0)
    def new_node(a, b):
        counter[0] += 1
        children[counter[0]] = (a, b)
        heapq.heappush(h, (2, counter[0], -counter[0]))
    while len(h) > 1:
        _, _, a = heapq.heappop(h)
        _, _, b = heapq.heappop(h)
        new_node(a, b)
    root_id = h[0][2]
    rc = children[-root_id]
    dense = []
    remap = {}
    def reidx(v):
        if v in remap:
            return remap[v]
        remap[v] = len(dense)
        dense.append(None)
        if v >= 0:
            dense[remap[v]] = (v, -1)
        else:
            a, b = children[-v]
            dense[remap[v]] = (reidx(a), reidx(b))
        return remap[v]
    reidx(rc[0]); reidx(rc[1])
    root_children = (remap[rc[0]], remap[rc[1]])
    leaf_set = {l for l, r in dense if r < 0}
    assert leaf_set == set(code_multiset), ('tree build lost codes',
                                            len(leaf_set), len(set(code_multiset)))
    return dense, root_children

def serialize(newarr, root_children):
    """[root u32][节点数组]，每个节点 4 字节。"""
    out = bytearray()
    out += root_children[0].to_bytes(2, 'little') + root_children[1].to_bytes(2, 'little')
    for l, r in newarr:
        if r < 0:
            out += (l | 0xFFFF0000).to_bytes(4, 'little')   # 叶子：高 16 位全 1
        else:
            out += (l | (r << 16)).to_bytes(4, 'little')
    return bytes(out)
