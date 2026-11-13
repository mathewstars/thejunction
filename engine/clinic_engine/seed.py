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
import math
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
                   example: bool, allow_outside: bool = False, share_notes: bool = False) -> str:
    pid = new_id("pat")
    store.put(f"clinics/{clinic_id}/patients/{pid}/patient.json", {
        "id": pid, "clinic_id": clinic_id, "label": label, "timezone": tz, "example": example,
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
GOOD_THINGS = ["walked", "good_food", "talked_to_someone", "music", "rested", "laughed",
               "outside", "got_something_done"]


def _face(rng: random.Random, flat: float = 1.0) -> dict:
    return {"smile_rate_per_min": round(max(0.0, rng.gauss(2.6, 0.25) * flat * flat), 2),
            "smile_intensity": round(max(0.0, min(1.0, rng.gauss(0.36, 0.03) * flat)), 2),
            "facial_activity": round(max(0.0, min(1.0, rng.gauss(0.52, 0.03) * flat)), 2),
            "blink_rate_per_min": round(rng.gauss(16.0, 1.2), 1),
            "look_down_share": round(max(0.0, min(1.0, rng.gauss(0.2, 0.03) / flat)), 2),
            "head_tilt_deg": round(rng.gauss(3.0, 1.0), 1),
            "tracking_quality": round(min(1.0, rng.gauss(0.86, 0.03)), 2)}


def make_activity(rng: random.Random, aid: str, started: datetime, typ: str, how: str,
                  dip: bool, prev_plan: bool) -> dict:
    rec = {"id": aid, "type": typ, "started_at": started.isoformat(), "suggestion_id": None}
    if typ == "focus":
        slow = 1.35 if dip else 1.0
        n = rng.randint(16, 20) if how == "finished" else rng.randint(7, 10)
        rts = [int(max(200, rng.gauss(520, 55) * slow)) for _ in range(n)]
        rec.update(duration_s=45.0 if how == "finished" else round(rng.uniform(18, 28), 1),
                   correct_taps=n - 1, wrong_taps=1, misses=rng.randint(1, 3) + (2 if dip else 0),
                   reaction_ms=rts[: n], face=_face(rng, 0.5 if dip else 1.0))
    elif typ == "breathing":
        if dip and rng.random() < 0.7:
            how = "user_stopped"
        played = 60.0 if how == "finished" else round(rng.uniform(20, 35), 1)
        rec.update(duration_s=played, time_played_s=played,
                   breaths_completed=6 if how == "finished" else int(played // 10),
                   face=_face(rng, 0.5 if dip else 1.0))
    else:
        k = 1 if dip else rng.choice([2, 3, 3])
        rec.update(duration_s=round(rng.uniform(40, 80), 1),
                   good_things=[{"catalog_id": g} for g in rng.sample(GOOD_THINGS, k)],
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
    base = f"clinics/{clinic_id}/patients/{patient_id}/activities/"
    for key in store.list(base):
        if (store.get(key) or {}).get("example"):
            store.delete(key)
    now = now or datetime.now(timezone.utc)
    previous: list[dict] = []
    had_plan = False
    for n, (off, hm, typ, how) in enumerate(ACTIVITY_PLAN):
        h, m = (int(x) for x in hm.split(":"))
        started = datetime.combine(today + timedelta(days=off), time(h, m), tzinfo=tz)
        if started.astimezone(timezone.utc) > now:
            continue
        a = make_activity(rng, f"example-act-{n:03d}", started.astimezone(timezone.utc), typ, how,
                          dip and off > -DIP_ACTIVITY_DAYS, had_plan)
        if typ == "checkin":
            had_plan = True
        rec = process_activity(a, previous)
        rec.update(example=True, received_at=a["started_at"], content_sha256="example",
                   crisis=False, analysis={"status": "not_applicable" if typ == "checkin"
                                           else "off"})
        store.put(base + f"{rec['id']}.json", rec)
        previous.append(rec)


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
                   "attention", "mind", "rejected"):
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
    if rounds:
        write_rounds(store, clinic_id, patient_id, today, tz, seed, dip=scenario == "dip")
    if activities:
        write_activities(store, clinic_id, patient_id, today, tz, seed, dip=scenario == "dip",
                         now=now)
        if history:
            settle_lanvi(store, clinic_id, patient_id, now)


async def settle(app_mind, clinic_id: str, patient_id: str, review: bool = True) -> None:
    """Let the mind look at the new data once (and run a review)."""
    repo = app_mind.repo(clinic_id, patient_id)
    async with app_mind.lock(clinic_id, patient_id):
        if review:
            await app_mind.run_review(repo, "seed")
        await app_mind.publish("scenario", clinic_id, patient_id)


def create_demo(store: Store, settings: Settings, now: datetime, extra: int = 0,
                username: str | None = None, password: str | None = None) -> dict:
    if store.get("demo/state.json"):
        raise SystemExit("A demo already exists in this store. Use --reset to regenerate its data.")
    username = username or os.environ.get("SEED_CLINICIAN_USERNAME", "demo-clinician")
    password = password or os.environ.get("SEED_CLINICIAN_PASSWORD") or secrets.token_urlsafe(12)
    tz = settings.default_timezone
    clinic = create_clinic(store, "Demo clinic", now)
    clinician = create_clinician(store, clinic, username, password, now)
    patient = create_patient(store, clinic, DEMO_LABEL, tz, now, example=True, allow_outside=True)
    device_token = pair_device_direct(store, clinic, patient, "demo device", now)
    admin_token = issue_token(store, "admin", now=now)
    fill_patient(store, clinic, patient, now, seed=14)
    extras = []
    for n in range(extra):
        scen = ("normal", "dip", "silent")[n % 3]
        pid = create_patient(store, clinic, f"Example B-{21 + n:03d}", tz, now, example=True)
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
            await settle(mind, st["clinic_id"], st["patient_id"])
            print("Demo patient data regenerated.")
            out = st
        else:
            out = create_demo(store, settings, now, extra=args.extra)
            for pid in [out["patient_id"], *out["extra_patient_ids"]]:
                await settle(mind, out["clinic_id"], pid)
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
