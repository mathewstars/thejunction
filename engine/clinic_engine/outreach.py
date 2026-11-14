"""The ONLY module that sends anything to a host outside the private network.

Three kinds of outbound data exist:
- level-2 review packs to Gemini (OUTREACH_MODE=gemini, default off)
- Lanvi's chat reply (CHAT_MODE=gemini, default fixed): the note the person
  just wrote and today's earlier non-crisis turns, checked by
  InputGate.check_chat_outbound right before sending
- "needs review" messages to a clinic Telegram chat (NOTIFY_MODE=telegram, default off)

Rules enforced here, in code:
- a host allowlist per purpose, https only
- the level-2 pack is checked again by InputGate.check_outbound right before
  sending (the anonymizer itself is InputGate in mind/gates.py); the frame
  reading, the only pack with face frames, by InputGate.check_frames_pack; the
  sensor reading (watch heart data with the game moments) by check_sensors_pack
- a notification text is built by notify.build_message from an allowlist of
  four fields and checked again here
- timeouts everywhere, and no exception ever leaves this module
"""

from __future__ import annotations

import asyncio
import logging
import time
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
        self.last_frames_meta: dict = {}  # the last frame-reading call: codes and counts

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
        out, t0 = None, time.monotonic()
        try:
            out = await self._level2(pack)
            return out
        finally:
            if self.recorder is not None:
                self.recorder(pack, out, (time.monotonic() - t0) * 1000, self.level2_model, 2)

    async def _robust_call(self, url: str, headers: dict, body: dict,
                           timeout: float) -> str | None:
        """One level-2 answer, with the same checked content in every attempt
        (at most four). What it works around:

        - a slow answer: the request asks the model to think little
          (GEMINI_THINKING=low; a reading takes a few seconds instead of half a
          minute and a fraction of the tokens). An empty answer is asked again
          with the model's default thinking;
        - a 400: tried again without the thinking setting, then without the
          response schema (a model that takes neither);
        - a busy or failing service (429, 5xx, a timeout): tried again after a
          growing wait, the second time with GEMINI_FALLBACK_MODEL when set;
        - out of tokens while thinking: tried again with twice the limit.

        Why it stopped, the token counts, the model and the thinking used are
        kept in last_frames_meta (codes and counts only)."""
        level = (self.settings.gemini_thinking or "default").lower()
        if level != "default":
            body = {**body, "generationConfig": {**body["generationConfig"],
                                                 "thinkingConfig": {"thinkingLevel": level}}}
        model, failures, attempts = self.settings.gemini_model, 0, 0
        self.last_frames_meta = {}

        def without(key: str) -> dict:
            return {**body, "generationConfig": {k: v for k, v in body["generationConfig"].items()
                                                 if k != key}}

        while attempts < 4:
            attempts += 1
            config = body["generationConfig"]
            used = {"attempts": attempts, "model": model,
                    "thinking": (config.get("thinkingConfig") or {}).get("thinkingLevel", "default")}
            try:
                data = await self._post("gemini", url, body, headers, timeout) or {}
                text = gemini.parse_response(data)
                self.last_frames_meta = {**gemini.reply_meta(data), **used}
                if text is not None:
                    return text
                if self.last_frames_meta.get("finish") == "MAX_TOKENS":
                    body = {**body, "generationConfig": {
                        **config, "maxOutputTokens": 2 * config["maxOutputTokens"]}}
                elif "thinkingConfig" in config:
                    body = without("thinkingConfig")
                else:
                    failures += 1
            except httpx.HTTPStatusError as exc:
                code = exc.response.status_code
                self.last_frames_meta = {"finish": f"http_{code}", **used}
                if code == 400 and "thinkingConfig" in config:
                    body = without("thinkingConfig")
                    continue
                if code == 400 and "responseSchema" in config:
                    body = without("responseSchema")
                    continue
                if not (code == 429 or code >= 500):
                    raise
                failures += 1
            except httpx.TransportError:
                self.last_frames_meta = {"finish": "no_connection", **used}
                failures += 1
            if failures >= 3:
                break
            if failures:
                fallback = self.settings.gemini_fallback_model
                if failures >= 2 and fallback and model != fallback:
                    url, model = url.replace(f"/models/{model}:", f"/models/{fallback}:"), fallback
                await asyncio.sleep(self.settings.gemini_frames_retry_wait_s * failures)
        return None

    async def _level2(self, pack: Pack) -> str | None:
        # The frame reading sends a long stream and the model thinks before it
        # answers: it gets its own output limit and timeout; other tasks keep theirs.
        frames = pack.task in ("frames_reading", "days_reading")  # the two long readings
        max_tokens = self.settings.gemini_frames_max_tokens if frames else None
        timeout = self.settings.gemini_days_timeout_s if pack.task == "days_reading" else \
            self.settings.gemini_frames_timeout_s if frames else self.settings.gemini_timeout_s
        try:
            if pack.task == "reading":
                INPUT_GATE.check_reading_outbound(pack.payload)
            elif pack.task == "session_reading":
                INPUT_GATE.check_session_outbound(pack.payload)
            elif pack.task == "frames_reading":
                INPUT_GATE.check_frames_pack(pack)  # the only pack that carries frames
            elif pack.task == "days_reading":
                INPUT_GATE.check_days_pack(pack)
            elif pack.task == "sensor_reading":
                INPUT_GATE.check_sensors_pack(pack)
            else:
                INPUT_GATE.check_outbound(pack.payload)
            if self.standin:
                if pack.images:
                    return None  # the stand-in reads numbers only
                from .llm.local import LocalModel
                return await LocalModel(self.settings, transport=self.transport).complete(
                    Pack(1, pack.task, pack.messages, pack.payload, pack.ref_map),
                    json_mode=True, max_tokens=max_tokens or 1500)
            schema = None
            if pack.task == "frames_reading":
                from .mind.frame_reading import RESPONSE_SCHEMA as schema
            elif pack.task == "days_reading":
                from .mind.day_reading import RESPONSE_SCHEMA as schema
            elif pack.task == "sensor_reading":
                from .mind.sensor_reading import RESPONSE_SCHEMA as schema
            url, headers, body = gemini.build_request(self.settings, pack,
                                                      max_output_tokens=max_tokens or 4000,
                                                      response_schema=schema)
            return await self._robust_call(url, headers, body, timeout)
        except GateError:
            raise
        except Exception as exc:  # noqa: BLE001
            log.warning("level 2 unavailable: %s", type(exc).__name__)
            return None

    # ---- Lanvi's chat reply (CHAT_MODE=gemini) ----------------------------------

    @property
    def chat_on(self) -> bool:
        s = self.settings
        return s.chat_mode == "gemini" and bool(s.gemini_api_key and gemini.chat_model(s))

    async def chat_complete(self, pack: Pack, forbidden: list[str]) -> str | None:
        """The model's raw reply, or None (off, refused, error, timeout). Never raises."""
        if not self.chat_on or pack.task != "chat" or pack.level != 2:
            return None
        out, t0 = None, time.monotonic()
        try:
            INPUT_GATE.check_chat_outbound(pack, forbidden)
            url, headers, body = gemini.build_chat_request(self.settings, pack)
            limit = self.settings.chat_timeout_s
            data = await asyncio.wait_for(self._post("gemini", url, body, headers, limit), limit)
            out = gemini.parse_response(data or {})
            return out
        except Exception as exc:  # noqa: BLE001 - any failure means the fixed line
            log.warning("chat reply unavailable: %s", type(exc).__name__)
            return None
        finally:
            if self.recorder is not None:
                self.recorder(pack, out, (time.monotonic() - t0) * 1000,
                              gemini.chat_model(self.settings), 2)

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
