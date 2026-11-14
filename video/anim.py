# Two animated screens for the film's middle part, drawn from one session of the engine's own
# reference generator (clinic_engine.frames_reference.make_session): ARKit-like numbers, 55 per row, 30 rows a second.
#   python3 anim.py stream <outdir> <seconds> [start_s]      right half: what leaves the phone
#   python3 anim.py check  <outdir> <seconds> t1,t2,t3       full frame: rules, two models, code's check
import json, os, sys
from PIL import Image, ImageDraw, ImageFont
HERE = os.path.dirname(os.path.abspath(__file__))
raw, truth = json.load(open(os.path.join(HERE, "session.json")))
CH = raw["channels"]; SM = raw["samples"]; RATE = raw["rate_hz"]
BG, INK, MUTED, LINE, GLOW, RED = (15, 14, 19), (243, 240, 234), (157, 157, 170), (38, 38, 46), (140, 240, 200), (240, 99, 63)
HV, MONO = "/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/Menlo.ttc"
S = 2
def f(size, mono=False): return ImageFont.truetype(MONO if mono else HV, size * S)
def col(name): i = CH.index(name); return [r[i] for r in SM]
def mix(a, b, k): return tuple(int(a[c] + (b[c] - a[c]) * max(0.0, min(1.0, k))) for c in range(3))

BARS = [("smile, left", "mouthSmileLeft"), ("smile, right", "mouthSmileRight"), ("cheek, left", "cheekSquintLeft"), ("cheek, right", "cheekSquintRight"),
        ("blink, left", "eyeBlinkLeft"), ("blink, right", "eyeBlinkRight"), ("brow down", "browDownLeft"), ("inner brow up", "browInnerUp"),
        ("jaw open", "jawOpen"), ("look down", "eyeLookDownLeft")]
BCOL = [col(n) for _, n in BARS]

def stream(t, start, qt=1e9):
    w, h = 640 * S, 720 * S; im = Image.new("RGB", (w, h), BG); g = ImageDraw.Draw(im)
    a = min(1.0, t / 0.5)
    g.text((40 * S, 44 * S), "What leaves the phone", font=f(32), fill=mix(BG, INK, a))
    g.text((40 * S, 90 * S), "No photo, no video. Face-movement numbers only, 30 a second.", font=f(16), fill=mix(BG, MUTED, a))
    pos = (start + t) * RATE; i0 = min(len(SM) - 2, int(pos)); fr = pos - i0
    for k, (label, _) in enumerate(BARS):
        if t < 0.25 + 0.06 * k: continue
        y = (140 + k * 29) * S; v = BCOL[k][i0] + (BCOL[k][i0 + 1] - BCOL[k][i0]) * fr
        g.text((40 * S, y), label, font=f(15), fill=MUTED)
        x0, x1 = 170 * S, 500 * S
        g.rounded_rectangle((x0, y + 5 * S, x1, y + 13 * S), 4 * S, fill=LINE)
        c = mix(MUTED, GLOW, (v - 0.12) / 0.15)
        g.rounded_rectangle((x0, y + 5 * S, x0 + max(8 * S, (x1 - x0) * min(1.0, v / 0.7)), y + 13 * S), 4 * S, fill=c)
        g.text((516 * S, y), f"{v:.3f}", font=f(15, True), fill=c)
    # the rows themselves, newest at the bottom
    if t > 0.9:
        g.text((40 * S, 446 * S), "the rows, as sent", font=f(14), fill=MUTED)
        rows = 8
        for r in range(rows):
            i = i0 - (rows - 1 - r)
            if i < 0: continue
            y = (472 + r * 21) * S; b = 0.25 + 0.75 * (r + 1) / rows
            txt = f"{i / RATE:6.3f}  " + " ".join(f"{SM[i][CH.index(n)]:.2f}" for _, n in BARS)
            g.text((40 * S, y), txt, font=f(13, True), fill=mix(BG, INK if r == rows - 1 else MUTED, b))
    if t >= qt:
        al = min(1.0, (t - qt) / 0.6)
        g.text((40 * S, 652 * S), "Do they change before a hard week?", font=f(24), fill=mix(BG, GLOW, al))
    g.text((40 * S, 692 * S), "Example session, generated numbers", font=f(14), fill=MUTED)
    return im.resize((640, 720), Image.LANCZOS)

SMILE = [(a + b) / 2 for a, b in zip(col("mouthSmileLeft"), col("mouthSmileRight"))]
def check(t, beats):
    w, h = 1280 * S, 720 * S; im = Image.new("RGB", (w, h), BG); g = ImageDraw.Draw(im)
    g.text((262 * S, 40 * S), "One game session, read", font=f(34), fill=INK)
    g.text((262 * S, 86 * S), "how far the mouth corners moved, over 45 seconds", font=f(16), fill=MUTED)
    x0, x1, yb, amp = 130 * S, 1150 * S, 300 * S, 150 * S
    def X(sec): return x0 + sec / 45.0 * (x1 - x0)
    def Y(v): return yb - min(0.62, v) / 0.62 * amp
    g.line((x0, yb, x1, yb), fill=LINE, width=S)
    for sec in (0, 15, 30, 45): g.text((X(sec) - 8 * S, yb + 8 * S), f"{sec} s", font=f(13), fill=MUTED)
    t3 = beats[2]
    # at the third beat: what the model reported, and what code made of it
    spans = [(truth[0]["start_s"], truth[0]["end_s"], True), (17.2, 18.9, False), (truth[2]["start_s"], truth[2]["end_s"], True)]
    for k, (a, b, ok) in enumerate(spans):
        st = t3 + (0.5, 1.7, 1.0)[k]
        if t < st: continue
        al = min(1.0, (t - st) / 0.35); c = GLOW if ok else RED
        g.rectangle((X(a - 0.5), yb - amp - 6 * S, X(b + 0.5), yb), fill=mix(BG, c, 0.20 * al), outline=mix(BG, c, al), width=2 * S)
        lab = "confirmed" if ok else "dropped"; tw = g.textlength(lab, font=f(15))
        g.text(((X(a) + X(b)) / 2 - tw / 2, yb - amp - 30 * S), lab, font=f(15), fill=mix(BG, c, al))
        if not ok: g.line((X(a - 0.5), yb - amp - 6 * S, X(b + 0.5), yb), fill=mix(BG, RED, al), width=2 * S)
    upto = min(1.0, t / 1.6) * (len(SMILE) - 1); pts = []
    for i in range(0, int(upto) + 1, 3): pts.append((X(i / RATE), Y(SMILE[i])))
    if len(pts) > 1: g.line(pts, fill=INK, width=3 * S, joint="curve")
    heads = [("Rules raise a flag.", "Plain rules we can explain, not a model."),
             ("Two models weigh in.", "A small local model and Gemini: agree, raise or lower."),
             ("Code checks every claim.", "What the numbers don't support is dropped.")]
    for k, (hd, sub) in enumerate(heads):
        if t < beats[k]: continue
        al = min(1.0, (t - beats[k]) / 0.45); x = (70 + k * 395) * S; y = 380 * S
        g.text((x, y), str(k + 1), font=f(44), fill=mix(BG, GLOW, al))
        g.text((x + 44 * S, y + 4 * S), hd, font=f(25), fill=mix(BG, INK, al))
        g.text((x + 44 * S, y + 42 * S), sub, font=f(14), fill=mix(BG, MUTED, al))
    if t >= t3 + 2.6:
        al = min(1.0, (t - t3 - 2.6) / 0.5)
        txt = "One real run on our server:   3 smiles reported   ·   2 confirmed by code   ·   1 dropped"
        tw = g.textlength(txt, font=f(22)); g.text(((w - tw) / 2, 500 * S), txt, font=f(22), fill=mix(BG, GLOW, al))
        t2 = "Only confirmed items reach the clinician."; tw = g.textlength(t2, font=f(17)); g.text(((w - tw) / 2, 540 * S), t2, font=f(17), fill=mix(BG, MUTED, al))
    g.text((40 * S, 612 * S), "Drawn on an example session with generated numbers; the counts are from one real run.", font=f(13), fill=MUTED)
    return im.resize((1280, 720), Image.LANCZOS)

mode, out, secs = sys.argv[1], sys.argv[2], float(sys.argv[3]); os.makedirs(out, exist_ok=True); n = int(secs * 24)
if mode == "stream":
    start = float(sys.argv[4]) if len(sys.argv) > 4 else 3.6; qt = float(sys.argv[5]) if len(sys.argv) > 5 else 1e9
    for k in range(n): stream(k / 24, start, qt).save(f"{out}/{k:04d}.png")
else:
    beats = [float(x) for x in sys.argv[4].split(",")]
    for k in range(n): check(k / 24, beats).save(f"{out}/{k:04d}.png")
print(out, n)
