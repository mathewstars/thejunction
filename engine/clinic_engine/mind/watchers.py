"""Watchers: small pure functions that hold attention.

Each watcher looks at a read-only View of one patient and returns operations
(open, update, close) on attention items of its own kind. Watchers never
write anything; the engine applies their operations.

Attention is HELD: an item stays open, with its start date, until the data
recovers for some days or a clinician acknowledges it. After an
acknowledgement the same evidence does not reopen it; fresh evidence does.

Levels: watch < attention < urgent. "urgent" means a clinician should review
this today ("needs review"). It is not an emergency and not a diagnosis.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime, timedelta

from .thresholds import METRICS, PLAUSIBLE, T, Thresholds

LEVELS = ("watch", "attention", "urgent")
KINDS = ("deviation", "novelty", "silence", "oddity", "ignored", "asked_for_help", "low_notes",
         "weak_rounds", "round_mismatch", "fading", "stopped_early", "not_played",
         "slower_reactions", "face_flat", "checkins_stopped", "plans_not_done",
         "model_noticed")
# Kinds that sit at "watch" alone and rise to "attention" only while a
# movement drop is held (thresholds.py, rules for activity signals).
WEIGHT_ONLY = ("ignored", "low_notes", "weak_rounds", "not_played", "slower_reactions",
               "face_flat", "checkins_stopped", "plans_not_done", "model_noticed")
# Kinds the responder answers with a suggestion.
RESPONDABLE = ("deviation", "novelty", "low_notes")


def level_max(a: str, b: str) -> str:
    return a if LEVELS.index(a) >= LEVELS.index(b) else b


@dataclass
class View:
    today: date
    now: datetime
    days: dict[str, dict]  # accepted day records by ISO date
    series: list[dict]  # daily_series(): z-scores per day, oldest first
    has_baseline: bool
    items: list[dict]  # attention items, open and closed
    suggestions: list[dict]  # oldest first
    oddities: list[dict]  # recent rejected records: {at, date, reason}
    notes: list[dict]  # recent note classifications: {at, crisis, mood, ...}, no text
    contacts: list[str] = field(default_factory=list)  # ISO dates with rounds/feedback/notes
    rounds: list[dict] = field(default_factory=list)  # processed rounds (earlier design)
    activities: list[dict] = field(default_factory=list)  # processed activities, oldest first
    tz: object = None  # the patient's time zone
    th: Thresholds = T
    days_reading: dict | None = None  # the stored day reading (level 2 read, code checked)

    def model_noticed(self) -> dict:
        """What the level-2 model found that the fixed rules did not flag and
        that code confirmed in the numbers; {} when there is nothing.

        - daily numbers: a stretch only the model named, lower, confirmed by
          code's check (day_reading.check_stretch), still going on at the end
          of the window, in a reading not older than model_notice_max_age_days;
        - face: in the last two sessions the model read, the fixed rule counted
          no smile while the model found faint ones that code confirmed, and an
          earlier session had clear smiles (smiles have become faint).

        Only items that passed code's check count. A model's word alone never
        reaches this."""
        th, out = self.th, {}
        dr = self.days_reading or {}
        if dr.get("status") == "ready" and dr.get("at") and dr.get("stream"):
            age = self.now - datetime.fromisoformat(dr["at"])
            last_d = dr["stream"]["days"] - 1
            hits = [s for s in (dr.get("reading") or {}).get("stretches", [])
                    if s.get("status") == "model_only" and s.get("direction") == "lower"
                    and s.get("channel") in ("steps", "walk_speed", "sleep_h", "hrv")
                    and s.get("end_d", -1) >= last_d - th.model_notice_recent_days]
            if hits and age <= timedelta(days=th.model_notice_max_age_days):
                best = max(hits, key=lambda s: s.get("days", 0))
                out.update(daily_channel=best["channel"], daily_shape=best["shape"],
                           daily_days=best.get("days"))
        read = [a["frames_reading"]["agreement"] for a in self.activities
                if (a.get("frames_reading") or {}).get("status") == "ready"
                and (a["frames_reading"].get("agreement") or {}).get("smiles_code") is not None]
        read = read[-th.model_notice_face_window:]
        if len(read) >= 3:
            recent, earlier = read[-2:], read[:-2]
            if all(g["smiles_code"] == 0 and (g.get("smiles_faint") or 0) >= 1 for g in recent) \
                    and any(g["smiles_code"] >= 2 for g in earlier):
                out.update(faint_sessions=len(recent),
                           faint_smiles=sum(g.get("smiles_faint") or 0 for g in recent))
        return out

    def of_type(self, typ: str) -> list[dict]:
        return [a for a in self.activities if a["type"] == typ]

    def slower_reactions(self) -> list[dict]:
        """Focus sessions among the last few whose reaction time is clearly
        slower than own normal; [] unless at least activity_min_hits."""
        th = self.th
        last = [a for a in self.of_type("focus")
                if (a.get("z") or {}).get("median_reaction_ms") is not None][-th.activity_window:]
        hits = [a for a in last if a["z"]["median_reaction_ms"] >= th.slower_reaction_z
                or _read(a, "reactions") == "slower"]
        return hits if len(last) >= th.activity_window and len(hits) >= th.activity_min_hits else []

    def face_flat(self) -> list[dict]:
        """Good-quality face sessions (focus or breathing) among the last few
        where facial activity or smiling is clearly below own normal."""
        th = self.th
        last = [a for a in self.activities if a.get("face_quality") == "good"
                and any(v is not None for v in (a.get("face_z") or {}).values())][-th.activity_window:]
        def flat(a: dict) -> bool:
            fz = a["face_z"]
            return any(fz.get(k) is not None and fz[k] <= th.face_flat_z
                       for k in ("facial_activity", "smile_rate_per_min")) \
                or _read(a, "expression") == "less_expressive"
        hits = [a for a in last if flat(a)]
        return hits if len(last) >= th.activity_window and len(hits) >= th.activity_min_hits else []

    def activity_weight(self) -> bool:
        return bool(self.slower_reactions() or self.face_flat())

    def scored_rounds(self) -> list[dict]:
        """Good-quality rounds that have an energy bucket (own baseline exists)."""
        return [r for r in self.rounds if r.get("quality") == "good" and r.get("energy_bucket")]

    def weak_rounds(self) -> bool:
        s = self.scored_rounds()
        return len(s) >= 2 and all(r["energy_bucket"] == "low" for r in s[-2:])

    def open_item(self, kind: str) -> dict | None:
        for it in self.items:
            if it["kind"] == kind and it["state"] == "open":
                return it
        return None

    def last_closed(self, kind: str) -> dict | None:
        closed = [it for it in self.items if it["kind"] == kind and it["state"] == "closed"]
        return max(closed, key=lambda it: it["closed_at"]) if closed else None


def _read(a: dict, field: str) -> str | None:
    """A claim from the level-2 session reading that code confirmed."""
    return (((a.get("analysis") or {}).get("reading")) or {}).get(field)


@dataclass
class Op:
    op: str  # open | update | close
    kind: str
    item_id: str | None = None
    since: str | None = None
    level: str = "watch"
    reason: str | None = None
    detail: dict = field(default_factory=dict)


# ---- helpers ---------------------------------------------------------------

def recent_scored(view: View, n: int, max_age_days: int) -> list[dict]:
    """Last n days that have a movement z, inside the last max_age_days."""
    cutoff = view.today - timedelta(days=max_age_days - 1)
    scored = [s for s in view.series
              if s["movement_z"] is not None and date.fromisoformat(s["date"]) >= cutoff
              and date.fromisoformat(s["date"]) <= view.today]
    return scored[-n:]


def last_data_date(view: View) -> date | None:
    past = [date.fromisoformat(d) for d in view.days if date.fromisoformat(d) <= view.today]
    return max(past) if past else None


def deviation_now(view: View) -> tuple[bool, list[dict]]:
    """True when at least 3 of the last 5 days with data are clearly low.
    Two weak rounds in a row lower the need by one day: the round adds
    evidence and can raise attention earlier, but never alone."""
    th = view.th
    window = recent_scored(view, th.deviation_lookback, th.deviation_lookback + 2)
    lows = [s for s in window if s["movement_z"] <= th.low_day_z]
    return len(lows) >= deviation_need(view), lows


def deviation_need(view: View) -> int:
    """Low days needed. Weak rounds, slower reactions or a flatter face add
    weight: one low day fewer, never fewer than two. Never a deviation alone."""
    th = view.th
    need = th.deviation_min_low
    if view.weak_rounds() or view.activity_weight():
        need = max(2, need - max(th.round_weak_lowers_deviation_by,
                                 th.activity_lowers_deviation_by))
    return need


def silent(view: View) -> bool:
    last = last_data_date(view)
    return last is None or (view.today - last).days >= view.th.silence_days


# ---- watchers ----------------------------------------------------------------

def watch_deviation(view: View) -> list[Op]:
    th = view.th
    item = view.open_item("deviation")
    sustained, lows = deviation_now(view)
    if item is None:
        if not sustained:
            return []
        prev = view.last_closed("deviation")
        if prev and prev.get("close_reason") == "acknowledged":
            # The clinician saw it. Only low days after the acknowledgement count.
            fresh = [s for s in lows if s["date"] > prev.get("acked_through", "")]
            if len(fresh) < th.deviation_min_low:
                return []
        mean_z = sum(s["movement_z"] for s in lows) / len(lows)
        return [Op("open", "deviation", since=lows[0]["date"], level="attention",
                   reason="sustained_drop",
                   detail={"low_days": len(lows), "mean_low_z": round(mean_z, 2)})]
    # Held: close only after a run of recovered days.
    recent = recent_scored(view, th.recovery_days, th.recovery_days + 2)
    if len(recent) >= th.recovery_days and all(s["movement_z"] > th.recovered_z for s in recent):
        return [Op("close", "deviation", item_id=item["id"], reason="recovered")]
    if lows:
        mean_z = sum(s["movement_z"] for s in lows) / len(lows)
        return [Op("update", "deviation", item_id=item["id"],
                   detail={"low_days": len(lows), "mean_low_z": round(mean_z, 2)})]
    return []


def watch_novelty(view: View) -> list[Op]:
    th = view.th
    item = view.open_item("novelty")
    recent = recent_scored(view, 1, 2)
    latest = recent[-1] if recent else None
    novel = None
    if latest:
        for m, z in latest["z"].items():
            if abs(z) >= th.novelty_z:
                novel = (m, z)
                break
    if novel and item is None:
        m, z = novel
        prev = view.last_closed("novelty")
        if prev and prev.get("detail", {}).get("day") == latest["date"]:
            return []  # the same day already raised and closed it
        return [Op("open", "novelty", since=latest["date"], level="watch", reason="far_from_normal",
                   detail={"day": latest["date"], "metric": m,
                           "direction": "down" if z < 0 else "up"})]
    if item is not None:
        if novel:
            return [Op("update", "novelty", item_id=item["id"],
                       detail={**item.get("detail", {}), "day": latest["date"]})]
        last_novel = date.fromisoformat(item.get("detail", {}).get("day", item["since"]))
        later = [s for s in view.series if s["movement_z"] is not None
                 and date.fromisoformat(s["date"]) > last_novel]
        if len(later) >= th.novelty_close_days:
            return [Op("close", "novelty", item_id=item["id"], reason="settled")]
    return []


def watch_silence(view: View) -> list[Op]:
    """No daily data for N days. Silence never reads as "within"."""
    th = view.th
    item = view.open_item("silence")
    last = last_data_date(view)
    if silent(view):
        since = (last + timedelta(days=1)).isoformat() if last else view.today.isoformat()
        cutoff = (view.today - timedelta(days=th.silence_days - 1)).isoformat()
        had_contact = any(c >= cutoff for c in view.contacts)
        level = "watch" if had_contact else "attention"
        detail = {"days_without_data": (view.today - last).days if last else None,
                  "other_contact": had_contact}
        if item is None:
            return [Op("open", "silence", since=since, level=level, reason="no_daily_data",
                       detail=detail)]
        return [Op("update", "silence", item_id=item["id"], level=level, detail=detail)]
    if item is not None:
        return [Op("close", "silence", item_id=item["id"], reason="data_arrived")]
    return []


def watch_oddity(view: View) -> list[Op]:
    th = view.th
    item = view.open_item("oddity")
    cutoff = view.now - timedelta(days=th.oddity_hold_days)
    recent = [o for o in view.oddities if datetime.fromisoformat(o["at"]) >= cutoff]
    if recent:
        detail = {"rejected_records": len(recent),
                  "reasons": sorted({o["reason"] for o in recent})}
        if item is None:
            return [Op("open", "oddity", since=recent[0]["at"][:10], level="watch",
                       reason="implausible_data", detail=detail)]
        return [Op("update", "oddity", item_id=item["id"], detail=detail)]
    if item is not None:
        return [Op("close", "oddity", item_id=item["id"], reason="clean_again")]
    return []


def watch_ignored(view: View) -> list[Op]:
    th = view.th
    item = view.open_item("ignored")
    resolved = [s for s in view.suggestions if s["status"] != "open"]
    last_n = resolved[-th.ignored_in_a_row:]
    ignored = len(last_n) >= th.ignored_in_a_row and all(s["status"] == "expired" for s in last_n)
    if ignored and item is None:
        return [Op("open", "ignored", since=last_n[0]["date"], level="watch",
                   reason="no_answers", detail={"unanswered_in_a_row": len(last_n)})]
    if item is not None and resolved and resolved[-1]["status"] != "expired":
        return [Op("close", "ignored", item_id=item["id"], reason="answered_again")]
    return []


def watch_help(view: View) -> list[Op]:
    """A note that asks for help opens an urgent item, closed only by a clinician."""
    item = view.open_item("asked_for_help")
    flagged = [n for n in view.notes if n.get("crisis")]
    if not flagged:
        return []
    latest = max(flagged, key=lambda n: n["at"])
    if item is None:
        prev = view.last_closed("asked_for_help")
        if prev and latest["at"] <= prev.get("closed_at", ""):
            return []
        return [Op("open", "asked_for_help", since=latest["at"][:10], level="urgent",
                   reason="note_flagged", detail={"notes_flagged": len(flagged)})]
    return [Op("update", "asked_for_help", item_id=item["id"], level="urgent",
               detail={"notes_flagged": len(flagged)})]


def watch_low_notes(view: View) -> list[Op]:
    item = view.open_item("low_notes")
    cutoff = (view.now - timedelta(days=5)).isoformat()
    lows = [n for n in view.notes if n["at"] >= cutoff and n.get("mood") == "low"]
    if len(lows) >= 2:
        if item is None:
            return [Op("open", "low_notes", since=lows[0]["at"][:10], level="watch",
                       reason="low_mood_notes", detail={"low_notes": len(lows)})]
        return [Op("update", "low_notes", item_id=item["id"], detail={"low_notes": len(lows)})]
    if item is not None:
        return [Op("close", "low_notes", item_id=item["id"], reason="settled")]
    return []


# ---- round watchers (docs/game-interface.md, section 4, step 5) -----------------

def _simple(view: View, kind: str, active: bool, since: str | None, reason: str,
            detail: dict, close_reason: str) -> list[Op]:
    item = view.open_item(kind)
    if active and item is None:
        return [Op("open", kind, since=since or view.today.isoformat(), level="watch",
                   reason=reason, detail=detail)]
    if active and item is not None and detail != item.get("detail"):
        return [Op("update", kind, item_id=item["id"], detail=detail)]
    if not active and item is not None:
        return [Op("close", kind, item_id=item["id"], reason=close_reason)]
    return []


def watch_weak_rounds(view: View) -> list[Op]:
    s = view.scored_rounds()
    active = view.weak_rounds()
    return _simple(view, "weak_rounds", active, s[-2]["started_at"][:10] if active else None,
                   "two_weak_rounds", {"rounds": 2} if active else {}, "round_usual_again")


def watch_round_mismatch(view: View) -> list[Op]:
    """Rounds and daily data disagree: weak rounds on normal days, or the other way."""
    s = view.scored_rounds()
    if not s or not view.has_baseline:
        return _simple(view, "round_mismatch", False, None, "", {}, "agree_again")
    days_low, _ = deviation_now(view)
    last = s[-1]["energy_bucket"]
    which = None
    if view.weak_rounds() and not days_low:
        which = "rounds_low_days_usual"
    elif days_low and last in ("usual", "high"):
        which = "days_low_rounds_usual"
    return _simple(view, "round_mismatch", which is not None, s[-1]["started_at"][:10],
                   "rounds_and_days_disagree", {"which": which} if which else {}, "agree_again")


def watch_fading(view: View) -> list[Op]:
    """A growing fade: speed drops more within rounds, or a checked reading says slowing."""
    th = view.th
    s = view.scored_rounds()[-3:]
    fz = [r["z"].get("fade") for r in s]
    growing = len(fz) == 3 and all(v is not None for v in fz) and fz[0] > fz[1] > fz[2]         and fz[2] <= th.round_fade_z
    read_slowing = sum(1 for r in s if ((r.get("analysis") or {}).get("reading") or {})
                       .get("pattern") == "slowing") >= 2
    active = growing or read_slowing
    return _simple(view, "fading", active, s[0]["started_at"][:10] if active else None,
                   "growing_fade", {"from_reading": read_slowing and not growing} if active else {},
                   "fade_settled")


def watch_stopped_early(view: View) -> list[Op]:
    th = view.th
    last3 = [r for r in view.rounds if r.get("quality") is not None][-3:]
    stopped = [r for r in last3 if r["ended_by"] == "user_stopped"]
    active = len(stopped) >= th.round_stopped_early_of_3
    return _simple(view, "stopped_early", active, stopped[0]["started_at"][:10] if active else None,
                   "rounds_stopped_early", {"of_last_3": len(stopped)} if active else {},
                   "finished_again")


PLAYABLE = ("breathing", "focus_game", "checkin", "ar_round", "ar_round_seated")


def watch_not_played(view: View) -> list[Op]:
    """Activities (or, earlier, rounds) offered but not played, several in a row."""
    th = view.th
    played_for = {r.get("suggestion_id") for r in view.rounds} | \
        {a.get("suggestion_id") for a in view.activities}
    offered = [s for s in view.suggestions if s["action"] in PLAYABLE and s["status"] != "open"]
    last = offered[-th.activity_not_played_in_a_row:]
    def played(s: dict) -> bool:
        return s["id"] in played_for or s.get("round_completed") or s.get("played") \
            or s.get("answer") == "did_it"
    active = len(last) >= th.activity_not_played_in_a_row and not any(played(s) for s in last)
    return _simple(view, "not_played", active, last[0]["date"] if active else None,
                   "activities_offered_not_played", {"in_a_row": len(last)} if active else {},
                   "played_again")


# ---- activity watchers (docs/game-design.md; rules in thresholds.py) -------------------

def _local_day(view: View, iso: str) -> date:
    dt = datetime.fromisoformat(iso)
    return (dt.astimezone(view.tz) if view.tz else dt).date()


def watch_slower_reactions(view: View) -> list[Op]:
    hits = view.slower_reactions()
    return _simple(view, "slower_reactions", bool(hits),
                   _local_day(view, hits[0]["started_at"]).isoformat() if hits else None,
                   "reactions_slower_than_usual",
                   {"slower_sessions": len(hits), "of_last": view.th.activity_window,
                    "max_z": max(a["z"]["median_reaction_ms"] for a in hits)} if hits else {},
                   "reactions_usual_again")


def watch_face_flat(view: View) -> list[Op]:
    hits = view.face_flat()
    return _simple(view, "face_flat", bool(hits),
                   _local_day(view, hits[0]["started_at"]).isoformat() if hits else None,
                   "face_less_active_than_usual",
                   {"flat_sessions": len(hits), "of_last": view.th.activity_window} if hits else {},
                   "face_usual_again")


def watch_model_noticed(view: View) -> list[Op]:
    """A flag for the clinic from what the level-2 model found and code
    confirmed. It sits at "watch" alone and, like the other activity signals,
    rises to "attention" only while a movement drop is held. It never brings a
    suggestion to the patient and never an alert by itself."""
    found = view.model_noticed()
    return _simple(view, "model_noticed", bool(found), view.today.isoformat() if found else None,
                   "model_found_confirmed_by_code", found, "model_no_longer_reports_it")


def watch_checkins_stopped(view: View) -> list[Op]:
    th = view.th
    days = sorted({_local_day(view, a["started_at"]) for a in view.of_type("checkin")})
    recent_cut = view.today - timedelta(days=th.checkins_stopped_days - 1)
    habit_from = recent_cut - timedelta(days=14)
    habit = [d for d in days if habit_from <= d < recent_cut]
    recent = [d for d in days if d >= recent_cut]
    active = len(habit) >= th.checkins_habit_min and not recent
    since = (max(habit) + timedelta(days=1)).isoformat() if active else None
    return _simple(view, "checkins_stopped", active, since, "checkins_stopped",
                   {"days_without": (view.today - max(habit)).days,
                    "checkins_before": len(habit)} if active else {},
                   "checkin_again")


def watch_plans_not_done(view: View) -> list[Op]:
    th = view.th
    answered = [a for a in view.of_type("checkin") if a.get("plan_done") in ("yes", "no")]
    last = answered[-th.plans_not_done_in_a_row:]
    active = len(last) >= th.plans_not_done_in_a_row and all(a["plan_done"] == "no" for a in last)
    return _simple(view, "plans_not_done", active,
                   _local_day(view, last[0]["started_at"]).isoformat() if active else None,
                   "plans_repeatedly_not_done", {"in_a_row": len(last)} if active else {},
                   "plan_done_again")


WATCHERS = [watch_silence, watch_oddity, watch_deviation, watch_novelty, watch_ignored,
            watch_help, watch_low_notes, watch_weak_rounds, watch_round_mismatch, watch_fading,
            watch_stopped_early, watch_not_played, watch_slower_reactions, watch_face_flat,
            watch_checkins_stopped, watch_plans_not_done, watch_model_noticed]


def run_watchers(view: View) -> list[Op]:
    ops: list[Op] = []
    for w in WATCHERS:
        ops.extend(w(view))
    return ops


# ---- escalation --------------------------------------------------------------

def escalate(items: list[dict], view: View, why: dict[str, str] | None = None) -> dict[str, str]:
    """Return {item_id: level} for open items, from plain documented rules.

    - deviation is "attention"; it becomes "urgent" (needs review) when
      a) the drop is deep (4 of the last 5 days low, mean z <= -2.5) AND
         suggestions are being left unanswered, or
      b) the drop is followed by silence (no data while it is held), or
      c) it has been held for 10 days or more.
    - ignored, low_notes, weak_rounds, not_played and the activity kinds
      (slower_reactions, face_flat, checkins_stopped, plans_not_done) rise
      from "watch" to "attention" only while a deviation is held. Alone they
      stay at "watch".
    - two weak rounds in a row, slower reactions or a flatter face also let
      the deviation open one low day earlier (see deviation_need); they never
      open a deviation alone.
    - asked_for_help is always "urgent".
    These rules never lower a level while an item is held. With
    TRIAGE_MODE=models the two model levels can, within the floors in
    mind/triage.py.

    `why`, when given, receives {item_id: rule code} naming the rule that set
    each level (for the decision trace; it never changes the result).
    """
    th = view.th
    open_by_kind = {it["kind"]: it for it in items if it["state"] == "open"}
    out: dict[str, str] = {}
    dev = open_by_kind.get("deviation")
    for kind, it in open_by_kind.items():
        level = it.get("level", "watch")
        rule = "kept_level"
        if kind == "deviation":
            level = level_max(level, "attention")
            rule = "deviation_is_attention"
            _, lows = deviation_now(view)
            deep = (len(lows) >= th.urgent_deep_min_low
                    and sum(s["movement_z"] for s in lows) / len(lows) <= th.urgent_deep_z)
            held_days = (view.today - date.fromisoformat(it["since"])).days
            if (deep and "ignored" in open_by_kind) or "silence" in open_by_kind \
                    or held_days >= th.urgent_held_days:
                level = "urgent"
                rule = ("deep_drop_and_unanswered" if deep and "ignored" in open_by_kind
                        else "silence_while_held" if "silence" in open_by_kind
                        else "held_too_long")
        elif kind in WEIGHT_ONLY and dev is not None:
            level = level_max(level, "attention")
            rule = "raised_while_drop_held"
        elif kind == "asked_for_help":
            level = "urgent"
            rule = "asked_for_help_is_urgent"
        out[it["id"]] = level
        if why is not None:
            why[it["id"]] = rule
    return out


# ---- status -------------------------------------------------------------------

def compute_status(view: View) -> str:
    """no_data | no_baseline | outside | within. Thresholds only, never lessons."""
    if silent(view):
        return "no_data"
    if not view.has_baseline:
        return "no_baseline"
    sustained, _ = deviation_now(view)
    if sustained or view.open_item("deviation") is not None:
        return "outside"
    return "within"


# ---- oddity check at ingest ------------------------------------------------

def check_day(rec: dict, today: date, th: Thresholds = T) -> str | None:
    """Return a reason code when a day record cannot be true, else None."""
    try:
        d = date.fromisoformat(rec["date"])
    except (KeyError, ValueError):
        return "bad_date"
    if d > today + timedelta(days=1):
        return "future_date"
    if d < today - timedelta(days=400):
        return "too_old"
    for m in METRICS:
        v = rec.get(m)
        if v is None:
            continue
        lo, hi = PLAUSIBLE[m]
        if v != v or v < 0:  # NaN or negative
            return f"negative_{m}"
        if not (lo <= v <= hi):
            return f"implausible_{m}"
    return None
