"""The mind: events -> watchers -> attention items -> responder -> memory/learning.

Every ingest (a day, a round, feedback, a note, a rule change, an answer, a
clinician acknowledgement) is published as an Event on an in-process bus. The
mind reacts to each event:

  1. expire stale suggestions (an unanswered suggestion is evidence too)
  2. run the watchers over a read-only View and apply their operations
  3. escalate levels by plain rules; the first time an item reaches
     "urgent", the notifier is asked to send one "needs review" message
  4. respond: if held attention needs an answer, code picks ONE action and
     a level-1 model may word it through the gates
  5. learn: after feedback, answers and rejections (and on the tick), the
     review builds evidence, proposes and validates lessons

A light periodic tick exists only because silence cannot announce itself.
Callers hold the patient's asyncio lock while publishing.
"""

from __future__ import annotations

import asyncio
import logging
from collections import defaultdict, deque
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from typing import Awaitable, Callable

from ..audit import audit_prefix, write_audit
from ..config import Settings
from ..security import new_id
from ..store import Store
from . import learn
from .baseline import baseline_for, daily_series, has_baseline, series_against
from . import lines, xp
from .catalog import QUESTIONS, plain_name
from .gates import INPUT_GATE, OUTPUT_GATE, GateError, GateRefusal, Pack
from .repo import PatientRepo
from .respond import blocked_reason, needs_response, pick_action, rank_actions
from .thresholds import T, Thresholds
from .trace import Tracer, trigger_detail, watcher_facts
from .watchers import LEVELS, RESPONDABLE, WATCHERS, Op, View, escalate

log = logging.getLogger("clinic_engine.mind")

# Audit actions of the clinician-only outputs (the association appraisal and its
# ratings, the frame reading). The learning review never sees them.
RESEARCH_ACTIONS = {"association_appraisal", "association_run", "rating_add", "rating_delete",
                    "frames_reading", "days_reading"}
RESEARCH_TASKS = {"association", "frames_reading", "days_reading"}


def is_research_event(ev: dict) -> bool:
    return ev.get("action") in RESEARCH_ACTIONS or \
        (ev.get("action") == "gate_refusal" and
         (ev.get("detail") or {}).get("task") in RESEARCH_TASKS)


# ---- clock ------------------------------------------------------------------------

class Clock:
    def now(self) -> datetime:
        return datetime.now(timezone.utc)


class FixedClock(Clock):
    """For tests and demos: time moves only when told."""

    def __init__(self, at: datetime):
        self.at = at

    def now(self) -> datetime:
        return self.at

    def advance(self, **kw) -> None:
        self.at += timedelta(**kw)


# ---- bus ----------------------------------------------------------------------------

@dataclass
class Event:
    kind: str  # day | activity | round | feedback | note | rule | preferences | lesson_rejected | question_answered | ack | tick | scenario | reading
    clinic_id: str
    patient_id: str
    at: str
    data: dict = field(default_factory=dict)  # ids and enums only


Handler = Callable[[Event], Awaitable[None]]


class Bus:
    def __init__(self) -> None:
        self._subs: dict[str, list[Handler]] = defaultdict(list)
        self.recent: deque[dict] = deque(maxlen=200)

    def subscribe(self, kind: str, handler: Handler) -> None:
        self._subs[kind].append(handler)

    async def publish(self, ev: Event) -> None:
        self.recent.append({"kind": ev.kind, "at": ev.at})
        for h in self._subs.get(ev.kind, []) + self._subs.get("*", []):
            await h(ev)


# ---- the mind -------------------------------------------------------------------------

REVIEW_TRIGGERS = ("feedback", "round", "activity", "question_answered", "lesson_rejected",
                   "preferences")


class Mind:
    def __init__(self, store: Store, settings: Settings, clock: Clock, local_model, outreach,
                 notifications, th: Thresholds = T):
        self.store = store
        self.settings = settings
        self.clock = clock
        self.local = local_model
        self.outreach = outreach
        self.notifications = notifications
        self.th = th
        self.bus = Bus()
        self.bus.subscribe("*", self._on_event)
        # The decision trace: describes each step, never decides (see trace.py).
        self.tracer = Tracer(store, clock)
        if notifications is not None:
            notifications.trace_hook = self._trace_notify
        self._locks: dict[tuple[str, str], asyncio.Lock] = {}
        self._tasks: set[asyncio.Task] = set()
        self._appraising: set[tuple[str, str]] = set()

    # ---- plumbing --------------------------------------------------------------------

    def lock(self, clinic_id: str, patient_id: str) -> asyncio.Lock:
        key = (clinic_id, patient_id)
        if key not in self._locks:
            self._locks[key] = asyncio.Lock()
        return self._locks[key]

    def repo(self, clinic_id: str, patient_id: str) -> PatientRepo:
        return PatientRepo(self.store, clinic_id, patient_id)

    async def publish(self, kind: str, clinic_id: str, patient_id: str, **data) -> None:
        """Caller must hold self.lock(clinic_id, patient_id)."""
        ev = Event(kind, clinic_id, patient_id, self.clock.now().isoformat(), data)
        with self.tracer.chain(clinic_id, patient_id, kind):
            await self.bus.publish(ev)

    def trace(self, repo: PatientRepo, layer: str, code: str, detail: dict | None = None,
              notable: bool = False) -> None:
        """Record one step of the current chain. Never raises."""
        self.tracer.add(repo.clinic_id, repo.patient_id, layer, code, detail, notable)

    def _trace_notify(self, clinic_id: str, patient_id: str, outcome: str, reason: str,
                      item_id: str, level: str) -> None:
        code = {"sent": "sent", "outside_hours_queued": "queued"}.get(reason, "suppressed")
        if reason == "send_failed":
            code = "failed"
        self.tracer.add(clinic_id, patient_id, "notifier", code,
                        {"attention_id": item_id, "level": level, "reason": reason,
                         "mode": self.settings.notify_mode},
                        notable=code in ("sent", "queued"), kind="queued_message_due")

    def audit(self, repo: PatientRepo, action: str, outcome: str = "ok", reason: str | None = None,
              actor: str = "mind", **detail) -> None:
        write_audit(self.store, self.clock.now(), clinic_id=repo.clinic_id,
                    patient_id=repo.patient_id, actor=actor, action=action, outcome=outcome,
                    reason=reason, detail=detail)

    def refuse(self, repo: PatientRepo, r: GateRefusal) -> None:
        self.audit(repo, "gate_refusal", "refused", r.reason, **r.as_detail())

    async def idle(self) -> None:
        """Wait for background reviews (tests)."""
        while self._tasks:
            await asyncio.gather(*list(self._tasks), return_exceptions=True)

    def all_patients(self) -> list[tuple[str, str]]:
        out = []
        for k in self.store.list("patients/"):
            rec = self.store.get(k)
            if rec:
                out.append((rec["clinic_id"], rec["patient_id"]))
        return out

    # ---- view ---------------------------------------------------------------------------

    def build_view(self, repo: PatientRepo, now: datetime | None = None) -> View:
        now = now or self.clock.now()
        local = repo.local(now)
        today = local.date()
        days = repo.days()
        series = daily_series(days, self.th, since=today - timedelta(days=42))
        tz = repo.tz()
        contacts = [datetime.fromisoformat(r["started_at"]).astimezone(tz).date().isoformat()
                    for r in repo.rounds()]
        contacts += [datetime.fromisoformat(f["received_at"]).astimezone(tz).date().isoformat()
                     for f in repo.feedback()]
        notes = repo.note_classes()
        contacts += [datetime.fromisoformat(n["at"]).astimezone(tz).date().isoformat() for n in notes]
        acts = repo.activities()
        contacts += [datetime.fromisoformat(a["started_at"]).astimezone(tz).date().isoformat()
                     for a in acts]
        return View(today=today, now=now, days=days, series=series,
                    has_baseline=has_baseline(baseline_for(days, today, self.th)),
                    items=repo.items(), suggestions=repo.suggestions(),
                    oddities=repo.oddities(), notes=notes, contacts=contacts,
                    rounds=repo.rounds(), activities=acts, tz=tz, th=self.th,
                    days_reading=repo.get("research/days_reading.json"))

    # ---- the event handler -------------------------------------------------------------

    async def _on_event(self, ev: Event) -> None:
        repo = self.repo(ev.clinic_id, ev.patient_id)
        patient = repo.patient()
        if patient is None:
            return
        now = self.clock.now()
        ch = self.tracer.current(ev.clinic_id, ev.patient_id)
        if ch is not None and not ch.has_trigger:
            ch.add("trigger", ev.kind, trigger_detail(repo, ev.kind, ev.data))
        self.expire_suggestions(repo, now)
        try:
            # Lanvi's XP and wanderings: only ever adds; never part of a decision.
            xp.sync(repo, now)
        except Exception:  # noqa: BLE001
            log.exception("xp sync failed")
        await self.observe(repo, patient, now)
        await self.respond(repo, now)
        if ev.kind in REVIEW_TRIGGERS:
            await self.schedule_review(repo, ev.kind)
        elif ev.kind == "tick":
            last = repo.state().get("last_review_at")
            if not last or now - datetime.fromisoformat(last) > timedelta(hours=24):
                await self.schedule_review(repo, "tick")
            if self.appraisal_due(repo, now):
                await self.schedule_appraisal(repo)

    def expire_suggestions(self, repo: PatientRepo, now: datetime) -> None:
        today = repo.local(now).date().isoformat()
        for s in repo.suggestions():
            if s["status"] != "open":
                continue
            age = now - datetime.fromisoformat(s["created_at"])
            if age > timedelta(hours=self.th.suggestion_ttl_hours) or s["date"] < today:
                s.update(status="expired", resolved_at=now.isoformat())
                repo.put(f"suggestions/{s['id']}.json", s)
                self.audit(repo, "suggestion_expired", suggestion_id=s["id"], action_id=s["action"])

    # ---- 2 and 3: attention ------------------------------------------------------------

    async def observe(self, repo: PatientRepo, patient: dict, now: datetime) -> list[dict]:
        view = self.build_view(repo, now)
        fired, quiet, all_ops = [], [], []
        for w in WATCHERS:  # the same order as run_watchers(); all run before any apply
            name = w.__name__.removeprefix("watch_")
            ops = w(view)
            all_ops.extend(ops)
            if not ops:
                quiet.append(name)
            for op in ops:
                fired.append({"watcher": name, "op": op.op, "kind": op.kind,
                              "reason": op.reason, "level": op.level if op.op != "close" else None,
                              "detail": op.detail})
        for op in all_ops:
            self._apply(repo, op, now)
        try:
            facts = watcher_facts(view)
        except Exception:  # noqa: BLE001
            facts = {}
        self.trace(repo, "watchers", "fired" if fired else "quiet",
                   {"fired": fired, "quiet": quiet, "facts": facts})
        view = self.build_view(repo, now)
        why: dict[str, str] = {}
        levels = escalate(view.items, view, why)
        for it in view.items:
            if it["state"] != "open":
                continue
            new = levels.get(it["id"], it["level"])
            if LEVELS.index(new) > LEVELS.index(it["level"]):
                old = it["level"]
                it.update(level=new, peak_level=new, level_changed_at=now.isoformat())
                it["history"].append({"at": now.isoformat(), "event": "level", "level": new})
                repo.put(f"attention/{it['id']}.json", it)
                self.audit(repo, "attention_escalate", attention_id=it["id"], kind=it["kind"],
                           from_level=old, level=new)
                self.trace(repo, "attention", "raised",
                           {"attention_id": it["id"], "kind": it["kind"], "from_level": old,
                            "level": new, "rule": why.get(it["id"]),
                            "facts": it.get("detail") or {}}, notable=True)
        # The first time an item is urgent, ask the notifier (it deduplicates too).
        reached_urgent = [it for it in repo.items() if it["state"] == "open"
                          and it["level"] == "urgent" and not it.get("notified_urgent")]
        for it in reached_urgent:
            it["notified_urgent"] = True
            repo.put(f"attention/{it['id']}.json", it)
            try:
                await self.notifications.on_level(now, repo.clinic_id, patient, it)
            except Exception as exc:  # noqa: BLE001 - a notifier must never break ingest
                log.warning("notification step failed: %s", type(exc).__name__)
                self.audit(repo, "notify_urgent", "refused", "notifier_error", attention_id=it["id"])
                self.trace(repo, "notifier", "failed", {"attention_id": it["id"],
                                                         "reason": "notifier_error"})
        return repo.items()

    def _apply(self, repo: PatientRepo, op: Op, now: datetime) -> None:
        now_s = now.isoformat()
        if op.op == "open":
            item = {"id": new_id("att"), "kind": op.kind, "state": "open", "since": op.since,
                    "opened_at": now_s, "level": op.level, "peak_level": op.level,
                    "level_changed_at": now_s, "reason": op.reason, "detail": op.detail,
                    "history": [{"at": now_s, "event": "opened", "level": op.level}]}
            repo.put(f"attention/{item['id']}.json", item)
            self.store.put(f"clinics/{repo.clinic_id}/attention_index/{item['id']}.json",
                           {"patient_id": repo.patient_id})
            self.audit(repo, "attention_open", attention_id=item["id"], kind=op.kind,
                       level=op.level, reason_code=op.reason)
            self.trace(repo, "attention", "opened",
                       {"attention_id": item["id"], "kind": op.kind, "level": op.level,
                        "since": op.since, "rule": op.reason, "facts": op.detail}, notable=True)
            return
        item = repo.get(f"attention/{op.item_id}.json")
        if not item or item["state"] != "open":
            return
        if op.op == "update":
            changed = False
            if op.detail and op.detail != item.get("detail"):
                item["detail"] = op.detail
                changed = True
            if LEVELS.index(op.level) > LEVELS.index(item["level"]):
                self.trace(repo, "attention", "raised",
                           {"attention_id": item["id"], "kind": item["kind"],
                            "from_level": item["level"], "level": op.level,
                            "rule": f"{item['kind']}_watcher", "facts": op.detail}, notable=True)
                item.update(level=op.level, peak_level=op.level, level_changed_at=now_s)
                item["history"].append({"at": now_s, "event": "level", "level": op.level})
                changed = True
            if changed:
                repo.put(f"attention/{item['id']}.json", item)
        elif op.op == "close":
            self.close_item(repo, item, op.reason or "closed", now)

    def close_item(self, repo: PatientRepo, item: dict, reason: str, now: datetime,
                   actor: str = "mind", acked_through: str | None = None) -> None:
        item.update(state="closed", closed_at=now.isoformat(), close_reason=reason)
        if acked_through:
            item["acked_through"] = acked_through
        item["history"].append({"at": now.isoformat(), "event": "closed", "reason": reason})
        repo.put(f"attention/{item['id']}.json", item)
        self.audit(repo, "attention_close", actor=actor, attention_id=item["id"],
                   kind=item["kind"], reason_code=reason)
        self.trace(repo, "attention", "closed",
                   {"attention_id": item["id"], "kind": item["kind"], "level": item["level"],
                    "rule": reason, "by": "clinician" if actor.startswith("clinician") else "mind"})

    # ---- 4: respond ------------------------------------------------------------------------

    async def respond(self, repo: PatientRepo, now: datetime) -> dict | None:
        local = repo.local(now)
        today = local.date().isoformat()
        items, suggestions = repo.items(), repo.suggestions()
        target = needs_response(items, suggestions, today, RESPONDABLE)
        if target is None:
            held = [i for i in items if i["state"] == "open"]
            self.trace(repo, "response", "none", {
                "because": "already_answered_today" if any(i["kind"] in RESPONDABLE for i in held)
                else "no_held_item_to_answer" if not held else "held_items_need_a_clinician",
                "held": [i["kind"] for i in held]})
            return None
        rules = repo.rules()
        blocked = blocked_reason(rules, suggestions, local, now, self.th)
        if blocked:
            st = repo.state()
            if st.get("last_blocked") != blocked:
                st["last_blocked"] = blocked
                repo.save_state(st)
            self.trace(repo, "response", "blocked", {"attention_id": target["id"],
                                                     "kind": target["kind"], "because": blocked})
            return None
        lessons = repo.lessons_doc().get("lessons", [])
        prefs = repo.preferences()
        action = pick_action(rules, lessons, local, prefs)
        if action is None:
            self.audit(repo, "suggestion", "refused", "no_action_allowed_by_rules")
            self.trace(repo, "response", "none", {"attention_id": target["id"],
                                                  "kind": target["kind"],
                                                  "because": "no_action_allowed_by_rules"})
            return None
        explain: dict = {}
        rank_actions(rules, lessons, local, explain, prefs)
        text, wording, wording_line = await self.word(repo, action)
        considered = [x["id"] for x in lessons if x.get("status") == "active"]
        s = {"id": new_id("sug"), "action": action, "text": text, "wording": wording,
             "created_at": now.isoformat(), "date": today, "status": "open",
             "attention_ids": [target["id"]], "attention_kind": target["kind"],
             "ranked": rank_actions(rules, lessons, local, None, prefs),
             "lessons_considered": considered, "line_id": wording_line,
             "answer": None, "felt": None, "round_completed": False, "played": False}
        repo.put(f"suggestions/{s['id']}.json", s)
        self.audit(repo, "suggestion", suggestion_id=s["id"], action_id=action, wording=wording,
                   attention_id=target["id"])
        self.trace(repo, "response", "suggested",
                   {"attention_id": target["id"], "kind": target["kind"], "action": action,
                    "wording": wording, "suggestion_id": s["id"], "ranking": explain},
                   notable=True)
        return s

    async def word(self, repo: PatientRepo, action: str) -> tuple[str, str, str]:
        """Level 1 may CHOOSE one of Lanvi's fixed lines for the action; the
        output gate decides; else the first line. Returns (text, by, line id)."""
        options = lines.suggestion_lines(action)
        first = options[0]
        if not getattr(self.local, "configured", False):
            self.trace(repo, "level1", "off", {"task": "wording", "used": "template",
                                               "line_id": first["id"]})
            return first["text"], "template", first["id"]
        pack = INPUT_GATE.wording_pack(action)
        raw = await self.local.complete(pack)
        res = OUTPUT_GATE.choose_line(raw, action)
        saw = {"fields": sorted(pack.payload), "action": action,
               "lines_offered": [x["id"] for x in options]}
        if res.ok:
            self.trace(repo, "level1", "accepted",
                       {"task": "wording", "saw": saw, "returned": {"line_id": res.value["id"]},
                        "verdict": "accepted", "used": "model", "line_id": res.value["id"]})
            return res.value["text"], "model", res.value["id"]
        for r in res.refusals:
            self.refuse(repo, r)
        self.trace(repo, "level1", "no_reply" if raw is None else "refused",
                   {"task": "wording", "saw": saw,
                    "returned": None if raw is None else {"words": len(raw.split())},
                    "verdict": "refused", "reasons": [r.reason for r in res.refusals],
                    "used": "template", "line_id": first["id"]}, notable=raw is not None)
        return first["text"], "template", first["id"]

    # ---- 5: learn ----------------------------------------------------------------------

    async def schedule_review(self, repo: PatientRepo, trigger: str) -> None:
        if self.settings.review_inline:
            await self.run_review(repo, trigger)
            return

        async def bg() -> None:
            async with self.lock(repo.clinic_id, repo.patient_id):
                try:
                    await self.run_review(repo, trigger)
                except Exception:  # noqa: BLE001
                    log.exception("review failed")

        task = asyncio.get_running_loop().create_task(bg())
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    def evidence(self, repo: PatientRepo) -> tuple[list[dict], list[dict]]:
        tz = repo.tz()
        days = repo.days()
        today = repo.local(self.clock.now()).date()
        series = series_against(days, baseline_for(days, today, self.th))
        rows = learn.evidence_table(
            repo.suggestions(), series, repo.questions(),
            lambda iso: datetime.fromisoformat(iso).astimezone(tz).hour, self.th,
            activities=repo.activities())
        return rows, series

    def _review_refusals(self, repo: PatientRepo, limit: int) -> list[dict]:
        """The same as list_audit(outcome="refused", limit) over the same window of
        the newest audit events, but as if the association appraisal and the
        ratings had never written any: they must not change what the review sees."""
        out, scanned = [], 0
        for k in reversed(self.store.list(audit_prefix(repo.clinic_id, repo.patient_id))):
            ev = self.store.get(k)
            if not ev:
                scanned += 1
            elif is_research_event(ev):
                continue
            else:
                scanned += 1
                if ev.get("outcome") == "refused":
                    out.append(ev)
            if len(out) >= limit or scanned >= limit * 4:
                break
        return out

    async def run_review(self, repo: PatientRepo, trigger: str) -> dict:
        with self.tracer.chain(repo.clinic_id, repo.patient_id, "review_" + trigger):
            return await self._run_review(repo, trigger)

    async def _run_review(self, repo: PatientRepo, trigger: str) -> dict:
        now = self.clock.now()
        today = repo.local(now).date()
        review_id = new_id("rev")
        rows, series = self.evidence(repo)
        doc = repo.lessons_doc()
        questions = repo.questions()
        refusals: list[GateRefusal] = []
        models = {"level1": "off", "level2": "off"}

        # Code first: deterministic candidates, validated like any proposal.
        accepted: list[dict] = []
        code_cands = learn.code_candidates(rows, self.th)
        for c in code_cands:
            v = learn.validate_lesson(c, rows, doc, self.th)
            if v.ok:
                accepted.append({**c, "source": "code"})
            elif v.reason != "rejected_by_patient":
                refusals.append(GateRefusal("code", 0, "review", v.reason))
        new_questions = learn.code_questions(rows, doc.get("lessons", []), questions)
        new_questions = [{**q, "source": "code"} for q in new_questions]

        # Level 1 proposes through the gates.
        if getattr(self.local, "configured", False) and rows:
            # Refusals of the association appraisal never reach the review: that
            # clinician-only research output must not feed lessons.
            refused = self._review_refusals(repo, 20)
            recent = [{"reason": e.get("reason"), "task": e.get("detail", {}).get("task")}
                      for e in refused if e.get("action") == "gate_refusal"]
            pack = INPUT_GATE.review_pack(1, rows, series, today, recent, doc.get("lessons", []),
                                          rounds=repo.rounds(), activities=repo.activities())
            raw = await self.local.complete(pack, json_mode=True)
            models["level1"] = "no_reply" if raw is None else "replied"
            l1 = {"task": "review", "saw": {"fields": sorted(k for k in pack.payload
                                                            if k != "alias"),
                                            "evidence_rows": len(rows)}}
            if raw is None:
                self.trace(repo, "level1", "no_reply", {**l1, "verdict": "no_reply",
                                                        "used": "code_only"})
            if raw is not None:
                res = OUTPUT_GATE.review(raw, pack, rows, doc, questions)
                refusals.extend(res.refusals)
                self.trace(repo, "level1", "accepted" if res.ok and not res.refusals
                           else "partly_refused" if res.ok else "refused",
                           {**l1, "returned": {
                               "lessons": len(res.value["lessons"]) if res.ok else None,
                               "questions": len(res.value["questions"]) if res.ok else None},
                            "verdict": "accepted" if res.ok else "refused",
                            "reasons": [r.reason for r in res.refusals],
                            "used": "model_and_code" if res.ok else "code_only"},
                           notable=bool(res.refusals))
                if res.ok:
                    keys = {(a["action"], a["effect"], a["context"]) for a in accepted}
                    for p in res.value["lessons"]:
                        key = (p["action"], p["effect"], p["context"])
                        if key not in keys:
                            accepted.append({**p, "source": "local"})
                            keys.add(key)
                    for q in res.value["questions"]:
                        if learn.validate_question(q, questions + new_questions).ok:
                            new_questions.append({**q, "source": "local"})

        for a in accepted:
            a["id"] = new_id("les")

        # Level 2 (optional) may object to lessons code accepted. It cannot add.
        # The evidence rows leave the private network: the patient's consent decides.
        if self.outreach is not None and self.outreach.gemini_on and accepted and \
                (repo.patient() or {}).get("allow_outside_processing"):
            try:
                pack2 = INPUT_GATE.second_opinion_pack(accepted, rows, today)
                raw2 = await self.outreach.gemini_complete(pack2)
                res2 = OUTPUT_GATE.second_opinion(raw2, pack2)
                refusals.extend(res2.refusals)
                self.trace(repo, "level2", "accepted" if res2.ok else "refused", {
                    "task": "second_opinion", "anonymized": True,
                    "sent_fields": sorted(k for k in pack2.payload if k != "alias"),
                    "lessons_sent": len(accepted),
                    "returned": {"objections": sorted(set(res2.value.values()))
                                 if res2.ok else None},
                    "verdict": "accepted" if res2.ok else "refused",
                    "reasons": [r.reason for r in res2.refusals]},
                    notable=raw2 is not None and not res2.ok)
                if res2.ok:
                    models["level2"] = "replied"
                    kept = []
                    for a in accepted:
                        if a["id"] in res2.value:
                            refusals.append(GateRefusal("output", 2, "second_opinion",
                                                        "level2_objection:" + res2.value[a["id"]]))
                        else:
                            kept.append(a)
                    accepted = kept
                else:
                    models["level2"] = "refused_or_unavailable"
            except GateError as ge:
                refusals.append(ge.refusal)
                models["level2"] = "input_refused"
                self.trace(repo, "level2", "not_sent", {"task": "second_opinion",
                                                        "reason": ge.refusal.reason})

        applied = learn.apply_lessons(doc, accepted, rows, now, review_id, self.th)
        repo.put("mind/lessons.json", doc)

        open_q = [q for q in questions if q["status"] == "open"]
        added_q = []
        for q in new_questions:
            if len(open_q) + len(added_q) >= self.th.max_open_questions:
                break
            name = plain_name(q["action"])
            added_q.append({"id": new_id("q"), "code": q["code"], "action": q["action"],
                            "text": QUESTIONS[q["code"]].format(name=name),
                            "status": "open", "created_at": now.isoformat(),
                            "review_id": review_id, "source": q["source"]})
        if added_q:
            repo.put("mind/questions.json", {"questions": questions + added_q})

        for r in refusals:
            self.refuse(repo, r)
        review = {"id": review_id, "at": now.isoformat(), "trigger": trigger, "models": models,
                  "evidence_rows": len(rows),
                  "accepted": [{"id": a["id"], "action": a["action"], "effect": a["effect"],
                                "context": a["context"], "source": a["source"]} for a in accepted],
                  "added": [x["id"] for x in applied.added],
                  "refreshed": [x["id"] for x in applied.refreshed],
                  "retired": [{"id": x["id"], "reason": x["end_reason"]} for x in applied.retired],
                  "refused": [{"gate": r.gate, "level": r.level, "task": r.task, "reason": r.reason}
                              for r in refusals],
                  "questions_added": [q["id"] for q in added_q]}
        repo.put(f"mind/reviews/{review_id}.json", review)
        st = repo.state()
        st["last_review_at"] = now.isoformat()
        repo.save_state(st)
        self.audit(repo, "review", review_id=review_id, trigger=trigger,
                   added=len(applied.added), refused=len(refusals))
        self.trace(repo, "learning", "review", {
            "review_id": review_id, "trigger": trigger, "evidence_rows": len(rows),
            "proposed_by_code": len(code_cands), "models": models,
            "accepted": review["accepted"], "added": len(applied.added),
            "refreshed": len(applied.refreshed), "retired": review["retired"],
            "refused": [{"by": r.gate, "level": r.level, "reason": r.reason} for r in refusals],
            "questions_added": len(added_q)})
        return review

    # ---- the movement reading (level 2, background) --------------------------------------

    def reading_state(self, repo: PatientRepo, round_rec: dict) -> str:
        """pending | off | not_allowed, decided when the round arrives."""
        if self.outreach is None or not self.outreach.gemini_on:
            return "off"
        if not (repo.patient() or {}).get("allow_outside_processing"):
            return "not_allowed"
        return "pending"

    async def schedule_reading(self, repo: PatientRepo, round_id: str) -> None:
        if self.settings.review_inline:
            await self.run_reading(repo, round_id)
            return

        async def bg() -> None:
            # The model call runs WITHOUT the patient lock; storing takes it.
            try:
                await self.run_reading(repo, round_id, take_lock=True)
            except Exception:  # noqa: BLE001
                log.exception("reading failed")

        task = asyncio.get_running_loop().create_task(bg())
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    def usual_round(self, repo: PatientRepo, rec: dict) -> dict | None:
        """The earlier good round of the same mode whose energy is closest to usual."""
        good = [r for r in repo.rounds() if r["id"] != rec["id"] and r["mode"] == rec["mode"]
                and r.get("quality") == "good" and r["started_at"] < rec["started_at"]]
        if not good:
            return None
        return min(good[-20:], key=lambda r: abs(r.get("energy") or 0.0))

    async def run_reading(self, repo: PatientRepo, round_id: str, take_lock: bool = False) -> dict:
        with self.tracer.chain(repo.clinic_id, repo.patient_id, "reading_requested"):
            return await self._run_reading(repo, round_id, take_lock)

    async def _run_reading(self, repo: PatientRepo, round_id: str, take_lock: bool) -> dict:
        rec = repo.get(f"rounds/{round_id}.json")
        if rec is None:
            return {"status": "failed"}
        state = self.reading_state(repo, rec)
        if state != "pending":
            return {"status": state}
        now = self.clock.now()
        reader = self._session_reader()
        level_name = "level1" if reader == "local" else "level2"
        analysis: dict = {"status": "failed", "read_by": level_name, "checked_by": "code",
                          "at": now.isoformat()}
        refusals: list[GateRefusal] = []
        try:
            pack = INPUT_GATE.reading_pack(rec, self.usual_round(repo, rec),
                                           images=self.settings.reading_images)
            if reader == "local":
                INPUT_GATE.check_session_outbound(pack.payload)  # same check as for the outside model
                raw = await self.local.complete(Pack(1, pack.task, pack.messages, pack.payload),
                                                json_mode=True, max_tokens=1500)
            else:
                raw = await self.outreach.gemini_complete(pack)
            if raw is None:
                analysis["reason"] = "no_reply"
            else:
                res = OUTPUT_GATE.reading(raw, rec)
                refusals.extend(res.refusals)
                if res.ok:
                    analysis.update(status="ready", reading=res.value["reading"],
                                    dropped=res.value["dropped"])
                else:
                    analysis["reason"] = "refused"
        except GateError as ge:
            refusals.append(ge.refusal)
            analysis["reason"] = "input_refused"
        try:
            reading = analysis.get("reading") or {}
            self.trace(repo, level_name, "accepted" if analysis["status"] == "ready" else
                       "not_sent" if analysis.get("reason") == "input_refused" else
                       "no_reply" if analysis.get("reason") == "no_reply" else "refused", {
                           "task": "reading", "round_id": round_id, "anonymized": True,
                           "sent_fields": ["mode", "duration_s", "lights (timing per light)",
                                           "path (relative, turned)", "usual round"],
                           "returned": {k: reading.get(k) for k in
                                        ("pattern", "fade_from_light", "reach", "turning",
                                         "compared_to_usual", "confidence")} or None,
                           "confirmed": [e.get("claim") for e in reading.get("evidence", [])],
                           "dropped": [{"field": d.get("field"), "reason": d.get("reason")}
                                       for d in analysis.get("dropped", [])],
                           "verdict": analysis["status"],
                           "reasons": [r.reason for r in refusals]},
                       notable=bool(refusals))
        except Exception:  # noqa: BLE001
            pass

        async def store() -> None:
            cur = repo.get(f"rounds/{round_id}.json")
            if cur is None:
                return
            cur["analysis"] = analysis
            repo.put(f"rounds/{round_id}.json", cur)
            for r in refusals:
                self.refuse(repo, r)
            self.audit(repo, "round_reading", round_id=round_id, status=analysis["status"],
                       dropped=len(analysis.get("dropped", [])))
            if analysis["status"] == "ready":
                await self.publish("reading", repo.clinic_id, repo.patient_id, round_id=round_id)

        if take_lock:
            async with self.lock(repo.clinic_id, repo.patient_id):
                await store()
        else:
            await store()
        return analysis

    # ---- the session reading (level 2, background) ------------------------------------

    def session_reading_state(self, repo: PatientRepo, rec: dict) -> str:
        """pending | off | not_allowed | not_applicable, decided when the activity arrives."""
        from .session_reading import applies
        if not applies(rec):
            return "not_applicable"
        reader = self._session_reader()
        if reader is None:
            return "off"
        # Consent is about data leaving the clinic. The local model does not leave it.
        if reader == "gemini" and not (repo.patient() or {}).get("allow_outside_processing"):
            return "not_allowed"
        return "pending"

    def _session_reader(self) -> str | None:
        """Which model reads a session: "gemini" (level 2), "local" (level 1) or None.
        The pack is the same anonymous one in both cases and code checks every claim."""
        mode = getattr(self.settings, "session_reader", "auto")
        if mode == "off":
            return None
        if mode in ("auto", "gemini") and self.outreach is not None and self.outreach.gemini_on:
            return "gemini"
        if mode == "local" and getattr(self.local, "configured", False):
            return "local"
        return None

    async def schedule_session_reading(self, repo: PatientRepo, activity_id: str) -> None:
        if self.settings.review_inline:
            await self.run_session_reading(repo, activity_id)
            return

        async def bg() -> None:
            try:
                await self.run_session_reading(repo, activity_id, take_lock=True)
            except Exception:  # noqa: BLE001
                log.exception("session reading failed")

        task = asyncio.get_running_loop().create_task(bg())
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def run_session_reading(self, repo: PatientRepo, activity_id: str,
                                  take_lock: bool = False) -> dict:
        with self.tracer.chain(repo.clinic_id, repo.patient_id, "reading_requested"):
            return await self._run_session_reading(repo, activity_id, take_lock)

    async def _run_session_reading(self, repo: PatientRepo, activity_id: str,
                                   take_lock: bool) -> dict:
        from .session_reading import earlier_sessions
        rec = repo.get(f"activities/{activity_id}.json")
        if rec is None:
            return {"status": "failed"}
        state = self.session_reading_state(repo, rec)
        if state != "pending":
            return {"status": state}
        now = self.clock.now()
        earlier = earlier_sessions(rec, repo.activities())
        reader = self._session_reader()
        level_name = "level1" if reader == "local" else "level2"
        analysis: dict = {"status": "failed", "read_by": level_name, "checked_by": "code",
                          "at": now.isoformat()}
        refusals: list[GateRefusal] = []
        sent: list[str] = []
        try:
            pack = INPUT_GATE.session_pack(rec, earlier)
            sent = sorted(pack.payload["session"])
            if reader == "local":
                INPUT_GATE.check_session_outbound(pack.payload)  # same check as for the outside model
                raw = await self.local.complete(Pack(1, pack.task, pack.messages, pack.payload),
                                                json_mode=True, max_tokens=1500)
            else:
                raw = await self.outreach.gemini_complete(pack)
            if raw is None:
                analysis["reason"] = "no_reply"
            else:
                res = OUTPUT_GATE.session_reading(raw, rec, earlier)
                refusals.extend(res.refusals)
                if res.ok:
                    analysis.update(status="ready", reading=res.value["reading"],
                                    dropped=res.value["dropped"])
                else:
                    analysis["reason"] = "refused"
        except GateError as ge:
            refusals.append(ge.refusal)
            analysis["reason"] = "input_refused"
        try:
            reading = analysis.get("reading") or {}
            self.trace(repo, level_name, "accepted" if analysis["status"] == "ready" else
                       "not_sent" if analysis.get("reason") == "input_refused" else
                       "no_reply" if analysis.get("reason") == "no_reply" else "refused", {
                           "task": "session_reading", "activity_id": activity_id,
                           "type": rec["type"], "anonymized": True,
                           "sent_fields": sent, "earlier_sessions": len(earlier),
                           "returned": {k: reading.get(k) for k in
                                        ("reactions", "expression", "eyes", "compared_to_usual",
                                         "from_session", "confidence")} or None,
                           "confirmed": [e.get("claim") for e in reading.get("evidence", [])],
                           "dropped": [{"field": d.get("field"), "reason": d.get("reason")}
                                       for d in analysis.get("dropped", [])],
                           "verdict": analysis["status"],
                           "reasons": [r.reason for r in refusals]},
                       notable=bool(refusals))
        except Exception:  # noqa: BLE001
            pass

        async def store() -> None:
            cur = repo.get(f"activities/{activity_id}.json")
            if cur is None:
                return
            cur["analysis"] = analysis
            repo.put(f"activities/{activity_id}.json", cur)
            for r in refusals:
                self.refuse(repo, r)
            self.audit(repo, "session_reading", activity_id=activity_id,
                       status=analysis["status"], dropped=len(analysis.get("dropped", [])))
            if analysis["status"] == "ready":
                await self.publish("reading", repo.clinic_id, repo.patient_id,
                                   activity_id=activity_id)

        if take_lock:
            async with self.lock(repo.clinic_id, repo.patient_id):
                await store()
        else:
            await store()
        return analysis

    # ---- the frame reading (level 2 reads the raw frames; code checks) -------------------
    #
    # Clinician-only. Reads the stored raw frames, writes ONLY the activity's
    # `frames_reading` field, the trace, the audit log and the refusal log. Never
    # attention, suggestions, lessons, questions or mind state, never an event
    # on the bus, never any patient-facing text. Nothing in the mind reads it.

    def frames_reading_state(self, repo: PatientRepo, rec: dict) -> str:
        """pending | off | not_allowed | not_applicable."""
        if rec.get("type") not in ("focus", "breathing") or rec.get("face_source") != "raw":
            return "not_applicable"
        if getattr(self.settings, "frames_reader", "auto") == "off" or \
                self.outreach is None or not self.outreach.gemini_on:
            return "off"
        # The frames leave the private network: the patient's consent decides.
        if not (repo.patient() or {}).get("allow_outside_processing"):
            return "not_allowed"
        return "pending"

    async def schedule_frames_reading(self, repo: PatientRepo, activity_id: str) -> None:
        if self.settings.review_inline:
            await self.run_frames_reading(repo, activity_id)
            return

        async def bg() -> None:
            try:
                await self.run_frames_reading(repo, activity_id, take_lock=True)
            except Exception:  # noqa: BLE001
                log.exception("frame reading failed")

        task = asyncio.get_running_loop().create_task(bg())
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def run_frames_reading(self, repo: PatientRepo, activity_id: str,
                                 take_lock: bool = False) -> dict:
        with self.tracer.chain(repo.clinic_id, repo.patient_id, "frames_reading", fresh=True):
            return await self._run_frames_reading(repo, activity_id, take_lock)

    async def _run_frames_reading(self, repo: PatientRepo, activity_id: str,
                                  take_lock: bool) -> dict:
        rec = repo.get(f"activities/{activity_id}.json")
        if rec is None:
            return {"status": "failed", "reason": "not_found"}
        state = self.frames_reading_state(repo, rec)
        raw = repo.get(f"faceraw/{activity_id}.json") if state == "pending" else None
        if state == "pending" and raw is None:
            state = "not_applicable"
        if state != "pending":
            out = {"status": state}

            async def keep() -> None:
                cur = repo.get(f"activities/{activity_id}.json")
                if cur is not None and cur.get("face_source") == "raw" and \
                        (cur.get("frames_reading") or {}).get("status") != state:
                    cur["frames_reading"] = out
                    repo.put(f"activities/{activity_id}.json", cur)
            if take_lock:
                async with self.lock(repo.clinic_id, repo.patient_id):
                    await keep()
            else:
                await keep()
            return out
        now = self.clock.now()
        result: dict = {"status": "failed", "read_by": "level2",
                        "model": self.outreach.level2_model, "checked_by": "code",
                        "at": now.isoformat()}
        refusals: list[GateRefusal] = []
        sent: dict = {}
        try:
            pack = INPUT_GATE.frames_pack(rec, raw)
            sent = {"frames": len(pack.payload["frames"]), "rate_hz": pack.payload["rate_hz"],
                    "channels": len(pack.payload["channels"]),
                    "moments": len(pack.payload["moments_s"])}
            reply = await self.outreach.gemini_complete(pack)
            # Why the model stopped and its token counts (codes and counts only).
            meta = getattr(self.outreach, "last_frames_meta", None) or {}
            sent.update({k: meta[k] for k in ("finish", "attempts", "thinking", "prompt_tokens",
                                              "thought_tokens", "output_tokens")
                         if meta.get(k) is not None})
            if meta.get("model"):
                result["model"] = meta["model"] if not self.outreach.standin else result["model"]
            if reply is None:
                result["reason"] = "no_reply"
            else:
                res = OUTPUT_GATE.frames_reading(reply, pack, raw)
                refusals.extend(res.refusals)
                if res.ok:
                    result.update(status="ready", reading=res.value["reading"],
                                  agreement=res.value["agreement"],
                                  dropped=res.value["dropped"])
                else:
                    result["reason"] = res.refusals[0].reason if res.refusals else "refused"
        except GateError as ge:
            refusals.append(ge.refusal)
            result["reason"] = "input_refused"
        ag = result.get("agreement") or {}
        counts = {k: ag.get(k) for k in ("smiles_reported", "smiles_confirmed",
                                         "smiles_corrected", "smiles_faint", "smiles_brief", "smiles_inside_long",
                                         "smiles_not_in_numbers", "smiles_missed",
                                         "segments_reported", "segments_confirmed",
                                         "blinks_model", "blinks_code", "overall_same")}
        try:
            # Counts and codes only: never a frame value.
            self.trace(repo, "level2", "accepted" if result["status"] == "ready" else
                       "not_sent" if result.get("reason") == "input_refused" else
                       "no_reply" if result.get("reason") == "no_reply" else "refused", {
                           "task": "frames_reading", "activity_id": activity_id,
                           "type": rec["type"], "anonymized": True, **sent, **counts,
                           "verdict": result["status"],
                           "reasons": [r.reason for r in refusals][:20]},
                       notable=bool(refusals))
        except Exception:  # noqa: BLE001
            pass

        async def store() -> None:
            cur = repo.get(f"activities/{activity_id}.json")
            if cur is None:
                return
            cur["frames_reading"] = result
            repo.put(f"activities/{activity_id}.json", cur)
            for r in refusals:
                self.refuse(repo, r)
            if result["status"] == "ready":
                # The watchers look again: what the model found and code confirmed
                # may open (or close) a flag for the clinic (watch_model_noticed).
                await self.observe(repo, repo.patient(), self.clock.now())
            self.audit(repo, "frames_reading", activity_id=activity_id,
                       status=result["status"], reason=result.get("reason"),
                       frames_sent=sent.get("frames"), dropped=len(result.get("dropped", [])),
                       **{k: v for k, v in counts.items() if v is not None})

        if take_lock:
            async with self.lock(repo.clinic_id, repo.patient_id):
                await store()
        else:
            await store()
        return result

    # ---- the day reading (level 2 reads the daily numbers; code checks) -------------------
    #
    # Clinician-only. Reads the day records and the stored HealthKit types,
    # writes ONLY research/days_reading.json, the trace, the audit log and the
    # refusal log. Never attention, suggestions, lessons, questions or mind
    # state, never an event on the bus, never any patient-facing text.

    def days_reading_state(self, repo: PatientRepo) -> str:
        """pending | off | not_allowed | too_few_days."""
        if getattr(self.settings, "days_reader", "auto") == "off" or \
                self.outreach is None or not self.outreach.gemini_on:
            return "off"
        # The numbers leave the private network: the patient's consent decides.
        if not (repo.patient() or {}).get("allow_outside_processing"):
            return "not_allowed"
        have = sum(1 for d in repo.days().values() if d.get("steps") is not None)
        return "pending" if have >= self.th.dayr_min_days else "too_few_days"

    async def schedule_days_reading(self, repo: PatientRepo) -> None:
        """After new days arrived: a new reading, at most every
        dayr_min_hours_between hours per person."""
        if self.days_reading_state(repo) != "pending":
            return
        old = repo.get("research/days_reading.json") or {}
        if old.get("at"):
            age = self.clock.now() - datetime.fromisoformat(old["at"])
            if age < timedelta(hours=self.th.dayr_min_hours_between):
                return
        if self.settings.review_inline:
            await self.run_days_reading(repo, take_lock=True)
            return

        async def bg() -> None:
            try:
                await self.run_days_reading(repo, take_lock=True)
            except Exception:  # noqa: BLE001
                log.exception("day reading failed")

        task = asyncio.get_running_loop().create_task(bg())
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def run_days_reading(self, repo: PatientRepo, take_lock: bool = False) -> dict:
        with self.tracer.chain(repo.clinic_id, repo.patient_id, "days_reading", fresh=True):
            return await self._run_days_reading(repo, take_lock)

    async def _run_days_reading(self, repo: PatientRepo, take_lock: bool) -> dict:
        from .day_reading import first_date
        state = self.days_reading_state(repo)
        now = self.clock.now()
        if state != "pending":
            return {"status": state}
        result: dict = {"status": "failed", "read_by": "level2",
                        "model": self.outreach.level2_model, "checked_by": "code",
                        "at": now.isoformat()}
        refusals: list[GateRefusal] = []
        sent: dict = {}
        try:
            days = repo.days()
            health = {h["type"]: h for h in repo.docs("health") if h.get("type")}
            pack = INPUT_GATE.days_pack(days, health)
            if pack is None:
                return {"status": "too_few_days"}
            sent = {"days": pack.payload["days"], "channels": len(pack.payload["channels"])}
            # What was sent, for the clinician's chart; the date of row 0 is kept
            # beside it and was never sent.
            result["stream"] = {"first_date": first_date(days, pack.payload), **pack.payload}
            reply = await self.outreach.gemini_complete(pack)
            meta = getattr(self.outreach, "last_frames_meta", None) or {}
            sent.update({k: meta[k] for k in ("finish", "attempts", "thinking", "prompt_tokens",
                                              "thought_tokens", "output_tokens")
                         if meta.get(k) is not None})
            if meta.get("model"):
                result["model"] = meta["model"] if not self.outreach.standin else result["model"]
            if reply is None:
                result["reason"] = "no_reply"
            else:
                res = OUTPUT_GATE.days_reading(reply, pack)
                refusals.extend(res.refusals)
                if res.ok:
                    result.update(status="ready", reading=res.value["reading"],
                                  agreement=res.value["agreement"],
                                  dropped=res.value["dropped"])
                else:
                    result["reason"] = res.refusals[0].reason if res.refusals else "refused"
        except GateError as ge:
            refusals.append(ge.refusal)
            result["reason"] = "input_refused"
        ag = result.get("agreement") or {}
        counts = {k: ag.get(k) for k in ("stretches_reported", "stretches_same",
                                         "stretches_model_only", "stretches_not_in_numbers",
                                         "stretches_missed", "weekdays_confirmed",
                                         "overall_same")}
        try:
            # Counts and codes only: never a day's value.
            self.trace(repo, "level2", "accepted" if result["status"] == "ready" else
                       "not_sent" if result.get("reason") == "input_refused" else
                       "no_reply" if result.get("reason") == "no_reply" else "refused", {
                           "task": "days_reading", "anonymized": True, **sent, **counts,
                           "verdict": result["status"],
                           "reasons": [r.reason for r in refusals][:20]},
                       notable=bool(refusals))
        except Exception:  # noqa: BLE001
            pass

        async def store() -> None:
            repo.put("research/days_reading.json", result)
            for r in refusals:
                self.refuse(repo, r)
            if result["status"] == "ready":
                await self.observe(repo, repo.patient(), self.clock.now())
            self.audit(repo, "days_reading", status=result["status"],
                       reason=result.get("reason"), days_sent=sent.get("days"),
                       dropped=len(result.get("dropped", [])),
                       **{k: v for k, v in counts.items() if v is not None})

        if take_lock:
            async with self.lock(repo.clinic_id, repo.patient_id):
                await store()
        else:
            await store()
        return result

    # ---- the association appraisal (clinician-only research output) ---------------------
    #
    # Reads the patient's data, writes ONLY research/associations.json, the trace,
    # the audit log and the refusal log. Never attention, suggestions, lessons,
    # questions or mind state; never any patient-facing text. Nothing in the
    # mind reads what it stores.

    ASSOC_KEY = "research/associations.json"

    def appraisal_due(self, repo: PatientRepo, now: datetime) -> bool:
        if not getattr(self.settings, "associations_enabled", True):
            return False
        if (repo.clinic_id, repo.patient_id) in self._appraising:
            return False
        cur = repo.get(self.ASSOC_KEY)
        if not cur or not cur.get("generated_at"):
            return True
        return repo.local(datetime.fromisoformat(cur["generated_at"])).date() < \
            repo.local(now).date()

    async def schedule_appraisal(self, repo: PatientRepo) -> None:
        """At most once a day per patient, after the tick; in the background."""
        if self.settings.review_inline:
            await self.run_appraisal(repo, "daily")
            return
        key = (repo.clinic_id, repo.patient_id)
        self._appraising.add(key)

        async def bg() -> None:
            try:
                await self.run_appraisal(repo, "daily")
            except Exception:  # noqa: BLE001
                log.exception("association appraisal failed")
            finally:
                self._appraising.discard(key)

        task = asyncio.get_running_loop().create_task(bg())
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def run_appraisal(self, repo: PatientRepo, trigger: str = "on_demand") -> dict:
        """Compute, appraise (code, then the level-1 model if configured, held to
        code's rules), store and return. Always returns a usable appraisal."""
        with self.tracer.chain(repo.clinic_id, repo.patient_id, "appraisal", fresh=True):
            return await self._run_appraisal(repo, trigger)

    async def _run_appraisal(self, repo: PatientRepo, trigger: str) -> dict:
        from . import associations as assoc
        now = self.clock.now()
        th = self.th
        today = repo.local(now).date()
        days = repo.days()
        ds = assoc.build_dataset(
            days, daily_series(days, th, since=today - timedelta(days=th.assoc_window_days + 7)),
            repo.activities(), repo.docs("ratings"), repo.items(), repo.tz(), today, th)
        rows = assoc.compute_rows(ds, th)
        ref_kind = ds["reference"]["kind"]
        code_rows, code_ov = assoc.code_appraisal(rows, ref_kind, ds["notes"], th)
        tested = [r for r in code_rows if r["status"] == "tested"]
        self.trace(repo, "trigger", "appraisal",
                   {"by": trigger, "reference": ds["reference"]["key"], "kind": ref_kind,
                    "days": ds["n_days"], "sessions": ds["n_sessions"],
                    "rows_tested": len(tested)})
        out_rows, overall, corrections = code_rows, code_ov, []
        appraised_by, model_name = "code", "code"
        refusals: list[GateRefusal] = []
        l1 = {"task": "association", "rows": len(tested)}
        if not getattr(self.local, "configured", False):
            self.trace(repo, "level1", "off", {**l1, "used": "code"})
        elif not tested:
            self.trace(repo, "level1", "not_needed", {**l1, "used": "code"})
        else:
            try:
                pack = INPUT_GATE.association_pack(assoc.build_payload(ds, code_rows))
                l1["saw"] = {"fields": sorted(pack.payload),
                             "row_fields": list(assoc.PACK_ROW_FIELDS)}
                raw = await self.local.complete(pack, json_mode=True,
                                                max_tokens=th.assoc_max_tokens)
                res = OUTPUT_GATE.association(raw, pack)
                refusals.extend(res.refusals)
                if res.ok:
                    out_rows, overall, corrections = assoc.merge(res.value, code_rows, code_ov,
                                                                 ref_kind, th)
                    appraised_by = "model"
                    model_name = getattr(self.local, "model", None) or "level1"
                    refusals.extend(GateRefusal("output", 1, "association",
                                                f"corrected:{c['field']}:{c['reason']}"[:80])
                                    for c in corrections)
                code = "no_reply" if raw is None else \
                    ("accepted" if res.ok and not refusals else
                     "partly_refused" if res.ok else "refused")
                self.trace(repo, "level1", code, {
                    **l1, "verdict": "used" if res.ok else "refused",
                    "returned": None if not res.ok else {
                        "pattern": res.value["overall"]["pattern"],
                        "confidence": res.value["overall"]["confidence"]},
                    "corrected": [{"field": c["field"], "key": c["key"], "reason": c["reason"]}
                                  for c in corrections],
                    "reasons": [r.reason for r in refusals],
                    "used": "model_checked_by_code" if res.ok else "code"},
                    notable=bool(refusals) and raw is not None)
            except GateError as ge:
                refusals.append(ge.refusal)
                self.trace(repo, "level1", "not_sent", {**l1, "reason": ge.refusal.reason,
                                                        "used": "code"})
        result = assoc.assemble(ds, out_rows, overall, corrections, appraised_by, model_name, now)
        repo.put(self.ASSOC_KEY, result)
        for r in refusals:
            self.refuse(repo, r)
        self.audit(repo, "association_appraisal", trigger=trigger, appraised_by=appraised_by,
                   reference=ds["reference"]["key"], rows_tested=len(tested),
                   corrections=len(corrections), pattern=overall["pattern"])
        return result

    # ---- tick ----------------------------------------------------------------------------

    async def tick(self) -> None:
        clinics = set()
        for clinic_id, patient_id in self.all_patients():
            clinics.add(clinic_id)
            async with self.lock(clinic_id, patient_id):
                await self.publish("tick", clinic_id, patient_id)
        now = self.clock.now()
        for c in clinics:
            try:
                await self.notifications.flush(
                    now, c, lambda pid, c=c: self.repo(c, pid).patient(),
                    lambda pid, aid, c=c: self.repo(c, pid).get(f"attention/{aid}.json"))
            except Exception as exc:  # noqa: BLE001
                log.warning("notification flush failed: %s", type(exc).__name__)

    async def run_ticker(self) -> None:
        while True:
            await asyncio.sleep(self.settings.tick_seconds)
            try:
                await self.tick()
            except Exception:  # noqa: BLE001
                log.exception("tick failed")
