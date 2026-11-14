# Soundtrack of the submission film: Suno's own mixes, uncut inside sentences.
# A = narrator take up to the chart; B, D, E = the last-part take; in between a phone buzz and the nurse's line.
import subprocess, json
def sh(a):
    r = subprocess.run(a, capture_output=True, text=True)
    if r.returncode: print(r.stderr[-600:])
    return r
T = dict(A=0.0, B=76.3, RING=87.9, NURSE=89.3, D=95.6, E=106.6, END=116.6)
ms = lambda t: int(t * 1000)
N = "loudnorm=I=-16:TP=-1.5:LRA=9"
# Every change of take is a fade, never a switch: the outgoing piano fades after the last word,
# the incoming one fades in during the pause before the next word. Source times are those of the takes.
def part(tag, src, a, b, at, fin, fout):
    d = b - a
    return f"[{src}]atrim={a}:{b},asetpts=PTS-STARTPTS,afade=t=in:d={fin}:curve=qsin,afade=t=out:st={d - fout:.2f}:d={fout}:curve=qsin,adelay={ms(at)}:all=1[{tag}];"
fc = (
 f"[0:a]{N}[n0];[1:a]{N},asplit=3[x1][x2][x3];"
 + part("a", "n0", 0.0, 76.7, 0.0, 0.01, 1.5)                 # last word ends 75.1; the piano fades to 76.7
 + part("b", "x1", 0.0, 11.15, T["B"], 0.35, 0.7)             # the take's own opening; voice ends 10.4
 + part("d", "x2", 10.5, 21.5, T["D"] - 0.4, 0.6, 0.65)       # in during the pause before "Anna is invented"
 + part("e", "x3", 20.9, 30.6, T["E"] - 0.5, 0.6, 1.4)        # in during the pause before "Lanvi"
 + f"[2:a]atrim=0:5.7,asetpts=PTS-STARTPTS,highpass=f=220,lowpass=f=3800,loudnorm=I=-17:TP=-2,afade=t=in:d=0.05,afade=t=out:st=5.3:d=0.4,adelay={ms(T['NURSE'])}:all=1[n];"
 f"sine=f=150:d=1.1,tremolo=f=28:d=0.9,volume=0.10,afade=t=in:d=0.05,afade=t=out:st=0.9:d=0.2,adelay={ms(T['RING'])}:all=1[r];"
 f"anoisesrc=color=pink:amplitude=0.004:d={T['END']},lowpass=f=1800[air];"       # a breath of room tone so the gaps are not dead
 f"[a][b][d][e][n][r][air]amix=inputs=7:normalize=0:duration=longest,apad=whole_dur={T['END']},alimiter=limit=0.9[o]")
sh(["ffmpeg", "-loglevel", "error", "-nostdin", "-y", "-i", "narr.m4a", "-i", "act3.m4a", "-i", "nurse.m4a", "-filter_complex", fc, "-map", "[o]", "-t", str(T["END"]), "-c:a", "aac", "-b:a", "192k", "track5.m4a"])
json.dump(T, open("audio5.json", "w"))
print(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", "track5.m4a"], capture_output=True, text=True).stdout.strip())
