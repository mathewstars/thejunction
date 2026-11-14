"""Looking for a better within-person signal in PSYCHE-D, without fooling ourselves.

People are split in two halves by a fixed rule. Everything is chosen on the first half
(which measures, which direction, how many to combine); the second half is touched once,
at the end, to see what survives. Same data and same "within one person" comparison as
psyched_check.py: a person's windows against that person's own average.

    python psyched_explore.py data.parquet [--out result.json]        (needs pandas, pyarrow)
"""

import argparse
import hashlib
import json
import random

import pandas as pd

MIN_WINDOWS = 4
SKIP = ("phq9_", "person", "month")


def within(df: pd.DataFrame, col: str) -> pd.Series:
    return df[col] - df.groupby("person")[col].transform("mean")


def rank_corr(a: pd.Series, b: pd.Series) -> float:
    ok = a.notna() & b.notna()
    return float(a[ok].rank().corr(b[ok].rank())) if ok.sum() > 50 else float("nan")


def interval(df: pd.DataFrame, stat, rng: random.Random, n: int = 400) -> list[float]:
    groups = [g for _, g in df.groupby("person")]
    vals = sorted(stat(pd.concat([groups[rng.randrange(len(groups))] for _ in groups])) for _ in range(n))
    return [round(vals[int(0.025 * n)], 3), round(vals[int(0.975 * n)], 3)]


def run(path: str) -> dict:
    rng = random.Random(20261115)
    df = pd.read_parquet(path)
    df["person"] = [str(i).split("_")[0] for i in df.index]
    df = df.dropna(subset=["phq9_score_end"])
    df = df[df.groupby("person")["person"].transform("size") >= MIN_WINDOWS].copy()
    half = df["person"].map(lambda p: int(hashlib.sha256(p.encode()).hexdigest(), 16) % 2)
    find, confirm = df[half == 0].copy(), df[half == 1].copy()
    out: dict = {"people": {"choose_on": int(find["person"].nunique()), "confirm_on": int(confirm["person"].nunique())}}

    # Only measures that change from window to window can move with the score within a person.
    feats = [c for c in df.columns if not c.startswith(SKIP) and pd.api.types.is_numeric_dtype(df[c])
             and find.groupby("person")[c].nunique().gt(1).mean() > 0.5]
    find_phq, conf_phq = within(find, "phq9_score_end"), within(confirm, "phq9_score_end")
    table = []
    for c in feats:
        r = rank_corr(within(find, c), find_phq)
        if r == r:
            table.append((c, r))
    table.sort(key=lambda x: -abs(x[1]))
    out["measures_tried"] = len(table)
    out["top_on_first_half"] = [{"measure": c, "rank_correlation": round(r, 3),
                                 "on_second_half": round(rank_corr(within(confirm, c), conf_phq), 3)}
                                for c, r in table[:12]]
    out["steps_alone"] = {"first_half": round(dict(table).get("steps_awake_mean", float("nan")), 3),
                          "second_half": round(rank_corr(within(confirm, "steps_awake_mean"), conf_phq), 3)}

    # A combined score: the top k measures, each in the person's own spread, signed as on the first half.
    def combined(d: pd.DataFrame, k: int) -> pd.Series:
        tot = None
        for c, r in table[:k]:
            w = within(d, c)
            sd = d.assign(w=w).groupby("person")["w"].transform("std").replace(0, float("nan"))
            z = (w / sd).fillna(0) * (1 if r > 0 else -1)
            tot = z if tot is None else tot + z
        return tot / k

    best_k, best = 1, 0.0
    tried = {}
    for k in (1, 2, 3, 5, 8, 12):
        r = rank_corr(combined(find, k), find_phq)
        tried[k] = round(r, 3)
        if abs(r) > abs(best):
            best_k, best = k, r
    confirm = confirm.assign(score=combined(confirm, best_k), phq_dev=conf_phq)
    stat = lambda d: rank_corr(d["score"], d["phq_dev"])
    out["combined_score"] = {"tried_on_first_half": tried, "chosen_k": best_k, "first_half": round(best, 3),
                             "second_half": round(stat(confirm), 3), "second_half_interval_95": interval(confirm, stat, rng),
                             "measures": [c for c, _ in table[:best_k]]}
    # As a flag: the highest fifth of the combined score within the confirmation half.
    cut = confirm["score"].quantile(0.8)
    hi = confirm["score"] >= cut
    stat2 = lambda d: float(d.loc[d["score"] >= cut, "phq_dev"].mean() - d.loc[d["score"] < cut, "phq_dev"].mean())
    out["flag_on_second_half"] = {"windows_flagged": int(hi.sum()), "of": int(len(confirm)),
                                  "phq9_difference": round(stat2(confirm), 2),
                                  "interval_95": interval(confirm, stat2, rng)}
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("data")
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    res = run(a.data)
    print(json.dumps(res, indent=1))
    if a.out:
        json.dump(res, open(a.out, "w"), indent=1)
