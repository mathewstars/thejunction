"""Tokens, passwords, scopes, rate limits.

- Tokens are 256-bit random strings. Only their SHA-256 hash is stored, under
  `tokens/{sha256}.json`. The clear token is shown once and never stored.
- Every token has a scope: device (one patient in one clinic), clinician
  (one clinic) or admin.
- Passwords use scrypt from the standard library.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import secrets
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from .store import Store

SCOPES = ("device", "clinician", "admin")
_PAIR_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O, 1/I


def new_id(prefix: str) -> str:
    """Random opaque id, e.g. pat_3f9c1a... (96 bits)."""
    return f"{prefix}_{secrets.token_hex(12)}"


def new_token() -> str:
    return secrets.token_urlsafe(32)  # 256 bits


def sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def new_pairing_code() -> str:
    raw = "".join(secrets.choice(_PAIR_ALPHABET) for _ in range(12))  # ~60 bits
    return f"{raw[0:4]}-{raw[4:8]}-{raw[8:12]}"


def normalize_pairing_code(code: str) -> str:
    raw = "".join(ch for ch in code.upper() if ch.isalnum())
    return f"{raw[0:4]}-{raw[4:8]}-{raw[8:12]}" if len(raw) == 12 else raw


# ---- passwords -------------------------------------------------------------

_SCRYPT = {"n": 2**14, "r": 8, "p": 1, "dklen": 32}


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    dk = hashlib.scrypt(password.encode("utf-8"), salt=salt, **_SCRYPT)
    return "scrypt$" + base64.b64encode(salt).decode() + "$" + base64.b64encode(dk).decode()


def verify_password(password: str, stored: str) -> bool:
    try:
        _algo, salt_b64, dk_b64 = stored.split("$")
        salt = base64.b64decode(salt_b64)
        expected = base64.b64decode(dk_b64)
    except ValueError:
        return False
    dk = hashlib.scrypt(password.encode("utf-8"), salt=salt, **_SCRYPT)
    return hmac.compare_digest(dk, expected)


# A fixed hash so that an unknown username costs the same time as a wrong password.
_DUMMY_HASH = hash_password(secrets.token_hex(16))


def dummy_verify(password: str) -> None:
    verify_password(password, _DUMMY_HASH)


# ---- principals and tokens -------------------------------------------------

@dataclass(frozen=True)
class Principal:
    scope: str
    token_hash: str
    clinic_id: str | None = None
    patient_id: str | None = None
    device_id: str | None = None
    clinician_id: str | None = None

    @property
    def actor(self) -> str:
        if self.scope == "device":
            return f"device:{self.device_id}"
        if self.scope == "clinician":
            return f"clinician:{self.clinician_id}"
        return "admin"


def issue_token(store: Store, scope: str, *, clinic_id: str | None = None,
                patient_id: str | None = None, device_id: str | None = None,
                clinician_id: str | None = None, ttl: timedelta | None = None,
                now: datetime | None = None) -> str:
    if scope not in SCOPES:
        raise ValueError("bad scope")
    if scope == "device" and not (clinic_id and patient_id and device_id):
        raise ValueError("device token needs clinic, patient and device")
    if scope == "clinician" and not (clinic_id and clinician_id):
        raise ValueError("clinician token needs clinic and clinician")
    token = new_token()
    now = now or datetime.now(timezone.utc)
    h = sha256_hex(token)
    store.put(f"tokens/{h}.json", {
        "hash": h, "scope": scope, "clinic_id": clinic_id, "patient_id": patient_id,
        "device_id": device_id, "clinician_id": clinician_id,
        "created_at": now.isoformat(),
        "expires_at": (now + ttl).isoformat() if ttl else None,
    })
    return token


def resolve_token(store: Store, token: str, now: datetime) -> Principal | None:
    if not token or len(token) > 128:
        return None
    h = sha256_hex(token)
    rec = store.get(f"tokens/{h}.json")
    if not rec or not hmac.compare_digest(rec.get("hash", ""), h):
        return None
    if rec.get("revoked"):
        return None
    exp = rec.get("expires_at")
    if exp and datetime.fromisoformat(exp) <= now:
        return None
    if rec.get("scope") not in SCOPES:
        return None
    return Principal(scope=rec["scope"], token_hash=h, clinic_id=rec.get("clinic_id"),
                     patient_id=rec.get("patient_id"), device_id=rec.get("device_id"),
                     clinician_id=rec.get("clinician_id"))


# ---- rate limit ------------------------------------------------------------

class RateLimiter:
    """In-memory token bucket per key (a token hash, or an IP for open endpoints)."""

    def __init__(self, per_minute: int, burst: int) -> None:
        self.rate = per_minute / 60.0
        self.burst = float(burst)
        self._buckets: dict[str, tuple[float, float]] = {}
        self._lock = threading.Lock()

    def allow(self, key: str, cost: float = 1.0) -> bool:
        now = time.monotonic()
        with self._lock:
            tokens, last = self._buckets.get(key, (self.burst, now))
            tokens = min(self.burst, tokens + (now - last) * self.rate)
            if tokens < cost:
                self._buckets[key] = (tokens, now)
                return False
            self._buckets[key] = (tokens - cost, now)
            if len(self._buckets) > 50_000:  # keep memory bounded
                self._buckets.clear()
            return True
