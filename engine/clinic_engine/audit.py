"""Audit log: one object per event (object stores cannot append).

Every write and every refusal is recorded. Audit details hold codes, ids and
counts only: never request bodies, never the patient's note text.
"""

from __future__ import annotations

import secrets
from datetime import datetime

from .store import Store

# Detail keys that may never be written to the audit log.
_FORBIDDEN_DETAIL_KEYS = {"text", "note", "body", "password", "token", "pairing_code", "content"}


def audit_prefix(clinic_id: str | None, patient_id: str | None = None) -> str:
    if clinic_id and patient_id:
        return f"clinics/{clinic_id}/patients/{patient_id}/audit/"
    if clinic_id:
        return f"clinics/{clinic_id}/audit/"
    return "audit/"


def write_audit(store: Store, now: datetime, *, clinic_id: str | None, patient_id: str | None,
                actor: str, action: str, outcome: str = "ok", reason: str | None = None,
                detail: dict | None = None, request_id: str | None = None) -> dict:
    assert outcome in ("ok", "refused")
    clean = {k: v for k, v in (detail or {}).items() if k not in _FORBIDDEN_DETAIL_KEYS}
    ev_id = secrets.token_hex(6)
    ts = now.strftime("%Y%m%dT%H%M%S%f")
    ev = {"id": ev_id, "at": now.isoformat(), "actor": actor, "action": action,
          "outcome": outcome, "reason": reason, "detail": clean, "request_id": request_id}
    store.put(f"{audit_prefix(clinic_id, patient_id)}{ts}-{ev_id}.json", ev)
    return ev


def list_audit(store: Store, clinic_id: str | None, patient_id: str | None = None,
               outcome: str | None = None, limit: int = 200) -> list[dict]:
    keys = store.list(audit_prefix(clinic_id, patient_id))[-limit * 4:]
    out = []
    for k in reversed(keys):
        ev = store.get(k)
        if ev and (outcome is None or ev.get("outcome") == outcome):
            out.append(ev)
            if len(out) >= limit:
                break
    return out
