"""Decision trace: a readable, ordered record of how the mind reasoned.

Every pass of the mind's loop belongs to a CHAIN: everything caused by one
trigger (a day arriving, a round, a note, feedback, a rule change, a tick, a
clinician acknowledgement). Inside a chain each step is an ENTRY on one
LAYER, in this order:

  trigger -> watchers -> attention -> response -> level1 -> level2 -> notifier -> learning

The trace only describes; it never decides. Recording is wrapped so that a
failure to write an entry is logged and ignored: ingest and the mind behave
exactly the same with or without it.

Entries hold codes, ids, enums and numbers only. Never note text, never a
model's free text, never a raw path, never a pack alias.
"""

from __future__ import annotations

import contextlib
import itertools
import logging
from contextvars import ContextVar
from datetime import datetime, timezone

from ..security import new_id
from ..store import Store

log = logging.getLogger("clinic_engine.trace")

LAYERS = ("trigger", "watchers", "attention", "response", "level1", "level2", "notifier",
          "learning")

# Keys that may never appear anywhere in an entry's detail.
_FORBIDDEN = {"text", "note", "body", "password", "token", "pairing_code", "content", "alias",
              "points", "messages", "raw"}
_MAX_STR = 80
_MAX_LIST = 30
_KEEP = 2000  # stored entries per patient; older ones are pruned

_current: ContextVar["Chain | None"] = ContextVar("trace_chain", default=None)
_seq = itertools.count(1)


def clean(value, depth: int = 0):
    """Make a detail safe to store: drop forbidden keys, cut long strings and lists."""
    if depth > 5:
        return None
    if isinstance(value, dict):
        return {str(k)[:40]: clean(v, depth + 1) for k, v in value.items()
                if str(k) not in _FORBIDDEN}
    if isinstance(value, (list, tuple)):
        return [clean(v, depth + 1) for v in list(value)[:_MAX_LIST]]
    if isinstance(value, str):
        return value[:_MAX_STR]
    if isinstance(value, float):
        return round(value, 2)
    if value is None or isinstance(value, (bool, int)):
        return value
    return str(value)[:_MAX_STR]


def prefix(clinic_id: str, patient_id: str) -> str:
    return f"clinics/{clinic_id}/patients/{patient_id}/trace/"


class Chain:
    def __init__(self, tracer: "Tracer", clinic_id: str, patient_id: str, kind: str):
        self.tracer = tracer
        self.clinic_id = clinic_id
        self.patient_id = patient_id
        self.kind = kind
        self.id = new_id("chain")
        self.entries: list[dict] = []
        self.flushed = False
        self.has_trigger = False

    def add(self, layer: str, code: str, detail: dict | None = None,
            notable: bool = False) -> None:
        try:
            assert layer in LAYERS
            now = self.tracer.clock.now()
            e = {"id": new_id("tr"), "at": now.isoformat(), "chain_id": self.id,
                 "layer": layer, "code": str(code)[:48], "detail": clean(detail or {}),
                 "notable": bool(notable), "seq": next(_seq)}
            if layer == "trigger":
                self.has_trigger = True
            if self.flushed:  # a late entry (background review or reading)
                self.tracer.write(self, e)
            else:
                self.entries.append(e)
        except Exception as exc:  # noqa: BLE001 - the trace never breaks the mind
            log.warning("trace entry not recorded: %s", type(exc).__name__)

    @property
    def changed(self) -> bool:
        return any(e["notable"] for e in self.entries)


class Tracer:
    def __init__(self, store: Store, clock):
        self.store = store
        self.clock = clock

    def current(self, clinic_id: str, patient_id: str) -> Chain | None:
        ch = _current.get()
        if ch is not None and ch.clinic_id == clinic_id and ch.patient_id == patient_id:
            return ch
        return None

    @contextlib.contextmanager
    def chain(self, clinic_id: str, patient_id: str, kind: str, fresh: bool = False):
        """Join the chain already running for this patient, or start one.
        `fresh` always starts a chain of its own (the association appraisal)."""
        cur = self.current(clinic_id, patient_id)
        if cur is not None and not fresh:
            yield cur
            return
        ch = Chain(self, clinic_id, patient_id, kind)
        token = _current.set(ch)
        try:
            yield ch
        finally:
            _current.reset(token)
            self.flush(ch)

    def add(self, clinic_id: str, patient_id: str, layer: str, code: str,
            detail: dict | None = None, notable: bool = False, kind: str = "internal") -> None:
        """Add to the running chain; with none running, the entry gets its own chain."""
        try:
            with self.chain(clinic_id, patient_id, kind) as ch:
                ch.add(layer, code, detail, notable)
        except Exception as exc:  # noqa: BLE001
            log.warning("trace entry not recorded: %s", type(exc).__name__)

    def flush(self, ch: Chain) -> None:
        try:
            ch.flushed = True
            # A tick that found nothing to do leaves no trace (it runs every few minutes).
            if ch.kind == "tick" and not ch.changed and all(
                    e["layer"] in ("trigger", "watchers", "response") for e in ch.entries) and \
                    not any(e["layer"] == "watchers" and e["code"] == "fired"
                            for e in ch.entries):
                return
            if not ch.has_trigger:
                ch.entries.insert(0, {"id": new_id("tr"), "at": self.clock.now().isoformat(),
                                      "chain_id": ch.id, "layer": "trigger", "code": ch.kind,
                                      "detail": {}, "notable": False, "seq": next(_seq)})
                ch.has_trigger = True
            for e in ch.entries:
                self.write(ch, e)
            self.prune(ch.clinic_id, ch.patient_id)
        except Exception as exc:  # noqa: BLE001
            log.warning("trace chain not recorded: %s", type(exc).__name__)

    def write(self, ch: Chain, e: dict) -> None:
        try:
            ts = datetime.fromisoformat(e["at"]).astimezone(timezone.utc).strftime(
                "%Y%m%dT%H%M%S%f")
            self.store.put(f"{prefix(ch.clinic_id, ch.patient_id)}{ts}-{e['seq']:09d}.json", e)
        except Exception as exc:  # noqa: BLE001
            log.warning("trace entry not written: %s", type(exc).__name__)

    def prune(self, clinic_id: str, patient_id: str) -> None:
        keys = self.store.list(prefix(clinic_id, patient_id))
        for k in keys[:max(0, len(keys) - _KEEP)]:
            self.store.delete(k)


# ---- facts the watchers decided on (read-only, reuse the watchers' own helpers) ----

def watcher_facts(view) -> dict:
    from .watchers import deviation_need, deviation_now, last_data_date, recent_scored
    th = view.th
    out: dict = {}
    window = recent_scored(view, th.deviation_lookback, th.deviation_lookback + 2)
    sustained, lows = deviation_now(view)
    need = deviation_need(view)
    out["deviation"] = {"low_days": len(lows), "of_days": len(window), "needed": need,
                        "low_z": th.low_day_z,
                        "mean_low_z": round(sum(s["movement_z"] for s in lows) / len(lows), 2)
                        if lows else None, "sustained": sustained}
    last = last_data_date(view)
    out["silence"] = {"days_since_data": (view.today - last).days if last else None,
                      "needed": th.silence_days}
    latest = recent_scored(view, 1, 2)
    if latest and latest[-1]["z"]:
        m, z = max(latest[-1]["z"].items(), key=lambda kv: abs(kv[1]))
        out["novelty"] = {"day": latest[-1]["date"], "metric": m, "z": round(z, 2),
                          "needed": th.novelty_z}
    flagged = [n for n in view.notes if n.get("crisis")]
    out["notes"] = {"asked_for_help": len(flagged),
                    "low_mood_recent": sum(1 for n in view.notes[-10:] if n.get("mood") == "low")}
    s = view.scored_rounds()
    if s:
        out["rounds"] = {"last_energy": [r["energy_bucket"] for r in s[-3:]]}
    if view.activities:
        focus = [a for a in view.of_type("focus")][-th.activity_window:]
        faces = [a for a in view.activities if a.get("face_quality") == "good"][-th.activity_window:]
        out["activities"] = {
            "focus_reaction_z": [(a.get("z") or {}).get("median_reaction_ms") for a in focus],
            "slower_needed_z": th.slower_reaction_z,
            "face_activity_z": [(a.get("face_z") or {}).get("facial_activity") for a in faces],
            "face_smile_z": [(a.get("face_z") or {}).get("smile_rate_per_min") for a in faces],
            "flat_needed_z": th.face_flat_z,
            "adds_weight": view.activity_weight(),
            "last_finished": [a["ended_by"] == "finished" for a in view.activities[-3:]],
        }
    return out


def trigger_detail(repo, kind: str, data: dict) -> dict:
    """Non-sensitive facts about what started a chain: ids, dates and enums only."""
    d = {k: v for k, v in data.items() if isinstance(v, (str, int, float, bool)) and k != "text"}
    try:
        if kind == "round" and data.get("round_id"):
            r = repo.get(f"rounds/{data['round_id']}.json") or {}
            d.update(mode=r.get("mode"), energy_bucket=r.get("energy_bucket"),
                     ended_by=r.get("ended_by"), quality=r.get("quality"))
        elif kind == "activity" and data.get("activity_id"):
            a = repo.get(f"activities/{data['activity_id']}.json") or {}
            d.update(type=a.get("type"), ended_by=a.get("ended_by"), completed=a.get("completed"),
                     face_quality=a.get("face_quality"), suggested=bool(a.get("suggestion_id")),
                     z={k: v for k, v in (a.get("z") or {}).items()},
                     face_z={k: v for k, v in (a.get("face_z") or {}).items()
                             if k in ("facial_activity", "smile_rate_per_min")},
                     baseline_sessions=a.get("baseline_sessions"))
            if a.get("type") == "checkin":
                d.update(good_things=len(a.get("good_things") or []),
                         typed_items=sum(1 for g in (a.get("good_things") or []) if "note_id" in g)
                         + (1 if (a.get("plan") or {}).get("note_id") else 0),
                         plan_made=a.get("plan") is not None, plan_done=a.get("plan_done"),
                         asked_for_help=bool(a.get("crisis")))
        elif kind == "preferences":
            d["helps"] = repo.preferences()
        elif kind == "note" and data.get("note_id"):
            n = repo.get(f"notes/{data['note_id']}.json") or {}
            c = n.get("classification") or {}
            d.update({k: c.get(k) for k in ("mood", "topic", "crisis", "asks_for_help", "model")})
        elif kind == "feedback" and data.get("suggestion_id"):
            s = repo.get(f"suggestions/{data['suggestion_id']}.json") or {}
            d.update(action=s.get("action"), answer=s.get("answer"), felt=s.get("felt"))
        elif kind == "rule":
            d["rules"] = sorted({r["type"] for r in repo.rules()})
        elif kind == "ack" and data.get("attention_id"):
            it = repo.get(f"attention/{data['attention_id']}.json") or {}
            d["kind"] = it.get("kind")
    except Exception:  # noqa: BLE001
        pass
    return d


# ---- reading the trace back ----------------------------------------------------------------

def load_entries(store: Store, clinic_id: str, patient_id: str, limit: int = _KEEP) -> list[dict]:
    out = []
    for k in store.list(prefix(clinic_id, patient_id))[-limit:]:
        e = store.get(k)
        if e:
            out.append(e)
    return out


# ---- one row per chain: a headline (at most 6 words) and an outcome enum -----------

KIND_SHORT = {
    "deviation": "Movement drop", "novelty": "Unusual day", "silence": "No data",
    "oddity": "Odd values", "ignored": "Suggestions unanswered", "asked_for_help": "Asked for help",
    "low_notes": "Low mood notes", "weak_rounds": "Weak rounds", "round_mismatch": "Rounds disagree",
    "fading": "Slowing in rounds", "stopped_early": "Rounds stopped early",
    "not_played": "Activities not played", "slower_reactions": "Slower reactions",
    "face_flat": "Less facial movement", "checkins_stopped": "Check-ins stopped",
    "plans_not_done": "Plans not done",
}
ACTION_SHORT = {"breathing": "breathing", "focus_game": "Sparks and snow", "checkin": "check-in",
                "walk_10min": "a walk", "daylight_10min": "daylight", "call_someone": "a call"}
TRIGGER_SHORT = {
    "day": "Daily data", "activity": "Activity", "note": "Note", "feedback": "Answer",
    "rule": "Rule change", "tick": "Regular check", "scenario": "Demo scenario",
    "ack": "Acknowledged", "lesson_rejected": "Lesson rejected", "question_answered": "Question answered",
    "reading": "Movement reading", "reading_requested": "Movement reading", "round": "Round",
    "preferences": "Preferences set", "queued_message_due": "Queued message",
    "appraisal": "Association appraisal",
}
OUTCOMES = ("message_sent", "attention_opened", "attention_raised", "suggested",
            "attention_closed", "refused", "nothing")


def chain_row(entries: list[dict], trigger: str) -> tuple[str, str]:
    """(headline, outcome) for a chain, chosen by code from fixed sets."""
    found: dict[str, dict] = {}
    for e in entries:
        d = e.get("detail") or {}
        if e["layer"] == "notifier" and e["code"] == "sent":
            found.setdefault("message_sent", d)
        elif e["layer"] == "attention" and e["code"] == "opened":
            found.setdefault("attention_opened", d)
        elif e["layer"] == "attention" and e["code"] == "raised":
            found.setdefault("attention_raised", d)
        elif e["layer"] == "attention" and e["code"] == "closed":
            found.setdefault("attention_closed", d)
        elif e["layer"] == "response" and e["code"] == "suggested":
            found.setdefault("suggested", d)
        elif e["layer"] in ("level1", "level2") and e["code"] in ("refused", "partly_refused",
                                                                    "not_sent"):
            found.setdefault("refused", d)
    outcome = next((o for o in OUTCOMES if o in found), "nothing")
    d = found.get(outcome, {})
    kind = KIND_SHORT.get(d.get("kind"), "Attention")
    if outcome == "message_sent":
        head = "Needs-review message sent"
    elif outcome == "attention_opened":
        head = "Opened: " + kind
    elif outcome == "attention_raised":
        head = "Raised: " + kind
    elif outcome == "attention_closed":
        head = "Closed: " + kind
    elif outcome == "suggested":
        head = "Suggested " + ACTION_SHORT.get(d.get("action"), "an action")
    elif outcome == "refused":
        head = "Model answer refused"
    else:
        base = "Learning review" if trigger.startswith("review_") else \
            TRIGGER_SHORT.get(trigger, "Internal step")
        head = base + ", no change"
    return head, outcome


def _mentions(e: dict, attention_id: str) -> bool:
    d = e.get("detail") or {}
    return d.get("attention_id") == attention_id


def chains(entries: list[dict], chain_id: str | None = None, attention_id: str | None = None,
           changed_only: bool = False, limit: int = 30) -> list[dict]:
    by: dict[str, list[dict]] = {}
    for e in entries:
        by.setdefault(e["chain_id"], []).append(e)
    out = []
    for cid, es in by.items():
        es.sort(key=lambda e: (LAYERS.index(e["layer"]), e["seq"]))
        if chain_id and cid != chain_id:
            continue
        if attention_id and not any(_mentions(e, attention_id) for e in es):
            continue
        changed = any(e.get("notable") for e in es)
        if changed_only and not changed:
            continue
        trig = next((e for e in es if e["layer"] == "trigger"), es[0])
        headline, outcome = chain_row(es, trig["code"])
        out.append({"chain_id": cid, "at": min(e["at"] for e in es),
                    "last_seq": max(e["seq"] for e in es), "trigger": trig["code"],
                    "changed": changed, "headline": headline, "outcome": outcome,
                    "entries": [{k: e.get(k) for k in ("id", "at", "chain_id", "layer", "code",
                                                       "detail", "notable")} for e in es]})
    out.sort(key=lambda c: (c["at"], c["last_seq"]), reverse=True)
    for c in out:
        c.pop("last_seq")
    return out[:limit]


def current_state(entries: list[dict], items: list[dict]) -> list[dict]:
    """For each held item: its level, why it is at that level, and what was last done."""
    out = []
    newest_first = sorted(entries, key=lambda e: (e["at"], e["seq"]), reverse=True)
    for it in items:
        if it["state"] != "open":
            continue
        lvl = next((e for e in newest_first if e["layer"] == "attention"
                    and e["code"] in ("opened", "raised") and _mentions(e, it["id"])), None)
        opened = next((e for e in newest_first if e["layer"] == "attention"
                       and e["code"] == "opened" and _mentions(e, it["id"])), None)
        act = next((e for e in newest_first if e["layer"] in ("response", "notifier")
                    and _mentions(e, it["id"])), None)
        out.append({
            "attention_id": it["id"], "kind": it["kind"], "level": it["level"],
            "since": it["since"],
            "level_rule": ((lvl or {}).get("detail") or {}).get("rule") or it.get("reason"),
            "level_detail": ((lvl or {}).get("detail") or {}).get("facts") or it.get("detail") or {},
            "level_chain_id": (lvl or {}).get("chain_id"),
            "opened_chain_id": (opened or {}).get("chain_id"),
            "last_action": None if act is None else {
                "at": act["at"], "layer": act["layer"], "code": act["code"],
                "detail": act.get("detail") or {}, "chain_id": act["chain_id"]},
        })
    return out

