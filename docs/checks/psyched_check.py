"""Our movement hypothesis on real people: the public PSYCHE-D dataset.

PSYCHE-D (Makhmutova et al., Evidation; https://zenodo.org/records/5085146, CC BY-NC 4.0) is a
feature table from the DiSCover Project: about 10,000 adults in the United States who wore a
Fitbit for a year and filled in the PHQ-9 every three months. One row is one person and one
three-month window: the PHQ-9 at its start and end, and summaries of the steps and sleep in
it. The data is NOT in this repository.

    curl -L -o data.parquet "https://zenodo.org/api/records/5085146/files/anon_processed_df_parquet/content"
    python psyched_check.py data.parquet [--out result.json]        (needs pandas and pyarrow)

It has no daily series, so our own-normal rule cannot be run on it as it runs on the server.
What it can test is the hypothesis the rule rests on, fixed on 13 November before any data:
within one person, less movement goes with worse symptoms. Three ways, all within person:

1. Across a person's windows: in the windows where they walked less than their own average,
   was their PHQ-9 higher than their own average?
2. The same as a rule, in the spirit of ours: when a window's steps were clearly below the
   person's own normal (1.5 of their own spreads or more under their own median, from their
   other windows), how did their PHQ-9 in that window compare with their own other windows?
3. Inside one window: did the PHQ-9 change over the three months go with the trend of the
   steps in it?

Intervals come from resampling people, not rows, 2,000 times.
"""

import argparse
import json
import random
import sys

import pandas as pd

MIN_WINDOWS = 4  # windows a person needs before they are compared with themselves


def rank_corr(a: pd.Series, b: pd.Series) -> float:
    return float(a.rank().corr(b.rank()))


def by_person_interval(df: pd.DataFrame, stat, rng: random.Random, n: int = 2000) -> list[float]:
    groups = [g for _, g in df.groupby("person")]
    vals = []
    for _ in range(n):
        pick = pd.concat([groups[rng.randrange(len(groups))] for _ in groups])
        vals.append(stat(pick))
    vals.sort()
    return [round(vals[int(0.025 * n)], 3), round(vals[int(0.975 * n)], 3)]


def run(path: str) -> dict:
    rng = random.Random(20261115)
    df = pd.read_parquet(path)
    df["person"] = [str(i).split("_")[0] for i in df.index]
    df = df.dropna(subset=["steps_awake_mean", "phq9_score_end", "phq9_score_start"])
    out: dict = {"dataset": "PSYCHE-D (DiSCover Project, Evidation), Zenodo 5085146; not in this repository",
                 "rows": int(len(df)), "people": int(df["person"].nunique())}

    # 1. Within a person, across their windows.
    many = df[df.groupby("person")["person"].transform("size") >= MIN_WINDOWS].copy()
    many["steps_dev"] = many["steps_awake_mean"] - many.groupby("person")["steps_awake_mean"].transform("mean")
    many["phq_dev"] = many["phq9_score_end"] - many.groupby("person")["phq9_score_end"].transform("mean")
    stat1 = lambda d: rank_corr(d["steps_dev"], d["phq_dev"])
    out["within_person_across_windows"] = {
        "people": int(many["person"].nunique()), "rows": int(len(many)), "expected_sign": "negative",
        "rank_correlation": round(stat1(many), 3), "interval_95": by_person_interval(many, stat1, rng, 400),
        "phq9_per_1000_fewer_steps": round(float(-many["steps_dev"].cov(many["phq_dev"]) / many["steps_dev"].var() * 1000), 3)}

    # 1b. The same after taking out what every person shares in a given study month (season,
    # getting used to the questionnaire), so a common drift cannot make the relation.
    many["month"] = [str(i).split("_")[1] for i in many.index]
    adj = many.copy()
    for col in ("steps_awake_mean", "phq9_score_end"):
        adj[col] = adj[col] - adj.groupby("month")[col].transform("mean")
    adj["steps_dev"] = adj["steps_awake_mean"] - adj.groupby("person")["steps_awake_mean"].transform("mean")
    adj["phq_dev"] = adj["phq9_score_end"] - adj.groupby("person")["phq9_score_end"].transform("mean")
    out["within_person_across_windows_month_removed"] = {
        "rank_correlation": round(stat1(adj), 3), "interval_95": by_person_interval(adj, stat1, rng, 400)}

    # 2. As a rule: a window clearly below the person's own normal (leave-one-out median and spread).
    rows = []
    for _, g in many.groupby("person"):
        s, p = g["steps_awake_mean"].tolist(), g["phq9_score_end"].tolist()
        for i in range(len(s)):
            rest = s[:i] + s[i + 1:]
            med = sorted(rest)[len(rest) // 2] if len(rest) % 2 else sum(sorted(rest)[len(rest) // 2 - 1:len(rest) // 2 + 1]) / 2
            mad = sorted(abs(v - med) for v in rest)
            mad = mad[len(mad) // 2] if len(mad) % 2 else sum(mad[len(mad) // 2 - 1:len(mad) // 2 + 1]) / 2
            scale = max(mad * 1.4826, abs(med) * 0.05)
            others = p[:i] + p[i + 1:]
            rows.append((g["person"].iloc[0], (s[i] - med) / scale <= -1.5, p[i] - sum(others) / len(others)))
    r = pd.DataFrame(rows, columns=["person", "low", "phq_vs_own"])
    stat2 = lambda d: float(d.loc[d["low"], "phq_vs_own"].mean() - d.loc[~d["low"], "phq_vs_own"].mean())
    out["windows_clearly_below_own_normal"] = {
        "windows": int(len(r)), "low_windows": int(r["low"].sum()),
        "people_with_a_low_window": int(r.loc[r["low"], "person"].nunique()),
        "phq9_vs_own_other_windows_when_low": round(float(r.loc[r["low"], "phq_vs_own"].mean()), 2),
        "phq9_vs_own_other_windows_otherwise": round(float(r.loc[~r["low"], "phq_vs_own"].mean()), 2),
        "difference": round(stat2(r), 2), "interval_95": by_person_interval(r, stat2, rng, 400),
        "share_higher_than_own_when_low": round(float((r.loc[r["low"], "phq_vs_own"] > 0).mean()), 3),
        "share_higher_than_own_otherwise": round(float((r.loc[~r["low"], "phq_vs_own"] > 0).mean()), 3)}

    # 3. Inside one window: the trend of the steps against the change of the score.
    t = df.dropna(subset=["steps__awake__sum__coeff"]).copy()
    t["phq_change"] = t["phq9_score_end"] - t["phq9_score_start"]
    stat3 = lambda d: rank_corr(d["steps__awake__sum__coeff"], d["phq_change"])
    out["trend_inside_a_window"] = {
        "rows": int(len(t)), "people": int(t["person"].nunique()), "expected_sign": "negative",
        "rank_correlation": round(stat3(t), 3), "interval_95": by_person_interval(t, stat3, rng, 200)}
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
