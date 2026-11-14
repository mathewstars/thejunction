"""PSYCHE-D, second search for a stronger within-person signal.

Three ideas, each chosen on the first half of the four-window people (as in
psyched_explore.py) and then checked on people that no earlier step had looked at: the
1,717 people with two or three windows. The second half of the four-window people, already
seen once, is reported beside it.

A. Where does the relation live? The same steps-against-own-average comparison, only in
   people who were ever at or above 10 on the PHQ-9 (the clinical range), and only in people
   whose score moved by 5 points or more (a change that matters clinically).
B. Change against change: from one window to the next, did the PHQ-9 move with the steps?
C. A learned combination: gradient boosting on every passive step and sleep measure, each as
   the person's own deviation, predicting the person's own PHQ-9 deviation.

    python psyched_explore2.py data.parquet [--out result.json]   (pandas, pyarrow, scikit-learn)
"""

import argparse
import hashlib
import json
import random

import pandas as pd
from sklearn.ensemble import HistGradientBoostingRegressor


def dev(df: pd.DataFrame, col: str) -> pd.Series:
    return df[col] - df.groupby("person")[col].transform("mean")


def rc(a: pd.Series, b: pd.Series) -> float:
    ok = a.notna() & b.notna()
    return round(float(a[ok].rank().corr(b[ok].rank())), 3) if ok.sum() > 50 else float("nan")


def ci(df: pd.DataFrame, stat, rng: random.Random, n: int = 300) -> list[float]:
    groups = [g for _, g in df.groupby("person")]
    vals = sorted(stat(pd.concat([groups[rng.randrange(len(groups))] for _ in groups])) for _ in range(n))
    return [round(vals[int(0.025 * n)], 3), round(vals[int(0.975 * n)], 3)]


def run(path: str) -> dict:
    rng = random.Random(20261115)
    df = pd.read_parquet(path)
    df["person"] = [str(i).split("_")[0] for i in df.index]
    df["month"] = [int(str(i).split("_")[1]) for i in df.index]
    df = df.dropna(subset=["phq9_score_end", "steps_awake_mean"])
    size = df.groupby("person")["person"].transform("size")
    four = df[size >= 4].copy()
    half = four["person"].map(lambda p: int(hashlib.sha256(p.encode()).hexdigest(), 16) % 2)
    sets = {"chosen_on": four[half == 0].copy(), "fresh_people": df[(size >= 2) & (size <= 3)].copy(),
            "second_half_seen_before": four[half == 1].copy()}
    out: dict = {"people": {k: int(v["person"].nunique()) for k, v in sets.items()}}

    # A. Subgroups by the person's own PHQ-9 history.
    def steps_r(d: pd.DataFrame) -> float:
        return rc(dev(d, "steps_awake_mean"), dev(d, "phq9_score_end"))
    groups = {"everyone": lambda g: True, "ever_10_or_more": lambda g: g.max() >= 10,
              "moved_5_or_more": lambda g: g.max() - g.min() >= 5,
              "both": lambda g: g.max() >= 10 and g.max() - g.min() >= 5}
    out["A_steps_by_group"] = {}
    for name, rule in groups.items():
        row = {}
        for sname, d in sets.items():
            keep = d.groupby("person")["phq9_score_end"].transform(rule).astype(bool)
            sub = d[keep]
            row[sname] = {"people": int(sub["person"].nunique()), "rank_correlation": steps_r(sub)}
            if sname == "fresh_people" and len(sub) > 100:
                row[sname]["interval_95"] = ci(sub, steps_r, rng)
        out["A_steps_by_group"][name] = row

    # B. Change from one window to the next.
    out["B_change_to_next_window"] = {}
    for sname, d in sets.items():
        d = d.sort_values(["person", "month"])
        d["d_steps"] = d.groupby("person")["steps_awake_mean"].diff()
        d["d_phq"] = d.groupby("person")["phq9_score_end"].diff()
        d["gap"] = d.groupby("person")["month"].diff()
        c = d[d["gap"] == 3].dropna(subset=["d_steps", "d_phq"])
        stat = lambda x: rc(x["d_steps"], x["d_phq"])
        big = c[c["d_steps"] <= -2000]
        out["B_change_to_next_window"][sname] = {
            "pairs": int(len(c)), "rank_correlation": stat(c),
            **({"interval_95": ci(c, stat, rng)} if sname == "fresh_people" else {}),
            "pairs_with_2000_fewer_steps": int(len(big)),
            "mean_phq9_change_then": round(float(big["d_phq"].mean()), 2),
            "mean_phq9_change_otherwise": round(float(c.loc[c["d_steps"] > -2000, "d_phq"].mean()), 2)}

    # C. A learned combination of all passive measures, as own deviations.
    passive = [c for c in df.columns if c.startswith(("steps", "sleep")) and pd.api.types.is_numeric_dtype(df[c])]
    def xy(d: pd.DataFrame):
        x = pd.DataFrame({c: dev(d, c) for c in passive})
        return x, dev(d, "phq9_score_end")
    xf, yf = xy(sets["chosen_on"])
    model = HistGradientBoostingRegressor(max_depth=3, learning_rate=0.05, max_iter=200, random_state=0).fit(xf, yf)
    out["C_learned_combination"] = {"measures": len(passive)}
    for sname in ("fresh_people", "second_half_seen_before"):
        d = sets[sname].copy()
        x, y = xy(d)
        d["pred"], d["y"] = model.predict(x), y
        stat = lambda z: rc(z["pred"], z["y"])
        out["C_learned_combination"][sname] = {"rank_correlation": stat(d),
                                               **({"interval_95": ci(d, stat, rng)} if sname == "fresh_people" else {}),
                                               "steps_alone_same_people": -steps_r(d)}
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
