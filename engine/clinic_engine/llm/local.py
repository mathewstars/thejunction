"""Level 1: an OpenAI-compatible chat endpoint for a model the team hosts on
its private network. Base URL, model and key come from the environment.

This client only carries packs that InputGate built; its replies go to
OutputGate. It never raises: on any failure it returns None and the caller
falls back to code.
"""

from __future__ import annotations

import logging
import time

import httpx

from ..config import Settings
from ..mind.gates import Pack

log = logging.getLogger("clinic_engine.llm.local")


class LocalModel:
    level = 1

    def __init__(self, settings: Settings, transport: httpx.AsyncBaseTransport | None = None):
        self.base_url = settings.local_llm_base_url.rstrip("/")
        self.model = settings.local_llm_model
        self.key = settings.local_llm_api_key
        self.timeout = settings.local_llm_timeout_s
        self.long_timeout = max(settings.local_llm_timeout_s,
                                getattr(settings, "local_llm_appraisal_timeout_s", 0.0))
        self.transport = transport
        self.recorder = None  # set by the app: keeps the raw exchange for the clinician

    @property
    def configured(self) -> bool:
        return bool(self.base_url and self.model)

    async def complete(self, pack: Pack, json_mode: bool = False, max_tokens: int = 400) -> str | None:
        if not self.configured or pack.level != 1:
            return None
        body = {"model": self.model, "messages": pack.messages, "temperature": 0,
                "max_tokens": max_tokens}
        if json_mode:
            body["response_format"] = {"type": "json_object"}
        headers = {"Authorization": f"Bearer {self.key}"} if self.key else {}
        out, t0 = None, time.monotonic()
        try:
            out = await self._send(pack, body, headers)
            return out
        finally:
            if self.recorder is not None:
                self.recorder(pack, out, (time.monotonic() - t0) * 1000, self.model, 1)

    async def _send(self, pack: Pack, body: dict, headers: dict) -> str | None:
        try:
            # The association appraisal may think for a while before answering.
            # So may the frame reading when the local model stands in for level 2.
            timeout = self.long_timeout if pack.task in ("association", "frames_reading") \
                else self.timeout
            async with httpx.AsyncClient(timeout=timeout, transport=self.transport) as c:
                r = await c.post(f"{self.base_url}/chat/completions", json=body, headers=headers)
                r.raise_for_status()
                content = r.json()["choices"][0]["message"]["content"]
                return content if isinstance(content, str) else None
        except Exception as exc:  # noqa: BLE001 - any failure means "no model"
            log.warning("level 1 model unavailable for %s: %s", pack.task, type(exc).__name__)
            return None
