"""Urgent notifier: one "needs review" message per attention item per level.

"urgent" means a clinician should review this today. It is not an emergency
and not a diagnosis, and the message says only "needs review".

The message may contain ONLY: the product name, the clinic-set patient label,
the level, how long attention has been held, and a link to the clinician
page. No measurements, ids, dates, note text or anything else.

Policy (from config): allowed clinic hours; outside them an urgent message is
queued to the start of the next window (or dropped, if the clinic says so);
a rate limit per hour. Every send and every suppressed send is audited.
A failing notifier never breaks ingest.
"""

from __future__ import annotations

import logging
import time
from collections import deque
from datetime import datetime, timedelta
from typing import Protocol
from zoneinfo import ZoneInfo

from .audit import write_audit
from .config import Settings
from .outreach import Outreach
from .store import Store

log = logging.getLogger("clinic_engine.notify")


class Notifier(Protocol):
    async def send(self, text: str, chat_id: str | None = None) -> bool: ...


class OffNotifier:
    async def send(self, text: str, chat_id: str | None = None) -> bool:
        return False


def family_contacts(settings: Settings) -> dict[str, str]:
    """{name: telegram chat id} from FAMILY_CONTACTS ("Name=chat id;Name=chat id")."""
    out: dict[str, str] = {}
    for part in (settings.family_contacts or "").split(";"):
        name, sep, chat = part.partition("=")
        name, chat = " ".join(name.split()), chat.strip()
        if sep and name and chat and len(name) <= 40:
            out[name] = chat
    return out


def build_family_message(product: str) -> str:
    """What the chosen person gets: no name, no level, no measurement, no link."""
    return f"{product}: someone close to you may appreciate a call or a visit today."


class TelegramNotifier:
    """Telegram Bot API sendMessage, through outreach.py (host allowlist)."""

    def __init__(self, outreach: Outreach):
        self.outreach = outreach

    async def send(self, text: str, chat_id: str | None = None) -> bool:
        return await self.outreach.telegram_send(text, chat_id)


class RecordingNotifier:
    """Fake for tests: records messages, can be told to fail."""

    def __init__(self, fail: bool = False):
        self.messages: list[str] = []
        self.family: list[tuple[str, str]] = []  # (chat id, text) sent to a chosen person
        self.fail = fail

    async def send(self, text: str, chat_id: str | None = None) -> bool:
        if self.fail:
            raise RuntimeError("notifier down")
        if chat_id:
            self.family.append((chat_id, text))
        else:
            self.messages.append(text)
        return True


def make_notifier(settings: Settings, outreach: Outreach) -> Notifier:
    if settings.notify_mode == "telegram":
        return TelegramNotifier(outreach)
    return OffNotifier()


def build_message(product: str, label: str, level: str, held_days: int, link: str) -> str:
    """The only fields allowed in a notification."""
    held = "today" if held_days <= 0 else f"{held_days} day{'s' if held_days != 1 else ''}"
    word = "needs review" if level == "urgent" else f"level {level}"
    msg = f"{product}: {label} {word}. Attention held {held}."
    if link:
        msg += f" {link}"
    return msg


class NotifyPolicy:
    def __init__(self, hours: str, tz: str, queue: bool):
        start, end = hours.split("-")
        self.start, self.end = int(start), int(end)
        self.tz = ZoneInfo(tz)
        self.queue = queue

    def in_window(self, now: datetime) -> bool:
        h = now.astimezone(self.tz).hour
        return self.start <= h < self.end

    def next_window(self, now: datetime) -> datetime:
        local = now.astimezone(self.tz)
        start = local.replace(hour=self.start, minute=0, second=0, microsecond=0)
        if local >= start:
            start += timedelta(days=1)
        return start


class UrgentNotifications:
    def __init__(self, store: Store, settings: Settings, notifier: Notifier):
        self.store = store
        self.settings = settings
        self.notifier = notifier
        self.policy = NotifyPolicy(settings.notify_hours, settings.clinic_timezone,
                                   settings.notify_queue_outside_hours)
        self._sent_times: deque[float] = deque()
        # Set by the mind: records each outcome in the decision trace. Never decides.
        self.trace_hook = None

    def _key(self, clinic_id: str, item_id: str, level: str) -> str:
        return f"clinics/{clinic_id}/notify/{item_id}-{level}.json"

    def _audit(self, now, clinic_id, patient_id, outcome, reason, item_id, level):
        write_audit(self.store, now, clinic_id=clinic_id, patient_id=patient_id, actor="notifier",
                    action="notify_urgent", outcome=outcome, reason=reason,
                    detail={"attention_id": item_id, "level": level,
                            "mode": self.settings.notify_mode})
        if self.trace_hook is not None:
            try:
                self.trace_hook(clinic_id, patient_id, outcome, reason, item_id, level)
            except Exception:  # noqa: BLE001 - the trace never breaks a send
                log.warning("notify trace not recorded")

    async def on_level(self, now: datetime, clinic_id: str, patient: dict, item: dict) -> None:
        """Called when an item first reaches a level. Only urgent is sent."""
        level = item["level"]
        pid = patient["id"]
        if level != "urgent":
            return
        key = self._key(clinic_id, item["id"], level)
        if self.store.get(key):
            self._audit(now, clinic_id, pid, "refused", "duplicate", item["id"], level)
            return
        if not self.policy.in_window(now):
            if self.policy.queue:
                self.store.put(key, {"status": "queued", "patient_id": pid,
                                     "attention_id": item["id"], "level": level,
                                     "send_after": self.policy.next_window(now).isoformat()})
                self._audit(now, clinic_id, pid, "refused", "outside_hours_queued", item["id"], level)
            else:
                self.store.put(key, {"status": "suppressed", "reason": "outside_hours"})
                self._audit(now, clinic_id, pid, "refused", "outside_hours_dropped", item["id"], level)
            return
        await self._send(now, clinic_id, patient, item, key)

    async def flush(self, now: datetime, clinic_id: str, load_patient, load_item) -> None:
        """Send queued messages whose window has opened (called on the tick)."""
        if not self.policy.in_window(now):
            return
        for key in self.store.list(f"clinics/{clinic_id}/notify/"):
            rec = self.store.get(key)
            if not rec or rec.get("status") != "queued":
                continue
            if datetime.fromisoformat(rec["send_after"]) > now:
                continue
            patient, item = load_patient(rec["patient_id"]), load_item(rec["patient_id"], rec["attention_id"])
            if not patient or not item:
                continue
            await self._send(now, clinic_id, patient, item, key)

    async def _family(self, now: datetime, clinic_id: str, patient: dict) -> None:
        """When the clinic has been told, the person the clinic chose for this patient
        (with the patient's agreement) gets one short line too. It says nothing about
        who or why. Never breaks the clinic's message."""
        chat = family_contacts(self.settings).get(patient.get("family_contact") or "")
        if not chat:
            return
        try:
            ok = await self.notifier.send(build_family_message(self.settings.product_name), chat)
        except Exception as exc:  # noqa: BLE001
            log.warning("family notifier failed: %s", type(exc).__name__)
            ok = False
        write_audit(self.store, now, clinic_id=clinic_id, patient_id=patient["id"], actor="mind",
                    action="notify_family", outcome="ok" if ok else "refused",
                    reason="sent" if ok else "send_failed")

    async def _send(self, now: datetime, clinic_id: str, patient: dict, item: dict, key: str) -> None:
        pid, level = patient["id"], item["level"]
        if self.settings.notify_mode == "off":
            self.store.put(key, {"status": "suppressed", "reason": "notify_off"})
            self._audit(now, clinic_id, pid, "refused", "notify_off", item["id"], level)
            return
        mono = time.monotonic()
        while self._sent_times and mono - self._sent_times[0] > 3600:
            self._sent_times.popleft()
        if len(self._sent_times) >= self.settings.notify_max_per_hour:
            self.store.put(key, {"status": "suppressed", "reason": "rate_limited"})
            self._audit(now, clinic_id, pid, "refused", "rate_limited", item["id"], level)
            return
        held = (now.date() - datetime.fromisoformat(item["since"][:10]).date()).days
        text = build_message(self.settings.product_name, patient["label"], level, held,
                             self.settings.clinician_page_url)
        try:
            ok = await self.notifier.send(text)
        except Exception as exc:  # noqa: BLE001 - never break ingest
            log.warning("notifier failed: %s", type(exc).__name__)
            ok = False
        if ok:
            self._sent_times.append(mono)
            self.store.put(key, {"status": "sent", "at": now.isoformat()})
            self._audit(now, clinic_id, pid, "ok", "sent", item["id"], level)
            await self._family(now, clinic_id, patient)
        else:
            self.store.put(key, {"status": "failed", "at": now.isoformat()})
            self._audit(now, clinic_id, pid, "refused", "send_failed", item["id"], level)
