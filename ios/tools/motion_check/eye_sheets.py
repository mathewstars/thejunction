# Every frame of a fox clip as eye crops, 120 frames a sheet, each numbered with its time,
# so a fox PR can show (and a reviewer can check) every single frame of the eyes.
#
#   1. Record the spam test on Home (60 fps): launch with
#        -offline -screen home -hour 13 -puppetTaps YES [-puppetLog YES -puppetLogSeconds 27]
#      (two bursts of 25 quick taps, a drag, the frame log in tmp/puppet-frames.csv).
#   2. python3 ios/tools/motion_check/eye_sheets.py clip.mp4 OUTDIR NAME [x0,y0,x1,y1]
#      The crop box is in shares of the frame; the default fits Home on the iPhone 16e.
#   3. Look at every sheet. Attach them to the PR. LanviEyesTests.testRapidTaps... checks
#      the same burst in the maths.
import sys, os, subprocess, glob
from PIL import Image, ImageDraw
clip, out, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
box = tuple(float(v) for v in (sys.argv[4] if len(sys.argv) > 4 else "0.27,0.515,0.73,0.615").split(","))
tmp = os.path.join(out, "_frames"); os.makedirs(tmp, exist_ok=True)
for f in glob.glob(tmp + "/*.png"): os.remove(f)
subprocess.run(["ffmpeg", "-v", "error", "-i", clip, "-vf", "fps=60", tmp + "/f%05d.png"], check=True)
files = sorted(glob.glob(tmp + "/f*.png"))
w, h = Image.open(files[0]).size
b = (int(w*box[0]), int(h*box[1]), int(w*box[2]), int(h*box[3]))
cw, ch = int((b[2]-b[0])*0.6), int((b[3]-b[1])*0.6)
cols, per = 12, 120
for s in range(0, len(files), per):
    chunk = files[s:s+per]
    rows = (len(chunk)+cols-1)//cols
    sheet = Image.new("RGB", (cw*cols, (ch+12)*rows), (255,255,255))
    d = ImageDraw.Draw(sheet)
    for n, f in enumerate(chunk):
        i = s + n
        im = Image.open(f).crop(b).resize((cw, ch))
        x, y = (n % cols)*cw, (n//cols)*(ch+12)
        sheet.paste(im, (x, y+12))
        d.text((x+2, y), "%d  %.2fs" % (i, i/60), fill=(200,0,0))
    sheet.save(os.path.join(out, "%s-%02d-frames-%04d-%04d.png" % (prefix, s//per, s, s+len(chunk)-1)))
for f in files: os.remove(f)
os.rmdir(tmp)
print(len(files), "frames,", (len(files)+per-1)//per, "sheets")
