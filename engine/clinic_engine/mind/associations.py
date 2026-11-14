"""The association appraisal: for ONE person over time, do the measures the
app takes move together with that person's symptom state, in the direction
the research literature leads us to expect?

Clinician-only research output. Nothing here writes to attention, suggestions,
lessons, questions or the mind's state, and nothing here produces text for
the patient. The mind never reads what this module stores.

Three parts, all code except the optional model step in engine.py:

1. data set   one row per day: each measure in data/association_hypotheses.json
              that has data that day, and the reference (a clinician rating
              when there are enough of them, else the proxy movement_z)
2. statistics Spearman rho (oriented: positive = moves in the expected
              direction when symptoms are worse), bootstrap 95% interval,
              permutation p-value, Benjamini-Hochberg across the measures
              tested, the lag with the largest association, Cliff's delta
              between days with attention held and other days. Standard
              library only, seeded, so the same data give the same numbers.
3. appraisal  code's own reading of the table (the same shape the model must
              return), and the checks that hold the model to code's rules:
              merge() keeps what the model may judge (caveats, the overall
              pattern, the main alternative, the next step) and replaces what
              it got wrong by code's value, field by field, saying so.
"""

from __future__ import annotations

import json
import math
import random
from datetime import date, datetime, timedelta
from functools import lru_cache
from pathlib import Path
from statistics import fmean

from .thresholds import T, Thresholds

DATA_DIR = Path(__file__).resolve().parents[1] / "data"

AGREEMENTS = ("consistent", "opposite", "inconclusive", "related_no_prediction")
STRENGTHS = ("negligible", "weak", "moderate", "strong")
PATTERNS = ("consistent_with_worse_state", "partly_consistent", "no_clear_relation",
            "opposite_to_expectation", "insufficient_data")
CONFIDENCE = ("low", "medium", "high")
NEXT_STEPS = ("collect_more_sessions", "add_reference_rating", "review_tracking_quality",
              "discuss_with_patient", "none")
DESIGN_TYPE = "within_person_time_series"
SCALE_ORDER = ("phq9", "phq2", "clinician_global")
PROXY = "movement_z"

DISCLAIMER = ("This is a within-person description of how this person's measurements moved "
              "together over time. It is not validated, and it is not a diagnosis.")

# Data notes beyond the caveat codes of the hypotheses file.
EXTRA_NOTES = {
    "short_period": "The period with data is short.",
    "few_ratings": "Fewer clinical ratings than needed; a proxy was used instead.",
    "no_face_data": "No usable face data in this period.",
}

# Code's own per-row caveats, by measure.
_TASK_CONFOUND = {"face.look_down_share", "face.head_pitch_deg", "face.head_movement"}
_MEDICATION = {"face.facial_activity", "face.blink_rate_per_min", "face.blink_duration_ms",
               "focus.median_reaction_ms", "focus.reaction_spread_ms"}
_GLASSES = {"face.eye_smile_share", "face.blink_rate_per_min", "face.blink_duration_ms",
            "face.look_down_share"}
_FATIGUE = {"focus.median_reaction_ms", "focus.error_rate", "activity.completed_share",
            "daily.steps", "daily.walking_speed_m_s", "daily.hrv_ms", "daily.sleep_h",
            "face.blink_duration_ms"}
# Movement measures that ARE the proxy reference; never correlated with it.
_REFERENCE_MEASURES = {PROXY: {"daily.steps", "daily.walking_speed_m_s"}}


@lru_cache(maxsize=1)
def hypotheses() -> dict:
    return json.loads((DATA_DIR / "association_hypotheses.json").read_text("utf-8"))


@lru_cache(maxsize=1)
def prompt_text() -> str:
    return (DATA_DIR / "association_prompt.txt").read_text("utf-8")


def caveat_codes() -> list[str]:
    return list(hypotheses()["caveats"])


def note_text(code: str) -> str:
    return hypotheses()["caveats"].get(code) or EXTRA_NOTES.get(code, "")


def note_codes() -> list[str]:
    return caveat_codes() + list(EXTRA_NOTES)


# ============================================================================
# 2. statistics (pure functions; tested on hand-built series)
# ============================================================================

def ranks(v: list[float]) -> list[float]:
    """1-based ranks; ties get their average rank."""
    order = sorted(range(len(v)), key=lambda i: v[i])
    out = [0.0] * len(v)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and v[order[j + 1]] == v[order[i]]:
            j += 1
        avg = (i + j) / 2 + 1
        for k in range(i, j + 1):
            out[order[k]] = avg
        i = j + 1
    return out


def pearson(a: list[float], b: list[float]) -> float | None:
    n = len(a)
    if n < 2 or n != len(b):
        return None
    ma, mb = fmean(a), fmean(b)
    sab = saa = sbb = 0.0
    for x, y in zip(a, b):
        dx, dy = x - ma, y - mb
        sab += dx * dy
        saa += dx * dx
        sbb += dy * dy
    if saa <= 1e-12 or sbb <= 1e-12:
        return None  # one side does not vary
    return max(-1.0, min(1.0, sab / math.sqrt(saa * sbb)))


def spearman(x: list[float], y: list[float]) -> float | None:
    """Pearson correlation of the average ranks (handles ties)."""
    if len(x) != len(y) or len(x) < 3:
        return None
    return pearson(ranks(x), ranks(y))


def permutation_p(x: list[float], y: list[float], n_perm: int, rng: random.Random) -> float | None:
    """Two-sided permutation p-value for Spearman rho: shuffle one side's ranks."""
    rx, ry = ranks(x), ranks(y)
    obs = pearson(rx, ry)
    if obs is None:
        return None
    perm = list(ry)
    hits = 0
    for _ in range(n_perm):
        rng.shuffle(perm)
        r = pearson(rx, perm)
        if r is not None and abs(r) >= abs(obs) - 1e-12:
            hits += 1
    return (hits + 1) / (n_perm + 1)


def _quantile(sorted_vals: list[float], q: float) -> float:
    pos = q * (len(sorted_vals) - 1)
    lo = math.floor(pos)
    hi = min(lo + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (pos - lo)


def bootstrap_ci(x: list[float], y: list[float], n_boot: int,
                 rng: random.Random) -> tuple[float | None, float | None]:
    """Percentile 95% interval of Spearman rho over day pairs resampled with
    replacement. Resamples where one side does not vary are skipped; with
    fewer than half usable, no interval."""
    n = len(x)
    vals = []
    for _ in range(n_boot):
        idx = [rng.randrange(n) for _ in range(n)]
        r = spearman([x[i] for i in idx], [y[i] for i in idx])
        if r is not None:
            vals.append(r)
    if len(vals) < n_boot / 2:
        return None, None
    vals.sort()
    return _quantile(vals, 0.025), _quantile(vals, 0.975)


def bh_adjust(ps: list[float]) -> list[float]:
    """Benjamini-Hochberg adjusted p-values, in the input order."""
    m = len(ps)
    order = sorted(range(m), key=lambda i: ps[i])
    out = [1.0] * m
    running = 1.0
    for rank in range(m, 0, -1):
        i = order[rank - 1]
        running = min(running, ps[i] * m / rank)
        out[i] = min(1.0, running)
    return out


def cliffs_delta(a: list[float], b: list[float]) -> float | None:
    """P(a > b) - P(a < b) over all pairs."""
    if not a or not b:
        return None
    gt = lt = 0
    for x in a:
        for y in b:
            if x > y:
                gt += 1
            elif x < y:
                lt += 1
    return (gt - lt) / (len(a) * len(b))


def lagged_pairs(measure: dict[date, float], ref: dict[date, float],
                 lag: int) -> tuple[list[float], list[float]]:
    """Pair the measure on day d with the reference on day d - lag. A negative
    lag pairs today's measure with a LATER reference: the measure moves first."""
    xs, ys = [], []
    for d in sorted(measure):
        r = ref.get(d - timedelta(days=lag))
        if r is not None:
            xs.append(measure[d])
            ys.append(r)
    return xs, ys


def orient_sign(expected: str) -> int:
    """Reference values are 'higher = worse'. A measure expected LOWER when
    worse is flipped, so a positive oriented rho always means 'as expected'."""
    return -1 if expected == "lower" else 1


def best_lag(measure: dict[date, float], ref: dict[date, float], expected: str,
             th: Thresholds = T) -> tuple[int | None, int | None]:
    """(lead_days, n at that lag): the lag in -max..+max with the largest
    oriented association (largest |rho| for 'mixed'), among lags with at least
    assoc_min_n pairs. Ties go to the smaller |lag|."""
    sign = orient_sign(expected)
    best: tuple[float, int, int] | None = None
    for lag in sorted(range(-th.assoc_max_lag, th.assoc_max_lag + 1), key=lambda k: (abs(k), k)):
        xs, ys = lagged_pairs(measure, ref, lag)
        if len(xs) < th.assoc_min_n:
            continue
        r = spearman(xs, ys)
        if r is None:
            continue
        score = abs(r) if expected == "mixed" else sign * r
        if best is None or score > best[0] + 1e-9:
            best = (score, lag, len(xs))
    return (best[1], best[2]) if best else (None, None)


def _r2(x: float | None) -> float | None:
    return None if x is None else round(float(x), 2)


def row_stats(key: str, expected: str, measure: dict[date, float], ref: dict[date, float],
              held: set[date], th: Thresholds = T, daily: dict[date, float] | None = None,
              find_lag: bool = True) -> dict:
    """All numbers for one measure. Rounded to 2 decimals here, so code judges
    exactly the numbers the model sees. `measure` and `ref` hold one value per
    observation (a rating occasion, or a day with a proxy reference); `daily`
    is the day-by-day measure for the held-days contrast."""
    xs, ys = lagged_pairs(measure, ref, 0)
    n = len(xs)
    out: dict = {"n": n, "rho": None, "ci_low": None, "ci_high": None, "p": None,
                 "lead_days": None, "lead_n": None, "contrast": None,
                 "change_rho": None, "change_n": None}
    per_day = measure if daily is None else daily
    held_vals = [v for d, v in per_day.items() if d in held]
    other_vals = [v for d, v in per_day.items() if d not in held]
    if len(held_vals) >= th.assoc_min_contrast_days and len(other_vals) >= th.assoc_min_contrast_days:
        cd = cliffs_delta(held_vals, other_vals)
        if cd is not None:
            out["contrast"] = _r2(cd if expected == "mixed" else orient_sign(expected) * cd)
    if n < th.assoc_min_n:
        out["status"] = "insufficient"
        return out
    raw = spearman(xs, ys)
    if raw is None:
        out["status"] = "no_variation"
        return out
    sign = 1 if expected == "mixed" else orient_sign(expected)
    seed = f"{th.assoc_seed}:{key}"
    lo, hi = bootstrap_ci(xs, ys, th.assoc_bootstrap, random.Random(seed + ":boot"))
    p = permutation_p(xs, ys, th.assoc_permutations, random.Random(seed + ":perm"))
    if sign < 0 and lo is not None:
        lo, hi = -hi, -lo
    lead, lead_n = best_lag(measure, ref, expected, th) if find_lag else (None, None)
    out.update(status="tested", rho=_r2(sign * raw), ci_low=_r2(lo), ci_high=_r2(hi),
               p=p, lead_days=lead, lead_n=lead_n)
    if not find_lag:
        # With one observation per rating: does the measure CHANGE when the
        # score changes, from one rating to the next? Two series that only drift
        # slowly over the same weeks correlate in level and not in change.
        dx = [b - a for a, b in zip(xs, xs[1:])]
        dy = [b - a for a, b in zip(ys, ys[1:])]
        ch = spearman(dx, dy) if len(dx) >= th.assoc_min_n - 1 else None
        out.update(change_rho=None if ch is None else _r2(sign * ch), change_n=len(dx))
    return out


# ============================================================================
# 1. the data set
# ============================================================================

def _local_day(iso: str, tz) -> date:
    return datetime.fromisoformat(iso).astimezone(tz).date()


def _held_days(items: list[dict], today: date, tz) -> set[date]:
    """Days on which an attention item that reached 'attention' or 'urgent'
    was held (from its `since` day, or the day it opened, to the day it closed)."""
    out: set[date] = set()
    for it in items:
        if (it.get("peak_level") or it.get("level")) not in ("attention", "urgent"):
            continue
        try:
            start = date.fromisoformat(it["since"]) if it.get("since") else \
                _local_day(it["opened_at"], tz)
            end = _local_day(it["closed_at"], tz) if it.get("closed_at") else today
        except (KeyError, ValueError):
            continue
        d = start
        while d <= end:
            out.add(d)
            d += timedelta(days=1)
    return out


def choose_reference(ratings: list[dict], start: date, end: date,
                     th: Thresholds = T) -> tuple[str, dict[date, float]] | None:
    """A rating scale with at least assoc_min_ratings ratings in (or near) the
    period. Each rating stands for the days within assoc_rating_carry_days of
    it; a day near two ratings takes the nearer one (the later one on a tie).
    No interpolation beyond that. Values are 'higher = worse'."""
    carry = th.assoc_rating_carry_days
    scales = hypotheses()["reference_scales"]
    by_scale: dict[str, list[dict]] = {}
    for r in ratings:
        d = date.fromisoformat(r["date"])
        if r.get("scale") in scales and start - timedelta(days=carry) <= d <= end + timedelta(days=carry):
            by_scale.setdefault(r["scale"], []).append(r)
    usable = [s for s in SCALE_ORDER if len(by_scale.get(s, [])) >= th.assoc_min_ratings]
    if not usable:
        return None
    scale = max(usable, key=lambda s: (len(by_scale[s]), -SCALE_ORDER.index(s)))
    sign = 1 if scales[scale]["worse_is"] == "higher" else -1
    rs = sorted(by_scale[scale], key=lambda r: (r["date"], r.get("created_at", "")))
    out: dict[date, float] = {}
    d = start
    while d <= end:
        best = None
        for r in rs:
            dist = abs((date.fromisoformat(r["date"]) - d).days)
            if dist <= carry and (best is None or dist <= best[0]):
                best = (dist, r)
        if best is not None:
            out[d] = sign * float(best[1]["score"])
        d += timedelta(days=1)
    return scale, out


def build_dataset(days: dict[str, dict], series: list[dict], activities: list[dict],
                  ratings: list[dict], items: list[dict], tz, today: date,
                  th: Thresholds = T) -> dict:
    """Everything the statistics need, per day. Reads only; writes nothing."""
    start = today - timedelta(days=th.assoc_window_days - 1)
    feats = hypotheses()["features"]
    measures: dict[str, dict[date, list[float]]] = {f["key"]: {} for f in feats}
    usable: dict[str, list[int]] = {f["key"]: [0, 0] for f in feats}  # [usable, of]

    def add(key: str, d: date, v) -> None:
        if key in measures and v is not None:
            measures[key].setdefault(d, []).append(float(v))

    acts = [a for a in activities if start <= _local_day(a["started_at"], tz) <= today]
    sessions = [a for a in acts if a["type"] in ("focus", "breathing")]
    face_sessions = [a for a in sessions if a.get("face")]
    hours = []
    for a in acts:
        d = _local_day(a["started_at"], tz)
        f = a.get("features") or {}
        if a["type"] in ("focus", "breathing"):
            add("activity.completed_share", d, 1.0 if f.get("completed", a.get("completed")) else 0.0)
            usable["activity.completed_share"][0] += 1
            usable["activity.completed_share"][1] += 1
            face = a.get("face") or {}
            good = a.get("face_quality") == "good"
            if face:
                hours.append(datetime.fromisoformat(a["started_at"]).astimezone(tz).hour)
            for key in measures:
                if not key.startswith("face."):
                    continue
                name = key[5:]
                if face:
                    usable[key][1] += 1
                    if good and face.get(name) is not None:
                        usable[key][0] += 1
                        add(key, d, face[name])
        if a["type"] == "focus":
            for name in ("median_reaction_ms", "reaction_spread_ms", "error_rate"):
                usable["focus." + name][1] += 1
                if f.get(name) is not None:
                    usable["focus." + name][0] += 1
                    add("focus." + name, d, f[name])
        if a["type"] == "checkin":
            usable["checkin.good_things"][1] += 1
            if f.get("good_things") is not None:
                usable["checkin.good_things"][0] += 1
                add("checkin.good_things", d, f["good_things"])
            usable["checkin.plan_done_share"][1] += 1
            if f.get("plan_done") in ("yes", "no"):
                usable["checkin.plan_done_share"][0] += 1
                add("checkin.plan_done_share", d, 1.0 if f["plan_done"] == "yes" else 0.0)
    day_dates = [date.fromisoformat(ds) for ds in days if start <= date.fromisoformat(ds) <= today]
    for d in day_dates:
        rec = days[d.isoformat()]
        for metric in ("steps", "walking_speed_m_s", "sleep_h", "hrv_ms"):
            key = "daily." + metric
            if key in usable:
                usable[key][1] += 1
                if rec.get(metric) is not None:
                    usable[key][0] += 1
                    add(key, d, rec[metric])

    per_day = {k: {d: fmean(v) for d, v in m.items()} for k, m in measures.items()}
    covered = sorted({d for m in per_day.values() for d in m})
    first = covered[0] if covered else today

    ref = choose_reference(ratings, first, today, th)
    notes: list[str] = []
    if ref is not None:
        ref_key, ref_vals = ref
        kind = "rating"
        n_ratings = sum(1 for r in ratings if r.get("scale") == ref_key)
    else:
        ref_key, kind, n_ratings = PROXY, "proxy", None
        ref_vals = {date.fromisoformat(s["date"]): -float(s["movement_z"])
                    for s in series if s.get("movement_z") is not None
                    and first <= date.fromisoformat(s["date"]) <= today}
        notes.append("no_reference_rating")
        if ratings:
            notes.append("few_ratings")
        notes.append("proxy_shares_cause")

    n_face_low = sum(1 for a in face_sessions if a.get("face_quality") != "good")
    if len(sessions) < th.assoc_few_sessions:
        notes.append("few_sessions")
    if face_sessions and n_face_low / len(face_sessions) > th.assoc_poor_tracking_share:
        notes.append("poor_tracking")
    if not any(a.get("face_quality") == "good" for a in face_sessions):
        notes.append("no_face_data")
    if len(covered) < th.assoc_short_period_days:
        notes.append("short_period")
    if hours and max(hours) - min(hours) >= th.assoc_time_of_day_hours:
        notes.append("time_of_day")
    all_sessions = [a for a in activities if a["type"] in ("focus", "breathing")]
    early = all_sessions[:th.activity_baseline_min]
    if early and any(start <= _local_day(a["started_at"], tz) for a in early):
        notes.append("novelty")
    notes.append("single_person")

    # What counts as one observation. With a rating scale it is ONE RATING: the
    # measure is averaged over the week that ends on the rating day. Days between
    # ratings are not treated as separate observations (they are not independent,
    # and the rating says nothing about them). With a proxy it is one day.
    if kind == "rating":
        win = th.assoc_occasion_days
        stat_ref = {d: v for d, v in ref_vals.items()
                    if any(r.get("scale") == ref_key and r["date"] == d.isoformat() for r in ratings)}
        stat_measures = {}
        for k, m in per_day.items():
            occ = {}
            for rd in stat_ref:
                vals = [v for d, v in m.items() if 0 <= (rd - d).days < win]
                if vals:
                    occ[rd] = fmean(vals)
            stat_measures[k] = occ
        unit = "rating"
    else:
        stat_ref, stat_measures, unit = ref_vals, per_day, "day"
    if kind == "rating":
        ref_points = sorted((date.fromisoformat(r["date"]), float(r["score"])) for r in ratings
                            if r.get("scale") == ref_key
                            and first <= date.fromisoformat(r["date"]) <= today)
    else:
        ref_points = sorted(ref_vals.items())
    return {"start": first, "end": today, "measures": per_day, "ref_points": ref_points,
            "quality": {k: (round(u / of, 2) if of else None) for k, (u, of) in usable.items()},
            "reference": {"key": ref_key, "kind": kind, "n_ratings": n_ratings},
            "ref_values": ref_vals, "held": _held_days(items, today, tz),
            "stat_ref": stat_ref, "stat_measures": stat_measures, "unit": unit,
            "n_obs": len(stat_ref),
            "n_days": len(covered), "n_sessions": len(acts), "notes": notes}


def compute_rows(ds: dict, th: Thresholds = T) -> list[dict]:
    """One row per hypothesis measure, with the statistics and BH across the tested."""
    feats = hypotheses()["features"]
    is_ref = _REFERENCE_MEASURES.get(ds["reference"]["key"], set())
    rows = []
    for f in feats:
        base = {k: f[k] for k in ("key", "label", "group", "expected", "support", "why")}
        base["quality"] = ds["quality"].get(f["key"])
        if f["key"] in is_ref:
            rows.append({**base, "status": "is_reference", "n": len(ds["measures"][f["key"]]),
                         "rho": None, "ci_low": None, "ci_high": None, "p": None,
                         "lead_days": None, "lead_n": None, "contrast": None,
                         "change_rho": None, "change_n": None})
            continue
        stat_m = ds.get("stat_measures", ds["measures"])[f["key"]]
        rows.append({**base, **row_stats(f["key"], f["expected"], stat_m,
                                         ds.get("stat_ref", ds["ref_values"]), ds["held"], th,
                                         daily=ds["measures"][f["key"]],
                                         find_lag=ds.get("unit", "day") == "day")})
    tested = [r for r in rows if r["status"] == "tested" and r["p"] is not None]
    for r, pa in zip(tested, bh_adjust([r["p"] for r in tested])):
        r["p_adj"] = _r2(pa)
    for r in rows:
        r.setdefault("p_adj", None)
        r["p"] = None if r["p"] is None else round(r["p"], 4)
    if len(tested) > th.assoc_many_tests and "many_tests" not in ds["notes"]:
        ds["notes"].insert(len(ds["notes"]) - 1, "many_tests")
    return rows


# ============================================================================
# 3. appraisal: code's own, and the checks on the model's
# ============================================================================

def strength_of(x: float, th: Thresholds = T) -> str:
    x = abs(x)
    if x < th.assoc_strength_weak:
        return "negligible"
    if x < th.assoc_strength_moderate:
        return "weak"
    if x <= th.assoc_strength_strong:
        return "moderate"
    return "strong"


def code_agreement(row: dict, th: Thresholds = T) -> str:
    """Step 4 of the prompt, with the corrected-p rule of step 3."""
    rho, lo, hi, pa = row["rho"], row["ci_low"], row["ci_high"], row["p_adj"]
    if rho is None or lo is None or hi is None:
        return "inconclusive"
    if row["expected"] == "mixed":
        return "related_no_prediction" if (lo > 0 or hi < 0) else "inconclusive"
    if rho > 0 and lo > 0 and pa is not None and pa <= th.assoc_p_adj_max:
        return "consistent"
    if rho < 0 and hi < 0:
        return "opposite"
    return "inconclusive"


def max_strength(row: dict, th: Thresholds = T) -> str:
    """Step 5 and step 3: the strongest label the interval supports (the end
    of the interval nearest zero; an interval across zero supports
    'negligible'), and at most 'weak' with few paired days."""
    lo, hi, rho = row["ci_low"], row["ci_high"], row["rho"]
    if rho is None or lo is None or hi is None or (lo <= 0 <= hi):
        return "negligible"
    s = strength_of(min(abs(rho), abs(lo), abs(hi)), th)
    if row["n"] < th.assoc_weak_n and STRENGTHS.index(s) > STRENGTHS.index("weak"):
        s = "weak"
    return s


def code_caveats(row: dict, ref_kind: str, th: Thresholds = T) -> tuple[list[str], list[str]]:
    """(required, suggested) caveat codes for a row. Required ones stay even
    when the model leaves them out."""
    req, sug = [], []
    if row.get("quality") is not None and row["quality"] < th.assoc_row_quality_min:
        req.append("poor_tracking")
    if row["n"] < th.assoc_weak_n:
        req.append("few_sessions")
    if ref_kind == "proxy":
        req.append("proxy_shares_cause")
    if row["expected"] == "mixed" or row["support"] == "mixed":
        req.append("mixed_literature")
    k = row["key"]
    if k in _TASK_CONFOUND:
        # Required: the page's headline passes over a measure the task itself
        # moves (looking down at the phone), and must do so whatever a model says.
        req.append("task_confound")
    if k in _MEDICATION:
        sug.append("medication")
    if k in _GLASSES:
        sug.append("glasses_or_light")
    if k in _FATIGUE:
        sug.append("fatigue_or_illness")
    return req, sug


def _lines(rows: list[dict]) -> tuple[list[dict], int]:
    """Consistent rows that are at least weak, and how many different groups they span."""
    cons = [r for r in rows if r.get("agreement") == "consistent"
            and r.get("strength") not in (None, "negligible")]
    return cons, len({r["group"] for r in cons})


def _confidence_cap(ref_kind: str, lines: int, strongest_n: int, th: Thresholds = T,
                    unit: str = "day", n_obs: int | None = None) -> str:
    """The most confidence the data can carry, whoever asks. With one
    observation per rating, fewer than assoc_low_ratings ratings from one
    person always give "low": no pattern of rows changes that."""
    if unit == "rating" and (n_obs or 0) < th.assoc_low_ratings:
        return "low"
    if ref_kind == "rating" and lines >= th.assoc_high_lines and strongest_n >= th.assoc_high_n:
        return "high"
    return "medium"


def _groups_mostly_agree(rows: list[dict]) -> bool:
    """For "consistent": in every group that has a line (a consistent row that
    is at least weak), at least half of the rows with an expected direction are
    as expected. One good row among five in a group is "partly"."""
    cons, _ = _lines(rows)
    for g in {r["group"] for r in cons}:
        directional = [r for r in rows if r["group"] == g and r["expected"] != "mixed"]
        agree = [r for r in directional if r.get("agreement") == "consistent"]
        if 2 * len(agree) < len(directional):
            return False
    return True


def _pattern_allowed(pattern: str, rows: list[dict], lines: int, tested: int,
                     th: Thresholds = T) -> bool:
    if tested < th.assoc_min_tested_rows:
        return pattern == "insufficient_data"
    cons, _ = _lines(rows)
    if pattern == "consistent_with_worse_state":
        return lines >= 2 and _groups_mostly_agree(rows)
    if pattern == "partly_consistent":
        return bool(cons)
    if pattern == "opposite_to_expectation":
        return any(r.get("agreement") == "opposite" for r in rows)
    return True  # no_clear_relation and insufficient_data: restraint is always allowed


def code_overall(rows: list[dict], ref_kind: str, notes: list[str], th: Thresholds = T,
                 unit: str = "day", n_obs: int | None = None) -> dict:
    tested = [r for r in rows if r["status"] == "tested"]
    cons, lines = _lines(tested)
    opp = [r for r in tested if r.get("agreement") == "opposite"
           and r.get("strength") not in (None, "negligible")]
    if len(tested) < th.assoc_min_tested_rows:
        pattern = "insufficient_data"
    elif cons and lines >= 2 and not opp and _groups_mostly_agree(tested):
        pattern = "consistent_with_worse_state"
    elif cons:
        pattern = "partly_consistent"
    elif opp:
        pattern = "opposite_to_expectation"
    else:
        pattern = "no_clear_relation"
    strongest = sorted(cons, key=lambda r: (-STRENGTHS.index(r["strength"]), -r["rho"], r["key"]))[:3]
    min_n = min((r["n"] for r in strongest), default=0)
    cap = _confidence_cap(ref_kind, lines, min_n, th, unit, n_obs)
    if pattern == "insufficient_data" or not cons or cap == "low":
        conf = "low"
    elif cap == "high":
        conf = "high"
    elif lines >= th.assoc_medium_lines and min_n >= th.assoc_weak_n:
        conf = "medium"
    else:
        conf = "low"
    leads = bool(cons) and sum(1 for r in cons if (r.get("lead_days") or 0) < 0) > len(cons) / 2
    if ref_kind == "proxy":
        alt = "proxy_shares_cause"
    elif "poor_tracking" in notes:
        alt = "poor_tracking"
    elif "few_sessions" in notes:
        alt = "few_sessions"
    else:
        alt = "fatigue_or_illness"
    if pattern == "insufficient_data" or "few_sessions" in notes or "short_period" in notes:
        step = "collect_more_sessions"
    elif ref_kind == "proxy":
        step = "add_reference_rating"
    elif "poor_tracking" in notes:
        step = "review_tracking_quality"
    elif pattern in ("consistent_with_worse_state", "partly_consistent"):
        step = "discuss_with_patient"
    else:
        step = "none"
    return {"pattern": pattern, "confidence": conf, "independent_lines": lines,
            "strongest": [r["key"] for r in strongest], "leads_reference": leads,
            "main_alternative": alt, "next_step": step}


OVERALL_FIELDS = ("pattern", "confidence", "independent_lines", "strongest", "leads_reference",
                  "main_alternative", "next_step")


def code_appraisal(rows: list[dict], ref_kind: str, notes: list[str],
                   th: Thresholds = T, unit: str = "day",
                   n_obs: int | None = None) -> tuple[list[dict], dict]:
    """Code's full appraisal, no model. Returns (rows with judgements, overall)."""
    out = []
    for r in rows:
        r = dict(r)
        if r["status"] == "tested":
            req, sug = code_caveats(r, ref_kind, th)
            r.update(agreement=code_agreement(r, th), strength=max_strength(r, th),
                     agreement_source="code", strength_source="code",
                     caveats=[{"code": c, "by": "code"} for c in dict.fromkeys(req + sug)])
        else:
            cav = ["few_sessions"] if r["status"] == "insufficient" else []
            r.update(agreement=None, strength=None, agreement_source=None, strength_source=None,
                     caveats=[{"code": c, "by": "code"} for c in cav])
        out.append(r)
    overall = code_overall(out, ref_kind, notes, th, unit, n_obs)
    overall["sources"] = {k: "code" for k in OVERALL_FIELDS}
    return out, overall


def merge(reply: dict, code_rows: list[dict], code_ov: dict, ref_kind: str,
          th: Thresholds = T, unit: str = "day",
          n_obs: int | None = None) -> tuple[list[dict], dict, list[dict]]:
    """Hold the model's reply (already shape-checked by the output gate) to
    code's rules. Returns (rows, overall, corrections). Every value the model
    got wrong is replaced by code's value and listed as a correction; the
    model's own value is kept in a correction only when it is an enum."""
    corrections: list[dict] = []

    def fix(where: str, key: str | None, field: str, model, code, reason: str) -> None:
        corrections.append({"where": where, "key": key, "field": field,
                            "model": model, "code": code, "reason": reason})

    by_key = {r["key"]: r for r in reply["rows"]}
    rows = []
    for cr in code_rows:
        r = dict(cr)
        m = by_key.get(r["key"])
        if r["status"] != "tested" or m is None:
            rows.append(r)
            continue
        if m["agreement"] == cr["agreement"]:
            r.update(agreement=m["agreement"], agreement_source="model")
        else:
            fix("row", r["key"], "agreement", m["agreement"], cr["agreement"],
                "agreement_not_supported_by_numbers")
            r.update(agreement=cr["agreement"], agreement_source="code_corrected")
        # The strength label is code's, always: it decides which rows count as a
        # line and which measure the page's headline names, so it must not change
        # with what a model happens to answer. A differing answer is listed.
        if m["strength"] == cr["strength"]:
            r.update(strength=cr["strength"], strength_source="model")
        else:
            fix("row", r["key"], "strength", m["strength"], cr["strength"],
                "stronger_than_interval_supports"
                if STRENGTHS.index(m["strength"]) > STRENGTHS.index(cr["strength"])
                else "strength_set_by_code")
            r.update(strength=cr["strength"], strength_source="code_corrected")
        req, _ = code_caveats(r, ref_kind, th)
        cav = [{"code": c, "by": "model"} for c in dict.fromkeys(m["caveats"])]
        have = {c["code"] for c in cav}
        cav += [{"code": c, "by": "code"} for c in req if c not in have]
        r["caveats"] = cav
        rows.append(r)

    tested = [r for r in rows if r["status"] == "tested"]
    cons, lines = _lines(tested)
    cons_keys = {r["key"] for r in tested if r.get("agreement") == "consistent"}
    mo = reply["overall"]
    ov: dict = {}
    src: dict = {}

    # independent_lines: always code's count over the (corrected) consistent rows.
    ov["independent_lines"] = lines
    if mo["independent_lines"] == lines:
        src["independent_lines"] = "model"
    else:
        src["independent_lines"] = "code_corrected"
        fix("overall", None, "independent_lines", mo["independent_lines"], lines,
            "recounted_from_consistent_rows")

    # strongest: consistent rows only, each once, at most three.
    kept = list(dict.fromkeys(k for k in mo["strongest"] if k in cons_keys))[:3]
    if kept != list(mo["strongest"]):
        fix("overall", None, "strongest", [k for k in mo["strongest"] if k in by_key],
            kept, "strongest_must_be_consistent_rows")
        src["strongest"] = "code_corrected"
    else:
        src["strongest"] = "model"
    ov["strongest"] = kept

    # pattern: code's rule on the corrected rows, always. A model may not lower it
    # either: "no clear relation" beside a forest of agreeing rows would contradict
    # the page. A differing answer is listed as a correction.
    if mo["pattern"] == code_ov["pattern"]:
        ov["pattern"], src["pattern"] = code_ov["pattern"], "model"
    else:
        ov["pattern"], src["pattern"] = code_ov["pattern"], "code_corrected"
        fix("overall", None, "pattern", mo["pattern"], code_ov["pattern"],
            "pattern_not_supported_by_rows"
            if not _pattern_allowed(mo["pattern"], tested, lines, len(tested), th)
            else "pattern_set_by_code")

    # confidence: capped by the reference kind, the lines and the observations.
    by_row = {r["key"]: r for r in tested}
    min_n = min((by_row[k]["n"] for k in kept), default=0)
    cap = _confidence_cap(ref_kind, lines, min_n, th, unit, n_obs)
    # Code's value, always, like the pattern: the page says confidence is set by
    # code, and that has to hold with twenty ratings too.
    code_conf = code_ov["confidence"]
    if CONFIDENCE.index(code_conf) > CONFIDENCE.index(cap):
        code_conf = cap
    if mo["confidence"] == code_conf:
        ov["confidence"], src["confidence"] = code_conf, "model"
    else:
        ov["confidence"], src["confidence"] = code_conf, "code_corrected"
        fix("overall", None, "confidence", mo["confidence"], code_conf,
            "confidence_above_cap_for_" + ("proxy" if ref_kind == "proxy" else
                                            "few_ratings" if cap == "low" else "data")
            if CONFIDENCE.index(mo["confidence"]) > CONFIDENCE.index(cap)
            else "confidence_set_by_code")

    # leads_reference: a claim of an early signal needs consistent rows that lead.
    if mo["leads_reference"] and not any((r.get("lead_days") or 0) < 0 for r in cons):
        ov["leads_reference"], src["leads_reference"] = False, "code_corrected"
        fix("overall", None, "leads_reference", True, False, "no_consistent_row_leads")
    else:
        ov["leads_reference"], src["leads_reference"] = mo["leads_reference"], "model"

    # main_alternative: a known caveat code (the gate blanks anything else).
    if mo.get("main_alternative") in hypotheses()["caveats"]:
        ov["main_alternative"], src["main_alternative"] = mo["main_alternative"], "model"
    else:
        ov["main_alternative"], src["main_alternative"] = code_ov["main_alternative"], \
            "code_corrected"
        fix("overall", None, "main_alternative", None, code_ov["main_alternative"],
            "unknown_caveat_code")

    ov["next_step"], src["next_step"] = mo["next_step"], "model"
    ov = {k: ov[k] for k in OVERALL_FIELDS}
    ov["sources"] = src
    return rows, ov, corrections


# ============================================================================
# the model's input: built from scratch, numbers and fixed codes only
# ============================================================================

PACK_ROW_FIELDS = ("key", "group", "expected", "support", "n", "rho", "ci_low", "ci_high",
                   "p_adj", "lead_days", "contrast", "quality")


def build_payload(ds: dict, rows: list[dict]) -> dict:
    """Exactly what association_prompt.txt describes: design, reference, rows,
    data_notes, caveat_codes. Only tested rows go (the rest have no rho)."""
    ref = ds["reference"]
    worse = (hypotheses()["reference_scales"].get(ref["key"]) or
             hypotheses()["proxy_references"].get(ref["key"]))["worse_is"]

    def num(x):
        if x is None:
            return None
        return round(float(x), 2) if isinstance(x, float) else x

    prow = []
    for r in rows:
        if r["status"] != "tested":
            continue
        item = {k: num(r[k]) for k in PACK_ROW_FIELDS}
        if r["lead_days"] is None:
            item["lead_days"] = None
        prow.append(item)
    return {
        "design": {"type": DESIGN_TYPE, "days": ds["n_days"], "sessions": ds["n_sessions"],
                   "reference": ref["key"]},
        "reference": {"key": ref["key"], "kind": ref["kind"], "worse_is": worse},
        "rows": prow,
        "data_notes": list(ds["notes"]),
        "caveat_codes": caveat_codes(),
    }


def allowed_pack_strings() -> set[str]:
    h = hypotheses()
    s = {DESIGN_TYPE, "rating", "proxy", "lower", "higher", "mixed",
         "stronger", "moderate", "weaker"}
    s |= set(h["reference_scales"]) | set(h["proxy_references"])
    for f in h["features"]:
        s |= {f["key"], f["group"], f["expected"], f["support"]}
    s |= set(note_codes())
    return s


# ============================================================================
# the stored and returned form
# ============================================================================

ROW_OUT = ("key", "label", "group", "expected", "support", "why", "status", "n", "rho",
           "ci_low", "ci_high", "p_adj", "lead_days", "contrast", "change_rho", "change_n",
           "quality", "agreement",
           "strength", "agreement_source", "strength_source")


def assemble(ds: dict, rows: list[dict], overall: dict, corrections: list[dict],
             appraised_by: str, model_name: str, now: datetime) -> dict:
    ref = ds["reference"]
    h = hypotheses()
    ref_info = h["reference_scales"].get(ref["key"]) or h["proxy_references"][ref["key"]]
    out_rows = []
    for r in rows:
        o = {k: r.get(k) for k in ROW_OUT}
        # Set by code from the key, not from the caveat list: a model may add the
        # phone-position caveat to every face measure, and the page's headline
        # must still know which measures the task itself moves.
        o["task_bound"] = r["key"] in _TASK_CONFOUND
        o["caveats"] = [{"code": c["code"], "text": note_text(c["code"]), "by": c["by"]}
                        for c in r.get("caveats", [])]
        out_rows.append(o)
    ov = dict(overall)
    ov["main_alternative_text"] = note_text(ov["main_alternative"])
    tested = sum(1 for r in rows if r["status"] == "tested")
    return {
        "status": "ready",
        "appraised_by": appraised_by,
        "checked_by": "code",
        "generated_at": now.isoformat(),
        "design": {"type": DESIGN_TYPE, "days": ds["n_days"], "sessions": ds["n_sessions"],
                   "first_day": ds["start"].isoformat(), "last_day": ds["end"].isoformat(),
                   "rows_tested": tested, "min_n": T.assoc_min_n,
                   "unit": ds.get("unit", "day"), "observations": ds.get("n_obs"),
                   "low_below_ratings": T.assoc_low_ratings},
        "reference": {"key": ref["key"], "label": ref_info["label"], "kind": ref["kind"],
                      "worse_is": ref_info["worse_is"], "ratings": ref["n_ratings"]},
        "rows": out_rows,
        "overall": ov,
        "data_notes": [{"code": c, "text": note_text(c)} for c in ds["notes"]],
        "corrections": corrections,
        "hypotheses_reviewed_by_clinician": bool(h.get("reviewed_by_clinician")),
        "disclaimer": DISCLAIMER,
        # For the clinician's charts only: day by day, what was measured. Never sent to a model.
        "series": {
            "first_day": ds["start"].isoformat(), "last_day": ds["end"].isoformat(),
            "reference": [[(d - ds["start"]).days, round(v, 2)] for d, v in ds.get("ref_points", [])],
            "measures": {r["key"]: [[(d - ds["start"]).days, round(v, 3)]
                                    for d, v in sorted(ds["measures"].get(r["key"], {}).items())]
                         for r in rows if r["status"] == "tested"}},
        "inputs": {"reference": ref["key"], "n_days": ds["n_days"],
                   "n_sessions": ds["n_sessions"], "generated_at": now.isoformat(),
                   "model": model_name},
    }
