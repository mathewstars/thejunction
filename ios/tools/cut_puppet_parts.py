#!/usr/bin/env python3
"""Cut Lanvi's paper-puppet parts out of the painted art sheets.

Usage:
    python3 ios/tools/cut_puppet_parts.py PARTS.png FACE.png [--preview DIR]

The sheets are 2048 x 2048 PNGs with a real transparent background:
- PARTS: top row left ear, head, right ear; middle row body, tail;
  bottom row left front leg, right front leg.
- FACE: row 1 eye pairs open, half closed, closed, happy; row 2 eye pairs looking
  left, looking right, looking up, wide; row 3 mouths smile, o, happy, yawn, flat.

What it does, in plain words:
1. Finds every separate piece: pixels that are not see-through, joined to their
   neighbours, make one piece. Pieces close together in a row (the two eyes of a
   pair) are kept as one image.
2. Cleans the edge: the sheets keep a coloured glow in their see-through pixels,
   so every soft edge pixel takes the colour of the solid paint just inside it
   (no glow, no dark rim). Nearly solid pixels become fully solid.
3. Trims each piece, scales it to 60 % (plenty sharp on a phone) and saves it into
   ios/Lanvi/Assets.xcassets as puppet-<name>.imageset.
4. Writes ios/Lanvi/Mascot/LanviArt.swift with every piece's size on the sheet,
   so the rig in code always matches the art. Each eye pair stays one image; the
   file also says where to split it, so the two eyes can sit on the head's own
   eye patches (they are further apart on the head than on the face sheet).

Only Pillow is needed. Re-run it whenever better art arrives.
"""
import json
import os
import shutil
import sys
from collections import deque

from PIL import Image, ImageChops, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.normpath(os.path.join(HERE, "..", "Lanvi", "Assets.xcassets"))
SWIFT = os.path.normpath(os.path.join(HERE, "..", "Lanvi", "Mascot", "LanviArt.swift"))
STEP = 4          # blob finding works on a 4x smaller mask
SAVE_SCALE = 0.6  # saved assets are this size of the sheet
PAIR_GAP = 70     # face sheet pixels: pieces closer than this in a row are one image (eye pairs)

PART_NAMES = [["ear-left", "head", "ear-right"], ["body", "tail"], ["leg-left", "leg-right"]]
FACE_NAMES = [["eyes-open", "eyes-half", "eyes-closed", "eyes-happy"],
              ["eyes-left", "eyes-right", "eyes-up", "eyes-wide"],
              ["mouth-smile", "mouth-o", "mouth-happy", "mouth-yawn", "mouth-flat"]]


def blobs(alpha):
    small = alpha.resize((alpha.width // STEP, alpha.height // STEP), Image.BILINEAR)
    w, h = small.size
    px = small.load()
    seen = [[0] * w for _ in range(h)]
    out = []
    for y in range(h):
        for x in range(w):
            if seen[y][x] or px[x, y] < 100:
                continue
            q = deque([(x, y)])
            seen[y][x] = 1
            cells = []
            while q:
                cx, cy = q.popleft()
                cells.append((cx, cy))
                for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                    if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and px[nx, ny] >= 100:
                        seen[ny][nx] = 1
                        q.append((nx, ny))
            if len(cells) * STEP * STEP < 400:
                continue
            xs = [c[0] for c in cells]
            ys = [c[1] for c in cells]
            out.append({"cells": cells,
                        "box": [min(xs) * STEP, min(ys) * STEP, (max(xs) + 1) * STEP, (max(ys) + 1) * STEP]})
    return out, (w, h)


def rows(found, names, pair_gap):
    """Group pieces into rows (by vertical centre), then join close pieces in a row."""
    found = sorted(found, key=lambda b: (b["box"][1] + b["box"][3]) / 2)
    grouped = []
    for b in found:
        cy = (b["box"][1] + b["box"][3]) / 2
        if grouped and abs(cy - grouped[-1][0]) < 160:
            grouped[-1][1].append(b)
        else:
            grouped.append([cy, [b]])
    result = []
    for _, row in grouped:
        row.sort(key=lambda b: b["box"][0])
        items = [[row[0]]]
        for b in row[1:]:
            if b["box"][0] - items[-1][-1]["box"][2] < pair_gap:
                items[-1].append(b)
            else:
                items.append([b])
        result.append(items)
    if [len(r) for r in result] != [len(r) for r in names]:
        raise SystemExit(f"layout differs from what the script expects: rows {[len(r) for r in result]}, "
                         f"expected {[len(r) for r in names]}")
    return [(n, item) for row_names, row in zip(names, result) for n, item in zip(row_names, row)]


def cut(sheet, pieces, small_size):
    alpha = sheet.getchannel("A")
    mask_small = Image.new("L", small_size, 0)
    mp = mask_small.load()
    for b in pieces:
        for cx, cy in b["cells"]:
            mp[cx, cy] = 255
    mask = mask_small.resize(sheet.size, Image.NEAREST).filter(ImageFilter.MaxFilter(2 * STEP + 3))
    a = ImageChops.multiply(alpha, mask)
    a = a.point(lambda v: 0 if v < 4 else min(255, round(v * 255 / 248)))   # nearly solid = solid
    box = a.getbbox()
    pad = 3
    box = (max(box[0] - pad, 0), max(box[1] - pad, 0), min(box[2] + pad, sheet.width), min(box[3] + pad, sheet.height))
    piece = sheet.crop(box)
    piece.putalpha(a.crop(box))
    return bleed(piece), box


def bleed(piece):
    """Soft edge pixels take the colour of the solid paint just inside them."""
    r, g, b, a = piece.split()
    solid = a.point(lambda v: 255 if v > 235 else 0)
    rgb = Image.merge("RGB", (r, g, b))
    filled = Image.new("RGB", piece.size, (0, 0, 0))
    filled.paste(rgb, mask=solid)
    known = solid
    for _ in range(8):
        grown = filled.filter(ImageFilter.MaxFilter(3))
        grown_mask = known.filter(ImageFilter.MaxFilter(3))
        ring = ImageChops.subtract(grown_mask, known)
        filled.paste(grown, mask=ring)
        known = grown_mask
    out = Image.composite(rgb, filled, solid).convert("RGBA")
    out.putalpha(a)
    return out


def save_asset(img, name):
    d = os.path.join(ASSETS, name + ".imageset")
    os.makedirs(d, exist_ok=True)
    small = img.resize((max(1, round(img.width * SAVE_SCALE)), max(1, round(img.height * SAVE_SCALE))), Image.LANCZOS)
    small.save(os.path.join(d, name + ".png"), optimize=True)
    with open(os.path.join(d, "Contents.json"), "w") as f:
        json.dump({"images": [{"filename": name + ".png", "idiom": "universal", "scale": "1x"}],
                   "info": {"author": "xcode", "version": 1}}, f, indent=2)


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        print(__doc__)
        sys.exit(1)
    preview = args[args.index("--preview") + 1] if "--preview" in args else None
    if preview:
        os.makedirs(preview, exist_ok=True)

    # one set of puppet assets only: clear the old ones first
    for d in os.listdir(ASSETS):
        if d.startswith("puppet-") and d.endswith(".imageset"):
            shutil.rmtree(os.path.join(ASSETS, d))

    sizes = {}
    eyes = {}
    for path, names, gap in ((args[0], PART_NAMES, 0), (args[1], FACE_NAMES, PAIR_GAP)):
        sheet = Image.open(path).convert("RGBA")
        found, small_size = blobs(sheet.getchannel("A"))
        for name, pieces in rows(found, names, gap):
            img, box = cut(sheet, pieces, small_size)
            save_asset(img, "puppet-" + name)
            sizes[name] = (img.width, img.height, box[0], box[1])
            if name.startswith("eyes-") and len(pieces) == 2:
                # where to split a pair in two, and each eye's centre, in pixels of the image
                l, r = pieces
                split = (l["box"][2] + r["box"][0]) / 2 - box[0]
                c = lambda b: ((b["box"][0] + b["box"][2]) / 2 - box[0], (b["box"][1] + b["box"][3]) / 2 - box[1])
                eyes[name] = (split, *c(l), *c(r))
            if preview:
                img.save(os.path.join(preview, name + ".png"))

    lines = ["// Written by ios/tools/cut_puppet_parts.py. Do not edit by hand: re-run the script.",
             "// Each puppet part's size in pixels on the 2048 x 2048 art sheet.",
             "import CoreGraphics", "", "enum LanviArt {", "    static let size: [String: CGSize] = ["]
    for name, (w, h, _, _) in sizes.items():
        lines.append(f'        "{name}": CGSize(width: {w}, height: {h}),')
    lines += ["    ]", "",
              "    /// Eye pairs: where the image splits between the eyes, and each eye's centre.",
              "    static let eyeSplit: [String: (split: CGFloat, left: CGPoint, right: CGPoint)] = ["]
    for name, (sp, lx, ly, rx, ry) in eyes.items():
        lines.append(f'        "{name}": ({sp:.0f}, CGPoint(x: {lx:.0f}, y: {ly:.0f}), CGPoint(x: {rx:.0f}, y: {ry:.0f})),')
    lines += ["    ]", "", "    static func px(_ name: String) -> CGSize { size[name] ?? CGSize(width: 1, height: 1) }", "}", ""]
    with open(SWIFT, "w") as f:
        f.write("\n".join(lines))
    print(json.dumps(sizes))


if __name__ == "__main__":
    main()
