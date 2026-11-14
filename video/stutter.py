# Reports the seconds of a film in which a moving shot shows the same frame twice in a row.
import subprocess, numpy as np, sys
W,H=160,90
p=subprocess.Popen(["ffmpeg","-loglevel","error","-nostdin","-i",sys.argv[1],"-vf",f"scale={W}:{H},format=gray","-f","rawvideo","-"],stdout=subprocess.PIPE)
prev=None; dup=[]
while True:
    b=p.stdout.read(W*H)
    if len(b)<W*H: break
    f=np.frombuffer(b,dtype=np.uint8).astype(np.int16)
    if prev is not None: dup.append(np.abs(f-prev).mean())
    prev=f
dup=np.array(dup); t=np.arange(1,len(dup)+1)/24; out=[]
for s in range(int(t[-1])+1):
    m=(t>=s)&(t<s+1); d=dup[m]
    if len(d)<20: continue
    if np.median(d)>0.5 and int((d<0.15).sum())>=2: out.append((s,int((d<0.15).sum())))
print("seconds with repeated frames inside moving shots:", out)
