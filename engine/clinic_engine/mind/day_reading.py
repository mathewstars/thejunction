"""The day reading: the level-2 model reads the person's daily numbers from
Apple Health (steps, walking speed, sleep, HRV and a few more when a watch
sends them) over the last weeks, and code checks every item it reports.

The same idea as the frame reading (frame_reading.py), on days instead of
frames. Code already compares each day with the person's own normal (baseline.py,
watchers.py) with a fixed rule; nothing here changes that. The model reads the
whole series and names stretches that changed, including a slow decline that
never crosses the fixed rule on a single day, and the person's weekly rhythm.
Code then tests each item against the same numbers.

The parts that are pure code:

- reduce(): the stream the model receives (data/days_prompt.txt describes it):
  one row per calendar day with a day index and the weekday, a few named
  channels, rounded. No dates, ids, names or text.
- code_view(): code's own stretches (runs of days clearly outside the trailing
  normal) and the weekly rhythm, from the same rows.
- verify(): every item the model returned, compared with code_view().
- aggregate(): not needed here; one reading covers the whole window.

Clinician-only. Nothing here reaches the patient, changes what is offered or
feeds the learning review. One thing follows from it: when the model finds
something the fixed rules did not flag and code confirms it, the mind opens a
low-level flag for the clinic (watchers.watch_model_noticed).
"""

from __future__ import annotations

import math
from datetime import date, timedelta
from functools import lru_cache
from pathlib import Path
from statistics import median

from .thresholds import T, Thresholds

DATA_DIR = Path(__file__).resolve().parent.parent / "data"

# name in the stream -> (where the value comes from, decimals, lowest, highest)
# "day:<field>" is a field of the day record; "health:<type>" a stored HealthKit type.
CHANNELS = {
    "steps": ("day:steps", -1, 0, 100_000),
    "walk_speed": ("day:walking_speed_m_s", 2, 0, 5),
    "sleep_h": ("day:sleep_h", 1, 0, 24),
    "hrv": ("day:hrv_ms", 0, 0, 400),
    "rest_hr": ("health:HKQuantityTypeIdentifierRestingHeartRate", 0, 20, 220),
    "active_kcal": ("health:HKQuantityTypeIdentifierActiveEnergyBurned", -1, 0, 20_000),
    "exercise_min": ("health:HKQuantityTypeIdentifierAppleExerciseTime", 0, 0, 1440),
    "daylight_min": ("health:HKQuantityTypeIdentifierTimeInDaylight", 0, 0, 1440),
}
ORDER = ("d", "wd") + tuple(CHANNELS)
PAYLOAD_KEYS = ("days", "channels", "rows")
# Floors for the spread of a channel, so a very regular person does not turn
# every small change into a large one.
MIN_SCALE = {"steps": 400.0, "walk_speed": 0.03, "sleep_h": 0.3, "hrv": 3.0, "rest_hr": 1.5,
             "active_kcal": 40.0, "exercise_min": 5.0, "daylight_min": 10.0}

DIRECTIONS = ("lower", "higher")
SHAPES = ("sustained", "gradual")
LEVELS = ("lower", "as_usual", "higher", "unclear")
CONFIDENCE = ("low", "medium", "high")
MAX_STRETCHES = 12
MAX_WEEKLY = 4
MAX_GAPS = 8


@lru_cache(maxsize=1)
def prompt_text() -> str:
    return (DATA_DIR / "days_prompt.txt").read_text("utf-8")


def _obj(props: dict) -> dict:
    return {"type": "OBJECT", "properties": props, "required": list(props),
            "propertyOrdering": list(props)}


def _enum(words) -> dict:
    return {"type": "STRING", "enum": list(words)}


RESPONSE_SCHEMA = _obj({
    "stretches": {"type": "ARRAY", "maxItems": MAX_STRETCHES, "items": _obj({
        "start_d": {"type": "INTEGER"}, "end_d": {"type": "INTEGER"},
        "channel": _enum(CHANNELS), "direction": _enum(DIRECTIONS), "shape": _enum(SHAPES)})},
    "weekly": {"type": "ARRAY", "maxItems": MAX_WEEKLY, "items": _obj({
        "channel": _enum(CHANNELS),
        "low_weekdays": {"type": "ARRAY", "maxItems": 3, "items": {"type": "INTEGER"}}})},
    "gaps": {"type": "ARRAY", "maxItems": MAX_GAPS, "items": _obj({
        "start_d": {"type": "INTEGER"}, "end_d": {"type": "INTEGER"}})},
    "overall": _obj({"movement": _enum(LEVELS), "sleep": _enum(LEVELS),
                     "confidence": _enum(CONFIDENCE)}),
})


# ---- the reduced stream ------------------------------------------------------------------

def _round(v: float, nd: int):
    if nd < 0:
        return int(round(v, nd))
    return int(round(v)) if nd == 0 else round(v, nd)


def reduce(days: dict[str, dict], health: dict[str, dict], th: Thresholds = T) -> dict | None:
    """The JSON object the model receives, or None when there are too few days.
    `days`: accepted day records by ISO date; `health`: stored HealthKit types
    by identifier ({"days": {iso: value}}). The window ends at the last day
    with steps and holds every calendar day back to dayr_max_days."""
    have = sorted(d for d, r in days.items() if r.get("steps") is not None)
    if len(have) < th.dayr_min_days:
        return None
    last = date.fromisoformat(have[-1])
    first = max(date.fromisoformat(have[0]), last - timedelta(days=th.dayr_max_days - 1))
    n = (last - first).days + 1

    def value(name: str, iso: str):
        src, nd, lo, hi = CHANNELS[name]
        kind, key = src.split(":", 1)
        v = (days.get(iso) or {}).get(key) if kind == "day" else \
            ((health.get(key) or {}).get("days") or {}).get(iso)
        if v is None or not isinstance(v, (int, float)) or not math.isfinite(v) or not lo <= v <= hi:
            return None
        return _round(float(v), nd)

    isos = [(first + timedelta(days=k)).isoformat() for k in range(n)]
    cols = {c: [value(c, iso) for iso in isos] for c in CHANNELS}
    names = [c for c in CHANNELS
             if sum(1 for v in cols[c] if v is not None) >= th.dayr_min_channel_days]
    rows = [[k, date.fromisoformat(iso).isoweekday()] + [cols[c][k] for c in names]
            for k, iso in enumerate(isos)]
    return {"days": n, "channels": ["d", "wd"] + names, "rows": rows}


def first_date(days: dict[str, dict], payload: dict) -> str:
    """The calendar date of row 0 (for the clinician's chart; never sent)."""
    have = sorted(d for d, r in days.items() if r.get("steps") is not None)
    return (date.fromisoformat(have[-1]) - timedelta(days=payload["days"] - 1)).isoformat()


# ---- code's own view ---------------------------------------------------------------------

def _scale(vals: list[float], channel: str, th: Thresholds) -> tuple[float, float]:
    med = median(vals)
    mad = median(abs(v - med) for v in vals)
    return med, max(mad * th.mad_to_sigma, MIN_SCALE[channel], abs(med) * 0.05)


def _series(payload: dict, channel: str) -> list[float | None]:
    k = payload["channels"].index(channel)
    return [row[k] for row in payload["rows"]]


def _trailing_z(x: list[float | None], channel: str, th: Thresholds) -> list[float | None]:
    """Each day against the person's own normal as seen that day: the days in
    the window before it, the most recent few left out (as baseline.py does)."""
    out: list[float | None] = []
    for i, v in enumerate(x):
        lo, hi = i - th.baseline_exclude_recent - th.baseline_window_days, i - th.baseline_exclude_recent
        base = [u for u in x[max(0, lo):max(0, hi)] if u is not None]
        if v is None or len(base) < th.dayr_min_before:
            out.append(None)
            continue
        med, sc = _scale(base, channel, th)
        out.append((v - med) / sc)
    return out


def _runs(z: list[float | None], sign: int, th: Thresholds) -> list[tuple[int, int]]:
    """Runs of days at least dayr_code_z outside normal in one direction, at
    least dayr_min_len days with data; a day without data does not end a run,
    two in a row do."""
    out, start, last, miss = [], None, None, 0
    for i, v in enumerate(z + [0.0, 0.0, 0.0]):
        hit = v is not None and v * sign >= th.dayr_code_z
        if hit:
            start = i if start is None else start
            last, miss = i, 0
            continue
        if start is None:
            continue
        miss = miss + 1 if v is None else 99
        if miss >= 2:
            n = sum(1 for j in range(start, last + 1) if z[j] is not None)
            if n >= th.dayr_min_len:
                out.append((start, last))
            start = None
    return out


def _weekly_low(x: list[float | None], wd: list[int], channel: str, th: Thresholds) -> list[int]:
    vals = [v for v in x if v is not None]
    if len(vals) < th.dayr_min_days:
        return []
    low = []
    for day in range(1, 8):
        mine = [v for v, w in zip(x, wd) if v is not None and w == day]
        rest = [v for v, w in zip(x, wd) if v is not None and w != day]
        if len(mine) < th.dayr_weekday_min_n or len(rest) < th.dayr_min_before:
            continue
        med, sc = _scale(rest, channel, th)
        # Low week after week, not once or twice: most of that weekday's values
        # lie under the usual level of the other days.
        under = sum(1 for v in mine if v < med) / len(mine)
        if (median(mine) - med) / sc <= -th.dayr_weekday_z and under >= th.dayr_weekday_share:
            low.append(day)
    return low


def _level(z: list[float | None], th: Thresholds) -> str:
    recent = [v for v in z[-7:] if v is not None]
    if len(recent) < 3:
        return "unclear"
    m = median(recent)
    return "lower" if m <= -th.dayr_overall_z else "higher" if m >= th.dayr_overall_z else "as_usual"


def code_view(payload: dict, th: Thresholds = T) -> dict:
    names = payload["channels"][2:]
    wd = [row[1] for row in payload["rows"]]
    series = {c: _series(payload, c) for c in names}
    z = {c: _trailing_z(series[c], c, th) for c in names}
    stretches = [{"start_d": a, "end_d": b, "channel": c, "direction": d}
                 for c in names for d, sign in (("lower", -1), ("higher", 1))
                 for a, b in _runs(z[c], sign, th)]
    weekly = {c: _weekly_low(series[c], wd, c, th) for c in names}
    gaps, start = [], None
    steps = series.get("steps") or []
    for i, v in enumerate(steps + [0]):
        if v is None:
            start = i if start is None else start
        elif start is not None:
            if i - start >= th.dayr_gap_min:
                gaps.append({"start_d": start, "end_d": i - 1})
            start = None
    overall = {"movement": _level(z["steps"], th) if "steps" in z else "unclear",
               "sleep": _level(z["sleep_h"], th) if "sleep_h" in z else "unclear"}
    return {"names": names, "wd": wd, "series": series, "z": z, "stretches": stretches,
            "weekly": weekly, "gaps": gaps, "overall": overall}


# ---- verify --------------------------------------------------------------------------------

def _spearman(xs: list[float], ys: list[float]) -> float:
    def ranks(v):
        order = sorted(range(len(v)), key=lambda i: v[i])
        r = [0.0] * len(v)
        i = 0
        while i < len(order):
            j = i
            while j + 1 < len(order) and v[order[j + 1]] == v[order[i]]:
                j += 1
            for k in range(i, j + 1):
                r[order[k]] = (i + j) / 2
            i = j + 1
        return r
    rx, ry = ranks(xs), ranks(ys)
    mx, my = sum(rx) / len(rx), sum(ry) / len(ry)
    sx = math.sqrt(sum((a - mx) ** 2 for a in rx))
    sy = math.sqrt(sum((b - my) ** 2 for b in ry))
    return sum((a - mx) * (b - my) for a, b in zip(rx, ry)) / (sx * sy) if sx and sy else 0.0


def check_stretch(view: dict, st: dict, th: Thresholds = T) -> tuple[dict | None, str | None]:
    """Is the reported change in the numbers? Returns (measured, None) or
    (None, reason). The span is compared with the days before it (up to the
    baseline window; all other days when too few came before).

    sustained: the span's median lies at least dayr_stretch_z spreads from the
    median before, in the reported direction.
    gradual: within the span the values fall (or rise) day by day (Spearman of
    value against day at least dayr_gradual_rho) and its last third lies at
    least dayr_stretch_z spreads from its first third."""
    c = st["channel"]
    if c not in view["series"]:
        return None, "channel_missing"
    x = view["series"][c]
    a, b = st["start_d"], st["end_d"]
    idx = [i for i in range(a, b + 1) if x[i] is not None]
    need = th.dayr_gradual_min_len if st["shape"] == "gradual" else th.dayr_min_len
    if len(idx) < need:
        return None, "too_short"
    before = [v for v in x[max(0, a - th.baseline_window_days):a] if v is not None]
    if len(before) < th.dayr_min_before:
        before = [v for i, v in enumerate(x) if v is not None and not a <= i <= b]
    if len(before) < th.dayr_min_before:
        return None, "too_little_before"
    med, sc = _scale(before, c, th)
    sign = -1 if st["direction"] == "lower" else 1
    vals = [x[i] for i in idx]
    if st["shape"] == "sustained":
        zmed = (median(vals) - med) / sc
        if zmed * sign < th.dayr_stretch_z:
            return None, "not_in_numbers"
        return {"z": round(zmed, 1), "days": len(idx)}, None
    third = max(2, len(vals) // 3)
    drop = (median(vals[-third:]) - median(vals[:third])) / sc
    rho = _spearman([float(i) for i in idx], [float(v) for v in vals])
    if rho * sign < th.dayr_gradual_rho or drop * sign < th.dayr_stretch_z:
        return None, "not_in_numbers"
    return {"z": round(drop, 1), "rho": round(rho, 2), "days": len(idx)}, None


def verify(reply: dict, payload: dict, th: Thresholds = T) -> dict:
    """Check every item of a reply that already has the right shape."""
    view = code_view(payload, th)
    dropped: list[dict] = []

    used: set[int] = set()
    kept = []
    for st in reply["stretches"]:
        item = {k: st[k] for k in ("start_d", "end_d", "channel", "direction", "shape")}
        measured, reason = check_stretch(view, st, th)
        if measured is None:
            dropped.append({"item": "stretch", **item, "reason": reason})
            continue
        if any(k["channel"] == st["channel"] and k["direction"] == st["direction"] and
               min(k["end_d"], st["end_d"]) >= max(k["start_d"], st["start_d"]) for k in kept):
            dropped.append({"item": "stretch", **item, "reason": "same_stretch_twice"})
            continue
        # The same stretch as one of code's: same channel and direction, the two
        # spans overlap by at least dayr_iou of their union.
        best = None
        for j, cs in enumerate(view["stretches"]):
            if j in used or cs["channel"] != st["channel"] or cs["direction"] != st["direction"]:
                continue
            inter = min(cs["end_d"], st["end_d"]) - max(cs["start_d"], st["start_d"]) + 1
            if inter <= 0:
                continue
            iou = inter / (max(cs["end_d"], st["end_d"]) - min(cs["start_d"], st["start_d"]) + 1)
            if iou >= th.dayr_iou and (best is None or iou > best[1]):
                best = (j, iou)
        if best is not None:
            used.add(best[0])
            cs = view["stretches"][best[0]]
            kept.append({**item, **measured, "status": "same", "code_start_d": cs["start_d"],
                         "code_end_d": cs["end_d"]})
        else:
            # The fixed rule did not flag it (too mild on any single day, or a
            # slow decline), but the change is in the numbers.
            kept.append({**item, **measured, "status": "model_only"})
    missed = [cs for j, cs in enumerate(view["stretches"]) if j not in used]

    weekly_out = []
    claimed: dict[str, set[int]] = {}
    for w in reply["weekly"]:
        c = w["channel"]
        if c not in view["weekly"]:
            dropped.append({"item": "weekly", "channel": c, "reason": "channel_missing"})
            continue
        code_low = set(view["weekly"][c])
        days = sorted(set(w["low_weekdays"]))
        claimed.setdefault(c, set()).update(days)
        weekly_out.append({"channel": c, "low_weekdays": [d for d in days if d in code_low],
                           "not_confirmed": [d for d in days if d not in code_low]})
    weekly_missed = {c: [d for d in low if d not in claimed.get(c, set())]
                     for c, low in view["weekly"].items() if low}
    weekly_missed = {c: v for c, v in weekly_missed.items() if v}

    gaps_out = []
    steps = view["series"].get("steps") or []
    for g in reply["gaps"]:
        a, b = g["start_d"], g["end_d"]
        if b - a + 1 >= th.dayr_gap_min and all(steps[i] is None for i in range(a, b + 1)):
            gaps_out.append({"start_d": a, "end_d": b, "status": "confirmed"})
        else:
            dropped.append({"item": "gap", "start_d": a, "end_d": b, "reason": "days_have_data"})

    checks = {k: {"model": reply["overall"][k], "code": view["overall"][k],
                  "status": "same" if reply["overall"][k] == view["overall"][k] else "different"}
              for k in ("movement", "sleep")}
    same = sum(1 for k in kept if k["status"] == "same")
    only = len(kept) - same
    at_code_level = len(reply["stretches"]) - only
    wc = sum(len(w["low_weekdays"]) for w in weekly_out)
    agreement = {
        "stretches_reported": len(reply["stretches"]),
        "stretches_same": same,
        "stretches_model_only": only,
        "stretches_gradual": sum(1 for k in kept if k["shape"] == "gradual"),
        "stretches_dropped": sum(1 for d in dropped if d["item"] == "stretch"),
        "stretches_not_in_numbers": sum(1 for d in dropped if d["item"] == "stretch"
                                        and d["reason"] == "not_in_numbers"),
        "stretches_missed": len(missed),
        "stretches_code": len(view["stretches"]),
        "stretch_precision": round(same / at_code_level, 2) if at_code_level else None,
        "stretch_recall": round(same / len(view["stretches"]), 2) if view["stretches"] else None,
        "weekdays_confirmed": wc,
        "weekdays_not_confirmed": sum(len(w["not_confirmed"]) for w in weekly_out),
        "weekdays_missed": sum(len(v) for v in weekly_missed.values()),
        "gaps_confirmed": len(gaps_out),
        "overall_same": sum(1 for c in checks.values() if c["status"] == "same"),
    }
    reading = {"stretches": kept, "missed_stretches": missed, "weekly": weekly_out,
               "weekly_missed": weekly_missed, "gaps": gaps_out,
               "overall": {**view["overall"], "confidence": reply["overall"]["confidence"]},
               "overall_checks": checks}
    return {"reading": reading, "agreement": agreement, "dropped": dropped}


def range_problem(reply: dict, payload: dict) -> str | None:
    """A reason code when a day index lies outside the window, a span is turned
    round, or a weekday is not 1 to 7; None when everything is usable."""
    n = payload["days"]
    for sp in reply["stretches"] + reply["gaps"]:
        if not (0 <= sp["start_d"] < n and 0 <= sp["end_d"] < n):
            return "day_outside_window"
        if sp["end_d"] < sp["start_d"]:
            return "end_before_start"
    for w in reply["weekly"]:
        if any(not 1 <= d <= 7 for d in w["low_weekdays"]):
            return "weekday_not_1_to_7"
    return None
