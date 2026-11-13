"""A simulated 12-week study of one person, to demonstrate the association appraisal.

    python -m clinic_engine.seed_research

Creates (or regenerates) one example patient in the demo clinic with 84 days of
daily data, one or two sessions a day and a weekly PHQ-9. Every value is drawn
from a hidden symptom course plus noise, so the measures are related to the
ratings BY CONSTRUCTION. It shows that the pipeline finds a relation that is
there; it is not evidence about any real person. Everything is marked example.
"""

from __future__ import annotations

import random
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from .config import Settings
from .seed import GOOD_THINGS, _day_values, _face, create_patient, wipe_patient
from .store import Store, make_store

LABEL = "Example R-001"
NAME = "Elina Peltonen"
DAYS = 84
# The hidden course, as (day index, symptom level 0..1): settles, worsens, recovers, worsens.
COURSE = ((0, 0.45), (14, 0.2), (28, 0.2), (45, 0.7), (60, 0.3), (72, 0.3), (83, 0.75))


def level(k: int) -> float:
    for (a, va), (b, vb) in zip(COURSE, COURSE[1:]):
        if a <= k <= b:
            return va + (vb - va) * (k - a) / (b - a)
    return COURSE[-1][1]


def create(store: Store, clinic_id: str, tz_name: str, now: datetime, seed: int = 7) -> str:
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
    tz = ZoneInfo(tz_name)
    today = now.astimezone(tz).date()
    base = f"clinics/{clinic_id}/patients/{pid}/"
    rng, rx, noise = random.Random(seed), random.Random(seed + 1), random.Random(seed + 2)
    previous: list[dict] = []
    had_plan, n_act, n_rat, drift = False, 0, 0, 0.0
    for k in range(DAYS):
        d = today - timedelta(days=DAYS - 1 - k)
        drift = 0.7 * drift + noise.gauss(0, 0.05)  # day-to-day wobble around the course
        s = max(0.0, min(1.0, level(k) + drift))
        store.put(base + f"days/{d.isoformat()}.json", _day_values(rng, d, 1.0 - 0.45 * s))
        if k % 7 == 3:  # weekly PHQ-9
            rid = f"rat_r{n_rat:023x}"
            n_rat += 1
            store.put(base + f"ratings/{rid}.json", {
                "id": rid, "date": d.isoformat(), "scale": "phq9",
                "score": int(max(0, min(27, round(3 + 15 * s + noise.gauss(0, 1.0))))),
                "created_at": datetime.combine(d, time(12, 0), tzinfo=timezone.utc).isoformat(),
                "by": "example", "example": True})
        plan = []
        if noise.random() > 0.15 + 0.25 * s:  # worse days are more often skipped
            plan.append(("focus", "09:10" if k % 2 else "15:20"))
        if k % 2 == 0 and noise.random() > 0.1:
            plan.append(("breathing", "21:00"))
        if noise.random() > 0.2:
            plan.append(("checkin", "21:30"))
        for typ, hm in plan:
            h, m = (int(x) for x in hm.split(":"))
            started = datetime.combine(d, time(h, m), tzinfo=tz).astimezone(timezone.utc)
            if started > now:
                continue
            flat = 1.0 - 0.5 * s
            a = {"id": f"example-study-{n_act:04d}", "type": typ,
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
            elif typ == "breathing":
                if noise.random() < 0.6 * s:
                    how = "user_stopped"
                played = 60.0 if how == "finished" else round(rng.uniform(20, 35), 1)
                a.update(duration_s=played, time_played_s=played,
                         breaths_completed=6 if how == "finished" else int(played // 10),
                         face=_face(rng, flat, rx))
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
            previous.append(rec)
    return pid


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
    pid = create(store, st["clinic_id"], tz_name, datetime.now(timezone.utc))
    mind = create_app(settings=settings, store=store, start_ticker=False).state.ctx.mind
    asyncio.run(settle(mind, st["clinic_id"], pid, review=False, appraise=True))
    print(f"Study example ready: {NAME} ({LABEL}), {DAYS} days. Patient id: {pid}")


if __name__ == "__main__":
    main()
