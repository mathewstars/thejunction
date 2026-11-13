"""Where one patient's memory lives in the store. Every key is tenant-scoped:
clinics/{clinic_id}/patients/{patient_id}/...
"""

from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

from ..store import Store


class PatientRepo:
    def __init__(self, store: Store, clinic_id: str, patient_id: str) -> None:
        self.store = store
        self.clinic_id = clinic_id
        self.patient_id = patient_id
        self.p = f"clinics/{clinic_id}/patients/{patient_id}/"

    # ---- record ------------------------------------------------------------
    def patient(self) -> dict | None:
        return self.store.get(self.p + "patient.json")

    def tz(self) -> ZoneInfo:
        rec = self.patient() or {}
        return ZoneInfo(rec.get("timezone") or "UTC")

    def local(self, now: datetime) -> datetime:
        return now.astimezone(self.tz())

    # ---- generic helpers -----------------------------------------------------
    def get(self, rel: str) -> dict | None:
        return self.store.get(self.p + rel)

    def put(self, rel: str, doc: dict) -> None:
        self.store.put(self.p + rel, doc)

    def delete(self, rel: str) -> None:
        self.store.delete(self.p + rel)

    def docs(self, folder: str) -> list[dict]:
        return self.store.list_docs(self.p + folder + "/")

    # ---- typed accessors -------------------------------------------------------
    def days(self) -> dict[str, dict]:
        return {d["date"]: d for d in self.docs("days")}

    def suggestions(self) -> list[dict]:
        return sorted(self.docs("suggestions"), key=lambda s: s["created_at"])

    def items(self) -> list[dict]:
        return sorted(self.docs("attention"), key=lambda i: i["opened_at"])

    def oddities(self) -> list[dict]:
        return sorted(self.docs("rejected"), key=lambda o: o["at"])

    def notes(self) -> list[dict]:
        return sorted(self.docs("notes"), key=lambda n: n["at"])

    def note_classes(self) -> list[dict]:
        """Note classifications for the mind: enums and time only, never text."""
        return [{"at": n["at"], **{k: n["classification"][k]
                                    for k in ("mood", "topic", "crisis", "asks_for_help")}}
                for n in self.notes()]

    def rounds(self) -> list[dict]:
        return sorted(self.docs("rounds"), key=lambda r: r["started_at"])

    def feedback(self) -> list[dict]:
        return sorted(self.docs("feedback"), key=lambda f: f["received_at"])

    def rules(self) -> list[dict]:
        return (self.get("mind/rules.json") or {}).get("rules", [])

    def lessons_doc(self) -> dict:
        return self.get("mind/lessons.json") or {"lessons": []}

    def questions(self) -> list[dict]:
        return (self.get("mind/questions.json") or {}).get("questions", [])

    def reviews(self) -> list[dict]:
        return sorted(self.docs("mind/reviews"), key=lambda r: r["at"])

    def state(self) -> dict:
        return self.get("mind/state.json") or {}

    def save_state(self, st: dict) -> None:
        self.put("mind/state.json", st)
