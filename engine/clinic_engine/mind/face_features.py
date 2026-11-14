"""The face summary, computed on the server from raw ARKit frames.

The phone does no computation on the face. It sends what ARKit gives per frame
(blend-shape coefficients 0..1 and three head angles in degrees) and the server
derives every measure here, with the thresholds in thresholds.py. The raw frames
are kept (outside the packs), so the rules can change and every session can be
re-analysed later (service.recompute_face).

Pure functions, no I/O. The output has exactly the fields of the `face` summary a
phone may still send itself (models.FaceSummary), so everything downstream (own
normal, watchers, session reading, research appraisal) works unchanged.

Rules (docs/face-raw.md has the table):
- tracking_quality: share of frames marked tracked. Every other measure uses
  tracked frames only; with less than face_raw_min_tracked_s of tracked time
  they are all null.
- events (smiles, blinks) use hysteresis like FaceMetrics: an event starts at a
  frame at or above `onset` and ends at the first frame at or below `offset`.
  Events never cross an untracked stretch: an open smile is closed at the last
  tracked frame (it was seen), an open blink is dropped (its length is unknown).
- movement (facial_activity, head_movement) is measured on short blocks of
  frames (about 0.1 s) so that the frame rate does not change the result.
"""

from __future__ import annotations

import math
from statistics import median

from .thresholds import T, Thresholds

BLEND_SHAPES = (
    "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight",
    "cheekPuff", "cheekSquintLeft", "cheekSquintRight", "eyeBlinkLeft", "eyeBlinkRight",
    "eyeLookDownLeft", "eyeLookDownRight", "eyeLookInLeft", "eyeLookInRight", "eyeLookOutLeft",
    "eyeLookOutRight", "eyeLookUpLeft", "eyeLookUpRight", "eyeSquintLeft", "eyeSquintRight",
    "eyeWideLeft", "eyeWideRight", "jawForward", "jawLeft", "jawOpen", "jawRight", "mouthClose",
    "mouthDimpleLeft", "mouthDimpleRight", "mouthFrownLeft", "mouthFrownRight", "mouthFunnel",
    "mouthLeft", "mouthLowerDownLeft", "mouthLowerDownRight", "mouthPressLeft", "mouthPressRight",
    "mouthPucker", "mouthRight", "mouthRollLower", "mouthRollUpper", "mouthShrugLower",
    "mouthShrugUpper", "mouthSmileLeft", "mouthSmileRight", "mouthStretchLeft",
    "mouthStretchRight", "mouthUpperUpLeft", "mouthUpperUpRight", "noseSneerLeft",
    "noseSneerRight", "tongueOut")
HEAD_CHANNELS = ("headPitch", "headYaw", "headRoll")  # degrees; headPitch positive = chin down
ALLOWED_CHANNELS = frozenset(BLEND_SHAPES + HEAD_CHANNELS)
REQUIRED_CHANNELS = ("mouthSmileLeft", "mouthSmileRight", "eyeBlinkLeft", "eyeBlinkRight")
BLINK_CHANNELS = ("eyeBlinkLeft", "eyeBlinkRight")

# Request limits (models.FaceRawIn checks them).
RATE_MIN_HZ, RATE_MAX_HZ = 5, 60
MAX_CHANNELS = 60
MAX_SAMPLES = 12_000
MAX_MOMENTS = 20
ANGLE_LIMIT_DEG = 180.0

SUMMARY_FIELDS = ("smile_rate_per_min", "smile_intensity", "facial_activity",
                  "blink_rate_per_min", "look_down_share", "head_tilt_deg", "smile_time_share",
                  "eye_smile_share", "smile_response_share", "smile_response_latency_s",
                  "brow_down_share", "inner_brow_up_share", "blink_duration_ms",
                  "head_pitch_deg", "head_movement", "smile_asymmetry",
                  "lip_down_share", "lip_press_share")


# ---- checking the request ---------------------------------------------------------------

def check_raw(raw: dict, th: Thresholds = T) -> str | None:
    """A plain message for the first problem found, else None. Never echoes a
    value or a name the client sent: positions only."""
    channels = raw["channels"]
    if len(channels) > MAX_CHANNELS:
        return f"at most {MAX_CHANNELS} channels"
    seen: set[str] = set()
    for i, name in enumerate(channels):
        if name not in ALLOWED_CHANNELS:
            return (f"channels[{i}] is not an ARKit blend-shape name or one of "
                    "headPitch, headYaw, headRoll")
        if name in seen:
            return f"channels[{i}] repeats an earlier channel"
        seen.add(name)
    missing = [c for c in REQUIRED_CHANNELS if c not in seen]
    if missing:
        return "channels must include " + ", ".join(missing)
    samples = raw["samples"]
    if len(samples) > MAX_SAMPLES:
        return f"at most {MAX_SAMPLES} samples"
    n_ch = len(channels)
    lo, hi = -th.face_raw_overshoot, 1 + th.face_raw_overshoot
    is_angle = [c in HEAD_CHANNELS for c in channels]
    for r, row in enumerate(samples):
        if len(row) != n_ch:
            return f"samples[{r}] has {len(row)} values; channels has {n_ch}"
        for c, v in enumerate(row):
            if not math.isfinite(v):
                return f"samples[{r}][{c}] is not a finite number"
            if is_angle[c]:
                if not -ANGLE_LIMIT_DEG <= v <= ANGLE_LIMIT_DEG:
                    return f"samples[{r}][{c}] ({channels[c]}) is outside -180..180 degrees"
            elif not lo <= v <= hi:
                return f"samples[{r}][{c}] ({channels[c]}) is outside 0..1"
    tracked = raw.get("tracked")
    if tracked is not None and len(tracked) != len(samples):
        return f"tracked has {len(tracked)} values; samples has {len(samples)}"
    moments = raw.get("moments_ms")
    if moments is not None and len(moments) > MAX_MOMENTS:
        return f"at most {MAX_MOMENTS} moments"
    return None


# ---- small helpers ------------------------------------------------------------------------

def _columns(raw: dict) -> dict[str, list[float]]:
    """Channel -> values per frame; blend shapes clamped to 0..1."""
    cols: dict[str, list[float]] = {}
    for i, name in enumerate(raw["channels"]):
        vals = [float(row[i]) for row in raw["samples"]]
        if name not in HEAD_CHANNELS:
            vals = [0.0 if v < 0 else 1.0 if v > 1 else v for v in vals]
        cols[name] = vals
    return cols


def _tracked(raw: dict) -> list[bool]:
    t = raw.get("tracked")
    n = len(raw["samples"])
    return [True] * n if t is None else [bool(x) for x in t]


def _runs(tracked: list[bool]) -> list[tuple[int, int]]:
    """Stretches of tracked frames, [start, end)."""
    out, start = [], None
    for i, ok in enumerate(tracked):
        if ok and start is None:
            start = i
        elif not ok and start is not None:
            out.append((start, i))
            start = None
    if start is not None:
        out.append((start, len(tracked)))
    return out


def _events(sig: list[float], runs: list[tuple[int, int]], onset: float, offset: float,
            close_at_gap: bool) -> list[tuple[int, int]]:
    """Hysteresis events [start, end): start at the first frame >= onset, end at
    the first frame <= offset (that frame is outside the event)."""
    out = []
    for a, b in runs:
        start = None
        for i in range(a, b):
            v = sig[i]
            if start is None:
                if v >= onset:
                    start = i
            elif v <= offset:
                out.append((start, i))
                start = None
        if start is not None and close_at_gap:
            out.append((start, b))
    return out


def _mean(vals) -> float | None:
    vals = list(vals)
    return sum(vals) / len(vals) if vals else None


def _pair(cols: dict, a: str, b: str) -> list[float] | None:
    if a not in cols or b not in cols:
        return None
    return [(x + y) / 2 for x, y in zip(cols[a], cols[b])]


def _share(sig: list[float] | None, idx: list[int], at_least: float) -> float | None:
    if sig is None or not idx:
        return None
    return sum(1 for i in idx if sig[i] >= at_least) / len(idx)


def _blocks(runs: list[tuple[int, int]], k: int) -> list[list[tuple[int, int]]]:
    """Consecutive blocks of k tracked frames, grouped per tracked stretch."""
    return [[(s, s + k) for s in range(a, b - k + 1, k)] for a, b in runs]


def _block_speeds(cols: list[list[float]], runs, k: int, width_s: float,
                  combine, angles: bool = False) -> list[float]:
    """One speed per pair of neighbouring blocks (same stretch): combine() of the
    per-channel |change of block mean| / width. Angle changes are taken the
    short way round (179 to -179 degrees is 2 degrees)."""
    out = []
    for blocks in _blocks(runs, k):
        means = [[sum(c[s:e]) / k for c in cols] for s, e in blocks]
        for m0, m1 in zip(means, means[1:]):
            d = [y - x for x, y in zip(m0, m1)]
            if angles:
                d = [(x + 180.0) % 360.0 - 180.0 for x in d]
            out.append(combine([abs(x) / width_s for x in d]))
    return out


def _r(x: float | None, nd: int = 3, lo: float | None = None, hi: float | None = None):
    if x is None:
        return None
    if lo is not None:
        x = max(x, lo)
    if hi is not None:
        x = min(x, hi)
    return round(x, nd)


# ---- the summary ---------------------------------------------------------------------------

def describe(raw: dict) -> dict:
    """Counts only, for the activity record and the clinician page."""
    tracked = _tracked(raw)
    n = len(tracked)
    return {"rate_hz": raw["rate_hz"], "frames": n,
            "tracked_share": round(sum(tracked) / n, 3) if n else 0.0,
            "channels": len(raw["channels"])}


def summarize(raw: dict, th: Thresholds = T) -> dict:
    """The face summary (FaceSummary fields) from raw frames."""
    rate = float(raw["rate_hz"])
    tracked = _tracked(raw)
    n = len(tracked)
    out: dict = {k: None for k in SUMMARY_FIELDS}
    out["tracking_quality"] = round(sum(tracked) / n, 3) if n else 0.0
    idx = [i for i, ok in enumerate(tracked) if ok]
    tracked_s = len(idx) / rate
    if tracked_s < th.face_raw_min_tracked_s:
        return out
    minutes = tracked_s / 60
    cols = _columns(raw)
    runs = _runs(tracked)

    # Smiles.
    left, right = cols["mouthSmileLeft"], cols["mouthSmileRight"]
    smile = [(x + y) / 2 for x, y in zip(left, right)]
    smiles = [(s, e) for s, e in _events(smile, runs, th.smile_onset, th.smile_offset, True)
              if (e - s) / rate >= th.smile_min_s]
    inside = [i for s, e in smiles for i in range(s, e)]
    out["smile_rate_per_min"] = _r(len(smiles) / minutes, 2, 0, 120)
    out["smile_time_share"] = _r(len(inside) / len(idx), 3, 0, 1)
    if smiles:
        out["smile_intensity"] = _r(_mean(smile[i] for i in inside), 3, 0, 1)
        out["smile_asymmetry"] = _r(_mean(abs(left[i] - right[i]) for i in inside), 3, 0, 1)
        cheek = _pair(cols, "cheekSquintLeft", "cheekSquintRight")
        if cheek is not None:
            reach = sum(1 for s, e in smiles
                        if sum(cheek[s:e]) / (e - s) >= th.eye_smile_cheek_min)
            out["eye_smile_share"] = _r(reach / len(smiles), 3, 0, 1)

    # Answers to marked pleasant moments: a smile starting within the window.
    moments = raw.get("moments_ms") or []
    counted, delays = 0, []
    for m in moments:
        mi = int(round(m / 1000 * rate))
        if mi >= n or not tracked[mi]:
            continue  # after the last frame, or not seen: cannot be answered
        counted += 1
        window_end = mi + th.smile_response_window_s * rate
        starts = [s for s, _e in smiles if mi <= s <= window_end]
        if starts:
            delays.append((starts[0] - mi) / rate)
    if counted:
        out["smile_response_share"] = _r(len(delays) / counted, 3, 0, 1)
        if delays:
            out["smile_response_latency_s"] = _r(median(delays), 2, 0, 30)

    # Blinks: either eye closes, both open again (FaceMetrics).
    blink = [max(x, y) for x, y in zip(cols["eyeBlinkLeft"], cols["eyeBlinkRight"])]
    blinks = [(e - s) / rate for s, e in _events(blink, runs, th.blink_onset, th.blink_offset,
                                                 False)
              if th.blink_min_s <= (e - s) / rate <= th.blink_max_s]
    out["blink_rate_per_min"] = _r(len(blinks) / minutes, 2, 0, 120)
    if blinks:
        out["blink_duration_ms"] = _r(median(blinks) * 1000, 1, 0, 2000)

    # Where the eyes and brows were.
    out["look_down_share"] = _r(_share(_pair(cols, "eyeLookDownLeft", "eyeLookDownRight"), idx,
                                       th.look_down_min))
    out["brow_down_share"] = _r(_share(_pair(cols, "browDownLeft", "browDownRight"), idx,
                                       th.brow_down_min))
    out["inner_brow_up_share"] = _r(_share(cols.get("browInnerUp"), idx, th.inner_brow_up_min))

    # The mouth held down or pressed shut. Observer-rated "lips down" and "tight
    # lips" track treatment response in the literature (docs/research-notes-
    # gamified-dtx.md); here the share of tracked frames at or above a threshold,
    # like the brows. Lip corners down = mouthFrown; lips pressed = mouthPress.
    out["lip_down_share"] = _r(_share(_pair(cols, "mouthFrownLeft", "mouthFrownRight"), idx,
                                      th.lip_down_min))
    out["lip_press_share"] = _r(_share(_pair(cols, "mouthPressLeft", "mouthPressRight"), idx,
                                       th.lip_press_min))

    # How much the face moved: blocks of about face_motion_block_s.
    k = max(1, int(round(rate * th.face_motion_block_s)))
    width = k / rate
    moving = [cols[c] for c in cols if c not in HEAD_CHANNELS and c not in BLINK_CHANNELS]
    if moving:
        speeds = _block_speeds(moving, runs, k, width, lambda v: sum(v) / len(v))
        if speeds:
            out["facial_activity"] = _r(_mean(speeds) / th.facial_activity_full_per_s, 3, 0, 1)

    # The head.
    if "headPitch" in cols:
        out["head_pitch_deg"] = _r(_mean(cols["headPitch"][i] for i in idx), 2, -90, 90)
    if "headRoll" in cols:
        out["head_tilt_deg"] = _r(_mean(abs(cols["headRoll"][i]) for i in idx), 2, 0, 90)
    head = [cols[c] for c in HEAD_CHANNELS if c in cols]
    if head:
        speeds = _block_speeds(head, runs, k, width,
                               lambda v: math.sqrt(sum(x * x for x in v)), angles=True)
        if speeds:
            out["head_movement"] = _r(_mean(speeds) / th.head_movement_full_deg_s, 3, 0, 1)
    return out
