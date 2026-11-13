"""The person's own normal: robust median and MAD over trailing days.

Every deviation downstream is a robust z-score against this person's own
days, never against a population norm.
"""

from __future__ import annotations

from datetime import date, timedelta
from statistics import median

from .thresholds import METRICS, MIN_SCALE, MOVEMENT_METRICS, T, Thresholds


def robust_stats(values: list[float], metric: str, th: Thresholds = T) -> tuple[float, float]:
    """Return (median, scale). Scale is MAD in sigma units, with a floor."""
    med = median(values)
    mad = median(abs(v - med) for v in values)
    floor = max(MIN_SCALE.get(metric, 0.0), abs(med) * 0.05)
    return med, max(mad * th.mad_to_sigma, floor)


def baseline_for(days: dict[str, dict], ref: date, th: Thresholds = T) -> dict[str, dict]:
    """Baseline per metric as seen on day `ref`.

    Uses days in [ref - exclude - window, ref - exclude). Metrics with fewer
    than `baseline_min_days` values are left out.
    """
    end = ref - timedelta(days=th.baseline_exclude_recent)
    start = end - timedelta(days=th.baseline_window_days)
    out: dict[str, dict] = {}
    for m in METRICS:
        vals = []
        for ds, rec in days.items():
            d = date.fromisoformat(ds)
            if start <= d < end and rec.get(m) is not None:
                vals.append(float(rec[m]))
        if len(vals) >= th.baseline_min_days:
            med, scale = robust_stats(vals, m, th)
            out[m] = {"median": med, "scale": scale, "n": len(vals)}
    return out


def zscores(rec: dict, base: dict[str, dict]) -> dict[str, float]:
    out = {}
    for m, b in base.items():
        v = rec.get(m)
        if v is not None:
            out[m] = (float(v) - b["median"]) / b["scale"]
    return out


def movement_z(z: dict[str, float]) -> float | None:
    vals = [z[m] for m in MOVEMENT_METRICS if m in z]
    return sum(vals) / len(vals) if vals else None


def has_baseline(base: dict[str, dict]) -> bool:
    return "steps" in base


def series_against(days: dict[str, dict], base: dict[str, dict]) -> list[dict]:
    """Every day against ONE baseline (the person's current normal). Used to
    measure outcomes: a change between days needs a common yardstick, and
    early days have no baseline of their own yet."""
    out = []
    for ds in sorted(days):
        z = zscores(days[ds], base)
        mz = movement_z(z)
        out.append({"date": ds, "z": {k: round(v, 2) for k, v in z.items()},
                    "movement_z": round(mz, 2) if mz is not None else None,
                    "example": bool(days[ds].get("example"))})
    return out


def daily_series(days: dict[str, dict], th: Thresholds = T,
                 since: date | None = None) -> list[dict]:
    """For each day with data: z-scores against the baseline as seen that day."""
    out = []
    for ds in sorted(days):
        d = date.fromisoformat(ds)
        if since and d < since:
            continue
        base = baseline_for(days, d, th)
        if not has_baseline(base):
            out.append({"date": ds, "z": {}, "movement_z": None,
                        "example": bool(days[ds].get("example"))})
            continue
        z = zscores(days[ds], base)
        out.append({"date": ds, "z": {k: round(v, 2) for k, v in z.items()},
                    "movement_z": round(movement_z(z), 2) if movement_z(z) is not None else None,
                    "example": bool(days[ds].get("example"))})
    return out
