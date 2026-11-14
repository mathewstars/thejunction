"""The sensor reading: the level-2 model reads one session's heart rate (and HRV
when there is one) from the watch together with the game's moments, the face
summary and the game's numbers, and code checks every item it reports
(data/sensors_prompt.txt).

The parts that are pure code:

- build_payload(): the object the model receives. Numbers and fixed codes only:
  times in seconds from the activity's start (never a clock time), heart rate
  rounded to whole beats, at most MAX_HR_ROWS rows, moment codes from the fixed
  list, the face summary's five numbers, the game's own numbers. No ids, no
  dates, no names, no text.
- code_view(): code's own answer to every question in the prompt, from the same
  payload, with the same rules.
- verify(): the model's reply against code_view(). An item code cannot confirm
  becomes "unclear" (or null) and is logged; copied numbers must exist in the
  payload.

Clinician-only. Nothing here reaches the patient, opens or closes attention,
changes what is offered or feeds the learning review.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from statistics import mean

from .sensors import MOMENT_NAMES

DATA_DIR = Path(__file__).resolve().parent.parent / "data"

ACTIVITIES = ("focus", "breathing", "checkin")
PAYLOAD_KEYS = ("activity", "duration_s", "finished", "heart_rate", "hrv_sdnn", "moments",
                "gameplay", "face")
GAMEPLAY_KEYS = {"focus": ("correct_taps", "wrong_taps", "misses", "median_reaction_ms"),
                 "breathing": ("breaths_completed", "time_played_s"),
                 "checkin": ("good_things",)}
FACE_KEYS = ("smile_rate_per_min", "facial_activity", "blink_rate_per_min", "look_down_share",
             "tracking_quality")
MAX_HR_ROWS = 150
MAX_MOMENT_ROWS = 200
BEFORE_S, AFTER_S = 600.0, 60.0

TREND = ("rising", "falling", "steady", "unclear")
AROUND = ("higher", "lower", "same", "unclear")
BREATHING = ("slows_with_breaths", "no_change", "unclear", "not_applicable")
HRV = ("present", "none")
FACE_HEART = ("lively_face_higher_hr", "still_face_lower_hr", "no_pattern", "unclear")
QUALITY = ("good", "partly", "poor")
CONFIDENCE = ("low", "medium", "high")

EDGE_S = 15.0
WINDOW_S = 5.0
STEP_BPM = 3.0
MIN_SAMPLES = 4
MIN_SPAN_S = 10.0
LIVELY_MIN = 0.45
STILL_BELOW = 0.2


def _obj(props: dict) -> dict:
    return {"type": "OBJECT", "properties": props, "required": list(props),
            "propertyOrdering": list(props)}


def _enum(words) -> dict:
    return {"type": "STRING", "enum": list(words)}


def _num_or_null() -> dict:
    return {"type": "NUMBER", "nullable": True}


# The reply's shape for the model's structured output (the output gate checks the
# same shape again, strictly, whatever the model was told).
RESPONSE_SCHEMA = _obj({
    "heart_rate": _obj({"trend": _enum(TREND), "start_bpm": _num_or_null(),
                        "end_bpm": _num_or_null(), "peak_bpm": _num_or_null(),
                        "peak_at_s": _num_or_null()}),
    "around_moments": {"type": "ARRAY", "maxItems": len(MOMENT_NAMES), "items": _obj({
        "moment": _enum(MOMENT_NAMES), "heart_rate": _enum(AROUND)})},
    "breathing_pattern": _enum(BREATHING),
    "hrv": _enum(HRV),
    "face_and_heart": _enum(FACE_HEART),
    "data_quality": _enum(QUALITY),
    "confidence": _enum(CONFIDENCE),
})


@lru_cache(maxsize=1)
def prompt_text() -> str:
    return (DATA_DIR / "sensors_prompt.txt").read_text("utf-8")


# ---- the payload ---------------------------------------------------------------------------

def _thin(rows: list, cap: int) -> list:
    if len(rows) <= cap:
        return rows
    k = -(-len(rows) // cap)  # ceil
    return rows[::k]


def build_payload(rec: dict, sensors: dict) -> dict:
    dur = float(rec["duration_s"])
    lo, hi = -BEFORE_S, dur + AFTER_S
    hr = [[round(t / 1000, 1), float(round(v))] for t, v in sensors.get("heart_rate") or []
          if lo <= t / 1000 <= hi]
    hrv = [[round(t / 1000, 1), round(float(v), 1)] for t, v in sensors.get("hrv_sdnn") or []
           if lo <= t / 1000 <= hi]
    moments = [[round(m["t_ms"] / 1000, 1), m["name"]] for m in sensors.get("moments") or []
               if m["name"] in MOMENT_NAMES and lo <= m["t_ms"] / 1000 <= hi]
    f = rec.get("features") or {}
    gameplay: dict = {}
    for k in GAMEPLAY_KEYS[rec["type"]]:
        v = rec.get(k, f.get(k))
        if isinstance(v, bool) or v is None:
            continue
        if isinstance(v, (int, float)):
            gameplay[k] = round(float(v), 2) if isinstance(v, float) else v
    payload = {"activity": rec["type"], "duration_s": round(dur, 1),
               "finished": rec.get("ended_by") == "finished",
               "heart_rate": _thin(hr, MAX_HR_ROWS), "hrv_sdnn": hrv[:50],
               "moments": _thin(moments, MAX_MOMENT_ROWS), "gameplay": gameplay}
    face = rec.get("face") if rec.get("face_quality") == "good" else None
    if face:
        payload["face"] = {k: round(float(face[k]), 2) for k in FACE_KEYS
                           if isinstance(face.get(k), (int, float)) and not isinstance(face.get(k), bool)}
    return payload


# ---- code's own view ------------------------------------------------------------------------

def _window(hr: list, a: float, b: float) -> float | None:
    vals = [v for t, v in hr if a <= t < b]
    return mean(vals) if vals else None


def _nearest(hr: list, at: float) -> float | None:
    if not hr:
        return None
    return min(hr, key=lambda r: abs(r[0] - at))[1]


def code_view(payload: dict) -> dict:
    dur = payload["duration_s"]
    hr = payload["heart_rate"]
    inside = [r for r in hr if 0 <= r[0] <= dur]
    span = inside[-1][0] - inside[0][0] if len(inside) > 1 else 0.0
    usable = len(inside) >= MIN_SAMPLES and span >= MIN_SPAN_S
    first = _window(inside, 0, EDGE_S) if usable else None
    last = _window(inside, max(0.0, dur - EDGE_S), dur + 0.01) if usable else None
    if first is None or last is None:
        trend = "unclear"
    else:
        d = last - first
        trend = "rising" if d >= STEP_BPM else "falling" if d <= -STEP_BPM else "steady"
    peak = max(inside, key=lambda r: r[1]) if inside else None
    session_mean = mean(v for _, v in inside) if inside else None
    around: dict[str, str] = {}
    for t, code in payload["moments"]:
        if code in around:
            continue
        windows = [_window(hr, mt, mt + WINDOW_S) for mt, c in payload["moments"] if c == code]
        windows = [w for w in windows if w is not None]
        if not windows or session_mean is None:
            around[code] = "unclear"
        else:
            d = mean(windows) - session_mean
            around[code] = "higher" if d >= STEP_BPM else "lower" if d <= -STEP_BPM else "same"
    if payload["activity"] != "breathing":
        breathing = "not_applicable"
    else:
        ins = [t for t, c in payload["moments"] if c == "breath_in"]
        end = next((t for t, c in payload["moments"] if c == "breathe_ended"), dur)
        cycles = []
        for i, t in enumerate(ins):
            stop = ins[i + 1] if i + 1 < len(ins) else end
            cycles.append(_window(hr, t, stop))
        if len(cycles) < 4 or any(c is None for c in cycles[:2] + cycles[-2:]):
            breathing = "unclear"
        else:
            d = mean(cycles[-2:]) - mean(cycles[:2])
            breathing = "slows_with_breaths" if d <= -STEP_BPM else "no_change"
    face = payload.get("face")
    if not face or trend == "unclear" or "facial_activity" not in face:
        face_heart = "unclear"
    elif face["facial_activity"] >= LIVELY_MIN and trend == "rising":
        face_heart = "lively_face_higher_hr"
    elif face["facial_activity"] < STILL_BELOW and trend == "falling":
        face_heart = "still_face_lower_hr"
    else:
        face_heart = "no_pattern"
    coverage = span / dur if dur > 0 else 0.0
    dense = len(inside) >= dur / 10
    quality = "good" if dense and coverage >= 0.8 else "partly" if coverage >= 0.5 else "poor"
    return {"trend": trend, "start_bpm": _nearest(hr, 0.0), "end_bpm": _nearest(hr, dur),
            "peak_bpm": peak[1] if peak else None, "peak_at_s": peak[0] if peak else None,
            "around": around, "breathing_pattern": breathing,
            "hrv": "present" if payload["hrv_sdnn"] else "none",
            "face_and_heart": face_heart, "data_quality": quality,
            "session_mean_bpm": round(session_mean, 1) if session_mean is not None else None}


# ---- verify -------------------------------------------------------------------------------

def verify(reply: dict, payload: dict) -> dict:
    """Every item against code's view. Returns {"reading", "dropped", "agreement"}."""
    code = code_view(payload)
    kept = {"heart_rate": dict(reply["heart_rate"]), "around_moments": [],
            "breathing_pattern": reply["breathing_pattern"], "hrv": reply["hrv"],
            "face_and_heart": reply["face_and_heart"], "data_quality": reply["data_quality"],
            "confidence": reply["confidence"]}
    dropped: list[dict] = []
    confirmed = 0

    def drop(item: str, value, reason: str) -> None:
        dropped.append({"item": item, "value": value, "reason": reason})

    hr = kept["heart_rate"]
    if hr["trend"] != "unclear":
        if hr["trend"] == code["trend"]:
            confirmed += 1
        else:
            drop("trend", hr["trend"], "code_disagrees")
            hr["trend"] = "unclear"
    values = {v for _, v in payload["heart_rate"]}
    for key in ("start_bpm", "end_bpm", "peak_bpm"):
        v = hr.get(key)
        if v is None:
            continue
        if v != code[key]:
            drop(key, v, "not_in_numbers" if v not in values else "code_disagrees")
            hr[key] = None
        else:
            confirmed += 1
    if hr.get("peak_at_s") is not None:
        at_ok = any(t == hr["peak_at_s"] and v == code["peak_bpm"] for t, v in payload["heart_rate"])
        if not at_ok or hr.get("peak_bpm") is None:
            drop("peak_at_s", hr["peak_at_s"], "not_in_numbers")
            hr["peak_at_s"] = None
        else:
            confirmed += 1
    seen: set[str] = set()
    for item in reply["around_moments"]:
        code_name, word = item["moment"], item["heart_rate"]
        if code_name not in code["around"] or code_name in seen:
            drop("around_moments", code_name, "moment_not_in_data" if code_name not in code["around"]
                 else "duplicate_moment")
            continue
        seen.add(code_name)
        if word != "unclear" and word != code["around"][code_name]:
            drop("around_moments", f"{code_name}:{word}", "code_disagrees")
            word = "unclear"
        elif word != "unclear":
            confirmed += 1
        kept["around_moments"].append({"moment": code_name, "heart_rate": word})
    for name in ("breathing_pattern", "face_and_heart"):
        if kept[name] in ("unclear", "not_applicable") and kept[name] == code[name]:
            continue
        if kept[name] != code[name]:
            drop(name, kept[name], "code_disagrees")
            kept[name] = "unclear" if name == "face_and_heart" or payload["activity"] == "breathing" \
                else "not_applicable"
        else:
            confirmed += 1
    if kept["hrv"] != code["hrv"]:
        drop("hrv", kept["hrv"], "code_disagrees")
        kept["hrv"] = code["hrv"]
    else:
        confirmed += 1
    if kept["data_quality"] != code["data_quality"]:
        drop("data_quality", kept["data_quality"], "code_disagrees")
        kept["data_quality"] = code["data_quality"]
    else:
        confirmed += 1
    missing = [m for m in code["around"] if m not in seen]
    agreement = {"items_confirmed": confirmed, "items_dropped": len(dropped),
                 "moments_reported": len(reply["around_moments"]), "moments_in_data": len(code["around"]),
                 "moments_missed": len(missing), "trend_code": code["trend"],
                 "data_quality_code": code["data_quality"]}
    return {"reading": kept, "dropped": dropped, "agreement": agreement, "code": code}
