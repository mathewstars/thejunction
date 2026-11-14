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
fc = (
 f"[0:a]atrim=0:75.9,asetpts=PTS-STARTPTS,{N},afade=t=out:st=75.2:d=0.7[a];"
 f"[1:a]{N},asplit=3[x1][x2][x3];"
 f"[x1]atrim=0:10.9,asetpts=PTS-STARTPTS,afade=t=in:d=0.15,afade=t=out:st=10.4:d=0.5,adelay={ms(T['B'])}:all=1[b];"
 f"[x2]atrim=10.9:21.2,asetpts=PTS-STARTPTS,afade=t=in:d=0.2,afade=t=out:st=9.9:d=0.4,adelay={ms(T['D'])}:all=1[d];"
 f"[x3]atrim=21.4:30.4,asetpts=PTS-STARTPTS,afade=t=in:d=0.15,afade=t=out:st=7.8:d=1.2,adelay={ms(T['E'])}:all=1[e];"
 f"[2:a]atrim=0:5.7,asetpts=PTS-STARTPTS,highpass=f=220,lowpass=f=3800,loudnorm=I=-17:TP=-2,afade=t=out:st=5.3:d=0.4,adelay={ms(T['NURSE'])}:all=1[n];"
 f"sine=f=150:d=1.1,tremolo=f=28:d=0.9,volume=0.10,afade=t=in:d=0.05,afade=t=out:st=0.9:d=0.2,adelay={ms(T['RING'])}:all=1[r];"
 f"[a][b][d][e][n][r]amix=inputs=6:normalize=0:duration=longest,apad=whole_dur={T['END']},alimiter=limit=0.9[o]")
sh(["ffmpeg", "-loglevel", "error", "-nostdin", "-y", "-i", "narr.m4a", "-i", "act3.m4a", "-i", "nurse.m4a", "-filter_complex", fc, "-map", "[o]", "-t", str(T["END"]), "-c:a", "aac", "-b:a", "192k", "track5.m4a"])
json.dump(T, open("audio5.json", "w"))
print(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", "track5.m4a"], capture_output=True, text=True).stdout.strip())
