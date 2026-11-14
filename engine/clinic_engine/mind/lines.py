"""Lanvi's lines: the fixed sets in data/lanvi_lines.json and the check-in
catalog in data/checkin_catalog.json.

Code picks a line; a model may at most choose among the ids code offers,
through the output gate. Nothing generated is ever shown to the person,
except Lanvi's reply to a note when CHAT_MODE=gemini (see service.chat_reply).
"""

from __future__ import annotations

import hashlib
import json
from functools import lru_cache
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "data"
LINES_PATH = DATA / "lanvi_lines.json"
CHECKIN_PATH = DATA / "checkin_catalog.json"


@lru_cache(maxsize=2)
def lines(path: str = str(LINES_PATH)) -> dict:
    return json.loads(Path(path).read_text("utf-8"))


@lru_cache(maxsize=2)
def checkin_catalog(path: str = str(CHECKIN_PATH)) -> dict:
    return json.loads(Path(path).read_text("utf-8"))


def good_thing_ids() -> list[str]:
    return [x["id"] for x in checkin_catalog()["good_things"]]


def plan_ids() -> list[str]:
    return [x["id"] for x in checkin_catalog()["plans"]]


def label(kind: str, item_id: str) -> str:
    for x in checkin_catalog()[kind]:
        if x["id"] == item_id:
            return x["label"]
    return item_id


def suggestion_lines(action: str) -> list[dict]:
    return list(lines()["suggestions"].get(action, []))


def suggestion_template(action: str) -> str:
    """The first line for an action: the fallback when no model chooses."""
    return suggestion_lines(action)[0]["text"]


def line_text(line_id: str) -> str | None:
    for group in ("suggestions",):
        for items in lines()[group].values():
            for x in items:
                if x["id"] == line_id:
                    return x["text"]
    for group in ("welcome_back", "hello", "away", "back"):
        for x in lines()[group]:
            if x["id"] == line_id:
                return x["text"]
    return None


def reply_templates() -> dict[str, str]:
    return dict(lines()["replies"])


def after_activity(template_id: str) -> dict:
    return {"template_id": template_id, "text": lines()["after_activity"][template_id]}


def pick(group: str, key: str) -> dict:
    """A stable choice from a set: the same key gives the same line."""
    items = lines()[group]
    i = int(hashlib.sha256(key.encode()).hexdigest()[:8], 16) % len(items)
    return {"template_id": items[i]["id"], "text": items[i]["text"]}


def story(story_id: str) -> dict | None:
    for s in lines()["stories"]:
        if s["id"] == story_id:
            return {"id": s["id"], "text": s["text"], "question": s["question"],
                    "answers": [{"id": k, "text": v} for k, v in sorted(s["answers"].items())]}
    return None


def story_ids() -> list[str]:
    return [s["id"] for s in lines()["stories"]]


def preference_ack(first: str | None) -> dict:
    key = first or "none"
    return {"template_id": "preferences." + key, "text": lines()["preferences_ack"][key]}
