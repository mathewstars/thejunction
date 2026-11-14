"""Contact sheets of every seam of the fox's head at 4x, one sheet per seam, one tile
per frame (rest, the 12 extreme turns, the wobble frames).

    python3 ios/tools/seam_check/sheets.py FRAMES_DIR OUT_DIR [LABEL]

Each seam is a point relative to the eyes (found in each frame), so a tile follows the
head however it turns or tilts. Pixel offsets are on the iPhone 16e puppet screen.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from eyes import eyes  # noqa: E402

REST_GAP = 178.0   # pixels between the eyes at rest
SEAMS = [   # name, offset from the eyes' midpoint (along the eyes, down), at rest
    ("forehead-middle", (0, -193)), ("brow-middle", (0, -113)), ("muzzle-middle", (0, 87)),
    ("patch-l-outer", (-181, -23)), ("patch-r-outer", (184, -23)),
    ("patch-l-top", (-86, -93)), ("patch-r-top", (94, -93)),
    ("patch-l-cheek", (-156, 47)), ("patch-r-cheek", (164, 47)),
    ("nose", (0, 32)), ("brow-l", (-96, -148)), ("brow-r", (99, -148)),
    ("ear-l-base", (-156, -193)), ("ear-r-base", (154, -193)),
    ("ear-l-middle", (-166, -263)), ("ear-r-middle", (184, -263)),
    ("cheek-l-outline", (-266, 27)), ("cheek-r-outline", (274, 27)),
    ("neck-middle", (0, 147)), ("neck-l", (-106, 147)),
]
# The tail and body seams sit still on the screen when the head turns (screen pixels).
FIXED = [("tail-top", (250, 1000)), ("tail-tip", (230, 1150)), ("tail-low", (150, 1250)),
         ("bib-side", (560, 1180)), ("bib-top", (480, 1050))]
TILE = 100    # source pixels; 400 on the sheet
ZOOM = 4


def order(names):
    key = lambda n: (0 if n.startswith("rest") else 1 if n.startswith("turn") else 2, n)
    return sorted(names, key=key)


def main():
    src, out = sys.argv[1], sys.argv[2]
    label = sys.argv[3] if len(sys.argv) > 3 else os.path.basename(src.rstrip("/"))
    os.makedirs(out, exist_ok=True)
    frames = order([f for f in os.listdir(src) if f.endswith(".png")])
    font = ImageFont.load_default(size=26)
    where, pics = {}, {}
    for f in frames:
        pics[f] = Image.open(os.path.join(src, f)).convert("RGB")
        e = eyes(os.path.join(src, f))
        if len(e) == 2:
            (lx, ly), (rx, ry) = e
            where[f] = ((lx + rx) / 2, (ly + ry) / 2, math.atan2(ry - ly, rx - lx), math.hypot(rx - lx, ry - ly) / REST_GAP)
    cols = 7
    rows = math.ceil(len(frames) / cols)
    T = TILE * ZOOM
    for name, (a, b) in SEAMS + [(n, (0, None)) for n, _ in FIXED]:
        sheet = Image.new("RGB", (cols * (T + 8) + 8, rows * (T + 40) + 60), (24, 24, 28))
        d = ImageDraw.Draw(sheet)
        d.text((10, 14), f"{label}: {name} at 4x", fill=(255, 255, 255), font=font)
        for i, f in enumerate(frames):
            x0, y0 = 8 + (i % cols) * (T + 8), 60 + (i // cols) * (T + 40)
            d.text((x0, y0), f[:-4], fill=(200, 200, 200), font=font)
            if b is None:
                fx, fy = dict(FIXED)[name]
                box = (fx - TILE // 2, fy - TILE // 2, fx + TILE // 2, fy + TILE // 2)
                sheet.paste(pics[f].crop(box).resize((T, T), Image.NEAREST), (x0, y0 + 34))
                continue
            if f not in where:
                d.text((x0, y0 + 40), "eyes not found", fill=(255, 80, 80), font=font)
                continue
            mx, my, ang, s = where[f]
            px = mx + s * (a * math.cos(ang) - b * math.sin(ang))
            py = my + s * (a * math.sin(ang) + b * math.cos(ang))
            im = pics[f]
            box = (round(px - TILE / 2), round(py - TILE / 2), round(px + TILE / 2), round(py + TILE / 2))
            sheet.paste(im.crop(box).resize((T, T), Image.NEAREST), (x0, y0 + 34))
        sheet.save(os.path.join(out, f"{label}-{name}.png"), optimize=True)
    print(f"{len(SEAMS) + len(FIXED)} sheets, {len(frames)} frames, eyes found in {len(where)}")


if __name__ == "__main__":
    main()
