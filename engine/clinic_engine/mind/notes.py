"""Free text from the patient (a note, or typed words in a check-in),
handled as untrusted data. Both go through exactly this code.

Processing is classification only:
  A. code: a multilingual lexicon check (data/note_lexicon.json)
  B. level-1 model through the gates: returns enums, or is refused

Crisis rule (team decision): ONLY help-seeking or self-harm language opens
the help screen.
  - a hit in the lexicon's "help_seeking" group ALWAYS gives crisis = true,
    whatever the model says, and also when the model is down or refused;
  - a model label asks_for_help = true also gives crisis = true;
  - "low_mood" words alone, or an unclear/refused model answer on a note with
    no help-seeking hit, give crisis = false. They still set mood = "low" and
    so count as evidence for the clinician's attention items (low_notes).

With CHAT_MODE=fixed (default) the reply is never generated text: code picks
a vetted template; the model may at most choose between the templates code
allows for that case. With CHAT_MODE=gemini, a note that did not open the
help screen may get a reply written by Gemini instead (service.chat_reply,
checked by OutputGate.chat); this template stays the fallback.
"""

from __future__ import annotations

import json
import re
import unicodedata
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

LEXICON_PATH = Path(__file__).resolve().parent.parent / "data" / "note_lexicon.json"

# Vetted replies, in Lanvi's voice: the "replies" set of data/lanvi_lines.json.
# Short, warm, non-clinical. No advice beyond the catalog action or the help block.
def reply_templates() -> dict[str, str]:
    from .lines import reply_templates as _r
    return _r()


REPLY_TEMPLATES = reply_templates()


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
    for group in ("help_seeking", "low_mood"):
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
    return LexiconHit(help=any(p.search(norm) for p in pats["help_seeking"]),
                      low=any(p.search(norm) for p in pats["low_mood"]))


def merge(lex: LexiconHit, model: dict | None) -> dict:
    """Combine lexicon and model into enums only. `model` is None when the
    model was unreachable or its answer was refused by the output gate."""
    asks_for_help = bool(lex.help or (model and model.get("asks_for_help")))
    # Only help-seeking language opens the help screen. Low-mood words and an
    # unclear or missing model answer never do on their own.
    crisis = asks_for_help
    if model is not None and model.get("mood") != "unclear":
        mood = model["mood"]
    else:
        mood = "low" if lex.low or lex.help else "unclear"
    topic = model["topic"] if model else "unclear"
    allowed = templates_for(mood, crisis)
    pick = model.get("reply_template") if model else None
    template_id = pick if pick in allowed else allowed[0]
    return {"mood": mood, "topic": topic, "crisis": crisis,
            "asks_for_help": asks_for_help,
            "lexicon_help": lex.help, "lexicon_low": lex.low,
            "template_id": template_id}
