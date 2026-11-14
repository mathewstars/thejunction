"""What each write does, between the HTTP layer and the mind.

Every function here: checks tenant ownership by building keys only from the
caller's principal, takes the patient's lock, writes, audits, and publishes
one event to the mind's bus.
"""

from __future__ import annotations

import json
import re
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta

from .audit import write_audit
from .config import Settings
from .mind import face_features, lines, xp
from .mind import notes as note_logic
from .mind.activities import check_activity, played_to_the_end, process_activity
from .mind.engine import Clock, Mind
from .mind.gates import INPUT_GATE, OUTPUT_GATE, GateError
from .mind.repo import PatientRepo
from .mind.rounds import check_round, process_round
from .mind.watchers import check_day
from .security import (Principal, issue_token, new_id, normalize_pairing_code, sha256_hex)
from .store import Store


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


@dataclass
class Ctx:
    store: Store
    settings: Settings
    clock: Clock
    mind: Mind


AFTER_ROUND = {
    "lively": "That was a lively round. Well done.",
    "done": "Round done. Well done for showing up.",
    "stopped": "Thanks for playing. Every round counts.",
    "hard_to_track": "Thanks for playing. The room was hard to follow this time.",
}


def _audit(ctx: Ctx, p: Principal | None, action: str, outcome: str = "ok",
           reason: str | None = None, request_id: str | None = None, **detail) -> None:
    write_audit(ctx.store, ctx.clock.now(), clinic_id=p.clinic_id if p else None,
                patient_id=p.patient_id if p else None, actor=p.actor if p else "anonymous",
                action=action, outcome=outcome, reason=reason, detail=detail,
                request_id=request_id)


def repo_for(ctx: Ctx, p: Principal) -> PatientRepo:
    assert p.scope == "device" and p.clinic_id and p.patient_id
    return ctx.mind.repo(p.clinic_id, p.patient_id)


# ---- pairing -----------------------------------------------------------------------

def create_pairing_code(ctx: Ctx, clinic_id: str, patient_id: str) -> str:
    from .security import new_pairing_code
    code = new_pairing_code()
    now = ctx.clock.now()
    ctx.store.put(f"pairing/{sha256_hex(normalize_pairing_code(code))}.json", {
        "clinic_id": clinic_id, "patient_id": patient_id, "created_at": now.isoformat(),
        "expires_at": (now + timedelta(hours=ctx.settings.pairing_ttl_hours)).isoformat()})
    return code


async def pair_device(ctx: Ctx, code: str, label: str, platform: str, rid: str) -> dict:
    now = ctx.clock.now()
    key = f"pairing/{sha256_hex(normalize_pairing_code(code))}.json"
    rec = ctx.store.get(key)
    if not rec or rec.get("used_at") or datetime.fromisoformat(rec["expires_at"]) <= now:
        why = "unknown" if not rec else ("replayed" if rec.get("used_at") else "expired")
        write_audit(ctx.store, now, clinic_id=None, patient_id=None, actor="anonymous",
                    action="pair", outcome="refused", reason=f"pairing_code_{why}", request_id=rid)
        raise ApiError(400, "invalid_pairing_code", "The pairing code is not valid.")
    rec["used_at"] = now.isoformat()  # one-time: mark before issuing
    ctx.store.put(key, rec)
    c, pid = rec["clinic_id"], rec["patient_id"]
    dev = new_id("dev")
    ctx.store.put(f"clinics/{c}/patients/{pid}/devices/{dev}.json",
                  {"id": dev, "label": label, "platform": platform, "created_at": now.isoformat()})
    token = issue_token(ctx.store, "device", clinic_id=c, patient_id=pid, device_id=dev, now=now)
    write_audit(ctx.store, now, clinic_id=c, patient_id=pid, actor=f"device:{dev}",
                action="pair", detail={"device_id": dev}, request_id=rid)
    return {"device_token": token, "patient_id": pid}


# ---- daily data --------------------------------------------------------------------------

async def ingest_days(ctx: Ctx, p: Principal, days: list[dict], rid: str) -> dict:
    repo = repo_for(ctx, p)
    async with ctx.mind.lock(p.clinic_id, p.patient_id):
        now = ctx.clock.now()
        today = repo.local(now).date()
        by_date: dict[str, list[dict]] = {}
        for d in days:
            by_date.setdefault(d["date"], []).append(d)
        have = repo.days()
        accepted, rejected, changed = [], [], []
        for ds, group in sorted(by_date.items()):
            reason = None
            if any(g != group[0] for g in group[1:]):
                reason = "conflicting_duplicate"
            rec = group[0]
            reason = reason or check_day(rec, today)
            if reason:
                rejected.append({"date": ds, "reason": reason})
                repo.put(f"rejected/{now.strftime('%Y%m%dT%H%M%S%f')}-{secrets.token_hex(3)}.json",
                         {"at": now.isoformat(), "date": ds, "reason": reason})
                _audit(ctx, p, "day", "refused", reason, rid, date=ds)
                continue
            # Merge, never replace: a value the upload leaves out (a watch that has not
            # synced last night yet, a phone without a watch) keeps what is stored, so
            # re-sending a day is always safe. Seeded example days are replaced whole.
            old = have.get(ds) or {}
            if old.get("example"):
                old = {}
            merged = {k: old.get(k) if rec.get(k) is None else rec[k] for k in DAY_FIELDS}
            if old and all(old.get(k) == merged[k] for k in DAY_FIELDS):
                accepted.append(ds)  # nothing new: not written again, no reading scheduled
                continue
            repo.put(f"days/{ds}.json", {"date": ds, **merged, "received_at": now.isoformat(),
                                         "example": False, "source": "device"})
            accepted.append(ds)
            changed.append(ds)
        if changed:
            _audit(ctx, p, "day", "ok", None, rid, days=len(changed), last=changed[-1])
            xp.sync(repo, now)
        await ctx.mind.publish("day", p.clinic_id, p.patient_id, days=len(changed),
                               last_day=changed[-1] if changed else "none",
                               rejected=len(rejected))
        status = _status(ctx, repo)
    if changed:
        # Clinician-only, behind the consent: level 2 reads the daily numbers again.
        await ctx.mind.schedule_days_reading(repo)
    return {"accepted": accepted, "rejected": rejected, "status": status}


DAY_FIELDS = ("steps", "walking_speed_m_s", "hrv_ms", "sleep_h")


# The four HealthKit types the mind compares with the person's own normal, and
# the field of the day record each fills. Every other type is stored and shown
# to the clinician, and a few of them go into the day reading (mind/day_reading.py).
HEALTH_DAY_FIELDS = {
    "HKQuantityTypeIdentifierStepCount": "steps",
    "HKQuantityTypeIdentifierWalkingSpeed": "walking_speed_m_s",
    "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": "hrv_ms",
    "HKCategoryTypeIdentifierSleepAnalysis": "sleep_h",
}
HEALTH_MAX_DAYS = 400  # per type, the most recent are kept


def health_key(type_id: str) -> str:
    return "health/" + re.sub(r"[^A-Za-z0-9]", "_", type_id) + ".json"


async def ingest_health(ctx: Ctx, p: Principal, body: dict, rid: str) -> dict:
    """An Apple Health summary from the HealthKit harness app: per type, one
    value per day. Every type is stored (numbers by day, nothing else of the
    summary). Steps, walking speed, sleep and HRV also fill the day records,
    through the same checks as POST /v1/daily, so the own-normal comparison
    sees them. A day needs steps to exist; values for a day without steps stay
    in the stored type only."""
    import math
    repo = repo_for(ctx, p)
    stored, fill = [], {}
    async with ctx.mind.lock(p.clinic_id, p.patient_id):
        now = ctx.clock.now()
        for m in body["metrics"]:
            tid = m["typeIdentifier"]
            vals: dict[str, float] = {}
            for d in m["daily"]:
                v = d.get("mean") if d.get("mean") is not None else d.get("sum")
                if v is None or not math.isfinite(v) or abs(v) > 1e7:
                    continue
                vals[d["day"]] = round(float(v), 4)
            if not vals:
                continue
            key = health_key(tid)
            old = repo.get(key) or {}
            days = {**(old.get("days") or {}), **vals}
            days = dict(sorted(days.items())[-HEALTH_MAX_DAYS:])
            repo.put(key, {"type": tid, "unit": m.get("unit"), "aggregation": m["aggregation"],
                           "days": days, "updated_at": now.isoformat()})
            stored.append({"type": tid, "days": len(days), "last_day": max(days)})
            field = HEALTH_DAY_FIELDS.get(tid)
            if field:
                for ds, v in vals.items():
                    fill.setdefault(ds, {})[field] = int(round(v)) if field == "steps" else v
        have = repo.days()
    changed = []
    for ds, new in sorted(fill.items()):
        old = have.get(ds) or {}
        rec = {"date": ds, **{k: old.get(k) for k in DAY_FIELDS}, **new}
        if rec["steps"] is None:
            continue  # a day record needs steps
        if any(rec[k] != old.get(k) for k in DAY_FIELDS):
            changed.append(rec)
    out = {"accepted": [], "rejected": []}
    if changed:
        out = await ingest_days(ctx, p, changed, rid)
    _audit(ctx, p, "health_summary", "ok", None, rid, types=len(stored),
           days_updated=len(out["accepted"]))
    return {"stored": stored, "days_updated": out["accepted"], "rejected": out["rejected"],
            "status": out.get("status") or _status(ctx, repo)}


def _status(ctx: Ctx, repo: PatientRepo) -> str:
    from .mind.watchers import compute_status
    return compute_status(ctx.mind.build_view(repo))


# ---- rounds -----------------------------------------------------------------------------

def after_round_line(rec: dict) -> dict:
    if rec["quality"] == "low":
        tid = "hard_to_track"
    elif rec["ended_by"] != "finished":
        tid = "stopped"
    elif rec.get("energy_bucket") == "high":
        tid = "lively"
    else:
        tid = "done"
    return {"template_id": tid, "text": AFTER_ROUND[tid]}


async def record_round(ctx: Ctx, p: Principal, body: dict, rid: str) -> dict:
    repo = repo_for(ctx, p)
    async with ctx.mind.lock(p.clinic_id, p.patient_id):
        now = ctx.clock.now()
        body = {**body, "started_at": body["started_at"]}
        reason = check_round(body, now)
        if reason:
            repo.put(f"rejected/{now.strftime('%Y%m%dT%H%M%S%f')}-{secrets.token_hex(3)}.json",
                     {"at": now.isoformat(), "date": body["started_at"][:10], "reason": reason})
            _audit(ctx, p, "round", "refused", reason, rid, round_id=body["id"])
            await ctx.mind.publish("day", p.clinic_id, p.patient_id)  # oddity watcher
            raise ApiError(422, "implausible_round", f"The round was rejected: {reason}.")
        sug = None
        if body.get("suggestion_id"):
            sug = repo.get(f"suggestions/{body['suggestion_id']}.json")
            if sug is None:
                _audit(ctx, p, "round", "refused", "unknown_suggestion", rid, round_id=body["id"])
                raise ApiError(404, "not_found", "Suggestion not found.")
        previous = [r for r in repo.rounds() if r["id"] != body["id"]
                    and r["started_at"] < body["started_at"]]
        rec = process_round(body, previous)
        old = repo.get(f"rounds/{body['id']}.json")
        rec["received_at"] = now.isoformat()
        rec["example"] = False
        rec["analysis"] = {"status": ctx.mind.reading_state(repo, rec)}
        if old and old.get("analysis", {}).get("status") == "ready":
            rec["analysis"] = old["analysis"]
        repo.put(f"rounds/{rec['id']}.json", rec)
        if sug is not None:
            sug["round_id"] = rec["id"]
            if body["completed"]:
                sug["round_completed"] = True
                if sug["status"] in ("open", "expired"):
                    sug.update(status="done", resolved_at=now.isoformat())
            repo.put(f"suggestions/{sug['id']}.json", sug)
        _audit(ctx, p, "round", "ok", None, rid, round_id=rec["id"], quality=rec["quality"],
               upsert=bool(old))
        await ctx.mind.publish("round", p.clinic_id, p.patient_id, round_id=rec["id"])
        analysis = rec["analysis"]["status"]
        if analysis == "pending":
            await ctx.mind.schedule_reading(repo, rec["id"])
    return {"id": rec["id"], "quality": rec["quality"], "energy_bucket": rec["energy_bucket"],
            "analysis": analysis if analysis in ("pending", "off", "not_allowed") else "pending",
            "after_round": after_round_line(rec)}


def round_analysis(ctx: Ctx, p: Principal, round_id: str) -> dict:
    from .mind.reading import PATIENT_LINES
    rec = repo_for(ctx, p).get(f"rounds/{round_id}.json")
    if rec is None:
        raise ApiError(404, "not_found", "Round not found.")
    a = rec.get("analysis") or {"status": "off"}
    out = {"status": a["status"], "line": None}
    if a["status"] == "ready":
        out["line"] = PATIENT_LINES[a["reading"]["pattern"]]
    return out


# ---- feedback ------------------------------------------------------------------------------

async def record_feedback(ctx: Ctx, p: Principal, body: dict, rid: str) -> dict:
    repo = repo_for(ctx, p)
    async with ctx.mind.lock(p.clinic_id, p.patient_id):
        now = ctx.clock.now()
        sug = repo.get(f"suggestions/{body['suggestion_id']}.json")
        if sug is None:
            _audit(ctx, p, "feedback", "refused", "unknown_suggestion", rid)
            raise ApiError(404, "not_found", "Suggestion not found.")
        old = repo.get(f"feedback/{body['id']}.json")
        if old and old["suggestion_id"] != body["suggestion_id"]:
            _audit(ctx, p, "feedback", "refused", "id_reused", rid, feedback_id=body["id"])
            raise ApiError(409, "conflict", "This feedback id belongs to another suggestion.")
        fb = {**body, "received_at": old["received_at"] if old else now.isoformat()}
        repo.put(f"feedback/{body['id']}.json", fb)
        sug.update(answer=body["answer"], felt=body.get("felt"), answered_at=now.isoformat())
        if sug["status"] in ("open", "expired"):
            sug["status"] = "answered"
            sug["resolved_at"] = now.isoformat()
        repo.put(f"suggestions/{sug['id']}.json", sug)
        _audit(ctx, p, "feedback", "ok", None, rid, feedback_id=body["id"],
               suggestion_id=sug["id"], answer=body["answer"], upsert=bool(old))
        await ctx.mind.publish("feedback", p.clinic_id, p.patient_id, suggestion_id=sug["id"])
    return {"ok": True}


# ---- the note: one free-text field, classified only ---------------------------------------

async def classify_text(ctx: Ctx, p: Principal, repo: PatientRepo, note_id: str, text: str,
                        rid: str, source: str = "note", activity_id: str | None = None) -> dict:
    """The one path for free text, notes and check-in words alike. Caller holds
    the patient lock and a trace chain. Classification only: the code word list
    and, when configured, the level-1 model through both gates. The text is
    stored for the patient's record and nowhere else: the audit and the trace
    get enums only."""
    now = ctx.clock.now()
    lex = note_logic.lexicon_check(text)
    model_cls, model_state = None, "off"
    if getattr(ctx.mind.local, "configured", False):
        ids = [t for t in note_logic.reply_templates() if t != "help"]
        pack = INPUT_GATE.note_pack(1, text, ids)
        raw = await ctx.mind.local.complete(pack, json_mode=True)
        res = OUTPUT_GATE.note(raw, ids)
        if res.ok:
            model_cls, model_state = res.value, "ok"
        else:
            model_state = "refused" if raw is not None else "unavailable"
            for r in res.refusals:
                if raw is not None:
                    ctx.mind.refuse(repo, r)
        # The trace says what the model saw by name only; the text stays out.
        ctx.mind.trace(repo, "level1", {"ok": "accepted", "refused": "refused"}
                       .get(model_state, "no_reply"), {
            "task": "note", "source": source,
            "saw": {"fields": [f"{source} words (inside data markers, stays on this server)",
                               "reply_template ids"]},
            "returned": None if model_cls is None else
            {k: model_cls.get(k) for k in ("mood", "topic", "asks_for_help")},
            "verdict": model_state,
            "reasons": [r.reason for r in res.refusals] if model_state == "refused" else [],
            "used": "model_and_word_list" if model_cls else "word_list_only"},
            notable=model_state == "refused")
    else:
        ctx.mind.trace(repo, "level1", "off", {"task": "note", "source": source,
                                               "used": "word_list_only"})
    cls = note_logic.merge(lex, model_cls)
    cls["model"] = model_state
    rec = {"id": note_id, "at": now.isoformat(), "text": text, "text_sha256": sha256_hex(text),
           "classification": cls, "source": source}
    if activity_id:
        rec["activity_id"] = activity_id
    repo.put(f"notes/{note_id}.json", rec)
    # Audit holds enums only, never the text.
    _audit(ctx, p, "note", "ok", None, rid, note_id=note_id, source=source, crisis=cls["crisis"],
           mood=cls["mood"], topic=cls["topic"], model=model_state)
    return cls


def _chat_earlier(repo: PatientRepo, now: datetime, note_id: str) -> list[dict]:
    """Today's earlier turns of the conversation (patient's local day): the
    person's notes and Lanvi's replies, oldest first. A note that opened the help
    screen is left out with its reply, so its words never reach the model."""
    today = repo.local(now).date()
    turns: list[dict] = []
    for n in repo.notes():
        if n["id"] == note_id or n.get("source", "note") != "note":
            continue
        try:
            day = repo.local(datetime.fromisoformat(n["at"])).date()
        except (KeyError, ValueError):
            continue
        cls = n.get("classification") or {}
        if day != today or cls.get("crisis") or cls.get("asks_for_help"):
            continue
        turns.append({"role": "person", "text": n.get("text") or ""})
        reply = (n.get("reply") or {}).get("text") or \
            note_logic.reply_templates().get(cls.get("template_id"))
        if reply:
            turns.append({"role": "lanvi", "text": reply})
    return turns


async def chat_reply(ctx: Ctx, p: Principal, repo: PatientRepo, note_id: str, text: str,
                     cls: dict) -> dict | None:
    """CHAT_MODE=gemini: Lanvi's reply written by Gemini, or None for the fixed
    line. Runs only AFTER classification, and never for a note that opened the
    help screen: the code checks decide alone and the model cannot change them."""
    outreach = ctx.mind.outreach
    if ctx.settings.chat_mode != "gemini" or outreach is None:
        return None
    if cls["crisis"] or cls["asks_for_help"] or cls.get("lexicon_help"):
        ctx.mind.trace(repo, "level2", "skipped", {"task": "chat", "reason": "help_screen",
                                                   "used": "fixed_line"})
        return None
    patient = repo.patient() or {}
    if not patient.get("allow_outside_processing"):
        ctx.mind.trace(repo, "level2", "skipped", {"task": "chat", "reason": "no_consent",
                                                   "used": "fixed_line"})
        return None
    if not getattr(outreach, "chat_on", False):
        ctx.mind.trace(repo, "level2", "off", {"task": "chat", "used": "fixed_line"})
        return None
    # The record's own identifying values: if one is in the words, nothing is sent.
    forbidden = [str(v) for v in (patient.get("id"), patient.get("clinic_id"),
                                  patient.get("label"), patient.get("display_name"), note_id) if v]
    earlier = _chat_earlier(repo, ctx.clock.now(), note_id)
    try:
        pack = INPUT_GATE.chat_pack(text, earlier, forbidden)
    except GateError as e:
        ctx.mind.refuse(repo, e.refusal)
        ctx.mind.trace(repo, "level2", "refused", {"task": "chat", "verdict": "input_refused",
                                                   "reasons": [e.refusal.reason],
                                                   "used": "fixed_line"}, notable=True)
        return None
    raw = await outreach.chat_complete(pack, forbidden)
    res = OUTPUT_GATE.chat(raw)
    written = None
    if res.ok:
        from .llm.gemini import chat_model
        written = {"template_id": "gemini", "text": res.value, "written_by": "model",
                   "model": chat_model(ctx.settings)}
    elif raw is not None:
        for r in res.refusals:
            ctx.mind.refuse(repo, r)
    # The trace keeps codes only: never the words or the reply.
    ctx.mind.trace(repo, "level2", "accepted" if res.ok else ("refused" if raw is not None
                                                              else "no_reply"), {
        "task": "chat",
        "saw": {"fields": ["the note just written", f"{len(earlier)} earlier turns of today"]},
        "verdict": "ok" if res.ok else ("refused" if raw is not None else "unavailable"),
        "reasons": [r.reason for r in res.refusals] if raw is not None else [],
        "used": "model_reply" if res.ok else "fixed_line"},
        notable=raw is not None and not res.ok)
    return written


async def record_note(ctx: Ctx, p: Principal, note_id: str, text: str, rid: str) -> dict:
    repo = repo_for(ctx, p)
    async with ctx.mind.lock(p.clinic_id, p.patient_id):
        old = repo.get(f"notes/{note_id}.json")
        if old is not None:
            if old["text_sha256"] != sha256_hex(text):
                _audit(ctx, p, "note", "refused", "id_reused", rid, note_id=note_id)
                raise ApiError(409, "conflict", "This note id was used for another note.")
            cls = old["classification"]
            written = old.get("reply")
        else:
            # One trace chain for the note: the classification and what the mind did after.
            with ctx.mind.tracer.chain(p.clinic_id, p.patient_id, "note"):
                cls = await classify_text(ctx, p, repo, note_id, text, rid)
                written = await chat_reply(ctx, p, repo, note_id, text, cls)
                if written is not None:
                    rec = repo.get(f"notes/{note_id}.json")
                    repo.put(f"notes/{note_id}.json", {**rec, "reply": written})
                if ctx.settings.chat_mode == "gemini":
                    _audit(ctx, p, "note_reply", "ok", None, rid, note_id=note_id,
                           written_by="model" if written else "fixed")
                await ctx.mind.publish("note", p.clinic_id, p.patient_id, note_id=note_id)
        open_s = next((s for s in repo.suggestions() if s["status"] == "open"), None)
    reply = ({"template_id": written["template_id"], "text": written["text"]}
             if written and not cls["crisis"] else
             {"template_id": cls["template_id"],
              "text": note_logic.reply_templates()[cls["template_id"]]})
    out = {"reply": reply,
           "crisis": cls["crisis"],
           "crisis_block": crisis_block(ctx) if cls["crisis"] else None,
           "suggestion": suggestion_out(open_s)}
    return out


# ---- activities: focus, breathing, check-in -------------------------------------------------

def _canonical_sha(body: dict) -> str:
    return sha256_hex(json.dumps(body, sort_keys=True, separators=(",", ":")))


def _text_note_id(activity_id: str, slot: str) -> str:
    return f"ck-{sha256_hex(activity_id)[:24]}-{slot}"


def after_activity_line(rec: dict, crisis: bool) -> dict:
    if crisis:
        return {"template_id": "help", "text": note_logic.reply_templates()["help"]}
    t = rec["type"]
    if rec["ended_by"] == "interrupted" and t != "checkin":
        return lines.after_activity("interrupted")
    if t in ("focus", "breathing"):
        return lines.after_activity(f"{t}_done" if played_to_the_end(rec) else f"{t}_stopped")
    if rec.get("plan_done") == "yes":
        return lines.after_activity("plan_done_yes")
    if rec.get("plan_done") == "no":
        return lines.after_activity("plan_done_no")
    return lines.after_activity("checkin_plan" if rec.get("plan") else "checkin_done")


def _activity_out(ctx: Ctx, repo: PatientRepo, rec: dict, xp_gained: int, crisis: bool) -> dict:
    st = xp.load(repo)
    f = xp.facts(st)
    return {"id": rec["id"], "type": rec["type"], "xp_gained": xp_gained, "xp_total": f["xp"],
            "stage": f["stage"], "next_stage_at": f["next_stage_at"], "glow": f["glow"],
            "wandering": st["wandering"]["state"], "line": after_activity_line(rec, crisis),
            "crisis": crisis, "crisis_block": crisis_block(ctx) if crisis else None,
            "reading": (rec.get("analysis") or {}).get("status", "not_applicable")}


def activity_reading(ctx: Ctx, p: Principal, activity_id: str) -> dict:
    """The patient-safe side of the session reading: a status and, when ready,
    one neutral line. Never the reading itself, never a mood or a face."""
    from .mind.session_reading import PATIENT_LINES
    rec = repo_for(ctx, p).get(f"activities/{activity_id}.json")
    if rec is None:
        raise ApiError(404, "not_found", "Activity not found.")
    a = rec.get("analysis") or {"status": "not_applicable"}
    status = a["status"]
    return {"status": status,
            "line": PATIENT_LINES.get(rec["type"]) if status == "ready" else None}


async def record_activity(ctx: Ctx, p: Principal, body: dict, rid: str) -> dict:
    repo = repo_for(ctx, p)
    async with ctx.mind.lock(p.clinic_id, p.patient_id):
        now = ctx.clock.now()
        sha = _canonical_sha(body)
        old = repo.get(f"activities/{body['id']}.json")
        if old is not None:
            if old["content_sha256"] != sha:
                _audit(ctx, p, "activity", "refused", "id_reused", rid, activity_id=body["id"])
                raise ApiError(409, "conflict", "This activity id was used for another record.")
            return _activity_out(ctx, repo, old, 0, bool(old.get("crisis")))
        reason = check_activity(body, now)
        if reason is None and body["type"] == "checkin":
            items = list(body.get("good_things") or [])
            if any(x.get("catalog_id") and x["catalog_id"] not in lines.good_thing_ids()
                   for x in items):
                reason = "unknown_good_thing"
            plan = body.get("plan")
            if plan and plan.get("catalog_id") and plan["catalog_id"] not in lines.plan_ids():
                reason = "unknown_plan"
        if reason:
            repo.put(f"rejected/{now.strftime('%Y%m%dT%H%M%S%f')}-{secrets.token_hex(3)}.json",
                     {"at": now.isoformat(), "date": body["started_at"][:10], "reason": reason})
            _audit(ctx, p, "activity", "refused", reason, rid, activity_id=body["id"],
                   type=body["type"])
            await ctx.mind.publish("day", p.clinic_id, p.patient_id)  # oddity watcher
            raise ApiError(422, "implausible_activity", f"The activity was rejected: {reason}.")
        sug = None
        if body.get("suggestion_id"):
            sug = repo.get(f"suggestions/{body['suggestion_id']}.json")
            if sug is None:
                _audit(ctx, p, "activity", "refused", "unknown_suggestion", rid,
                       activity_id=body["id"])
                raise ApiError(404, "not_found", "Suggestion not found.")
        with ctx.mind.tracer.chain(p.clinic_id, p.patient_id, "activity"):
            stored = {k: v for k, v in body.items() if k not in ("good_things", "plan")}
            crisis = False
            if body["type"] == "checkin":
                # Typed words become notes (the same machinery); the record keeps
                # only references, never the words.
                refs = []
                for i, item in enumerate(body.get("good_things") or [], 1):
                    if item.get("text") is not None:
                        nid = _text_note_id(body["id"], f"g{i}")
                        cls = await classify_text(ctx, p, repo, nid, item["text"], rid,
                                                  source="checkin", activity_id=body["id"])
                        crisis = crisis or cls["crisis"]
                        refs.append({"note_id": nid})
                    else:
                        refs.append({"catalog_id": item["catalog_id"]})
                stored["good_things"] = refs
                plan = body.get("plan")
                stored["plan"] = None
                if plan is not None:
                    if plan.get("text") is not None:
                        nid = _text_note_id(body["id"], "plan")
                        cls = await classify_text(ctx, p, repo, nid, plan["text"], rid,
                                                  source="checkin", activity_id=body["id"])
                        crisis = crisis or cls["crisis"]
                        stored["plan"] = {"note_id": nid}
                    else:
                        stored["plan"] = {"catalog_id": plan["catalog_id"]}
            raw = stored.pop("face_raw", None)
            if raw is not None:
                # The phone sent raw frames: the server computes the summary and
                # keeps the frames as their own object, outside the activity
                # record and outside every pack, for re-analysis.
                repo.put(f"faceraw/{body['id']}.json", _raw_object(body, raw, now))
                stored.update(face=face_features.summarize(raw), face_source="raw",
                              face_raw_info=face_features.describe(raw))
            elif stored.get("face") is not None:
                stored["face_source"] = "summary"
            previous = [a for a in repo.activities() if a["started_at"] < body["started_at"]]
            rec = process_activity(stored, previous)
            rec.update(received_at=now.isoformat(), example=False, content_sha256=sha,
                       crisis=crisis, analysis={"status": ctx.mind.session_reading_state(repo, rec)})
            if rec.get("face_source") == "raw":
                # The frame reading (clinician-only): level 2 reads the frames, code checks.
                rec["frames_reading"] = {"status": ctx.mind.frames_reading_state(repo, rec)}
            repo.put(f"activities/{rec['id']}.json", rec)
            if sug is not None:
                sug["activity_id"] = rec["id"]
                sug["played"] = True
                if sug["status"] in ("open", "expired"):
                    sug.update(status="done", resolved_at=now.isoformat())
                repo.put(f"suggestions/{sug['id']}.json", sug)
            _st, new = xp.sync(repo, now)
            gained = sum(a["xp"] for a in new if a.get("by") == rec["id"])
            _audit(ctx, p, "activity", "ok", None, rid, activity_id=rec["id"], type=rec["type"],
                   ended_by=rec["ended_by"], face_quality=rec["face_quality"],
                   face_source=rec.get("face_source"), xp_gained=gained, crisis=crisis)
            await ctx.mind.publish("activity", p.clinic_id, p.patient_id, activity_id=rec["id"],
                                   xp_gained=gained)
        if rec["analysis"]["status"] == "pending":
            await ctx.mind.schedule_session_reading(repo, rec["id"])
        if (rec.get("frames_reading") or {}).get("status") == "pending":
            await ctx.mind.schedule_frames_reading(repo, rec["id"])
        return _activity_out(ctx, repo, rec, gained, crisis)


def _raw_object(body: dict, raw: dict, now: datetime) -> dict:
    """The raw frames as sent, plus counts. Stored at faceraw/{activity_id}.json."""
    tracked = raw.get("tracked")
    return {"activity_id": body["id"], "type": body["type"], "started_at": body["started_at"],
            "received_at": now.isoformat(), "rate_hz": raw["rate_hz"],
            "channels": raw["channels"], "samples": raw["samples"], "tracked": tracked,
            "moments_ms": raw.get("moments_ms"), "frames": len(raw["samples"]),
            "channel_count": len(raw["channels"]),
            "tracked_frames": len(raw["samples"]) if tracked is None else sum(tracked)}


def recompute_face(repo: PatientRepo, activity_id: str) -> bool:
    """Compute the face summary of one raw session again from its stored frames,
    with the current thresholds, and rewrite the activity's face summary, face
    quality and face z values (against the same earlier sessions). The caller
    holds the patient lock. False when the activity or its frames are missing."""
    raw = repo.get(f"faceraw/{activity_id}.json")
    rec = repo.get(f"activities/{activity_id}.json")
    if raw is None or rec is None:
        return False
    face = face_features.summarize(raw)
    previous = [a for a in repo.activities() if a["started_at"] < rec["started_at"]]
    redo = process_activity({**rec, "face": face}, previous)
    rec.update(face=face, face_source="raw", face_raw_info=face_features.describe(raw),
               face_quality=redo["face_quality"], face_z=redo["face_z"], usual=redo["usual"])
    repo.put(f"activities/{activity_id}.json", rec)
    return True


def recompute_faces(repo: PatientRepo) -> int:
    """recompute_face for every raw session of the patient, oldest first, so a
    later session's own normal sees the earlier ones' new values."""
    ids = [k.rsplit("/", 1)[1][:-len(".json")] for k in repo.store.list(repo.p + "faceraw/")]
    recs = [r for r in (repo.get(f"activities/{i}.json") for i in ids) if r is not None]
    return sum(recompute_face(repo, r["id"])
               for r in sorted(recs, key=lambda r: (r["started_at"], r["id"])))


def checkin_options() -> dict:
    cat = lines.checkin_catalog()
    return {"good_things": [{"id": x["id"], "label": x["label"]} for x in cat["good_things"]],
            "plans": [{"id": x["id"], "label": x["label"]} for x in cat["plans"]]}


async def set_preferences(ctx: Ctx, p: Principal, helps: list[str], rid: str) -> dict:
    repo = repo_for(ctx, p)
    async with ctx.mind.lock(p.clinic_id, p.patient_id):
        repo.put("mind/preferences.json", {"helps": helps,
                                           "updated_at": ctx.clock.now().isoformat()})
        _audit(ctx, p, "preferences", "ok", None, rid, helps=helps)
        await ctx.mind.publish("preferences", p.clinic_id, p.patient_id)
    return {"helps": helps, "line": lines.preference_ack(helps[0] if helps else None)}


async def answer_wandering(ctx: Ctx, p: Principal, wandering_id: str, answer: str,
                           rid: str) -> dict:
    repo = repo_for(ctx, p)
    async with ctx.mind.lock(p.clinic_id, p.patient_id):
        now = ctx.clock.now()
        st = xp.load(repo)
        if not xp.answer(st, wandering_id, answer, now):
            _audit(ctx, p, "wandering_answer", "refused", "not_waiting", rid)
            raise ApiError(404, "not_found", "No story is waiting under this id.")
        repo.put(xp.STATE_KEY, st)
        _audit(ctx, p, "wandering_answer", "ok", None, rid, wandering_id=wandering_id,
               answer=answer)
    return {"id": wandering_id, "answer": answer, "wandering": xp.wandering_out(st)}


def crisis_block(ctx: Ctx) -> dict:
    from .help import help_block
    return help_block(ctx.settings)


def suggestion_out(s: dict | None) -> dict | None:
    if not s:
        return None
    return {"id": s["id"], "action": s["action"], "text": s["text"], "created_at": s["created_at"]}


# ---- the mind, from the patient's side ----------------------------------------------------

async def add_rule(ctx: Ctx, p: Principal, rule: dict, rid: str) -> dict:
    repo = repo_for(ctx, p)
    async with ctx.mind.lock(p.clinic_id, p.patient_id):
        rules = repo.rules()
        if len(rules) >= 20:
            _audit(ctx, p, "rule", "refused", "too_many_rules", rid)
            raise ApiError(400, "too_many_rules", "At most 20 rules.")
        rec = {"id": new_id("rule"), "type": rule["type"], "params": rule["params"],
               "created_at": ctx.clock.now().isoformat()}
        repo.put("mind/rules.json", {"rules": rules + [rec]})
        _audit(ctx, p, "rule_add", "ok", None, rid, rule_id=rec["id"], type=rec["type"])
        await ctx.mind.publish("rule", p.clinic_id, p.patient_id)
    return rec


async def delete_rule(ctx: Ctx, p: Principal, rule_id: str, rid: str) -> None:
    repo = repo_for(ctx, p)
    async with ctx.mind.lock(p.clinic_id, p.patient_id):
        rules = repo.rules()
        keep = [r for r in rules if r["id"] != rule_id]
        if len(keep) == len(rules):
            _audit(ctx, p, "rule_delete", "refused", "not_found", rid)
            raise ApiError(404, "not_found", "Rule not found.")
        repo.put("mind/rules.json", {"rules": keep})
        _audit(ctx, p, "rule_delete", "ok", None, rid, rule_id=rule_id)
        await ctx.mind.publish("rule", p.clinic_id, p.patient_id)


async def reject_lesson(ctx: Ctx, p: Principal, lesson_id: str, rid: str) -> dict:
    repo = repo_for(ctx, p)
    async with ctx.mind.lock(p.clinic_id, p.patient_id):
        doc = repo.lessons_doc()
        lsn = next((x for x in doc["lessons"] if x["id"] == lesson_id), None)
        if lsn is None:
            _audit(ctx, p, "lesson_reject", "refused", "not_found", rid)
            raise ApiError(404, "not_found", "Lesson not found.")
        lsn.update(status="rejected", ended_at=ctx.clock.now().isoformat(), end_reason="patient")
        repo.put("mind/lessons.json", doc)
        _audit(ctx, p, "lesson_reject", "ok", None, rid, lesson_id=lesson_id)
        await ctx.mind.publish("lesson_rejected", p.clinic_id, p.patient_id, lesson_id=lesson_id)
    return {"id": lesson_id, "status": "rejected"}


async def answer_question(ctx: Ctx, p: Principal, qid: str, answer: str, rid: str) -> dict:
    repo = repo_for(ctx, p)
    async with ctx.mind.lock(p.clinic_id, p.patient_id):
        qs = repo.questions()
        q = next((x for x in qs if x["id"] == qid), None)
        if q is None or q["status"] != "open":
            _audit(ctx, p, "question_answer", "refused", "not_open", rid)
            raise ApiError(404, "not_found", "Open question not found.")
        q.update(status="answered", answer=answer, answered_at=ctx.clock.now().isoformat())
        repo.put("mind/questions.json", {"questions": qs})
        _audit(ctx, p, "question_answer", "ok", None, rid, question_id=qid, answer=answer)
        await ctx.mind.publish("question_answered", p.clinic_id, p.patient_id, question_id=qid)
    return {"id": qid, "status": "answered"}


# ---- clinician ------------------------------------------------------------------------------

async def ack_attention(ctx: Ctx, p: Principal, att_id: str, rid: str) -> dict:
    idx = ctx.store.get(f"clinics/{p.clinic_id}/attention_index/{att_id}.json")
    if idx is None:
        _audit(ctx, p, "attention_ack", "refused", "not_found_in_clinic", rid, attention_id=att_id)
        raise ApiError(404, "not_found", "Attention item not found.")
    repo = ctx.mind.repo(p.clinic_id, idx["patient_id"])
    async with ctx.mind.lock(p.clinic_id, idx["patient_id"]):
        item = repo.get(f"attention/{att_id}.json")
        if item is None or item["state"] != "open":
            raise ApiError(409, "conflict", "The item is not open.")
        days = sorted(repo.days())
        ctx.mind.close_item(repo, item, "acknowledged", ctx.clock.now(), actor=p.actor,
                            acked_through=days[-1] if days else "")
        await ctx.mind.publish("ack", p.clinic_id, idx["patient_id"], attention_id=att_id)
    return {"id": att_id, "state": "closed", "close_reason": "acknowledged"}
