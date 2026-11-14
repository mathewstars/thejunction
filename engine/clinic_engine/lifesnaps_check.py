"""The movement rule, exactly as it runs on the server, on real daily data: LifeSnaps.

LifeSnaps (Yfantidou et al., Scientific Data 2022; https://zenodo.org/records/7229547, open)
followed 71 people for about four months with a Fitbit and a short daily mood report (which
of: happy, rested, alert, neutral, tired, tense or anxious, sad), plus the PANAS every week.
They are volunteers, not patients, and there is no depression scale. The data is NOT in this
repository.

    python -m clinic_engine.lifesnaps_check path/to/rais_anonymized [--out result.json]

Each person's daily steps go through `mind.baseline.daily_series` with the server's own
thresholds: every day against that person's own normal (28 days ending 5 days back, at least
14), "clearly low" at -1.5 or under, a movement flag while at least 3 of the last 5 scored
days are clearly low. Nothing is tuned to this data. Questions, each within one person:

1. How often does the rule call a day clearly low, and how many people ever get a flag?
2. On clearly low days, what did the person report, against their own other days?
3. While a flag is held, the same.
4. In weeks with a flag, the weekly PANAS against the person's own other weeks.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import random
from collections import defaultdict
from datetime import date, timedelta

from .mind.baseline import daily_series
from .mind.thresholds import T

MOODS = ("SAD", "TENSE/ANXIOUS", "TIRED", "HAPPY", "RESTED/RELAXED", "ALERT")


def mean(xs):
    xs = list(xs)
    return sum(xs) / len(xs) if xs else None


def person_diffs(people: dict, pick, value) -> list[float]:
    """For each person: mean of `value` on picked days minus on their other days."""
    out = []
    for days in people.values():
        a = [value(d) for d in days if pick(d) and value(d) is not None]
        b = [value(d) for d in days if not pick(d) and value(d) is not None]
        if len(a) >= 2 and len(b) >= 5:
            out.append(mean(a) - mean(b))
    return out


def summary(diffs: list[float], rng: random.Random) -> dict:
    if len(diffs) < 5:
        return {"people": len(diffs)}
    boots = sorted(mean(rng.choice(diffs) for _ in diffs) for _ in range(4000))
    return {"people": len(diffs), "mean_difference": round(mean(diffs), 3),
            "interval_95": [round(boots[100], 3), round(boots[3900], 3)],
            "people_with_positive_difference": sum(d > 0 for d in diffs)}


def run(folder: str) -> dict:
    rng = random.Random(20261115)
    raw: dict[str, dict[str, dict]] = defaultdict(dict)
    with open(os.path.join(folder, "csv_rais_anonymized", "daily_fitbit_sema_df_unprocessed.csv"), newline="") as f:
        for row in csv.DictReader(f):
            rec = raw[row["id"]].setdefault(row["date"][:10], {})
            if row.get("steps") not in (None, "", "nan") and float(row["steps"]) > 0:
                rec["steps"] = float(row["steps"])
            for m in MOODS:
                if row.get(m) not in (None, "", "nan"):
                    rec[m] = float(row[m])
    people: dict[str, list[dict]] = {}
    scored_days = low_days = 0
    flagged_people = 0
    for pid, days in raw.items():
        steps = {d: {"steps": r["steps"]} for d, r in days.items() if "steps" in r}
        series = {s["date"]: s["movement_z"] for s in daily_series(steps, T) if s["movement_z"] is not None}
        if not series:
            continue
        ordered = sorted(series)
        low = {d: series[d] <= T.low_day_z for d in ordered}
        held = {}
        for i, d in enumerate(ordered):
            last = ordered[max(0, i - T.deviation_lookback + 1): i + 1]
            held[d] = sum(low[x] for x in last) >= T.deviation_min_low
        scored_days += len(ordered)
        low_days += sum(low.values())
        flagged_people += any(held.values())
        people[pid] = [{"date": d, "low": low[d], "held": held[d], **{m: days[d].get(m) for m in MOODS}} for d in ordered]
    out: dict = {
        "dataset": "LifeSnaps (Yfantidou et al. 2022), Zenodo 7229547; not in this repository",
        "rule": "the server's thresholds, unchanged",
        "people_scored": len(people), "scored_days": scored_days, "clearly_low_days": low_days,
        "clearly_low_share": round(low_days / scored_days, 3),
        "people_ever_flagged": flagged_people,
        "days_with_flag_held": sum(d["held"] for p in people.values() for d in p),
        "on_clearly_low_days_vs_own_other_days": {}, "while_flag_held_vs_own_other_days": {}}
    for m in MOODS:
        out["on_clearly_low_days_vs_own_other_days"][m] = summary(person_diffs(people, lambda d: d["low"], lambda d, m=m: d[m]), rng)
        out["while_flag_held_vs_own_other_days"][m] = summary(person_diffs(people, lambda d: d["held"], lambda d, m=m: d[m]), rng)

    # Weekly PANAS: a week counts as flagged when a flag was held on any of the 7 days before the form.
    panas: dict[str, list] = defaultdict(list)
    with open(os.path.join(folder, "scored_surveys", "panas.csv"), newline="") as f:
        for row in csv.DictReader(f):
            panas[row["user_id"]].append((row["submitdate"][:10], float(row["positive_affect_score"]), float(row["negative_affect_score"])))
    weeks: dict[str, list[dict]] = {}
    for pid, forms in panas.items():
        if pid not in people:
            continue
        held = {d["date"]: d["held"] for d in people[pid]}
        rows = []
        for ds, pos, neg in forms:
            end = date.fromisoformat(ds)
            window = [(end - timedelta(days=k)).isoformat() for k in range(7)]
            seen = [held[w] for w in window if w in held]
            if seen:
                rows.append({"held": any(seen), "pos": pos, "neg": neg})
        weeks[pid] = rows
    out["weekly_panas_in_flagged_weeks_vs_own_other_weeks"] = {
        "weeks": sum(len(v) for v in weeks.values()), "flagged_weeks": sum(r["held"] for v in weeks.values() for r in v),
        "positive_affect": summary([mean(r["pos"] for r in v if r["held"]) - mean(r["pos"] for r in v if not r["held"])
                                    for v in weeks.values() if any(r["held"] for r in v) and sum(not r["held"] for r in v) >= 2], rng),
        "negative_affect": summary([mean(r["neg"] for r in v if r["held"]) - mean(r["neg"] for r in v if not r["held"])
                                    for v in weeks.values() if any(r["held"] for r in v) and sum(not r["held"] for r in v) >= 2], rng)}
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("folder", help="the unpacked rais_anonymized folder")
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    res = run(a.folder)
    print(json.dumps(res, indent=1))
    if a.out:
        with open(a.out, "w") as f:
            json.dump(res, f, indent=1)


if __name__ == "__main__":
    main()
