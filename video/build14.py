# Lanvi submission film (v5): pictures cut to track6.m4a. Run: python3 build5.py
import os, subprocess, json
from PIL import Image, ImageDraw, ImageFont
os.chdir(os.path.dirname(os.path.abspath(__file__)))
OLD = ".."; F = "/System/Library/Fonts/Helvetica.ttc"; BGHEX = "0x0b131e"; CHBG = "0x0f0e13"
V = "-c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -r 24 -an".split()
os.system("rm -rf seg8"); os.makedirs("seg8")
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
_t = Image.open(f"{OLD}/tag_gen.png").convert("RGBA"); _g = ImageDraw.Draw(_t); _f = ImageFont.truetype(F, 34); _s = "The next morning, her clinic calls."
_w = _g.textlength(_s, font=_f); _g.text(((1280 - _w) / 2 + 2, 602), _s, font=_f, fill=(0, 0, 0, 220)); _g.text(((1280 - _w) / 2, 600), _s, font=_f, fill=(255, 255, 255, 255)); _t.save("tag_morning.png")
text_png("c_yes.png", [("She said yes.", 56, 286, INK), ("While she cares for him, the phone keeps count.", 30, 372, GLOW)])
text_png("c_num.png", [("Numbers only. Never pictures.", 60, 286, INK), ("How far each part of the face moved, thirty times a second. No photo or video leaves the phone.", 22, 378, GLOW)], bg=(11, 19, 30, 150))
text_png("c_gem.png", [("Gemini reads them. Code checks its work.", 44, 146, INK),
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
    o = out(); L = dur_of(src) - 0.1; speed = min(1.0, (L - ss) / d)
    slow = ",minterpolate=fps=24:mi_mode=mci:mc_mode=aobmc:vsbmc=1" if speed < 0.985 else ""
    vf = f"[0:v]setpts=PTS/{speed}{slow},scale=1280:720,fps=24,eq=brightness=-0.22:saturation=0.8,gblur=sigma=3[b];[b][1:v]overlay=0:0[w];[w][2:v]overlay=0:0[v]"
    run(["-ss", str(ss), "-i", src, "-i", png, "-i", f"{OLD}/tag_gen.png", "-filter_complex", vf, "-map", "[v]", "-t", str(d)] + V + [o]); check(o, d)
MCI = ",minterpolate=fps=24:mi_mode=mci:mc_mode=aobmc:vsbmc=1"      # slow motion from computed in-between frames, never repeated ones
def windows(src, d, wins, ss=0.0, tag=None, dim=-0.10, fin=0.0, fout=0.0, wfade=0.3):
    """The clip (or still) stays as it was; framed windows come up over it and fade out again before the cut."""
    o = out(); img = src.endswith(".png")
    if img:
        ins = ["-loop", "1", "-t", str(d), "-i", src]; vf = f"[0:v]scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720,fps=24,eq=brightness={dim}[b0];"
    else:
        L = dur_of(src) - 0.1; speed = min(1.0, (L - ss) / d); ins = ["-ss", str(ss), "-i", src]
        vf = f"[0:v]setpts=PTS/{speed}{MCI if speed < 0.985 else ''},scale=1280:720,fps=24,eq=brightness={dim}[b0];"
    cur = "[b0]"
    for i, (png, a, b) in enumerate(wins):
        oe = min(b, d); ins += ["-loop", "1", "-t", str(d), "-i", png]
        vf += f"[{i+1}:v]format=rgba,fade=t=in:st={a}:d={wfade}:alpha=1,fade=t=out:st={oe - wfade - 0.02:.3f}:d={wfade}:alpha=1[w{i}];{cur}[w{i}]overlay=0:0:enable='between(t,{a},{oe})'[b{i+1}];"; cur = f"[b{i+1}]"
    fades = (f",fade=t=in:d={fin}" if fin else "") + (f",fade=t=out:st={d - fout:.3f}:d={fout}" if fout else "")
    ins += ["-i", tag or f"{OLD}/tag_gen.png"]; vf += f"{cur}[{len(wins)+1}:v]overlay=0:0{fades}[v]"
    run(ins + ["-filter_complex", vf, "-map", "[v]", "-t", str(d)] + V + [o]); check(o, d)
AURORA = "0x8CF0C8"
def into_phone(src, d, fx=0.42, fy=0.74):
    """Our own version of the reveal, used only if the generated one is missing."""
    o = out(); N = int(round(d * 24))
    vf = (f"[0:v]scale=3840:2160:force_original_aspect_ratio=increase,crop=3840:2160,"
          f"zoompan=z='1+pow(on/{N},2.2)*5.0':x='(iw-iw/zoom)*{fx}':y='(ih-ih/zoom)*{fy}':d={N}:s=1280x720:fps=24,"
          f"fade=t=out:st={d - 0.75:.3f}:d=0.75:color={AURORA}[v];[v][1:v]overlay=0:0[w]")
    run(["-loop", "1", "-i", src, "-i", f"{OLD}/tag_gen.png", "-filter_complex", vf, "-map", "[w]", "-frames:v", str(N)] + V + [o]); check(o, N / 24)
def from_light(fn_out, d, fin=0.7):
    """The next shot comes up out of the same light."""
    o2 = fn_out.replace(".mp4", "_f.mp4")
    run(["-i", fn_out, "-vf", f"fade=t=in:d={fin}:color={AURORA}", "-t", str(d)] + V + [o2]); os.replace(o2, fn_out)
def measure_screen(app_src, panel, d, ss=1.0):
    """One calm screen for the three measures: the app on the left, the three lines arriving on the right."""
    o = out()
    vf = f"[0:v]fps=24,scale=-2:624,pad=640:720:(ow-iw)/2:16:color={BGHEX}[l];[1:v]fps=24,tpad=stop_mode=clone:stop_duration=9,scale=576:648,pad=640:720:32:0:color={CHBG}[r];[l][r]hstack[v]"
    run(["-stream_loop", "3", "-ss", str(ss), "-i", app_src, "-i", panel, "-filter_complex", vf, "-map", "[v]", "-t", str(d)] + V + [o]); check(o, d)
def two_step_card(first, second, d, at2):
    """One card over the scrolling numbers: the first statement, then the second joins it."""
    o = out(); H = Image.open("wall.png").size[1]
    vf = (f"[0:v]fps=24,crop=1280:720:0:'min({H - 720},t*40)'[w];[1:v]format=rgba[a];[2:v]format=rgba,fade=t=in:st={at2}:d=0.5:alpha=1[b];"
          f"[w][a]overlay=0:0[x];[x][b]overlay=0:0:enable='gte(t,{at2})',fade=t=in:d=0.3[v]")
    run(["-loop", "1", "-i", "wall.png", "-loop", "1", "-i", first, "-loop", "1", "-t", str(d), "-i", second, "-filter_complex", vf, "-map", "[v]", "-t", str(d)] + V + [o]); check(o, d)
text_png("c8_num.png", [("Numbers only. Never pictures.", 56, 150, INK), ("How far each part of the face moved, thirty times a second. No photo or video leaves the phone.", 21, 232, GLOW)], bg=(11, 19, 30, 165))
text_png("c8_gem.png", [("Gemini reads them. Code checks its work.", 40, 372, INK), ("One real run on our server:  3 smiles reported   \u00b7   2 confirmed by code   \u00b7   1 dropped", 24, 440, GLOW), ("Only confirmed items reach the clinician.", 21, 492, MUT)])
n = [0]
def out(): n[0] += 1; return f"seg8/{n[0]:03d}.mp4"
def check(o, d):
    got = dur_of(o); assert abs(got - d) < 0.09, (o, d, got)
def clip(src, d, ss=0.0, speed=1.0, zoom=1.0, fx=0.5, fy=0.5, tag="tag_gen.png", cap=None):
    o = out(); cw, ch = 1280 / zoom, 720 / zoom; L = dur_of(src) - 0.1
    if ss + d * speed > L: ss = max(0.0, L - d * speed)
    if ss + d * speed > L: speed = (L - ss) / d
    tagp = tag if os.path.exists(tag) else f"{OLD}/{tag}"
    slow = ",minterpolate=fps=24:mi_mode=mci:mc_mode=aobmc:vsbmc=1" if speed < 0.985 else ""
    vf = f"[0:v]setpts=PTS/{speed}{slow},scale=1280:720,crop={cw:.0f}:{ch:.0f}:{(1280-cw)*fx:.0f}:{(720-ch)*fy:.0f},scale=1280:720,fps=24[v];[v][1:v]overlay=0:0[w]"
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
    o = out(); run(["-i", src, "-i", f"{OLD}/tag_ex.png", "-filter_complex", f"[0:v]fps=24,tpad=stop_mode=clone:stop_duration=9,scale=1152:648,pad=1280:720:64:0:color={CHBG}[v];[v][1:v]overlay=0:-58", "-t", str(d)] + V + [o]); check(o, d)
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
# v8: new, brighter footage; one untouched Suno take (v14/track14.m4a); the same data on screen as v6.
C = lambda k: f"v8/clips/{k}.mp4"; N8 = lambda k: f"v8/stills/{k}.png"
def have(k): return os.path.exists(C(k))
# RULES (14 Nov): a clip is shown once only, and every footage shot runs 4 s or more at natural speed.
USED = {}
def rule(k, d, ss=0.0, **kw):
    """One footage shot: checks the two rules, then cuts it."""
    assert k not in USED, f"clip {k} used twice"; USED[k] = d
    L = dur_of(C(k)) - 0.1; assert d >= 3.99, f"{k}: shot of {d} s is under 4 s"; assert d <= L + 0.02, f"{k}: shot of {d} s is longer than the clip ({L:.2f})"
    return min(ss, max(0.0, L - d)), kw
def fclip(k, d, ss=0.0, **kw):
    ss, kw = rule(k, d, ss, **kw); clip(C(k), d, ss=ss, **kw)
def over_once(k, png, d, ss=0.0):
    """Words over darkened footage at natural speed; when the clip ends the backdrop has already faded to the dark ground."""
    USED[k] = d if k not in USED else 1 / 0
    o = out(); L = dur_of(C(k)) - 0.1 - ss; assert L >= d, f"{k}: the clip ({L:.2f} s) ends before the card does ({d} s)"
    vf = (f"[0:v]scale=1280:720,fps=24,eq=brightness=-0.22:saturation=0.8,gblur=sigma=3[b];"
          f"[b][1:v]overlay=0:0[w];[w][2:v]overlay=0:0[v]")
    run(["-ss", str(ss), "-i", C(k), "-i", png, "-i", f"{OLD}/tag_gen.png", "-filter_complex", vf, "-map", "[v]", "-t", str(d)] + V + [o]); check(o, d)
def reveal(d):
    ss, _ = rule("reveal", d, 0.85); clip(C("reveal"), d, ss=ss); o = f"seg8/{n[0]:03d}.mp4"
    run(["-i", o, "-vf", f"fade=t=out:st={d - 0.45:.3f}:d=0.45:color={AURORA}", "-t", str(d)] + V + [o.replace(".mp4", "_f.mp4")]); os.replace(o.replace(".mp4", "_f.mp4"), o)
def app_from_light(d):
    phone(A("home"), d, ss=1.0); from_light(f"seg8/{n[0]:03d}.mp4", d)
def win_shot(k, d, png, a, ss=0.0, slide=0):
    """One footage shot with one framed window over it for the whole shot: it comes in at `a` (sliding up by `slide` px if asked) and fades out just before the cut."""
    ss, _ = rule(k, d, ss); o = out()
    y = f"if(lt(t,{a + 0.7}),{slide}*pow(1-(t-{a})/0.7,2),0)" if slide else "0"
    vf = (f"[0:v]scale=1280:720,fps=24,eq=brightness=-0.10[b];[1:v]format=rgba,fade=t=in:st={a}:d=0.5:alpha=1,fade=t=out:st={d - 0.45:.3f}:d=0.4:alpha=1[w];"
          f"[b][w]overlay=x=0:y='{y}':eval=frame:enable='gte(t,{a})'[x];[x][2:v]overlay=0:0[v]")
    run(["-ss", str(ss), "-i", C(k), "-loop", "1", "-t", str(d), "-i", png, "-i", f"{OLD}/tag_gen.png", "-filter_complex", vf, "-map", "[v]", "-t", str(d)] + V + [o]); check(o, d)
def nurse_shot(d): win_shot("nurse", d, "w_tg.png", 0.25, slide=110)       # the alert slides up and stays for the whole shot
GETUP_SS = 2.9; PICK_SS = 0.2
# v13: a slower take with a pause before "I'm here." (v14/track14.m4a, Suno song bc8a5409).
text_png("c11_a.png", [("This is not a habit tracker.", 58, 190, INK)], bg=(11, 19, 30, 165))
text_png("c11_b.png", [("She said yes.", 46, 330, INK), ("While she plays, the phone may measure.", 23, 398, GLOW)])
def screen(src, d):
    o = out(); run(["-i", src, "-vf", "fps=24,tpad=stop_mode=clone:stop_duration=9", "-t", str(d)] + V + [o]); check(o, d)
at(0.0,  lambda d: fclip("exit", d, ss=0.2))
at(4.4,  lambda d: fclip("card", d, ss=0.3))
at(8.9,  lambda d: fclip("pickup", d, ss=PICK_SS, zoom=1.2, fx=0.3, fy=0.55))
at(16.2, reveal)
at(20.2, app_from_light)
at(23.3, lambda d: fclip("getup", d, ss=GETUP_SS))
at(30.3, lambda d: two_step_card("c11_a.png", "c11_b.png", d, at2=4.2))            # not a habit tracker; she said yes
at(36.6, lambda d: measure_screen(A("focus"), "v13/stream.mp4", d))                # what leaves the phone while she plays
at(46.9, lambda d: screen("v13/check.mp4", d))                                     # rules notice, two models weigh in, code checks
at(61.2, lambda d: fclip("november", d, ss=0.05))
at(65.9, lambda d: fclip("night", d, cap=("cap_help.png", 3.2)))
at(70.8, nurse_shot)                                                               # "Her words reach her clinic.": the alert, for the whole shot
at(74.8, lambda d: fclip("curtains", d, ss=0.1))                                   # "Next morning, her nurse calls."
at(79.6, lambda d: win_shot("nurse2", d, "w_anna_left.png", 0.3, ss=0.05))         # "Anna, I read your note.": the clinic page beside her
at(84.4, lambda d: fclip("call", d, ss=0.4))                                       # "I'm here."
at(88.4, lambda d: fclip("return", d, ss=0.0))                                    # "This time, she doesn't wait six weeks."
at(93.35, lambda d: card("c_brand6.png", d, fade=0.8))
AEND = 102.6; END = 102.6
FIXED = {t for t, _ in T}                                   # every cut is placed by hand; none is moved onto a beat
B = json.load(open("v8/beats8.json"))
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
open("list8.txt", "w").write("".join(f"file 'seg8/{i:03d}.mp4'\n" for i in range(1, n[0] + 1)))
run(["-f", "concat", "-safe", "0", "-i", "list8.txt", "-c", "copy", "silent8.mp4"])
FOX, BRAND = T[3][0], T[-1][0]
# Subtitles: every spoken line, at the times of the take itself. Lines that a card already shows in full, the big
# "I need help." caption and the closing frame (which carries the motto) are not doubled.
SUBS = [
 (1.2, 3.7, "Anna\u2019s treatment for depression is over."), (4.9, 7.4, "The next appointment is six weeks away."),
 (9.4, 13.9, "On the way home, she finds a fox cub, alone in the snow."), (15.3, 16.25, "She picks him up."), (16.4, 18.7, "And he steps into her phone."),
 (20.3, 22.8, "Every day she does one small thing for him."), (23.8, 25.8, "Some days, she would stay in bed."), (26.6, 28.5, "For him, she gets up."),
 (37.3, 40.5, "While she plays, the phone reads how her face moves,"), (40.6, 42.2, "thirty times a second."), (43.1, 46.2, "Numbers only, never pictures."),
 (47.9, 50.4, "At the clinic, rules notice a change."), (51.6, 53.6, "Two models weigh in."), (55.4, 56.7, "Code checks every claim,"), (57.8, 60.5, "and drops what the numbers don\u2019t support."),
 (61.9, 64.6, "In November, hard days return."), (66.8, 68.8, "At one a.m. she writes:"),
 (71.4, 73.6, "Her words reach her clinic."), (74.9, 77.8, "Next morning, her nurse calls."), (80.3, 83.9, "\u201cAnna, I read your note.\u201d"), (85.1, 86.8, "\u201cI\u2019m here.\u201d"),
 (88.5, 92.9, "This time, she doesn\u2019t wait six weeks."),
]
os.makedirs("subs8", exist_ok=True); SF = ImageFont.truetype(F, 30)
ins = ["-i", "silent8.mp4", "-loop", "1", "-t", str(END), "-i", "logo_corner.png", "-i", "v14/track14.m4a"]
fc = (f"[1:v]format=rgba,fade=t=in:st={FOX}:d=0.6:alpha=1,fade=t=out:st={BRAND - 0.6}:d=0.6:alpha=1[lg];[0:v][lg]overlay=0:0:shortest=0[s0];")
for i, (a, b, txt) in enumerate(SUBS):
    im = Image.new("RGBA", (1280, 720), (0, 0, 0, 0)); g = ImageDraw.Draw(im); w = g.textlength(txt, font=SF); x = (1280 - w) / 2
    g.rounded_rectangle((x - 18, 664, x + w + 18, 710), 10, fill=(6, 10, 16, 215)); g.text((x, 670), txt, font=SF, fill=(255, 255, 255, 255)); im.save(f"subs8/{i:02d}.png")
    ins += ["-loop", "1", "-t", str(END), "-i", f"subs8/{i:02d}.png"]
    fc += f"[s{i}][{i+3}:v]overlay=0:0:enable='between(t,{a},{b})'[s{i+1}];"
fc += f"[s{len(SUBS)}]fade=t=out:st={END - 1.2}:d=1.2[v];[2:a]afade=t=out:st={AEND - 2.2}:d=2.2,apad=whole_dur={END}[a]"
run(ins + ["-filter_complex", fc, "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-t", str(END), "film14.mp4"])
print(round(dur_of("film14.mp4"), 2), "s,", n[0], "shots, picture", round(dur_of("silent8.mp4"), 2))
