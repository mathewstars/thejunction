"""Fine facial movement: a research signal beside the ARKit blend shapes.

The TrueDepth camera gives an app the fitted face mesh and the depth map. Both
are the shape of a face, so they never leave the phone. What the phone sends
instead (docs/face-fine.md) is, for a few named regions and for every frame,
how far that region is from the person's own resting shape after the head's
movement is taken out, in millimetres. Numbers only.

This module checks such a stream and sums it up. It describes movement and
nothing else: no mood, no symptom, no flag. Nothing here is used by triage, by
the baseline or by any model. The summary is kept beside the activity for
research (docs/research-proposal.md, "A finer signal we would try next"), and
the stream is stored as its own object so that the summary can be computed
again when these rules change.

The thresholds below are first guesses. They have not been set on recordings
of people; the noise floor of the sensor has to be measured first.
"""

from __future__ import annotations

import math

RULES_VERSION = 1

# The regions a phone may name. A fixed list, so that no free text arrives.
REGIONS = ("mouth_left", "mouth_right", "lip_upper", "lip_lower", "cheek_left", "cheek_right",
           "brow_left", "brow_right", "eyelid_left", "eyelid_right", "jaw", "nose")
REQUIRED_REGIONS = ("mouth_left", "mouth_right")
PAIRS = (("mouth_left", "mouth_right"), ("cheek_left", "cheek_right"),
         ("brow_left", "brow_right"), ("eyelid_left", "eyelid_right"))

MAX_SAMPLES = 12000
MAX_MM = 50.0            # a region further than this from rest is not a face movement
MIN_TRACKED_S = 5.0      # less tracked time: every measure null
DEFAULT_NOISE_MM = 0.3   # used when the phone did not measure its own noise floor
NOISY_ABOVE_MM = 1.0     # a stated noise floor above this marks the stream "noisy"
TWITCH_FLOOR_MM = 0.5    # a twitch rises at least this far above the region's usual level ...
TWITCH_NOISE_FACTOR = 3.0  # ... and at least this many times the noise floor
TWITCH_MAX_S = 0.4       # and is back within this time; anything longer is an expression


def check(raw: dict) -> str | None:
    """A plain message for the first problem found, else None. Never echoes a
    value or a name the client sent: positions only."""
    regions = raw["regions"]
    seen: set[str] = set()
    for i, name in enumerate(regions):
        if name not in REGIONS:
            return f"regions[{i}] is not one of the region names in docs/face-fine.md"
        if name in seen:
            return f"regions[{i}] repeats an earlier region"
        seen.add(name)
    missing = [r for r in REQUIRED_REGIONS if r not in seen]
    if missing:
        return "regions must include " + ", ".join(missing)
    samples = raw["samples"]
    if len(samples) > MAX_SAMPLES:
        return f"at most {MAX_SAMPLES} samples"
    n = len(regions)
    for i, row in enumerate(samples):
        if len(row) != n:
            return f"samples[{i}] must have {n} values, one per region"
        for j, v in enumerate(row):
            if not math.isfinite(v) or v < 0 or v > MAX_MM:
                return f"samples[{i}][{j}] must be a distance from 0 to {MAX_MM:g} mm"
    tracked = raw.get("tracked")
    if tracked is not None and len(tracked) != len(samples):
        return "tracked must have one value per sample"
    return None


def describe(raw: dict) -> dict:
    """Counts only, for the activity record: never a value of the stream."""
    n = len(raw["samples"])
    tracked = raw.get("tracked")
    share = 1.0 if tracked is None or n == 0 else sum(tracked) / n
    return {"source": raw["source"], "rate_hz": raw["rate_hz"], "frames": n,
            "tracked_share": round(share, 3), "regions": len(raw["regions"])}


def _pct(sorted_vals: list[float], q: float) -> float:
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    pos = q * (len(sorted_vals) - 1)
    lo = int(math.floor(pos))
    hi = min(lo + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (pos - lo)


def _median3(x: list[float]) -> list[float]:
    """A running median of three: one bad frame does not make a movement."""
    if len(x) < 3:
        return list(x)
    out = [x[0]]
    for i in range(1, len(x) - 1):
        out.append(sorted(x[i - 1:i + 2])[1])
    out.append(x[-1])
    return out


def _runs(mask: list[bool]) -> list[tuple[int, int]]:
    """Stretches of consecutive true values as (first index, length)."""
    runs, start = [], None
    for i, m in enumerate(mask):
        if m and start is None:
            start = i
        if not m and start is not None:
            runs.append((start, i - start))
            start = None
    if start is not None:
        runs.append((start, len(mask) - start))
    return runs


def _twitch_runs(y: list[float], rate: float, noise: float) -> tuple[float, list[tuple[int, int]]]:
    """The region's usual level and its brief excursions as (first frame, frames)."""
    level = _pct(sorted(y), 0.5)
    floor = max(TWITCH_FLOOR_MM, TWITCH_NOISE_FACTOR * noise)
    max_frames = max(2, int(round(TWITCH_MAX_S * rate)))
    return level, [r for r in _runs([v > level + floor for v in y]) if 2 <= r[1] <= max_frames]


def _region(x: list[float], rate: float, noise: float) -> dict:
    y = _median3(x)
    s = sorted(y)
    level, twitches = _twitch_runs(y, rate, noise)
    reach = _pct(s, 0.95) - level
    steps = sorted(abs(b - a) * rate for a, b in zip(y, y[1:])) or [0.0]
    minutes = len(y) / rate / 60.0
    return {"level_mm": round(level, 3),          # where the region usually sits in this session
            "reach_mm": round(reach, 3),          # how far above that it goes (95th percentile)
            "speed_mm_s": round(_pct(steps, 0.95), 2),   # how fast it moves at its fastest
            "twitches_per_min": round(len(twitches) / minutes, 2) if minutes > 0 else None}


def twitches(raw: dict) -> list[dict]:
    """Every brief movement code finds, with its place in time: what a second
    reader (a model, or a person marking a plot) is compared with. Times are
    seconds from the first frame. Untracked frames are skipped by leaving the
    rows out, as in the summary, so use it on streams that were tracked
    throughout when exact times matter."""
    rate = float(raw["rate_hz"])
    tracked = raw.get("tracked")
    keep = [i for i in range(len(raw["samples"])) if tracked is None or tracked[i]]
    stated = raw.get("noise_mm")
    noise = DEFAULT_NOISE_MM if stated is None else float(stated)
    out = []
    for j, name in enumerate(raw["regions"]):
        y = _median3([raw["samples"][i][j] for i in keep])
        level, runs = _twitch_runs(y, rate, noise)
        for first, n in runs:
            out.append({"region": name, "start_s": round(keep[first] / rate, 2),
                        "end_s": round((keep[first + n - 1] + 1) / rate, 2),
                        "peak_mm": round(max(y[first:first + n]) - level, 2)})
    return sorted(out, key=lambda t: (t["start_s"], t["region"]))


def summarize(raw: dict) -> dict:
    """The summary kept beside the activity. Movement only, per region; null
    wherever there was too little tracked time to say anything."""
    regions, rate = raw["regions"], float(raw["rate_hz"])
    tracked = raw.get("tracked")
    rows = [r for i, r in enumerate(raw["samples"]) if tracked is None or tracked[i]]
    tracked_s = len(rows) / rate
    stated = raw.get("noise_mm")
    noise = DEFAULT_NOISE_MM if stated is None else float(stated)
    share = 1.0 if not raw["samples"] else len(rows) / len(raw["samples"])
    out = {"rules": RULES_VERSION, "source": raw["source"], "tracked_s": round(tracked_s, 1),
           "noise_mm": stated, "regions": {}, "asymmetry": {}}
    if tracked_s < MIN_TRACKED_S:
        out["quality"] = "short"
        out["regions"] = {name: None for name in regions}
        return out
    out["quality"] = ("noisy" if noise > NOISY_ABOVE_MM else "good" if share >= 0.9 else "partly")
    for j, name in enumerate(regions):
        out["regions"][name] = _region([r[j] for r in rows], rate, noise)
    for left, right in PAIRS:
        a, b = out["regions"].get(left), out["regions"].get(right)
        if a and b and a["reach_mm"] + b["reach_mm"] > 0:
            # -1: only the right side moves; 0: both alike; +1: only the left side moves.
            out["asymmetry"][left.rsplit("_", 1)[0]] = round(
                (a["reach_mm"] - b["reach_mm"]) / (a["reach_mm"] + b["reach_mm"]), 3)
    return out
