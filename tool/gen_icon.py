#!/usr/bin/env python3
"""PNG 解码 + 区域平均缩放 + PNG 编码（纯标准库，无 PIL）。

把 2048x2048 的图标 PNG 缩到 Android mipmap 各密度。
"""
import struct, sys, zlib, os

def read_png(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', 'not a PNG'
    pos = 8
    w = h = depth = ctype = interlace = 0
    idat = b''
    plte = None
    trns = None
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos+4])[0]
        t = d[pos+4:pos+8]
        data = d[pos+8:pos+8+ln]
        pos += 12 + ln
        if t == b'IHDR':
            w, h, depth, ctype, comp, filt, interlace = struct.unpack('>IIBBBBB', data)
            assert depth == 8, f'bitdepth {depth}'
            assert interlace == 0, 'interlaced not supported'
        elif t == b'IDAT':
            idat += data
        elif t == b'PLTE':
            plte = data
        elif t == b'tRNS':
            trns = data
        elif t == b'IEND':
            break
    nch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(idat)
    stride = w * nch
    buf = bytearray(w * h * 4)
    prev = bytearray(stride)
    off = 0
    for y in range(h):
        ft = raw[off]; off += 1
        line = bytearray(raw[off:off+stride]); off += stride
        if ft == 1:
            for i in range(nch, stride):
                line[i] = (line[i] + line[i-nch]) & 0xFF
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(stride):
                left = line[i-nch] if i >= nch else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                left = line[i-nch] if i >= nch else 0
                up = prev[i]
                lu = prev[i-nch] if i >= nch else 0
                p = left + up - lu
                pa, pb, pc = abs(p-left), abs(p-up), abs(p-lu)
                pr = left if (pa <= pb and pa <= pc) else (up if pb <= pc else lu)
                line[i] = (line[i] + pr) & 0xFF
        elif ft != 0:
            raise ValueError(f'filter {ft}')
        prev = line
        for x in range(w):
            i = x * nch
            o = (y * w + x) * 4
            if ctype == 3:
                r = plte[line[i]*3]; g = plte[line[i]*3+1]; b = plte[line[i]*3+2]
                a = 255
                if trns is not None and line[i] < len(trns):
                    a = trns[line[i]]
            elif ctype == 2:
                r, g, b, a = line[i], line[i+1], line[i+2], 255
            elif ctype == 6:
                r, g, b, a = line[i], line[i+1], line[i+2], line[i+3]
            elif ctype == 4:
                r = g = b = line[i]; a = line[i+1]
            else:
                r = g = b = line[i]; a = 255
            buf[o] = r; buf[o+1] = g; buf[o+2] = b; buf[o+3] = a
    return w, h, buf

def area_scale(src, sw, sh, dw, dh):
    out = bytearray(dw * dh * 4)
    fx, fy = sw / dw, sh / dh
    for y in range(dh):
        y0 = int(y * fy); y1 = max(y0 + 1, int((y + 1) * fy))
        for x in range(dw):
            x0 = int(x * fx); x1 = max(x0 + 1, int((x + 1) * fx))
            r = g = b = a = 0
            for sy in range(y0, y1):
                row = sy * sw * 4
                for sx in range(x0, x1):
                    o = row + sx * 4
                    r += src[o]; g += src[o+1]; b += src[o+2]; a += src[o+3]
            n = (x1 - x0) * (y1 - y0)
            o = (y * dw + x) * 4
            out[o] = r // n; out[o+1] = g // n; out[o+2] = b // n; out[o+3] = a // n
    return out

def write_png(path, w, h, rgba):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += rgba[y * w * 4:(y + 1) * w * 4]
    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)
    out = b'\x89PNG\r\n\x1a\n'
    out += chunk(b'IHDR', ihdr)
    out += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    out += chunk(b'IEND', b'')
    open(path, 'wb').write(out)

def main():
    src_path, out_dir = sys.argv[1], sys.argv[2]
    w, h, buf = read_png(src_path)
    print(f'source: {w}x{h}')
    densities = {
        'mipmap-mdpi': 48, 'mipmap-hdpi': 72, 'mipmap-xhdpi': 96,
        'mipmap-xxhdpi': 144, 'mipmap-xxxhdpi': 192,
    }
    for name, size in densities.items():
        dst = area_scale(buf, w, h, size, size)
        p = os.path.join(out_dir, name, 'ic_launcher.png')
        os.makedirs(os.path.dirname(p), exist_ok=True)
        write_png(p, size, size, dst)
        print(f'{name}: {size}x{size} -> {p}')

if __name__ == '__main__':
    main()
