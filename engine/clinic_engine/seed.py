"""Demo seed: one clinic, one clinician, one patient with a paired device,
plus mock example records. Everything generated here is flagged example.

    python -m clinic_engine.seed            # create the demo (refuses if it exists)
    python -m clinic_engine.seed --reset    # wipe the demo patient's data and regenerate
    python -m clinic_engine.seed --extra 3  # also add 3 example patients

Tokens and the password are printed ONCE. Nothing secret is written to disk
in clear text.
"""

from __future__ import annotations

import argparse
import asyncio
import copy
import math
from functools import lru_cache
import os
import random
import secrets
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from .config import Settings
from .mind.round_configs import ROUND_CONFIGS
from .mind.rounds import layout_seed, process_round
from .security import hash_password, issue_token, new_id, sha256_hex
from .store import Store, make_store

DEMO_LABEL = "Patient A-014"
# Invented example names, shown only on the clinician page.
DEMO_DISPLAY_NAME = "Anna Korhonen"
EXTRA_DISPLAY_NAMES = ("Mikko Laine", "Sofia Rantanen", "Jari Heikkinen", "Elina Peltonen", "Tomas Virtanen")
DIP_DAYS = 5


# ---- records ---------------------------------------------------------------------------

def create_clinic(store: Store, name: str, now: datetime) -> str:
    cid = new_id("clinic")
    store.put(f"clinics/{cid}/clinic.json", {"id": cid, "name": name, "created_at": now.isoformat()})
    return cid


def create_clinician(store: Store, clinic_id: str, username: str, password: str,
                     now: datetime) -> str:
    uid = new_id("clin")
    store.put(f"clinics/{clinic_id}/clinicians/{uid}.json", {
        "id": uid, "clinic_id": clinic_id, "username_sha256": sha256_hex(username.lower()),
        "password_hash": hash_password(password), "created_at": now.isoformat()})
    store.put(f"usernames/{sha256_hex(username.lower())}.json",
              {"clinic_id": clinic_id, "clinician_id": uid})
    return uid


def create_patient(store: Store, clinic_id: str, label: str, tz: str, now: datetime,
                   example: bool, allow_outside: bool = False, share_notes: bool = False,
                   display_name: str | None = None) -> str:
    """`label` is the clinic's code for the person; it is what an alert carries.
    `display_name` is optional, set by the clinic, and shown only on the clinician page
    behind its login. It never goes into an alert, a model pack or a log."""
    pid = new_id("pat")
    store.put(f"clinics/{clinic_id}/patients/{pid}/patient.json", {
        "id": pid, "clinic_id": clinic_id, "label": label, "display_name": display_name,
        "timezone": tz, "example": example,
        "allow_outside_processing": allow_outside, "share_notes": share_notes,
        "created_at": now.isoformat()})
    store.put(f"patients/{pid}.json", {"clinic_id": clinic_id, "patient_id": pid})
    return pid


def pair_device_direct(store: Store, clinic_id: str, patient_id: str, label: str,
                       now: datetime) -> str:
    dev = new_id("dev")
    store.put(f"clinics/{clinic_id}/patients/{patient_id}/devices/{dev}.json",
              {"id": dev, "label": label, "platform": "ios", "created_at": now.isoformat(),
               "example": True})
    return issue_token(store, "device", clinic_id=clinic_id, patient_id=patient_id,
                       device_id=dev, now=now)


# ---- example data generators ------------------------------------------------------------

def _day_values(rng: random.Random, d, factor: float = 1.0) -> dict:
    weekend = d.weekday() >= 5
    steps = rng.gauss(7600 if not weekend else 6200, 650) * factor
    return {"date": d.isoformat(), "steps": int(max(300, steps)),
            "walking_speed_m_s": round(rng.gauss(1.27, 0.025) * (0.85 + 0.15 * factor), 3),
            "hrv_ms": round(rng.gauss(46, 3.5) * (0.8 + 0.2 * factor), 1),
            "sleep_h": round(rng.gauss(7.2, 0.4), 2), "example": True, "source": "seed",
            "received_at": datetime.combine(d, time(21, 0), tzinfo=timezone.utc).isoformat()}


def write_history(store: Store, clinic_id: str, patient_id: str, today, seed: int,
                  days: int = 28, shaped: dict | None = None) -> None:
    """28 plausible days ending today. `shaped` maps day offset -> factor."""
    rng = random.Random(seed)
    base = f"clinics/{clinic_id}/patients/{patient_id}/days/"
    for k in range(days - 1, -1, -1):
        d = today - timedelta(days=k)
        factor = (shaped or {}).get(-k, 1.0)
        store.put(base + f"{d.isoformat()}.json", _day_values(rng, d, factor))


def apply_scenario(store: Store, clinic_id: str, patient_id: str, today, name: str,
                   seed: int) -> None:
    """dip: the most recent days become a clear sustained drop. normal: restore."""
    rng = random.Random(seed + 7)
    base = f"clinics/{clinic_id}/patients/{patient_id}/days/"
    for k in range(DIP_DAYS - 1, -1, -1):
        d = today - timedelta(days=k)
        factor = (0.42 + rng.uniform(-0.05, 0.05)) if name == "dip" else 1.0
        store.put(base + f"{d.isoformat()}.json", _day_values(rng, d, factor))


def make_round(rng: random.Random, rid: str, started: datetime, power: float, patient_id: str,
               mode: str = "standing", fade: float = 0.0, ended_by: str = "finished") -> dict:
    """A plausible round. power 1.0 = usual; fade > 0 slows the second half."""
    cfg = "standard" if mode == "standing" else "seated_gentle"
    total = ROUND_CONFIGS[cfg]["lights_total"]
    lights, t = [], 2.0
    for i in range(total):
        f = power * (1 - fade * i / total)
        dist = rng.uniform(1.0, 2.4) if mode == "standing" else rng.uniform(0.3, 0.7)
        height = rng.uniform(0.5, 1.8) if mode == "standing" else rng.uniform(0.6, 1.2)
        reaction = max(0.2, rng.gauss(0.8, 0.1) / max(f, 0.2))
        travel = dist / max(0.15, rng.gauss(0.7, 0.05) * f)
        caught = travel < 7.5 and not (height > 1.6 and power < 0.8 and rng.random() < 0.7)
        fm = t + reaction
        end = min(fm + travel, t + 8.0)
        lights.append({"i": i, "spawn_t": round(t, 1), "dist_m": round(dist, 1),
                       "height_m": round(height, 1), "first_move_t": round(fm, 1),
                       "end_t": round(end, 1), "caught": caught})
        t = end + 1.0
    duration = round(min(t + 1.0, 130.0), 1)
    points, x, z, y = [], 0.0, 0.0, 0.0
    tx, tz = rng.uniform(-1.5, 1.5), rng.uniform(-1.5, 1.5)
    n = min(240, int(duration * 2))
    for k in range(n):
        if math.hypot(tx - x, tz - z) < 0.3:
            tx, tz = rng.uniform(-1.5, 1.5) * power, rng.uniform(-1.5, 1.5) * power
        step = 0.35 * power * (1 - fade * k / n)
        ang = math.atan2(tz - z, tx - x)
        x, z = x + step * math.cos(ang), z + step * math.sin(ang)
        y = 0.25 * power * math.sin(k / 5.0)
        points.append([round(x, 1), round(z, 1), round(y, 1)])
    rec = {
        "id": rid, "schema": 2, "suggestion_id": None, "started_at": started.isoformat(),
        "duration_s": duration, "mode": mode, "completed": ended_by == "finished",
        "ended_by": ended_by,
        "config": {"config_id": cfg, "layout_seed": layout_seed(patient_id, cfg),
                   "lights_total": total},
        "tracking": {"normal_ratio": 0.95, "limited_reasons": [], "play_area_m2": 9.0,
                     "light": "ok", "lidar": False},
        "lights": lights, "path": {"hz": 2, "points": points},
    }
    if mode == "screen":
        rec["path"] = None
    return rec


def write_rounds(store: Store, clinic_id: str, patient_id: str, today, tz: ZoneInfo, seed: int,
                 dip: bool = False) -> None:
    rng = random.Random(seed + 99)
    base = f"clinics/{clinic_id}/patients/{patient_id}/rounds/"
    for key in store.list(base):
        if (store.get(key) or {}).get("example"):
            store.delete(key)
    previous: list[dict] = []
    offsets = [-27, -24, -21, -18, -15, -12, -9, -6, -3, -1]
    for n, off in enumerate(offsets):
        weak = dip and off >= -3
        started = datetime.combine(today + timedelta(days=off), time(10, 30), tzinfo=tz)
        r = make_round(rng, f"example-round-{n:02d}", started.astimezone(timezone.utc),
                       0.55 if weak else rng.uniform(0.95, 1.05), patient_id,
                       fade=0.45 if weak else 0.0)
        rec = process_round(r, previous)
        rec.update(example=True, received_at=r["started_at"], analysis={"status": "off"})
        store.put(base + f"{rec['id']}.json", rec)
        previous.append(rec)


def write_example_suggestions(store: Store, clinic_id: str, patient_id: str, today,
                              tz: ZoneInfo) -> dict:
    """Earlier episodes, so the mind has something to learn from:
    breathing with Lanvi was done three times and the next days went up;
    a walk was offered three times and not done. Returns day-shape factors."""
    base = f"clinics/{clinic_id}/patients/{patient_id}/"
    shaped = {}
    plan = [(-22, "breathing", "did_it", "good"), (-21, "walk_10min", "not_today", None),
            (-18, "breathing", "did_it", "ok"), (-17, "walk_10min", "not_today", None),
            (-14, "breathing", "did_it", "good"), (-13, "walk_10min", "not_today", None)]
    from .mind.catalog import ACTIONS
    for off, action, answer, felt in plan:
        d = today + timedelta(days=off)
        created = datetime.combine(d, time(10, 0), tzinfo=tz).astimezone(timezone.utc)
        sid = new_id("sug")
        store.put(base + f"suggestions/{sid}.json", {
            "id": sid, "action": action, "text": ACTIONS[action].template, "wording": "template",
            "created_at": created.isoformat(), "date": d.isoformat(), "status": "answered",
            "attention_ids": [], "attention_kind": "example", "answer": answer, "felt": felt,
            "round_completed": False, "played": answer == "did_it", "example": True,
            "line_id": action + ".1",
            "resolved_at": (created + timedelta(hours=2)).isoformat()})
        if action == "breathing":
            shaped[off] = 0.8
            shaped[off + 1] = 1.12
            shaped[off + 2] = 1.12
    return shaped


# Two weeks of example activities: (day offset, local time, type, how it went).
# Focus in the morning is mostly stopped early (so a lesson can be learned);
# breathing in the evening is finished; check-ins most evenings.
ACTIVITY_PLAN = [
    (-13, "21:00", "breathing", "finished"),
    (-12, "21:30", "checkin", "walk"),
    (-11, "09:10", "focus", "user_stopped"),
    (-10, "21:00", "breathing", "finished"),
    (-9, "09:20", "focus", "user_stopped"), (-9, "21:30", "checkin", "call_someone"),
    (-7, "21:30", "checkin", "walk"),
    (-6, "09:05", "focus", "user_stopped"), (-6, "21:00", "breathing", "finished"),
    (-5, "15:20", "focus", "finished"), (-5, "21:30", "checkin", "music"),
    (-4, "09:15", "focus", "finished"), (-4, "21:00", "breathing", "finished"),
    (-3, "15:10", "focus", "finished"), (-3, "21:30", "checkin", "daylight"),
    (-2, "15:00", "focus", "finished"), (-2, "21:00", "breathing", "finished"),
    (-2, "21:30", "checkin", "walk"),
    (-1, "15:05", "focus", "finished"), (-1, "21:00", "breathing", "finished"),
    (-1, "21:30", "checkin", "coffee_outside"),
    (0, "08:30", "breathing", "finished"),
]
DIP_ACTIVITY_DAYS = 3  # the dip makes sessions from this many days back slower and flatter
# The evening check-in tells the slide in the person's own terms (docs/pitch.md):
# three good things every evening for two weeks, then two, then one, and in the
# dip the last evenings without a check-in at all.
EARLY_CHECKIN_OFFSETS = range(-27, -13)  # one every evening, three good things each
EARLY_PLANS = ("walk", "call_someone", "music", "daylight", "coffee_outside")
DIP_GOOD_THINGS = {-12: 2, -9: 2, -7: 2, -5: 1, -3: 1}  # day offset -> good things named
DIP_NO_CHECKIN_FROM = -2  # in the dip: no check-in from this day on
GOOD_THINGS = ["walked", "good_food", "talked_to_someone", "music", "rested", "laughed",
               "outside", "got_something_done"]


def _clamp01(x: float) -> float:
    return max(0.0, min(1.0, x))


# The levels and spreads below follow the first real games: 19 well tracked games from
# two team members' iPhones on 14 November 2026 (docs/face-generator.md). Before that
# the generated face was about four times as lively as a real one during the game,
# smiled in every session and held the phone level. Real players mostly do not smile
# while they play, blink about eight times a minute and look down at the phone.
# What a dip does (flat < 1) is still OUR assumption, not something measured.

def _face_more(rx: random.Random, flat: float) -> dict:
    """The newer face fields. Drawn from their own generator, so the draws of
    the older fields stay in step. In the dip (flat < 1) smiling and head
    movement drop, brows, blinks and head angle go the other way."""
    return {"smile_time_share": abs(rx.gauss(0.02, 0.008)),          # per smile a minute; see _face
            "eye_smile_share": round(_clamp01(rx.gauss(0.15, 0.2) * flat), 2),
            "smile_response_share": round(_clamp01(rx.gauss(0.05, 0.15) * flat), 2),
            "smile_response_latency_s": round(max(0.2, rx.gauss(1.1, 0.15) / flat), 2),
            "brow_down_share": round(_clamp01(rx.gauss(0.03, 0.03) / flat), 2),
            "inner_brow_up_share": round(_clamp01(rx.gauss(0.02, 0.04) / flat), 2),
            "blink_duration_ms": round(max(33.0, rx.gauss(100, 25) / math.sqrt(flat)), 0),
            "head_pitch_deg": round(rx.gauss(-16.0, 4.0) + (1 - flat) * 16, 1),
            "head_movement": round(_clamp01(rx.gauss(0.43, 0.10) * flat), 2),
            "smile_asymmetry": round(_clamp01(rx.gauss(0.03, 0.02)), 2)}


def _face(rng: random.Random, flat: float = 1.0, rx: random.Random | None = None) -> dict:
    more = _face_more(rx, flat) if rx is not None else {}
    # About half of the real games had no smile at all, and a few had many.
    rate = round(max(0.0, rng.gauss(0.3, 2.6)) * flat * flat, 2)
    out = {**more, "smile_rate_per_min": rate,
           "smile_intensity": round(max(0.0, min(1.0, rng.gauss(0.36, 0.08) * flat)), 2),
           "facial_activity": round(max(0.02, min(1.0, rng.gauss(0.13, 0.03) * flat)), 3),
           "blink_rate_per_min": round(max(1.0, rng.gauss(8.0, 3.0)), 1),
           "look_down_share": round(max(0.0, min(1.0, rng.gauss(0.15, 0.10) / flat)), 2),
           "head_tilt_deg": round(abs(rng.gauss(2.5, 1.5)), 1),
           "tracking_quality": round(max(0.62, min(1.0, rng.gauss(0.92, 0.08))), 2)}
    if more:
        out["smile_time_share"] = round(_clamp01(rate * more["smile_time_share"]), 3)
    if rate == 0:
        # No smile in the session: nothing to say about how the smiles looked.
        out["smile_intensity"] = 0.0
        for k in ("eye_smile_share", "smile_response_share"):
            if k in out:
                out[k] = 0.0
        for k in ("smile_response_latency_s", "smile_asymmetry"):
            if k in out:
                out[k] = None
    elif "smile_response_share" in out and out["smile_response_share"] == 0:
        out["smile_response_latency_s"] = None
    return out


# Which draw of the generated fine movement the examples use. At the real spread a
# drop to a third shows in about 7 of 10 such stories (25 of the 32 draws tried); this is one where the
# example dip shows and the unchanged example stays quiet (as EXAMPLE_SEED for the game).
FINE_SEED = 2

FINE_REGIONS = ("mouth_left", "mouth_right", "lip_upper", "lip_lower", "cheek_left", "cheek_right",
                "brow_left", "brow_right", "eyelid_left", "eyelid_right", "jaw", "nose",
                "mouth_corner_left", "mouth_corner_right")


# Per group of regions, from the first real games: where the region sits (mm from the
# resting shape), how far it reaches against the face's mean reach, and brief movements
# a minute at the usual reach. (level, reach factor, brief movements a minute)
_FINE_SHAPE = {"mouth": (1.4, 1.3, 9.0), "lip_upper": (1.7, 0.8, 2.0), "lip_lower": (1.8, 1.8, 12.0),
               "cheek": (1.0, 0.6, 2.0), "brow": (1.5, 0.9, 6.0), "eyelid": (1.3, 0.4, 2.0),
               "jaw": (1.25, 1.3, 9.0), "nose": (0.85, 0.3, 0.0), "mouth_corner": (1.0, 1.4, 12.0)}
FINE_REACH_MM = 0.5      # the middle of the real games' mean reach
FINE_SPREAD = 0.6        # how much it differs from game to game, on its logarithm
_FINE_CAL = 1.0          # brings the summary's reach onto the reach asked for (set by measuring)


@lru_cache(maxsize=4096)
def fine_stream(activity_id: str, flat: float = 1.0) -> dict:
    """The fine movement stream of one generated session, shaped like the app's
    (docs/face-fine.md): fourteen regions, thirty frames a second, millimetres
    from the resting shape. Drawn from its own generator, seeded by the
    session's id, so nothing else in the example moves. The summary on the
    page is computed from it by the same code as for a real stream.

    The shape follows the first real games (14 November 2026, one iPhone, ten
    games): each region sits one to two millimetres from the resting shape and
    creeps up through the game; from frame to frame it jumps by about a
    hundredth of a millimetre; slower movements of half a second to three
    seconds give the reach, near half a millimetre over the face and differing
    from game to game by a factor of about 1.8; brief movements of a tenth of
    a second rise 0.55 to 1 mm, most often at the mouth. That a dip lowers the
    reach, and by how much (to about a third when `flat` is 0.5), is OUR
    assumption: nobody has measured it."""
    r = random.Random(f"fine-{FINE_SEED}-{activity_id}")
    n = r.randint(800, 1300)
    session = FINE_REACH_MM * math.exp(r.gauss(0, FINE_SPREAD)) * flat ** 1.5
    creep = r.uniform(0.1, 1.0)
    cols = []
    for name in FINE_REGIONS:
        level, factor, brief = _FINE_SHAPE[name.replace("_left", "").replace("_right", "")]
        reach = session * factor * math.exp(r.gauss(0, 0.2)) * _FINE_CAL
        base = abs(r.gauss(level, 0.3))
        y = [base + creep * i / n + r.gauss(0, 0.012) for i in range(n)]
        t = r.uniform(0, 4) * 30
        while t < n:                                   # slower movements: these give the reach
            long = int(r.uniform(0.6, 3.0) * 30)
            high = reach * r.uniform(0.7, 1.6)
            for i in range(int(t), min(n, int(t) + long)):
                y[i] += high * math.sin(math.pi * (i - t) / long) ** 2
            t += long + r.expovariate(1 / (5.0 * 30))
        for _ in range(_poisson(r, brief * n / 1800 * min(2.0, session / FINE_REACH_MM))):
            i0, long, high = r.randrange(n - 6), r.randint(3, 5), r.uniform(0.55, 1.0)
            for i in range(i0, i0 + long):
                y[i] += high
        cols.append(y)
    return {"source": "mesh", "rate_hz": 30, "regions": list(FINE_REGIONS),
            "samples": [[round(max(0.0, c[i]), 2) for c in cols] for i in range(n)],
            "noise_mm": round(abs(r.gauss(0.09, 0.03)), 2)}


def _poisson(r: random.Random, mean: float) -> int:
    k, p, limit = 0, 1.0, math.exp(-max(0.0, mean))
    while True:
        p *= r.random()
        if p <= limit:
            return k
        k += 1


def _fine(activity_id: str, flat: float = 1.0) -> dict:
    """The fields a generated face session carries for its fine movement: the
    summary and the counts, computed from the generated stream as the server
    computes them from a real one."""
    # The example people share session ids ("example-act-003"), so the person is part
    # of the name the stream is drawn from: no two people get the same face.
    name = f"{_FINE_WHO}{activity_id}"
    _FINE_FLAT[activity_id] = (name, flat)
    return copy.deepcopy(_fine_summary(name, flat, FINE_SEED))


@lru_cache(maxsize=4096)
def _fine_summary(activity_id: str, flat: float, draw: int) -> dict:
    from .mind import face_fine
    stream = fine_stream(activity_id, flat)
    return {"face_fine": face_fine.summarize(stream), "face_fine_info": face_fine.describe(stream)}


_FINE_FLAT: dict[str, tuple[str, float]] = {}   # per session id: the name and `flat` its stream was drawn with
_FINE_WHO = ""                                    # set by the writer: whose sessions are being drawn


def put_fine_stream(store, base: str, rec: dict) -> None:
    """Keep the generated stream beside the session, as for a real one.
    `base` is the patient's folder."""
    if rec.get("face_fine"):
        stream = fine_stream(*_FINE_FLAT.get(rec["id"], (rec["id"], 1.0)))
        store.put(base + f"facefine/{rec['id']}.json",
                  {"activity_id": rec["id"], "type": rec["type"], "started_at": rec["started_at"],
                   "received_at": rec["started_at"], **stream, "frames": len(stream["samples"])})


def revontulet_game(rv: random.Random, rts: list[int], low: float = 0.0, finished: bool = True,
                    played_s: float = 90.0, hard: float = 0.85, hit: float | None = None,
                    min_hits: int = 0) -> dict:
    """The focus fields of one generated Revontulet game, as the app sends it
    (ios ActivityRouter.record): launches and embers hit as correct taps, no
    wrong taps, embers missed as misses, one reaction time per ember hit (taken
    from `rts`, already drawn by the caller) and the `revontulet` object.
    `low` (0 as usual, 1 lowest) slows the tracing and stroking; a game stopped
    early has two rounds, no strokes and no burst. `min_hits` draws the game
    again until that many embers were tapped: the two-week example needs
    reaction times in every game for its "slower reactions" story to show
    (a real game often has fewer; see revontulet_min_reactions)."""
    from .seed_revontulet import _game  # that module imports this one
    for _ in range(200):
        g = _game(rv, low, hard=hard, hit=0.9 - 0.25 * low if hit is None else hit)
        if not finished:
            g.update(rounds=g["rounds"][:2], strokes=[], broke_through_s=None, fox_finished=None)
        hits = sum(r["embers_hit"] for r in g["rounds"])
        if hits >= min_hits:
            break
    shown = sum(r["embers_shown"] for r in g["rounds"])
    # A real game ends some twenty seconds after the wall bursts (the strokes);
    # when the fox had to finish it, the full 90 seconds ran out.
    burst = g["broke_through_s"]
    length = 90.0 if burst is None else min(90.0, round(burst + rv.uniform(17, 27), 1))
    return {"duration_s": length if finished else played_s, "correct_taps": len(g["rounds"]) + hits,
            "wrong_taps": 0, "misses": shown - hits, "reaction_ms": rts[:hits], "revontulet": g}


def make_activity(rng: random.Random, aid: str, started: datetime, typ: str, how: str,
                  dip: bool, prev_plan: bool, rx: random.Random | None = None,
                  good: int | None = None, rv: random.Random | None = None) -> dict:
    """`good` sets how many good things a check-in names, after the usual draws,
    so every other example value stays exactly as it was. A focus record is a
    Revontulet game; `rv` is the generator for its measures (its own, for the
    same reason)."""
    rec = {"id": aid, "type": typ, "started_at": started.isoformat(), "suggestion_id": None}
    if typ == "focus":
        slow = 1.35 if dip else 1.0
        n = rng.randint(16, 20) if how == "finished" else rng.randint(7, 10)
        rts = [int(max(200, rng.gauss(520, 55) * slow)) for _ in range(n)]
        rec.update(duration_s=45.0 if how == "finished" else round(rng.uniform(18, 28), 1),
                   correct_taps=n - 1, wrong_taps=1, misses=rng.randint(1, 3) + (2 if dip else 0),
                   reaction_ms=rts[: n], face=_face(rng, 0.5 if dip else 1.0, rx))
        rec.update(_fine(aid, 0.5 if dip else 1.0))
        # In the dip the tracing and the ember taps get slower; the embers are
        # still tapped, so the slower reaction times are there to be seen.
        rec.update(revontulet_game(rv or rng, rts, 0.6 if dip else 0.0, how == "finished",
                                   rec["duration_s"], hard=0.9, hit=0.9, min_hits=3))
    elif typ == "breathing":
        if dip and rng.random() < 0.7:
            how = "user_stopped"
        played = 60.0 if how == "finished" else round(rng.uniform(20, 35), 1)
        rec.update(duration_s=played, time_played_s=played,
                   breaths_completed=6 if how == "finished" else int(played // 10),
                   face=_face(rng, 0.5 if dip else 1.0, rx))
        rec.update(_fine(aid, 0.5 if dip else 1.0))
    else:
        k = 1 if dip else rng.choice([2, 3, 3])
        things = rng.sample(GOOD_THINGS, k)
        if good is not None:
            things = (things + [g for g in GOOD_THINGS if g not in things])[:good]
        rec.update(duration_s=round(rng.uniform(40, 80), 1),
                   good_things=[{"catalog_id": g} for g in things],
                   plan={"catalog_id": how},
                   plan_done=("no" if dip else rng.choice(["yes", "yes", "no"]))
                   if prev_plan else "not_asked")
        how = "finished"
    rec.update(completed=how == "finished", ended_by=how)
    return rec


def write_activities(store: Store, clinic_id: str, patient_id: str, today, tz: ZoneInfo,
                     seed: int, dip: bool = False, now: datetime | None = None) -> None:
    """About two weeks of example activities with face summaries. The same ids
    every time, so switching scenarios never takes XP away (XP awards are
    keyed by record id and never removed)."""
    from .mind.activities import process_activity
    rng = random.Random(seed + 31)
    rx = random.Random(seed + 37)  # the newer face fields only
    rv = random.Random(seed + 43)  # Revontulet's measures only
    global _FINE_WHO
    _FINE_WHO = f"{seed}:"         # each example person has their own seed
    base = f"clinics/{clinic_id}/patients/{patient_id}/activities/"
    for key in store.list(base):
        if (store.get(key) or {}).get("example"):
            store.delete(key)
    now = now or datetime.now(timezone.utc)
    previous: list[dict] = []

    def keep(a: dict) -> None:
        rec = process_activity(a, previous)
        rec.update(example=True, received_at=a["started_at"], content_sha256="example",
                   crisis=False, analysis={"status": "not_applicable"})
        store.put(base + f"{rec['id']}.json", rec)
        previous.append(rec)

    # The two weeks before: a check-in every evening, three good things each.
    # Drawn from their own generator, so everything below stays as it was.
    early = random.Random(seed + 41)
    for k, off in enumerate(EARLY_CHECKIN_OFFSETS):
        started = datetime.combine(today + timedelta(days=off), time(21, 30), tzinfo=tz)
        keep(make_activity(early, f"example-chk-{k:03d}", started.astimezone(timezone.utc),
                           "checkin", EARLY_PLANS[k % len(EARLY_PLANS)], False, k > 0, good=3))
    had_plan = False
    for n, (off, hm, typ, how) in enumerate(ACTIVITY_PLAN):
        h, m = (int(x) for x in hm.split(":"))
        started = datetime.combine(today + timedelta(days=off), time(h, m), tzinfo=tz)
        if started.astimezone(timezone.utc) > now:
            continue
        a = make_activity(rng, f"example-act-{n:03d}", started.astimezone(timezone.utc), typ, how,
                          dip and off > -DIP_ACTIVITY_DAYS, had_plan, rx,
                          good=DIP_GOOD_THINGS.get(off) if dip and typ == "checkin" else None,
                          rv=rv)
        if typ == "checkin":
            had_plan = True
            if dip and off >= DIP_NO_CHECKIN_FROM:
                continue  # drawn (the values after it stay the same), not kept
        rec = process_activity(a, previous)
        rec.update(example=True, received_at=a["started_at"], content_sha256="example",
                   crisis=False, analysis={"status": "not_applicable" if typ == "checkin"
                                           else "off"})
        store.put(base + f"{rec['id']}.json", rec)
        put_fine_stream(store, base[:-len("activities/")], rec)
        previous.append(rec)


# Weekly example ratings (day offset). The last two move in the dip.
RATING_OFFSETS = (-27, -20, -13, -6, -1)


def write_ratings(store: Store, clinic_id: str, patient_id: str, today, seed: int,
                  dip: bool = False) -> None:
    """Example PHQ-9 ratings, weekly, marked example. Worse (higher) in the dip.
    A clinician's own ratings are never touched. Read only by the association
    appraisal; the mind never sees them."""
    rng = random.Random(seed + 53)
    base = f"clinics/{clinic_id}/patients/{patient_id}/ratings/"
    for key in store.list(base):
        if (store.get(key) or {}).get("example"):
            store.delete(key)
    for n, off in enumerate(RATING_OFFSETS):
        score = 5 + rng.choice([-1, 0, 0, 1])
        if dip and off == RATING_OFFSETS[-2]:
            score = 9
        if dip and off == RATING_OFFSETS[-1]:
            score = 15
        d = today + timedelta(days=off)
        rid = f"rat_{n:024x}"
        store.put(base + f"{rid}.json", {
            "id": rid, "date": d.isoformat(), "scale": "phq9", "score": score,
            "created_at": datetime.combine(d, time(12, 0), tzinfo=timezone.utc).isoformat(),
            "by": "example", "example": True})


def settle_lanvi(store: Store, clinic_id: str, patient_id: str, now: datetime) -> None:
    """Give the seeded XP, and for the demo let Lanvi be back with a story."""
    from .mind import lanvi_config, xp
    from .mind.repo import PatientRepo
    repo = PatientRepo(store, clinic_id, patient_id)
    st, _ = xp.sync(repo, now, save=False)
    told = max(0, xp.total(st) // lanvi_config.GLOW_CAPACITY_XP - 1)
    st["glow_spent"] = (told + 1) * lanvi_config.GLOW_CAPACITY_XP
    ids = __import__("clinic_engine.mind.lines", fromlist=["x"]).story_ids()
    st["wanderings"] = [{"id": f"wander-{k + 1:04d}", "story_id": ids[k % len(ids)],
                         "answer": "a", "example": True} for k in range(told)]
    st["wandering"] = {"state": "back", "id": f"wander-{told + 1:04d}",
                       "started_at": (now - timedelta(hours=5)).isoformat(),
                       "returns_at": (now - timedelta(hours=2)).isoformat(),
                       "returned_at": (now - timedelta(hours=2)).isoformat(),
                       "story_id": ids[told % len(ids)]}
    repo.put(xp.STATE_KEY, st)


# ---- whole demo ------------------------------------------------------------------------------

def wipe_patient(store: Store, clinic_id: str, patient_id: str) -> None:
    base = f"clinics/{clinic_id}/patients/{patient_id}/"
    for folder in ("days", "rounds", "activities", "lanvi", "suggestions", "feedback", "notes",
                   "attention", "mind", "rejected", "ratings", "research", "exchanges",
                   "faceraw", "facefine", "health"):
        store.delete_prefix(base + folder + "/")
    for key in store.list(f"clinics/{clinic_id}/attention_index/"):
        if (store.get(key) or {}).get("patient_id") == patient_id:
            store.delete(key)
    for key in store.list(f"clinics/{clinic_id}/notify/"):
        if (store.get(key) or {}).get("patient_id") in (patient_id, None):
            store.delete(key)


def fill_patient(store: Store, clinic_id: str, patient_id: str, now: datetime, seed: int,
                 scenario: str = "normal", rounds: bool = True, history: bool = True,
                 activities: bool = True) -> None:
    """`rounds` adds example AR rounds of the earlier design (shown as
    earlier rounds); `activities` adds about two weeks of Lanvi activities."""
    rec = store.get(f"clinics/{clinic_id}/patients/{patient_id}/patient.json")
    tz = ZoneInfo(rec["timezone"])
    today = now.astimezone(tz).date()
    shaped = write_example_suggestions(store, clinic_id, patient_id, today, tz) if history else {}
    write_history(store, clinic_id, patient_id, today, seed, shaped=shaped)
    if scenario == "dip":
        apply_scenario(store, clinic_id, patient_id, today, "dip", seed)
    if history:
        write_ratings(store, clinic_id, patient_id, today, seed, dip=scenario == "dip")
    if rounds:
        write_rounds(store, clinic_id, patient_id, today, tz, seed, dip=scenario == "dip")
    if activities:
        write_activities(store, clinic_id, patient_id, today, tz, seed, dip=scenario == "dip",
                         now=now)
        if history:
            settle_lanvi(store, clinic_id, patient_id, now)


async def settle(app_mind, clinic_id: str, patient_id: str, review: bool = True,
                 appraise: bool = False) -> None:
    """Let the mind look at the new data once (and run a review). `appraise`
    also computes the association appraisal (clinician-only; changes nothing
    the mind does)."""
    repo = app_mind.repo(clinic_id, patient_id)
    async with app_mind.lock(clinic_id, patient_id):
        if review:
            await app_mind.run_review(repo, "seed")
        await app_mind.publish("scenario", clinic_id, patient_id)
    if appraise:
        await app_mind.run_appraisal(repo, "seed")


def create_demo(store: Store, settings: Settings, now: datetime, extra: int = 0,
                username: str | None = None, password: str | None = None) -> dict:
    if store.get("demo/state.json"):
        raise SystemExit("A demo already exists in this store. Use --reset to regenerate its data.")
    username = username or os.environ.get("SEED_CLINICIAN_USERNAME", "demo-clinician")
    password = password or os.environ.get("SEED_CLINICIAN_PASSWORD") or secrets.token_urlsafe(12)
    tz = settings.default_timezone
    clinic = create_clinic(store, "Demo clinic", now)
    clinician = create_clinician(store, clinic, username, password, now)
    patient = create_patient(store, clinic, DEMO_LABEL, tz, now, example=True, allow_outside=True,
                             display_name=DEMO_DISPLAY_NAME)
    device_token = pair_device_direct(store, clinic, patient, "demo device", now)
    admin_token = issue_token(store, "admin", now=now)
    fill_patient(store, clinic, patient, now, seed=14)
    extras = []
    for n in range(extra):
        scen = ("normal", "dip", "silent")[n % 3]
        pid = create_patient(store, clinic, f"Example B-{21 + n:03d}", tz, now, example=True,
                             display_name=EXTRA_DISPLAY_NAMES[n % len(EXTRA_DISPLAY_NAMES)])
        fill_patient(store, clinic, pid, now - (timedelta(days=4) if scen == "silent" else timedelta()),
                     seed=100 + n, scenario="dip" if scen == "dip" else "normal", history=False)
        extras.append(pid)
    # A second, mock clinic so tenant isolation has something to refuse.
    other = create_clinic(store, "Mock clinic (example)", now)
    other_pid = create_patient(store, other, "Example C-001", tz, now, example=True)
    fill_patient(store, other, other_pid, now, seed=500, rounds=False, history=False,
                 activities=False)
    state = {"clinic_id": clinic, "clinician_id": clinician, "patient_id": patient,
             "extra_patient_ids": extras, "mock_clinic_id": other, "mock_patient_id": other_pid,
             "created_at": now.isoformat()}
    store.put("demo/state.json", state)
    return {**state, "username": username, "password": password, "device_token": device_token,
            "admin_token": admin_token}


def main() -> None:
    from .app import create_app
    ap = argparse.ArgumentParser(description="Seed the demo clinic.")
    ap.add_argument("--extra", type=int, default=0, help="extra example patients")
    ap.add_argument("--reset", action="store_true", help="regenerate the demo patient's data")
    ap.add_argument("--pairing-code", action="store_true",
                    help="also print a one-time pairing code for a real phone")
    args = ap.parse_args()
    settings = Settings.from_env()
    store = make_store(settings)
    app = create_app(settings=settings, store=store, start_ticker=False)
    mind = app.state.ctx.mind
    now = datetime.now(timezone.utc)

    async def run() -> None:
        if args.reset:
            st = store.get("demo/state.json")
            if not st:
                raise SystemExit("No demo in this store yet.")
            wipe_patient(store, st["clinic_id"], st["patient_id"])
            fill_patient(store, st["clinic_id"], st["patient_id"], now, seed=14)
            await settle(mind, st["clinic_id"], st["patient_id"], appraise=True)
            print("Demo patient data regenerated.")
            out = st
        else:
            out = create_demo(store, settings, now, extra=args.extra)
            for pid in [out["patient_id"], *out["extra_patient_ids"]]:
                await settle(mind, out["clinic_id"], pid, appraise=True)
            await settle(mind, out["mock_clinic_id"], out["mock_patient_id"], review=False)
            print(f"Product:          {settings.product_name}")
            print(f"Clinic id:        {out['clinic_id']}")
            print(f"Patient id:       {out['patient_id']}  ({DEMO_LABEL})")
            print(f"Clinician login:  {out['username']} / {out['password']}")
            print(f"Device token:     {out['device_token']}")
            print(f"Admin token:      {out['admin_token']}")
            print("These are shown once. Keep them out of the repo.")
        if args.pairing_code:
            from .service import create_pairing_code
            code = create_pairing_code(app.state.ctx, out["clinic_id"], out["patient_id"])
            print(f"Pairing code:     {code}  (one-time, {settings.pairing_ttl_hours} h)")

    asyncio.run(run())


if __name__ == "__main__":
    main()
