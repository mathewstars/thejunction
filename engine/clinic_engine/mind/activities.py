"""What the server makes of one activity record (docs/game-design.md).

All code, no model:
  1. check     values that cannot be true reject the record
  2. features  per type: focus -> median and spread of reaction time,
               error rate, completion; breathing -> completion and time
               played; checkin -> good things, plan made, yesterday's plan done
  3. face      the summary values (sent by the phone, or computed by the server
               from raw frames in face_features.py), used only when tracking quality is good
               enough; a low-quality summary is stored but never enters a
               baseline
  4. own normal per activity type and per feature: robust z against the
               person's earlier sessions (at least activity_baseline_min)
"""

from __future__ import annotations

from datetime import datetime, timedelta
from statistics import median

from .thresholds import ACTIVITY_MIN_SCALE, T, Thresholds

FACE_FIELDS = ("smile_rate_per_min", "smile_intensity", "facial_activity", "blink_rate_per_min",
               "look_down_share", "head_tilt_deg",
               # Optional, newer fields (all numbers). Compared with own normal the
               # same way; the watchers still look only at facial_activity and
               # smile_rate_per_min.
               "smile_time_share", "eye_smile_share", "smile_response_share",
               "smile_response_latency_s", "brow_down_share", "inner_brow_up_share",
               "blink_duration_ms", "head_pitch_deg", "head_movement", "smile_asymmetry")
# Features compared with own normal, per type. Completion is a yes/no per
# session; watchers look at it over several sessions instead of a z.
Z_FEATURES = {
    "focus": ("median_reaction_ms", "reaction_spread_ms", "error_rate"),
    "breathing": ("time_played_s",),
    "checkin": ("good_things",),
}


# ---- 1. check -------------------------------------------------------------------------

def check_activity(a: dict, now: datetime) -> str | None:
    """Reason code when the record cannot be true, else None."""
    started = datetime.fromisoformat(a["started_at"])
    if started > now + timedelta(minutes=10):
        return "future_activity"
    if started < now - timedelta(days=400):
        return "too_old"
    dur = a["duration_s"]
    if not (0 <= dur <= 1800):
        return "implausible_duration"
    t = a["type"]
    if t == "focus":
        taps = a["correct_taps"] + a["wrong_taps"]
        if taps + a["misses"] > 1000:
            return "implausible_taps"
        if len(a["reaction_ms"]) > taps:
            return "more_reactions_than_taps"
        if dur > 0 and taps > dur * 10:
            return "taps_too_fast"
    elif t == "breathing":
        if a["time_played_s"] > dur + 1:
            return "played_longer_than_duration"
        if a.get("breaths_completed") is not None and a["breaths_completed"] > dur / 2 + 2:
            return "implausible_breaths"
    if (a.get("face") is not None or a.get("face_raw") is not None) and t == "checkin":
        return "face_on_checkin"
    raw = a.get("face_raw")
    if raw is not None and len(raw["samples"]) / raw["rate_hz"] > dur * 1.2 + 5:
        return "face_frames_longer_than_activity"
    return None


# ---- 2 and 3. features ---------------------------------------------------------------------

def _iqr(vals: list[float]) -> float | None:
    if len(vals) < 4:
        return None
    s = sorted(vals)
    n = len(s)
    return float(s[(3 * n) // 4] - s[n // 4])


def features(a: dict, th: Thresholds = T) -> dict:
    t = a["type"]
    f: dict = {"completed": bool(a["completed"]), "ended_by": a["ended_by"]}
    if t == "focus":
        rts = [r for r in a["reaction_ms"] if r >= th.reaction_min_ms]
        enough = len(rts) >= th.activity_min_reactions
        total = a["correct_taps"] + a["wrong_taps"] + a["misses"]
        f.update(median_reaction_ms=float(median(rts)) if enough else None,
                 reaction_spread_ms=_iqr(rts) if enough else None,
                 error_rate=round((a["wrong_taps"] + a["misses"]) / total, 3) if total else None,
                 reactions_used=len(rts))
    elif t == "breathing":
        f.update(time_played_s=float(a["time_played_s"]),
                 breaths_completed=a.get("breaths_completed"))
    elif t == "checkin":
        f.update(good_things=len(a.get("good_things") or []),
                 plan_made=a.get("plan") is not None,
                 plan_done=a.get("plan_done", "not_asked"))
    return f


def face_quality(a: dict, th: Thresholds = T) -> str:
    face = a.get("face")
    if not face:
        return "none"
    return "good" if face["tracking_quality"] >= th.face_min_quality else "low"


# ---- 4. own normal ---------------------------------------------------------------------------

def _stats(vals: list[float], name: str, th: Thresholds) -> dict:
    med = median(vals)
    mad = median(abs(v - med) for v in vals)
    return {"median": med, "scale": max(mad * th.mad_to_sigma, ACTIVITY_MIN_SCALE.get(name, 0.01)),
            "n": len(vals)}


def baseline(previous: list[dict], typ: str, th: Thresholds = T) -> dict:
    """Own normal per feature over earlier sessions of the same type.
    Face features use only earlier sessions whose face quality was good."""
    same = [p for p in previous if p["type"] == typ][-th.activity_baseline_max:]
    out: dict = {}
    for name in Z_FEATURES.get(typ, ()):
        vals = [p["features"][name] for p in same if p["features"].get(name) is not None]
        if len(vals) >= th.activity_baseline_min:
            out[name] = _stats(vals, name, th)
    good_face = [p for p in same if p.get("face_quality") == "good"]
    for name in FACE_FIELDS:
        vals = [p["face"][name] for p in good_face if p["face"].get(name) is not None]
        if len(vals) >= th.activity_baseline_min:
            out["face." + name] = _stats(vals, name, th)
    return out


def _z(v, b: dict | None) -> float | None:
    if v is None or b is None:
        return None
    return round((v - b["median"]) / b["scale"], 2)


def process_activity(a: dict, previous: list[dict], th: Thresholds = T) -> dict:
    """The stored form: input + features, face quality, z against own normal."""
    f = features(a, th)
    fq = face_quality(a, th)
    base = baseline(previous, a["type"], th)
    z = {name: _z(f.get(name), base.get(name)) for name in Z_FEATURES.get(a["type"], ())}
    face_z = {}
    if fq == "good":
        face_z = {name: _z(a["face"].get(name), base.get("face." + name)) for name in FACE_FIELDS}
    usual = {k: {"median": round(v["median"], 3), "scale": round(v["scale"], 3), "n": v["n"]}
             for k, v in base.items()}
    return {**a, "features": f, "face_quality": fq, "z": z, "face_z": face_z, "usual": usual,
            "baseline_sessions": sum(1 for p in previous if p["type"] == a["type"])}
