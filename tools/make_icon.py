#!/usr/bin/env python3
"""
Draws the project logo (docs/icon.png, 512x512): a paw print inside a hunter-green ring on a dark rounded
square - the same look as the addon's map pins. Original artwork, no game assets. No dependencies.

Usage: python -I tools/make_icon.py
"""
import math
import os
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "icon.png")
SIZE = 512
PX = 2.0 / SIZE  # one pixel in shape units (the canvas is [-1, 1] x [-1, 1], y down)

GREEN = (171, 212, 115)   # the hunter class colour
CREAM = (247, 240, 214)


def cover(d):
    """Anti-aliased coverage of a shape from its signed distance (negative = inside)."""
    return max(0.0, min(1.0, 0.5 - d / PX))


def circle(x, y, cx, cy, r):
    return math.hypot(x - cx, y - cy) - r


def ellipse(x, y, cx, cy, rx, ry, deg):
    a = math.radians(deg)
    dx, dy = x - cx, y - cy
    u = dx * math.cos(a) + dy * math.sin(a)
    v = -dx * math.sin(a) + dy * math.cos(a)
    k = math.hypot(u / rx, v / ry)
    return (k - 1.0) * min(rx, ry)


def rounded_square(x, y, half, radius):
    qx, qy = abs(x) - half + radius, abs(y) - half + radius
    return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - radius


def smooth_min(a, b, k):
    h = max(0.0, min(1.0, 0.5 + 0.5 * (b - a) / k))
    return b + (a - b) * h - k * h * (1.0 - h)


def paw(x, y):
    pad = smooth_min(circle(x, y, 0.0, 0.20, 0.215),
                     smooth_min(circle(x, y, -0.17, 0.33, 0.15), circle(x, y, 0.17, 0.33, 0.15), 0.08), 0.12)
    toes = min(ellipse(x, y, -0.375, -0.02, 0.095, 0.135, -24), ellipse(x, y, -0.135, -0.27, 0.105, 0.15, -7),
               ellipse(x, y, 0.135, -0.27, 0.105, 0.15, 7), ellipse(x, y, 0.375, -0.02, 0.095, 0.135, 24))
    return min(pad, toes)


def blend(base, colour, alpha):
    return tuple(base[i] * (1.0 - alpha) + colour[i] * alpha for i in range(3))


def pixel(x, y):
    """-> (r, g, b, a) with a in 0..1"""
    alpha = cover(rounded_square(x, y, 0.97, 0.24))
    if alpha <= 0.0:
        return 0, 0, 0, 0.0
    r = math.hypot(x, y + 0.15)
    glow = max(0.0, 1.0 - r / 1.25)
    col = (14 + 30 * glow, 20 + 44 * glow, 14 + 24 * glow)                    # dark green, lighter towards the top
    col = blend(col, (8, 11, 8), 0.55 * cover(circle(x, y, 0, 0, 0.80)))       # the well inside the ring
    ring = max(circle(x, y, 0, 0, 0.80), -circle(x, y, 0, 0, 0.705))           # annulus
    shade = 0.82 + 0.18 * (0.5 - y / 1.6)                                      # lighter at the top
    col = blend(col, tuple(min(255.0, c * shade) for c in GREEN), cover(ring))
    col = blend(col, (0, 0, 0), 0.35 * cover(paw(x, y - 0.03) - 0.02))         # soft shadow under the paw
    col = blend(col, CREAM, cover(paw(x, y)))
    return col[0], col[1], col[2], alpha


def main():
    rows = bytearray()
    for j in range(SIZE):
        rows.append(0)
        y = (j + 0.5) * PX - 1.0
        for i in range(SIZE):
            r, g, b, a = pixel((i + 0.5) * PX - 1.0, y)
            rows += bytes((int(r + 0.5), int(g + 0.5), int(b + 0.5), int(a * 255 + 0.5)))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))
    print(f"wrote {os.path.relpath(OUT, ROOT)} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
