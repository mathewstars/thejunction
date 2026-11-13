"""Read-only projections of the mind: what the patient sees, what the
clinician sees, and the derived progress data for the dashboard.

Lessons never shape what the clinician sees: status and attention here come
from data and thresholds only.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta

from ..audit import list_audit
from ..help import help_block
from .notes import lexicon_reviewed
from .catalog import ACTIONS
from .repo import PatientRepo
from .round_configs import ROUND_DURATION_S
from .rounds import pick_round_config
from .watchers import LEVELS, View, compute_status, deviation_now, silent

PATIENT_SUMMARY = {
    "within": "Your days look like your usual.",
    "outside": "Your movement has been lower than your usual for a few days.",
    "no_data": "We have not received movement data for a few days.",
    "no_baseline": "We are still learning what your usual days look like.",
}


def today_view(mind, repo: PatientRepo, settings) -> dict:
    now = mind.clock.now()
    view = mind.build_view(repo, now)
    status = compute_status(view)
    sug = next((s for s in view.suggestions if s["status"] == "open"), None)
    local = repo.local(now)
    lessons = repo.lessons_doc().get("lessons", [])
    seated_action = bool(sug and sug["action"] == "ar_round_seated")
    cfg = pick_round_config(repo.patient_id, view.rounds, status, repo.rules(), lessons, local,
                            seated_action)
    cfg = {k: v for k, v in cfg.items() if k != "reason"}
    cfg["duration_s"] = ROUND_DURATION_S
    return {
        "status": status,
        "suggestion": None if not sug else {"id": sug["id"], "action": sug["action"],
                                            "text": sug["text"], "created_at": sug["created_at"]},
        "round_config": cfg,
        "attention": PATIENT_SUMMARY[status],
        "crisis": help_block(settings),
        "product_name": settings.product_name,
    }


def mind_view(repo: PatientRepo) -> dict:
    lessons = [x for x in repo.lessons_doc().get("lessons", []) if x["status"] == "active"]
    return {
        "rules": repo.rules(),
        "lessons": [{"id": x["id"], "text": x["text"], "action": x["action"],
                     "effect": x["effect"], "context": x["context"],
                     "config_id": x.get("config_id"), "evidence_count": x["evidence_count"],
                     "created_at": x["created_at"]} for x in lessons],
        "questions": [{"id": q["id"], "text": q["text"], "answers": ["yes", "no", "not_sure"]}
                      for q in repo.questions() if q["status"] == "open"],
    }


# ---- clinician --------------------------------------------------------------------------

def _summary(view: View, status: str, items: list[dict]) -> str:
    parts = []
    if status == "outside":
        _, lows = deviation_now(view)
        dev = next((i for i in items if i["kind"] == "deviation"), None)
        since = f", held since {dev['since']}" if dev else ""
        parts.append(f"Movement below own normal on {len(lows)} of the last "
                     f"{view.th.deviation_lookback} days{since}.")
    elif status == "no_data":
        last = max(view.days) if view.days else None
        parts.append(f"No daily data since {last}." if last else "No daily data yet.")
    elif status == "no_baseline":
        parts.append(f"Learning own normal ({len(view.days)} of {view.th.baseline_min_days} days).")
    else:
        parts.append("Within own normal.")
    kinds = {i["kind"] for i in items}
    if "asked_for_help" in kinds:
        parts.append("Asked for help in a note.")
    if any(i["level"] == "urgent" for i in items):
        parts.append("Needs review.")
    answered = [s for s in view.suggestions if s.get("answer")]
    if answered:
        last = answered[-1]
        parts.append(f"Last suggestion: {ACTIONS[last['action']].plain_name}, "
                     f"answer: {last['answer'].replace('_', ' ')}.")
    return " ".join(parts)


def clinician_line(mind, repo: PatientRepo) -> dict:
    view = mind.build_view(repo)
    status = compute_status(view)
    items = [i for i in view.items if i["state"] == "open"]
    patient = repo.patient()
    top = max((LEVELS.index(i["level"]) for i in items), default=-1)
    return {
        "patient_id": repo.patient_id, "label": patient["label"],
        "example": bool(patient.get("example")), "status": status,
        "level": LEVELS[top] if top >= 0 else None,
        "attention": [{"id": i["id"], "kind": i["kind"], "level": i["level"], "since": i["since"]}
                      for i in items],
        "last_data_day": max(view.days) if view.days else None,
        "summary": _summary(view, status, items),
    }


def progress(mind, repo: PatientRepo, view: View, rows: list[dict]) -> dict:
    """Derived data a dashboard can chart directly."""
    series = [{"date": s["date"], "z": s["z"], "movement_z": s["movement_z"],
               "example": s["example"]} for s in view.series]
    weeks = []
    start = view.today - timedelta(days=view.today.weekday()) - timedelta(weeks=5)
    for w in range(6):
        ws = start + timedelta(weeks=w)
        days = [ws + timedelta(days=k) for k in range(7) if ws + timedelta(days=k) <= view.today]
        zs = [s["movement_z"] for s in view.series
              if s["movement_z"] is not None and date.fromisoformat(s["date"]) in days]
        with_data = sum(1 for d in days if d.isoformat() in view.days)
        weeks.append({"week_start": ws.isoformat(),
                      "mean_movement_z": round(sum(zs) / len(zs), 2) if zs else None,
                      "days_with_data": with_data, "days_missing": len(days) - with_data})
    episodes = [{"id": i["id"], "kind": i["kind"], "start": i["since"],
                 "peak_level": i.get("peak_level", i["level"]),
                 "end": i["closed_at"][:10] if i.get("closed_at") else None,
                 "end_reason": i.get("close_reason")} for i in view.items]
    actions = {}
    for a in ACTIONS:
        sug = [s for s in view.suggestions if s["action"] == a]
        r = [x for x in rows if x["kind"] == "suggestion" and x["action"] == a]
        deltas = [x["delta"] for x in r if x["delta"] is not None]
        actions[a] = {
            "offered": len(sug),
            "done": sum(1 for x in r if x["done"]),
            "not_today": sum(1 for x in r if x["answer"] == "not_today"),
            "something_else": sum(1 for x in r if x["answer"] == "something_else"),
            "no_answer": sum(1 for x in r if x["answer"] == "no_answer" and not x["done"]),
            "open": sum(1 for s in sug if s["status"] == "open"),
            "outcomes": {k: sum(1 for x in r if x["outcome"] == k)
                         for k in ("improved", "same", "worse", "unknown")},
            "mean_outcome_change": round(sum(deltas) / len(deltas), 2) if deltas else None,
            "outcome_measure": f"change in movement z over the {view.th.outcome_days} days after",
        }
    ar_offered = [s for s in view.suggestions if s["action"] in ("ar_round", "ar_round_seated")]
    played_ids = {r.get("suggestion_id") for r in view.rounds}
    rounds = {
        "energy_series": [{"id": r["id"], "started_at": r["started_at"], "mode": r["mode"],
                           "config_id": r["config"]["config_id"], "quality": r["quality"],
                           "energy": r.get("energy"), "energy_bucket": r.get("energy_bucket"),
                           "ended_by": r["ended_by"], "example": bool(r.get("example")),
                           "reading": ((r.get("analysis") or {}).get("reading") or {}).get("pattern")}
                          for r in view.rounds],
        "played_vs_offered": {
            "offered": len(ar_offered),
            "played_when_offered": sum(1 for s in ar_offered if s["id"] in played_ids),
            "played_unprompted": sum(1 for r in view.rounds if not r.get("suggestion_id")),
        },
    }
    band = {"low_z": view.th.low_day_z, "high_z": -view.th.low_day_z,
            "novelty_z": view.th.novelty_z,
            "meaning": "z between low_z and high_z is within the person's own normal"}
    return {"series": series, "weekly": weeks, "episodes": episodes, "actions": actions,
            "rounds": rounds, "band": band}


def clinician_detail(mind, repo: PatientRepo) -> dict:
    line = clinician_line(mind, repo)
    view = mind.build_view(repo)
    rows, _ = mind.evidence(repo)
    patient = repo.patient()
    share = bool(patient.get("share_notes"))
    lessons = repo.lessons_doc().get("lessons", [])
    refusals = list_audit(mind.store, repo.clinic_id, repo.patient_id, outcome="refused", limit=50)
    return {
        **line,
        "share_notes": share,
        "allow_outside_processing": bool(patient.get("allow_outside_processing")),
        "timeline": [{"date": s["date"], "z": s["z"], "movement_z": s["movement_z"],
                      "low": s["movement_z"] is not None and s["movement_z"] <= view.th.low_day_z}
                     for s in view.series],
        "attention_items": [{k: i.get(k) for k in ("id", "kind", "state", "level", "peak_level",
                                                   "since", "opened_at", "closed_at",
                                                   "close_reason", "reason", "detail", "history")}
                            for i in view.items],
        "suggestions": [{k: s.get(k) for k in ("id", "action", "text", "wording", "date",
                                               "created_at", "status", "answer", "felt",
                                               "attention_kind", "ranked", "round_completed")}
                        for s in view.suggestions],
        "lessons": [{**{k: x.get(k) for k in ("id", "text", "action", "effect", "context",
                                              "config_id", "status", "rationale_code",
                                              "evidence_ids", "evidence_count", "source",
                                              "review_id", "created_at", "expires_at",
                                              "end_reason")},
                     "provenance": {"review_id": x["review_id"], "model": x["source"],
                                    "evidence_ids": x["evidence_ids"]}} for x in lessons],
        "questions": repo.questions(),
        "reviews": repo.reviews()[-10:],
        "notes": [{"id": n["id"], "at": n["at"],
                   "classification": {k: n["classification"][k]
                                      for k in ("mood", "topic", "crisis", "asks_for_help", "model")},
                   **({"text": n["text"]} if share else {})} for n in repo.notes()],
        "refusal_log": refusals,
        "draft_wording": {"help_block_reviewed_by_clinician": help_block(mind.settings)["reviewed_by_clinician"],
                          "note_lexicon_reviewed_by_clinician": lexicon_reviewed()},
        "progress": progress(mind, repo, view, rows),
    }


def clinician_round(repo: PatientRepo, round_id: str, mind=None) -> dict | None:
    r = repo.get(f"rounds/{round_id}.json")
    if r is None:
        return None
    out = {k: r.get(k) for k in ("id", "started_at", "duration_s", "mode", "completed",
                                 "ended_by", "config", "tracking", "lights", "path", "quality",
                                 "quality_reasons", "features", "turning", "z", "energy",
                                 "energy_bucket", "analysis", "example", "suggestion_id")}
    # The usual round of the same mode (the one the movement reading compares
    # with), so the page can draw the two trails side by side.
    usual = mind.usual_round(repo, r) if mind is not None else None
    out["usual_round"] = None if usual is None else {
        k: usual.get(k) for k in ("id", "started_at", "mode", "path", "energy_bucket", "example")}
    return out
