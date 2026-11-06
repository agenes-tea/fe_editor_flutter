#!/usr/bin/env python3
"""AI 生成的立绘 PNG → GBA 火纹肖像索引图 JSON。

用法：
    python3 tool/portrait_convert.py <输入图.png> <输出.json> [--crop x0,y0,x1,y1]

流程：
  1. 从四边 flood fill 抠掉纯白背景（只抠与边界连通的，
     不会吃掉角色内部的白色蕾丝/围裙）
  2. 可选 --crop x0,y0,x1,y1 裁出头部区域（不指定则保留全部内容）
  3. 等比缩到能完整落进有效区的最宽尺寸（实测 68 宽）并居中 ——
     火纹 96×80 肖像的上部两侧（x<16、x>=80 且 y<48）是无效区，
     放内容会被裁掉
  4. 按火纹语义分配 15 色（1-4 肤色 / 5-6 描边 / 7-13 蓝 / 14 白 / 15 高光），
     索引 0 留透明
  5. 输出带 palette_bgr555 的 JSON，直接喂给 tool/apply_portrait.dart

GBA 15bit 颜色位序：bit0-4=R，bit5-9=G，bit10-14=B。
"""
from PIL import Image
import colorsys
import json
import sys
from collections import deque

# 火纹肖像 96x80 的 6 块有效区（与 PortraitReader.faceImage 的 blit 对应）
VALID_BLOCKS = [
    (16, 0, 64, 32), (16, 32, 64, 32), (16, 64, 32, 16),
    (0, 48, 16, 32), (48, 64, 32, 16), (80, 48, 16, 32),
]

# 语义分层调色板：索引 0 透明，1-4 肤色，5-6 描边，7-13 蓝，14 白，15 高光
PALETTE = [
    (160, 200, 152),
    (255, 226, 200), (245, 196, 168), (222, 160, 136), (178, 116, 102),
    (92, 64, 80), (48, 36, 60),
    (186, 212, 248), (146, 180, 234), (110, 148, 214), (80, 118, 196),
    (58, 88, 166), (40, 64, 132), (26, 44, 98),
    (234, 242, 252), (255, 255, 255),
]


def to555(c):
    r, g, b = c
    return (r >> 3) | ((g >> 3) << 5) | ((b >> 3) << 10)


def from555(v):
    return ((v & 0x1F) << 3, ((v >> 5) & 0x1F) << 3, ((v >> 10) & 0x1F) << 3)


def cut_background(im):
    """从四边 flood fill 掉浅色背景，保留角色内部的白色。"""
    w, h = im.size
    px = im.load()

    def light(c):
        r, g, b, a = c
        return a < 32 or (r > 232 and g > 232 and b > 232)

    seen = [[False] * w for _ in range(h)]
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if light(px[x, y]) and not seen[y][x]:
                seen[y][x] = True
                q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if light(px[x, y]) and not seen[y][x]:
                seen[y][x] = True
                q.append((x, y))
    while q:
        x, y = q.popleft()
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and light(px[nx, ny]):
                seen[ny][nx] = True
                q.append((nx, ny))
    for y in range(h):
        for x in range(w):
            if seen[y][x]:
                px[x, y] = (0, 0, 0, 0)
    return im


def valid_mask():
    m = [[False] * 96 for _ in range(80)]
    for dx, dy, w, h in VALID_BLOCKS:
        for y in range(dy, dy + h):
            for x in range(dx, dx + w):
                m[y][x] = True
    return m


def fit_into_valid(content):
    """等比缩放到能完整落进有效区的最宽尺寸，居中偏下放置。"""
    mask = valid_mask()
    best = None
    for w in range(96, 32, -2):
        h = max(1, round(content.height * w / content.width))
        if h > 80:
            continue
        x0 = (96 - w) // 2
        y0 = 80 - h
        scaled = content.resize((w, h), Image.LANCZOS)
        sp = scaled.load()
        ok = True
        for y in range(h):
            for x in range(w):
                if sp[x, y][3] > 0 and not mask[y0 + y][x0 + x]:
                    ok = False
                    break
            if not ok:
                break
        if ok:
            best = (scaled, x0, y0)
            break
    if best is None:
        scaled = content.resize((64, 48), Image.LANCZOS)
        best = (scaled, 16, 32)
    return best


def classify(r, g, b):
    h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
    hd = h * 360
    if s < 0.18 and v > 0.72:
        return [14, 15]
    if v < 0.30:
        return [5, 6]
    if 185 <= hd <= 290:
        return [7, 8, 9, 10, 11, 12, 13]
    if hd >= 320 or hd <= 50:
        return [1, 2, 3, 4]
    return list(range(1, 16))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    src_path, out_path = sys.argv[1], sys.argv[2]
    crop = None
    if '--crop' in sys.argv:
        i = sys.argv.index('--crop')
        crop = tuple(int(v) for v in sys.argv[i + 1].split(','))

    im = Image.open(src_path).convert('RGBA')
    im = cut_background(im)
    if crop:
        im = im.crop(crop)

    px = im.load()
    minx, miny, maxx, maxy = im.width, im.height, -1, -1
    for y in range(im.height):
        for x in range(im.width):
            if px[x, y][3] > 0:
                minx, maxx = min(minx, x), max(maxx, x)
                miny, maxy = min(miny, y), max(maxy, y)
    if maxx < 0:
        raise SystemExit('图中没有不透明内容')
    content = im.crop((minx, miny, maxx + 1, maxy + 1))

    scaled, x0, y0 = fit_into_valid(content)
    canvas = Image.new('RGBA', (96, 80), (0, 0, 0, 0))
    canvas.paste(scaled, (x0, y0), scaled)
    print(f'内容 {content.width}x{content.height} → 缩放 {scaled.width}x{scaled.height} @({x0},{y0})')

    pal = [to555(c) for c in PALETTE]
    disp = [from555(v) for v in pal]
    cp = canvas.load()
    indices, used = [], set()
    for y in range(80):
        row = []
        for x in range(96):
            r, g, b, a = cp[x, y]
            if a == 0:
                row.append(0)
                continue
            i = min(classify(r, g, b), key=lambda k: sum((c - d) ** 2 for c, d in zip((r, g, b), disp[k])))
            row.append(i)
            used.add(i)
        indices.append(row)

    canvas.resize((96 * 4, 80 * 4), Image.NEAREST).save(out_path.replace('.json', '_preview.png'))
    json.dump({
        'width': 96, 'height': 80,
        'indices': indices,
        'palette_rgb': [list(c) for c in PALETTE],
        'palette_bgr555': pal,
        'used_indices': sorted(used),
    }, open(out_path, 'w'))
    print(f'使用索引: {sorted(used)}')
    print(f'已写出 {out_path}')


if __name__ == '__main__':
    main()
