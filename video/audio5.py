# Soundtrack of the submission film: Suno's own mixes, uncut inside sentences.
# A = narrator take up to the chart; B, D, E = the last-part take; in between a phone buzz and the nurse's line.
import subprocess, json
def sh(a):
    r = subprocess.run(a, capture_output=True, text=True)
    if r.returncode: print(r.stderr[-600:])
    return r
T = dict(A=0.0, B=76.3, RING=91.0, NURSE=92.1, D=98.2, E=109.2, END=118.9)
ms = lambda t: int(t * 1000)
N = "loudnorm=I=-16:TP=-1.5:LRA=9"
# Every change of take is a fade, never a switch: the outgoing piano fades after the last word,
# the incoming one fades in during the pause before the next word. Source times are those of the takes.
def part(tag, src, a, b, at, fin, fout):
    d = b - a
    return f"[{src}]atrim={a}:{b},asetpts=PTS-STARTPTS,afade=t=in:d={fin}:curve=qsin,afade=t=out:st={d - fout:.2f}:d={fout}:curve=qsin,adelay={ms(at)}:all=1[{tag}];"
import os
TRANS = os.environ.get("TRANS", "pingpong22")
GR = ("[1:a]" + N + ",atrim=10.5:10.95,asetpts=PTS-STARTPTS,asplit=8[g0][g1][g2][g3][g4][g5][g6][g7];[g1]areverse[r1];[g3]areverse[r3];[g5]areverse[r5];[g7]areverse[r7];"
      "[g0][r1]acrossfade=d=0.06[t1];[t1][g2]acrossfade=d=0.06[t2];[t2][r3]acrossfade=d=0.06[t3];[t3][g4]acrossfade=d=0.06[t4];[t4][r5]acrossfade=d=0.06[t5];[t5][g6]acrossfade=d=0.06[t6];[t6][r7]acrossfade=d=0.06[t7];")
if TRANS == "pingpong3":      # the last note sustained forwards and backwards, three seconds
    BPART = part("b", "x1", 0.0, 10.95, T["B"], 0.35, 0.35) + GR + f"[t7]afade=t=in:d=0.3,afade=t=out:st=0.2:d=2.9:curve=qsin,adelay={ms(T['B'] + 10.65)}:all=1[tail];"
elif TRANS == "pingpong22":   # the same, a little over two seconds: it ends with the picture's fade to black
    BPART = part("b", "x1", 0.0, 10.95, T["B"], 0.35, 0.35) + GR + f"[t7]atrim=0:2.5,afade=t=in:d=0.3,afade=t=out:st=0.2:d=2.3:curve=qsin,adelay={ms(T['B'] + 10.65)}:all=1[tail];"
elif TRANS == "pingpong15":   # the same, a second and a half
    BPART = part("b", "x1", 0.0, 10.95, T["B"], 0.35, 0.35) + GR + f"[t7]atrim=0:1.7,afade=t=in:d=0.3,afade=t=out:st=0.2:d=1.5:curve=qsin,adelay={ms(T['B'] + 10.65)}:all=1[tail];"
elif TRANS == "short":        # plain fade in the 0.75 s that exist
    BPART = part("b", "x1", 0.0, 11.15, T["B"], 0.35, 0.75) + "anullsrc=d=0.1[tail];"
elif TRANS == "early":        # the whole scene fades: from the middle of the last sentence, voice and piano together, 2.4 s
    BPART = part("b", "x1", 0.0, 11.1, T["B"], 0.35, 2.4) + "anullsrc=d=0.1[tail];"
elif TRANS == "echo":         # plain fade plus a soft room echo that carries the last chord
    BPART = (f"[x1]atrim=0:11.1,asetpts=PTS-STARTPTS,afade=t=in:d=0.35,afade=t=out:st=10.45:d=0.65,apad=pad_dur=3,aecho=0.9:0.5:260|520|840:0.33|0.22|0.13,"
             f"afade=t=out:st=11.0:d=2.8,adelay={ms(T['B'])}:all=1[b];anullsrc=d=0.1[tail];")
fc = (
 f"[0:a]{N}[n0];[1:a]{N},asplit=3[x1][x2][x3];"
 + part("a", "n0", 0.0, 76.7, 0.0, 0.01, 1.5)                 # last word ends 75.1; the piano fades to 76.7
 + BPART
 + part("d", "x2", 10.5, 21.5, T["D"] - 0.4, 0.6, 0.65)       # in during the pause before "Anna is invented"
 + part("e", "x3", 20.9, 30.6, T["E"] - 0.5, 0.6, 1.4)        # in during the pause before "Lanvi"
 + f"[2:a]atrim=0:5.7,asetpts=PTS-STARTPTS,highpass=f=220,lowpass=f=3800,loudnorm=I=-17:TP=-2,afade=t=in:d=0.05,afade=t=out:st=5.3:d=0.4,adelay={ms(T['NURSE'])}:all=1[n];"
 f"sine=f=150:d=1.1,tremolo=f=28:d=0.9,volume=0.10,afade=t=in:d=0.05,afade=t=out:st=0.9:d=0.2,adelay={ms(T['RING'])}:all=1[r];"
 # Under the clinic screens and the nurse's call there is no music, by choice: the piano fades out before and fades in after.
 f"anoisesrc=color=pink:amplitude=0.003:d={T['END']},lowpass=f=1800[air];"
 f"[a][b][d][e][n][r][air][tail]amix=inputs=8:normalize=0:duration=longest,apad=whole_dur={T['END']},alimiter=limit=0.9[o]")
sh(["ffmpeg", "-loglevel", "error", "-nostdin", "-y", "-i", "narr.m4a", "-i", "act3.m4a", "-i", "nurse.m4a", "-filter_complex", fc, "-map", "[o]", "-t", str(T["END"]), "-c:a", "aac", "-b:a", "192k", "track5.m4a"])
json.dump(T, open("audio5.json", "w"))
print(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", "track5.m4a"], capture_output=True, text=True).stdout.strip())
