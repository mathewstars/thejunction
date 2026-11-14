"""Fixed catalogs: actions, rule templates, question templates, enums.

The mind can only ever pick from these lists. To add an action, add one
ActionSpec to ACTIONS (and its keywords, so the wording gate can tell actions
apart). Nothing a model says can add to these lists at run time.
"""

from __future__ import annotations

from dataclasses import dataclass

from .lines import suggestion_template


@dataclass(frozen=True)
class ActionSpec:
    id: str
    group: str  # actions in the same group count as "the same action" for the wording gate
    base_rank: int  # lower comes first
    template: str  # the fixed fallback sentence (also the gate's reference)
    keywords: tuple[str, ...]  # words that name this action in a sentence
    numbers: tuple[str, ...] = ()  # numbers the sentence may mention
    seated_ok: bool = False
    plain_name: str = ""
    activity: str | None = None  # focus | breathing | checkin, when the action is an activity


ACTIONS: dict[str, ActionSpec] = {a.id: a for a in [
    ActionSpec("breathing", "breathing", 0, suggestion_template("breathing"),
               ("breathe", "breath", "breaths", "breathing"), (), seated_ok=True,
               plain_name="Breathe with Lanvi", activity="breathing"),
    ActionSpec("focus_game", "focus", 1, suggestion_template("focus_game"),
               ("spark", "sparks", "snow", "snowflakes", "game", "revontulet", "ice", "embers",
                "fox"), (), seated_ok=True,
               plain_name="Revontulet", activity="focus"),
    ActionSpec("walk_10min", "walk", 2, suggestion_template("walk_10min"),
               ("walk", "walking", "stroll"), ("ten", "10"), plain_name="a short walk"),
    ActionSpec("daylight_10min", "daylight", 3, suggestion_template("daylight_10min"),
               ("daylight", "outside", "outdoors", "sunlight", "window"), ("ten", "10"),
               plain_name="some daylight"),
    ActionSpec("call_someone", "call", 4, suggestion_template("call_someone"),
               ("call", "phone", "message", "text", "chat"), (), seated_ok=True,
               plain_name="reaching out to someone"),
    ActionSpec("checkin", "checkin", 5, suggestion_template("checkin"),
               ("things", "check", "tonight"), ("three", "3"), seated_ok=True,
               plain_name="the evening check-in", activity="checkin"),
]}

# Activity type (as the app sends it) -> catalog action.
ACTIVITY_ACTION = {a.activity: a.id for a in ACTIONS.values() if a.activity}
ACTIVITY_TYPES = ("focus", "breathing", "checkin")

# Names for actions of the earlier design, so old stored records still read.
# They can never be suggested again.
LEGACY_ACTION_NAMES = {"ar_round": "an AR round (earlier design)",
                       "ar_round_seated": "a seated AR round (earlier design)",
                       "breathing_2min": "slow breathing (earlier design)"}


def plain_name(action: str) -> str:
    if action in ACTIONS:
        return ACTIONS[action].plain_name
    return LEGACY_ACTION_NAMES.get(action, action.replace("_", " "))


CONTEXTS = ("morning", "afternoon", "evening", "any")
EFFECTS = ("prefer", "avoid")

# Why a lesson is claimed. Each code maps to a check that code can recompute.
RATIONALES = {
    "done_and_improved": "prefer",
    "felt_better_after": "prefer",
    "patient_said_yes": "prefer",
    "offered_not_done": "avoid",
    "done_and_worse": "avoid",
    "patient_said_too_much": "avoid",
    # Lessons about activities, from how they went: "breathing in the evening
    # is usually finished", "the focus game is often stopped early".
    "activity_finished_more": "prefer",
    "activity_stopped_early": "avoid",
}
ACTIVITY_RATIONALES = ("activity_finished_more", "activity_stopped_early")

# Rule templates the patient can set. Typed parameters, no free text.
RULE_TYPES = ("quiet_hours", "seated_only", "max_suggestions_per_day", "no_action")
WEEKDAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")

# Questions the mind may ask. The model can only pick a code and an action.
QUESTIONS = {
    "prefer_morning": "Does {name} suit you better in the morning?",
    "too_much": "Was {name} too much on some days?",
    "prefer_evening": "Does {name} suit you better in the evening?",
    "helped": "Did {name} help on the days you tried it?",
}
QUESTION_ANSWERS = ("yes", "no", "not_sure")

FEEDBACK_ANSWERS = ("did_it", "not_today", "something_else")
FELT = ("rough", "ok", "good")


def context_for_hour(hour: int) -> str:
    if 5 <= hour < 12:
        return "morning"
    if 12 <= hour < 18:
        return "afternoon"
    return "evening"


def lesson_text(action: str, effect: str, context: str, config_id: str | None = None) -> str:
    """Plain-language text for a lesson. Written by code, never by a model."""
    name = plain_name(action)
    when = "" if context == "any" else f" in the {context}"
    if effect == "prefer":
        return f"{name[0].upper() + name[1:]}{when} seemed to suit you, so it comes first now."
    return f"{name[0].upper() + name[1:]}{when} was often not right for you, so it is offered less."
