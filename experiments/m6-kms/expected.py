#!/usr/bin/env python3
"""M6 reference frames and PPM comparison. Usage:
  expected.py <ppm> A|B|SMPTE [WxH]   -> prints mismatch count, exit 0 iff the frame is exact
Pattern A/B: kmsdumb.c pattern(); SMPTE: libdrm tests/util fill_smpte_rgb32 (XR24)."""
import sys

def pat(which, x, y, w, h):
    bars = [0xffffff, 0xffff00, 0x00ffff, 0x00ff00, 0xff00ff, 0xff0000, 0x0000ff, 0x000000]
    if x == 0 or y == 0 or x == w - 1 or y == h - 1:
        v = 0xffffff
    elif y < h // 2:
        v = bars[x * 8 // w]
    else:
        v = ((x * 255 // (w - 1)) << 16) | ((y * 255 // (h - 1)) << 8) | ((x ^ y) & 0xff)
    return (~v & 0xffffff) if which else v

def rgb(r, g, b): return (r << 16) | (g << 8) | b
TOP = [rgb(192,192,192), rgb(192,192,0), rgb(0,192,192), rgb(0,192,0), rgb(192,0,192), rgb(192,0,0), rgb(0,0,192)]
MID = [rgb(0,0,192), rgb(19,19,19), rgb(192,0,192), rgb(19,19,19), rgb(0,192,192), rgb(19,19,19), rgb(192,192,192)]
BOT = [rgb(0,33,76), rgb(255,255,255), rgb(50,0,106), rgb(19,19,19), rgb(9,9,9), rgb(19,19,19), rgb(29,29,29), rgb(19,19,19)]

def smpte(x, y, w, h):
    if y < h * 6 // 9: return TOP[x * 7 // w]
    if y < h * 7 // 9: return MID[x * 7 // w]
    if x < w * 5 // 7: return BOT[x * 4 // (w * 5 // 7)]
    if x < w * 6 // 7: return BOT[(x - w * 5 // 7) * 3 // (w // 7) + 4]
    return BOT[7]

def read_ppm(p):
    d = open(p, 'rb').read()
    parts, i = [], 0
    while len(parts) < 4:
        while d[i:i+1].isspace(): i += 1
        if d[i:i+1] == b'#':
            while d[i:i+1] != b'\n': i += 1
            continue
        j = i
        while not d[j:j+1].isspace(): j += 1
        parts.append(d[i:j]); i = j
    i += 1
    assert parts[0] == b'P6' and parts[3] == b'255', parts
    return int(parts[1]), int(parts[2]), d[i:]

def compare(ppm, kind, w=None, h=None):
    W, H, px = read_ppm(ppm)
    if (w, h) != (None, None) and (W, H) != (w, h):
        return W, H, -1, []
    bad, samples = 0, []
    for y in range(H):
        row = px[y * W * 3:(y + 1) * W * 3]
        for x in range(W):
            got = (row[3*x] << 16) | (row[3*x+1] << 8) | row[3*x+2]
            exp = smpte(x, y, W, H) if kind == 'SMPTE' else pat(kind == 'B', x, y, W, H)
            if got != exp:
                bad += 1
                if len(samples) < 5: samples.append((x, y, '%06x' % got, '%06x' % exp))
    return W, H, bad, samples

if __name__ == '__main__':
    w = h = None
    if len(sys.argv) > 3: w, h = map(int, sys.argv[3].split('x'))
    W, H, bad, s = compare(sys.argv[1], sys.argv[2], w, h)
    print("%s %dx%d mismatched pixels %d %s" % (sys.argv[2], W, H, bad, s))
    sys.exit(0 if bad == 0 else 1)
