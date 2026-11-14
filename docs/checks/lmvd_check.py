"""Our face hypotheses on real faces: the public LMVD dataset.

LMVD (He et al. 2024, https://github.com/helang818/LMVD, figshare 25698351, Apache 2.0) holds
OpenFace features, frame by frame, of 1,823 video logs from about 1,475 people on four
platforms: 908 by people who say they have depression, 915 by others. No video, no audio,
no names: action units (how strongly a facial muscle group is active), gaze and head pose.
The data (16 GB zipped) is NOT in this repository.

    python lmvd_check.py features LMVD_Feature.zip per_video.csv      (pandas; about 15 minutes)
    python lmvd_check.py compare per_video.csv [--out result.json]

It asks one thing: do the face measures we fixed hypotheses for on 13 November differ
between the two groups in the direction we wrote down? Each video is reduced to the same
kind of numbers our server computes from ARKit, by fixed rules written before looking at
the result. Smile = action unit 12 present, eye smile = 12 with 6, blink = 45, brows down =
4, inner brows up = 1.

What it cannot say. This is a comparison between people, not the within-person change our
product looks for. The groups differ in more than depression: what they talk about, how they
film, which platform. OpenFace on a vlog is not ARKit on a game. A difference here supports
choosing a measure; it does not show that the measure follows one person's symptoms.
"""

import io
import json
import random
import sys
import zipfile
from multiprocessing import Pool

COLS = ["timestamp", "confidence", "success", "gaze_angle_y", "pose_Rx", "pose_Ry", "pose_Rz",
        "AU01_c", "AU04_c", "AU06_c", "AU12_c", "AU45_c", "AU12_r"]
AU_R = ["AU01_r", "AU02_r", "AU04_r", "AU05_r", "AU06_r", "AU07_r", "AU09_r", "AU10_r", "AU12_r",
        "AU14_r", "AU15_r", "AU17_r", "AU20_r", "AU23_r", "AU25_r", "AU26_r"]
DEG = 57.29578


def label(n: int) -> int | None:
    if 1 <= n <= 601 or 1117 <= n <= 1423:
        return 1
    if 602 <= n <= 1116 or 1425 <= n <= 1824:
        return 0
    return None


def runs(flags) -> list[int]:
    out, n = [], 0
    for f in flags:
        if f:
            n += 1
        elif n:
            out.append(n)
            n = 0
    if n:
        out.append(n)
    return out


def one(args) -> dict | None:
    import pandas as pd
    zpath, name = args
    try:
        with zipfile.ZipFile(zpath) as z, z.open(name) as f:
            df = pd.read_csv(io.BufferedReader(f), skipinitialspace=True, usecols=lambda c: c in set(COLS) | set(AU_R))
    except Exception as exc:  # noqa: BLE001
        return {"video": name, "error": type(exc).__name__}
    num = int(name.split("/")[-1].split(".")[0])
    df = df[(df["success"] == 1) & (df["confidence"] >= 0.8)]
    if len(df) < 300:
        return {"video": num, "label": label(num), "frames": len(df)}
    dt = df["timestamp"].diff()
    step = float(dt[dt > 0].median())
    if not step or step != step:
        return {"video": num, "label": label(num), "frames": len(df)}
    minutes = len(df) * step / 60
    smile = (df["AU12_c"] == 1).tolist()
    blink = (df["AU45_c"] == 1).tolist()
    smile_runs = [r for r in runs(smile) if r * step >= 0.3]
    blink_runs = [r for r in runs(blink) if r * step <= 0.6]
    cont = dt.fillna(0).between(0, step * 1.5)  # only steps between neighbouring frames
    au_move = df[AU_R].diff().abs()[cont].mean().mean() / step
    head = (df[["pose_Rx", "pose_Ry", "pose_Rz"]].diff().abs()[cont].sum(axis=1).mean() / step) * DEG
    s = df["AU12_c"] == 1
    return {"video": num, "label": label(num), "frames": len(df), "minutes": round(minutes, 2),
            "smile_time_share": float(s.mean()),
            "smile_rate_per_min": len(smile_runs) / minutes,
            "smile_intensity": float(df.loc[s, "AU12_r"].mean()) if s.any() else None,
            "eye_smile_share": float((df.loc[s, "AU06_c"] == 1).mean()) if s.any() else None,
            "facial_activity": float(au_move),
            "brow_down_share": float((df["AU04_c"] == 1).mean()),
            "inner_brow_up_share": float((df["AU01_c"] == 1).mean()),
            "blink_rate_per_min": len(blink_runs) / minutes,
            "blink_duration_ms": 1000 * step * sum(blink_runs) / len(blink_runs) if blink_runs else None,
            "look_down_share": float((df["gaze_angle_y"] > 0.25).mean()),
            "head_pitch_deg": float(df["pose_Rx"].mean() * DEG),
            "head_movement": float(head)}


EXPECTED = {"smile_time_share": "lower", "smile_rate_per_min": "lower", "smile_intensity": "lower",
            "eye_smile_share": "lower", "facial_activity": "lower", "brow_down_share": "higher",
            "inner_brow_up_share": "higher", "blink_rate_per_min": "mixed", "blink_duration_ms": "higher",
            "look_down_share": "higher", "head_pitch_deg": "higher", "head_movement": "lower"}


def auc(a: list[float], b: list[float]) -> float:
    """Chance that a value from `a` is above a value from `b` (ties count half)."""
    allv = sorted([(v, 0) for v in a] + [(v, 1) for v in b])
    rank_sum, i = 0.0, 0
    while i < len(allv):
        j = i
        while j + 1 < len(allv) and allv[j + 1][0] == allv[i][0]:
            j += 1
        r = (i + j) / 2 + 1
        rank_sum += r * sum(1 for k in range(i, j + 1) if allv[k][1] == 0)
        i = j + 1
    return (rank_sum - len(a) * (len(a) + 1) / 2) / (len(a) * len(b))


def compare(path: str) -> dict:
    import csv
    rows = [r for r in csv.DictReader(open(path)) if r.get("label") in ("0", "1") and r.get("smile_time_share")]
    rng = random.Random(20261115)
    out = {"dataset": "LMVD (He et al. 2024), figshare 25698351; not in this repository",
           "videos_used": len(rows), "depression": sum(r["label"] == "1" for r in rows),
           "others": sum(r["label"] == "0" for r in rows), "measures": {}}
    for m, exp in EXPECTED.items():
        a = [float(r[m]) for r in rows if r["label"] == "1" and r[m] not in ("", "None")]
        b = [float(r[m]) for r in rows if r["label"] == "0" and r[m] not in ("", "None")]
        v = auc(a, b)
        boots = sorted(auc([rng.choice(a) for _ in a], [rng.choice(b) for _ in b]) for _ in range(300))
        lo, hi = boots[7], boots[292]
        seen = "higher" if lo > 0.5 else "lower" if hi < 0.5 else "no clear difference"
        out["measures"][m] = {
            "expected_in_depression": exp, "median_depression": round(sorted(a)[len(a) // 2], 4),
            "median_others": round(sorted(b)[len(b) // 2], 4), "chance_depression_video_is_higher": round(v, 3),
            "interval_95": [round(lo, 3), round(hi, 3)], "seen": seen,
            "as_expected": None if exp == "mixed" else (seen == exp) if seen != "no clear difference" else False}
    ms = [x for x in out["measures"].values() if x["as_expected"] is not None]
    out["as_expected"] = sum(x["as_expected"] for x in ms)
    out["opposite"] = sum(x["seen"] not in ("no clear difference", x["expected_in_depression"]) for x in ms)
    out["no_clear_difference"] = sum(x["seen"] == "no clear difference" for x in ms)
    return out


if __name__ == "__main__":
    if sys.argv[1] == "features":
        import csv
        zpath, outp = sys.argv[2], sys.argv[3]
        with zipfile.ZipFile(zpath) as z:
            names = sorted(n for n in z.namelist() if n.startswith("Video_feature/") and n.endswith(".csv"))
        keys = ["video", "label", "frames", "minutes", *EXPECTED, "error"]
        with Pool(int(sys.argv[4]) if len(sys.argv) > 4 else 8) as pool, open(outp, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=keys)
            w.writeheader()
            for i, row in enumerate(pool.imap_unordered(one, [(zpath, n) for n in names], chunksize=4)):
                if row:
                    w.writerow({k: row.get(k) for k in keys})
                if i % 100 == 0:
                    f.flush()
                    print(i, "of", len(names), flush=True)
    else:
        res = compare(sys.argv[2])
        print(json.dumps(res, indent=1))
        if "--out" in sys.argv:
            json.dump(res, open(sys.argv[sys.argv.index("--out") + 1], "w"), indent=1)
