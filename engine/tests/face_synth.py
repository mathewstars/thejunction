"""Synthetic raw face frames for the tests: a realistic-looking ARKit stream
with events placed exactly where a test wants them. Test helper only, never
used by the seed."""

import math
import random

from clinic_engine.mind.face_features import BLEND_SHAPES, HEAD_CHANNELS

ALL_CHANNELS = list(BLEND_SHAPES) + list(HEAD_CHANNELS)
REQUIRED = ["mouthSmileLeft", "mouthSmileRight", "eyeBlinkLeft", "eyeBlinkRight"]
# A value no rule would ever produce, written into every frame of one channel,
# so the tests can look for it in places where frames must never appear.
MARKER = 0.0123457
MOVING = ["jawOpen", "mouthClose", "mouthFunnel", "mouthPucker", "mouthLowerDownLeft",
          "mouthLowerDownRight", "mouthUpperUpLeft", "mouthUpperUpRight", "mouthStretchLeft",
          "mouthStretchRight", "mouthPressLeft", "mouthPressRight", "mouthRollLower",
          "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper", "browInnerUp",
          "browOuterUpLeft", "browOuterUpRight", "eyeWideLeft", "eyeWideRight", "eyeSquintLeft",
          "eyeSquintRight", "cheekSquintLeft", "cheekSquintRight"]


def _span(start_s, dur_s, rate):
    a = int(round(start_s * rate))
    return range(a, a + int(round(dur_s * rate)))


def make_raw(seconds=60.0, rate=30, channels=None, smiles=(), blinks=(), lively=False,
             head_lively=False, jitter=0.008, head_jitter=0.3, untracked=(), look_down=(),
             lip_down=(), lip_press=(), moments_ms=None, marker=False, seed=7):
    """smiles: (start_s, dur_s, left, right[, cheek]); blinks: (start_s, dur_s);
    untracked / look_down / lip_down / lip_press: (start_s, dur_s) spans."""
    channels = list(channels or ALL_CHANNELS)
    rng = random.Random(seed)
    n = int(round(seconds * rate))
    cols = {}
    for c in channels:
        if c in HEAD_CHANNELS:
            base = {"headPitch": 6.0, "headYaw": -2.0, "headRoll": 3.0}[c]
            vals = []
            for i in range(n):
                t = i / rate
                v = base + rng.gauss(0, head_jitter)
                if head_lively and c != "headRoll":
                    v += 10 * math.sin(2 * math.pi * 0.3 * t + (0 if c == "headYaw" else 1))
                vals.append(v)
        else:
            vals = []
            for i in range(n):
                t = i / rate
                v = 0.05 + rng.gauss(0, jitter)
                if lively and c in MOVING:
                    v += 0.12 * (1 + math.sin(2 * math.pi * 1.0 * t + sum(map(ord, c)) % 7))
                vals.append(min(1.0, max(0.0, v)))
        cols[c] = vals
    for sm in smiles:
        start, dur, left, right = sm[:4]
        cheek = sm[4] if len(sm) > 4 else None
        for i in _span(start, dur, rate):
            if i < n:
                cols["mouthSmileLeft"][i] = left
                cols["mouthSmileRight"][i] = right
                if cheek is not None:
                    for c in ("cheekSquintLeft", "cheekSquintRight"):
                        if c in cols:
                            cols[c][i] = cheek
    for start, dur in blinks:
        for i in _span(start, dur, rate):
            if i < n:
                cols["eyeBlinkLeft"][i] = 0.9
                cols["eyeBlinkRight"][i] = 0.85
    for start, dur in look_down:
        for i in _span(start, dur, rate):
            for c in ("eyeLookDownLeft", "eyeLookDownRight"):
                if c in cols and i < n:
                    cols[c][i] = 0.5
    for spans, pair in ((lip_down, ("mouthFrownLeft", "mouthFrownRight")),
                        (lip_press, ("mouthPressLeft", "mouthPressRight"))):
        for start, dur in spans:
            for i in _span(start, dur, rate):
                for c in pair:
                    if c in cols and i < n:
                        cols[c][i] = 0.5
    if marker and "noseSneerLeft" in cols:
        cols["noseSneerLeft"] = [MARKER] * n
    tracked = [1] * n
    for start, dur in untracked:
        for i in _span(start, dur, rate):
            if i < n:
                tracked[i] = 0
    raw = {"rate_hz": rate, "channels": channels,
           "samples": [[round(cols[c][i], 7) for c in channels] for i in range(n)]}
    if untracked:
        raw["tracked"] = tracked
    if moments_ms is not None:
        raw["moments_ms"] = list(moments_ms)
    return raw
