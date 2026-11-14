# Lanvi submission film (v5): pictures cut to track5.m4a. Run: python3 build5.py
import os, subprocess, json
from PIL import Image, ImageDraw, ImageFont
os.chdir(os.path.dirname(os.path.abspath(__file__)))
OLD = ".."; F = "/System/Library/Fonts/Helvetica.ttc"; BGHEX = "0x0b131e"
V = "-c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -r 24 -an".split()
os.system("rm -rf seg5"); os.makedirs("seg5")
def run(a): subprocess.run(["ffmpeg", "-loglevel", "error", "-nostdin", "-y"] + a, check=True)
def dur_of(p): return float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", p], capture_output=True, text=True).stdout)
def text_png(name, lines, bg=None, size=(1280, 720)):
    im = Image.new("RGBA", size, bg or (0, 0, 0, 0)); g = ImageDraw.Draw(im)
    for (txt, px, y, col) in lines:
        f = ImageFont.truetype(F, px); w = g.textlength(txt, font=f)
        if bg is None: g.text(((size[0] - w) / 2 + 2, y + 2), txt, font=f, fill=(0, 0, 0, 210))
        g.text(((size[0] - w) / 2, y), txt, font=f, fill=col)
    im.save(name)
INK, AMB, MUT, GLOW, DK = (243, 240, 234, 255), (240, 138, 28, 255), (157, 157, 170, 255), (112, 224, 170, 255), (11, 19, 30, 255)
text_png("cap_help.png", [("“I need help.”", 54, 560, (255, 255, 255, 255))])
im_ = Image.new("RGBA", (1280, 720), (0, 0, 0, 0)); g_ = ImageDraw.Draw(im_); g_.text((34, 676), "The real app, simulator recording", font=ImageFont.truetype(F, 17), fill=MUT); im_.save("cap_app.png")
text_png("tag_none.png", [])
text_png("c_yes.png", [("She said yes to one more thing.", 50, 292, INK), ("While she cares for him, the phone keeps count.", 30, 372, GLOW)])
text_png("c_num.png", [("Numbers only. Never pictures.", 60, 286, INK), ("How far each part of the face moved, thirty times a second. No photo or video leaves the phone.", 22, 378, GLOW)], bg=(11, 19, 30, 150))
text_png("c_gem.png", [("Gemini reads the raw numbers. Code checks its work.", 40, 150, INK),
    ("One real run on our server, 14 November", 22, 214, MUT),
    ("Smiles Gemini reported", 26, 300, MUT), ("3", 86, 336, INK),
    ("confirmed by code:  2          dropped by code:  1  (timing off by a second)", 26, 452, GLOW),
    ("Blinks: Gemini 6, code 6", 26, 510, INK),
    ("Only confirmed items reach the clinician.", 22, 600, MUT)], bg=(11, 19, 30, 185))
text_png("c_study.png", [("Whether a phone can follow this is not yet shown.", 38, 236, INK), ("That is the study we want to run.", 38, 300, AMB),
    ("Pilot: 30 people after TMS, 12 weeks, each compared only with themselves.", 23, 410, MUT),
    ("Can people keep it up, and do the numbers move with their own questionnaire score?", 23, 448, MUT),
    ("Not yet tested with patients.", 20, 560, MUT)], bg=DK)
# brand frame
im = Image.open("logo/b.png").convert("RGB").resize((1280, 714)); bg = Image.new("RGB", (1280, 720), im.getpixel((10, 10))); bg.paste(im, (0, -30))
g = ImageDraw.Draw(bg)
for (t, px, y, col) in [("The fox you rescue keeps the light on for you.", 32, 462, (214, 222, 240)), ("lanvi.app", 26, 522, (112, 224, 170)),
                        ("Anna is invented. Story footage is generated; the app, the charts and the numbers are from our system, with example data.", 16, 670, (120, 130, 150))]:
    f = ImageFont.truetype(F, px); w = g.textlength(t, font=f); g.text(((1280 - w) / 2, y), t, font=f, fill=col)
bg.save("c_brand.png")
import random
CH = ["mouthSmileLeft", "mouthSmileRight", "cheekSquintLeft", "cheekSquintRight", "eyeBlinkLeft", "eyeBlinkRight", "browDownLeft", "browInnerUp",
      "jawOpen", "eyeLookDownLeft", "mouthFrownLeft", "headPitch", "headYaw", "headRoll"]
def numbers_wall(name, rows=70):
    """A tall sheet of face-movement rows in the shape the phone sends (channel names from ARKit), to scroll behind a card."""
    random.seed(7); M = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 17)
    im = Image.new("RGB", (1280, rows * 30 + 20), (11, 19, 30)); g = ImageDraw.Draw(im); v = {c: random.random() * 0.2 for c in CH}
    for r in range(rows):
        for c in CH: v[c] = max(0.0, min(1.0, v[c] + random.uniform(-0.05, 0.05)))
        line = f'{{"t": {r/30:.3f}, ' + ", ".join(f'"{c}": {v[c]:.3f}' for c in random.sample(CH, 5)) + "}"
        g.text((24, 10 + r * 30), line, font=M, fill=(46, 74, 96))
    im.save(name)
numbers_wall("wall.png")
def card_wall(png, d, fade=0.3):
    """A card whose text sits over the numbers scrolling upward."""
    o = out(); H = Image.open("wall.png").size[1]
    vf = (f"[0:v]fps=24,crop=1280:720:0:'min({H - 720},t*46)'[w];[1:v]format=rgba[c];[w][c]overlay=0:0,fade=t=in:d={fade}[v]")
    run(["-loop", "1", "-i", "wall.png", "-loop", "1", "-i", png, "-filter_complex", vf, "-map", "[v]", "-t", str(d)] + V + [o]); check(o, d)
def over(src, png, d, ss=0.0, speed=1.0):
    """Words over darkened footage."""
    o = out(); L = dur_of(src) - 0.1
    if ss + d * speed > L: ss = max(0.0, L - d * speed)
    if ss + d * speed > L: speed = (L - ss) / d
    vf = f"[0:v]setpts=PTS/{speed},scale=1280:720,fps=24,eq=brightness=-0.22:saturation=0.8,gblur=sigma=3[b];[b][1:v]overlay=0:0[w];[w][2:v]overlay=0:0[v]"
    run(["-ss", str(ss), "-i", src, "-i", png, "-i", f"{OLD}/tag_gen.png", "-filter_complex", vf, "-map", "[v]", "-t", str(d)] + V + [o]); check(o, d)
n = [0]
def out(): n[0] += 1; return f"seg5/{n[0]:03d}.mp4"
def check(o, d):
    got = dur_of(o); assert abs(got - d) < 0.09, (o, d, got)
def clip(src, d, ss=0.0, speed=1.0, zoom=1.0, fx=0.5, fy=0.5, tag="tag_gen.png", cap=None):
    o = out(); cw, ch = 1280 / zoom, 720 / zoom; L = dur_of(src) - 0.1
    if ss + d * speed > L: ss = max(0.0, L - d * speed)
    if ss + d * speed > L: speed = (L - ss) / d
    tagp = tag if os.path.exists(tag) else f"{OLD}/{tag}"
    vf = f"[0:v]setpts=PTS/{speed},scale=1280:720,crop={cw:.0f}:{ch:.0f}:{(1280-cw)*fx:.0f}:{(720-ch)*fy:.0f},scale=1280:720,fps=24[v];[v][1:v]overlay=0:0[w]"
    ins = ["-ss", str(ss), "-i", src, "-i", tagp]; last = "[w]"
    if cap: ins += ["-i", cap[0]]; vf += f";[w][2:v]overlay=0:0:enable='gte(t,{cap[1]})'[x]"; last = "[x]"
    run(ins + ["-filter_complex", vf, "-map", last, "-t", str(d)] + V + [o]); check(o, d)
def still(src, d, z0=1.0, z1=1.1, fx=0.5, fy=0.5, tag="tag_gen.png", fit=False):
    o = out(); N = int(round(d * 24)); tagp = tag if os.path.exists(tag) else f"{OLD}/{tag}"
    pre = f"scale=2560:1440:force_original_aspect_ratio=decrease,pad=2560:1440:(ow-iw)/2:(oh-ih)/2:color=0x0f0f13" if fit else "scale=2560:1440:force_original_aspect_ratio=increase,crop=2560:1440"
    vf = f"[0:v]{pre},zoompan=z='{z0}+({z1}-{z0})*on/{N}':x='(iw-iw/zoom)*{fx}':y='(ih-ih/zoom)*{fy}':d={N}:s=1280x720:fps=24[v];[v][1:v]overlay=0:0[w]"
    run(["-loop", "1", "-i", src, "-i", tagp, "-filter_complex", vf, "-map", "[w]", "-frames:v", str(N)] + V + [o]); check(o, N / 24)
def card(src, d, fade=0.3):
    o = out(); run(["-loop", "1", "-i", src, "-vf", f"fps=24,fade=t=in:d={fade}", "-t", str(d)] + V + [o]); check(o, d)
def chart(src, d):
    o = out(); run(["-i", src, "-i", f"{OLD}/tag_ex.png", "-filter_complex", "[0:v]fps=24,tpad=stop_mode=clone:stop_duration=9[v];[v][1:v]overlay=0:0", "-t", str(d)] + V + [o]); check(o, d)
def phone(src, d, ss=1.0):
    """The app's own screen, upright in the middle of a dark frame."""
    o = out()
    vf = f"[0:v]fps=24,scale=-2:680,pad=1280:720:(ow-iw)/2:20:color={BGHEX}[v];[v][1:v]overlay=0:0[w]"
    run(["-ss", str(ss), "-i", src, "-i", "cap_app.png", "-filter_complex", vf, "-map", "[w]", "-t", str(d)] + V + [o]); check(o, d)
def split(left, right, d, ss=1.0, app=True):
    """Left: the moment with the fox. Right: the line that moment feeds."""
    o = out()
    lf = f"fps=24,scale=-2:680,pad=640:720:(ow-iw)/2:20:color={BGHEX}" if app else "fps=24,scale=1280:720,crop=640:720:320:0"
    vf = f"[0:v]{lf}[l];[1:v]fps=24,tpad=stop_mode=clone:stop_duration=9[r];[l][r]hstack[v]"
    run(["-ss", str(ss), "-i", left, "-i", right, "-filter_complex", vf, "-map", "[v]", "-t", str(d)] + V + [o]); check(o, d)
G = lambda k: f"{OLD}/clips/{k}.mp4"; K = lambda k: f"clips/{k}.mp4"; S = lambda k: f"stills/{k}.png"; A = lambda k: f"app/{k}.mov"
T = []
def at(t, fn): T.append((t, fn))
# 1 the door closes
at(0.0,  lambda d: clip(G("g1"), d))
at(2.2,  lambda d: clip(G("g2"), d, ss=0.6))
at(5.4,  lambda d: clip(G("g3"), d, ss=0.8))
at(7.6,  lambda d: clip(G("g6"), d))
# 2 she finds him
at(9.4,  lambda d: clip(G("g6"), d, ss=2.6, zoom=1.25, fy=0.6))
at(10.8, lambda d: clip(K("k1"), d))
at(12.5, lambda d: clip(K("k1"), d, ss=2.9, zoom=1.35, fx=0.5, fy=0.2))
at(14.3, lambda d: clip(K("k2"), d, ss=1.6))
at(16.0, lambda d: clip(K("k6"), d))
at(17.2, lambda d: phone(A("home"), d, ss=1.0))                       # "He lives in her phone now."
# 3 one small thing a day, in the real app
at(19.9, lambda d: phone(A("home"), d, ss=3.0))
at(22.7, lambda d: phone(A("focus"), d, ss=2.0))
at(24.0, lambda d: phone(A("breathe"), d, ss=2.0))
at(25.3, lambda d: phone(A("checkin"), d, ss=2.0))
at(27.2, lambda d: clip(G("g4"), d, ss=0.2))                          # "Some days, she would stay in bed."
at(29.9, lambda d: still(S("s5"), d, z0=1.0, z1=1.14, fx=0.4, fy=0.7))   # "For him, she gets up."
# 4 she said yes; every moment with him is a number
at(33.3, lambda d: over(K("k6"), "c_yes.png", d, speed=0.6))
at(41.0, lambda d: split(A("focus"), "single1.mp4", d, ss=3.5))
at(43.6, lambda d: split(A("breathe"), "single0.mp4", d, ss=3.5))
at(47.3, lambda d: card_wall("c_num.png", d))
at(50.8, lambda d: split(G("g6"), "single2.mp4", d, ss=0.5, app=False))
at(53.6, lambda d: card_wall("c_gem.png", d))
# 5 the questionnaire beside the lines
at(59.7, lambda d: chart("chart_a.mp4", d))
at(65.7, lambda d: chart("chart_b.mp4", d))
# 6 November
at(76.3, lambda d: still("chart_end.png", d, z0=1.0, z1=1.07, fx=1.0, fy=0.5, tag="tag_ex.png"))
at(78.0, lambda d: clip(K("k5"), d, ss=0.2, zoom=1.9, fx=0.12, fy=0.8))    # the boots alone
at(80.4, lambda d: clip(K("k4"), d, ss=0.4, cap=("cap_help.png", 1.3)))
at(84.1, lambda d: clip(K("k7"), d, ss=0.6))
at(87.9, lambda d: still(S("morning"), d, z0=1.0, z1=1.05, fx=0.6, fy=0.5))  # the phone buzzes
at(89.3, lambda d: clip(K("k8"), d, speed=0.78))                            # "Anna? I read your note. I'm here."
# 7 honest
at(95.6, lambda d: still(f"{OLD}/screens/r4_anna.jpg", d, z0=1.3, z1=1.4, fx=0.0, fy=0.14, tag="tag_ex.png", fit=True))
at(98.4, lambda d: still(f"{OLD}/screens/r5_elina.jpg", d, z0=1.3, z1=1.4, fx=0.0, fy=0.14, tag="tag_ex.png", fit=True))
at(102.7, lambda d: card("c_study.png", d))
# 8 the name and the motto
at(106.6, lambda d: card("c_brand.png", d, fade=0.8))
END = 116.6
FIXED = {0.0, 87.9, 89.3, 95.6, 106.6}        # cuts that belong to the sound and must not move
B = json.load(open("beats5.json"))
def snap(t, prev):
    best, bs = t, -9
    for b, st in zip(B["beats"], B["strength"]):
        if abs(b - t) <= 0.4 and b - prev >= 0.9:
            sc = min(st, 3.0) - 4.0 * abs(b - t)
            if sc > bs: best, bs = b, sc
    return best
prev = 0.0
for i in range(1, len(T)):
    nt = T[i][0] if T[i][0] in FIXED else snap(T[i][0], prev); T[i] = (nt, T[i][1]); prev = nt
for i, (t, fn) in enumerate(T):
    nxt = T[i + 1][0] if i + 1 < len(T) else END
    fn(round(round((nxt - t) * 24) / 24, 4))
open("list5.txt", "w").write("".join(f"file 'seg5/{i:03d}.mp4'\n" for i in range(1, n[0] + 1)))
run(["-f", "concat", "-safe", "0", "-i", "list5.txt", "-c", "copy", "silent5.mp4"])
FOX, BRAND = T[5][0], T[-1][0]
fc = (f"[1:v]format=rgba,fade=t=in:st={FOX}:d=0.6:alpha=1,fade=t=out:st={BRAND - 0.6}:d=0.6:alpha=1[lg];"
      f"[0:v][lg]overlay=0:0:shortest=0[v1];[v1]fade=t=out:st={END - 1.2}:d=1.2[v];[2:a]afade=t=out:st={END - 1.2}:d=1.2,apad=whole_dur={END}[a]")
run(["-i", "silent5.mp4", "-loop", "1", "-t", str(END), "-i", "logo_corner.png", "-i", "track5.m4a", "-filter_complex", fc,
     "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-t", str(END), "film5.mp4"])
print(round(dur_of("film5.mp4"), 2), "s,", n[0], "shots, picture", round(dur_of("silent5.mp4"), 2))
