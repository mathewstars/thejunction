"""The session reading (level 2) of a focus or breathing activity that carries
a face summary. The parts that are pure code:

- the outbound pack content: this session's numbers and a handful of the
  person's earlier sessions of the same type, by relative position only
  (-1, -2, ...). No ids, no dates, no time of day, never any typed text.
- verify(): every claim the model makes is checked against code's own
  own-normal calculation (the z values stored with each session); what code
  cannot confirm is dropped and logged
- the one plain line the patient may see: neutral, never about mood or face

The gates in gates.py call into this module; the engine runs it in the
background. With level 2 off the code-only path stands.
"""

from __future__ import annotations

from .activities import game_kind, played_to_the_end

REACTIONS = ("steady", "slower", "faster", "unclear")
EXPRESSION = ("as_usual", "less_expressive", "more_expressive", "unclear")
EYES = ("as_usual", "looking_down_more", "blinking_less", "blinking_more", "unclear")
COMPARED = ("similar", "lower", "higher", "unclear")
CONFIDENCE = ("low", "medium", "high")
CLAIMS = tuple(x for x in REACTIONS + EXPRESSION + EYES + COMPARED if x != "unclear")
EARLIER_MAX = 5
CLEAR_Z = 1.0  # a claim of change needs |z| >= this against own normal

# Numbers a pack may carry per session (and the evidence may name).
VALUE_FIELDS = ("median_reaction_ms", "reaction_spread_ms", "error_rate", "time_played_s",
                "smile_rate_per_min", "smile_intensity", "facial_activity", "blink_rate_per_min",
                "look_down_share", "head_tilt_deg", "tracking_quality")

# What the patient may see: one neutral line per type. Never a mood, a face or a score.
PATIENT_LINES = {
    "focus": "Thanks for playing Revontulet with me.",
    "breathing": "Thanks for breathing with me.",
}


def applies(rec: dict) -> bool:
    return rec.get("type") in ("focus", "breathing") and rec.get("face") is not None


def _r(x, nd: int = 2):
    if x is None:
        return None
    return round(float(x), nd)


def session_values(rec: dict) -> dict:
    """One session as the model may see it. Built from scratch, allowlist only."""
    f = rec.get("features") or {}
    face = rec.get("face") or {}
    out: dict = {"type": rec["type"], "finished": played_to_the_end(rec)}
    if rec["type"] == "focus":
        out.update(median_reaction_ms=_r(f.get("median_reaction_ms"), 0),
                   reaction_spread_ms=_r(f.get("reaction_spread_ms"), 0),
                   error_rate=_r(f.get("error_rate")))
    else:
        out["time_played_s"] = _r(f.get("time_played_s"), 0)
    for k in ("smile_rate_per_min", "smile_intensity", "facial_activity", "blink_rate_per_min",
              "look_down_share", "head_tilt_deg", "tracking_quality"):
        out[k] = _r(face.get(k))
    return {k: v for k, v in out.items() if v is not None}


def earlier_sessions(rec: dict, previous: list[dict]) -> list[dict]:
    # like with like: a game with its measures is never set beside one sent without them
    same = [p for p in previous if game_kind(p) == game_kind(rec)
            and p["started_at"] < rec["started_at"] and p.get("face_quality") == "good"]
    return same[-EARLIER_MAX:]


def build_payload(rec: dict, earlier: list[dict], alias: str) -> dict:
    n = len(earlier)
    return {"alias": alias, "session": session_values(rec),
            "earlier": [{"position": i - n, **session_values(p)} for i, p in enumerate(earlier)]}


# ---- verify -------------------------------------------------------------------------

def _dir(z: float | None) -> str | None:
    if z is None:
        return None
    return "up" if z >= CLEAR_Z else "down" if z <= -CLEAR_Z else "flat"


def _reactions_ok(claim: str, rec: dict) -> tuple[bool, str]:
    if rec["type"] != "focus":
        return False, "no_reaction_data"
    d = _dir((rec.get("z") or {}).get("median_reaction_ms"))
    if d is None:
        return False, "no_own_baseline"
    return {"slower": d == "up", "faster": d == "down", "steady": d == "flat"}[claim], \
        "own_baseline_disagrees"


def _face_z(rec: dict) -> dict:
    return rec.get("face_z") or {} if rec.get("face_quality") == "good" else {}


def _expression_ok(claim: str, rec: dict) -> tuple[bool, str]:
    fz = _face_z(rec)
    ds = [_dir(fz.get(k)) for k in ("facial_activity", "smile_rate_per_min")]
    ds = [d for d in ds if d is not None]
    if not ds:
        return False, "no_face_baseline" if rec.get("face_quality") == "good" else "face_quality_low"
    ok = {"less_expressive": "down" in ds and "up" not in ds,
          "more_expressive": "up" in ds and "down" not in ds,
          "as_usual": all(d == "flat" for d in ds)}[claim]
    return ok, "own_baseline_disagrees"


def _eyes_ok(claim: str, rec: dict) -> tuple[bool, str]:
    fz = _face_z(rec)
    look, blink = _dir(fz.get("look_down_share")), _dir(fz.get("blink_rate_per_min"))
    if look is None and blink is None:
        return False, "no_face_baseline" if rec.get("face_quality") == "good" else "face_quality_low"
    ok = {"looking_down_more": look == "up", "blinking_less": blink == "down",
          "blinking_more": blink == "up",
          "as_usual": look in (None, "flat") and blink in (None, "flat")}[claim]
    return ok, "own_baseline_disagrees"


def energy(rec: dict) -> float | None:
    """Code's own summary: faster, more expressive, longer = higher."""
    z, fz = rec.get("z") or {}, _face_z(rec)
    parts = []
    if z.get("median_reaction_ms") is not None:
        parts.append(-z["median_reaction_ms"])
    if z.get("time_played_s") is not None:
        parts.append(z["time_played_s"])
    for k in ("facial_activity", "smile_rate_per_min"):
        if fz.get(k) is not None:
            parts.append(fz[k])
    return sum(parts) / len(parts) if parts else None


def _compared_ok(claim: str, rec: dict) -> tuple[bool, str]:
    e = energy(rec)
    if e is None:
        return False, "no_own_baseline"
    d = _dir(e)
    return {"lower": d == "down", "higher": d == "up", "similar": d == "flat"}[claim], \
        "own_baseline_disagrees"


def _from_ok(k: int, kept: dict, rec: dict, earlier: list[dict]) -> bool:
    """The change starts at earlier session k: from k on every session shows
    it (by code's z), and the session before k does not."""
    if not -len(earlier) <= k <= -1:
        return False
    if kept["reactions"] == "slower":
        test = lambda r: _dir((r.get("z") or {}).get("median_reaction_ms")) == "up"  # noqa: E731
    elif kept["expression"] == "less_expressive":
        test = lambda r: _expression_ok("less_expressive", r)[0]  # noqa: E731
    elif kept["compared_to_usual"] == "lower":
        test = lambda r: _dir(energy(r)) == "down"  # noqa: E731
    else:
        return False
    run = earlier[len(earlier) + k:] + [rec]
    before = earlier[len(earlier) + k - 1] if len(earlier) + k - 1 >= 0 else None
    return all(test(r) for r in run) and (before is None or not test(before))


def verify(reply: dict, rec: dict, earlier: list[dict]) -> tuple[dict, list[dict]]:
    """Check each claim against code. Returns (kept reading, dropped claims)."""
    kept = dict(reply)
    dropped: list[dict] = []

    def drop(field: str, value, reason: str, blank):
        dropped.append({"field": field, "value": value, "reason": reason})
        kept[field] = blank

    for field, check in (("reactions", _reactions_ok), ("expression", _expression_ok),
                         ("eyes", _eyes_ok), ("compared_to_usual", _compared_ok)):
        if reply[field] != "unclear":
            ok, why = check(reply[field], rec)
            if not ok:
                drop(field, reply[field], why, "unclear")
    k = reply.get("from_session")
    if k is not None and not _from_ok(k, kept, rec, earlier):
        drop("from_session", k, "change_does_not_start_there", None)
    live = {kept["reactions"], kept["expression"], kept["eyes"], kept["compared_to_usual"]} - \
        {"unclear"}
    sent = set(session_values(rec))
    ev_kept = []
    for e in reply.get("evidence", []):
        if e["claim"] not in live:
            dropped.append({"field": "evidence", "value": e["claim"], "reason": "claim_not_kept"})
            continue
        if not e["values"] or any(v not in sent or v not in VALUE_FIELDS for v in e["values"]):
            dropped.append({"field": "evidence", "value": e["claim"], "reason": "unknown_values"})
            continue
        ev_kept.append(e)
    kept["evidence"] = ev_kept
    return kept, dropped
