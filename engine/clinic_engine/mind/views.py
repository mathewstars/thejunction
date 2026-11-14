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
from . import lanvi_config, lines, xp
from .activities import played_to_the_end
from .catalog import ACTIONS, ACTIVITY_ACTION, plain_name
from .repo import PatientRepo
from .round_configs import ROUND_DURATION_S
from .rounds import pick_round_config
from .baseline import baseline_for
from .thresholds import METRICS, T
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
        "lanvi": lanvi_block(repo, view, sug),
        "round_config": cfg,
        "attention": PATIENT_SUMMARY[status],
        "crisis": help_block(settings),
        "product_name": settings.product_name,
    }


def lanvi_line(view: View, st: dict, sug: dict | None, key: str) -> dict:
    """The one line Lanvi says today. Never guilt, never about mood or the face."""
    w = st["wandering"]["state"]
    if w == "back":
        return lines.pick("back", key)
    today = view.today.isoformat()
    before = [c for c in view.contacts if c < today]
    if today not in view.contacts and before and \
            (view.today - date.fromisoformat(max(before))).days >= lanvi_config.WELCOME_BACK_AFTER_DAYS:
        return lines.pick("welcome_back", key)
    if w == "away":
        return lines.pick("away", key)
    if sug is not None:
        return {"template_id": sug.get("line_id") or "suggestion", "text": sug["text"]}
    return lines.pick("hello", key)


def plan_to_ask(repo: PatientRepo, view: View) -> dict | None:
    """Yesterday's (or the last earlier) plan, unless today's check-in answered it."""
    checkins = view.of_type("checkin")
    tz = repo.tz()
    day = lambda a: datetime.fromisoformat(a["started_at"]).astimezone(tz).date()  # noqa: E731
    earlier = [a for a in checkins if day(a) < view.today and a.get("plan")]
    if not earlier:
        return None
    last = earlier[-1]
    answered = [a for a in checkins if a["started_at"] > last["started_at"]
                and a.get("plan_done") in ("yes", "no")]
    if answered or (view.today - day(last)).days > 2:
        return None
    return {"checkin_id": last["id"], "plan_id": (last["plan"] or {}).get("catalog_id")}


def lanvi_block(repo: PatientRepo, view: View, sug: dict | None) -> dict:
    st = xp.load(repo)
    return {**xp.facts(st), "wandering": xp.wandering_out(st),
            "line": lanvi_line(view, st, sug, repo.patient_id + view.today.isoformat()),
            "plan_to_ask": plan_to_ask(repo, view)}


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
        parts.append(f"Last suggestion: {plain_name(last['action'])}, "
                     f"answer: {last['answer'].replace('_', ' ')}.")
    return " ".join(parts)


REASON_SHORT = {
    "deviation": "Movement down {n} days", "silence": "No data {n} days",
    "asked_for_help": "Asked for help", "novelty": "One unusual day", "oddity": "Odd values sent",
    "ignored": "Suggestions left unanswered", "low_notes": "Low mood in notes",
    "weak_rounds": "Weak rounds", "round_mismatch": "Rounds and days disagree",
    "fading": "Slowing within rounds", "stopped_early": "Rounds stopped early",
    "not_played": "Activities offered, not played", "slower_reactions": "Slower reactions",
    "face_flat": "Less facial movement", "checkins_stopped": "Check-ins stopped",
    "plans_not_done": "Plans not done", "model_noticed": "Noticed by the model, confirmed",
    "within": "Within own normal", "no_baseline": "Learning own normal",
    "no_data": "No data {n} days", "no_data_never": "No data yet", "outside": "Movement down {n} days",
}
# Which held kind names the row first, at the same level.
_KIND_ORDER = ("asked_for_help", "deviation", "silence", "novelty", "slower_reactions", "face_flat",
               "checkins_stopped", "plans_not_done", "model_noticed", "not_played", "ignored",
               "low_notes",
               "oddity", "weak_rounds", "round_mismatch", "fading", "stopped_early")


def reason_short(view: View, status: str, items: list[dict]) -> str:
    """At most 6 words, chosen by code from REASON_SHORT. No sentences."""
    last = max((date.fromisoformat(d) for d in view.days
                if date.fromisoformat(d) <= view.today), default=None)
    def fill(key: str) -> str:
        if key in ("deviation", "outside"):
            _, lows = deviation_now(view)
            return REASON_SHORT[key].format(n=max(len(lows), 1))
        if key in ("silence", "no_data"):
            if last is None:
                return REASON_SHORT["no_data_never"]
            return REASON_SHORT[key].format(n=(view.today - last).days)
        return REASON_SHORT[key]
    if items:
        top = max(LEVELS.index(i["level"]) for i in items)
        kinds = [i["kind"] for i in items if LEVELS.index(i["level"]) == top]
        kinds.sort(key=lambda k: _KIND_ORDER.index(k) if k in _KIND_ORDER else 99)
        if kinds[0] in REASON_SHORT:
            return fill(kinds[0])
    return fill(status)


def spark(view: View, days: int = 28) -> list[float | None]:
    """The main movement z per day for the last `days` days; None when missing."""
    by = {s["date"]: s["movement_z"] for s in view.series}
    return [by.get((view.today - timedelta(days=k)).isoformat()) for k in range(days - 1, -1, -1)]


def clinician_line(mind, repo: PatientRepo) -> dict:
    repo = repo.snapshot()  # read each record once while building this answer
    return _clinician_line(mind, repo)


def _lowered_by_rule(mind, repo: PatientRepo, items: list[dict]) -> int:
    if not mind.triage_on:
        return 0
    levels = (repo.get("mind/triage.json") or {}).get("levels") or {}
    return sum(1 for i in items if (levels.get(i["id"]) or {}).get("clinic_rule_id")
               and i.get("level_source") == "models"
               and LEVELS.index(i["level"]) < LEVELS.index(i.get("rules_level", i["level"])))


def _clinician_line(mind, repo: PatientRepo) -> dict:
    view = mind.build_view(repo)
    status = compute_status(view)
    items = [i for i in view.items if i["state"] == "open"]
    patient = repo.patient()
    top = max((LEVELS.index(i["level"]) for i in items), default=-1)
    return {
        "since": min((i["since"] for i in items), default=None),
        "reason_short": reason_short(view, status, items),
        "spark": spark(view),
        "patient_id": repo.patient_id, "label": patient["label"],
        "display_name": patient.get("display_name"),
        "example": bool(patient.get("example")), "test_play": bool(patient.get("test_play")),
        "status": status,
        "level": LEVELS[top] if top >= 0 else None,
        "attention": [{"id": i["id"], "kind": i["kind"], "level": i["level"], "since": i["since"]}
                      for i in items],
        # Flags whose level a clinic rule holds below what the fixed rules say.
        "lowered_by_clinic_rule": _lowered_by_rule(mind, repo, items),
        "last_data_day": max(view.days) if view.days else None,
        "summary": _summary(view, status, items),
    }


def progress(mind, repo: PatientRepo, view: View, rows: list[dict]) -> dict:
    """Derived data a dashboard can chart directly."""
    series = [{"date": s["date"], "z": s["z"], "movement_z": s["movement_z"],
               "example": s["example"],
               "values": {m: view.days.get(s["date"], {}).get(m) for m in METRICS
                          if view.days.get(s["date"], {}).get(m) is not None}}
              for s in view.series]
    base = baseline_for(view.days, view.today, view.th)
    usual = {m: round(b["median"], 2) for m, b in base.items()}
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
                           "completed": bool(r.get("completed")),
                           "after_suggestion": bool(r.get("suggestion_id")),
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
    return {"today": view.today.isoformat(), "series": series, "usual": usual,
            "weekly": weeks, "episodes": episodes, "actions": actions,
            "rounds": rounds, "band": band}


def _reply_line(note: dict) -> str | None:
    """What Lanvi answered a note with: the model-written reply when there is one
    (CHAT_MODE=gemini, marked by _reply_by), else the fixed line."""
    written = note.get("reply") or {}
    if written.get("text"):
        return written["text"]
    from .lines import reply_templates
    return reply_templates().get((note.get("classification") or {}).get("template_id"))


def _reply_by(note: dict) -> str:
    """"model" when Gemini wrote Lanvi's reply (checked by code), else "fixed"."""
    return "model" if (note.get("reply") or {}).get("text") else "fixed"


def clinician_detail(mind, repo: PatientRepo) -> dict:
    repo = repo.snapshot()  # read each record once while building this answer
    line = _clinician_line(mind, repo)
    view = mind.build_view(repo)
    rows, _ = mind.evidence(repo)
    patient = repo.patient()
    share = bool(patient.get("share_notes"))
    lessons = repo.lessons_doc().get("lessons", [])
    refusals = list_audit(mind.store, repo.clinic_id, repo.patient_id, outcome="refused", limit=50)
    # Notifier sends and suppressions (both outcomes), for the safety log.
    notify_log = [e for e in list_audit(mind.store, repo.clinic_id, repo.patient_id, limit=400)
                  if e.get("action") == "notify_urgent"][:50]
    return {
        **line,
        "share_notes": share,
        "family_contact": patient.get("family_contact"),
        "chat_mode": mind.settings.chat_mode,
        "allow_outside_processing": bool(patient.get("allow_outside_processing")),
        "timeline": [{"date": s["date"], "z": s["z"], "movement_z": s["movement_z"],
                      "low": s["movement_z"] is not None and s["movement_z"] <= view.th.low_day_z}
                     for s in view.series],
        "attention_items": [{k: i.get(k) for k in ("id", "kind", "state", "level", "peak_level",
                                                   "since", "opened_at", "closed_at",
                                                   "close_reason", "reason", "detail", "history",
                                                   "rules_level", "level_source")}
                            for i in view.items],
        # Who sets the levels ("rules" or "models") and, with models, what each
        # of the two model levels said per item (codes only).
        # The clinic's own rules for this person (free text; read by the local
        # model in the triage, never sent outside).
        "clinic_rules": [{k: r.get(k) for k in ("id", "text", "at", "by", "expires_at")}
                         for r in mind.clinic_rules(repo)],
        "triage": {"mode": getattr(mind.settings, "triage_mode", "rules"),
                   **{k: (repo.get("mind/triage.json") or {}).get(k)
                      for k in ("status", "at", "models", "levels")}},
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
        "activities": activities_block(mind, repo, view, share),
        "days_reading": days_reading_out(mind, repo),
        "health_types": health_types_out(repo),
        "lanvi": {k: v for k, v in xp.facts(xp.load(repo)).items() if k in ("xp", "stage")},
        "preferences": repo.preferences(),
        "notes": [{"id": n["id"], "at": n["at"], "source": n.get("source", "note"),
                   "classification": {k: n["classification"][k]
                                      for k in ("mood", "topic", "crisis", "asks_for_help", "model")},
                   "reply": _reply_line(n),
                   "reply_by": _reply_by(n),
                   **({"text": n["text"]} if share else {})} for n in repo.notes()],
        "refusal_log": refusals,
        "notify_log": notify_log,
        "rules": [{k: r.get(k) for k in ("id", "type", "params", "created_at")}
                  for r in repo.rules()],
        "draft_wording": {"help_block_reviewed_by_clinician": help_block(mind.settings)["reviewed_by_clinician"],
                          "note_lexicon_reviewed_by_clinician": lexicon_reviewed()},
        "progress": progress(mind, repo, view, rows),
    }


# ---- activities for the clinician: compact and easy to draw ---------------------------------

HEADLINE = {"focus": ("median_reaction_ms", "error_rate"), "breathing": ("time_played_s",),
            "checkin": ("good_things",)}


def _face_out(a: dict) -> dict | None:
    face = a.get("face")
    if not face:
        return None
    from .activities import FACE_FIELDS
    return {**{k: face.get(k) for k in (*FACE_FIELDS, "tracking_quality")},
            "quality": a.get("face_quality"),
            "z": {k: v for k, v in (a.get("face_z") or {}).items()} or None}


def _reading_out(a: dict) -> dict:
    an = a.get("analysis") or {"status": "not_applicable"}
    out = {"status": an["status"]}
    if an["status"] == "ready":
        out.update(read_by=an.get("read_by"), checked_by=an.get("checked_by"), at=an.get("at"),
                   reading=an.get("reading"), dropped=an.get("dropped", []))
    return out


_AGREEMENT_KEYS = ("smiles_reported", "smiles_confirmed", "smiles_corrected", "smiles_matched",
                   "smiles_faint", "smiles_brief", "smiles_inside_long", "smiles_dropped", "smiles_not_in_numbers",
                   "smiles_poor_match", "smiles_missed", "smiles_code",
                   "smile_precision", "smile_recall", "smile_start_error_s",
                   "segments_reported", "segments_confirmed", "blinks_model", "blinks_code",
                   "moments_reported", "moments_agree", "overall_same")


def frames_reading_out(a: dict) -> dict:
    """The frame reading for the clinician: what the model reported, as code
    confirmed, corrected or dropped it; the faint smiles the model found under
    code's fixed onset (the rise is in the numbers); the smiles of code's that
    the model did not report. Counts, times and fixed words only; never the
    frames. The same keys in every state (null or empty until ready)."""
    fr = a.get("frames_reading") or {"status": "not_applicable"}
    ready = fr.get("status") == "ready"
    rd = fr.get("reading") or {}
    ag = fr.get("agreement") or {}
    return {
        "status": fr.get("status", "not_applicable"),
        "reason": fr.get("reason"),
        "read_by": fr.get("read_by"), "model": fr.get("model"),
        "checked_by": fr.get("checked_by"), "at": fr.get("at"),
        "agreement": {k: ag.get(k) for k in _AGREEMENT_KEYS} if ready else None,
        "overall": {k: (rd.get("overall") or {}).get(k) for k in
                    ("expression", "smiling", "gaze", "tracking", "confidence")} if ready else None,
        "overall_checks": rd.get("overall_checks") if ready else None,
        "blinks": rd.get("blinks") if ready else None,
        "smiles": [{k: x.get(k) for k in ("start_s", "end_s", "reaches_eyes", "side", "status",
                                          "corrected", "overlap", "code_start_s", "code_end_s",
                                          "start_error_s", "end_error_s")}
                   for x in rd.get("smiles", [])],
        "faint_smiles": [{k: x.get(k) for k in ("start_s", "end_s", "status", "peak", "rise",
                                                "rest")}
                         for x in rd.get("faint_smiles", [])],
        "missed_smiles": [{k: x.get(k) for k in ("start_s", "end_s")}
                          for x in rd.get("missed_smiles", [])],
        "resting_smile": rd.get("resting_smile") if ready else None,
        "segments": [{k: x.get(k) for k in ("start_s", "end_s", "what", "code_share")}
                     for x in rd.get("segments", [])],
        "moments": [{k: x.get(k) for k in ("at_s", "smiled", "model", "status")}
                    for x in rd.get("moments", [])],
        "dropped": [{k: x.get(k) for k in ("item", "start_s", "end_s", "at_s", "what", "reason")
                     if x.get(k) is not None} for x in fr.get("dropped", [])],
    }


def days_reading_out(mind, repo: PatientRepo) -> dict:
    """The day reading for the clinician: the stretches the model named as code
    confirmed them (the same as one of code's, or the model's alone with the
    change confirmed in the numbers), code's stretches the model did not name,
    the weekly rhythm, and the series that was sent (with the date of its first
    row, which was not sent). The same keys in every state."""
    dr = repo.get("research/days_reading.json") or {}
    state = mind.days_reading_state(repo)
    status = dr.get("status") if dr.get("status") in ("ready", "failed") else state
    ready = status == "ready"
    rd = dr.get("reading") or {}
    return {
        "status": status, "reason": dr.get("reason") if status == "failed" else None,
        "read_by": dr.get("read_by") if dr else None, "model": dr.get("model") if dr else None,
        "checked_by": dr.get("checked_by") if dr else None, "at": dr.get("at") if dr else None,
        "agreement": dr.get("agreement") if ready else None,
        "stretches": rd.get("stretches", []) if ready else [],
        "missed_stretches": rd.get("missed_stretches", []) if ready else [],
        "weekly": rd.get("weekly", []) if ready else [],
        "weekly_missed": rd.get("weekly_missed", {}) if ready else {},
        "gaps": rd.get("gaps", []) if ready else [],
        "overall": rd.get("overall") if ready else None,
        "overall_checks": rd.get("overall_checks") if ready else None,
        "dropped": dr.get("dropped", []) if ready else [],
        "stream": dr.get("stream") if ready else None,
    }


def health_types_out(repo: PatientRepo) -> list[dict]:
    """The HealthKit types stored for this person: counts and the last day only."""
    out = []
    for h in repo.docs("health"):
        days = h.get("days") or {}
        if h.get("type") and days:
            out.append({"type": h["type"], "unit": h.get("unit"), "days": len(days),
                        "first_day": min(days), "last_day": max(days)})
    return sorted(out, key=lambda x: x["type"])


def activities_block(mind, repo: PatientRepo, view: View, share: bool) -> dict:
    tz = repo.tz()
    notes = {n["id"]: n for n in repo.notes()} if share else {}

    def item(ref: dict | None, kind: str) -> dict | None:
        if ref is None:
            return None
        if "catalog_id" in ref:
            return {"catalog_id": ref["catalog_id"], "label": lines.label(kind, ref["catalog_id"])}
        out = {"typed": True}
        if share and ref.get("note_id") in notes:
            out["text"] = notes[ref["note_id"]]["text"]
        return out

    from . import face_fine as FF
    by_type: dict = {}
    for t in ("focus", "breathing", "checkin"):
        sessions = []
        fine_before: list[dict] = []   # this person's earlier fine-movement sessions
        for a in view.of_type(t):
            f = a.get("features") or {}
            s = {"id": a["id"], "started_at": a["started_at"],
                 "date": datetime.fromisoformat(a["started_at"]).astimezone(tz).date().isoformat(),
                 "completed": bool(f.get("completed", a["completed"])), "ended_by": a["ended_by"],
                 "after_suggestion": bool(a.get("suggestion_id")), "example": bool(a.get("example")),
                 "values": {k: f.get(k) for k in HEADLINE[t]},
                 "z": {k: (a.get("z") or {}).get(k) for k in HEADLINE[t]}}
            if t in ("focus", "breathing"):
                s["face"] = _face_out(a)
                # Where the summary came from. For raw sessions: counts only,
                # never the frames (GET .../activities/{id}/face-raw has them).
                s["face_source"] = a.get("face_source") or ("summary" if a.get("face") else None)
                info = a.get("face_raw_info")
                s["raw"] = None if not info else {k: info.get(k) for k in (
                    "rate_hz", "frames", "tracked_share", "channels")}
                s["reading"] = _reading_out(a)
                s["frames_reading"] = frames_reading_out(a)
                # Fine facial movement (research only, docs/face-fine.md): the
                # session's numbers beside this person's own earlier sessions.
                # Shown only; nothing is judged from it. Never the stream.
                s["fine"] = None
                fs, fh = a.get("face_fine"), FF.headline(a.get("face_fine"))
                if fs:
                    s["fine"] = {**(a.get("face_fine_info") or {}), "quality": fs.get("quality"),
                                 "noise_mm": fs.get("noise_mm"), "values": fh,
                                 "usual": FF.usual(fine_before), "earlier": len(fine_before),
                                 "needed": FF.OWN_MIN_SESSIONS, "per_region": fs.get("regions"),
                                 "asymmetry": fs.get("asymmetry")}
                    if fh and fs.get("quality") in ("good", "partly"):
                        fine_before.append(fh)
                if t == "focus":
                    # Revontulet's own measures, as sent (numbers only), or null.
                    s["revontulet"] = a.get("revontulet")
                    # The same game against the person's own earlier Revontulet
                    # games (shown only; it does not judge the day).
                    s["revontulet_own"] = None if not a.get("revontulet_features") else {
                        "values": a["revontulet_features"], "z": a.get("revontulet_z") or {},
                        "usual": a.get("revontulet_usual") or {},
                        "start": a.get("revontulet_start") or {},
                        "start_z": a.get("revontulet_start_z") or {},
                        "earlier_games": a.get("revontulet_baseline_sessions", 0),
                        "earlier_days": a.get("revontulet_baseline_days", 0),
                        "needed_days": T.revontulet_min_days,
                        "needed": T.revontulet_baseline_min, "unusual_z": T.revontulet_unusual_z}
            else:
                s["good_things"] = [item(g, "good_things") for g in a.get("good_things") or []]
                s["plan"] = item(a.get("plan"), "plans")
                s["plan_done"] = a.get("plan_done")
                s["asked_for_help"] = bool(a.get("crisis"))
            sessions.append(s)
        usual = {}
        if sessions:
            last = view.of_type(t)[-1]
            usual = {k: v for k, v in (last.get("usual") or {}).items()
                     if k in HEADLINE[t] or k.startswith("face.")}
        by_type[t] = {"sessions": sessions, "usual": usual}

    def counts(days: int) -> dict:
        cut = (view.today - timedelta(days=days - 1)).isoformat()
        out = {}
        for t, action in ACTIVITY_ACTION.items():
            offered = [s for s in view.suggestions if s["action"] == action and s["date"] >= cut]
            done = [a for a in view.of_type(t) if
                    datetime.fromisoformat(a["started_at"]).astimezone(tz).date().isoformat() >= cut]
            played_for = {a.get("suggestion_id") for a in done}
            out[t] = {"offered": len(offered),
                      "played_when_offered": sum(1 for s in offered if s["id"] in played_for),
                      "played": len(done),
                      "finished": sum(1 for a in done if played_to_the_end(a))}
        return out

    # The two readers over every session the model has read: sums, the two
    # shares for smiles, and how many sessions they cover.
    from .frame_reading import aggregate
    read = [a["frames_reading"]["agreement"] for t in ("focus", "breathing")
            for a in view.of_type(t)
            if (a.get("frames_reading") or {}).get("status") == "ready"
            and a["frames_reading"].get("agreement")]
    return {**by_type, "counts": {"last_7_days": counts(7), "last_28_days": counts(28)},
            "frames_agreement": aggregate(read)}


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
