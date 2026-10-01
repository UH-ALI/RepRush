"""Generate RepRush launcher icons — pure Python, no Pillow needed.

    python tool/gen_app_icon.py

The mark: a pointy-top hexagon (a territory cell) in the brand gradient,
cyan #48E5FF -> violet #9B6CFF, carrying two dark upward chevrons ("rush"),
on the app's dark surface #070A16.

Writes:
  android/app/src/main/res/mipmap-*/ic_launcher.png             legacy, full-bleed
  android/app/src/main/res/mipmap-*/ic_launcher_foreground.png  adaptive layer
  ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png           opaque, every size

Shapes are rasterised with exact horizontal span coverage over 4 sub-rows per
pixel, which is enough anti-aliasing for an icon and fast in plain Python.
"""

import json
import math
import os
import struct
import zlib

ROOT = os.path.join(os.path.dirname(__file__), "..")
BG = (0x07, 0x0A, 0x16)
CYAN = (0x48, 0xE5, 0xFF)
VIOLET = (0x9B, 0x6C, 0xFF)
INK = (0x07, 0x0A, 0x16)
SUBROWS = 4


def hexagon(cx, cy, r):
    return [
        (cx + r * math.cos(math.radians(90 + 60 * i)), cy - r * math.sin(math.radians(90 + 60 * i)))
        for i in range(6)
    ]


def chevron(cx, cy, w, h, t):
    """An upward chevron: apex at top, arms down to the sides, thickness t."""
    return [
        (cx, cy - h / 2),
        (cx + w / 2, cy + h / 2 - t),
        (cx + w / 2, cy + h / 2),
        (cx, cy - h / 2 + t * 1.15),
        (cx - w / 2, cy + h / 2),
        (cx - w / 2, cy + h / 2 - t),
    ]


def coverage(poly, size):
    """Per-pixel coverage in [0, 1] for an (even-odd) polygon."""
    cov = [[0.0] * size for _ in range(size)]
    n = len(poly)
    for py in range(size):
        row = cov[py]
        for s in range(SUBROWS):
            y = py + (s + 0.5) / SUBROWS
            xs = []
            for i in range(n):
                (x0, y0), (x1, y1) = poly[i], poly[(i + 1) % n]
                if (y0 <= y < y1) or (y1 <= y < y0):
                    xs.append(x0 + (y - y0) * (x1 - x0) / (y1 - y0))
            xs.sort()
            for a, b in zip(xs[0::2], xs[1::2]):
                a, b = max(a, 0.0), min(b, float(size))
                for px in range(int(a), min(int(math.ceil(b)), size)):
                    overlap = min(b, px + 1) - max(a, px)
                    if overlap > 0:
                        row[px] += overlap / SUBROWS
    return cov


def render(size, mark_scale, background):
    """RGBA rows. mark_scale is the hexagon radius as a fraction of size."""
    c = size / 2
    r = size * mark_scale
    hex_cov = coverage(hexagon(c, c, r), size)
    w, h, t = r * 0.95, r * 0.42, r * 0.17
    chev = [
        coverage(chevron(c, c - r * 0.22, w, h, t), size),
        coverage(chevron(c, c + r * 0.26, w, h, t), size),
    ]
    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            # Diagonal gradient across the hexagon's bounding box.
            g = max(0.0, min(1.0, ((x - (c - r)) + (y - (c - r))) / (4 * r)))
            col = [CYAN[i] + (VIOLET[i] - CYAN[i]) * g for i in range(3)]
            a_hex = min(1.0, hex_cov[y][x])
            a_ink = min(1.0, chev[0][y][x] + chev[1][y][x]) * a_hex
            # Ink over gradient, then the whole mark over the background.
            mark = [col[i] * (1 - a_ink) + INK[i] * a_ink for i in range(3)]
            if background:
                px = [BG[i] * (1 - a_hex) + mark[i] * a_hex for i in range(3)]
                row += bytes(int(round(v)) for v in px) + b"\xff"
            else:
                row += bytes(int(round(v)) for v in mark) + bytes([int(round(a_hex * 255))])
        rows.append(bytes(row))
    return rows


def write_png(path, rows, opaque=False):
    size = len(rows)
    raw = b"".join(
        b"\x00" + (bytes(v for i, v in enumerate(r) if i % 4 != 3) if opaque else r)
        for r in rows
    )

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(
            ">I", zlib.crc32(kind + data) & 0xFFFFFFFF
        )

    colour_type = 2 if opaque else 6
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, colour_type, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)


def main():
    res = os.path.join(ROOT, "android", "app", "src", "main", "res")
    densities = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    for name, scale in densities.items():
        legacy = int(48 * scale)
        write_png(os.path.join(res, f"mipmap-{name}", "ic_launcher.png"), render(legacy, 0.36, True))
        # Adaptive foreground: 108dp canvas, mark inside the 66dp safe zone.
        fg = int(108 * scale)
        write_png(
            os.path.join(res, f"mipmap-{name}", "ic_launcher_foreground.png"),
            render(fg, 0.24, False),
        )
        print("android", name)

    iconset = os.path.join(ROOT, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset")
    with open(os.path.join(iconset, "Contents.json")) as f:
        images = json.load(f)["images"]
    done = set()
    for image in images:
        name = image["filename"]
        if name in done:
            continue
        done.add(name)
        px = int(round(float(image["size"].split("x")[0]) * int(image["scale"][0])))
        # App Store icons must be opaque.
        write_png(os.path.join(iconset, name), render(px, 0.38, True), opaque=True)
        print("ios", name, px)


if __name__ == "__main__":
    main()
