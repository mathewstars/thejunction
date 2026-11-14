"""A simulated 12-week study of one person, to demonstrate the association appraisal.

    python -m clinic_engine.seed_research

Creates (or regenerates) one example patient in the demo clinic with 84 days of
daily data, one or two sessions a day and a weekly PHQ-9, all drawn from a
hidden symptom course plus noise. This person's course is flat, so the page
has to say "nothing to conclude". `--extend-demo` gives the demo patient
earlier weeks with a real rise and fall, where the measures follow the ratings
BY CONSTRUCTION. Neither is evidence about any real person. All marked example.
"""

from __future__ import annotations

import random
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from .config import Settings
from .seed import (GOOD_THINGS, _day_values, _face, _fine, create_patient, put_fine_stream,
                   revontulet_game,
                   wipe_patient)
from .store import Store, make_store

LABEL = "Example R-001"
NAME = "Elina Peltonen"
DAYS = 84
# The hidden course, as (day index, symptom level 0..1). This person stays well: the level
# hardly moves, so the ratings hardly move, and the honest answer is "nothing to conclude".
# The page must show that as clearly as it shows a relation (the demo patient has one).
COURSE = ((0, 0.22), (30, 0.16), (60, 0.24), (83, 0.18))


def level(k: int) -> float:
    for (a, va), (b, vb) in zip(COURSE, COURSE[1:]):
        if a <= k <= b:
            return va + (vb - va) * (k - a) / (b - a)
    return COURSE[-1][1]


def _simulate(store: Store, base: str, tz, now: datetime, plan: list[tuple[int, float]],
              seed: int, tag: str) -> None:
    """Write example days, sessions and weekly PHQ-9 for `plan`: (days ago, symptom level),
    oldest first. Every record is marked example and carries `tag` in its id."""
    from . import seed as seed_module
    from .mind.activities import process_activity
    seed_module._FINE_WHO = f"{tag}:{seed}:"   # this person's own fine movement streams
    today = now.astimezone(tz).date()
    rng, rx, noise = random.Random(seed), random.Random(seed + 1), random.Random(seed + 2)
    rv = random.Random(seed + 3)  # Revontulet's measures only: the other draws stay as they were
    previous: list[dict] = []
    had_plan, n_act, n_rat, drift = False, 0, 0, 0.0
    for k, (ago, lvl) in enumerate(plan):
        d = today - timedelta(days=ago)
        drift = 0.7 * drift + noise.gauss(0, 0.05)  # day-to-day wobble around the course
        s = max(0.0, min(1.0, lvl + drift))
        store.put(base + f"days/{d.isoformat()}.json", _day_values(rng, d, 1.0 - 0.45 * s))
        if k % 7 == 3:  # weekly PHQ-9
            rid = f"rat_{tag}{n_rat:020x}"
            n_rat += 1
            store.put(base + f"ratings/{rid}.json", {
                "id": rid, "date": d.isoformat(), "scale": "phq9",
                "score": int(max(0, min(27, round(3 + 15 * s + noise.gauss(0, 1.0))))),
                "created_at": datetime.combine(d, time(12, 0), tzinfo=timezone.utc).isoformat(),
                "by": "example", "example": True})
        todo = []
        if noise.random() > 0.15 + 0.25 * s:  # worse days are more often skipped
            todo.append(("focus", "09:10" if k % 2 else "15:20"))
        if k % 2 == 0 and noise.random() > 0.1:
            todo.append(("breathing", "21:00"))
        if noise.random() > 0.2:
            todo.append(("checkin", "21:30"))
        for typ, hm in todo:
            h, m = (int(x) for x in hm.split(":"))
            started = datetime.combine(d, time(h, m), tzinfo=tz).astimezone(timezone.utc)
            if started > now:
                continue
            flat = 1.0 - 0.5 * s
            a = {"id": f"example-{tag}-{n_act:04d}", "type": typ,
                 "started_at": started.isoformat(), "suggestion_id": None}
            n_act += 1
            how = "finished"
            if typ == "focus":
                n = rng.randint(16, 20)
                a.update(duration_s=45.0, correct_taps=n - 1, wrong_taps=1 + (noise.random() < s),
                         misses=rng.randint(1, 3) + int(round(2 * s)),
                         reaction_ms=[int(max(200, rng.gauss(520, 55 + 40 * s) * (1 + 0.4 * s)))
                                      for _ in range(n)],
                         face=_face(rng, flat, rx))
                a.update(_fine(a["id"], flat))
                # The game is Revontulet: harder cracks, ember taps and the two
                # speeds follow the symptom level, like everything else here.
                a.update(revontulet_game(rv, a["reaction_ms"], s, hard=0.9 - 0.35 * s,
                                         hit=0.92 - 0.3 * s))
            elif typ == "breathing":
                if noise.random() < 0.6 * s:
                    how = "user_stopped"
                played = 60.0 if how == "finished" else round(rng.uniform(20, 35), 1)
                a.update(duration_s=played, time_played_s=played,
                         breaths_completed=6 if how == "finished" else int(played // 10),
                         face=_face(rng, flat, rx))
                a.update(_fine(a["id"], flat))
            else:
                good = max(0, min(3, int(round(3 - 2.4 * s + noise.gauss(0, 0.5)))))
                a.update(duration_s=round(rng.uniform(40, 80), 1),
                         good_things=[{"catalog_id": g} for g in rng.sample(GOOD_THINGS, good)],
                         plan={"catalog_id": "walk"},
                         plan_done=("yes" if noise.random() > 0.15 + 0.7 * s else "no")
                         if had_plan else "not_asked")
                had_plan = True
            a.update(completed=how == "finished", ended_by=how)
            rec = process_activity(a, previous)
            rec.update(example=True, received_at=a["started_at"], content_sha256="example",
                       crisis=False, analysis={"status": "not_applicable" if typ == "checkin"
                                               else "off"})
            store.put(base + f"activities/{rec['id']}.json", rec)
            put_fine_stream(store, base, rec)
            previous.append(rec)


def create(store: Store, clinic_id: str, tz_name: str, now: datetime, seed: int = 7) -> str:
    pid = None
    for key in store.list(f"clinics/{clinic_id}/patients/"):
        if key.endswith("/patient.json") and (store.get(key) or {}).get("label") == LABEL:
            pid = store.get(key)["id"]
    if pid is None:
        pid = create_patient(store, clinic_id, LABEL, tz_name, now, example=True,
                             display_name=NAME)
    else:
        wipe_patient(store, clinic_id, pid)
    _simulate(store, f"clinics/{clinic_id}/patients/{pid}/", ZoneInfo(tz_name), now,
              [(DAYS - 1 - k, level(k)) for k in range(DAYS)], seed, "study")
    return pid


# For the demo patient: eight earlier weeks before the 28 days the seed already wrote.
# An earlier worse period, then recovery and two calm weeks, so the join is smooth.
EARLIER = ((0, 0.3), (12, 0.75), (24, 0.7), (40, 0.2), (55, 0.2))
EARLIER_FROM, EARLIER_TO = 84, 29  # days ago, both included


def extend_demo_history(store: Store, clinic_id: str, patient_id: str, tz_name: str,
                        now: datetime, seed: int = 21) -> int:
    """Adds simulated earlier weeks to an existing example patient, so the association
    appraisal has enough days. Touches nothing in the last 28 days. Safe to run again."""
    base = f"clinics/{clinic_id}/patients/{patient_id}/"
    for folder in ("activities", "ratings"):
        for key in store.list(base + folder + "/"):
            if "earlier" in key.rsplit("/", 1)[-1]:
                store.delete(key)

    def lvl(k: int) -> float:
        for (a, va), (b, vb) in zip(EARLIER, EARLIER[1:]):
            if a <= k <= b:
                return va + (vb - va) * (k - a) / (b - a)
        return EARLIER[-1][1]

    plan = [(ago, lvl(EARLIER_FROM - ago)) for ago in range(EARLIER_FROM, EARLIER_TO - 1, -1)]
    _simulate(store, base, ZoneInfo(tz_name), now, plan, seed, "earlier")
    return len(plan)


def main() -> None:
    import asyncio

    from .app import create_app
    from .seed import settle
    settings = Settings.from_env()
    store = make_store(settings)
    st = store.get("demo/state.json")
    if not st:
        raise SystemExit("No demo in this store yet. Run the seed first.")
    tz_name = store.get(f"clinics/{st['clinic_id']}/patients/{st['patient_id']}/patient.json")["timezone"]
    import sys
    now = datetime.now(timezone.utc)
    mind = create_app(settings=settings, store=store, start_ticker=False).state.ctx.mind
    if "--extend-demo" in sys.argv:
        n = extend_demo_history(store, st["clinic_id"], st["patient_id"], tz_name, now)
        asyncio.run(settle(mind, st["clinic_id"], st["patient_id"], review=False, appraise=True))
        print(f"Demo patient: {n} simulated earlier days added.")
        return
    pid = create(store, st["clinic_id"], tz_name, now)
    asyncio.run(settle(mind, st["clinic_id"], pid, review=False, appraise=True))
    print(f"Study example ready: {NAME} ({LABEL}), {DAYS} days. Patient id: {pid}")


if __name__ == "__main__":
    main()
