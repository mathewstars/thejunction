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
3. Trims each piece, scales it to 90 % (about 2x its largest size on a phone) and saves it into
   ios/Lanvi/Assets.xcassets as puppet-<name>.imageset.
4. Writes ios/Lanvi/Mascot/LanviArt.swift with every piece's size on the sheet,
   so the rig in code always matches the art. Each eye pair from the sheet is saved
   as its two halves (eyes-open-l, eyes-open-r) so the two eyes can sit on the
   head's own eye patches (they are further apart on the head than on the sheet).
5. Bakes the soft fades in (neck stub under the cheeks, top of the front legs), so
   the phone draws plain pictures with no masks.
6. Cuts depth layers (see `depth_layers`): the face markings (eye patches, brow marks,
   nose) come off the head so they can slide around it when the head turns; the chest
   bib comes off the body so it can swell with each breath; the tail and ears are split
   into overlapping bands along their length (each fading in over the one before) so
   they can bend. Where a marking
   came off, the head is filled with the fur around it.

Only Pillow is needed. Re-run it whenever better art arrives.
"""
import json
import math
import os
import re
import shutil
import sys
from collections import deque

from PIL import Image, ImageChops, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.normpath(os.path.join(HERE, "..", "Lanvi", "Assets.xcassets"))
SWIFT = os.path.normpath(os.path.join(HERE, "..", "Lanvi", "Mascot", "LanviArt.swift"))
STEP = 4          # blob finding works on a 4x smaller mask
SAVE_SCALE = 0.9  # saved assets are this size of the sheet (head about 730 px wide)
PAIR_GAP = 70     # face sheet pixels: pieces closer than this in a row are one image (eye pairs)

# Soft fades baked into the art (so the phone never masks them every frame):
# the head's neck stub fades out under the cheeks, the front legs fade in at the top.
NECK_FADE = (575 / 749, 650 / 749)   # 0...1 of the head's height
LEG_FADE = 0.42                      # top share of each front leg

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


def fade(img, rows):
    """Multiply alpha by f(y) for each row (f gets 0...1 of the height)."""
    a = img.getchannel("A")
    px = a.load()
    for y in range(img.height):
        f = rows(y / max(img.height - 1, 1))
        if f >= 1:
            continue
        for x in range(img.width):
            px[x, y] = int(px[x, y] * f)
    img.putalpha(a)
    return img


def smooth(x):
    x = min(max(x, 0.0), 1.0)
    return x * x * (3 - 2 * x)


def save_asset(img, name):
    d = os.path.join(ASSETS, name + ".imageset")
    os.makedirs(d, exist_ok=True)
    small = img.resize((max(1, round(img.width * SAVE_SCALE)), max(1, round(img.height * SAVE_SCALE))), Image.LANCZOS)
    small.save(os.path.join(d, name + ".png"), optimize=True)
    with open(os.path.join(d, "Contents.json"), "w") as f:
        json.dump({"images": [{"filename": name + ".png", "idiom": "universal", "scale": "1x"}],
                   "info": {"author": "xcode", "version": 1}}, f, indent=2)


# ---------------------------------------------------------------------------------
# Depth layers. All boxes are shares (0...1) of the part's own picture, measured on
# the painted head, body, tail and ears. Brightness is 0.3 R + 0.59 G + 0.11 B: white
# fur is about 235, the blue fur 175, the brow marks 130, the nose 72.

FACE = {
    # name: (box x0, y0, x1, y1, seed x, y, brightness test, grow px, soften px)
    "face-patch-l": ((0.13, 0.28, 0.49, 0.585), (0.31, 0.45), lambda v: v > 205, 16, 5),
    "face-patch-r": ((0.51, 0.28, 0.87, 0.585), (0.69, 0.45), lambda v: v > 205, 16, 5),
    "face-brow-l": ((0.26, 0.2, 0.43, 0.31), (0.342, 0.255), lambda v: v < 155, 8, 3),
    "face-brow-r": ((0.57, 0.2, 0.74, 0.31), (0.665, 0.255), lambda v: v < 155, 8, 3),
    "face-nose": ((0.4, 0.48, 0.6, 0.64), (0.5, 0.565), lambda v: v < 120, 12, 3),
}
BIB = ((0.24, 0.16, 0.76, 0.66), (0.496, 0.366), lambda v: v > 205, 12, 5)
# Bands: drawn in order, each over the last (see `bands`).
# Pivot (share of the part), distance measured in shares of `by` (width or
# height), band centres from `a` to `b`, `n` bands. A band's bend weight grows evenly from 0
# at the base to 1 at the tip, so neighbouring bands never differ by much.
BANDS = {
    "tail": ((0.88, 0.66), "w", 0.16, 0.93, 12),
    "ear-left": ((0.36, 0.8), "h", 0.1, 0.82, 10),
    "ear-right": ((0.64, 0.8), "h", 0.1, 0.82, 10),
}


def brightness(img):
    r, g, b = img.convert("RGB").split()
    return Image.merge("RGB", (r, g, b)).convert("L", (0.3, 0.59, 0.11, 0))


def feature_mask(img, box, seed, test, grow, soft, cut_bottom=True):
    """A soft mask of one painted marking: the pixels passing `test` inside `box` that
    touch `seed`, grown by `grow` px into the fur around it, softened by `soft` px."""
    W, H = img.size
    x0, y0, x1, y1 = int(box[0] * W), int(box[1] * H), int(box[2] * W), int(box[3] * H)
    lum = brightness(img).load()
    alpha = img.getchannel("A").load()
    m = Image.new("L", img.size, 0)
    mp = m.load()
    sx, sy = int(seed[0] * W), int(seed[1] * H)
    q = deque([(sx, sy)])
    seen = {(sx, sy)}
    while q:
        x, y = q.popleft()
        if not (x0 <= x < x1 and y0 <= y < y1) or alpha[x, y] < 250 or not test(lum[x, y]):
            continue
        mp[x, y] = 255
        for n in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if n not in seen:
                seen.add(n)
                q.append(n)
    for _ in range(grow // 2):
        m = m.filter(ImageFilter.MaxFilter(5))
    if cut_bottom:
        # a straight cut at the bottom of the box (the patches run into the white cheeks)
        m.paste(0, (0, y1, W, H))
    m = m.filter(ImageFilter.GaussianBlur(soft))
    return ImageChops.multiply(m, img.getchannel("A"))


def inpaint(img, core):
    """Fill the `core` pixels from the fur around them (a smooth pull-push fill)."""
    rgb = img.convert("RGB")
    known = ImageChops.multiply(ImageChops.invert(core), img.getchannel("A").point(lambda v: 255 if v > 250 else 0))
    levels = [(ImageChops.multiply(rgb, Image.merge("RGB", [known] * 3)), known)]
    while min(levels[-1][0].size) > 6:
        c, w = levels[-1]
        size = (max(1, c.width // 2), max(1, c.height // 2))
        levels.append((c.resize(size, Image.BOX), w.resize(size, Image.BOX)))
    c, w = levels[-1]
    cp, wp = c.load(), w.load()
    total, n = [0, 0, 0], 0
    for y in range(c.height):
        for x in range(c.width):
            if wp[x, y] > 0:
                for i in range(3):
                    total[i] += cp[x, y][i] * 255 / wp[x, y]
                n += 1
    avg = tuple(int(t / max(n, 1)) for t in total)
    f = Image.new("RGB", c.size)
    fp = f.load()
    for y in range(c.height):
        for x in range(c.width):
            w = wp[x, y]
            fp[x, y] = tuple(min(255, int(cp[x, y][i] * 255 / w)) for i in range(3)) if w > 0 else avg
    for c, w in reversed(levels[:-1]):
        up = f.resize(c.size, Image.BILINEAR)
        f = ImageChops.add(c, ImageChops.multiply(up, Image.merge("RGB", [ImageChops.invert(w)] * 3)))
    out = Image.composite(f, rgb, core).convert("RGBA")
    out.putalpha(img.getchannel("A"))
    return out


def layer(img, mask):
    """The part's pixels under `mask`, trimmed. Returns the picture and its box."""
    out = img.copy()
    out.putalpha(ImageChops.multiply(img.getchannel("A"), mask))
    box = out.getchannel("A").point(lambda v: 255 if v > 2 else 0).getbbox()
    return out.crop(box), box


def bands(img, pivot, by, a, b, n):
    """Overlapping bands around `pivot`, from the base outwards, made to be drawn one on
    top of the next with plain layering: band i fades in over band i - 1 (which is solid
    there) across [c - s/2, c + s/2], stays solid to the next band's fade-in, then fades
    out under it. At rest that rebuilds the painted part exactly; bent, neighbouring bands
    differ by one small step. Returns [(picture, box, bend weight)]."""
    W, H = img.size
    unit = W if by == "w" else H
    px, py = pivot[0] * W, pivot[1] * H
    reach = math.hypot(max(px, W - px), max(py, H - py))
    dist = Image.new("L", img.size)
    dp = dist.load()
    for y in range(H):
        for x in range(W):
            dp[x, y] = min(255, int(math.hypot(x - px, y - py) / reach * 255))
    s = (b - a) / (n - 1)
    out = []
    for i in range(n):
        c = a + i * s

        def weight(v, c=c, i=i):
            r = v / 255 * reach / unit
            rise = 1.0 if i == 0 else smooth((r - (c - s / 2)) / s)
            fall = 1.0 if i == n - 1 else 1 - smooth((r - (c + 1.5 * s)) / (0.5 * s))
            return int(round(255 * rise * fall))

        mask = dist.point(weight)
        pic, box = layer(img, mask)
        out.append((pic, box, i / (n - 1)))   # the bend grows evenly along the length
    return out


def depth_layers(pieces, preview):
    """Cut the depth layers. Returns {asset name: (box shares x, y, w, h, bend weight)}."""
    found = {}

    def keep(name, pic, box, parent, weight=0.0):
        W, H = parent.size
        save_asset(pic, "puppet-" + name)
        found[name] = (box[0] / W, box[1] / H, (box[2] - box[0]) / W, (box[3] - box[1]) / H, weight)
        if preview:
            pic.save(os.path.join(preview, name + ".png"))

    head = pieces["head"]
    masks = {name: feature_mask(head, *spec) for name, spec in FACE.items()}
    # the patches never take the nose or brows with them
    nose_zone = masks["face-nose"].filter(ImageFilter.MaxFilter(9))
    brow_zone = ImageChops.lighter(masks["face-brow-l"], masks["face-brow-r"]).filter(ImageFilter.MaxFilter(9))
    for side in ("face-patch-l", "face-patch-r"):
        masks[side] = ImageChops.subtract(masks[side], ImageChops.lighter(nose_zone, brow_zone))
    core = Image.new("L", head.size, 0)
    for name, m in masks.items():
        keep(name, *layer(head, m), head)
        core = ImageChops.lighter(core, m.point(lambda v: 255 if v >= 254 else 0))
    base = inpaint(head, core)
    # where a marking is only partly there (its soft rim), the head keeps its own paint
    save_asset(base, "puppet-head-base")
    if preview:
        base.save(os.path.join(preview, "head-base.png"))

    body = pieces["body"]
    bib = feature_mask(body, *BIB)
    keep("body-bib", *layer(body, bib), body)
    body_base = inpaint(body, bib.point(lambda v: 255 if v >= 254 else 0))
    save_asset(body_base, "puppet-body-base")

    for part, (pivot, by, a, b, n) in BANDS.items():
        for i, (pic, box, w) in enumerate(bands(pieces[part], pivot, by, a, b, n)):
            keep(f"{part}-b{i}", pic, box, pieces[part], w)
    return found


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
    full = {}   # each part at full size, for the depth layers
    for path, names, gap in ((args[0], PART_NAMES, 0), (args[1], FACE_NAMES, PAIR_GAP)):
        sheet = Image.open(path).convert("RGBA")
        found, small_size = blobs(sheet.getchannel("A"))
        for name, pieces in rows(found, names, gap):
            img, box = cut(sheet, pieces, small_size)
            if name == "head":
                a0, a1 = NECK_FADE
                img = fade(img, lambda y: 1 - smooth((y - a0) / (a1 - a0)))
            if name.startswith("leg-"):
                img = fade(img, lambda y: smooth(y / LEG_FADE))
            if name.startswith("eyes-") and len(pieces) == 2:
                # one eye pair from the sheet, saved as its left and right halves so
                # each eye can sit on its own patch on the head (no clipping on the phone)
                l, r = pieces
                split = round((l["box"][2] + r["box"][0]) / 2 - box[0])
                for side, b, x0, x1 in (("l", l, 0, split), ("r", r, split, img.width)):
                    half = img.crop((x0, 0, x1, img.height))
                    save_asset(half, f"puppet-{name}-{side}")
                    cx = (b["box"][0] + b["box"][2]) / 2 - box[0] - x0
                    cy = (b["box"][1] + b["box"][3]) / 2 - box[1]
                    sizes[f"{name}-{side}"] = (half.width, half.height, 0, 0)
                    eyes[f"{name}-{side}"] = (cx, cy)
                if preview:
                    img.save(os.path.join(preview, name + ".png"))
                continue
            save_asset(img, "puppet-" + name)
            full[name] = img
            sizes[name] = (img.width, img.height, box[0], box[1])
            if preview:
                img.save(os.path.join(preview, name + ".png"))

    lines = ["// Written by ios/tools/cut_puppet_parts.py. Do not edit by hand: re-run the script.",
             "// Each puppet part's size in pixels on the 2048 x 2048 art sheet.",
             "import CoreGraphics", "", "enum LanviArt {", "    static let size: [String: CGSize] = ["]
    for name, (w, h, _, _) in sizes.items():
        lines.append(f'        "{name}": CGSize(width: {w}, height: {h}),')
    lines += ["    ]", "",
              "    /// Each eye half: where the eye's centre is in its image.",
              "    static let eyeCenter: [String: CGPoint] = ["]
    for name, (cx, cy) in eyes.items():
        lines.append(f'        "{name}": CGPoint(x: {cx:.0f}, y: {cy:.0f}),')
    layers = depth_layers(full, preview)
    lines += ["    ]", "",
              "    /// Depth layers cut from a part (face markings, chest bib, bands of the tail and",
              "    /// ears): where each sits in its part's picture, as shares (x, y, width, height).",
              "    static let layer: [String: CGRect] = ["]
    for name, (x, y, w, h, _) in layers.items():
        lines.append(f'        "{name}": CGRect(x: {x:.5f}, y: {y:.5f}, width: {w:.5f}, height: {h:.5f}),')
    lines += ["    ]", "",
              "    /// Each band's share of its part's bend: 0 at the base, 1 at the tip.",
              "    static let bend: [String: CGFloat] = ["]
    for name, (_, _, _, _, wgt) in layers.items():
        if re.search(r"-b\d+$", name):
            lines.append(f'        "{name}": {wgt:.4f},')
    lines += ["    ]", "", "    static func px(_ name: String) -> CGSize { size[name] ?? CGSize(width: 1, height: 1) }", "}", ""]
    with open(SWIFT, "w") as f:
        f.write("\n".join(lines))
    print(json.dumps(sizes))


if __name__ == "__main__":
    main()
