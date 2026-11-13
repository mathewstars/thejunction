"""Learn: evidence table, deterministic lessons, validation of every claim.

Code builds the evidence. Code computes candidate lessons. A model may
propose more, but every proposal (from code or model) passes the same
validate_lesson() check, which recomputes the claim from the evidence table.
Code is the final judge.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime, timedelta

from .catalog import (ACTIONS, CONTEXTS, QUESTIONS, RATIONALES, ROUND_RATIONALES,
                      context_for_hour, lesson_text)
from .round_configs import ROUND_CONFIGS
from .thresholds import T, Thresholds

# question code -> (effect, rationale, context, action override)
_ANSWER_LESSONS = {
    "helped": ("prefer", "patient_said_yes", "any", None),
    "prefer_morning": ("prefer", "patient_said_yes", "morning", None),
    "seated_better": ("prefer", "patient_said_yes", "any", "ar_round_seated"),
    "too_much": ("avoid", "patient_said_too_much", "any", None),
}


# ---- evidence -----------------------------------------------------------------

def outcome_for(suggestion: dict, series_by_date: dict[str, dict], th: Thresholds = T) -> tuple[str, float | None]:
    """Change in movement z: mean of the next days minus the day itself."""
    d0 = date.fromisoformat(suggestion["date"])
    before = series_by_date.get(d0.isoformat(), {}).get("movement_z")
    if before is None:
        prev = series_by_date.get((d0 - timedelta(days=1)).isoformat(), {})
        before = prev.get("movement_z")
    after = []
    for k in range(1, th.outcome_days + 1):
        s = series_by_date.get((d0 + timedelta(days=k)).isoformat())
        if s and s.get("movement_z") is not None:
            after.append(s["movement_z"])
    if before is None or len(after) < th.outcome_days:
        return "unknown", None
    delta = sum(after) / len(after) - before
    if delta >= th.outcome_improved:
        return "improved", round(delta, 2)
    if delta <= th.outcome_worse:
        return "worse", round(delta, 2)
    return "same", round(delta, 2)


def evidence_table(suggestions: list[dict], series: list[dict], questions: list[dict],
                   tz_hour_of, th: Thresholds = T, rounds: list[dict] | None = None) -> list[dict]:
    """One row per resolved suggestion, per answered question, per good round."""
    by_date = {s["date"]: s for s in series}
    rows = []
    for s in suggestions:
        if s["status"] == "open":
            continue
        done = s.get("answer") == "did_it" or bool(s.get("round_completed"))
        outcome, delta = outcome_for(s, by_date, th) if done else ("unknown", None)
        rows.append({
            "id": s["id"], "kind": "suggestion", "action": s["action"],
            "context": context_for_hour(tz_hour_of(s["created_at"])),
            "date": s["date"], "done": done, "answer": s.get("answer") or "no_answer",
            "felt": s.get("felt"), "outcome": outcome, "delta": delta,
        })
    for r in rounds or []:
        if r.get("quality") != "good" or r["mode"] == "screen":
            continue
        reading = (r.get("analysis") or {}).get("reading") or {}
        rows.append({
            "id": r["id"], "kind": "round",
            "action": "ar_round_seated" if r["mode"] == "seated" else "ar_round",
            "context": context_for_hour(tz_hour_of(r["started_at"])),
            "date": r["started_at"][:10], "config_id": r["config"]["config_id"],
            "finished": r["ended_by"] == "finished", "stopped": r["ended_by"] == "user_stopped",
            "energy_bucket": r.get("energy_bucket") or "unknown",
            "pattern": reading.get("pattern"),
            "done": True, "answer": None, "felt": None, "outcome": "unknown", "delta": None,
        })
    for q in questions:
        if q.get("status") != "answered" or q["code"] not in _ANSWER_LESSONS:
            continue
        effect, _rat, ctx, override = _ANSWER_LESSONS[q["code"]]
        rows.append({
            "id": q["id"], "kind": "answer", "action": override or q["action"],
            "context": ctx, "date": q.get("answered_at", "")[:10], "question": q["code"],
            "answer": q["answer"], "done": None, "felt": None, "outcome": "unknown", "delta": None,
        })
    return rows


# ---- what each rationale means, as code -------------------------------------

def supports(rationale: str, row: dict) -> bool:
    if rationale == "done_and_improved":
        return row["kind"] == "suggestion" and row["done"] and row["outcome"] == "improved"
    if rationale == "done_and_worse":
        return row["kind"] == "suggestion" and row["done"] and row["outcome"] == "worse"
    if rationale == "felt_better_after":
        return row["kind"] == "suggestion" and row["done"] and row.get("felt") == "good"
    if rationale == "offered_not_done":
        return row["kind"] == "suggestion" and not row["done"]
    if rationale == "patient_said_yes":
        return row["kind"] == "answer" and row["answer"] == "yes" and \
            _ANSWER_LESSONS[row["question"]][1] == "patient_said_yes"
    if rationale == "config_finished_more":
        return row["kind"] == "round" and row["finished"]
    if rationale == "config_stopped_early":
        return row["kind"] == "round" and row["stopped"]
    if rationale == "patient_said_too_much":
        return row["kind"] == "answer" and row["answer"] == "yes" and row["question"] == "too_much"
    return False


def _relevant(rows: list[dict], action: str, context: str, rationale: str,
              config_id: str | None = None) -> list[dict]:
    if rationale in ROUND_RATIONALES:
        return [r for r in rows if r["kind"] == "round" and r["action"] == action
                and r["config_id"] == config_id and (context == "any" or r["context"] == context)]
    kind = "answer" if rationale.startswith("patient_said") else "suggestion"
    return [r for r in rows if r["kind"] == kind and r["action"] == action
            and (context == "any" or r["context"] == context)]


@dataclass
class Verdict:
    ok: bool
    reason: str = ""


def validate_lesson(p: dict, rows: list[dict], lessons_doc: dict, th: Thresholds = T) -> Verdict:
    """Recompute a lesson claim. p = {action, effect, context, evidence_ids, rationale_code}."""
    if p.get("action") not in ACTIONS:
        return Verdict(False, "action_not_in_catalog")
    if p.get("effect") not in ("prefer", "avoid"):
        return Verdict(False, "bad_effect")
    if p.get("context") not in CONTEXTS:
        return Verdict(False, "bad_context")
    rat = p.get("rationale_code")
    if rat not in RATIONALES:
        return Verdict(False, "bad_rationale")
    if RATIONALES[rat] != p["effect"]:
        return Verdict(False, "rationale_effect_mismatch")
    cfg = p.get("config_id")
    if cfg is not None and cfg not in ROUND_CONFIGS:
        return Verdict(False, "config_not_in_catalog")
    if (rat in ROUND_RATIONALES) != (cfg is not None):
        return Verdict(False, "config_rationale_mismatch")
    if cfg is not None and p["action"] not in ("ar_round", "ar_round_seated"):
        return Verdict(False, "config_needs_round_action")
    ids = p.get("evidence_ids") or []
    if len(ids) != len(set(ids)):
        return Verdict(False, "duplicate_evidence")
    by_id = {r["id"]: r for r in rows}
    if any(i not in by_id for i in ids):
        return Verdict(False, "unknown_evidence")
    cited = [by_id[i] for i in ids]
    if any(r["action"] != p["action"] for r in cited):
        return Verdict(False, "evidence_other_action")
    if cfg is not None and any(r.get("config_id") != cfg for r in cited):
        return Verdict(False, "evidence_other_config")
    if p["context"] != "any" and any(r["context"] != p["context"] for r in cited):
        return Verdict(False, "evidence_other_context")
    need = 1 if rat.startswith("patient_said") else th.min_evidence
    if len(cited) < need:
        return Verdict(False, "too_little_evidence")
    if not all(supports(rat, r) for r in cited):
        return Verdict(False, "evidence_does_not_support")
    relevant = _relevant(rows, p["action"], p["context"], rat, cfg)
    backing = [r for r in relevant if supports(rat, r)]
    if not relevant or len(backing) / len(relevant) < th.support_fraction:
        return Verdict(False, "claim_not_supported_overall")
    for old in lessons_doc.get("lessons", []):
        if old["status"] == "rejected" and old["action"] == p["action"] \
                and old.get("config_id") == cfg \
                and old["effect"] == p["effect"] and set(ids) <= set(old["evidence_ids"]):
            return Verdict(False, "rejected_by_patient")
    return Verdict(True)


# ---- deterministic candidates -----------------------------------------------

def code_candidates(rows: list[dict], th: Thresholds = T) -> list[dict]:
    out: list[dict] = []
    for action in ACTIONS:
        found: dict[tuple[str, str], dict] = {}
        for ctx in CONTEXTS[::-1]:  # "any" first
            for rat, effect in RATIONALES.items():
                if rat in ROUND_RATIONALES or (effect, "any") in found:
                    continue
                relevant = _relevant(rows, action, ctx, rat)
                backing = [r for r in relevant if supports(rat, r)]
                need = 1 if rat.startswith("patient_said") else th.min_evidence
                if len(backing) >= need and len(backing) / len(relevant) >= th.support_fraction:
                    found.setdefault((effect, ctx), {
                        "action": action, "effect": effect, "context": ctx,
                        "evidence_ids": [r["id"] for r in backing], "rationale_code": rat})
        effects = {e for e, _c in found}
        if effects == {"prefer", "avoid"}:
            continue  # the evidence disagrees with itself; learn nothing yet
        out.extend(found.values())
    # Round configs: which config gets finished, which gets stopped early.
    for action in ("ar_round", "ar_round_seated"):
        for cfg in ROUND_CONFIGS:
            cfound: dict = {}
            for ctx in CONTEXTS[::-1]:
                for rat in ROUND_RATIONALES:
                    effect = RATIONALES[rat]
                    if (effect, "any") in cfound:
                        continue
                    relevant = _relevant(rows, action, ctx, rat, cfg)
                    backing = [r for r in relevant if supports(rat, r)]
                    if len(backing) >= th.min_evidence and \
                            len(backing) / len(relevant) >= th.support_fraction:
                        cfound.setdefault((effect, ctx), {
                            "action": action, "effect": effect, "context": ctx,
                            "config_id": cfg, "evidence_ids": [r["id"] for r in backing],
                            "rationale_code": rat})
            # "finished" is the normal case: only learn a config preference
            # when it differs from how other configs went in that context.
            for (effect, ctx), c in cfound.items():
                if effect == "prefer":
                    others = [r for r in rows if r["kind"] == "round" and r["action"] == action
                              and r["config_id"] != cfg and (ctx == "any" or r["context"] == ctx)]
                    if not others or sum(1 for r in others if r["stopped"]) / len(others) < 0.5:
                        continue
                out.append(c)
    return out


def code_questions(rows: list[dict], lessons: list[dict], questions: list[dict]) -> list[dict]:
    """At most one question, when an action keeps not being done."""
    asked = {(q["code"], q["action"]) for q in questions}
    lesson_actions = {lsn["action"] for lsn in lessons if lsn["status"] == "active"}
    for action in ACTIONS:
        not_done = [r for r in rows if r["kind"] == "suggestion" and r["action"] == action
                    and not r["done"]]
        if len(not_done) >= 2 and action not in lesson_actions:
            if action == "ar_round" and ("seated_better", "ar_round_seated") not in asked:
                return [{"code": "seated_better", "action": "ar_round_seated"}]
            if ("too_much", action) not in asked:
                return [{"code": "too_much", "action": action}]
    return []


def validate_question(q: dict, questions: list[dict]) -> Verdict:
    if q.get("code") not in QUESTIONS:
        return Verdict(False, "question_not_in_catalog")
    if q.get("action") not in ACTIONS:
        return Verdict(False, "action_not_in_catalog")
    if q["code"] == "seated_better" and q["action"] != "ar_round_seated":
        return Verdict(False, "question_action_mismatch")
    if any(x["code"] == q["code"] and x["action"] == q["action"] for x in questions):
        return Verdict(False, "already_asked")
    return Verdict(True)


# ---- applying lessons -----------------------------------------------------------

@dataclass
class ApplyResult:
    added: list[dict] = field(default_factory=list)
    refreshed: list[dict] = field(default_factory=list)
    retired: list[dict] = field(default_factory=list)


def apply_lessons(doc: dict, accepted: list[dict], rows: list[dict], now: datetime,
                  review_id: str, th: Thresholds = T) -> ApplyResult:
    """Merge accepted lessons: expiry, contradiction, refresh, cap of 15."""
    res = ApplyResult()
    lessons = doc.setdefault("lessons", [])
    now_s = now.isoformat()

    def retire(lsn: dict, reason: str) -> None:
        lsn.update(status="retired" if reason != "expired" else "expired",
                   ended_at=now_s, end_reason=reason, ended_by_review=review_id)
        res.retired.append(lsn)

    for lsn in lessons:
        if lsn["status"] == "active" and lsn["expires_at"] <= now_s:
            retire(lsn, "expired")
    # Retire lessons that the current evidence no longer supports.
    for lsn in lessons:
        if lsn["status"] != "active":
            continue
        claim = {k: lsn.get(k) for k in ("action", "effect", "context", "evidence_ids",
                                         "rationale_code", "config_id")}
        claim["evidence_ids"] = [i for i in claim["evidence_ids"] if i in {r["id"] for r in rows}]
        if not claim["evidence_ids"] or not validate_lesson(claim, rows, {"lessons": []}, th).ok:
            retire(lsn, "contradicted")
    for p in accepted:
        same = [x for x in lessons if x["status"] == "active" and x["action"] == p["action"]
                and x["context"] == p["context"] and x.get("config_id") == p.get("config_id")]
        for x in same:
            if x["effect"] != p["effect"]:
                retire(x, "contradicted")
        twin = next((x for x in same if x["effect"] == p["effect"] and x["status"] == "active"), None)
        if twin:
            twin.update(evidence_ids=p["evidence_ids"], evidence_count=len(p["evidence_ids"]),
                        rationale_code=p["rationale_code"], review_id=review_id,
                        source=p["source"],
                        expires_at=(now + timedelta(days=th.lesson_ttl_days)).isoformat())
            res.refreshed.append(twin)
            continue
        lsn = {
            "id": p["id"], "action": p["action"], "effect": p["effect"], "context": p["context"],
            "config_id": p.get("config_id"),
            "rationale_code": p["rationale_code"], "evidence_ids": p["evidence_ids"],
            "evidence_count": len(p["evidence_ids"]), "status": "active",
            "text": lesson_text(p["action"], p["effect"], p["context"], p.get("config_id")),
            "source": p["source"], "review_id": review_id, "created_at": now_s,
            "expires_at": (now + timedelta(days=th.lesson_ttl_days)).isoformat(),
        }
        lessons.append(lsn)
        res.added.append(lsn)
    active = sorted((x for x in lessons if x["status"] == "active"), key=lambda x: x["created_at"])
    for x in active[: max(0, len(active) - th.max_active_lessons)]:
        retire(x, "cap")
    return res
