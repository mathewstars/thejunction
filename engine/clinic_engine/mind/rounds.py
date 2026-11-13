"""What the server makes of one AR round (docs/game-interface.md, sections 4 and 5).

All code, no model:
  1. check     values that cannot be true are rejected; weak tracking,
               a tiny play area or an interrupted round is kept but marked
               low quality and never enters a baseline
  2. features  per light and per round
  3. own normal per mode, robust z against the person's earlier good rounds
               (at least 5)
  4. energy    one summary bucket: low | usual | high
and round_config: which config the next round uses.
"""

from __future__ import annotations

import hashlib
import math
from datetime import datetime, timedelta
from statistics import median

from .catalog import WEEKDAYS, context_for_hour
from .round_configs import DEFAULT_CONFIG, LADDER, ROUND_CONFIGS
from .thresholds import ROUND_MIN_SCALE, T, Thresholds

FEATURES = ("caught_share", "median_reaction_s", "median_speed_m_s", "coverage",
            "still_share", "vertical_range_m", "fade")
HIGH_M, LOW_M, FAR_M = 1.5, 0.5, 2.0  # height and distance bands used by checks


# ---- 1. check ---------------------------------------------------------------------

def check_round(r: dict, now: datetime) -> str | None:
    """Reason code when the round cannot be true, else None."""
    started = datetime.fromisoformat(r["started_at"])
    if started > now + timedelta(minutes=10):
        return "future_round"
    if started < now - timedelta(days=400):
        return "too_old"
    dur = r["duration_s"]
    if not (0 < dur <= 900):
        return "implausible_duration"
    lights = r["lights"]
    total = r["config"]["lights_total"]
    if len(lights) > total or total > 40:
        return "more_lights_than_config"
    if len({lt["i"] for lt in lights}) != len(lights) or any(not 0 <= lt["i"] < total for lt in lights):
        return "bad_light_index"
    tr = r["tracking"]
    if not 0.0 <= tr["normal_ratio"] <= 1.0:
        return "implausible_normal_ratio"
    if tr.get("play_area_m2") is not None and not 0 <= tr["play_area_m2"] <= 400:
        return "implausible_play_area"
    screen = r["mode"] == "screen"
    for lt in lights:
        times = [lt["spawn_t"], lt.get("first_move_t"), lt.get("end_t")]
        if any(t is not None and not (0 <= t <= dur + 1) for t in times):
            return "light_time_outside_round"
        if lt.get("end_t") is not None and lt["end_t"] < lt["spawn_t"]:
            return "light_ends_before_spawn"
        if lt.get("first_move_t") is not None and lt["first_move_t"] < lt["spawn_t"]:
            return "move_before_spawn"
        if lt["caught"] and lt.get("end_t") is None:
            return "caught_without_end"
        if screen and (lt.get("dist_m") is not None or lt.get("height_m") is not None):
            return "screen_with_distances"
        if not screen:
            if lt.get("dist_m") is None or not 0 <= lt["dist_m"] <= 15:
                return "implausible_distance"
            if lt.get("height_m") is None or not -0.5 <= lt["height_m"] <= 3.5:
                return "implausible_height"
    path = r.get("path")
    if screen and path is not None:
        return "screen_with_path"
    if path is not None:
        pts = path["points"]
        if any(abs(c) > 30 for p in pts for c in p):
            return "path_out_of_range"
        step_max = 4.0 / path["hz"]  # faster than 4 m/s cannot be a person indoors
        for a, b in zip(pts, pts[1:]):
            if math.dist(a, b) > step_max:
                return "path_jump"
    return None


def quality(r: dict, th: Thresholds = T) -> tuple[str, list[str]]:
    reasons = []
    if r["ended_by"] == "interrupted":
        reasons.append("interrupted")
    if r["mode"] != "screen":
        if r["tracking"]["normal_ratio"] < th.round_min_normal_ratio:
            reasons.append("tracking_limited")
        area = r["tracking"].get("play_area_m2")
        if area is None or area < th.round_min_play_area_m2:
            reasons.append("small_play_area")
    return ("low" if reasons else "good"), reasons


# ---- 2. features ------------------------------------------------------------------

def light_rows(r: dict) -> list[dict]:
    """Per light: reaction time and travel speed (None when unknown)."""
    out = []
    for lt in sorted(r["lights"], key=lambda x: x["i"]):
        fm, end = lt.get("first_move_t"), lt.get("end_t")
        reaction = fm - lt["spawn_t"] if fm is not None else None
        if reaction is None and lt["caught"] and end is not None:
            reaction = end - lt["spawn_t"]  # fallback: time to catch
        speed = None
        if lt["caught"] and lt.get("dist_m") is not None and fm is not None and end is not None \
                and end - fm > 0.05:
            speed = lt["dist_m"] / (end - fm)
        out.append({"i": lt["i"], "caught": lt["caught"], "reaction_s": reaction,
                    "speed_m_s": speed, "dist_m": lt.get("dist_m"), "height_m": lt.get("height_m")})
    return out


def _med(vals: list[float]) -> float | None:
    vals = [v for v in vals if v is not None]
    return median(vals) if vals else None


def fade_of(rows: list[dict], start: int | None = None) -> float | None:
    """Speed after `start` (default: the second half) against before."""
    sp = [(x["i"], x["speed_m_s"]) for x in rows if x["speed_m_s"] is not None]
    if len(sp) < 4:
        return None
    if start is None:
        half = len(sp) // 2
        first, second = sp[:half], sp[half:]
    else:
        first = [s for s in sp if s[0] < start]
        second = [s for s in sp if s[0] >= start]
    if len(first) < 2 or len(second) < 2:
        return None
    a = median(v for _i, v in first)
    b = median(v for _i, v in second)
    return b / a if a > 0 else None


def path_stats(r: dict) -> dict:
    path = r.get("path")
    if not path or len(path["points"]) < 2:
        return {"coverage": None, "still_share": None, "vertical_range_m": None,
                "path_length_m": None}
    pts = path["points"]
    cells = {(math.floor(x / 0.5), math.floor(z / 0.5)) for x, z, _y in pts}
    area = r["tracking"].get("play_area_m2") or 0
    coverage = min(1.0, len(cells) * 0.25 / area) if area > 0 else None
    steps = [math.dist(a, b) for a, b in zip(pts, pts[1:])]
    still = sum(1 for s in steps if s < 0.05) / len(steps)
    ys = [p[2] for p in pts]
    return {"coverage": coverage, "still_share": still, "vertical_range_m": max(ys) - min(ys),
            "path_length_m": sum(steps)}


def turning_of(r: dict) -> dict:
    """Signed turning of the path in the floor plane. Left is positive."""
    path = r.get("path")
    left = right = 0.0
    if path:
        moves = []
        pts = path["points"]
        for a, b in zip(pts, pts[1:]):
            dx, dz = b[0] - a[0], b[1] - a[1]
            if math.hypot(dx, dz) >= 0.05:
                moves.append(math.atan2(dz, dx))
        for h1, h2 in zip(moves, moves[1:]):
            d = (h2 - h1 + math.pi) % (2 * math.pi) - math.pi
            if d > 0:
                left += d
            else:
                right -= d
    total = left + right
    if total < math.pi:
        label = "little"
    elif left >= 2 * right:
        label = "mostly_left"
    elif right >= 2 * left:
        label = "mostly_right"
    else:
        label = "both"
    return {"left_rad": round(left, 2), "right_rad": round(right, 2), "label": label}


def features(r: dict) -> dict:
    rows = light_rows(r)
    total = r["config"]["lights_total"]
    ps = path_stats(r)
    return {
        "caught_share": sum(1 for x in rows if x["caught"]) / total if total else None,
        "median_reaction_s": _med([x["reaction_s"] for x in rows]),
        "median_speed_m_s": _med([x["speed_m_s"] for x in rows]),
        "coverage": ps["coverage"],
        "still_share": ps["still_share"],
        "vertical_range_m": ps["vertical_range_m"],
        "fade": fade_of(rows),
        "path_length_m": ps["path_length_m"],
    }


# ---- 3 and 4. own normal and energy ---------------------------------------------------

def round_baseline(previous: list[dict], mode: str, th: Thresholds = T) -> dict | None:
    """Robust stats per feature over earlier GOOD rounds in the same mode."""
    good = [p for p in previous if p["mode"] == mode and p.get("quality") == "good"]
    good = good[-th.round_baseline_max:]
    if len(good) < th.round_baseline_min:
        return None
    base = {}
    for f in FEATURES:
        vals = [p["features"][f] for p in good if p["features"].get(f) is not None]
        if len(vals) >= th.round_baseline_min:
            med = median(vals)
            mad = median(abs(v - med) for v in vals)
            base[f] = {"median": med, "scale": max(mad * th.mad_to_sigma, ROUND_MIN_SCALE[f])}
    return base or None


def round_z(feat: dict, base: dict | None) -> dict:
    if not base:
        return {}
    return {f: round((feat[f] - b["median"]) / b["scale"], 2)
            for f, b in base.items() if feat.get(f) is not None}


def energy(z: dict, th: Thresholds = T) -> tuple[float | None, str | None]:
    """Speed, reaction (faster = more energy) and coverage against own normal."""
    parts = []
    if "median_speed_m_s" in z:
        parts.append(z["median_speed_m_s"])
    if "median_reaction_s" in z:
        parts.append(-z["median_reaction_s"])
    if "coverage" in z:
        parts.append(z["coverage"])
    elif "caught_share" in z:
        parts.append(z["caught_share"])
    if not parts:
        return None, None
    e = sum(parts) / len(parts)
    bucket = "low" if e <= th.round_energy_low else "high" if e >= th.round_energy_high else "usual"
    return round(e, 2), bucket


def process_round(r: dict, previous: list[dict], th: Thresholds = T) -> dict:
    """Return the stored form: input + quality, features, z, energy."""
    q, reasons = quality(r, th)
    feat = features(r)
    base = round_baseline(previous, r["mode"], th)
    z = round_z(feat, base)
    e, bucket = energy(z, th)
    return {**r, "quality": q, "quality_reasons": reasons,
            "features": {k: (round(v, 3) if isinstance(v, float) else v) for k, v in feat.items()},
            "turning": turning_of(r), "z": z, "energy": e, "energy_bucket": bucket,
            "baseline_rounds": 0 if base is None else min(
                th.round_baseline_max,
                sum(1 for p in previous if p["mode"] == r["mode"] and p.get("quality") == "good"))}


# ---- 5. round_config ---------------------------------------------------------------------

def layout_seed(patient_id: str, config_id: str) -> int:
    """Same person and config -> same layout, so rounds can be compared."""
    return int(hashlib.sha256(f"{patient_id}:{config_id}".encode()).hexdigest()[:6], 16) % 100000


def pick_round_config(patient_id: str, rounds: list[dict], status: str, rules: list[dict],
                      lessons: list[dict], local: datetime, seated_action: bool = False) -> dict:
    """Code picks from the fixed ladder:
    start from the usual config; one step down after a low-energy round or
    while status is outside; one step up after two high-energy rounds;
    a lesson may prefer (or avoid) a config for this time of day;
    the person's rules always win (seated only, or no standing round)."""
    reason = "usual"
    played = [r for r in rounds if r.get("quality") == "good" and r["mode"] != "screen"]
    recent_ids = [r["config"]["config_id"] for r in played[-10:]]
    usual = max(set(recent_ids), key=recent_ids.count) if recent_ids else DEFAULT_CONFIG
    if usual == "seated_gentle":
        usual = DEFAULT_CONFIG if not seated_action else usual
    cid = usual
    ctx = context_for_hour(local.hour)
    prefer = [x for x in lessons if x.get("status") == "active" and x.get("config_id")
              and x["effect"] == "prefer" and x["context"] in ("any", ctx)]
    if prefer:
        cid, reason = prefer[-1]["config_id"], "lesson"
    level = LADDER.index(cid)
    scored = [r for r in played if r.get("energy_bucket")]
    if (scored and scored[-1]["energy_bucket"] == "low") or status == "outside":
        level = max(0, level - 1)
        reason = "low_energy_step_down" if scored and scored[-1]["energy_bucket"] == "low" \
            else "outside_step_down"
    elif len(scored) >= 2 and all(r["energy_bucket"] == "high" for r in scored[-2:]):
        level = min(len(LADDER) - 1, level + 1)
        reason = "high_energy_step_up"
    avoid = {x["config_id"] for x in lessons if x.get("status") == "active" and x.get("config_id")
             and x["effect"] == "avoid" and x["context"] in ("any", ctx)}
    if LADDER[level] in avoid:
        for alt in [level - 1, level + 1, level - 2, level + 2]:
            if 0 <= alt < len(LADDER) and LADDER[alt] not in avoid and LADDER[alt] != "seated_gentle":
                level, reason = alt, "lesson_avoid"
                break
    cid = LADDER[level]
    if cid == "seated_gentle" and not seated_action:
        cid = "near_gentle"  # stepping down never forces a seated round
    # Patient rules win.
    weekday = WEEKDAYS[local.weekday()]
    seated_rule = any(r["type"] == "seated_only" and weekday in r["params"]["weekdays"] for r in rules)
    no_standing = any(r["type"] == "no_action" and r["params"]["action"] == "ar_round" for r in rules)
    if seated_rule or seated_action or no_standing:
        cid, reason = "seated_gentle", ("patient_rule" if (seated_rule or no_standing) else "seated_action")
    return {"config_id": cid, **ROUND_CONFIGS[cid], "layout_seed": layout_seed(patient_id, cid),
            "reason": reason}
