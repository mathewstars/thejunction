"""Key a flat green background out of a picture of Lanvi.

Usage (from the repo root):
    python3 ios/tools/key_green.py IN.png ASSET_NAME [LONG_SIDE]

Writes ios/Lanvi/Assets.xcassets/ASSET_NAME.imageset/ASSET_NAME.png (and its
Contents.json): a transparent PNG trimmed to the fox, about LONG_SIDE pixels on
its long side (default 1000).

How: how green a pixel is (green above the larger of red and blue) sets how
transparent it becomes, with a soft edge. Green light spilled onto the fur at
the edge is taken back out, so no green fringe shows on the dark sky. Pillow only.
"""

import json
import sys
from pathlib import Path

from PIL import Image, ImageFilter


def key(img: Image.Image) -> Image.Image:
    img = img.convert("RGB")
    px = list(img.get_flattened_data()) if hasattr(img, "get_flattened_data") else list(img.getdata())
    out = []
    for r, g, b in px:
        spill = g - max(r, b)
        # Fully green background -> 0; fur (blue and white) -> 1; a soft edge between.
        a = 1.0 - min(max((spill - 24) / 90, 0.0), 1.0)
        if a <= 0.01:
            out.append((0, 0, 0, 0))
            continue
        # Take the green spill back out of the colour.
        if g > max(r, b):
            g = max(r, b)
        out.append((r, g, b, int(a * 255)))
    keyed = Image.new("RGBA", img.size)
    keyed.putdata(out)
    # Tighten the edge by a pixel and soften it.
    alpha = keyed.getchannel("A").filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.8))
    keyed.putalpha(alpha)
    return keyed


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    src, name = sys.argv[1], sys.argv[2]
    long_side = int(sys.argv[3]) if len(sys.argv) > 3 else 1000
    img = key(Image.open(src))
    box = img.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    if box:
        l, t, r, b = box
        img = img.crop((max(l - 6, 0), max(t - 6, 0), min(r + 6, img.width), min(b + 6, img.height)))
    scale = long_side / max(img.size)
    img = img.convert("RGBa").resize((round(img.width * scale), round(img.height * scale)), Image.LANCZOS).convert("RGBA")
    folder = Path(__file__).resolve().parent.parent / "Lanvi" / "Assets.xcassets" / f"{name}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    img.save(folder / f"{name}.png", optimize=True)
    (folder / "Contents.json").write_text(json.dumps(
        {"images": [{"filename": f"{name}.png", "idiom": "universal"}], "info": {"author": "xcode", "version": 1}},
        indent=2) + "\n")
    print(f"{name}: {img.width} x {img.height}")


if __name__ == "__main__":
    main()
