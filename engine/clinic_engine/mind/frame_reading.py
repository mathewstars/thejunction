"""The frame reading: the level-2 model reads the raw face frames of one focus
or breathing session, and code checks every item it reports.

The model is the reader here; code is the checker and the fallback. The
deterministic summary (face_features.summarize) is computed and stored either
way, and nothing in this module changes it.

The parts that are pure code:

- reduce(): the reduced stream the model receives (data/frames_prompt.txt
  describes it): a few named channels, averaged over short blocks, rounded,
  capped in length. Numbers and fixed codes only: no ids, no dates or clock
  times, no names, no text.
- code_view(): code's own detection on the FULL-rate raw frames, with the
  thresholds of the face summary (smiles, blinks, the moment answers) plus a
  few of its own (segments, side, overall words).
- verify(): every item the model returned, confirmed, corrected or dropped
  against code_view(), with an agreement block.

Clinician-only. Nothing here reaches the patient, opens or closes attention,
changes what is offered or feeds the learning review.
"""

from __future__ import annotations

import math
from functools import lru_cache
from pathlib import Path

from . import face_features as ff
from .thresholds import T, Thresholds

DATA_DIR = Path(__file__).resolve().parent.parent / "data"

# The channels of the reduced stream, in this order. Each is sent only when its
# source channels exist; "tracked" is always last and always sent.
CHANNELS = ("smile", "smile_left", "smile_right", "cheek", "frown", "blink", "look_down",
            "brow_down", "brow_inner_up", "jaw_open", "head_pitch", "head_yaw", "head_roll",
            "tracked")
SOURCES = {
    "smile": ("mouthSmileLeft", "mouthSmileRight"),
    "smile_left": ("mouthSmileLeft",),
    "smile_right": ("mouthSmileRight",),
    "cheek": ("cheekSquintLeft", "cheekSquintRight"),
    "frown": ("mouthFrownLeft", "mouthFrownRight"),
    "blink": ("eyeBlinkLeft", "eyeBlinkRight"),
    "look_down": ("eyeLookDownLeft", "eyeLookDownRight"),
    "brow_down": ("browDownLeft", "browDownRight"),
    "brow_inner_up": ("browInnerUp",),
    "jaw_open": ("jawOpen",),
    "head_pitch": ("headPitch",),
    "head_yaw": ("headYaw",),
    "head_roll": ("headRoll",),
}
ANGLE_CHANNELS = ("head_pitch", "head_yaw", "head_roll")
ACTIVITIES = ("focus", "breathing")
PAYLOAD_KEYS = ("activity", "rate_hz", "channels", "frames", "moments_s")

# The reply, exactly as the prompt defines it.
SIDES = ("both", "left", "right")
SEGMENT_KINDS = ("looking_down", "brows_down", "inner_brows_raised", "head_down", "still_face",
                 "eyes_closed", "not_tracked")
EXPRESSION = ("lively", "moderate", "still", "unclear")
SMILING = ("often", "sometimes", "rarely", "none", "unclear")
GAZE = ("mostly_up", "often_down", "unclear")
TRACKING = ("good", "partly", "poor")
CONFIDENCE = ("low", "medium", "high")
MAX_SMILES = 30
MAX_SEGMENTS = 12


@lru_cache(maxsize=1)
def prompt_text() -> str:
    return (DATA_DIR / "frames_prompt.txt").read_text("utf-8")


# ---- the reduced stream ------------------------------------------------------------------

def _source_series(cols: dict[str, list[float]], name: str) -> list[float] | None:
    src = SOURCES[name]
    if any(c not in cols for c in src):
        return None
    if name == "blink":
        # Per frame: the more closed eye (as in the face summary's blink signal).
        return [max(a, b) for a, b in zip(cols[src[0]], cols[src[1]])]
    if len(src) == 2:
        return [(a + b) / 2 for a, b in zip(cols[src[0]], cols[src[1]])]
    return list(cols[src[0]])


def block_size(n: int, rate: float, th: Thresholds = T) -> int:
    """Frames per block: about rate / frames_rate_hz, made larger until the
    stream fits within frames_max_frames rows."""
    k = max(1, int(round(rate / th.frames_rate_hz)))
    while math.ceil(n / k) > th.frames_max_frames:
        k += 1
    return k


def reduce(raw: dict, activity: str, th: Thresholds = T) -> dict:
    """The JSON object the model receives (see data/frames_prompt.txt)."""
    rate = float(raw["rate_hz"])
    cols = ff._columns(raw)
    tracked = ff._tracked(raw)
    n = len(tracked)
    k = block_size(n, rate, th)
    series = {c: s for c in CHANNELS[:-1] if (s := _source_series(cols, c)) is not None}
    names = [c for c in CHANNELS[:-1] if c in series] + ["tracked"]
    frames = []
    for a in range(0, n, k):
        b = min(n, a + k)
        seen = [i for i in range(a, b) if tracked[i]]
        is_tracked = 2 * len(seen) >= (b - a)
        row = []
        for c in names[:-1]:
            if not seen:
                # Nothing seen in this block: the values are not used (the prompt
                # says to ignore a row with tracked 0), so none are sent.
                row.append(0.0)
                continue
            vals = [series[c][i] for i in seen]
            if c == "blink":
                # Max, not mean: a blink lasts about 0.1-0.2 s, shorter than a
                # block, and averaging would flatten it away.
                v = max(vals)
            else:
                v = sum(vals) / len(vals)
            row.append(round(v, 1) if c in ANGLE_CHANNELS else round(v, 2))
        row.append(1 if is_tracked else 0)
        frames.append(row)
    duration = n / rate
    moments = [round(m / 1000, 1) for m in (raw.get("moments_ms") or [])
               if 0 <= m / 1000 < duration][:ff.MAX_MOMENTS]
    return {"activity": activity, "rate_hz": round(rate / k, 2), "channels": names,
            "frames": frames, "moments_s": moments}


def recording_s(payload: dict) -> float:
    """How long the reduced stream lasts, in seconds."""
    return len(payload["frames"]) / payload["rate_hz"] if payload["rate_hz"] else 0.0


# ---- code's own view of the full-rate frames ------------------------------------------------

def _bands(value, cuts, words):
    """The word for value: the first (cut, word) with value >= cut, else the last word."""
    for cut, word in zip(cuts, words):
        if value >= cut:
            return word
    return words[-1]


def code_view(raw: dict, th: Thresholds = T) -> dict:
    """What code itself finds in the raw frames, at full rate. Smiles, blinks
    and moment answers use exactly the rules of the face summary."""
    rate = float(raw["rate_hz"])
    cols = ff._columns(raw)
    tracked = ff._tracked(raw)
    n = len(tracked)
    runs = ff._runs(tracked)
    summary = ff.summarize(raw, th)
    enough = sum(tracked) / rate >= th.face_raw_min_tracked_s

    left, right = cols["mouthSmileLeft"], cols["mouthSmileRight"]
    smile = [(x + y) / 2 for x, y in zip(left, right)]
    cheek = ff._pair(cols, "cheekSquintLeft", "cheekSquintRight")
    smiles = []
    if enough:
        for s, e in ff._events(smile, runs, th.smile_onset, th.smile_offset, True):
            if (e - s) / rate < th.smile_min_s:
                continue
            diff = sum(left[i] - right[i] for i in range(s, e)) / (e - s)
            side = "left" if diff >= th.frames_side_diff else \
                "right" if diff <= -th.frames_side_diff else "both"
            reach = None if cheek is None else \
                sum(cheek[s:e]) / (e - s) >= th.eye_smile_cheek_min
            smiles.append({"start_s": s / rate, "end_s": e / rate, "a": s, "b": e,
                           "reaches_eyes": reach, "side": side})

    blink = [max(x, y) for x, y in zip(cols["eyeBlinkLeft"], cols["eyeBlinkRight"])]
    blinks = 0
    if enough:
        blinks = sum(1 for s, e in ff._events(blink, runs, th.blink_onset, th.blink_offset, False)
                     if th.blink_min_s <= (e - s) / rate <= th.blink_max_s)

    # Per-frame conditions for the segments (None: the channels are missing).
    look = ff._pair(cols, "eyeLookDownLeft", "eyeLookDownRight")
    brow = ff._pair(cols, "browDownLeft", "browDownRight")
    inner = cols.get("browInnerUp")
    pitch = cols.get("headPitch")
    cond: dict[str, list[bool] | None] = {
        "looking_down": None if look is None else [v >= th.look_down_min for v in look],
        "brows_down": None if brow is None else [v >= th.brow_down_min for v in brow],
        "inner_brows_raised": None if inner is None else [v >= th.inner_brow_up_min for v in inner],
        "head_down": None if pitch is None else [v >= th.frames_head_down_deg for v in pitch],
        "eyes_closed": [v >= th.blink_onset for v in blink],
        "still_face": _still_frames(cols, runs, rate, n, th),
        "not_tracked": [not t for t in tracked],
    }

    # Moments: a smile starting within the window after it (as in the summary).
    moments = []
    for m in raw.get("moments_ms") or []:
        mi = int(round(m / 1000 * rate))
        if mi >= n or not tracked[mi] or not enough:
            moments.append({"at_s": round(m / 1000, 1), "smiled": None})
            continue
        end = mi + th.smile_response_window_s * rate
        moments.append({"at_s": round(m / 1000, 1),
                        "smiled": any(mi <= s["a"] <= end for s in smiles)})

    fa, sr = summary.get("facial_activity"), summary.get("smile_rate_per_min")
    ld, tq = summary.get("look_down_share"), summary.get("tracking_quality") or 0.0
    overall = {
        "expression": "unclear" if fa is None else _bands(
            fa, (th.frames_lively_min, th.frames_still_below), ("lively", "moderate", "still")),
        "smiling": "unclear" if sr is None else "none" if not smiles else _bands(
            sr, (th.frames_smiling_often_min, th.frames_smiling_sometimes_min),
            ("often", "sometimes", "rarely")),
        "gaze": "unclear" if ld is None else
        ("often_down" if ld >= th.frames_gaze_down_share else "mostly_up"),
        "tracking": _bands(tq, (th.frames_tracking_good, th.face_min_quality),
                           ("good", "partly", "poor")),
    }
    return {"rate": rate, "n": n, "tracked": tracked, "smiles": smiles, "blinks": blinks,
            "cond": cond, "moments": moments, "overall": overall, "summary": summary}


def _still_frames(cols, runs, rate: float, n: int, th: Thresholds) -> list[bool]:
    """A frame is "still" when the 0.1 s block it lies in moves less than
    frames_still_speed per second against the block before it (mean over the
    blend shapes, blinks left out: the facial_activity rule)."""
    moving = [cols[c] for c in cols if c not in ff.HEAD_CHANNELS and c not in ff.BLINK_CHANNELS]
    out = [False] * n
    if not moving:
        return out
    k = max(1, int(round(rate * th.face_motion_block_s)))
    width = k / rate
    for blocks in ff._blocks(runs, k):
        prev = None
        for s, e in blocks:
            mean = [sum(c[s:e]) / k for c in moving]
            if prev is not None:
                speed = sum(abs(y - x) for x, y in zip(prev, mean)) / len(mean) / width
                if speed < th.frames_still_speed:
                    for i in range(s, e):
                        out[i] = True
            prev = mean
    return out


# ---- verify ---------------------------------------------------------------------------------

def segment_share(view: dict, kind: str, start_s: float,
                  end_s: float) -> tuple[float | None, str | None]:
    """Code's share of the span [start_s, end_s) in which `kind` holds: over
    tracked frames, except not_tracked (over all frames). (None, reason) when
    code cannot tell."""
    rate, n = view["rate"], view["n"]
    a, b = max(0, int(math.floor(start_s * rate))), min(n, int(math.ceil(end_s * rate)))
    c = view["cond"].get(kind)
    if c is None:
        return None, "channel_missing"
    if b <= a:
        return None, "outside_recording"
    idx = list(range(a, b)) if kind == "not_tracked" else \
        [i for i in range(a, b) if view["tracked"][i]]
    if not idx:
        return None, "not_tracked"
    return sum(1 for i in idx if c[i]) / len(idx), None


def segment_threshold(kind: str, th: Thresholds = T) -> float:
    return getattr(th, f"frames_share_{kind}")


def verify(reply: dict, raw: dict, payload: dict, th: Thresholds = T) -> dict:
    """Check every item of a reply that already has the right shape. Returns
    {"reading", "agreement", "dropped"}; never raises on content."""
    view = code_view(raw, th)
    dropped: list[dict] = []

    # Smiles: matched to code's smiles by overlap, each code smile once.
    used: set[int] = set()
    smiles_out = []
    for sm in reply["smiles"]:
        a, b = sm["start_s"], sm["end_s"]
        best, best_share, best_free = None, 0.0, None
        for j, cs in enumerate(view["smiles"]):
            ov = max(0.0, min(b, cs["end_s"]) - max(a, cs["start_s"])) / (b - a)
            if ov > best_share:
                best, best_share = j, ov
            if j not in used and ov >= th.frames_smile_overlap and \
                    (best_free is None or ov > best_free[1]):
                best_free = (j, ov)
        if best_free is None:
            reason = "same_smile_twice" if best is not None and \
                best_share >= th.frames_smile_overlap else "not_found_by_code"
            dropped.append({"item": "smile", "start_s": a, "end_s": b, "reason": reason})
            continue
        j, share = best_free
        used.add(j)
        cs = view["smiles"][j]
        corrected = []
        out = {"start_s": a, "end_s": b, "reaches_eyes": sm["reaches_eyes"], "side": sm["side"]}
        if sm["reaches_eyes"] != cs["reaches_eyes"]:
            corrected.append("reaches_eyes")
            out["reaches_eyes"] = cs["reaches_eyes"]
        if sm["side"] != cs["side"]:
            corrected.append("side")
            out["side"] = cs["side"]
        out.update(status="corrected" if corrected else "confirmed", corrected=corrected,
                   overlap=round(share, 2))
        smiles_out.append(out)
    missed = len(view["smiles"]) - len(used)

    # Blinks: the model's number, code's number beside it.
    bm, bc = reply["blinks"], view["blinks"]
    blinks_ok = abs(bm - bc) <= max(th.frames_blink_tolerance_n,
                                    th.frames_blink_tolerance_share * bc)
    blinks = {"model": bm, "code": bc, "status": "confirmed" if blinks_ok else "not_confirmed"}

    # Segments: code's own share of the span must meet the kind's threshold.
    segments_out = []
    for sg in reply["segments"]:
        share, reason = segment_share(view, sg["what"], sg["start_s"], sg["end_s"])
        if share is None:
            dropped.append({"item": "segment", "start_s": sg["start_s"], "end_s": sg["end_s"],
                            "what": sg["what"], "reason": reason})
            continue
        if share < segment_threshold(sg["what"], th):
            dropped.append({"item": "segment", "start_s": sg["start_s"], "end_s": sg["end_s"],
                            "what": sg["what"], "reason": "code_share_too_low",
                            "code_share": round(share, 2)})
            continue
        segments_out.append({"start_s": sg["start_s"], "end_s": sg["end_s"], "what": sg["what"],
                             "status": "confirmed", "code_share": round(share, 2)})

    # Moments: each compared with code's own answer.
    sent = list(payload.get("moments_s") or [])
    code_moments = {round(m["at_s"], 1): m["smiled"] for m in view["moments"]}
    moments_out, matched = [], set()
    for mo in reply["moments"]:
        at = round(mo["at_s"], 1)
        hit = next((i for i, s in enumerate(sent) if abs(s - at) < 0.051 and i not in matched),
                   None)
        if hit is None:
            dropped.append({"item": "moment", "at_s": at, "reason": "not_a_sent_moment"})
            continue
        matched.add(hit)
        code = code_moments.get(round(sent[hit], 1))
        if code is None:
            dropped.append({"item": "moment", "at_s": at, "reason": "not_tracked"})
            continue
        moments_out.append({"at_s": sent[hit], "smiled": code, "model": mo["smiled"],
                            "status": "confirmed" if code == mo["smiled"] else "corrected"})

    # Overall words: replaced with code's word when they disagree.
    overall, checks = {}, {}
    for k in ("expression", "smiling", "gaze", "tracking"):
        m, c = reply["overall"][k], view["overall"][k]
        overall[k] = c
        checks[k] = {"model": m, "code": c, "status": "confirmed" if m == c else "corrected"}
    overall["confidence"] = reply["overall"]["confidence"]  # the model's own; not checkable

    agreement = {
        "smiles_reported": len(reply["smiles"]),
        "smiles_confirmed": sum(1 for s in smiles_out if s["status"] == "confirmed"),
        "smiles_corrected": sum(1 for s in smiles_out if s["status"] == "corrected"),
        "smiles_dropped": sum(1 for d in dropped if d["item"] == "smile"),
        "smiles_missed": missed,
        "smiles_code": len(view["smiles"]),
        "segments_reported": len(reply["segments"]),
        "segments_confirmed": len(segments_out),
        "blinks_model": bm,
        "blinks_code": bc,
        "moments_reported": len(reply["moments"]),
        "moments_agree": sum(1 for m in moments_out if m["status"] == "confirmed"),
        "overall_replaced": sum(1 for c in checks.values() if c["status"] == "corrected"),
    }
    reading = {"smiles": smiles_out, "blinks": blinks, "segments": segments_out,
               "moments": moments_out, "overall": overall, "overall_checks": checks}
    return {"reading": reading, "agreement": agreement, "dropped": dropped}


def time_problem(reply: dict, payload: dict) -> str | None:
    """A reason code when a time lies outside the recording or a span is
    empty; None when every time is usable."""
    limit = recording_s(payload) + 0.1
    for sp in reply["smiles"] + reply["segments"]:
        if not (0 <= sp["start_s"] <= limit and 0 <= sp["end_s"] <= limit):
            return "time_outside_recording"
        if sp["end_s"] <= sp["start_s"]:
            return "end_not_after_start"
    for mo in reply["moments"]:
        if not 0 <= mo["at_s"] <= limit:
            return "time_outside_recording"
    return None
