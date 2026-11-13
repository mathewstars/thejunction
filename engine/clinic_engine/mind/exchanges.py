"""The raw exchange with a model: exactly what was sent and exactly what came back.

Kept per patient, next to the trace, so a clinician can open any model step and
read it. The trace itself stays codes and numbers only; this is the one place
that holds the full prompt. A note's prompt contains the patient's words, so
`view()` hides that message unless the patient shares their notes.
"""

from __future__ import annotations

from ..store import Store
from ..security import new_id
from . import trace as trace_mod

MAX_REPLY = 20000
PATIENT_WORD_TASKS = ("note",)
HIDDEN = "[the patient's words are not shared with the clinic]"


def folder(clinic_id: str, patient_id: str) -> str:
    return f"clinics/{clinic_id}/patients/{patient_id}/exchanges/"


class Recorder:
    def __init__(self, store: Store, clock):
        self.store = store
        self.clock = clock

    def __call__(self, pack, raw: str | None, ms: int, model: str, level: int) -> None:
        """Called by a model client after every call. Never raises."""
        try:
            ch = trace_mod._current.get()
            if ch is None:
                return
            doc = {"id": new_id("ex"), "at": self.clock.now().isoformat(), "chain_id": ch.id,
                   "level": level, "task": pack.task, "model": model, "ms": int(ms),
                   "messages": [{"role": str(m.get("role")), "content": str(m.get("content"))}
                                for m in pack.messages],
                   "pictures": len(getattr(pack, "images", []) or []),
                   "reply": None if raw is None else str(raw)[:MAX_REPLY]}
            self.store.put(folder(ch.clinic_id, ch.patient_id) + doc["id"] + ".json", doc)
        except Exception:  # noqa: BLE001 - recording must never break a model step
            pass


def view(store: Store, clinic_id: str, patient_id: str, share_notes: bool,
         limit: int = 50, task: str | None = None, chain_id: str | None = None) -> list[dict]:
    docs = store.list_docs(folder(clinic_id, patient_id))
    docs = [d for d in docs if (task is None or d.get("task") == task)
            and (chain_id is None or d.get("chain_id") == chain_id)]
    docs.sort(key=lambda d: d.get("at", ""), reverse=True)
    out = []
    for d in docs[:limit]:
        hide = d.get("task") in PATIENT_WORD_TASKS and not share_notes
        out.append({**d, "words_hidden": hide,
                    "messages": [{"role": m["role"],
                                  "content": HIDDEN if hide and m["role"] == "user" else m["content"]}
                                 for m in d.get("messages", [])]})
    return out
