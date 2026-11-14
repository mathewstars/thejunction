"""The movement rule, exactly as it runs on the server, on a second set of real daily data.

MobileWell400+ (https://zenodo.org/records/11060596, CC BY 4.0): 409 adults in Spain, 30 days
in July and August 2023, their phone's own activity recognition (still, walking, in a
vehicle ...), a short mood report several times a day (valence, energetic arousal, tense
arousal, each 0 to 100) and the PHQ-9 at the end. Volunteers, not patients. The data is NOT
in this repository.

    python -m clinic_engine.mobilewell_check path/to/folder [--out result.json]

A day's movement here is the minutes the phone labelled walking, on foot, running or on a
bicycle (each label counts until the next one, ten minutes at most), turned into steps at
100 a minute. That number goes in as the day's `steps`, through `mind.baseline.daily_series` with the server's thresholds,
unchanged. With 30 days and a rule that needs 14 days of history ending 5 days back, only
about the last ten days of each person can be scored.

1. How often is a day clearly low, and how many people get a movement flag?
2. On a clearly low day, what did the person report, against their own other scored days?
3. Between people: does the PHQ-9 at the end go with how much the person moved, and with
   having been flagged?
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import random
from collections import defaultdict

from .mind.baseline import daily_series
from .mind.thresholds import T

MOVING = {"WALKING", "ON_FOOT", "RUNNING", "ON_BICYCLE"}
CAP_S = 600.0
# The server's rule has a floor on the spread that is written in steps. Minutes on foot are
# turned into steps at 100 a minute (an ordinary walking pace) so that floor means what it
# means for a real day record. A first run in minutes scored no day as low for that reason.
STEPS_PER_MINUTE = 100.0


def mean(xs):
    xs = list(xs)
    return sum(xs) / len(xs) if xs else None


def ranks(xs):
    order = sorted(range(len(xs)), key=lambda i: xs[i])
    out = [0.0] * len(xs)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and xs[order[j + 1]] == xs[order[i]]:
            j += 1
        for k in range(i, j + 1):
            out[order[k]] = (i + j) / 2 + 1
        i = j + 1
    return out


def spearman(xs, ys):
    rx, ry = ranks(xs), ranks(ys)
    mx, my = mean(rx), mean(ry)
    den = (sum((a - mx) ** 2 for a in rx) * sum((b - my) ** 2 for b in ry)) ** 0.5
    return sum((a - mx) * (b - my) for a, b in zip(rx, ry)) / den if den else 0.0


def boot(diffs, rng, n=4000):
    b = sorted(mean(rng.choice(diffs) for _ in diffs) for _ in range(n))
    return [round(b[int(0.025 * n)], 2), round(b[int(0.975 * n)], 2)]


def run(folder: str) -> dict:
    rng = random.Random(20261115)
    minutes: dict[str, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    seen_day: dict[str, set] = defaultdict(set)
    last: dict[str, tuple] = {}
    with open(os.path.join(folder, "activity_recognition.csv"), newline="") as f:
        for row in csv.DictReader(f):
            p, t, day = row["participant"], float(row["timestamp_UTC"]), row["timestamp"][:10]
            seen_day[p].add(day)
            if p in last:
                t0, lab0, day0, conf0 = last[p]
                if lab0 in MOVING and conf0 >= 50 and 0 < t - t0:
                    minutes[p][day0] += min(t - t0, CAP_S) / 60
            last[p] = (t, row["label"], day, float(row["confidence"] or 0))
    mood: dict[str, dict[str, list]] = defaultdict(lambda: defaultdict(list))
    with open(os.path.join(folder, "daily_survey.csv"), newline="") as f:
        for row in csv.DictReader(f):
            try:
                mood[row["participant"]][row["timestamp"][:10]].append(
                    (float(row["valence"]), float(row["energetic_arousal"]), float(row["tense_arousal"])))
            except ValueError:
                continue
    phq: dict[str, float] = {}
    with open(os.path.join(folder, "final_survey.csv"), newline="") as f:
        for row in csv.DictReader(f):
            try:
                phq[row["participant"]] = sum(float(row[f"PHQ_{i}"]) for i in range(1, 10))
            except ValueError:
                continue

    people: dict[str, list[dict]] = {}
    scored = lows = 0
    flagged: dict[str, bool] = {}
    level: dict[str, float] = {}
    for p, days in seen_day.items():
        steps = {d: {"steps": minutes[p].get(d, 0.0) * STEPS_PER_MINUTE} for d in days}
        level[p] = mean(v["steps"] for v in steps.values())
        series = {s["date"]: s["movement_z"] for s in daily_series(steps, T) if s["movement_z"] is not None}
        if not series:
            continue
        ordered = sorted(series)
        low = {d: series[d] <= T.low_day_z for d in ordered}
        held = [sum(low[x] for x in ordered[max(0, i - T.deviation_lookback + 1): i + 1]) >= T.deviation_min_low
                for i in range(len(ordered))]
        scored += len(ordered)
        lows += sum(low.values())
        flagged[p] = any(held)
        people[p] = [{"low": low[d], "mood": mood[p].get(d)} for d in ordered]

    def diffs(k: int) -> list[float]:
        out = []
        for days in people.values():
            a = [mean(m[k] for m in d["mood"]) for d in days if d["low"] and d["mood"]]
            b = [mean(m[k] for m in d["mood"]) for d in days if not d["low"] and d["mood"]]
            if a and len(b) >= 3:
                out.append(mean(a) - mean(b))
        return out

    out: dict = {
        "dataset": "MobileWell400+ (Zenodo 11060596); not in this repository",
        "rule": "the server's thresholds, unchanged; a day's movement = minutes the phone labelled walking, on foot, running or cycling",
        "people_scored": len(people), "scored_days": scored, "clearly_low_days": lows,
        "clearly_low_share": round(lows / scored, 3) if scored else None,
        "people_flagged": sum(flagged.values()),
        "on_clearly_low_days_vs_own_other_days": {}}
    for k, name in enumerate(("valence", "energetic_arousal", "tense_arousal")):
        d = diffs(k)
        out["on_clearly_low_days_vs_own_other_days"][name] = {
            "people": len(d), "mean_difference": round(mean(d), 2) if d else None,
            "interval_95": boot(d, rng) if len(d) >= 5 else None,
            "people_lower": sum(x < 0 for x in d)}
    both = [p for p in phq if p in level and level[p] is not None]
    xs, ys = [level[p] for p in both], [phq[p] for p in both]
    rho = spearman(xs, ys)
    perm = sum(abs(spearman(xs, rng.sample(ys, len(ys)))) >= abs(rho) for _ in range(5000)) / 5000
    fl = [phq[p] for p in phq if flagged.get(p) is True]
    nf = [phq[p] for p in phq if flagged.get(p) is False]
    out["between_people"] = {
        "people_with_phq9": len(both), "phq9_at_10_or_more": sum(y >= 10 for y in ys),
        "movement_against_phq9_rank_correlation": round(rho, 3), "permutation_p": round(max(perm, 1 / 5000), 4),
        "mean_phq9_flagged": round(mean(fl), 2) if fl else None, "people_flagged_with_phq9": len(fl),
        "mean_phq9_not_flagged": round(mean(nf), 2) if nf else None}
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("folder")
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    res = run(a.folder)
    print(json.dumps(res, indent=1))
    if a.out:
        with open(a.out, "w") as f:
            json.dump(res, f, indent=1)


if __name__ == "__main__":
    main()
