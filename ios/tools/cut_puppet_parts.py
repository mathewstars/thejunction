#!/usr/bin/env python3
"""Cut Lanvi's paper-puppet parts out of the green-screen parts sheet.

Usage:
    python3 ios/tools/cut_puppet_parts.py path/to/lanvi-parts-sheet.png [--list] [--preview DIR]

What it does, in plain words:
1. Keys out the green: a pixel is background when its green is much stronger than
   its red and blue ("greenness"). A soft ramp between two greenness levels gives
   soft, anti-aliased fur edges instead of a hard cut.
2. Removes green spill: the edge is shrunk by one pixel, and any green left in a
   pixel is pulled down to the level of its red/blue (classic de-spill).
3. Finds every separate part (connected blob) on the sheet, names them by where
   they sit (see PARTS below), trims each to its own box and saves it into
   ios/Lanvi/Assets.xcassets as puppet-<name>.imageset.

Only Pillow is needed. Re-run it whenever better art arrives; if the new sheet's
layout differs, run with --list to see the blobs and adjust PARTS.
"""
import json
import os
import sys
from collections import deque

from PIL import Image, ImageChops, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.normpath(os.path.join(HERE, "..", "Lanvi", "Assets.xcassets"))

# Greenness = G - max(R, B). Background sits around 230+, fur is negative.
SOLID = 28     # at or below: fully opaque
CLEAR = 120    # at or above: fully transparent
STEP = 4       # downsample factor for blob finding

# Each part: name -> the point (in sheet pixels) that lies inside it; eye pairs and
# mouth pieces made of several blobs list several points. Parts are drawn on
# the sheet at 2476x1642.
PARTS = {
    "reference": [(560, 600)],
    "ear-left": [(1430, 230)],
    "head": [(1850, 290)],
    "ear-right": [(2270, 230)],
    "body": [(1550, 700)],
    "tail": [(2150, 700)],
    "paw-left": [(1900, 950)],
    "paw-right": [(2220, 950)],
}

def greenness_alpha(img):
    r, g, b = img.split()
    mx = ImageChops.lighter(r, b)
    gn = ImageChops.subtract(g, mx)          # 0 when not green-dominant
    span = CLEAR - SOLID
    alpha = gn.point(lambda v: 255 if v <= SOLID else (0 if v >= CLEAR else int(255 * (CLEAR - v) / span)))
    # de-spill: green may not exceed the average of red and blue (Lanvi's fur is
    # blue and white, so this never touches real fur colour, only green spill)
    avg = Image.blend(r, b, 0.5)
    g2 = ImageChops.darker(g, avg)
    return Image.merge("RGB", (r, g2, b)), alpha

def blobs(alpha):
    small = alpha.resize((alpha.width // STEP, alpha.height // STEP), Image.BILINEAR)
    w, h = small.size
    px = small.load()
    seen = [[0] * w for _ in range(h)]
    out = []
    for y in range(h):
        for x in range(w):
            if seen[y][x] or px[x, y] < 128:
                continue
            q = deque([(x, y)]); seen[y][x] = len(out) + 1
            cells = []
            while q:
                cx, cy = q.popleft(); cells.append((cx, cy))
                for nx, ny in ((cx+1, cy), (cx-1, cy), (cx, cy+1), (cx, cy-1)):
                    if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and px[nx, ny] >= 128:
                        seen[ny][nx] = len(out) + 1; q.append((nx, ny))
            xs = [c[0] for c in cells]; ys = [c[1] for c in cells]
            out.append({"id": len(out) + 1, "cells": cells, "area": len(cells) * STEP * STEP,
                        "box": (min(xs) * STEP, min(ys) * STEP, (max(xs) + 1) * STEP, (max(ys) + 1) * STEP)})
    return out, seen

def blob_at(seen, pt):
    x, y = pt[0] // STEP, pt[1] // STEP
    # look in a small neighbourhood (thin strokes like arcs)
    for r in range(0, 12):
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                yy, xx = y + dy, x + dx
                if 0 <= yy < len(seen) and 0 <= xx < len(seen[0]) and seen[yy][xx]:
                    return seen[yy][xx]
    return None

def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__); sys.exit(1)
    sheet = Image.open(args[0]).convert("RGB")
    rgb, alpha = greenness_alpha(sheet)
    found, seen = blobs(alpha)
    found = [b for b in found if b["area"] >= 300]
    if "--list" in args:
        for b in sorted(found, key=lambda b: (b["box"][1] // 200, b["box"][0])):
            print(b["id"], b["box"], b["area"])
        return
    preview = None
    if "--preview" in args:
        preview = args[args.index("--preview") + 1]; os.makedirs(preview, exist_ok=True)

    parts = dict(PARTS)
    parts.update(face_parts(found))
    by_id = {b["id"]: b for b in found}
    manifest = {}
    for name, pts in parts.items():
        ids = {blob_at(seen, p) for p in pts} - {None}
        if not ids:
            print("MISSING", name); continue
        # mask = the chosen blobs only (blown back up), grown a little to keep soft edges
        mask_small = Image.new("L", (len(seen[0]), len(seen)), 0)
        mp = mask_small.load()
        for i in ids:
            for cx, cy in by_id[i]["cells"]:
                mp[cx, cy] = 255
        mask = mask_small.resize(sheet.size, Image.NEAREST).filter(ImageFilter.MaxFilter(2 * STEP + 1))
        a = ImageChops.multiply(alpha, mask)
        a = a.filter(ImageFilter.MinFilter(3))          # shrink the edge one pixel
        a = a.filter(ImageFilter.GaussianBlur(0.6))     # and soften it again
        a = a.point(lambda v: 0 if v < 6 else v)
        box = a.getbbox()
        pad = 4
        box = (max(box[0] - pad, 0), max(box[1] - pad, 0), min(box[2] + pad, sheet.width), min(box[3] + pad, sheet.height))
        piece = rgb.crop(box).convert("RGBA")
        piece.putalpha(a.crop(box))
        piece = bleed(piece)
        manifest[name] = {"box": box, "size": piece.size}
        if name == "reference":
            if preview: piece.save(os.path.join(preview, "reference.png"))
            continue
        save_asset(piece, "puppet-" + name)
        if preview:
            piece.save(os.path.join(preview, name + ".png"))
    print(json.dumps(manifest, indent=1))

def bleed(piece):
    """Replace colour in see-through pixels with the nearest solid fur colour, so
    scaling on the phone never blends in a dark or green halo."""
    r, g, b, a = piece.split()
    solid = a.point(lambda v: 255 if v > 200 else 0)
    rgb = Image.merge("RGB", (r, g, b))
    filled = Image.new("RGB", piece.size, (0, 0, 0))
    filled.paste(rgb, mask=solid)
    known = solid
    for _ in range(6):
        grown = filled.filter(ImageFilter.MaxFilter(3))
        grown_mask = known.filter(ImageFilter.MaxFilter(3))
        ring = ImageChops.subtract(grown_mask, known)
        filled.paste(grown, mask=ring)
        known = grown_mask
    # solid pixels keep their colour; the soft edge takes the colour of the fur just
    # inside it, so the edge fades out in fur colour, never in a green or dark rim
    out_rgb = Image.composite(rgb, filled, solid)
    out = out_rgb.convert("RGBA"); out.putalpha(a)
    return out

def face_parts(found):
    """Eyes (8 pairs, left to right: open, half closed, happy arc, happy arc 2,
    then looking right, right and up, up, and wide open) and mouths (5: smile, o, big happy, yawn, flat) and mouths (5) sit in two rows at the bottom of the sheet."""
    eyes = sorted([b for b in found if 1100 < b["box"][1] < 1350 and b["box"][3] < 1350], key=lambda b: b["box"][0])
    mouths = sorted([b for b in found if b["box"][1] >= 1350], key=lambda b: b["box"][0])
    eye_names = ["open", "half", "happy", "happy2", "right", "right-up", "up", "wide"]
    mouth_names = ["smile", "o", "happy", "yawn", "flat"]
    out = {}
    if len(eyes) == 16:
        # each eye is saved on its own (l = the one on the viewer's left), so the
        # pair can be spaced to sit on the head's eye patches
        for i, n in enumerate(eye_names):
            left, right = eyes[2 * i: 2 * i + 2]
            out["eye-" + n + "-l"] = [center(left)]
            out["eye-" + n + "-r"] = [center(right)]
    else:
        print("expected 16 eye blobs, found", len(eyes), [b["box"] for b in eyes])
    if len(mouths) == 5:
        for b, n in zip(mouths, mouth_names):
            out["mouth-" + n] = [center(b)]
    else:
        print("expected 5 mouth blobs, found", len(mouths), [b["box"] for b in mouths])
    return out

def center(b):
    # a point surely inside the blob: one of its own cells
    cx, cy = b["cells"][len(b["cells"]) // 2]
    return (cx * STEP + STEP // 2, cy * STEP + STEP // 2)

def save_asset(img, name):
    d = os.path.join(ASSETS, name + ".imageset")
    os.makedirs(d, exist_ok=True)
    img.save(os.path.join(d, name + ".png"), optimize=True)
    with open(os.path.join(d, "Contents.json"), "w") as f:
        json.dump({"images": [{"filename": name + ".png", "idiom": "universal", "scale": "1x"}],
                   "info": {"author": "xcode", "version": 1}}, f, indent=2)

if __name__ == "__main__":
    main()
