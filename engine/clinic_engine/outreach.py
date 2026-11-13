"""The ONLY module that sends anything to a host outside the private network.

Two kinds of outbound data exist:
- level-2 review packs to Gemini (OUTREACH_MODE=gemini, default off)
- "needs review" messages to a clinic Telegram chat (NOTIFY_MODE=telegram, default off)

Rules enforced here, in code:
- a host allowlist per purpose, https only
- the level-2 pack is checked again by InputGate.check_outbound right before
  sending (the anonymizer itself is InputGate in mind/gates.py)
- a notification text is built by notify.build_message from an allowlist of
  four fields and checked again here
- timeouts everywhere, and no exception ever leaves this module
"""

from __future__ import annotations

import logging
import re
from urllib.parse import urlsplit

import httpx

from .config import Settings
from .llm import gemini
from .mind.gates import INPUT_GATE, GateError, Pack

log = logging.getLogger("clinic_engine.outreach")

ALLOWED_HOSTS = {
    "gemini": {gemini.GEMINI_HOST},
    "telegram": {"api.telegram.org"},
}


class OutreachRefused(Exception):
    pass


class Outreach:
    def __init__(self, settings: Settings, transport: httpx.AsyncBaseTransport | None = None):
        self.settings = settings
        self.transport = transport

    def _check_url(self, purpose: str, url: str) -> None:
        parts = urlsplit(url)
        if parts.scheme != "https" or parts.hostname not in ALLOWED_HOSTS.get(purpose, set()):
            raise OutreachRefused(f"host not allowed for {purpose}")

    async def _post(self, purpose: str, url: str, body: dict, headers: dict,
                    timeout: float) -> dict | None:
        self._check_url(purpose, url)
        async with httpx.AsyncClient(timeout=timeout, transport=self.transport,
                                     follow_redirects=False) as c:
            r = await c.post(url, json=body, headers=headers)
            r.raise_for_status()
            return r.json()

    # ---- level 2 -------------------------------------------------------------

    @property
    def gemini_on(self) -> bool:
        s = self.settings
        return s.outreach_mode == "gemini" and bool(s.gemini_api_key and s.gemini_model)

    async def gemini_complete(self, pack: Pack) -> str | None:
        if not self.gemini_on or pack.level != 2:
            return None
        try:
            if pack.task == "reading":
                INPUT_GATE.check_reading_outbound(pack.payload)
            else:
                INPUT_GATE.check_outbound(pack.payload)
            url, headers, body = gemini.build_request(self.settings, pack)
            data = await self._post("gemini", url, body, headers, self.settings.gemini_timeout_s)
            return gemini.parse_response(data or {})
        except GateError:
            raise
        except Exception as exc:  # noqa: BLE001
            log.warning("level 2 unavailable: %s", type(exc).__name__)
            return None

    # ---- notifications ---------------------------------------------------------

    _MSG_OK = re.compile(r"^[\w .,:()/\-]+( https://\S+)?$", re.UNICODE)

    async def telegram_send(self, text: str) -> bool:
        s = self.settings
        if s.notify_mode != "telegram" or not (s.telegram_bot_token and s.telegram_chat_id):
            return False
        if len(text) > 300 or not self._MSG_OK.match(text):
            raise OutreachRefused("message shape not allowed")
        url = f"https://api.telegram.org/bot{s.telegram_bot_token}/sendMessage"
        body = {"chat_id": s.telegram_chat_id, "text": text, "disable_web_page_preview": True}
        data = await self._post("telegram", url, body, {}, 10.0)
        return bool(data and data.get("ok"))
