"""The help (crisis) block. Always present in GET /v1/today, and in a note
reply when crisis is true. The wording lives in data/help_block.json and is a
DRAFT until a clinician reviews it (reviewed_by_clinician)."""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

from .config import Settings

HELP_PATH = Path(__file__).resolve().parent / "data" / "help_block.json"


@lru_cache(maxsize=2)
def _load(path: str) -> dict:
    return json.loads(Path(path).read_text("utf-8"))


def help_block(settings: Settings) -> dict:
    data = _load(str(HELP_PATH))
    clinic = settings.clinic_contact_label or data["clinic_fallback"]
    if settings.clinic_contact_phone:
        clinic = f"{clinic} ({settings.clinic_contact_phone})"
    contacts = [{"label": "Emergency number", "phone": settings.emergency_number}]
    if settings.clinic_contact_phone:
        contacts.append({"label": settings.clinic_contact_label or "Your clinic",
                         "phone": settings.clinic_contact_phone})
    return {"text": data["text"].format(product=settings.product_name,
                                        emergency_number=settings.emergency_number, clinic=clinic),
            "contacts": contacts,
            "reviewed_by_clinician": bool(data.get("reviewed_by_clinician", False))}
