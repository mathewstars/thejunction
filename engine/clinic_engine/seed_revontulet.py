"""An example person who played Revontulet for eight weeks, so the clinician
page can show the game's own measures (harder crack chosen, tracing speed,
strokes) without a recording of a real person.

    python -m clinic_engine.seed_revontulet

Every number is GENERATED and marked as example data. The story is built in on
purpose: in the first four weeks the person picks the harder crack in most
rounds and traces quickly; from week five the weekly PHQ-9 score rises and the
harder choices and the tracing speed fall. Because the relation is put there by
this script, it shows what the page would look like if such a relation existed.
It is not evidence that one exists. Nothing here is a measurement of a person.
"""

from __future__ import annotations

import random
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from .config import Settings
from .seed import create_patient, wipe_patient
from .store import Store, make_store

LABEL = "Example V-001"
NAME = "Aino Mäkelä"
WEEKS = 8
PER_WEEK = (6, 4, 1)          # days before the end of each week
# How far into the slide each week is (0 = as usual, 1 = the lowest week).
SLIDE = (0.0, 0.0, 0.05, 0.0, 0.3, 0.6, 0.85, 1.0)
PHQ9 = (5, 4, 5, 6, 8, 11, 13, 15)
# The scale of every number below is taken from nine real games played by one
# team member on 14 November 2026 (an iPhone 15 Pro, indoors in the evening):
# tracing at about 7 to 20 cm/s, strokes at 10 to 40 cm/s, one to three
# seconds to choose, the wall bursting 15 to 40 seconds in. The story (the
# slide, and how much it moves each number) is still made up.
PT_PER_CM = 60.4
TRACE_CM_S, STROKE_CM_S = 13.5, 19.5
# How much a whole game's speed varies from one game to the next, as a share of
# the speed: from the same nine real games (about 13 to 15% for tracing, about
# 30% for strokes; some of the nine gave no speed). Ten minutes of play by one
# team member, so a first look and not a norm.
TRACE_VARIES, STROKE_VARIES = 0.13, 0.29


def _game(rng: random.Random, slide: float, spread: float = 1.0,
          hard: float | None = None, hit: float | None = None) -> dict:
    """One game's `revontulet` object (the shape of models.RevontuletIn).
    `spread` scales how much the two speeds vary from game to game (1.0: as in
    the first real games), for revontulet_check. `hard` and `hit` set the
    chance of the harder crack and of tapping an ember, for the other example
    people (seed.revontulet_game); left out, both follow the slide."""
    p_hard = 0.8 - 0.7 * slide if hard is None else hard
    p_hit = 0.9 - 0.3 * slide if hit is None else hit
    # One draw per game and speed: a good or a slow game moves all its rounds
    # together. Within the game each round or stroke wobbles 10% either way.
    trace_lvl = max(0.3, rng.gauss(1.0, TRACE_VARIES * spread))
    stroke_lvl = max(0.3, rng.gauss(1.0, STROKE_VARIES * spread))
    wob = lambda: rng.uniform(0.9, 1.1)  # noqa: E731
    rounds = []
    for _ in range(3):
        hard = rng.random() < p_hard
        shown = 2 if hard else 0
        speed = PT_PER_CM * TRACE_CM_S * (1 - 0.37 * slide) * trace_lvl * wob()
        ms = int(rng.uniform(320, 1000) * (1 + 0.6 * slide))
        rounds.append({
            "effort": "hard" if hard else "easy",
            "choice_ms": int(rng.uniform(600, 3400) * (1 + 0.9 * slide)),
            "trace_start_ms": int(rng.uniform(250, 1500) * (1 + 0.5 * slide)),
            "trace_ms": ms, "trace_length_pt": round(speed * ms / 1000, 1),
            "trace_mean_speed_pt_s": round(speed, 1),
            "trace_peak_speed_pt_s": round(speed * rng.uniform(1.8, 2.2), 1),
            "trace_lifts": 1 if rng.random() < 0.4 + 0.3 * slide else 0,
            "pull_pt": round(rng.uniform(150, 164) * (1 - 0.2 * slide), 1),
            "pull_hold_ms": int(rng.uniform(170, 320)),
            "embers_shown": shown,
            "embers_hit": sum(rng.random() < p_hit for _ in range(shown)),
            "bonus": hard and rng.random() < 0.3})
    strokes = []
    for _ in range(rng.randint(1, 3)):
        ms, drift = int(rng.uniform(500, 5000)), rng.uniform(0.95, 1.05)
        speed = PT_PER_CM * STROKE_CM_S * (1 - 0.3 * slide) * stroke_lvl * wob()
        strokes.append({"ms": ms, "length_pt": round(min(20000.0, speed * ms / 1000 * drift), 1),
                        "mean_speed_pt_s": round(speed, 1)})
    fox = rng.random() < 0.6 * slide
    return {"rounds": rounds, "strokes": strokes,
            "broke_through_s": None if fox else round(rng.uniform(15, 38) + 14 * slide, 1),
            "fox_finished": fox, "pt_per_cm": PT_PER_CM,
            "touch_radius_mean_pt": round(rng.uniform(24, 30), 1),
            "touch_radius_var": round(rng.uniform(5, 40), 1)}


# The example's draw. Chosen so the page shows the common case: on generated runs
# like this one the last three games read "slower than the start" in about 9 of
# 10 (revontulet_check); in the others the line reads "not clearly different".
# The page says so in the example's first lines.
EXAMPLE_SEED = 43


def create(store: Store, clinic_id: str, tz_name: str, now: datetime,
           seed: int = EXAMPLE_SEED) -> str:
    """Create the example person, or write their games and ratings again in place."""
    from .mind.activities import process_activity
    pid = None
    for key in store.list(f"clinics/{clinic_id}/patients/"):
        if key.endswith("/patient.json") and (store.get(key) or {}).get("label") == LABEL:
            pid = store.get(key)["id"]
    if pid is None:
        pid = create_patient(store, clinic_id, LABEL, tz_name, now, example=True,
                             display_name=NAME)
    else:
        wipe_patient(store, clinic_id, pid)
    base = f"clinics/{clinic_id}/patients/{pid}/"
    tz = ZoneInfo(tz_name)
    today = now.astimezone(tz).date()
    rng = random.Random(seed)
    previous: list[dict] = []
    k = 0
    for week in range(WEEKS):
        week_end = today - timedelta(days=7 * (WEEKS - 1 - week))
        for back in PER_WEEK:
            rv = _game(rng, SLIDE[week])
            hits = sum(r["embers_hit"] for r in rv["rounds"])
            shown = sum(r["embers_shown"] for r in rv["rounds"])
            started = datetime.combine(week_end - timedelta(days=back), time(17, 5 + k % 40), tzinfo=tz)
            a = {"id": f"example-revontulet-{k:03d}", "type": "focus",
                 "started_at": started.astimezone(timezone.utc).isoformat(), "suggestion_id": None,
                 "duration_s": 90.0 if rv["broke_through_s"] is None
                 else min(90.0, round(rv["broke_through_s"] + 22.0, 1)),
                 "completed": True, "ended_by": "finished",
                 "correct_taps": 3 + hits, "wrong_taps": 0, "misses": shown - hits,
                 "reaction_ms": [int(rng.gauss(430, 45) * (1 + 0.25 * SLIDE[week])) for _ in range(hits)],
                 "revontulet": rv}
            rec = process_activity(a, previous)
            rec.update(example=True, received_at=a["started_at"], content_sha256="example",
                       crisis=False, analysis={"status": "off"})
            store.put(base + f"activities/{rec['id']}.json", rec)
            previous.append(rec)
            k += 1
        rid = f"rat_{week:024x}"
        store.put(base + f"ratings/{rid}.json", {
            "id": rid, "date": week_end.isoformat(), "scale": "phq9", "score": PHQ9[week],
            "created_at": datetime.combine(week_end, time(12, 0), tzinfo=timezone.utc).isoformat(),
            "by": "example", "example": True})
    return pid


def main() -> None:
    settings = Settings.from_env()
    store = make_store(settings)
    st = store.get("demo/state.json")
    if not st:
        raise SystemExit("No demo in this store yet. Run the seed first.")
    c = st["clinic_id"]
    tz_name = store.get(f"clinics/{c}/patients/{st['patient_id']}/patient.json")["timezone"]
    pid = create(store, c, tz_name, datetime.now(timezone.utc))
    print(f"Revontulet example ready: {NAME} ({LABEL}), {WEEKS * len(PER_WEEK)} generated games "
          f"and {WEEKS} weekly ratings. Patient id: {pid}.")


if __name__ == "__main__":
    main()
