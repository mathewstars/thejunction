#!/usr/bin/env python3
"""Read the CSVs that `motion_check` writes and judge the motion like a picky animator.

Usage: python3 ios/tools/motion_check/report.py OUTDIR

Prints one line per scene and draws OUTDIR/charts.png: for each scene the left pupil's
path on screen and the main channels over time, one dot per frame (even spacing between
dots = smooth speed; a gap or a kink = a pop).

What the numbers mean (pupil in pixels on a 3x phone, fox 300 points tall):
- turns/s   how often the pupil reverses direction (more than 0.15 px each way).
            The plain idle should stay under about 1.5.
- step      the largest move between two frames.
- jerk      the largest change of speed between frames (a pop shows up here).
- rest      how far the scene ends from the plain idle underneath (0 = back to rest).
- swaps     face picture changes, and how many of them did not fade (should be 0).
Only Pillow is needed.
"""
import csv
import os
import sys

from PIL import Image, ImageDraw

PX = 3.0  # points to pixels


def load(path):
    with open(path) as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        for k, v in r.items():
            try:
                r[k] = float(v)
            except ValueError:
                pass
    return rows


def turns(values, hysteresis=0.15):
    n, ext, d = 0, values[0], 0
    for v in values[1:]:
        if d >= 0 and v > ext:
            ext = v
            if d == 0 and v > values[0] + hysteresis:
                d = 1
        elif d <= 0 and v < ext:
            ext = v
            if d == 0 and v < values[0] - hysteresis:
                d = -1
        if d == 1 and v < ext - hysteresis:
            n, d, ext = n + 1, -1, v
        elif d == -1 and v > ext + hysteresis:
            n, d, ext = n + 1, 1, v
    return n


def judge(name, rows):
    xs = [r["pupilX"] * PX for r in rows]
    ys = [r["pupilY"] * PX for r in rows]
    dur = rows[-1]["t"] - rows[0]["t"]
    steps = [((xs[i + 1] - xs[i]) ** 2 + (ys[i + 1] - ys[i]) ** 2) ** 0.5 for i in range(len(xs) - 1)]
    jerk = max(abs((ys[i + 1] - ys[i]) - (ys[i] - ys[i - 1])) + abs((xs[i + 1] - xs[i]) - (xs[i] - xs[i - 1]))
               for i in range(1, len(xs) - 1))
    eye_swaps = sum(1 for a, b in zip(rows, rows[1:]) if a["eyes"] != b["eyes"])
    eye_pops = sum(1 for a, b in zip(rows, rows[1:]) if a["eyes"] != b["eyes"] and b["eyeFade"] >= 0.999)
    mouth_swaps = sum(1 for a, b in zip(rows, rows[1:]) if a["mouth"] != b["mouth"])
    mouth_pops = sum(1 for a, b in zip(rows, rows[1:]) if a["mouth"] != b["mouth"] and b["mouthFade"] >= 0.999)
    rest = max(r["rest"] for r in rows[-8:])
    return {
        "scene": name, "s": round(dur, 2),
        "turns/s y": round(turns(ys) / dur, 2), "turns/s x": round(turns(xs) / dur, 2),
        "step px": round(max(steps), 2), "jerk px": round(jerk, 2),
        "range y px": round(max(ys) - min(ys), 1), "range x px": round(max(xs) - min(xs), 1),
        "rest": round(rest, 4), "eye swaps": f"{eye_swaps} ({eye_pops} pop)",
        "mouth swaps": f"{mouth_swaps} ({mouth_pops} pop)",
    }


CHANNELS = [  # (column, scale, colour)
    ("pupilY", PX, (220, 40, 40)), ("pupilX", PX, (40, 90, 220)),
    ("dirX", 20, (0, 150, 0)), ("dirY", 20, (120, 160, 0)),
    ("tail", 1, (160, 60, 200)), ("tailBend", 1, (230, 120, 220)),
    ("earLBend", 1, (255, 140, 0)), ("rootY", 0.5, (0, 0, 0)), ("chest", 400, (0, 170, 170)),
]


def chart(name, rows, w=560, h=200):
    img = Image.new("RGB", (w, h), (255, 255, 255))
    d = ImageDraw.Draw(img)
    d.text((6, 4), name, fill=(0, 0, 0))
    n = len(rows)
    for col, scale, colour in CHANNELS:
        vals = [r[col] * scale for r in rows]
        base = vals[0]
        pts = [(10 + i * (w - 20) / max(n - 1, 1), h / 2 - (v - base) * 2.5) for i, v in enumerate(vals)]
        d.line(pts, fill=colour, width=1)
        for p in pts:
            d.point(p, fill=colour)
    # face swaps as ticks along the bottom
    for i in range(1, n):
        if rows[i]["eyes"] != rows[i - 1]["eyes"]:
            x = 10 + i * (w - 20) / max(n - 1, 1)
            d.line([(x, h - 14), (x, h - 4)], fill=(0, 0, 0))
            d.text((x + 2, h - 14), str(rows[i]["eyes"])[:5], fill=(90, 90, 90))
    return img


def main():
    out = sys.argv[1]
    names = sorted(f[:-4] for f in os.listdir(out) if f.endswith(".csv"))
    results, charts = [], []
    for name in names:
        rows = load(os.path.join(out, name + ".csv"))
        results.append(judge(name, rows))
        charts.append(chart(name, rows))
    keys = list(results[0].keys())
    widths = {k: max(len(k), *(len(str(r[k])) for r in results)) for k in keys}
    print("  ".join(k.ljust(widths[k]) for k in keys))
    for r in results:
        print("  ".join(str(r[k]).ljust(widths[k]) for k in keys))
    cols = 3
    w, h = charts[0].size
    sheet = Image.new("RGB", (w * cols, h * ((len(charts) + cols - 1) // cols)), (240, 240, 240))
    for i, c in enumerate(charts):
        sheet.paste(c, ((i % cols) * w, (i // cols) * h))
    sheet.save(os.path.join(out, "charts.png"))
    print("charts:", os.path.join(out, "charts.png"))


if __name__ == "__main__":
    main()
