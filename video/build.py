# The rescue film: pictures cut to the one soundtrack (track.m4a). Run: python3 build.py
import os, subprocess, json
from PIL import Image, ImageDraw, ImageFont
os.chdir(os.path.dirname(os.path.abspath(__file__)))
OLD = ".."            # earlier clips g1..g6, screens, tags
F = "/System/Library/Fonts/Helvetica.ttc"
V = "-c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -r 24 -an".split()
os.makedirs("seg", exist_ok=True)
def run(a): subprocess.run(["ffmpeg", "-loglevel", "error", "-nostdin", "-y"] + a, check=True)
def text_png(name, lines, size=(1280, 720), bg=None):
    im = Image.new("RGBA", size, bg or (0, 0, 0, 0)); g = ImageDraw.Draw(im)
    for (txt, px, y, col) in lines:
        f = ImageFont.truetype(F, px); w = g.textlength(txt, font=f)
        if bg is None: g.text(((size[0] - w) / 2 + 2, y + 2), txt, font=f, fill=(0, 0, 0, 200))
        g.text(((size[0] - w) / 2, y), txt, font=f, fill=col)
    im.save(name)
text_png("cap_help.png", [("“I need help.”", 54, 560, (255, 255, 255, 255))])
text_png("card_last.png", [("Lanvi", 84, 250, (243, 240, 234, 255)), ("lanvi.app", 30, 372, (240, 138, 28, 255)),
    ("Anna is an example. Story footage is generated; the charts come from the example data in our system.", 19, 640, (157, 157, 170, 255))], bg=(15, 15, 19, 255))
text_png("card_study.png", [("Nobody knows yet whether a phone can see this.", 40, 250, (243, 240, 234, 255)),
    ("That is the study we want to run.", 40, 318, (240, 138, 28, 255)),
    ("30 people after TMS  ·  12 weeks  ·  each compared only with themselves", 24, 430, (157, 157, 170, 255))], bg=(15, 15, 19, 255))
n = [0]
def out(): n[0] += 1; return f"seg/{n[0]:03d}.mp4"
def clip(src, dur, ss=0.0, speed=1.0, zoom=1.0, fx=0.5, fy=0.5, tag="tag_gen.png", cap=None):
    """A stretch of a moving clip, optionally punched in."""
    o = out(); cw, ch = 1280 / zoom, 720 / zoom
    L = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", src], capture_output=True, text=True).stdout) - 0.1
    if ss + dur * speed > L: ss = max(0.0, L - dur * speed)        # start earlier when the clip would run out
    if ss + dur * speed > L: speed = (L - ss) / dur                # and slow it down when it is still too short
    vf = f"[0:v]setpts=PTS/{speed},scale=1280:720,crop={cw:.0f}:{ch:.0f}:{(1280-cw)*fx:.0f}:{(720-ch)*fy:.0f},scale=1280:720,fps=24[v];[v][1:v]overlay=0:0[w]"
    ins = ["-ss", str(ss), "-i", src, "-i", f"{OLD}/{tag}"]; last = "[w]"
    if cap: ins += ["-i", cap[0]]; vf += f";[w][2:v]overlay=0:0:enable='gte(t,{cap[1]})'[x]"; last = "[x]"
    run(ins + ["-filter_complex", vf, "-map", last, "-t", str(dur)] + V + [o])
    got = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", o], capture_output=True, text=True).stdout)
    assert abs(got - dur) < 0.09, (src, dur, got)
def still(src, dur, z0=1.0, z1=1.1, fx=0.5, fy=0.5, tag="tag_gen.png", cap=None, fit=False):
    """A still with a slow move."""
    o = out(); N = int(round(dur * 24))
    pre = "scale=2560:1440:force_original_aspect_ratio=decrease,pad=2560:1440:(ow-iw)/2:(oh-ih)/2:color=0x0f0f13" if fit else "scale=2560:1440:force_original_aspect_ratio=increase,crop=2560:1440"
    vf = f"[0:v]{pre},zoompan=z='{z0}+({z1}-{z0})*on/{N}':x='(iw-iw/zoom)*{fx}':y='(ih-ih/zoom)*{fy}':d={N}:s=1280x720:fps=24[v];[v][1:v]overlay=0:0[w]"
    ins = ["-loop", "1", "-i", src, "-i", f"{OLD}/{tag}"]; last = "[w]"
    if cap: ins += ["-i", cap[0]]; vf += f";[w][2:v]overlay=0:0:enable='gte(t,{cap[1]})'[x]"; last = "[x]"
    run(ins + ["-filter_complex", vf, "-map", last, "-frames:v", str(N)] + V + [o])
def card(src, dur, fade=0.5):
    o = out(); run(["-loop", "1", "-i", src, "-vf", f"fps=24,fade=t=in:d={fade}", "-t", str(dur)] + V + [o])
def chart(src, dur):
    o = out(); run(["-i", src, "-i", f"{OLD}/tag_ex.png", "-filter_complex", "[0:v]fps=24[v];[v][1:v]overlay=0:0", "-t", str(dur)] + V + [o])
def shot(name, dur, alt, motion=None, **kw):
    """A moving clip when it has been generated, otherwise the still with a slow move."""
    p = f"clips/{name}.mp4"
    if os.path.exists(p): clip(p, dur, **(motion or {}))
    else: still(alt, dur, **kw)
G = lambda k: f"{OLD}/clips/{k}.mp4"; S = lambda k: f"stills/{k}.png"
T = []   # (start time on the soundtrack, function) ; durations follow from the next start
def at(t, fn): T.append((t, fn))
# --- the door closes (0.0)
at(0.0,  lambda d: clip(G("g1"), d))
at(3.3,  lambda d: clip(G("g2"), d, ss=0.6))
at(6.5,  lambda d: clip(G("g3"), d, ss=0.8))
at(9.2,  lambda d: clip(G("g6"), d))
# --- she finds him (11.6)
at(11.6, lambda d: clip(G("g6"), d, ss=2.6, zoom=1.25, fy=0.6))
at(13.5, lambda d: shot("k1", d, S("s1")))
at(16.3, lambda d: shot("k1", d, S("s1"), motion=dict(ss=2.9, zoom=1.35, fx=0.5, fy=0.2), z0=1.4, z1=1.6, fx=0.62, fy=0.35))
at(18.2, lambda d: shot("k2", d, S("s2"), motion=dict(ss=0.6)))
at(20.0, lambda d: shot("k2", d, S("s2"), motion=dict(ss=2.6, zoom=1.35, fx=0.3, fy=0.6), z0=1.3, z1=1.45, fx=0.3, fy=0.6))
# --- she takes care of him (22.4)
at(22.4, lambda d: shot("k6", d, S("s3"), z0=1.0, z1=1.12, fx=0.45, fy=0.55))
at(25.2, lambda d: clip(G("g5"), d, ss=0.5))
at(27.3, lambda d: shot("k9", d, S("sofa") if os.path.exists(S("sofa")) else S("s3"), z0=1.05, z1=1.18))
at(29.2, lambda d: shot("k6", d, S("s3"), motion=dict(ss=2.4, zoom=1.5, fx=0.45, fy=0.5), z0=1.45, z1=1.65, fx=0.45, fy=0.5))
at(33.1, lambda d: clip(G("g4"), d, ss=0.2))
at(35.1, lambda d: shot("k3", d, S("s5"), z0=1.0, z1=1.14, fx=0.4, fy=0.7))
at(37.2, lambda d: shot("k3", d, S("s5"), motion=dict(ss=2.5, zoom=1.4, fx=0.3, fy=0.85), z0=1.5, z1=1.7, fx=0.3, fy=0.85))
# --- he keeps watch (38.9)
at(38.9, lambda d: shot("k5", d, S("s6"), motion=dict(ss=1.6, zoom=1.5, fx=0.6, fy=0.35), z0=1.5, z1=1.75, fx=0.85, fy=0.7))
at(42.6, lambda d: clip(G("g6"), d, ss=1.0, zoom=1.6, fy=0.95))
at(43.8, lambda d: shot("k2", d, S("s2"), motion=dict(ss=3.6, zoom=1.9, fx=0.75, fy=0.1), z0=1.9, z1=2.0, fx=0.75, fy=0.1))
at(44.9, lambda d: clip(G("g5"), d, ss=2.5, zoom=1.3))
at(46.4, lambda d: card("card_num1.png", d, fade=0.25))
at(49.0, lambda d: card("card_num2.png", d, fade=0.25))
# --- the research (52.0)
at(52.0, lambda d: chart("chart_a.mp4", d))
at(58.0, lambda d: chart("chart_b.mp4", d))
at(65.5, lambda d: still("chart_end.png", d, z0=1.0, z1=1.22, fx=1.0, fy=0.0, tag="tag_ex.png"))
# --- November (70.2)
at(70.2, lambda d: shot("k5", d, S("s6"), z0=1.0, z1=1.12, fx=0.5, fy=0.6))
at(73.8, lambda d: shot("k4", d, S("s4"), cap=None, z0=1.0, z1=1.1, fx=0.6, fy=0.4))
at(76.0, lambda d: shot("k4", d, S("s4"), motion=dict(ss=2.2, zoom=1.35, fx=0.35, fy=0.45, cap=("cap_help.png", 1.6)), cap=("cap_help.png", 1.6), z0=1.3, z1=1.45, fx=0.35, fy=0.45))
at(80.4, lambda d: shot("k7", d, S("s7"), z0=1.0, z1=1.15, fx=0.75, fy=0.85))
at(83.0, lambda d: shot("k7", d, S("s7"), motion=dict(ss=2.6, zoom=1.4, fx=0.8, fy=0.9), z0=1.4, z1=1.55, fx=0.8, fy=0.9))
# --- the honest close (85.8)
at(85.8, lambda d: still(f"{OLD}/screens/r4_anna.jpg", d, z0=1.3, z1=1.4, fx=0.0, fy=0.14, tag="tag_ex.png", fit=True))
at(89.6, lambda d: still(f"{OLD}/screens/r5_elina.jpg", d, z0=1.3, z1=1.4, fx=0.0, fy=0.14, tag="tag_ex.png", fit=True))
at(95.6, lambda d: card("card_study.png", d))
# --- the turn (100.6)
at(100.6, lambda d: shot("k2", d, S("s2"), motion=dict(ss=1.2, speed=0.8), z0=1.0, z1=1.12, fx=0.4, fy=0.5))
at(104.4, lambda d: shot("k8", d, S("morning") if os.path.exists(S("morning")) else S("s4"), z0=1.0, z1=1.16, fx=0.6, fy=0.5))
at(109.6, lambda d: card("card_last.png", d, fade=0.8))
END = 113.0
# Every cut is moved onto a beat of the soundtrack (beats.py), preferring a strongly played beat close by.
B = json.load(open("beats.json")); moved = []
def snap(t, prev):
    best, bs = t, -9
    for b, st in zip(B["beats"], B["strength"]):
        if abs(b - t) <= 0.55 and b - prev >= 1.0:
            sc = min(st, 3.0) - 3.0 * abs(b - t)
            if sc > bs: best, bs = b, sc
    return best
prev = 0.0
for i in range(1, len(T)):
    nt = snap(T[i][0], prev); moved.append(abs(nt - T[i][0])); T[i] = (nt, T[i][1]); prev = nt
print("cuts on beats:", len(moved), "largest move", round(max(moved), 2), "s, mean", round(sum(moved) / len(moved), 2), "s")
json.dump([round(t, 3) for t, _ in T], open("cuts.json", "w"))
for i, (t, fn) in enumerate(T):
    nxt = T[i + 1][0] if i + 1 < len(T) else END
    fn(round(nxt - t, 3))
open("list.txt", "w").write("".join(f"file 'seg/{i:03d}.mp4'\n" for i in range(1, n[0] + 1)))
run(["-f", "concat", "-safe", "0", "-i", "list.txt", "-c", "copy", "silent.mp4"])
run(["-i", "silent.mp4", "-i", "track.m4a", "-filter_complex", "[1:a]apad=whole_dur=113[a]", "-map", "0:v", "-map", "[a]", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-t", "113", "film.mp4"])
print(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", "film.mp4"], capture_output=True, text=True).stdout.strip(), n[0], "shots")
