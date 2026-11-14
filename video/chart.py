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
    sm = [[p[0], sum(q[1] for q in z if abs(q[0] - p[0]) <= 3) / len([q for q in z if abs(q[0] - p[0]) <= 3])] for p in z]
    # Days without a value are bridged, so the line is one continuous stroke and its tip can only glide, never jump.
    sm.sort(); dense = []
    for a, b in zip(sm, sm[1:]):
        n = int(round(b[0] - a[0]))
        for k in range(max(1, n)): dense.append([a[0] + k, a[1] + (b[1] - a[1]) * k / max(1, n)])
    dense.append(sm[-1])
    # and it starts at the first day and runs to the last, held level at the ends
    first, last = dense[0], dense[-1]
    dense = [[d, first[1]] for d in range(0, int(first[0]))] + dense + [[d, last[1]] for d in range(int(last[0]) + 1, N)]
    return dense
rows = [("Smile movements", zs(d["m"]["face.smile_rate_per_min"], False)), ("Reaction speed", zs(d["m"]["focus.median_reaction_ms"], True)), ("Steps per day", zs(d["m"]["daily.steps"], False))]
AT, AH = 120 * S, 190 * S
def ya(v): return AT + (1 - v / 20) * AH
LT = [360 * S, 465 * S, 570 * S]; LH = 92 * S
def yl(i, z): return LT[i] + LH / 2 - max(-1.9, min(1.9, z)) * (LH / 2) / 1.9
big, mid, small = ImageFont.truetype(F, 34 * S), ImageFont.truetype(F, 22 * S), ImageFont.truetype(F, 17 * S)
def frame(t, title):   # t in 0..1: how much of the 84 days is drawn
    im = Image.new("RGB", (W, H), BG); g = ImageDraw.Draw(im)
    upto = t * (N - 1) + 0.001
    g.text((262 * S, 40 * S), title, font=big, fill=INK)   # clear of the corner logo
    # shaded weeks at or over 10 (only as far as drawn)
    for i, p in enumerate(ref):
        if p[1] < 10 or p[0] > upto: continue
        xa = x(p[0] - 3) if i == 0 else (x(ref[i - 1][0]) + x(p[0])) / 2
        xb = x(p[0] + 3) if i == len(ref) - 1 else (x(p[0]) + x(ref[i + 1][0])) / 2
        g.rectangle((xa, AT, min(xb, x(upto) + 20 * S), LT[2] + LH), fill=(34, 26, 22))
    g.line((PL, ya(10), W - PR, ya(10)), fill=(110, 70, 30), width=S)
    g.text((W - PR - 300 * S, ya(10) - 26 * S), "10: the usual cut-off", font=small, fill=MUTED)
    g.text((30 * S, AT + 50 * S), "Weekly", font=mid, fill=INK); g.text((30 * S, AT + 78 * S), "questionnaire", font=mid, fill=INK); g.text((30 * S, AT + 110 * S), "higher = worse", font=small, fill=MUTED)
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
        nx = [p for p in zz if p[0] > upto]
        if run and nx and nx[0][0] - run[-1][2] <= 7:            # the tip moves smoothly towards the next day
            lastp = [p for p in zz if p[0] <= upto][-1]; f = (upto - lastp[0]) / (nx[0][0] - lastp[0])
            run.append((x(upto), yl(i, lastp[1] + (nx[0][1] - lastp[1]) * f), upto))
        if len(run) > 1: g.line([(a, b) for a, b, _ in run], fill=INK, width=3 * S, joint="curve")
    g.text((PL, H - 62 * S), "Invented patient, example data. Lower lines: her own spread; down means less.", font=small, fill=MUTED)
    return im.resize((1280, 720), Image.LANCZOS)
GLOW = (112, 224, 170)
def single(i, t, head):          # one measure on its own, for the split screens (640x720)
    w, h = 640 * S, 720 * S; im = Image.new("RGB", (w, h), BG); g = ImageDraw.Draw(im)
    g.text((40 * S, 200 * S), head, font=big, fill=INK); g.text((40 * S, 250 * S), rows[i][0] + ", week by week", font=mid, fill=MUTED)
    zz = rows[i][1]; upto = t * (N - 1); x0, x1, ym, amp = 40 * S, w - 40 * S, 430 * S, 70 * S
    g.line((x0, ym, x1, ym), fill=LINE, width=S); run = []
    for p in zz:
        if p[0] > upto: break
        if run and p[0] - run[-1][2] > 7:
            if len(run) > 1: g.line([(a, b) for a, b, _ in run], fill=GLOW, width=4 * S, joint="curve")
            run = []
        run.append((x0 + p[0] / (N - 1) * (x1 - x0), ym - max(-1.9, min(1.9, p[1])) * amp / 1.9, p[0]))
    nx = [p for p in zz if p[0] > upto]
    if run and nx and nx[0][0] - run[-1][2] <= 7:
        lastp = [p for p in zz if p[0] <= upto][-1]; f = (upto - lastp[0]) / (nx[0][0] - lastp[0]); zv = lastp[1] + (nx[0][1] - lastp[1]) * f
        run.append((x0 + upto / (N - 1) * (x1 - x0), ym - max(-1.9, min(1.9, zv)) * amp / 1.9, upto))
    if len(run) > 1: g.line([(a, b) for a, b, _ in run], fill=GLOW, width=4 * S, joint="curve")
    if run: g.ellipse((run[-1][0] - 7 * S, run[-1][1] - 7 * S, run[-1][0] + 7 * S, run[-1][1] + 7 * S), fill=GLOW)
    g.text((40 * S, 560 * S), "Example data, invented patient", font=small, fill=MUTED)
    return im.resize((640, 720), Image.LANCZOS)
def triple(t_now, starts, draw=2.2):
    """Right half of the measurement screen: three rows, each appearing when the voice names it."""
    w, h = 640 * S, 720 * S; im = Image.new("RGB", (w, h), BG); g = ImageDraw.Draw(im)
    heads = [("His game", "reaction speed", 1), ("Breathing with him", "face movement", 0), ("All day", "steps", 2)]
    for k, (head, sub, ri) in enumerate(heads):
        hs = 0.1 + 0.25 * k                                   # all three headings are there from the start; the lines then draw one after another
        if t_now < hs: continue
        y0 = (70 + k * 200) * S; a = min(1.0, (t_now - hs) / 0.5); col = tuple(int(BG[c] + (INK[c] - BG[c]) * a) for c in range(3)); mc = tuple(int(BG[c] + (MUTED[c] - BG[c]) * a) for c in range(3))
        g.text((40 * S, y0), head, font=big, fill=col); g.text((40 * S, y0 + 46 * S), sub + ", week by week", font=small, fill=mc)
        zz = rows[ri][1]; prog = max(0.0, min(1.0, (t_now - starts[k]) / draw)); prog = prog * prog * (3 - 2 * prog); upto = prog * (N - 1); x0, x1, ym, amp = 40 * S, w - 50 * S, y0 + 125 * S, 42 * S
        g.line((x0, ym, x1, ym), fill=LINE, width=S); run = []
        for p_ in zz:
            if p_[0] > upto: break
            if run and p_[0] - run[-1][2] > 7:
                if len(run) > 1: g.line([(q, r) for q, r, _ in run], fill=GLOW, width=4 * S, joint="curve")
                run = []
            run.append((x0 + p_[0] / (N - 1) * (x1 - x0), ym - max(-1.9, min(1.9, p_[1])) * amp / 1.9, p_[0]))
        nx = [p_ for p_ in zz if p_[0] > upto]
        if run and nx and nx[0][0] - run[-1][2] <= 7:
            lastp = [p_ for p_ in zz if p_[0] <= upto][-1]; f = (upto - lastp[0]) / (nx[0][0] - lastp[0]); zv = lastp[1] + (nx[0][1] - lastp[1]) * f
            run.append((x0 + upto / (N - 1) * (x1 - x0), ym - max(-1.9, min(1.9, zv)) * amp / 1.9, upto))
        if len(run) > 1: g.line([(q, r) for q, r, _ in run], fill=GLOW, width=4 * S, joint="curve")
        if len(run) > 1: g.ellipse((run[-1][0] - 6 * S, run[-1][1] - 6 * S, run[-1][0] + 6 * S, run[-1][1] + 6 * S), fill=GLOW)
    g.text((40 * S, 672 * S), "Example data, invented patient", font=small, fill=MUTED)
    return im.resize((640, 720), Image.LANCZOS)
if sys.argv[1] == "triple":
    out, secs = sys.argv[2], float(sys.argv[3]); starts = [float(x) for x in sys.argv[4].split(",")]
    os.makedirs(out, exist_ok=True); n = int(secs * 24)
    for k in range(n): triple(k / 24, starts).save(f"{out}/{k:04d}.png")
    print(out, n); sys.exit()
if sys.argv[1] == "single":
    i, out, secs, head = int(sys.argv[2]), sys.argv[3], float(sys.argv[4]), sys.argv[5]
    os.makedirs(out, exist_ok=True); n = int(secs * 24)
    for k in range(n):
        e = k / max(1, n - 1); single(i, 0.86 * e, head).save(f"{out}/{k:04d}.png")
    print(out, n); sys.exit()
out, secs, title, t0, t1 = sys.argv[1], float(sys.argv[2]), sys.argv[3], float(sys.argv[4]), float(sys.argv[5])
os.makedirs(out, exist_ok=True)
n = int(secs * 24)
for k in range(n):
    e = k / max(1, n - 1); e = 0.5 * e + 0.5 * (e * e * (3 - 2 * e))
    frame(t0 + (t1 - t0) * e, title).save(f"{out}/{k:04d}.png")
print(out, n, "frames")
