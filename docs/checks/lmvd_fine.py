"""LMVD through our fine-movement analysis: the same code that sums up the Face ID stream.

The phone sends, for a few face regions and every frame, how far the region is from the
person's resting shape, in millimetres (docs/face-fine.md). LMVD has no mesh, but it has
OpenFace's 68 face landmarks in every frame. This script turns them into the same kind of
stream and hands it, unchanged, to `clinic_engine.mind.face_fine.summarize`:

- each frame's landmarks are laid over the video's own median face using the points that
  do not move with expression (eye corners and the bridge of the nose), which takes out
  where the head is, how it is turned in the picture and how far it is from the camera;
- a region's number is how far its landmark then sits from its own median place;
- pixels become millimetres by taking the distance between the outer eye corners as 90 mm.

Regions: the two mouth corners, upper and lower lip, the two brows, the two upper eyelids,
the jaw. No cheeks (OpenFace has no cheek point). At most the first 12,000 frames of a video.

What we expected before running it, written here first: with depression, less reach, lower
top speed and fewer brief movements. No direction for left-right asymmetry.

    PYTHONPATH=engine python lmvd_fine.py features LMVD_Feature.zip fine_per_video.csv
    PYTHONPATH=engine python lmvd_fine.py compare fine_per_video.csv [per_video.csv] [--out r.json]

Limits, beyond those of lmvd_check.py: these are flat picture landmarks from compressed
video, not a depth sensor; a head turned sideways leaks into the numbers; and these people
are talking, so most brief mouth movements here are speech.
"""

import csv
import io
import json
import random
import sys
import zipfile
from multiprocessing import Pool

STABLE = [36, 39, 42, 45, 27, 28, 29, 30]
REGIONS = {"mouth_left": [54], "mouth_right": [48], "lip_upper": [51], "lip_lower": [57],
           "brow_left": [22, 23, 24, 25, 26], "brow_right": [17, 18, 19, 20, 21],
           "eyelid_left": [43, 44], "eyelid_right": [37, 38], "jaw": [8]}
EYE_MM = 90.0
EXPECTED = {"reach_mm": "lower", "speed_mm_s": "lower", "twitches_per_min": "lower",
            "mouth_corner_twitches_per_min": "lower", "mouth_asymmetry_abs": "none"}


def label(n: int):
    if 1 <= n <= 601 or 1117 <= n <= 1423:
        return 1
    if 602 <= n <= 1116 or 1425 <= n <= 1824:
        return 0
    return None


def one(args):
    import numpy as np
    import pandas as pd
    from clinic_engine.mind import face_fine as ff
    zpath, name = args
    num = int(name.split("/")[-1].split(".")[0])
    want = {"timestamp", "confidence", "success"} | {f"x_{i}" for i in range(68)} | {f"y_{i}" for i in range(68)}
    try:
        with zipfile.ZipFile(zpath) as z, z.open(name) as f:
            df = pd.read_csv(io.BufferedReader(f), skipinitialspace=True, usecols=lambda c: c in want, nrows=ff.MAX_SAMPLES)
    except Exception as exc:  # noqa: BLE001
        return {"video": num, "error": type(exc).__name__}
    if len(df) < 300:
        return {"video": num, "label": label(num)}
    dt = df["timestamp"].diff()
    step = float(dt[dt > 0].median())
    if not step or step != step:
        return {"video": num, "label": label(num)}
    rate = min(60.0, max(5.0, 1.0 / step))
    ok = ((df["success"] == 1) & (df["confidence"] >= 0.8)).to_numpy()
    if ok.sum() < 300:
        return {"video": num, "label": label(num)}
    x = df[[f"x_{i}" for i in range(68)]].to_numpy(float)
    y = df[[f"y_{i}" for i in range(68)]].to_numpy(float)
    p = x + 1j * y                                  # points as complex numbers: a similarity is p * a + b
    ref = np.median(p[ok], axis=0)
    s, r = p[:, STABLE], ref[STABLE]
    sc, rc = s - s.mean(axis=1, keepdims=True), r - r.mean()
    a = (sc.conj() * rc).sum(axis=1) / np.maximum((abs(sc) ** 2).sum(axis=1), 1e-9)
    al = (p - s.mean(axis=1, keepdims=True)) * a[:, None] + r.mean()
    mm = EYE_MM / max(abs(ref[45] - ref[36]), 1e-6)
    names = list(REGIONS)
    cols = []
    for nm in names:
        pt = al[:, REGIONS[nm]].mean(axis=1)
        rest = np.median(pt[ok])
        cols.append(np.minimum(abs(pt - rest) * mm, 49.9))
    samples = np.round(np.stack(cols, axis=1), 3)
    raw = {"source": "mesh", "rate_hz": rate, "regions": names, "samples": samples.tolist(),
           "tracked": [int(v) for v in ok]}
    summ = ff.summarize(raw)
    head = ff.headline(summ) or {}
    asym = head.get("mouth_asymmetry")
    return {"video": num, "label": label(num), "rate_hz": round(rate, 1), "tracked_s": summ.get("tracked_s"),
            "quality": summ.get("quality"), "noise_mm": summ.get("noise_mm"),
            "reach_mm": head.get("reach_mm"), "speed_mm_s": head.get("speed_mm_s"),
            "twitches_per_min": head.get("twitches_per_min"),
            "mouth_corner_twitches_per_min": (summ.get("mouth_corners") or {}).get("per_min"),
            "mouth_asymmetry_abs": abs(asym) if asym is not None else None}


def auc(a, b):
    allv = sorted([(v, 0) for v in a] + [(v, 1) for v in b])
    rank_sum, i = 0.0, 0
    while i < len(allv):
        j = i
        while j + 1 < len(allv) and allv[j + 1][0] == allv[i][0]:
            j += 1
        rank_sum += ((i + j) / 2 + 1) * sum(1 for k in range(i, j + 1) if allv[k][1] == 0)
        i = j + 1
    return (rank_sum - len(a) * (len(a) + 1) / 2) / (len(a) * len(b))


def compare(path: str, coarse: str | None) -> dict:
    rows = [r for r in csv.DictReader(open(path)) if r.get("label") in ("0", "1") and r.get("reach_mm") not in ("", None)]
    rng = random.Random(20261115)
    import collections
    out = {"dataset": "LMVD landmarks through clinic_engine.mind.face_fine", "videos_used": len(rows),
           "depression": sum(r["label"] == "1" for r in rows), "others": sum(r["label"] == "0" for r in rows),
           "quality": dict(collections.Counter(r["quality"] for r in rows)),
           "median_noise_mm": sorted(float(r["noise_mm"]) for r in rows if r["noise_mm"])[len(rows) // 2], "measures": {}}
    for m, exp in EXPECTED.items():
        a = [float(r[m]) for r in rows if r["label"] == "1" and r[m] not in ("", "None")]
        b = [float(r[m]) for r in rows if r["label"] == "0" and r[m] not in ("", "None")]
        v = auc(a, b)
        boots = sorted(auc([rng.choice(a) for _ in a], [rng.choice(b) for _ in b]) for _ in range(300))
        lo, hi = boots[7], boots[292]
        seen = "higher" if lo > 0.5 else "lower" if hi < 0.5 else "no clear difference"
        out["measures"][m] = {"expected_in_depression": exp, "median_depression": round(sorted(a)[len(a) // 2], 3),
                              "median_others": round(sorted(b)[len(b) // 2], 3),
                              "chance_depression_video_is_higher": round(v, 3), "interval_95": [round(lo, 3), round(hi, 3)],
                              "seen": seen, "as_expected": None if exp == "none" else seen == exp}
    try:
        import pandas as pd
        from sklearn.linear_model import LogisticRegression
        from sklearn.metrics import roc_auc_score
        from sklearn.model_selection import StratifiedKFold, cross_val_predict
        from sklearn.pipeline import make_pipeline
        from sklearn.preprocessing import StandardScaler
        df = pd.read_csv(path)
        df = df[df["reach_mm"].notna() & df["label"].isin([0, 1])]
        fine = list(EXPECTED)

        def cv(d, cols):
            x = d[cols].fillna(d[cols].median())
            ps = [cross_val_predict(make_pipeline(StandardScaler(), LogisticRegression(max_iter=1000)), x, d["label"].astype(int),
                                    cv=StratifiedKFold(10, shuffle=True, random_state=s), method="predict_proba")[:, 1] for s in range(5)]
            return round(float(sum(roc_auc_score(d["label"].astype(int), p) for p in ps) / len(ps)), 3)
        out["score_on_unseen_videos"] = {"fine_measures_only": cv(df, fine)}
        if coarse:
            c = pd.read_csv(coarse)
            both = df.merge(c, on="video", suffixes=("", "_c"))
            both = both[both["smile_time_share"].notna()]
            coarse_cols = ["smile_time_share", "smile_rate_per_min", "smile_intensity", "eye_smile_share", "facial_activity",
                           "brow_down_share", "inner_brow_up_share", "blink_rate_per_min", "blink_duration_ms", "head_movement"]
            out["score_on_unseen_videos"].update({"videos_with_both": int(len(both)),
                                                  "action_unit_measures_only": cv(both, coarse_cols),
                                                  "fine_only_same_videos": cv(both, fine),
                                                  "both_together": cv(both, coarse_cols + fine)})
    except ImportError:
        pass
    return out


if __name__ == "__main__":
    if sys.argv[1] == "features":
        zpath, outp = sys.argv[2], sys.argv[3]
        with zipfile.ZipFile(zpath) as z:
            names = sorted(n for n in z.namelist() if n.startswith("Video_feature/") and n.endswith(".csv"))
        keys = ["video", "label", "rate_hz", "tracked_s", "quality", "noise_mm", *EXPECTED, "error"]
        with Pool(8) as pool, open(outp, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=keys)
            w.writeheader()
            for i, row in enumerate(pool.imap_unordered(one, [(zpath, n) for n in names], chunksize=2)):
                w.writerow({k: row.get(k) for k in keys})
                if i % 100 == 0:
                    f.flush()
                    print(i, "of", len(names), flush=True)
    else:
        args = [a for a in sys.argv[2:] if not a.startswith("--")]
        if "--out" in sys.argv:
            args = [a for a in args if a != sys.argv[sys.argv.index("--out") + 1]]
        res = compare(args[0], args[1] if len(args) > 1 else None)
        print(json.dumps(res, indent=1))
        if "--out" in sys.argv:
            json.dump(res, open(sys.argv[sys.argv.index("--out") + 1], "w"), indent=1)
