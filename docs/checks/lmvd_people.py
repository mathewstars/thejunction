"""LMVD: can we find the people who appear in more than one video, and what do their videos say?

LMVD has no person id: 1,823 videos from about 1,475 people. This script guesses who is who from
the shape of the face alone (never a picture): for each video, the median place of OpenFace's
68 landmarks over the frames where the head faces the camera, with position, size and tilt taken out.
Two videos whose shapes are closer than a threshold are taken as one person.

How we know whether the guess is any good, decided before looking: the two videos of one person
must carry the same label (depression or not). If matched pairs agree on the label hardly more
often than chance (about half), the matching does not work and nothing below it means anything.

What it can and cannot give: a person's videos all carry one label and no date, so nobody's
depression can be followed over time here. What it can give is whether a person's reach and speed
(lmvd_fine.py) are alike across their own videos, and the group comparison with one video a person.

    python lmvd_people.py shapes LMVD_Feature.zip shapes.npz
    python lmvd_people.py match shapes.npz fine_per_video.csv [--out r.json]
"""

import csv
import io
import json
import random
import sys
import zipfile
from multiprocessing import Pool


def label(n: int):
    if 1 <= n <= 601 or 1117 <= n <= 1423:
        return 1
    if 602 <= n <= 1116 or 1425 <= n <= 1824:
        return 0
    return None


def one(args):
    import numpy as np
    import pandas as pd
    zpath, name = args
    num = int(name.split("/")[-1].split(".")[0])
    want = {"confidence", "success", "pose_Rx", "pose_Ry"} | {f"x_{i}" for i in range(68)} | {f"y_{i}" for i in range(68)}
    try:
        with zipfile.ZipFile(zpath) as z, z.open(name) as f:
            df = pd.read_csv(io.BufferedReader(f), skipinitialspace=True, usecols=lambda c: c in want, nrows=12000)
    except Exception:  # noqa: BLE001
        return num, None
    ok = (df["success"] == 1) & (df["confidence"] >= 0.9)
    front = ok & (df["pose_Rx"].abs() < 0.12) & (df["pose_Ry"].abs() < 0.12)
    use = front if front.sum() >= 150 else ok
    if use.sum() < 150:
        return num, None
    p = df.loc[use, [f"x_{i}" for i in range(68)]].to_numpy(float) + 1j * df.loc[use, [f"y_{i}" for i in range(68)]].to_numpy(float)
    p = p - p.mean(axis=1, keepdims=True)
    eye = p[:, 42:48].mean(axis=1) - p[:, 36:42].mean(axis=1)          # eye line: level it and make it length 1
    p = p / eye[:, None]
    m = np.median(p.real, axis=0) + 1j * np.median(p.imag, axis=0)
    return num, np.concatenate([m.real, m.imag])


def match(shapes_path: str, fine_path: str) -> dict:
    import numpy as np
    d = np.load(shapes_path)
    vids, shp = d["videos"], d["shapes"]
    lab = np.array([label(int(v)) for v in vids])
    keep = np.array([x is not None for x in lab])
    vids, shp, lab = vids[keep], shp[keep], lab[keep].astype(int)
    rigid = list(range(0, 4)) + list(range(13, 17)) + list(range(27, 48))   # upper face outline, nose, eyes: not the mouth or jaw
    cols = rigid + [68 + i for i in rigid]
    x = shp[:, cols]
    x = (x - x.mean(axis=0)) / x.std(axis=0)
    n = len(x)
    d2 = ((x[:, None, :] - x[None, :, :]) ** 2).sum(axis=2) ** 0.5
    np.fill_diagonal(d2, np.inf)
    nn, nd = d2.argmin(axis=1), d2.min(axis=1)
    out = {"videos_with_a_shape": int(n), "chance_two_videos_share_a_label": round(float((lab.mean() ** 2) + ((1 - lab.mean()) ** 2)), 3), "thresholds": {}}
    order = np.sort(nd)
    for q in (0.05, 0.1, 0.2, 0.3, 0.5, 1.0):
        thr = float(order[min(n - 1, int(q * n) - 1)])
        sel = nd <= thr
        out["thresholds"][f"closest_{int(q*100)}pct"] = {"distance": round(thr, 2), "videos": int(sel.sum()),
                                                        "nearest_has_same_label": round(float((lab[sel] == lab[nn[sel]]).mean()), 3),
                                                        "median_gap_in_video_number": float(np.median(abs(vids[sel] - vids[nn[sel]])))}
    fine = {int(r["video"]): r for r in csv.DictReader(open(fine_path)) if r.get("reach_mm")}
    thr = float(order[int(0.2 * n) - 1])
    parent = list(range(n))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    for i in range(n):
        if nd[i] <= thr and d2[nn[i], i] <= thr and nn[nn[i]] == i:   # only mutual nearest neighbours
            parent[find(i)] = find(int(nn[i]))
    groups = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(i)
    pairs = [g for g in groups.values() if len(g) == 2]
    out["mutual_pairs_at_closest_20pct"] = {"pairs": len(pairs), "same_label": round(float(np.mean([lab[a] == lab[b] for a, b in pairs])), 3) if pairs else None}
    rng = random.Random(20261115)
    for m in ("reach_mm", "speed_mm_s"):
        import math
        val = {i: math.log(float(fine[int(vids[i])][m])) for i in range(n) if int(vids[i]) in fine and float(fine[int(vids[i])][m]) > 0}
        pp = [(val[a], val[b]) for a, b in pairs if a in val and b in val and lab[a] == lab[b]]
        if len(pp) < 10:
            continue

        def corr(ps):
            a, b = np.array([p[0] for p in ps]), np.array([p[1] for p in ps])
            a2, b2 = np.concatenate([a, b]), np.concatenate([b, a])            # each pair both ways round
            return float(np.corrcoef(a2, b2)[0, 1])
        idx = [i for i in val]
        by = {0: [i for i in idx if lab[i] == 0], 1: [i for i in idx if lab[i] == 1]}
        rnd = [corr([(val[rng.choice(by[lab[a]])], val[rng.choice(by[lab[a]])]) for a, b in pairs if a in val and b in val and lab[a] == lab[b]]) for _ in range(200)]
        boots = sorted(corr([rng.choice(pp) for _ in pp]) for _ in range(300))
        out[m] = {"pairs": len(pp), "agreement_between_one_persons_two_videos": round(corr(pp), 3),
                  "interval_95": [round(boots[7], 3), round(boots[292], 3)],
                  "same_for_two_random_videos_with_that_label": round(float(np.mean(rnd)), 3)}
    return out


if __name__ == "__main__":
    import numpy as np
    if sys.argv[1] == "shapes":
        zpath, outp = sys.argv[2], sys.argv[3]
        with zipfile.ZipFile(zpath) as z:
            names = sorted(n for n in z.namelist() if n.startswith("Video_feature/") and n.endswith(".csv"))
        vids, shapes = [], []
        with Pool(8) as pool:
            for i, (num, s) in enumerate(pool.imap_unordered(one, [(zpath, n) for n in names], chunksize=2)):
                if s is not None:
                    vids.append(num)
                    shapes.append(s)
                if i % 300 == 0:
                    print(i, "of", len(names), flush=True)
        np.savez(outp, videos=np.array(vids), shapes=np.array(shapes))
    else:
        res = match(sys.argv[2], sys.argv[3])
        print(json.dumps(res, indent=1))
        if "--out" in sys.argv:
            json.dump(res, open(sys.argv[sys.argv.index("--out") + 1], "w"), indent=1)
