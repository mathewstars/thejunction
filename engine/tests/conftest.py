"""Shared test helpers. Everything is offline: models and outbound hosts are
fakes (httpx.MockTransport for level 2 and Telegram)."""

import os
import asyncio
import json
import random
import warnings
from datetime import date, datetime, timedelta, timezone

import httpx
import pytest

warnings.filterwarnings("ignore", category=DeprecationWarning)

from fastapi.testclient import TestClient  # noqa: E402

from clinic_engine import seed  # noqa: E402
from clinic_engine.app import create_app  # noqa: E402
from clinic_engine.config import Settings  # noqa: E402
from clinic_engine.mind.engine import FixedClock  # noqa: E402
from clinic_engine.notify import RecordingNotifier  # noqa: E402
from clinic_engine.outreach import Outreach  # noqa: E402
from clinic_engine.store import MemoryStore  # noqa: E402

NOW = datetime(2026, 11, 13, 9, 0, tzinfo=timezone.utc)  # 11:00 in Helsinki, a Friday
TODAY = date(2026, 11, 13)


class FakeLocal:
    """Level-1 stand-in. Replies per task: a string, None, or a callable(pack)."""

    configured = True

    def __init__(self, **replies):
        self.replies = replies
        self.packs = []

    async def complete(self, pack, json_mode=False, max_tokens=400):
        self.packs.append(pack)
        r = self.replies.get(pack.task)
        return r(pack) if callable(r) else r


class Level2Recorder:
    """MockTransport handler: records every outbound request, answers per task."""

    def __init__(self, reply=None):
        self.requests = []  # (host, json body)
        self.reply = reply  # str, callable(body) -> str, or None for "no answer"

    def __call__(self, request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        self.requests.append((request.url.host, body, str(request.url)))
        if "api.telegram.org" in request.url.host:
            return httpx.Response(200, json={"ok": True})
        r = self.reply(body) if callable(self.reply) else self.reply
        if r is None:
            return httpx.Response(503, json={})
        return httpx.Response(200, json={"candidates": [{"content": {"parts": [{"text": r}]}}]})


def make_settings(**kw):
    base = dict(store="memory", review_inline=True, tick_seconds=0,
                gemini_frames_retry_wait_s=0)
    base.update(kw)
    return Settings(**base)


class Env:
    def __init__(self, local=None, level2=None, notifier=None, extra=0, **settings_kw):
        self.clock = FixedClock(NOW)
        self.store = MemoryStore()
        if os.environ.get("TEST_PACKED_STORE"):  # run the whole suite on the packed layout
            from clinic_engine.store import PackedStore
            self.store = PackedStore(self.store)
        if level2 is not None:
            settings_kw.setdefault("outreach_mode", "gemini")
            settings_kw.setdefault("gemini_api_key", "test-key")
            settings_kw.setdefault("gemini_model", "test-model")
        self.settings = make_settings(**settings_kw)
        self.level2 = level2
        transport = httpx.MockTransport(level2) if level2 is not None else None
        self.outreach = Outreach(self.settings, transport=transport)
        self.local = local
        self.notifier = notifier or RecordingNotifier()
        self.app = create_app(settings=self.settings, store=self.store, clock=self.clock,
                              local_model=local or _OffLocal(), outreach=self.outreach,
                              notifier=self.notifier, start_ticker=False)
        self.mind = self.app.state.ctx.mind
        self.demo = seed.create_demo(self.store, self.settings, NOW, extra=extra,
                                     password="correct horse battery")
        self.run(self._settle_all())
        self.client = TestClient(self.app)

    async def _settle_all(self):
        d = self.demo
        for pid in [d["patient_id"], *d["extra_patient_ids"]]:
            await seed.settle(self.mind, d["clinic_id"], pid)
        await seed.settle(self.mind, d["mock_clinic_id"], d["mock_patient_id"], review=False)

    def run(self, coro):
        return asyncio.run(coro)

    @property
    def H(self):
        return {"Authorization": "Bearer " + self.demo["device_token"]}

    @property
    def A(self):
        return {"Authorization": "Bearer " + self.demo["admin_token"]}

    def C(self):
        r = self.client.post("/v1/clinic/login", json={"username": "demo-clinician",
                                                         "password": "correct horse battery"})
        assert r.status_code == 200, r.text
        return {"Authorization": "Bearer " + r.json()["session_token"]}

    def repo(self, pid=None, clinic=None):
        return self.mind.repo(clinic or self.demo["clinic_id"], pid or self.demo["patient_id"])

    def audit(self, pid=None, clinic=None, outcome=None):
        from clinic_engine.audit import list_audit
        return list_audit(self.store, clinic or self.demo["clinic_id"],
                          pid or self.demo["patient_id"], outcome=outcome, limit=1000)

    def global_audit(self):
        from clinic_engine.audit import list_audit
        return list_audit(self.store, None, None, limit=1000)


class _OffLocal:
    configured = False

    async def complete(self, pack, json_mode=False, max_tokens=400):
        return None


@pytest.fixture
def env():
    return Env()


# ---- synthetic data for unit tests ------------------------------------------------------

def make_days(today=TODAY, n=28, steps=7000.0, speed=1.25, seed_=1, shape=None):
    """n days ending today; shape maps offset (0 = today, -1 = yesterday) -> factor."""
    rng = random.Random(seed_)
    out = {}
    for k in range(n - 1, -1, -1):
        d = today - timedelta(days=k)
        f = (shape or {}).get(-k, 1.0)
        out[d.isoformat()] = {"date": d.isoformat(), "steps": int(rng.gauss(steps, 500) * f),
                              "walking_speed_m_s": round(rng.gauss(speed, 0.03) * (0.8 + 0.2 * f), 3)}
    return out
