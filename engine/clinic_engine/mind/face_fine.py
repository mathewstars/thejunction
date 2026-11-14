"""Fine facial movement: a research signal beside the ARKit blend shapes.

The TrueDepth camera gives an app the fitted face mesh and the depth map. Both
are the shape of a face, so they never leave the phone. What the phone sends
instead (docs/face-fine.md) is, for a few named regions and for every frame,
how far that region is from the person's own resting shape after the head's
movement is taken out, in millimetres. Numbers only.

This module checks such a stream and sums it up. It describes movement and
nothing else: no mood, no symptom. One rule reads one number of it: the
watcher for "less facial movement" compares the reach over the last five
sessions with the person's own usual (mind/activities.fine_recent, since 15
November 2026). No model reads it. The summary is kept beside the activity
(docs/research-proposal.md, "A finer signal we would try next"), and
the stream is stored as its own object so that the summary can be computed
again when these rules change.

The thresholds below are first guesses. They have not been set on recordings
of people; the noise floor of the sensor has to be measured first.
"""

from __future__ import annotations

import bisect
import math

RULES_VERSION = 4   # 2: the top of a slow, small expression is no longer a brief movement
#                     3: brief movements of the mouth corners, by side (mouth_corners)
#                     4: after the first seven real games: the noise is measured from the
#                        stream itself (the phone's figure was 50 to 200 times the real
#                        jitter), the frames just after tracking returns are left out, and
#                        a slow creep of the level is taken out before anything is measured

# The regions a phone may name. A fixed list, so that no free text arrives.
REGIONS = ("mouth_left", "mouth_right", "lip_upper", "lip_lower", "cheek_left", "cheek_right",
           "brow_left", "brow_right", "eyelid_left", "eyelid_right", "jaw", "nose",
           "mouth_corner_left", "mouth_corner_right")
REQUIRED_REGIONS = ("mouth_left", "mouth_right")
PAIRS = (("mouth_left", "mouth_right"), ("mouth_corner_left", "mouth_corner_right"),
         ("cheek_left", "cheek_right"),
         ("brow_left", "brow_right"), ("eyelid_left", "eyelid_right"))

MAX_SAMPLES = 12000
MAX_MM = 50.0            # a region further than this from rest is not a face movement
MIN_TRACKED_S = 5.0      # less tracked time: every measure null
DEFAULT_NOISE_MM = 0.3   # used when the phone did not measure its own noise floor
NOISY_ABOVE_MM = 1.0     # a noise floor above this marks the stream "noisy"
NOISE_MIN_STEPS = 30     # fewer frame-to-frame steps: the noise cannot be measured from the stream
REGAIN_SKIP_S = 0.34     # frames left out after tracking returns: the mesh jumps there
LEVEL_WINDOW_S = 10.0    # the level a region is measured from: its median over this long around each moment
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


def kept(raw: dict) -> list[int]:
    """The frames that are measured: tracked, and not within REGAIN_SKIP_S after
    tracking came back."""
    tracked = raw.get("tracked")
    n = len(raw["samples"])
    if tracked is None:
        return list(range(n))
    skip = max(1, int(round(REGAIN_SKIP_S * float(raw["rate_hz"]))))
    out, wait = [], 0
    for i in range(n):
        if not tracked[i]:
            wait = skip
        elif wait > 0 and i > 0:
            wait -= 1
        else:
            out.append(i)
    return out


def measured_noise(raw: dict, keep: list[int] | None = None) -> float | None:
    """The noise floor read from the stream itself: per region, how much the
    number jumps from one frame to the next (a robust spread of the steps,
    brought to the scale of one frame), averaged over the regions. Movements
    are rare among the steps, so they do not raise it. None with too few steps.

    Noise that is smooth from frame to frame reads smaller here than it is;
    the twitch rule's fixed floor of TWITCH_FLOOR_MM covers that case."""
    keep = kept(raw) if keep is None else keep
    pairs = [(a, b) for a, b in zip(keep, keep[1:]) if b == a + 1]
    if len(pairs) < NOISE_MIN_STEPS:
        return None
    spreads = []
    for j in range(len(raw["regions"])):
        d = sorted(raw["samples"][b][j] - raw["samples"][a][j] for a, b in pairs)
        mid = _pct(d, 0.5)
        mad = _pct(sorted(abs(v - mid) for v in d), 0.5)
        spreads.append(1.4826 * mad / math.sqrt(2))
    return round(sum(spreads) / len(spreads), 3)


def noise_of(raw: dict, keep: list[int] | None = None) -> float:
    """The noise the rules use: measured from the stream when it can be, else
    what the phone stated, else the default."""
    m = measured_noise(raw, keep)
    if m is not None:
        return m
    stated = raw.get("noise_mm")
    return DEFAULT_NOISE_MM if stated is None else float(stated)


def _flatten(y: list[float], rate: float) -> list[float]:
    """The series with its slow level taken out and its own median put back:
    at each frame the median over LEVEL_WINDOW_S around it. A creep over the
    session or a step when the phone shifts no longer counts as movement;
    anything shorter than half the window stays."""
    n = len(y)
    half = int(round(LEVEL_WINDOW_S * rate / 2))
    if n <= 2 * half:
        return list(y)
    overall = _pct(sorted(y), 0.5)
    window = sorted(y[:half + 1])
    out = []
    for i in range(n):
        if i > 0:
            if i + half < n:
                bisect.insort(window, y[i + half])
            if i - half - 1 >= 0:
                del window[bisect.bisect_left(window, y[i - half - 1])]
        m = len(window)
        lvl = window[m // 2] if m % 2 else (window[m // 2 - 1] + window[m // 2]) / 2
        out.append(max(0.0, y[i] - lvl + overall))
    return out


def _twitch_runs(y: list[float], rate: float, noise: float) -> tuple[float, list[tuple[int, int]]]:
    """The region's usual level and its brief excursions as (first frame, frames)."""
    level = _pct(sorted(y), 0.5)
    floor = max(TWITCH_FLOOR_MM, TWITCH_NOISE_FACTOR * noise)
    max_frames = max(2, int(round(TWITCH_MAX_S * rate)))
    out = []
    for first, n in _runs([v > level + floor for v in y]):
        if not 2 <= n <= max_frames:
            continue
        # The whole rise must be brief too: measured at half the height, it may last
        # at most twice as long. Otherwise this is the top of a slow, small
        # expression that only just crossed the line.
        half = level + floor / 2
        a, b = first, first + n - 1
        while a > 0 and y[a - 1] > half:
            a -= 1
        while b < len(y) - 1 and y[b + 1] > half:
            b += 1
        if b - a + 1 <= 2 * max_frames:
            out.append((first, n))
    return level, out


def _region(x: list[float], rate: float, noise: float) -> dict:
    y = _flatten(_median3(x), rate)
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
    keep = kept(raw)
    noise = noise_of(raw, keep)
    out = []
    for j, name in enumerate(raw["regions"]):
        y = _flatten(_median3([raw["samples"][i][j] for i in keep]), rate)
        level, runs = _twitch_runs(y, rate, noise)
        for first, n in runs:
            out.append({"region": name, "start_s": round(keep[first] / rate, 2),
                        "end_s": round((keep[first + n - 1] + 1) / rate, 2),
                        "peak_mm": round(max(y[first:first + n]) - level, 2)})
    return sorted(out, key=lambda t: (t["start_s"], t["region"]))


# ---- brief movements of the mouth corners ------------------------------------------------

CORNER_PAIRS = (("mouth_corner_left", "mouth_corner_right"), ("mouth_left", "mouth_right"))
_MOUTH = ("mouth_left", "mouth_right", "mouth_corner_left", "mouth_corner_right",
          "lip_upper", "lip_lower", "jaw")
CORNER_TOGETHER_S = 0.07   # two movements this close in time are the same moment (2 frames at 30)


def _near(a: dict, b: dict) -> bool:
    return a["start_s"] <= b["end_s"] + CORNER_TOGETHER_S and b["start_s"] <= a["end_s"] + CORNER_TOGETHER_S


def mouth_corners(raw: dict, found: list[dict] | None = None) -> dict | None:
    """Brief movements at the two corners of the mouth, each named by its
    side: "left", "right" (the person's own) or "both" when the two corners
    move at the same moment. Uses the corner regions when the phone sends
    them, else the two halves of the mouth.

    A brief movement that most of the rest of the face makes at the same
    moment is not a movement of the mouth: it is a jolt of the whole face
    left over after the head's movement was taken out (or a blink, a sniff,
    the phone). Those are counted apart and not reported as corner movements.
    "Most" is at least half of the regions outside the mouth, and at least two.

    None when the stream has neither pair of regions. Movement only."""
    pair = next((p for p in CORNER_PAIRS if p[0] in raw["regions"] and p[1] in raw["regions"]), None)
    if pair is None:
        return None
    found = twitches(raw) if found is None else found
    others = [r for r in raw["regions"] if r not in _MOUTH]
    need = max(2, math.ceil(len(others) / 2))

    def whole_face(t: dict) -> bool:
        return len({o["region"] for o in found if o["region"] in others and _near(o, t)}) >= need

    left = [t for t in found if t["region"] == pair[0]]
    right = [t for t in found if t["region"] == pair[1]]
    events, dropped, used = [], 0, set()
    for t in left:
        mate = next((k for k, r in enumerate(right) if k not in used and _near(t, r)), None)
        span = [t] if mate is None else [t, right[mate]]
        if mate is not None:
            used.add(mate)
        ev = {"side": "left" if mate is None else "both",
              "start_s": min(x["start_s"] for x in span), "end_s": max(x["end_s"] for x in span),
              "peak_mm": max(x["peak_mm"] for x in span)}
        if whole_face(ev):
            dropped += 1
        else:
            events.append(ev)
    for k, r in enumerate(right):
        if k in used:
            continue
        ev = {"side": "right", "start_s": r["start_s"], "end_s": r["end_s"], "peak_mm": r["peak_mm"]}
        if whole_face(ev):
            dropped += 1
        else:
            events.append(ev)
    return {"regions": list(pair), "events": sorted(events, key=lambda e: e["start_s"]),
            "whole_face_dropped": dropped}


def summarize(raw: dict) -> dict:
    """The summary kept beside the activity. Movement only, per region; null
    wherever there was too little tracked time to say anything."""
    regions, rate = raw["regions"], float(raw["rate_hz"])
    keep = kept(raw)
    rows = [raw["samples"][i] for i in keep]
    tracked_s = len(rows) / rate
    stated = raw.get("noise_mm")
    noise = noise_of(raw, keep)
    share = 1.0 if not raw["samples"] else len(rows) / len(raw["samples"])
    # noise_mm is the noise the rules used (measured from the stream when it can be);
    # noise_stated_mm is what the phone said, kept for comparison.
    out = {"rules": RULES_VERSION, "source": raw["source"], "tracked_s": round(tracked_s, 1),
           "noise_mm": noise, "noise_stated_mm": stated, "regions": {}, "asymmetry": {}}
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
    # The rows left out are gone here, so the corner rule measures the same frames.
    mc = mouth_corners({**raw, "samples": rows, "tracked": None, "noise_mm": noise})
    if mc is not None:
        minutes = tracked_s / 60.0
        n = {side: sum(1 for e in mc["events"] if e["side"] == side) for side in ("left", "right", "both")}
        out["mouth_corners"] = {"regions": mc["regions"], "left": n["left"], "right": n["right"],
                                "both": n["both"], "whole_face_dropped": mc["whole_face_dropped"],
                                "per_min": round(len(mc["events"]) / minutes, 2)}
    return out


# ---- one session beside the person's own earlier sessions (shown only) ---------------------

OWN_MIN_SESSIONS = 3     # fewer earlier sessions: no "usual" is given
HEADLINE = ("reach_mm", "speed_mm_s", "twitches_per_min", "mouth_asymmetry")


def headline(summary: dict | None) -> dict | None:
    """Four numbers for one session: mean reach and mean top speed over the
    regions sent, brief movements per minute over all regions together, and
    the left-right asymmetry of the mouth. None when the session says nothing."""
    if not summary or summary.get("quality") == "short":
        return None
    regs = [r for r in (summary.get("regions") or {}).values() if r]
    if not regs:
        return None
    return {"reach_mm": round(sum(r["reach_mm"] for r in regs) / len(regs), 3),
            "speed_mm_s": round(sum(r["speed_mm_s"] for r in regs) / len(regs), 2),
            "twitches_per_min": round(sum(r["twitches_per_min"] or 0 for r in regs), 2),
            "mouth_asymmetry": (summary.get("asymmetry") or {}).get("mouth")}


def usual(earlier: list[dict]) -> dict:
    """The person's own usual value of each headline number: the median of
    their earlier sessions, or None with fewer than OWN_MIN_SESSIONS of them.
    A description for a reader. The flag has its own comparison, on the
    reach only (mind/activities.fine_recent)."""
    out = {}
    for k in HEADLINE:
        vals = sorted(h[k] for h in earlier if h.get(k) is not None)
        out[k] = round(_pct(vals, 0.5), 3) if len(vals) >= OWN_MIN_SESSIONS else None
    return out
