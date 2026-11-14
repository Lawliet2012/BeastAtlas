#!/usr/bin/env python3
"""
Generates the addon's own textures (Media/*.tga): 32-bit TGA with alpha, power-of-two sizes, as WoW requires.
All of them are white shapes; the addon tints them at runtime (SetVertexColor).

  Area.tga  habitat area: translucent fill, a brighter soft rim, fading out at the edge (world map)
  Ring.tga  anti-aliased ring (status border of a map pin)
  Disc.tga  anti-aliased filled disc (pin backdrop, count badge)
  Frame.tga square frame (status border around icons in the window's lists)
  Check.tga green check mark (finished steps in the training helper; not tinted)

Usage: python -I tools/make_media.py
"""
import math
import os
import struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Media")


def write_tga(path, size, alpha_at, metric=math.hypot, rgb=(255, 255, 255)):
    """alpha_at(r) -> 0..1, r = distance from the centre in units of the half-size (1.0 = edge).
    metric: math.hypot for round shapes, a max-norm for square ones."""
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 0x28)  # top-left origin, 8 alpha bits
    rows = bytearray()
    c = (size - 1) / 2.0
    for y in range(size):
        for x in range(size):
            # 4x4 supersampling for clean edges
            a = 0.0
            for sy in range(4):
                for sx in range(4):
                    dx = (x + (sx + 0.5) / 4 - 0.5 - c) / (size / 2.0)
                    dy = (y + (sy + 0.5) / 4 - 0.5 - c) / (size / 2.0)
                    a += alpha_at(metric(dx, dy))
            v = max(0, min(255, int(round(a / 16 * 255))))
            rows += bytes((rgb[2], rgb[1], rgb[0], v))  # BGRA
    with open(path, "wb") as f:
        f.write(header + bytes(rows))
    print(f"wrote {os.path.relpath(path, ROOT)} ({size}x{size})")


def smoothstep(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def area(r):
    # a glow, not a drawn shape: an even faint fill, a brighter soft rim, and no hard edge anywhere
    if r >= 1.0:
        return 0.0
    # the rim is thin: about a pixel or two on screen at the usual circle sizes
    rim = math.exp(-((r - 0.955) / 0.02) ** 2)
    return (0.2 + 0.55 * rim) * (1.0 - smoothstep(0.975, 1.0, r))


def ring(r):
    return 1.0 if 0.74 <= r <= 0.94 else 0.0


def disc(r):
    return 1.0 if r <= 0.94 else 0.0


def frame(r):
    return 1.0 if 0.86 <= r <= 1.0 else 0.0


def square(dx, dy):
    return max(abs(dx), abs(dy))


def segment_distance(px, py, ax, ay, bx, by):
    vx, vy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * vx + (py - ay) * vy) / (vx * vx + vy * vy)))
    return math.hypot(px - (ax + t * vx), py - (ay + t * vy))


def check_metric(dx, dy):
    """Distance to a check-mark stroke (y grows downwards)."""
    return min(segment_distance(dx, dy, -0.62, 0.05, -0.18, 0.50),
               segment_distance(dx, dy, -0.18, 0.50, 0.66, -0.48))


def check(d):
    return 1.0 if d <= 0.15 else 0.0


def main():
    os.makedirs(OUT, exist_ok=True)
    write_tga(os.path.join(OUT, "Area.tga"), 256, area)
    write_tga(os.path.join(OUT, "Ring.tga"), 64, ring)
    write_tga(os.path.join(OUT, "Disc.tga"), 64, disc)
    write_tga(os.path.join(OUT, "Frame.tga"), 64, frame, square)
    write_tga(os.path.join(OUT, "Check.tga"), 32, check, check_metric, rgb=(77, 255, 77))


if __name__ == "__main__":
    main()
