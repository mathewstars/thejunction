"""Lanvi's XP, stage, glow and wanderings, kept on the server.

XP lives in a ledger of awards (lanvi/state.json, "awards"), one entry per
thing done, keyed so each thing counts once:
  activity:<record id>        an activity, within the per-day cap
  plan:<check-in id>          the plan made in that check-in was done
  day:<YYYY-MM-DD>            walked or slept around own normal that day
sync() only ever ADDS awards. Nothing removes one, so XP never goes down,
whatever later data says (the dip scenario included).

The glow meter fills with XP. When it is full a wandering starts; after a
few hours Lanvi is back with one story and its question; the answer comes
back as an enum and the next wandering can start. The tick moves this on.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta

from . import lanvi_config as C
from . import lines
from .baseline import daily_series
from .repo import PatientRepo

STATE_KEY = "lanvi/state.json"


def load(repo: PatientRepo) -> dict:
    st = repo.get(STATE_KEY) or {}
    st.setdefault("awards", {})
    st.setdefault("glow_spent", 0)
    st.setdefault("wandering", {"state": "home"})
    st.setdefault("wanderings", [])
    return st


def total(st: dict) -> int:
    return int(sum(a["xp"] for a in st["awards"].values()))


def glow(st: dict) -> float:
    return round(max(0.0, min(1.0, (total(st) - st["glow_spent"]) / C.GLOW_CAPACITY_XP)), 2)


def _local_date(repo: PatientRepo, iso: str) -> str:
    return datetime.fromisoformat(iso).astimezone(repo.tz()).date().isoformat()


def _award(st: dict, key: str, xp: int, why: str, at: str, day: str, new: list,
           by: str | None = None) -> None:
    """`by`: the record that earned it (an activity id), when there is one."""
    if key in st["awards"] or xp <= 0:
        return
    st["awards"][key] = {"xp": xp, "why": why, "at": at, "date": day, "by": by}
    new.append({"key": key, "xp": xp, "why": why, "by": by})


def sync(repo: PatientRepo, now: datetime, th=None, save: bool = True) -> tuple[dict, list[dict]]:
    """Add every award that is due and not yet given. Returns (state, new awards)."""
    st = load(repo)
    new: list[dict] = []
    acts = repo.activities()
    per_day: dict[tuple[str, str], int] = {}
    for a in st["awards"].values():
        if a["why"] in C.MAX_AWARDS_PER_DAY:
            per_day[(a["why"], a["date"])] = per_day.get((a["why"], a["date"]), 0) + 1
    for a in acts:
        key = "activity:" + a["id"]
        if key in st["awards"] or (a["duration_s"] < C.MIN_SECONDS_FOR_XP and a["type"] != "checkin"):
            continue
        day = _local_date(repo, a["started_at"])
        if per_day.get((a["type"], day), 0) >= C.MAX_AWARDS_PER_DAY.get(a["type"], 1):
            continue
        _award(st, key, C.XP[a["type"]], a["type"], a["started_at"], day, new, by=a["id"])
        per_day[(a["type"], day)] = per_day.get((a["type"], day), 0) + 1
    # Yesterday's plan done: the latest earlier check-in with a plan, once.
    checkins = [a for a in acts if a["type"] == "checkin"]
    for c in checkins:
        if c.get("plan_done") != "yes":
            continue
        prev = previous_plan(repo, checkins, c)
        if prev is not None:
            _award(st, "plan:" + prev["id"], C.XP["plan_done"], "plan_done", c["started_at"],
                   _local_date(repo, c["started_at"]), new, by=c["id"])
    # Walked or slept around own normal: once per day with a baseline.
    days = repo.days()
    if days:
        today = repo.local(now).date()
        for s in daily_series(days, since=today - timedelta(days=42)):
            key = "day:" + s["date"]
            if key in st["awards"] or not s["z"] or date.fromisoformat(s["date"]) > today:
                continue
            steps_ok = s["z"].get("steps") is not None and s["z"]["steps"] >= C.DAY_STEPS_Z_AT_LEAST
            sleep_ok = s["z"].get("sleep_h") is not None and \
                abs(s["z"]["sleep_h"]) <= C.DAY_SLEEP_ABS_Z_AT_MOST
            if steps_ok or sleep_ok:
                _award(st, key, C.XP["day_normal"], "day_normal",
                       s["date"] + "T21:00:00+00:00", s["date"], new)
    advance(st, now)
    if save:
        repo.put(STATE_KEY, st)
    return st, new


def previous_plan(repo: PatientRepo, checkins: list[dict], c: dict) -> dict | None:
    day = _local_date(repo, c["started_at"])
    earlier = [x for x in checkins if x["id"] != c["id"] and x["started_at"] < c["started_at"]
               and _local_date(repo, x["started_at"]) < day and x.get("plan")]
    return earlier[-1] if earlier else None


def advance(st: dict, now: datetime) -> str | None:
    """Move the wandering on. Returns what happened: started | returned | None."""
    w = st["wandering"]
    if w["state"] == "away" and now >= datetime.fromisoformat(w["returns_at"]):
        told = [x.get("story_id") for x in st["wanderings"]]
        ids = lines.story_ids()
        fresh = [s for s in ids if s not in told] or ids
        w.update(state="back", returned_at=now.isoformat(), story_id=fresh[0])
        return "returned"
    if w["state"] == "home" and total(st) - st["glow_spent"] >= C.GLOW_CAPACITY_XP:
        st["glow_spent"] += C.GLOW_CAPACITY_XP
        n = len(st["wanderings"]) + 1
        st["wandering"] = {"state": "away", "id": f"wander-{n:04d}", "started_at": now.isoformat(),
                           "returns_at": (now + timedelta(hours=C.WANDERING_HOURS)).isoformat()}
        return "started"
    return None


def answer(st: dict, wandering_id: str, ans: str, now: datetime) -> bool:
    w = st["wandering"]
    if w["state"] != "back" or w.get("id") != wandering_id:
        return False
    st["wanderings"].append({"id": w["id"], "story_id": w["story_id"], "answer": ans,
                             "answered_at": now.isoformat(), "started_at": w["started_at"]})
    st["wandering"] = {"state": "home"}
    advance(st, now)
    return True


def facts(st: dict) -> dict:
    xp = total(st)
    stage, nxt = C.stage_for(xp)
    return {"xp": xp, "stage": stage, "next_stage_at": nxt, "glow": glow(st)}


def wandering_out(st: dict) -> dict:
    w = st["wandering"]
    return {"state": w["state"], "id": w.get("id"), "returns_at": w.get("returns_at"),
            "story": lines.story(w["story_id"]) if w["state"] == "back" else None}
