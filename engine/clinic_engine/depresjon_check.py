"""The movement rule on real recordings: the public Depresjon dataset.

Depresjon (Garcia-Ceja et al., MMSys 2018; Simula, https://datasets.simula.no/depresjon/)
holds wrist-worn movement counts, one per minute, of 23 patients in a depressive episode
and 32 healthy controls, with a MADRS rating at the start and at the end of each patient's
recording. It is free for research and education; the data is NOT in this repository.

    curl -LO https://datasets.simula.no/downloads/depresjon.zip && unzip depresjon.zip
    python -m clinic_engine.depresjon_check path/to/data [--out result.json]

What it can and cannot say. The recordings are about two weeks long and nobody in them is
known to relapse, so this is not a test of catching a slide early. It answers three
smaller questions with real people's movement instead of generated days:

1. How often does our own-normal rule, exactly as it runs on the server, raise a movement
   flag on real recordings, in patients and in healthy controls? (It needs 14 days of own
   history that end 5 days back, so only the longer recordings can be scored at all.)
2. The same with a shorter history (7 days, ending 2 days back), so that everyone can be
   scored. This is a variant for this check only; the server does not run it.
3. One of our hypotheses fixed in advance: less movement when symptoms are worse. Within
   each patient, did movement rise when the MADRS rating fell between start and end?

Wrist counts stand in for steps: one total per full day goes in as the day's `steps`.
"""

from __future__ import annotations

import argparse
import csv
import glob
import json
import os
import random
from collections import Counter
from dataclasses import replace
from statistics import median

from .mind.baseline import daily_series
from .mind.thresholds import T

FULL_DAY_MINUTES = 1300  # a day with fewer recorded minutes is left out
WORN_MINUTES = 600  # ... and so is a day with movement in fewer minutes than this


def load_days(path: str, measured_days: int | None) -> dict[str, dict]:
    """One total per measured day. Many files run on for days or weeks after the device
    came off (rows of zeros, or a low hum in every minute); counted as days, those would
    read as a collapse in movement. So only the first `measured_days` dates are used, the
    number the dataset's own scores.csv gives for each person, and of those only days with
    nearly all their minutes on file and at least ten hours of movement."""
    total: Counter = Counter()
    minutes: Counter = Counter()
    moving: Counter = Counter()
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            v = float(row["activity"])
            total[row["date"]] += v
            minutes[row["date"]] += 1
            moving[row["date"]] += v > 0
    dates = sorted(total)[:measured_days] if measured_days else sorted(total)
    return {d: {"steps": total[d]} for d in dates
            if minutes[d] >= FULL_DAY_MINUTES and moving[d] >= WORN_MINUTES}


def flags(days: dict[str, dict], th) -> dict:
    """The server's own-normal series and its movement-drop rule (at least
    `deviation_min_low` of the last `deviation_lookback` scored days at or under `low_day_z`)."""
    scored = [s for s in daily_series(days, th) if s["movement_z"] is not None]
    low = [s["movement_z"] <= th.low_day_z for s in scored]
    fired = any(sum(low[max(0, i - th.deviation_lookback + 1): i + 1]) >= th.deviation_min_low
                for i in range(len(low)))
    return {"days": len(days), "scored_days": len(scored), "low_days": sum(low), "flag": fired}


def group(rows: list[dict]) -> dict:
    scorable = [r for r in rows if r["scored_days"]]
    days = sum(r["scored_days"] for r in scorable)
    return {"people": len(rows), "people_scorable": len(scorable), "scored_days": days,
            "low_days": sum(r["low_days"] for r in scorable),
            "low_day_share": round(sum(r["low_days"] for r in scorable) / days, 3) if days else None,
            "people_flagged": sum(r["flag"] for r in scorable)}


def ranks(xs: list[float]) -> list[float]:
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


def spearman(xs: list[float], ys: list[float]) -> float:
    rx, ry = ranks(xs), ranks(ys)
    mx, my = sum(rx) / len(rx), sum(ry) / len(ry)
    num = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    den = (sum((a - mx) ** 2 for a in rx) * sum((b - my) ** 2 for b in ry)) ** 0.5
    return num / den if den else 0.0


def run(data: str) -> dict:
    scores = {}
    with open(os.path.join(data, "scores.csv"), newline="") as f:
        for row in csv.DictReader(f):
            scores[row["number"]] = row
    short = replace(T, baseline_exclude_recent=2, baseline_min_days=7)
    as_it_runs: dict[str, list] = {"condition": [], "control": []}
    short_history: dict[str, list] = {"condition": [], "control": []}
    level: dict[str, list] = {"condition": [], "control": []}
    change = []
    for g in ("condition", "control"):
        for path in sorted(glob.glob(os.path.join(data, g, "*.csv"))):
            name = os.path.splitext(os.path.basename(path))[0]
            sc = scores.get(name, {})
            days = load_days(path, int(sc["days"]) if sc.get("days") else None)
            if not days:
                continue
            vals = [d["steps"] for d in days.values()]
            level[g].append(sum(vals) / len(vals))
            as_it_runs[g].append({"name": name, **flags(days, T)})
            short_history[g].append({"name": name, **flags(days, short)})
            if g == "condition" and sc.get("madrs1") and sc.get("madrs2") and len(vals) >= 6:
                first, last = sum(vals[:3]) / 3, sum(vals[-3:]) / 3
                change.append({"name": name, "madrs_change": float(sc["madrs2"]) - float(sc["madrs1"]),
                               "movement_change_pct": round(100 * (last - first) / (sum(vals) / len(vals)), 1)})
    rng = random.Random(20261114)
    xs = [c["madrs_change"] for c in change]
    ys = [c["movement_change_pct"] for c in change]
    rho = spearman(xs, ys)
    perm = sum(abs(spearman(xs, rng.sample(ys, len(ys)))) >= abs(rho) for _ in range(10000)) / 10000
    boots = []
    for _ in range(4000):
        idx = [rng.randrange(len(xs)) for _ in xs]
        boots.append(spearman([xs[i] for i in idx], [ys[i] for i in idx]))
    boots.sort()
    a, b = level["condition"], level["control"]
    diff = median(a) - median(b)
    pooled = a + b
    perm_level = sum(abs(median(p[:len(a)]) - median(p[len(a):])) >= abs(diff)
                     for p in (rng.sample(pooled, len(pooled)) for _ in range(10000))) / 10000
    moved = [c for c in change if c["madrs_change"] != 0]
    return {
        "dataset": "Depresjon (Garcia-Ceja et al. 2018), wrist movement counts; not in this repository",
        "full_day_minutes": FULL_DAY_MINUTES, "worn_minutes": WORN_MINUTES,
        "rule_as_it_runs": {"history": "28 days ending 5 days back, at least 14",
                            "patients": group(as_it_runs["condition"]),
                            "controls": group(as_it_runs["control"])},
        "rule_with_short_history": {"history": "up to 28 days ending 2 days back, at least 7 (this check only)",
                                    "patients": group(short_history["condition"]),
                                    "controls": group(short_history["control"])},
        "hypothesis_less_movement_when_worse": {
            "patients": len(change), "expected_sign": "negative",
            "spearman_rho": round(rho, 2),
            "bootstrap_95": [round(boots[int(0.025 * len(boots))], 2), round(boots[int(0.975 * len(boots))], 2)],
            "permutation_p": round(perm, 3),
            "patients_whose_rating_changed": len(moved),
            "moved_as_expected": sum((c["madrs_change"] < 0) == (c["movement_change_pct"] > 0) for c in moved)},
        "level_between_groups": {"median_daily_count_patients": round(median(a)),
                                 "median_daily_count_controls": round(median(b)),
                                 "permutation_p_at_most": round(max(perm_level, 1 / 10000), 4)},
        "people": {"as_it_runs": as_it_runs, "short_history": short_history, "change": change},
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("data", help="the folder with scores.csv, condition/ and control/")
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    res = run(a.data)
    print(json.dumps({k: v for k, v in res.items() if k != "people"}, indent=1))
    if a.out:
        with open(a.out, "w") as f:
            json.dump(res, f, indent=1)


if __name__ == "__main__":
    main()
