# Renders the real example series as a line that draws itself: the weekly score on top,
# three measures below (each in the person's own spread, turned so that up means worse).
import json, os, sys
from PIL import Image, ImageDraw, ImageFont
F = "/System/Library/Fonts/Helvetica.ttc"
BG, INK, MUTED, AMBER, EMBER, LINE = (15, 15, 19), (243, 240, 234), (157, 157, 170), (240, 138, 28), (240, 99, 63), (38, 38, 46)
d = json.load(open("anna.json")); ref = sorted(d["ref"]); N = 84
S = 2  # supersample
W, H = 1280 * S, 720 * S
PL, PR = 215 * S, 60 * S
def x(day): return PL + day / (N - 1) * (W - PL - PR)
def zs(pts, flip):
    v = [p[1] for p in pts]; m = sum(v) / len(v); sd = (sum((q - m) ** 2 for q in v) / max(1, len(v) - 1)) ** 0.5 or 1
    z = [[p[0], ((p[1] - m) / sd) * (-1 if flip else 1)] for p in pts]
    return [[p[0], sum(q[1] for q in z if abs(q[0] - p[0]) <= 3) / len([q for q in z if abs(q[0] - p[0]) <= 3])] for p in z]
rows = [("Smiling less", zs(d["m"]["face.smile_rate_per_min"], True)), ("Reacting slower", zs(d["m"]["focus.median_reaction_ms"], False)), ("Walking less", zs(d["m"]["daily.steps"], True))]
AT, AH = 120 * S, 190 * S
def ya(v): return AT + (1 - v / 20) * AH
LT = [360 * S, 465 * S, 570 * S]; LH = 92 * S
def yl(i, z): return LT[i] + LH / 2 - max(-1.9, min(1.9, z)) * (LH / 2) / 1.9
big, mid, small = ImageFont.truetype(F, 34 * S), ImageFont.truetype(F, 22 * S), ImageFont.truetype(F, 17 * S)
def frame(t, title):   # t in 0..1: how much of the 84 days is drawn
    im = Image.new("RGB", (W, H), BG); g = ImageDraw.Draw(im)
    upto = t * (N - 1) + 0.001
    g.text((PL, 40 * S), title, font=big, fill=INK)
    # shaded weeks at or over 10 (only as far as drawn)
    for i, p in enumerate(ref):
        if p[1] < 10 or p[0] > upto: continue
        xa = x(p[0] - 3) if i == 0 else (x(ref[i - 1][0]) + x(p[0])) / 2
        xb = x(p[0] + 3) if i == len(ref) - 1 else (x(p[0]) + x(ref[i + 1][0])) / 2
        g.rectangle((xa, AT, min(xb, x(upto) + 20 * S), LT[2] + LH), fill=(34, 26, 22))
    g.line((PL, ya(10), W - PR, ya(10)), fill=(110, 70, 30), width=S)
    g.text((W - PR - 330 * S, ya(10) - 26 * S), "10: the line clinics watch", font=small, fill=MUTED)
    g.text((30 * S, AT + 60 * S), "Weekly", font=mid, fill=INK); g.text((30 * S, AT + 88 * S), "score", font=mid, fill=INK)
    pts = [(x(p[0]), ya(p[1])) for p in ref if p[0] <= upto]
    # partial segment to the moving tip
    nxt = [p for p in ref if p[0] > upto]
    if pts and nxt:
        a = [p for p in ref if p[0] <= upto][-1]; b = nxt[0]; f = (upto - a[0]) / (b[0] - a[0])
        pts.append((x(upto), ya(a[1] + (b[1] - a[1]) * f)))
    if len(pts) > 1: g.line(pts, fill=AMBER, width=5 * S, joint="curve")
    for p in ref:
        if p[0] <= upto:
            g.ellipse((x(p[0]) - 8 * S, ya(p[1]) - 8 * S, x(p[0]) + 8 * S, ya(p[1]) + 8 * S), fill=AMBER, outline=BG, width=3 * S)
            g.text((x(p[0]) - 10 * S, ya(p[1]) - 38 * S), str(int(p[1])), font=mid, fill=INK)
    for i, (name, zz) in enumerate(rows):
        g.line((PL, yl(i, 0), W - PR, yl(i, 0)), fill=LINE, width=S)
        g.text((30 * S, LT[i] + 30 * S), name, font=mid, fill=INK)
        run = []
        for p in zz:
            if p[0] > upto: break
            if run and p[0] - run[-1][2] > 7:
                if len(run) > 1: g.line([(a, b) for a, b, _ in run], fill=INK, width=3 * S, joint="curve")
                run = []
            run.append((x(p[0]), yl(i, p[1]), p[0]))
        if len(run) > 1: g.line([(a, b) for a, b, _ in run], fill=INK, width=3 * S, joint="curve")
    g.text((PL, H - 62 * S), "Example data. Lower lines: this person's own spread, turned so that up means worse.", font=small, fill=MUTED)
    return im.resize((1280, 720), Image.LANCZOS)
out, secs, title, t0, t1 = sys.argv[1], float(sys.argv[2]), sys.argv[3], float(sys.argv[4]), float(sys.argv[5])
os.makedirs(out, exist_ok=True)
n = int(secs * 24)
for k in range(n):
    e = k / max(1, n - 1); e = e * e * (3 - 2 * e)
    frame(t0 + (t1 - t0) * e, title).save(f"{out}/{k:04d}.png")
print(out, n, "frames")
