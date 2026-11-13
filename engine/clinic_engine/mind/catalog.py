"""Fixed catalogs: actions, rule templates, question templates, enums.

The mind can only ever pick from these lists. To add an action, add one
ActionSpec to ACTIONS (and its keywords, so the wording gate can tell actions
apart). Nothing a model says can add to these lists at run time.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ActionSpec:
    id: str
    group: str  # actions in the same group count as "the same action" for the wording gate
    base_rank: int  # lower comes first
    template: str  # the fixed fallback sentence (also the gate's reference)
    keywords: tuple[str, ...]  # words that name this action in a sentence
    numbers: tuple[str, ...] = ()  # numbers the sentence may mention
    seated_ok: bool = False
    round_mode: str | None = None  # standing | seated, when the action is an AR round
    plain_name: str = ""


ACTIONS: dict[str, ActionSpec] = {a.id: a for a in [
    ActionSpec("ar_round", "ar", 0,
               "How about a two-minute round of catching lights in your room?",
               ("catch", "catching", "lights", "round"), ("two", "2"),
               round_mode="standing", plain_name="catching lights"),
    ActionSpec("ar_round_seated", "ar", 1,
               "How about a two-minute round of catching lights from your chair?",
               ("catch", "catching", "lights", "round", "chair", "seated"), ("two", "2"),
               seated_ok=True, round_mode="seated", plain_name="catching lights, seated"),
    ActionSpec("walk_10min", "walk", 2,
               "How about a ten-minute walk, at your own pace?",
               ("walk", "walking", "stroll"), ("ten", "10"), plain_name="a short walk"),
    ActionSpec("daylight_10min", "daylight", 3,
               "How about ten minutes by a window or outside in the daylight?",
               ("daylight", "outside", "outdoors", "sunlight", "window"), ("ten", "10"),
               plain_name="some daylight"),
    ActionSpec("call_someone", "call", 4,
               "How about a short call or message to someone you like?",
               ("call", "phone", "message", "text", "chat"), (), seated_ok=True,
               plain_name="reaching out to someone"),
    ActionSpec("breathing_2min", "breathing", 5,
               "How about two minutes of slow breathing, wherever you are?",
               ("breathing", "breathe", "breath"), ("two", "2"), seated_ok=True,
               plain_name="slow breathing"),
]}

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
    # Lessons about round configs (they carry a config_id).
    "config_finished_more": "prefer",
    "config_stopped_early": "avoid",
}
ROUND_RATIONALES = ("config_finished_more", "config_stopped_early")

# Rule templates the patient can set. Typed parameters, no free text.
RULE_TYPES = ("quiet_hours", "seated_only", "max_suggestions_per_day", "no_action")
WEEKDAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")

# Questions the mind may ask. The model can only pick a code and an action.
QUESTIONS = {
    "prefer_morning": "Does {name} suit you better in the morning?",
    "too_much": "Was {name} too much on some days?",
    "seated_better": "Would catching lights from a chair be easier for you?",
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


CONFIG_NAMES = {"seated_gentle": "gentle seated rounds", "near_gentle": "gentle rounds close by",
                "standard": "standard rounds", "wide": "wide rounds",
                "wide_high": "wide rounds with high lights"}


def lesson_text(action: str, effect: str, context: str, config_id: str | None = None) -> str:
    """Plain-language text for a lesson. Written by code, never by a model."""
    name = CONFIG_NAMES.get(config_id, "") if config_id else ACTIONS[action].plain_name
    when = "" if context == "any" else f" in the {context}"
    if effect == "prefer":
        return f"{name.capitalize()}{when} seemed to suit you, so it comes first now."
    return f"{name.capitalize()}{when} was often not right for you, so it is offered less."
