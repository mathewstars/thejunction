"""The patient note: the one free-text field, handled as untrusted data.

Processing is classification only:
  A. code: a multilingual lexicon check (data/note_lexicon.json)
  B. level-1 model through the gates: returns enums, or is refused

Fail safe: if EITHER says the person asks for help, or the model answer is
refused/unclear on a note the lexicon flags, crisis = true. Over-triggering is
acceptable; missing is not.

The reply is never generated text. Code picks a vetted template; the model
may at most choose between the templates code allows for that case.
"""

from __future__ import annotations

import json
import re
import unicodedata
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

LEXICON_PATH = Path(__file__).resolve().parent.parent / "data" / "note_lexicon.json"

# Vetted replies. Short, warm, non-clinical. No advice beyond the catalog
# action or the help block.
REPLY_TEMPLATES = {
    "help": "Thank you for telling us. You do not have to carry this alone. The help contacts are right here.",
    "low_1": "Thank you for sharing this. Small steps count, and today's idea is here if it helps.",
    "low_2": "Thank you for telling us how today is. Go gently, one small thing at a time.",
    "ok": "Thank you. Good to hear from you.",
    "good": "Thank you, that is good to hear.",
    "neutral": "Thank you for your note. It is saved for you.",
}


def templates_for(mood: str | None, crisis: bool) -> list[str]:
    if crisis:
        return ["help"]
    if mood == "low":
        return ["low_1", "low_2"]
    if mood == "good":
        return ["good", "ok"]
    if mood == "ok":
        return ["ok", "neutral"]
    return ["neutral", "low_1", "low_2", "ok"]


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKD", text.lower().replace("’", "'"))
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    return " ".join(text.split())


@lru_cache(maxsize=4)
def _load(path: str) -> dict[str, list[re.Pattern]]:
    data = json.loads(Path(path).read_text("utf-8"))
    out = {}
    for group in ("help", "low"):
        pats = []
        for words in data[group].values():
            for w in words:
                pats.append(re.compile(r"(?<![a-z0-9])" + re.escape(normalize(w))))
        out[group] = pats
    return out


def lexicon_reviewed(path: Path = LEXICON_PATH) -> bool:
    return bool(json.loads(Path(path).read_text("utf-8")).get("reviewed_by_clinician", False))


@dataclass
class LexiconHit:
    help: bool
    low: bool


def lexicon_check(text: str, path: Path = LEXICON_PATH) -> LexiconHit:
    norm = normalize(text)
    pats = _load(str(path))
    return LexiconHit(help=any(p.search(norm) for p in pats["help"]),
                      low=any(p.search(norm) for p in pats["low"]))


def merge(lex: LexiconHit, model: dict | None) -> dict:
    """Combine lexicon and model into enums only. `model` is None when the
    model was unreachable or its answer was refused by the output gate."""
    model_unclear = model is None or model.get("mood") == "unclear"
    crisis = bool(lex.help or (model and model.get("asks_for_help"))
                  or ((lex.low or lex.help) and model_unclear))
    if model is not None and model.get("mood") != "unclear":
        mood = model["mood"]
    else:
        mood = "low" if lex.low or lex.help else "unclear"
    topic = model["topic"] if model else "unclear"
    allowed = templates_for(mood, crisis)
    pick = model.get("reply_template") if model else None
    template_id = pick if pick in allowed else allowed[0]
    return {"mood": mood, "topic": topic, "crisis": crisis,
            "asks_for_help": bool(lex.help or (model and model.get("asks_for_help"))),
            "lexicon_help": lex.help, "lexicon_low": lex.low,
            "template_id": template_id}
