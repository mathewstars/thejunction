"""Level 2 answered by the local model (OUTREACH_MODE=standin): same checks, nothing leaves."""
import asyncio
import dataclasses
import json

import httpx

from clinic_engine.config import Settings
from clinic_engine.mind.gates import Pack
from clinic_engine.outreach import Outreach


def _settings(**kw):
    base = {f.name: f.default for f in dataclasses.fields(Settings)
            if f.default is not dataclasses.MISSING}
    base.update(outreach_mode="standin", local_llm_base_url="http://model.test/v1",
                local_llm_model="local-test")
    base.update(kw)
    try:
        return Settings(**base)
    except TypeError:
        from tests.conftest import make_settings  # type: ignore
        return make_settings(**kw)


def test_standin_answers_level2_from_the_local_host_only():
    seen = []

    def handler(req: httpx.Request) -> httpx.Response:
        seen.append(req.url.host)
        return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps({"ok": 1})}}]})

    out = Outreach(_settings(), transport=httpx.MockTransport(handler))
    assert out.gemini_on and out.standin and out.level2_model.startswith("stand-in")
    pack = Pack(2, "second_opinion", [{"role": "user", "content": "{}"}], {})
    assert asyncio.run(out.gemini_complete(pack)) == json.dumps({"ok": 1})
    assert seen == ["model.test"]


def test_standin_off_without_a_local_model_and_skips_pictures():
    out = Outreach(_settings(local_llm_model=""))
    assert not out.gemini_on
    out = Outreach(_settings(), transport=httpx.MockTransport(lambda r: httpx.Response(500)))
    pack = Pack(2, "second_opinion", [{"role": "user", "content": "{}"}], {}, images=[b"x"])
    assert asyncio.run(out.gemini_complete(pack)) is None
