"""The two gates at both levels, the anonymizer, and refusals feeding the next review."""

import json
import re

from clinic_engine.mind.gates import INPUT_GATE, OUTPUT_GATE, GateError

from conftest import Env, FakeLocal, Level2Recorder

ISO_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")


def identifiers(env: Env) -> list[str]:
    d = env.demo
    repo = env.repo()
    ids = [d["clinic_id"], d["patient_id"], "Patient A-014", "Demo clinic"]
    ids += [s["id"] for s in repo.suggestions()]
    ids += [r["id"] for r in repo.rounds()]
    ids += [k.split("/")[-1].removesuffix(".json")
            for k in env.store.list(f"clinics/{d['clinic_id']}/patients/{d['patient_id']}/devices/")]
    ids += list(repo.days())  # dates
    ids += [str(v["steps"]) for v in repo.days().values()]  # raw values
    return ids


# ---- level 1: review ---------------------------------------------------------------------

def test_level1_review_pack_is_allowlisted_and_reply_is_validated():
    good_reply = None

    def reply(pack):
        nonlocal good_reply
        ev = pack.payload["evidence"]
        refs = [e["ref"] for e in ev if e["action"] == "breathing" and e.get("kind") == "suggestion"
                and e.get("done")
                and e.get("outcome") == "improved"]
        good_reply = json.dumps({"lessons": [
            {"action": "breathing", "effect": "prefer", "context": "morning",
             "evidence_ids": refs, "rationale_code": "done_and_improved"},
            {"action": "teleport", "effect": "prefer", "context": "any",
             "evidence_ids": refs, "rationale_code": "done_and_improved"}],
            "questions": [{"code": "prefer_morning", "action": "breathing"}]})
        return good_reply

    env = Env(local=FakeLocal(review=reply))
    review = env.run(env.mind.run_review(env.repo(), "test"))
    pack = [p for p in env.local.packs if p.task == "review"][-1]
    text = json.dumps(pack.payload)
    for ident in identifiers(env):
        assert ident not in text
    assert not ISO_DATE.search(text)
    assert review["models"]["level1"] == "replied"
    assert any(a["source"] == "local" and a["context"] == "morning" for a in review["accepted"])
    assert any(r["reason"] == "action_not_in_catalog" for r in review["refused"])
    refused = [e for e in env.audit(outcome="refused") if e["action"] == "gate_refusal"]
    assert any(e["reason"] == "action_not_in_catalog" for e in refused)


def test_refusals_become_input_to_the_next_review():
    env = Env(local=FakeLocal(review="Sure! Here are some lessons: be happy."))
    env.run(env.mind.run_review(env.repo(), "first"))
    env.run(env.mind.run_review(env.repo(), "second"))
    packs = [p for p in env.local.packs if p.task == "review"]
    assert any(r["reason"] == "not_json_object" for r in packs[-1].payload["recent_refusals"])


def test_level1_review_prose_and_extra_keys_refused():
    res = OUTPUT_GATE.review('{"lessons": [], "questions": [], "close_attention": true}',
                             INPUT_GATE.review_pack(1, [], [], __import__("datetime").date(2026, 11, 13), [], []),
                             [], {"lessons": []}, [])
    assert not res.ok and res.refusals[0].reason.startswith("schema:extra_forbidden")


# ---- level 1: wording ----------------------------------------------------------------------

def test_wording_goes_through_both_gates():
    env = Env(local=FakeLocal(wording="You might feel less depressed after a breath."))
    env.client.post("/v1/demo/scenario", headers=env.A, json={"name": "dip"})
    s = env.client.get("/v1/today", headers=env.H).json()["suggestion"]
    assert s is not None
    pack = [p for p in env.local.packs if p.task == "wording"][-1]
    assert set(pack.payload) == {"action", "lines"}
    from clinic_engine.mind.catalog import ACTIONS
    assert s["text"] == ACTIONS[s["action"]].template  # fell back to the first line
    assert any(e["reason"] == "line_not_in_set" for e in env.audit(outcome="refused"))


def test_wording_from_model_used_when_clean():
    env = Env(local=FakeLocal(wording=lambda pack: pack.payload["lines"][1]["id"]))
    env.client.post("/v1/demo/scenario", headers=env.A, json={"name": "dip"})
    s = env.client.get("/v1/today", headers=env.H).json()["suggestion"]
    from clinic_engine.mind.lines import suggestion_lines
    assert s["text"] == suggestion_lines(s["action"])[1]["text"]



# ---- level 2: second opinion ---------------------------------------------------------------

def test_level2_second_opinion_is_anonymous_and_can_only_object():
    def reply(body):
        payload = json.loads(body["contents"][0]["parts"][0]["text"])
        refs = [c["ref"] for c in payload["lessons"]]
        return json.dumps({"objections": [{"ref": refs[0], "code": "weak_evidence"}]})

    rec = Level2Recorder(reply)
    env = Env(level2=rec)
    rec.requests.clear()
    review = env.run(env.mind.run_review(env.repo(), "test"))
    assert rec.requests, "level 2 should be asked"
    host, body, url = rec.requests[-1]
    assert host == "generativelanguage.googleapis.com"
    blob = json.dumps(body)
    for ident in identifiers(env):
        assert ident not in blob
    assert not ISO_DATE.search(blob)
    assert any(r["reason"].startswith("level2_objection") for r in review["refused"])


def test_two_level2_requests_share_no_identifier():
    rec = Level2Recorder(json.dumps({"objections": []}))
    env = Env(level2=rec)
    rec.requests.clear()
    env.run(env.mind.run_review(env.repo(), "a"))
    env.run(env.mind.run_review(env.repo(), "b"))
    p1 = json.loads(rec.requests[-2][1]["contents"][0]["parts"][0]["text"])
    p2 = json.loads(rec.requests[-1][1]["contents"][0]["parts"][0]["text"])
    assert p1["alias"] != p2["alias"]
    strings = lambda x: {s for s in re.findall(r'"([^"]{6,})"', json.dumps(x))}  # noqa: E731
    shared = strings(p1) & strings(p2)
    assert not any(s.startswith("p-") for s in shared)


def test_level2_output_gate_refuses_prose():
    rec = Level2Recorder("I object to everything, please email the doctor.")
    env = Env(level2=rec)
    review = env.run(env.mind.run_review(env.repo(), "t"))
    assert review["models"]["level2"] == "refused_or_unavailable"
    assert any(r["reason"] == "not_json_object" and r["level"] == 2 for r in review["refused"])
    assert review["accepted"]  # code's lessons stand


def test_level2_input_gate_refuses_identifier_like_values():
    import pytest
    with pytest.raises(GateError):
        INPUT_GATE.check_outbound({"evidence": [{"action": "pat_0123456789abcdef01234567"}]})
    with pytest.raises(GateError):
        INPUT_GATE.check_outbound({"evidence": [{"action": "2026-11-13"}]})
    with pytest.raises(GateError):
        INPUT_GATE.check_outbound({"label": "Patient A-014"})
    with pytest.raises(GateError):
        INPUT_GATE.check_outbound({"recent_days": [{"movement_z": 1.234}]})


def test_note_text_can_never_be_packed_for_level2():
    import pytest
    with pytest.raises(GateError) as e:
        INPUT_GATE.note_pack(2, "hello", ["ok"])
    assert e.value.refusal.reason == "note_text_never_leaves_server"


def test_outreach_off_sends_nothing():
    rec = Level2Recorder(json.dumps({"objections": []}))
    env = Env(level2=rec, outreach_mode="off")
    rec.requests.clear()
    env.run(env.mind.run_review(env.repo(), "t"))
    assert rec.requests == []


def test_outreach_host_allowlist():
    import asyncio
    import pytest
    from clinic_engine.outreach import Outreach, OutreachRefused
    o = Outreach(Env().settings)
    with pytest.raises(OutreachRefused):
        asyncio.run(o._post("gemini", "https://evil.example.com/x", {}, {}, 1.0))
    with pytest.raises(OutreachRefused):
        asyncio.run(o._post("gemini", "http://generativelanguage.googleapis.com/x", {}, {}, 1.0))
    with pytest.raises(OutreachRefused):
        asyncio.run(o._post("telegram", "https://generativelanguage.googleapis.com/x", {}, {}, 1.0))


# ---- the real clients, offline ----------------------------------------------------------------

def test_local_client_calls_openai_compatible_endpoint_and_falls_back():
    import asyncio
    import httpx
    from clinic_engine.config import Settings
    from clinic_engine.llm.local import LocalModel
    seen = []

    def handler(req):
        seen.append(json.loads(req.content))
        return httpx.Response(200, json={"choices": [{"message": {"content": "hi"}}]})

    s = Settings(local_llm_base_url="http://model.internal.example/v1", local_llm_model="m")
    pack = INPUT_GATE.wording_pack("breathing")
    assert asyncio.run(LocalModel(s, httpx.MockTransport(handler)).complete(pack)) == "hi"
    assert seen[0]["model"] == "m" and seen[0]["messages"] == pack.messages

    def broken(req):
        raise httpx.ConnectError("down")

    assert asyncio.run(LocalModel(s, httpx.MockTransport(broken)).complete(pack)) is None
    # A level-2 pack is never sent to the level-1 client.
    pack2 = INPUT_GATE.second_opinion_pack([], [], __import__("datetime").date(2026, 11, 13))
    assert asyncio.run(LocalModel(s, httpx.MockTransport(handler)).complete(pack2)) is None


def test_gemini_request_shape():
    from clinic_engine.config import Settings
    from clinic_engine.llm import gemini
    s = Settings(gemini_api_key="k", gemini_model="some-model")
    pack = INPUT_GATE.second_opinion_pack([], [], __import__("datetime").date(2026, 11, 13))
    pack.images.append(b"\x89PNG")
    url, headers, body = gemini.build_request(s, pack)
    assert url.endswith("/models/some-model:generateContent")
    assert headers == {"x-goog-api-key": "k"}
    assert body["generationConfig"]["responseMimeType"] == "application/json"
    assert body["contents"][0]["parts"][1]["inline_data"]["mime_type"] == "image/png"
    assert gemini.parse_response({"candidates": [{"content": {"parts": [{"text": "{}"}]}}]}) == "{}"
    assert gemini.parse_response({}) is None
