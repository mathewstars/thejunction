"""The ONLY module that sends anything to a host outside the private network.

Two kinds of outbound data exist:
- level-2 review packs to Gemini (OUTREACH_MODE=gemini, default off)
- "needs review" messages to a clinic Telegram chat (NOTIFY_MODE=telegram, default off)

Rules enforced here, in code:
- a host allowlist per purpose, https only
- the level-2 pack is checked again by InputGate.check_outbound right before
  sending (the anonymizer itself is InputGate in mind/gates.py); the frame
  reading, the only pack with face frames, by InputGate.check_frames_pack
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
        self.recorder = None  # set by the app: keeps the raw exchange for the clinician

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
    def standin(self) -> bool:
        """Level 2 answered by the local model, to exercise the whole level-2 path
        (consent, anonymous pack, outbound check, output gate) before a Gemini key exists.
        Nothing leaves the private network in this mode."""
        s = self.settings
        return s.outreach_mode == "standin" and bool(s.local_llm_base_url and s.local_llm_model)

    @property
    def level2_model(self) -> str:
        if self.standin:
            return f"stand-in: {self.settings.local_llm_model}"
        return self.settings.gemini_model if self.gemini_on else "off"

    @property
    def gemini_on(self) -> bool:
        """True when level 2 can answer (Gemini, or the local stand-in)."""
        s = self.settings
        return self.standin or (s.outreach_mode == "gemini" and bool(s.gemini_api_key and s.gemini_model))

    async def gemini_complete(self, pack: Pack) -> str | None:
        if not self.gemini_on or pack.level != 2:
            return None
        import time
        out, t0 = None, time.monotonic()
        try:
            out = await self._level2(pack)
            return out
        finally:
            if self.recorder is not None:
                self.recorder(pack, out, (time.monotonic() - t0) * 1000, self.level2_model, 2)

    async def _level2(self, pack: Pack) -> str | None:
        # The frame reading sends a long stream and the model thinks before it
        # answers: it gets its own output limit and timeout; other tasks keep theirs.
        frames = pack.task == "frames_reading"
        max_tokens = self.settings.gemini_frames_max_tokens if frames else None
        timeout = self.settings.gemini_frames_timeout_s if frames else self.settings.gemini_timeout_s
        try:
            if pack.task == "reading":
                INPUT_GATE.check_reading_outbound(pack.payload)
            elif pack.task == "session_reading":
                INPUT_GATE.check_session_outbound(pack.payload)
            elif pack.task == "frames_reading":
                INPUT_GATE.check_frames_pack(pack)  # the only pack that carries frames
            else:
                INPUT_GATE.check_outbound(pack.payload)
            if self.standin:
                if pack.images:
                    return None  # the stand-in reads numbers only
                from .llm.local import LocalModel
                return await LocalModel(self.settings, transport=self.transport).complete(
                    Pack(1, pack.task, pack.messages, pack.payload, pack.ref_map),
                    json_mode=True, max_tokens=max_tokens or 1500)
            url, headers, body = gemini.build_request(self.settings, pack,
                                                      max_output_tokens=max_tokens or 4000)
            data = await self._post("gemini", url, body, headers, timeout)
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
