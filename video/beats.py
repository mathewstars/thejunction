# Finds the beats of the soundtrack (spectral flux, tempo by autocorrelation, beats by dynamic programming) and writes beats.json.
import subprocess, json, sys, numpy as np
from scipy.signal import stft
src = sys.argv[1]; SR = 22050; HOP = 256
raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-nostdin", "-i", src, "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"], capture_output=True).stdout
x = np.frombuffer(raw, dtype=np.float32)
f, t, Z = stft(x, fs=SR, nperseg=1024, noverlap=1024 - HOP)
M = np.log1p(50 * np.abs(Z))
flux = np.maximum(0, np.diff(M, axis=1)).sum(axis=0)
flux = flux - np.convolve(flux, np.ones(87) / 87, mode="same"); flux = np.maximum(0, flux); flux /= flux.std() + 1e-9
fps = SR / HOP
ac = np.correlate(flux, flux, mode="full")[len(flux) - 1:]
lo, hi = int(fps * 60 / 150), int(fps * 60 / 55)
w = np.exp(-0.5 * (np.log2(np.arange(lo, hi) / (fps * 60 / 92)) / 0.9) ** 2)
per = lo + int(np.argmax(ac[lo:hi] * w)); bpm = 60 * fps / per
# dynamic programming (Ellis 2007)
N = len(flux); score = flux.copy(); back = -np.ones(N, int); tight = 100.0
for i in range(N):
    a, b = max(0, i - 2 * per), i - per // 2
    if b <= a: continue
    prev = np.arange(a, b); pen = -tight * (np.log((i - prev) / per)) ** 2
    j = int(np.argmax(score[prev] + pen)); score[i] = flux[i] + score[prev][j] + pen[j]; back[i] = prev[j]
i = int(np.argmax(score[-per:])) + N - per; beats = []
while i >= 0: beats.append(i); i = back[i]
beats = np.array(beats[::-1]) / fps
strength = [float(flux[max(0, int(b * fps) - 2):int(b * fps) + 3].max()) for b in beats]
json.dump({"bpm": round(bpm, 1), "beats": [round(float(b), 3) for b in beats], "strength": [round(s, 2) for s in strength]}, open("beats.json", "w"))
print("bpm", round(bpm, 1), "beats", len(beats), "median gap", round(float(np.median(np.diff(beats))), 3), "share of beats on a real onset", round(float(np.mean(np.array(strength) > 1.0)), 2))
