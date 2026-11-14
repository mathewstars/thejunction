"""Cut Lanvi's eight poses out of the sharpened sticker sheet.

Usage (from the repo root):
    python3 ios/tools/cut_poses.py /path/to/sticker-sheet-4k.png

The sheet is the captain's original sticker sheet at 4096 x 2737: top row cheer,
curious, meh, run; bottom row love, surprised, grumpy, peek; a colour-swatch row
at the bottom (ignored). Background: flat warm off-white, with a soft grey-lilac
ground shadow under each fox.

For each pose this script:
- crops a box that holds the fox and its own little marks (lines, hearts, !!),
- keys out the off-white by colour distance with a soft edge,
- removes the ground shadow (flood fill from the outside through pale, greyish
  pixels in the lower part of the box; the app draws its own shadow),
- takes the off-white back out of the soft edge pixels, so no pale fringe shows
  on the dark sky,
- trims, scales to about 1000 px on the long side, and writes
  ios/Lanvi/Assets.xcassets/lanvi-<pose>.imageset/lanvi-<pose>.png.

Pillow only.
"""

import sys
from collections import deque
from pathlib import Path

from PIL import Image, ImageFilter

BG = (250, 249, 244)

# Crop boxes on the 4096 x 2737 sheet: (left, top, right, bottom).
BOXES = {
    "cheer": (90, 110, 1150, 1210),
    "curious": (1230, 190, 2130, 1210),
    "meh": (2170, 270, 2965, 1210),
    "run": (2975, 230, 4060, 1210),
    "love": (70, 1350, 1170, 2450),
    "surprised": (1190, 1310, 2095, 2450),
    "grumpy": (2130, 1470, 3170, 2450),
    # Peek is drawn cut flat, peeking over an edge: its box ends at the ground
    # line and it keeps no shadow handling (its lower fur is shadow-coloured).
    "peek": (3190, 1810, 4060, 2374),
}

LONG_SIDE = 1000


def dist_bg(p):
    r, g, b = p[0], p[1], p[2]
    return ((r - BG[0]) ** 2 + (g - BG[1]) ** 2 + (b - BG[2]) ** 2) ** 0.5


NO_SHADOW_PASS = {"peek"}


def cut(sheet: Image.Image, box, pose: str) -> Image.Image:
    crop = sheet.crop(box).convert("RGB")
    w, h = crop.size
    px = list(crop.get_flattened_data()) if hasattr(crop, "get_flattened_data") else list(crop.getdata())
    n = w * h

    d = [dist_bg(p) for p in px]

    def sat(p):
        return p[2] - (p[0] + p[1]) / 2

    # The lowest strong-blue fur (the feet). The ground shadow only lives below
    # about this line, so pale fur above it (white tail tips) is never touched.
    feet = 0
    for i in range(n):
        if sat(px[i]) > 45 and d[i] > 40:
            feet = max(feet, i // w)
    shadow_from = feet - 60

    def passable(i):
        if d[i] < 9:
            return True  # background
        if pose in NO_SHADOW_PASS or i // w < shadow_from:
            return False
        r, g, b = px[i]
        lum = (r + g + b) / 3
        # Pale, greyish lilac: the ground shadow and its soft edge.
        sp = sat(px[i])
        # White fur is brighter and bluer than any part of the shadow.
        shadowy = lum <= 236 or sp <= 8
        return lum >= 185 and 0 <= sp <= 32 and abs(r - g) <= 12 and b - g <= 22 and shadowy

    # Flood fill from the outside: background plus the shadow joined to it.
    outside = bytearray(n)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            i = y * w + x
            if not outside[i] and passable(i):
                outside[i] = 1
                q.append(i)
    for y in range(h):
        for x in (0, w - 1):
            i = y * w + x
            if not outside[i] and passable(i):
                outside[i] = 1
                q.append(i)

    def neighbours(i):
        x, y = i % w, i // w
        if x > 0:
            yield i - 1
        if x < w - 1:
            yield i + 1
        if y > 0:
            yield i - w
        if y < h - 1:
            yield i + w

    while q:
        i = q.popleft()
        for j in neighbours(i):
            if not outside[j] and passable(j):
                outside[j] = 1
                q.append(j)

    # How far each inside pixel is from the outside, up to a thin band.
    BAND = 6
    ring = [0] * n
    q = deque(i for i in range(n) if outside[i])
    seen = bytearray(outside)
    while q:
        i = q.popleft()
        step = ring[i] + 1
        if step > BAND:
            continue
        for j in neighbours(i):
            if not seen[j]:
                seen[j] = 1
                ring[j] = step
                q.append(j)

    out = []
    for i in range(n):
        if outside[i]:
            out.append((0, 0, 0, 0))
            continue
        r, g, b = px[i]
        if 0 < ring[i] <= 2 and (r + g + b) / 3 > 236 and sat(px[i]) < 20:
            out.append((0, 0, 0, 0))  # a speck of paper on the very edge
            continue
        if 0 < ring[i] <= BAND:
            # Soft edge: how far the colour is from the paper.
            a = min(max((d[i] - 8) / 22, 0.0), 1.0)
        else:
            a = 1.0  # inside the fox: solid, white fur included
        if a <= 0.02:
            out.append((0, 0, 0, 0))
            continue
        if a < 1:
            # Take the paper colour back out of the edge pixel.
            r = (r - (1 - a) * BG[0]) / a
            g = (g - (1 - a) * BG[1]) / a
            b = (b - (1 - a) * BG[2]) / a
        out.append((int(min(max(r, 0), 255)), int(min(max(g, 0), 255)), int(min(max(b, 0), 255)), int(a * 255)))

    img = Image.new("RGBA", (w, h))
    img.putdata(out)

    # Tighten the edge by one pixel and soften it, so no speckled paper rim remains.
    alpha = img.getchannel("A").filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.9))
    img.putalpha(alpha)

    # Trim to what is left, with a small margin.
    bbox = img.getchannel("A").point(lambda v: 255 if v > 6 else 0).getbbox()
    if bbox:
        l, t, r, b = bbox
        img = img.crop((max(l - 6, 0), max(t - 6, 0), min(r + 6, w), min(b + 6, h)))

    # Scale in premultiplied alpha so edges do not darken or lighten.
    scale = LONG_SIDE / max(img.size)
    size = (round(img.size[0] * scale), round(img.size[1] * scale))
    img = img.convert("RGBa").resize(size, Image.LANCZOS).convert("RGBA")
    return img


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    sheet = Image.open(sys.argv[1])
    assets = Path(__file__).resolve().parent.parent / "Lanvi" / "Assets.xcassets"
    for pose, box in BOXES.items():
        img = cut(sheet, box, pose)
        target = assets / f"lanvi-{pose}.imageset" / f"lanvi-{pose}.png"
        img.save(target, optimize=True)
        print(f"{pose}: {img.size[0]} x {img.size[1]} -> {target.relative_to(assets.parent.parent.parent)}")


if __name__ == "__main__":
    main()
