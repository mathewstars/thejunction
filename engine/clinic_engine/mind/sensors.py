"""The `sensors` block of an activity record (docs/sensors.md): the Apple Watch's
heart-rate and HRV samples during the game, every game moment, and the clock
anchor that lines them up with the raw face frames.

All code, no model:
  1. check      values that cannot be true reject the record (check_sensors)
  2. summary    heart rate over the session and around the game moments, the
                HRV samples as they are, the alignment facts (summarize)

The raw block is stored as its own object (sensors/{activity_id}.json), outside
the activity record and outside every pack. The record keeps only the summary.
Nothing here opens attention or changes what is offered: the summary is for the
clinician's page and for the sensor reading (sensor_reading.py).
"""

from __future__ import annotations

from statistics import mean, median

# The game moments the phone may name (ios/Lanvi/Screens/Games/GameMoments.swift).
MOMENT_NAMES = ("focus_started", "spark_caught", "snow_tapped", "spark_missed", "focus_ended",
                "breathe_started", "breath_in", "breath_hold", "breath_out", "breathe_ended",
                "checkin_started", "checkin_step", "checkin_ended")
MOMENTS_BY_TYPE = {
    "focus": {"focus_started", "spark_caught", "snow_tapped", "spark_missed", "focus_ended"},
    "breathing": {"breathe_started", "breath_in", "breath_hold", "breath_out", "breathe_ended"},
    "checkin": {"checkin_started", "checkin_step", "checkin_ended"},
}
START_MOMENTS = ("focus_started", "breathe_started", "checkin_started")
END_MOMENTS = ("focus_ended", "breathe_ended", "checkin_ended")
CHECKIN_STEPS = ("plan_question", "good_things", "plan", "goodnight")

HR_MIN, HR_MAX = 25.0, 250.0
HRV_MIN, HRV_MAX = 0.0, 500.0
# A sample may sit this long before started_at (the watch began while the phone
# waited) or after the activity ended (the last flush).
BEFORE_S, AFTER_S = 600.0, 60.0
# Heart rate in the window after a moment, compared with the session mean.
MOMENT_WINDOW_S = 5.0
EDGE_S = 15.0        # first and last stretch compared for the change
TREND_BPM = 3.0      # a change at least this big is a trend
MAX_DRIFT_MS = 2000  # wall clock against monotonic clock, per moment


def check_sensors(sensors: dict, rec: dict) -> str | None:
    """Reason code when the block cannot be true, else None. The shape itself is
    the model's job (SensorsIn); this checks the numbers against the activity."""
    dur = float(rec["duration_s"])
    lo, hi = -BEFORE_S * 1000, (dur + AFTER_S) * 1000
    for key, vmin, vmax in (("heart_rate", HR_MIN, HR_MAX), ("hrv_sdnn", HRV_MIN, HRV_MAX)):
        rows = sensors.get(key) or []
        last_t = None
        for row in rows:
            t, v = row
            if not lo <= t <= hi:
                return f"{key}_outside_activity"
            if not vmin <= v <= vmax:
                return f"{key}_implausible"
            if last_t is not None and t < last_t:
                return f"{key}_not_in_order"
            last_t = t
    for m in sensors.get("moments") or []:
        if m["name"] not in MOMENT_NAMES:
            return "unknown_moment"
        if m["name"] not in MOMENTS_BY_TYPE.get(rec["type"], set()):
            return "moment_from_another_activity"
        if not lo <= m["t_ms"] <= hi:
            return "moment_outside_activity"
        if abs(m["t_ms"] - m["wall_ms"]) > MAX_DRIFT_MS:
            return "moment_clocks_disagree"
        if m["name"] == "checkin_step" and m.get("step") not in CHECKIN_STEPS:
            return "unknown_checkin_step"
    off = sensors.get("face_offset_ms")
    if off is not None and rec.get("face_raw") is None:
        return "face_offset_without_frames"
    return None


# ---- summary -----------------------------------------------------------------------------

def _r(x, nd=1):
    return None if x is None else round(float(x), nd)


def _window_mean(hr: list[list[float]], start_ms: float, end_ms: float) -> float | None:
    vals = [v for t, v in hr if start_ms <= t < end_ms]
    return mean(vals) if vals else None


def _trend(first: float | None, last: float | None) -> str:
    if first is None or last is None:
        return "unclear"
    d = last - first
    return "rising" if d >= TREND_BPM else "falling" if d <= -TREND_BPM else "steady"


def _slope_bpm_per_min(hr: list[list[float]]) -> float | None:
    """Least squares over the samples, in bpm per minute. None under 4 samples or 10 s."""
    if len(hr) < 4:
        return None
    ts = [t / 60000.0 for t, _ in hr]
    vs = [v for _, v in hr]
    span = max(ts) - min(ts)
    if span * 60 < 10:
        return None
    mt, mv = mean(ts), mean(vs)
    den = sum((t - mt) ** 2 for t in ts)
    if den == 0:
        return None
    return sum((t - mt) * (v - mv) for t, v in zip(ts, vs)) / den


def heart_rate_summary(hr: list[list[float]], duration_s: float) -> dict | None:
    if not hr:
        return None
    # Only samples inside the activity count for the session numbers; the ones from
    # the wait before Start are kept apart as the resting stretch.
    inside = [[t, v] for t, v in hr if 0 <= t <= duration_s * 1000]
    before = [v for t, v in hr if t < 0]
    vals = [v for _, v in inside]
    out = {"samples": len(hr), "samples_in_activity": len(inside),
           "before_start_bpm": _r(mean(before)) if before else None}
    if not vals:
        return out
    first = _window_mean(inside, 0, EDGE_S * 1000)
    last = _window_mean(inside, max(0, duration_s - EDGE_S) * 1000, duration_s * 1000 + 1)
    peak = max(inside, key=lambda r: r[1])
    low = min(inside, key=lambda r: r[1])
    span_s = (inside[-1][0] - inside[0][0]) / 1000 if len(inside) > 1 else 0.0
    out.update(mean_bpm=_r(mean(vals)), median_bpm=_r(median(vals)),
               min_bpm=_r(low[1]), min_at_s=_r(low[0] / 1000),
               max_bpm=_r(peak[1]), max_at_s=_r(peak[0] / 1000),
               first_bpm=_r(first), last_bpm=_r(last),
               change_bpm=_r(last - first) if first is not None and last is not None else None,
               trend=_trend(first, last),
               slope_bpm_per_min=_r(_slope_bpm_per_min(inside), 2),
               coverage_s=_r(span_s),
               mean_gap_s=_r(span_s / (len(inside) - 1), 2) if len(inside) > 1 else None)
    return out


def moments_summary(moments: list[dict], hr: list[list[float]], session_mean: float | None) -> dict:
    by_name: dict[str, int] = {}
    for m in moments:
        by_name[m["name"]] = by_name.get(m["name"], 0) + 1
    out: dict = {"count": len(moments), "by_name": by_name,
                 "first_s": _r(min(m["t_ms"] for m in moments) / 1000) if moments else None,
                 "last_s": _r(max(m["t_ms"] for m in moments) / 1000) if moments else None,
                 "max_clock_drift_ms": max((abs(m["t_ms"] - m["wall_ms"]) for m in moments), default=0)}
    # Heart rate in the seconds after each kind of moment, against the session mean.
    around: dict = {}
    if hr and session_mean is not None:
        for name in ("spark_caught", "snow_tapped", "spark_missed", "breath_in", "breath_out",
                     "checkin_step"):
            windows = [_window_mean(hr, m["t_ms"], m["t_ms"] + MOMENT_WINDOW_S * 1000)
                       for m in moments if m["name"] == name]
            windows = [w for w in windows if w is not None]
            if windows:
                around[name] = {"n": len(windows), "mean_bpm": _r(mean(windows)),
                                "vs_session_bpm": _r(mean(windows) - session_mean)}
    out["heart_rate_after"] = around
    return out


def breath_cycles(moments: list[dict], hr: list[list[float]]) -> list[dict]:
    """Breathe with Lanvi: one row per breath, in-breath start to the next in-breath (or
    the end), with the mean heart rate inside it."""
    ins = sorted((m for m in moments if m["name"] == "breath_in"), key=lambda m: m["t_ms"])
    end = next((m["t_ms"] for m in moments if m["name"] == "breathe_ended"), None)
    rows = []
    for i, m in enumerate(ins):
        stop = ins[i + 1]["t_ms"] if i + 1 < len(ins) else end
        if stop is None:
            stop = m["t_ms"] + 11000
        rows.append({"breath": m.get("value") or i + 1, "start_s": _r(m["t_ms"] / 1000),
                     "end_s": _r(stop / 1000), "hr_mean_bpm": _r(_window_mean(hr, m["t_ms"], stop))})
    return rows


def summarize(sensors: dict, rec: dict) -> dict:
    """The stored summary. Built from scratch, numbers and fixed codes only."""
    hr = [[float(t), float(v)] for t, v in sensors.get("heart_rate") or []]
    hrv = [[float(t), float(v)] for t, v in sensors.get("hrv_sdnn") or []]
    moments = sensors.get("moments") or []
    dur = float(rec["duration_s"])
    hrs = heart_rate_summary(hr, dur)
    session_mean = (hrs or {}).get("mean_bpm")
    out: dict = {
        "source": (sensors.get("watch") or {}).get("source"),
        "watch_started_s": _r((sensors.get("watch") or {}).get("started_ms", 0) / 1000)
        if sensors.get("watch") else None,
        "heart_rate": hrs,
        "hrv_sdnn": {"samples": len(hrv),
                     "latest_ms": _r(hrv[-1][1]) if hrv else None,
                     "latest_at_s": _r(hrv[-1][0] / 1000) if hrv else None,
                     "mean_ms": _r(mean(v for _, v in hrv)) if hrv else None},
        "moments": moments_summary(moments, hr, session_mean),
        "alignment": {"started_uptime_s": sensors["clock"]["started_uptime_s"],
                      "face_offset_ms": sensors.get("face_offset_ms"),
                      "moments_on_face_clock": sensors.get("face_offset_ms") is not None},
    }
    if rec["type"] == "breathing":
        out["breaths"] = breath_cycles(moments, hr)
    return out


def describe(sensors: dict) -> dict:
    """Counts only, kept on the record next to the summary."""
    return {"heart_rate_samples": len(sensors.get("heart_rate") or []),
            "hrv_samples": len(sensors.get("hrv_sdnn") or []),
            "moments": len(sensors.get("moments") or []),
            "watch": bool(sensors.get("watch"))}
