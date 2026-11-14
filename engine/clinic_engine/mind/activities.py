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
               "blink_duration_ms", "head_pitch_deg", "head_movement", "smile_asymmetry",
               "lip_down_share", "lip_press_share")
# Features compared with own normal, per type. Completion is a yes/no per
# session; watchers look at it over several sessions instead of a z.
Z_FEATURES = {
    "focus": ("median_reaction_ms", "reaction_spread_ms", "error_rate"),
    "breathing": ("time_played_s",),
    "checkin": ("good_things",),
}
# Revontulet's own measures, compared with the person's earlier Revontulet
# games only (never with Sparks and snow). Kept apart from Z_FEATURES on
# purpose: nothing here reaches the watchers or changes how a day is judged.
REVONTULET_FEATURES = ("hard_share", "choice_ms", "trace_speed_cm_s", "stroke_speed_cm_s")


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
        rv = a.get("revontulet")
        if rv is not None and rv.get("broke_through_s") is not None \
                and rv["broke_through_s"] > dur + 1:
            return "broke_through_after_end"
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


def revontulet_features(a: dict) -> dict | None:
    """Four numbers from a game's `revontulet` object, or None without one:
    the share of rounds where the harder crack was picked (only for a game with
    all three rounds: one or two choices are too few to compare), the median
    time to choose, and the mean tracing and stroking speeds in cm per second
    (None when the phone did not send its points per centimetre)."""
    rv = a.get("revontulet")
    if not rv:
        return None
    rounds, strokes, per_cm = rv.get("rounds") or [], rv.get("strokes") or [], rv.get("pt_per_cm")

    def speed(items: list[dict], key: str) -> float | None:
        vals = [i[key] for i in items if i.get(key) is not None]
        return round(sum(vals) / len(vals) / per_cm, 3) if vals and per_cm else None

    choose = [r["choice_ms"] for r in rounds if r.get("choice_ms") is not None]
    return {"hard_share": round(sum(r.get("effort") == "hard" for r in rounds) / len(rounds), 3)
            if len(rounds) >= 3 else None,
            "choice_ms": float(median(choose)) if choose else None,
            "trace_speed_cm_s": speed(rounds, "trace_mean_speed_pt_s"),
            # one stroke is too little to compare: the stroke speed needs two
            "stroke_speed_cm_s": speed(strokes, "mean_speed_pt_s") if len(strokes) >= 2 else None,
            "pt_per_cm": per_cm}


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
    out = {**a, "features": f, "face_quality": fq, "z": z, "face_z": face_z, "usual": usual,
           "baseline_sessions": sum(1 for p in previous if p["type"] == a["type"])}
    rvf = revontulet_features(a)
    if rvf is not None:
        # Own normal over the earlier Revontulet games only. A record without
        # the object gets none of these keys and is stored as it always was.
        # Only games on the same phone: the half circle is laid out in screen
        # points, so a new phone (a different points-per-centimetre) changes the
        # speeds, and both references start again there.
        per_cm = rvf.get("pt_per_cm")
        every = [p["revontulet_features"] for p in previous if p.get("revontulet_features")
                 and (per_cm is None or p["revontulet_features"].get("pt_per_cm") is None
                      or abs(p["revontulet_features"]["pt_per_cm"] - per_cm) <= 0.5)]
        earlier = every[-th.activity_baseline_max:]
        # Two references. The moving one: the games just before this one. The
        # fixed one: the person's start, which a slow slide cannot drag along.
        start = (every[th.revontulet_start_from:th.revontulet_start_to]
                 if len(every) >= th.revontulet_start_to else [])
        rv_usual, rv_z, rv_start, rv_start_z = {}, {}, {}, {}
        for name in REVONTULET_FEATURES:
            for games, usual, zs in ((earlier, rv_usual, rv_z), (start, rv_start, rv_start_z)):
                vals = [e[name] for e in games if e.get(name) is not None]
                b = _stats(vals, name, th) if len(vals) >= th.revontulet_baseline_min else None
                zs[name] = _z(rvf.get(name), b)
                if b:
                    usual[name] = {"median": round(b["median"], 3), "scale": round(b["scale"], 3),
                                   "n": b["n"]}
        out.update(revontulet_features=rvf, revontulet_z=rv_z, revontulet_usual=rv_usual,
                   revontulet_start=rv_start, revontulet_start_z=rv_start_z,
                   revontulet_baseline_sessions=len(earlier))
    return out
