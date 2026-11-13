"""Respond: code picks exactly one action from the catalog.

Order of authority:
1. Patient rules filter the catalog (they always beat lessons).
2. Lessons re-rank what is left. They can never remove an action, add one,
   or leave the list empty.
3. The first action wins. A model may only word it afterwards (see gates.py).
"""

from __future__ import annotations

from datetime import datetime, timedelta

from .catalog import ACTIONS, WEEKDAYS, context_for_hour
from .thresholds import T, Thresholds

LESSON_WEIGHT = 2.5  # one lesson moves an action about two places


def _in_quiet_hours(rule: dict, local: datetime) -> bool:
    start, end = rule["params"]["from"], rule["params"]["to"]
    hm = local.strftime("%H:%M")
    if start <= end:
        return start <= hm < end
    return hm >= start or hm < end  # over midnight, e.g. 22:00-07:00


def allowed_actions(rules: list[dict], local: datetime) -> list[str]:
    """Apply the patient's own rules to the catalog."""
    weekday = WEEKDAYS[local.weekday()]
    acts = list(ACTIONS)
    for r in rules:
        p = r["params"]
        if r["type"] == "no_action":
            acts = [a for a in acts if a != p["action"]]
        elif r["type"] == "seated_only" and weekday in p["weekdays"]:
            acts = [a for a in acts if ACTIONS[a].seated_ok]
    return acts


def rank_actions(rules: list[dict], lessons: list[dict], local: datetime) -> list[str]:
    """Rules filter, lessons re-rank. Returns the ordered list."""
    acts = allowed_actions(rules, local)
    ctx = context_for_hour(local.hour)
    score = {a: float(ACTIONS[a].base_rank) for a in acts}
    for lesson in lessons:
        if lesson.get("status") != "active" or lesson["action"] not in score \
                or lesson.get("config_id"):  # config lessons shape round_config only
            continue
        if lesson["context"] not in ("any", ctx):
            continue
        score[lesson["action"]] += -LESSON_WEIGHT if lesson["effect"] == "prefer" else LESSON_WEIGHT
    return sorted(acts, key=lambda a: (score[a], ACTIONS[a].base_rank))


def blocked_reason(rules: list[dict], suggestions: list[dict], local: datetime,
                   now: datetime, th: Thresholds = T) -> str | None:
    """Why no new suggestion may be made right now, or None."""
    for r in rules:
        if r["type"] == "quiet_hours" and _in_quiet_hours(r, local):
            return "quiet_hours"
    if any(s["status"] == "open" for s in suggestions):
        return "one_open_already"
    today = local.date().isoformat()
    cap = th.max_suggestions_per_day
    for r in rules:
        if r["type"] == "max_suggestions_per_day":
            cap = min(cap, int(r["params"]["n"]))
    if sum(1 for s in suggestions if s["date"] == today) >= cap:
        return "daily_cap"
    if suggestions:
        last = datetime.fromisoformat(suggestions[-1]["created_at"])
        if now - last < timedelta(hours=th.suggestion_cooldown_hours):
            return "cooldown"
    return None


def needs_response(items: list[dict], suggestions: list[dict], today: str,
                   respondable: tuple[str, ...]) -> dict | None:
    """The held item to answer now: one per item per day, plus on escalation."""
    for it in sorted(items, key=lambda i: i["opened_at"]):
        if it["state"] != "open" or it["kind"] not in respondable:
            continue
        if it["kind"] == "novelty" and it.get("detail", {}).get("direction") != "down":
            continue
        answered_today = [s for s in suggestions if it["id"] in s.get("attention_ids", [])
                          and s["date"] == today]
        if not answered_today:
            return it
        if it.get("level_changed_at", "") > max(s["created_at"] for s in answered_today):
            return it  # escalated since the last suggestion
    return None


def pick_action(rules: list[dict], lessons: list[dict], local: datetime) -> str | None:
    ranked = rank_actions(rules, lessons, local)
    return ranked[0] if ranked else None
