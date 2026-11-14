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
- verify(): every item the model returned, compared with code_view(), with an
  agreement block. Two methods read the same numbers: where they agree the
  item is confirmed; where the model reports a smile that code's fixed onset
  did not reach, code tests the span against the session's own resting level
  and keeps it apart as a faint smile when the rise is in the numbers.
- aggregate(): the agreement over many sessions, with their number.

Clinician-only. Nothing here reaches the patient, changes what is offered or
feeds the learning review. One thing follows from it: when the model finds
something the fixed rules did not flag and code confirms it, the mind opens a
low-level flag for the clinic (watchers.watch_model_noticed).
"""

from __future__ import annotations

import math
from functools import lru_cache
from pathlib import Path

from . import face_features as ff
from .thresholds import T, Thresholds

DATA_DIR = Path(__file__).resolve().parent.parent / "data"

# The channels of the reduced stream, in this order. "t" (seconds from the
# first frame) is always first and "tracked" always last; each of the others is
# sent only when its source channels exist.
CHANNELS = ("t", "smile", "smile_left", "smile_right", "cheek", "frown", "blink", "look_down",
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


def _obj(props: dict) -> dict:
    return {"type": "OBJECT", "properties": props, "required": list(props),
            "propertyOrdering": list(props)}


def _enum(words) -> dict:
    return {"type": "STRING", "enum": list(words)}


# The reply's shape for the model's structured output (the output gate checks
# the same shape again, strictly, whatever the model was told).
RESPONSE_SCHEMA = _obj({
    "smiles": {"type": "ARRAY", "maxItems": MAX_SMILES, "items": _obj({
        "start_s": {"type": "NUMBER"}, "end_s": {"type": "NUMBER"},
        "reaches_eyes": {"type": "BOOLEAN", "nullable": True}, "side": _enum(SIDES)})},
    "blinks": {"type": "INTEGER"},
    "segments": {"type": "ARRAY", "maxItems": MAX_SEGMENTS, "items": _obj({
        "start_s": {"type": "NUMBER"}, "end_s": {"type": "NUMBER"},
        "what": _enum(SEGMENT_KINDS)})},
    "moments": {"type": "ARRAY", "items": _obj({
        "at_s": {"type": "NUMBER"}, "smiled": {"type": "BOOLEAN"}})},
    "overall": _obj({"expression": _enum(EXPRESSION), "smiling": _enum(SMILING),
                     "gaze": _enum(GAZE), "tracking": _enum(TRACKING),
                     "confidence": _enum(CONFIDENCE)}),
})


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
    series = {c: s for c in CHANNELS[1:-1] if (s := _source_series(cols, c)) is not None}
    names = ["t"] + [c for c in CHANNELS[1:-1] if c in series] + ["tracked"]
    frames = []
    for a in range(0, n, k):
        b = min(n, a + k)
        seen = [i for i in range(a, b) if tracked[i]]
        is_tracked = 2 * len(seen) >= (b - a)
        # The time the block starts: the model reads times, it does not count rows.
        row = [round(a / rate, 2)]
        for c in names[1:-1]:
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
    # Rounded down, so a moment in the last tenth of a second stays inside.
    moments = [math.floor(m / 100) / 10 for m in (raw.get("moments_ms") or [])
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

    # The session's own resting level of the smile signal: the median over the
    # tracked frames (a person smiling most of the session has a high one, and
    # then nothing is "faint").
    seen_vals = sorted(v for v, t in zip(smile, tracked) if t)
    rest = seen_vals[len(seen_vals) // 2] if seen_vals else 0.0

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
        if not 0 <= m / 1000 < n / rate:
            continue  # not sent to the model either (reduce)
        at = math.floor(m / 100) / 10
        mi = min(n - 1, int(round(m / 1000 * rate)))
        if not tracked[mi] or not enough:
            moments.append({"at_s": at, "smiled": None})
            continue
        end = mi + th.smile_response_window_s * rate
        moments.append({"at_s": at, "smiled": any(mi <= s["a"] <= end for s in smiles)})

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
            "cond": cond, "moments": moments, "overall": overall, "summary": summary,
            "smile": smile, "left": left, "right": right, "rest": rest, "enough": enough}


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

    # Smiles: matched to code's smiles one to one, by the overlap of the two
    # spans over their union (so neither a sliver inside a smile nor a span far
    # wider than it counts as the same smile). A reported smile that touches no
    # smile of code's is tested against the session's resting level: when the
    # rise is in the numbers it is kept apart as a faint smile.
    used: set[int] = set()
    smiles_out, faint_out, start_errors = [], [], []
    for sm in reply["smiles"]:
        a, b = sm["start_s"], sm["end_s"]
        touches, taken, best_free, inside_long = False, False, None, False
        for j, cs in enumerate(view["smiles"]):
            inter = max(0.0, min(b, cs["end_s"]) - max(a, cs["start_s"]))
            if inter <= 0:
                continue
            touches = True
            # The report lies inside a smile of code's that is several times
            # longer: the fixed rule may have merged a stretch into one smile
            # (a mouth that rests near the onset does that).
            if inter >= 0.8 * (b - a) and cs["end_s"] - cs["start_s"] >= max(
                    th.frames_long_smile_min_s, th.frames_long_smile_ratio * (b - a)):
                inside_long = True
            iou = inter / (max(b, cs["end_s"]) - min(a, cs["start_s"]))
            if iou < th.frames_smile_iou:
                continue
            if j in used:
                taken = True
            elif best_free is None or iou > best_free[1]:
                best_free = (j, iou)
        if best_free is None:
            again = False
            if not touches or (inside_long and not taken):
                rise = faint_rise(view, a, b, th, within_code_smile=touches)
                again = rise is not None and any(
                    min(b, f["end_s"]) > max(a, f["start_s"]) for f in faint_out)
                if rise is not None and not again:
                    faint_out.append({"start_s": a, "end_s": b, **rise})
                    continue
            reason = "same_smile_twice" if taken or again else \
                "poor_overlap" if touches else "no_rise_in_numbers"
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
                   overlap=round(share, 2), code_start_s=round(cs["start_s"], 2),
                   code_end_s=round(cs["end_s"], 2),
                   start_error_s=round(a - cs["start_s"], 2),
                   end_error_s=round(b - cs["end_s"], 2))
        start_errors.append(abs(a - cs["start_s"]))
        smiles_out.append(out)
    missed = [{"start_s": round(cs["start_s"], 2), "end_s": round(cs["end_s"], 2)}
              for j, cs in enumerate(view["smiles"]) if j not in used]

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
        short = sg["what"] in ("eyes_closed", "not_tracked")
        if sg["end_s"] - sg["start_s"] < (th.frames_segment_min_short_s if short
                                          else th.frames_segment_min_s) - 1e-9:
            dropped.append({"item": "segment", "start_s": sg["start_s"], "end_s": sg["end_s"],
                            "what": sg["what"], "reason": "too_short"})
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
    code_moments = {round(m["at_s"], 1): m["smiled"] for m in view["moments"]}  # as sent
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

    # Overall words: code's word is the one shown; the model's stands beside it.
    # They are a comparison of two summaries, not part of the item agreement:
    # "expression" is computed by code from every blend shape, and the model
    # sees ten channels.
    overall, checks = {}, {}
    for k in ("expression", "smiling", "gaze", "tracking"):
        m, c = reply["overall"][k], view["overall"][k]
        overall[k] = c
        checks[k] = {"model": m, "code": c, "status": "same" if m == c else "different"}
    overall["confidence"] = reply["overall"]["confidence"]  # the model's own; not checkable

    matched = len(smiles_out)
    at_code_level = len(reply["smiles"]) - len(faint_out)
    reasons = [d["reason"] for d in dropped if d["item"] == "smile"]
    agreement = {
        "smiles_reported": len(reply["smiles"]),
        "smiles_confirmed": sum(1 for s in smiles_out if s["status"] == "confirmed"),
        "smiles_corrected": sum(1 for s in smiles_out if s["status"] == "corrected"),
        "smiles_matched": matched,
        # Kept apart, the rise confirmed by code: "faint" stays under the fixed
        # onset; "brief" passes it but is shorter than the rule's minimum length.
        "smiles_faint": sum(1 for f in faint_out if f["status"] == "faint"),
        "smiles_brief": sum(1 for f in faint_out if f["status"] == "brief"),
        # A clear rise and return inside a far longer smile of the fixed rule's.
        "smiles_inside_long": sum(1 for f in faint_out if f["status"] == "inside_long"),
        "smiles_dropped": len(reasons),
        # Of the dropped: nothing in the numbers, against a real smile matched badly
        # (a sliver of it, far wider than it, or reported twice).
        "smiles_not_in_numbers": reasons.count("no_rise_in_numbers"),
        "smiles_poor_match": len(reasons) - reasons.count("no_rise_in_numbers"),
        "smiles_missed": len(missed),
        "smiles_code": len(view["smiles"]),
        # Of the smiles the model reported at code's level, the share code also
        # found; of code's smiles, the share the model also reported.
        "smile_precision": round(matched / at_code_level, 2) if at_code_level else None,
        "smile_recall": round(matched / len(view["smiles"]), 2) if view["smiles"] else None,
        "smile_start_error_s": round(sum(start_errors) / matched, 2) if matched else None,
        "segments_reported": len(reply["segments"]),
        "segments_confirmed": len(segments_out),
        "blinks_model": bm,
        "blinks_code": bc,
        "moments_reported": len(reply["moments"]),
        "moments_agree": sum(1 for m in moments_out if m["status"] == "confirmed"),
        "overall_same": sum(1 for c in checks.values() if c["status"] == "same"),
    }
    reading = {"smiles": smiles_out, "faint_smiles": faint_out, "missed_smiles": missed,
               "blinks": blinks, "segments": segments_out, "moments": moments_out,
               "overall": overall, "overall_checks": checks,
               "resting_smile": round(view["rest"], 2)}
    return {"reading": reading, "agreement": agreement, "dropped": dropped}


def _median(vals: list[float]) -> float:
    vals = sorted(vals)
    return vals[len(vals) // 2]


def faint_rise(view: dict, start_s: float, end_s: float, th: Thresholds = T,
               within_code_smile: bool = False) -> dict | None:
    """A reported smile that code's fixed rule did not find: is the rise in the
    numbers? Over the tracked full-rate frames of the span, the smile signal
    must lie above the local resting level by at least frames_faint_mean_rise
    on average and frames_faint_peak_rise at its peak, for at least
    smile_min_s, and both mouth corners must carry the rise. The local resting
    level is taken within frames_faint_window_s before and after the span (the
    span and code's smiles left out): the median of each side, and the higher of
    the two, because a smile returns to rest on both sides and a step in the
    baseline does not. With less than a second on either side, the session's
    median. Returns the measured rise with its status ("faint":
    the peak stays under the fixed onset; "brief": it passes the onset, but the
    smile is shorter than the rule's minimum length), or None.

    within_code_smile: the span lies inside a much longer smile of code's. Then
    code's smiles are not left out of the resting level (the long smile is what
    is in doubt), the peak rise must be twice as large, and the status is
    "inside_long": a clear rise and return inside a stretch the fixed rule
    counted as one smile."""
    if not view["enough"]:
        return None
    rate, n = view["rate"], view["n"]
    a, b = max(0, int(math.floor(start_s * rate))), min(n, int(math.ceil(end_s * rate)))
    idx = [i for i in range(a, b) if view["tracked"][i]]
    if len(idx) / rate < th.smile_min_s:
        return None
    w = int(th.frames_faint_window_s * rate)
    in_smile = [False] * n
    for cs in view["smiles"]:
        for i in range(cs["a"], cs["b"]):
            in_smile[i] = True
    if within_code_smile:
        in_smile = [False] * n
    sides = [[i for i in rng if view["tracked"][i] and not in_smile[i]]
             for rng in (range(max(0, a - w), a), range(b, min(n, b + w)))]
    sides = [sd for sd in sides if len(sd) / rate >= 1.0]

    def rise_of(sig: list[float], fallback: float | None) -> tuple[float, float, float]:
        # A smile returns to rest on both sides: the higher side is the rest.
        rest = max(_median([sig[i] for i in sd]) for sd in sides) if sides else \
            fallback if fallback is not None else \
            _median([v for v, t in zip(sig, view["tracked"]) if t])
        vals = [sig[i] for i in idx]
        return sum(vals) / len(vals) - rest, max(vals) - rest, rest

    mean_rise, peak_rise, rest = rise_of(view["smile"], view["rest"])
    need_peak = th.frames_faint_peak_rise * (2 if within_code_smile else 1)
    if mean_rise < th.frames_faint_mean_rise or peak_rise < need_peak:
        return None
    side = th.frames_faint_side_share * th.frames_faint_mean_rise
    if rise_of(view["left"], None)[0] < side or rise_of(view["right"], None)[0] < side:
        return None
    peak = max(view["smile"][i] for i in idx)
    return {"status": "inside_long" if within_code_smile else
            "faint" if peak < th.smile_onset else "brief",
            "peak": round(peak, 2), "rise": round(peak_rise, 2), "rest": round(rest, 2)}


_SUMS = ("smiles_reported", "smiles_matched", "smiles_faint", "smiles_brief",
         "smiles_inside_long", "smiles_dropped",
         "smiles_not_in_numbers", "smiles_poor_match", "smiles_missed",
         "smiles_code", "segments_reported", "segments_confirmed", "moments_reported",
         "moments_agree")


def aggregate(agreements: list[dict], th: Thresholds = T) -> dict | None:
    """The agreement of the two readers over several sessions: sums, the two
    shares and how many sessions they cover. None when there is no session."""
    # Readings stored before the union-overlap match have no matched count:
    # they are left out rather than counted as no agreement.
    agreements = [a for a in agreements if a.get("smiles_matched") is not None]
    if not agreements:
        return None
    out = {"sessions": len(agreements)}
    for k in _SUMS:
        out[k] = sum(int(a.get(k) or 0) for a in agreements)
    at_code_level = out["smiles_reported"] - out["smiles_faint"] - out["smiles_brief"] \
        - out["smiles_inside_long"]
    out["smile_precision"] = round(out["smiles_matched"] / at_code_level, 2) \
        if at_code_level else None
    out["smile_recall"] = round(out["smiles_matched"] / out["smiles_code"], 2) \
        if out["smiles_code"] else None
    errs = [(a["smile_start_error_s"], a.get("smiles_matched") or 0) for a in agreements
            if a.get("smile_start_error_s") is not None]
    weight = sum(w for _, w in errs)
    out["smile_start_error_s"] = round(sum(e * w for e, w in errs) / weight, 2) if weight else None
    out["blink_sessions_agree"] = sum(
        1 for a in agreements if a.get("blinks_model") is not None and
        abs(a["blinks_model"] - a["blinks_code"]) <= max(
            th.frames_blink_tolerance_n, th.frames_blink_tolerance_share * a["blinks_code"]))
    return out


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
