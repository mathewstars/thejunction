"""Turn Lanvi's green-screen video clips into see-through clips for the app.

Usage (from the repo root; needs ffmpeg 6+ on PATH, Python standard library only):
    python3 ios/tools/fox_clips.py check  /path/to/clips      # measure + contact sheets
    python3 ios/tools/fox_clips.py build  /path/to/clips      # write the app's clips
    python3 ios/tools/fox_clips.py build  /path/to/clips idle look   # only some
    python3 ios/tools/fox_clips.py compare /path/to/clips happy 2.0  # 24 vs 60 fps sheet

The clips (made on the team's Higgsfield account) are 5 s, 24 fps, 1440 x 1440: the
fox sitting on flat pure green, starting and ending on the same rest pose, so any
clip can follow any other. Re-run `build` when a better clip arrives.

What `build` does to each clip:
- crops the same square around the fox for every clip (`CROP`), so the fox never
  shifts between clips,
- optionally makes 60 fps in-between frames (ffmpeg `minterpolate`, motion-
  compensated) where that looks cleaner than the plain 24 fps (`INTERPOLATE`),
- removes the green: alpha from how much greener than red a pixel is (the fox is
  blue and white, so its own green never exceeds its red by much), then takes the
  green back out of the soft edge pixels (un-mixing with the measured background)
  and clamps any leftover green to the red/blue average, so no green fringe and no
  dark halo shows on the night or the day scene,
- fades the last few frames into the shared rest frame, so a clip always ends on
  exactly the picture the next one starts with,
- scales to `SIZE`, premultiplies colour by alpha (what the iOS video layer
  expects) and encodes HEVC with alpha (`hevc_videotoolbox`, tag hvc1, no audio)
  to ios/Lanvi/Mascot/Clips/Media/fox-<name>.mov,
- writes the rest frame as a picture (shown before the first clip is ready, and
  with Reduce Motion): Assets.xcassets/fox-clip-rest.imageset.

`check` writes contact sheets (4 frames a second) and prints, per clip: the
background colour, the fox's box over all frames, how far the fox drifts, and how
close the last frame is to the first (PSNR; above ~32 dB is invisible at a switch).
"""

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / "ios/Lanvi/Mascot/Clips/Media"
REST_SET = ROOT / "ios/Lanvi/Assets.xcassets/fox-clip-rest.imageset"
ART_SWIFT = ROOT / "ios/Lanvi/Mascot/Clips/FoxClipArt.swift"
SHEETS = Path(tempfile.gettempdir()) / "lanvi-fox-clips"

ALL = ["idle", "look", "happy", "talk", "sleepy", "wave", "listen", "pet", "giggle", "nod"]
# Clips not shipped, and why (judged from their contact sheets).
SKIP = {
    "wave": "the fox swings a front leg as an arm (rejected in ios/HANDOFF.md) and the arm stretches oddly across the body",
}
# The same square for every clip, in source pixels (x, y, side). Even numbers (4:2:0).
# The rest fox spans x 326..1016, y 380..1183; all clips together x 136..1122, y 326..1186
# (happy's tail swings far left, sleepy's ears flop right).
CROP = (124, 192, 1016)
SIZE = 960              # output square, pixels
# 24 -> 60 fps with motion-compensated in-betweens, per clip (False keeps 24 fps).
INTERPOLATE = {name: True for name in ALL}
FADE_FRAMES = 6         # source frames (at 24 fps) faded into the rest frame at the end
THREADS = "4"
KEY_VERSION = 1         # bump when `key_filter` or the fade changes
QUALITY = "60"          # hevc_videotoolbox -q:v (higher = better, bigger)
ALPHA_Q = "0.8"         # quality of the alpha layer, 0...1


def ff(*args, capture=False):
    cmd = ["ffmpeg", "-hide_banner", "-v", "error", "-threads", THREADS,
           "-filter_threads", THREADS, "-filter_complex_threads", THREADS, "-y", *args]
    if capture:
        return subprocess.run(cmd, check=True, capture_output=True, text=True).stderr
    subprocess.run(cmd, check=True)


def rgb_at(clip, frame, x, y, w, h):
    """Mean colour of a box in one frame."""
    out = subprocess.run(
        ["ffmpeg", "-v", "error", "-threads", THREADS, "-i", str(clip), "-vf",
         f"select=eq(n\\,{frame}),scale=flags=bicubic+full_chroma_int+accurate_rnd,format=rgb24,"
         f"crop={w}:{h}:{x}:{y},scale=1:1:flags=area", "-frames:v", "1", "-f", "rawvideo", "-"],
        check=True, capture_output=True).stdout
    return tuple(out[:3])


def background(clip):
    """The green, from the four corners of the middle frame."""
    cs = [rgb_at(clip, 60, x, y, 48, 48) for x, y in [(0, 0), (1392, 0), (0, 1392), (1392, 1392)]]
    return tuple(round(sum(c[i] for c in cs) / 4) for i in range(3))


def key_filter(bg):
    """geq expressions: alpha from (g - r), un-mix the edge, clamp leftover green.
    Each plane's expression stores alpha (0) and the un-mixed red (1) and blue (2)."""
    br, bgg, bb = bg
    span = max(bgg - br - 56, 100)      # g - r of the background minus the fox's own
    a = f"st(0\\,clip(1-(g(X\\,Y)-r(X\\,Y)-40)/{span}\\,0\\,1))"
    d = "max(ld(0)\\,0.02)"
    ur = f"clip((r(X\\,Y)-(1-ld(0))*{br})/{d}\\,0\\,255)"
    ub = f"clip((b(X\\,Y)-(1-ld(0))*{bb})/{d}\\,0\\,255)"
    ug = (f"{a};st(1\\,{ur});st(2\\,{ub});"
          f"min(clip((g(X\\,Y)-(1-ld(0))*{bgg})/{d}\\,0\\,255)\\,(ld(1)+ld(2))/2)")
    return f"geq=r='{a};{ur}':g='{ug}':b='{a};{ub}':a='{a}*255'"


def to_rgb():
    return "scale=flags=bicubic+full_chroma_int+accurate_rnd,format=gbrap"


def frames_of(clip):
    out = subprocess.run(["ffprobe", "-v", "error", "-count_packets", "-select_streams", "v:0",
                          "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", str(clip)],
                         check=True, capture_output=True, text=True).stdout
    return int(out.strip())


def bbox_per_frame(clip, bg):
    log = subprocess.run(
        ["ffmpeg", "-hide_banner", "-v", "info", "-threads", THREADS, "-filter_threads", THREADS,
         "-i", str(clip), "-vf",
         f"scale=720:720:flags=area,{to_rgb()},{key_filter(bg)},alphaextract,format=gray,bbox=min_val=96",
         "-f", "null", "-"], check=True, capture_output=True, text=True).stderr
    boxes = []
    for m in re.finditer(r"x1:(\d+) x2:(\d+) y1:(\d+) y2:(\d+)", log):
        boxes.append(tuple(int(v) * 2 for v in m.groups()))   # back to 1440 pixels
    return boxes


def psnr(a, fa, b, fb):
    log = subprocess.run(
        ["ffmpeg", "-hide_banner", "-v", "info", "-threads", THREADS, "-i", str(a), "-i", str(b),
         "-lavfi", f"[0]select=eq(n\\,{fa}),setpts=0[x];[1]select=eq(n\\,{fb}),setpts=0[y];[x][y]psnr",
         "-f", "null", "-"], check=True, capture_output=True, text=True).stderr
    m = re.search(r"average:([\d.]+|inf)", log)
    return float(m.group(1)) if m else -1.0


def check(src, names):
    SHEETS.mkdir(parents=True, exist_ok=True)
    idle = src / "idle.mp4"
    x, y, s = CROP
    report = {}
    for n in names:
        clip = src / f"{n}.mp4"
        if not clip.exists():
            print(f"{n}: missing")
            continue
        nf = frames_of(clip)
        bg = background(clip)
        boxes = bbox_per_frame(clip, bg)
        ux1 = min(b[0] for b in boxes); ux2 = max(b[1] for b in boxes)
        uy1 = min(b[2] for b in boxes); uy2 = max(b[3] for b in boxes)
        feet = [b[3] for b in boxes]
        seam = psnr(clip, 0, clip, nf - 1)
        vs_idle = psnr(clip, 0, idle, 0) if n != "idle" else 99
        inside = ux1 >= x and uy1 >= y and ux2 <= x + s and uy2 <= y + s
        report[n] = dict(frames=nf, bg=bg, box=(ux1, uy1, ux2, uy2), feet=(min(feet), max(feet)),
                         seam_db=seam, start_vs_idle_db=vs_idle, inside_crop=inside)
        print(f"{n}: {nf} frames, bg {bg}, box x {ux1}..{ux2} y {uy1}..{uy2}, feet {min(feet)}..{max(feet)}, "
              f"last~first {seam:.1f} dB, first~idle {vs_idle:.1f} dB, inside crop {inside}"
              + (f"  [skipped: {SKIP[n]}]" if n in SKIP else ""))
        ff("-i", str(clip), "-vf", f"fps=4,crop={s}:{s}:{x}:{y},scale=280:280,tile=7x3",
           "-frames:v", "1", str(SHEETS / f"{n}.png"))
    (SHEETS / "report.json").write_text(json.dumps(report, indent=1))
    print(f"contact sheets: {SHEETS}")


def keyed(src, n, rest_png):
    """The clip keyed, cropped, scaled, at its final frame rate, losslessly (FFV1), in
    the temp folder (kept with FOX_KEEP=1 so encoder settings can be tried quickly)."""
    clip = src / f"{n}.mp4"
    fps = 60 if INTERPOLATE.get(n, True) else 24
    # Named by the settings that shape it, so a changed key or crop redoes it.
    tag = f"{CROP[0]}-{CROP[1]}-{CROP[2]}-{SIZE}-{fps}-k{KEY_VERSION}"
    out = SHEETS / f"{n}-keyed-{tag}.mkv"
    if out.exists() and out.stat().st_mtime > clip.stat().st_mtime:
        return out, fps
    x, y, s = CROP
    bg = background(clip)
    dur = frames_of(clip) / 24.0
    fade = FADE_FRAMES / 24.0
    interp = ("minterpolate=fps=60:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1:scd=none,"
              if fps == 60 else "")
    # The rest frame held still, faded in over the clip's last frames.
    w = f"clip((T-{dur - fade:.4f})/{fade:.4f}\\,0\\,1)"
    graph = (
        f"[0]crop={s}:{s}:{x}:{y},scale={SIZE}:{SIZE}:flags=lanczos,format=yuv444p,{interp}"
        f"{to_rgb()},{key_filter(bg)},setpts=N/{fps}/TB[clip];"
        f"[1]format=gbrap,loop=loop=-1:size=1,fps={fps},setpts=N/{fps}/TB[rest];"
        f"[clip][rest]blend=all_expr='A*(1-{w})+B*{w}':shortest=1[out]"
    )
    ff("-i", str(clip), "-i", str(rest_png), "-filter_complex", graph, "-map", "[out]",
       "-an", "-c:v", "ffv1", "-r", str(fps), str(out))
    return out, fps


def build_one(src, n, rest_png):
    lossless, fps = keyed(src, n, rest_png)
    out = MEDIA / f"fox-{n}.mov"
    # The app's video layer reads colour as premultiplied by alpha (a straight-alpha
    # clip shows coloured blocks where it should be clear), so premultiply here.
    ff("-i", str(lossless), "-vf", "format=gbrap,premultiply=inplace=1,format=bgra", "-an",
       "-c:v", "hevc_videotoolbox",
       "-alpha_quality", ALPHA_Q, "-q:v", QUALITY, "-tag:v", "hvc1", "-r", str(fps),
       "-movflags", "+faststart", str(out))
    print(f"{n}: {fps} fps -> {out.relative_to(ROOT)} ({out.stat().st_size / 1e6:.2f} MB)", flush=True)
    # The lossless file is ~140 MB; keep it only to try encoder settings (FOX_KEEP=1).
    if not os.environ.get("FOX_KEEP"):
        lossless.unlink()


def alpha_box(png, band=None):
    """Box of the solid part of a keyed picture (optionally of a band of rows)."""
    crop = f"crop=iw:{band[1] - band[0]}:0:{band[0]}," if band else ""
    log = subprocess.run(
        ["ffmpeg", "-hide_banner", "-v", "info", "-i", str(png), "-vf",
         f"{crop}alphaextract,format=gray,bbox=min_val=128", "-f", "null", "-"],
        check=True, capture_output=True, text=True).stderr
    m = re.search(r"x1:(\d+) x2:(\d+) y1:(\d+) y2:(\d+)", log)
    x1, x2, y1, y2 = (int(v) for v in m.groups())
    off = band[0] if band else 0
    return x1, x2 + 1, y1 + off, y2 + 1 + off


def write_art(rest):
    """Where the rest fox sits in the clip frame, for `LanviClipView` to line it up
    with the puppet: ear tips, paws, and the centre of the head (not the tail)."""
    _, _, top, feet = alpha_box(rest)
    hx1, hx2, _, _ = alpha_box(rest, (top, top + int((feet - top) * 0.45)))
    centre = (hx1 + hx2) / 2
    ART_SWIFT.write_text(f"""import CoreGraphics

// Written by ios/tools/fox_clips.py from the rest frame. Fractions of the clip frame.
enum FoxClipArt {{
    /// The ear tips at rest.
    static let earTop: CGFloat = {top / SIZE:.4f}
    /// The bottom of the paws (the ground line).
    static let feet: CGFloat = {feet / SIZE:.4f}
    /// The middle of the head, the fox's visual centre (the tail hangs out to the left).
    static let centerX: CGFloat = {centre / SIZE:.4f}
}}
""")
    print(f"rest fox: ears {top}, paws {feet}, centre x {centre} of {SIZE}")


def build(src, names):
    SHEETS.mkdir(parents=True, exist_ok=True)
    MEDIA.mkdir(parents=True, exist_ok=True)
    REST_SET.mkdir(parents=True, exist_ok=True)
    x, y, s = CROP
    # The shared rest frame: the idle clip's first frame, keyed, at full crop size.
    idle = src / "idle.mp4"
    rest = REST_SET / "fox-clip-rest.png"
    ff("-i", str(idle), "-vf",
       f"select=eq(n\\,0),crop={s}:{s}:{x}:{y},scale={SIZE}:{SIZE}:flags=lanczos,format=yuv444p,"
       f"{to_rgb()},{key_filter(background(idle))},format=rgba", "-frames:v", "1", str(rest))
    (REST_SET / "Contents.json").write_text(json.dumps(
        {"images": [{"filename": "fox-clip-rest.png", "idiom": "universal"}],
         "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    write_art(rest)
    for n in names:
        if n in SKIP:
            print(f"{n}: skipped ({SKIP[n]})")
            continue
        if not (src / f"{n}.mp4").exists():
            print(f"{n}: missing")
            continue
        build_one(src, n, rest)


def compare(src, name, at):
    """Contact sheet of 0.5 s from `at`: the plain 24 fps frames (top, 12) and the
    60 fps in-betweens (below, 30), on the night colour, to judge `INTERPOLATE`."""
    SHEETS.mkdir(parents=True, exist_ok=True)
    x, y, s = CROP
    clip = src / f"{name}.mp4"
    bg = background(clip)
    out = SHEETS / f"compare-{name}-{at:g}.png"
    base = (f"crop={s}:{s}:{x}:{y},scale=480:480:flags=lanczos,format=yuv444p,{{interp}}"
            f"{to_rgb()},{key_filter(bg)},trim=start={at}:duration=0.5,setpts=PTS-STARTPTS")
    night = "color=c=0x0E1A3A:s=480x480"
    graph = (
        f"[0]split[a][b];[a]{base.format(interp='')}[p24];"
        f"[b]{base.format(interp='minterpolate=fps=60:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1:scd=none,')}[p60];"
        f"{night},trim=end_frame=12[n24];{night},trim=end_frame=30[n60];"
        f"[n24][p24]overlay=format=auto:shortest=1,tile=12x1[t24];"
        f"[n60][p60]overlay=format=auto:shortest=1,tile=12x3[t60];"
        f"[t24][t60]vstack"
    )
    ff("-i", str(clip), "-filter_complex", graph, "-frames:v", "1", str(out))
    print(out)


def main():
    if len(sys.argv) >= 5 and sys.argv[1] == "compare":
        return compare(Path(sys.argv[2]), sys.argv[3], float(sys.argv[4]))
    if len(sys.argv) < 3 or sys.argv[1] not in ("check", "build"):
        print(__doc__)
        sys.exit(1)
    src = Path(sys.argv[2])
    names = sys.argv[3:] or ALL
    (check if sys.argv[1] == "check" else build)(src, names)


if __name__ == "__main__":
    main()
