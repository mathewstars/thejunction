"""What each write does, between the HTTP layer and the mind.

Every function here: checks tenant ownership by building keys only from the
caller's principal, takes the patient's lock, writes, audits, and publishes
one event to the mind's bus.
"""

from __future__ import annotations

import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta

from .audit import write_audit
from .config import Settings
from .mind import notes as note_logic
from .mind.engine import Clock, Mind
from .mind.gates import INPUT_GATE, OUTPUT_GATE
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
        accepted, rejected = [], []
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
            repo.put(f"days/{ds}.json", {**rec, "received_at": now.isoformat(),
                                         "example": False, "source": "device"})
            accepted.append(ds)
        if accepted:
            _audit(ctx, p, "day", "ok", None, rid, days=len(accepted), last=accepted[-1])
        await ctx.mind.publish("day", p.clinic_id, p.patient_id, days=len(accepted),
                               last_day=accepted[-1] if accepted else "none",
                               rejected=len(rejected))
        status = _status(ctx, repo)
    return {"accepted": accepted, "rejected": rejected, "status": status}


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

async def record_note(ctx: Ctx, p: Principal, note_id: str, text: str, rid: str) -> dict:
    repo = repo_for(ctx, p)
    async with ctx.mind.lock(p.clinic_id, p.patient_id):
        now = ctx.clock.now()
        old = repo.get(f"notes/{note_id}.json")
        if old is not None:
            if old["text_sha256"] != sha256_hex(text):
                _audit(ctx, p, "note", "refused", "id_reused", rid, note_id=note_id)
                raise ApiError(409, "conflict", "This note id was used for another note.")
            cls = old["classification"]
        else:
            # One trace chain for the note: the classification and what the mind did after.
            with ctx.mind.tracer.chain(p.clinic_id, p.patient_id, "note"):
                lex = note_logic.lexicon_check(text)
                model_cls, model_state = None, "off"
                if getattr(ctx.mind.local, "configured", False):
                    ids = [t for t in note_logic.REPLY_TEMPLATES if t != "help"]
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
                        "task": "note", "saw": {"fields": ["note (inside data markers, stays on "
                                                           "this server)", "reply_template ids"]},
                        "returned": None if model_cls is None else
                        {k: model_cls.get(k) for k in ("mood", "topic", "asks_for_help")},
                        "verdict": model_state,
                        "reasons": [r.reason for r in res.refusals] if model_state == "refused" else [],
                        "used": "model_and_word_list" if model_cls else "word_list_only"},
                        notable=model_state == "refused")
                else:
                    ctx.mind.trace(repo, "level1", "off", {"task": "note", "used": "word_list_only"})
                cls = note_logic.merge(lex, model_cls)
                cls["model"] = model_state
                repo.put(f"notes/{note_id}.json", {
                    "id": note_id, "at": now.isoformat(), "text": text, "text_sha256": sha256_hex(text),
                    "classification": cls})
                # Audit holds enums only, never the text.
                _audit(ctx, p, "note", "ok", None, rid, note_id=note_id, crisis=cls["crisis"],
                       mood=cls["mood"], topic=cls["topic"], model=model_state)
                await ctx.mind.publish("note", p.clinic_id, p.patient_id, note_id=note_id)
        open_s = next((s for s in repo.suggestions() if s["status"] == "open"), None)
    out = {"reply": {"template_id": cls["template_id"],
                     "text": note_logic.REPLY_TEMPLATES[cls["template_id"]]},
           "crisis": cls["crisis"],
           "crisis_block": crisis_block(ctx) if cls["crisis"] else None,
           "suggestion": suggestion_out(open_s)}
    return out


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
