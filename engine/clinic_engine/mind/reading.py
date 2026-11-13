"""The movement reading of a round (level 2), the parts that are pure code:

- the outbound trace: rotated by a random angle, times in seconds from start
- small trail pictures drawn with the standard library only (zlib PNG)
- verify(): every claim the model makes is checked against features code
  computes from the same round; what code cannot confirm is dropped
- the one plain line the patient sees, picked by pattern from a fixed set

The gates in gates.py call into this module.
"""

from __future__ import annotations

import math
import secrets
import struct
import zlib

from .rounds import FAR_M, HIGH_M, LOW_M, fade_of, features, light_rows, turning_of

PATTERNS = ("steady", "slowing", "stop_start", "hesitant_start", "rushed", "minimal_movement", "unclear")
REACH = ("full", "avoids_high", "avoids_low", "avoids_far", "unclear")
TURNING = ("both", "mostly_left", "mostly_right", "little", "unclear")
COMPARED = ("similar", "smaller", "slower", "smaller_and_slower", "larger", "faster", "unclear")
CONFIDENCE = ("low", "medium", "high")

PATIENT_LINES = {
    "steady": "A steady round. Nicely done.",
    "slowing": "You kept going to the end. That counts.",
    "stop_start": "A round with pauses is still a round.",
    "hesitant_start": "Starting is the hardest part, and you did it.",
    "rushed": "Lots of energy in that round.",
    "minimal_movement": "Even a small round counts.",
    "unclear": "Thanks for playing today.",
}

_rng = secrets.SystemRandom()


# ---- outbound trace -------------------------------------------------------------

def _r1(x: float | None) -> float | None:
    return None if x is None else round(x, 1)


def trace(r: dict) -> dict:
    """One round as the model may see it. Built from scratch, allowlist only."""
    angle = _rng.uniform(0, 2 * math.pi)
    c, s = math.cos(angle), math.sin(angle)
    out = {
        "mode": r["mode"],
        "duration_s": _r1(r["duration_s"]),
        "lights_total": r["config"]["lights_total"],
        "lights": [{"i": lt["i"], "spawn_s": _r1(lt["spawn_t"]), "dist_m": _r1(lt.get("dist_m")),
                    "height_m": _r1(lt.get("height_m")), "first_move_s": _r1(lt.get("first_move_t")),
                    "end_s": _r1(lt.get("end_t")), "caught": bool(lt["caught"])}
                   for lt in sorted(r["lights"], key=lambda x: x["i"])],
    }
    if r.get("path"):
        out["path"] = {"hz": r["path"]["hz"],
                       "points": [[_r1(x * c - z * s), _r1(x * s + z * c), _r1(y)]
                                  for x, z, y in r["path"]["points"]]}
    return out


# ---- trail picture (no image library) ------------------------------------------------

def trail_png(points: list[list[float]], size: int = 96) -> bytes:
    """Draw the path seen from above as a small grey-scale PNG."""
    img = bytearray([255] * size * size)
    if len(points) >= 2:
        xs, zs = [p[0] for p in points], [p[1] for p in points]
        span = max(max(xs) - min(xs), max(zs) - min(zs), 0.5)
        k = (size - 9) / span

        def px(p):
            return int(4 + (p[0] - min(xs)) * k), int(4 + (p[1] - min(zs)) * k)

        for a, b in zip(points, points[1:]):
            (x0, y0), (x1, y1) = px(a), px(b)
            n = max(abs(x1 - x0), abs(y1 - y0), 1)
            for t in range(n + 1):
                x = x0 + (x1 - x0) * t // n
                y = y0 + (y1 - y0) * t // n
                img[y * size + x] = 0
    raw = b"".join(b"\x00" + bytes(img[y * size:(y + 1) * size]) for y in range(size))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


# ---- verify every claim ----------------------------------------------------------------

def _rate(rows: list[dict]) -> float | None:
    return sum(1 for x in rows if x["caught"]) / len(rows) if rows else None


def _reach_ok(claim: str, rows: list[dict], feat: dict) -> tuple[bool, str]:
    if claim == "full":
        return (feat["caught_share"] or 0) >= 0.8, "catch_rate_below_0.8"
    if claim == "avoids_high":
        group = [x for x in rows if x["height_m"] is not None and x["height_m"] >= HIGH_M]
    elif claim == "avoids_low":
        group = [x for x in rows if x["height_m"] is not None and x["height_m"] <= LOW_M]
    else:
        group = [x for x in rows if x["dist_m"] is not None and x["dist_m"] >= FAR_M]
    other = [x for x in rows if x not in group]
    if len(group) < 2 or not other:
        return False, "too_few_lights_in_band"
    g, o = _rate(group), _rate(other)
    return (g <= 0.5 and o - g >= 0.25), "catch_rate_does_not_differ"


def _pattern_ok(claim: str, r: dict, rows: list[dict], feat: dict) -> tuple[bool, str]:
    fade = feat["fade"]
    if claim == "steady":
        ok = fade is not None and 0.8 <= fade <= 1.25 and (feat["still_share"] or 0) < 0.4
        return ok, "speed_not_steady"
    if claim == "slowing":
        return fade is not None and fade <= 0.85, "no_fade_in_speeds"
    if claim == "stop_start":
        return (feat["still_share"] or 0) >= 0.25, "few_pauses_in_path"
    if claim == "hesitant_start":
        rt = [x["reaction_s"] for x in rows]
        if len(rt) < 5 or any(v is None for v in rt[:3]):
            return False, "too_few_lights"
        from statistics import median
        rest = [v for v in rt[3:] if v is not None]
        return bool(rest) and median(rt[:3]) >= 1.5 * median(rest), "start_not_slower"
    if claim == "rushed":
        return feat["median_reaction_s"] is not None and feat["median_reaction_s"] <= 0.6, \
            "reaction_not_fast"
    if claim == "minimal_movement":
        pl, cov = feat.get("path_length_m"), feat["coverage"]
        return (pl is not None and pl < 3.0) or (cov is not None and cov < 0.1), "path_not_small"
    return True, ""


def _compared_ok(claim: str, z: dict) -> tuple[bool, str]:
    if not z:
        return False, "no_own_baseline"
    cov = min(z.get("coverage", 0), z.get("vertical_range_m", 0))
    cov_hi = z.get("coverage", 0)
    slow = z.get("median_speed_m_s", 0) <= -1 or z.get("median_reaction_s", 0) >= 1
    fast = z.get("median_speed_m_s", 0) >= 1 or z.get("median_reaction_s", 0) <= -1
    smaller, larger = cov <= -1, cov_hi >= 1
    ok = {"smaller": smaller, "slower": slow, "smaller_and_slower": smaller and slow,
          "larger": larger, "faster": fast,
          "similar": not (smaller or larger or slow or fast)}[claim]
    return ok, "own_baseline_disagrees"


def verify(reply: dict, r: dict) -> tuple[dict, list[dict]]:
    """Check each claim against code. Returns (kept reading, dropped claims)."""
    rows = light_rows(r)
    feat = r.get("features") or features(r)
    z = r.get("z") or {}
    kept = dict(reply)
    dropped: list[dict] = []

    def drop(field: str, value, reason: str, blank):
        dropped.append({"field": field, "value": value, "reason": reason})
        kept[field] = blank

    if reply["pattern"] != "unclear":
        ok, why = _pattern_ok(reply["pattern"], r, rows, feat)
        if not ok:
            drop("pattern", reply["pattern"], why, "unclear")
    k = reply.get("fade_from_light")
    if k is not None:
        f = fade_of(rows, start=k) if any(x["i"] == k for x in rows) else None
        ok = f is not None and f <= 0.85
        if ok:
            # The slowing must start AT light k: the first lights from k on are
            # already slower than the median before k.
            from statistics import median
            before = [x["speed_m_s"] for x in rows if x["i"] < k and x["speed_m_s"] is not None]
            after = [x["speed_m_s"] for x in rows if x["i"] >= k and x["speed_m_s"] is not None][:2]
            ok = bool(before and after) and all(v <= 0.85 * median(before) for v in after)
        if not ok:
            drop("fade_from_light", k, "speeds_do_not_drop_there", None)
    if reply["reach"] != "unclear":
        ok, why = _reach_ok(reply["reach"], rows, feat)
        if not ok:
            drop("reach", reply["reach"], why, "unclear")
    if reply["turning"] != "unclear":
        label = (r.get("turning") or turning_of(r))["label"]
        if not (label == reply["turning"] or (reply["turning"] == "both" and label != "little")):
            drop("turning", reply["turning"], "path_turns_differently", "unclear")
    if reply["compared_to_usual"] != "unclear":
        ok, why = _compared_ok(reply["compared_to_usual"], z)
        if not ok:
            drop("compared_to_usual", reply["compared_to_usual"], why, "unclear")
    # Evidence: the claim must still stand, and the lights must exist and fit.
    indices = {x["i"] for x in rows}
    live = {kept["pattern"], kept["reach"], kept["turning"], kept["compared_to_usual"]} - {"unclear"}
    ev_kept = []
    for e in reply.get("evidence", []):
        if e["claim"] not in live:
            dropped.append({"field": "evidence", "value": e["claim"], "reason": "claim_not_kept"})
            continue
        if not e["lights"] or any(i not in indices for i in e["lights"]):
            dropped.append({"field": "evidence", "value": e["claim"], "reason": "unknown_lights"})
            continue
        if e["claim"] == "avoids_high" and any(
                (next(x for x in rows if x["i"] == i)["height_m"] or 0) < HIGH_M for i in e["lights"]):
            dropped.append({"field": "evidence", "value": e["claim"], "reason": "lights_not_high"})
            continue
        ev_kept.append(e)
    kept["evidence"] = ev_kept
    return kept, dropped
