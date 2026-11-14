"""Lanvi's chat reply (CHAT_MODE=gemini): Gemini writes the reply to a note,
behind code checks on both sides. Gemini is always a fake here (MockTransport)."""

import asyncio
import json

import httpx

from clinic_engine.mind.gates import INPUT_GATE, OUTPUT_GATE
from clinic_engine.mind.notes import REPLY_TEMPLATES

from conftest import Env, FakeLocal, Level2Recorder

GOOD = "That sounds like a calm walk. What did you notice by the water?"


def note(env, text, nid="note-chat-0001"):
    return env.client.post("/v1/notes", headers=env.H, json={"id": nid, "text": text})


def model_says(mood="ok", help_=False, topic="other", template="ok"):
    return json.dumps({"mood": mood, "asks_for_help": help_, "topic": topic,
                       "reply_template": template})


def chat_env(reply: object = GOOD, local=None, **kw):
    """Chat on, level-2 review off, so every outbound request is a chat request."""
    rec = Level2Recorder(reply)
    kw.setdefault("chat_mode", "gemini")
    kw.setdefault("outreach_mode", "off")
    env = Env(local=local or FakeLocal(note=model_says()), level2=rec, **kw)
    return env, rec


def chat_requests(rec):
    return [r for r in rec.requests if r[0] == "generativelanguage.googleapis.com"]


# ---- fixed mode is today's behaviour ----------------------------------------------------

def test_fixed_mode_is_default_and_unchanged():
    from clinic_engine.config import Settings
    assert Settings().chat_mode == "fixed"
    rec = Level2Recorder(GOOD)
    env = Env(local=FakeLocal(note=model_says("ok", False, "other", "ok")), level2=rec,
              outreach_mode="off")
    body = note(env, "walked by the sea today").json()
    assert body["reply"] == {"template_id": "ok", "text": REPLY_TEMPLATES["ok"]}
    assert body["crisis"] is False and body["crisis_block"] is None
    assert chat_requests(rec) == []
    stored = env.repo().notes()[0]
    assert "reply" not in stored
    assert not any(e["action"] == "note_reply" for e in env.audit())
    d = env.client.get(f"/v1/clinic/patients/{env.demo['patient_id']}", headers=env.C()).json()
    assert d["notes"][0]["reply"] == REPLY_TEMPLATES["ok"]
    assert d["notes"][0]["reply_by"] == "fixed" and d["chat_mode"] == "fixed"


# ---- gemini mode ---------------------------------------------------------------------------

def test_gemini_mode_returns_the_model_reply_in_the_same_shape():
    env, rec = chat_env()
    r = note(env, "walked by the sea today")
    assert r.status_code == 200
    body = r.json()
    assert set(body) == {"reply", "crisis", "crisis_block", "suggestion"}
    assert body["reply"] == {"template_id": "gemini", "text": GOOD}
    assert body["crisis"] is False and body["crisis_block"] is None
    reqs = chat_requests(rec)
    assert len(reqs) == 1
    _, sent, url = reqs[0]
    assert url.endswith("/models/test-model:generateContent")
    assert sent["contents"] == [{"role": "user", "parts": [{"text": "walked by the sea today"}]}]
    assert "Arctic fox" in sent["systemInstruction"]["parts"][0]["text"]
    # Stored with the note, marked as model-written, and shown so to the clinician.
    stored = env.repo().notes()[0]
    assert stored["reply"]["text"] == GOOD and stored["reply"]["written_by"] == "model"
    d = env.client.get(f"/v1/clinic/patients/{env.demo['patient_id']}", headers=env.C()).json()
    assert d["notes"][0]["reply"] == GOOD and d["notes"][0]["reply_by"] == "model"
    assert d["chat_mode"] == "gemini"
    # The same note again gives the same answer, without asking the model again.
    assert note(env, "walked by the sea today").json() == body
    assert len(chat_requests(rec)) == 1


def test_raw_exchange_is_kept_and_words_hidden_without_share_notes():
    env, _ = chat_env()
    note(env, "walked by the sea today")
    pid = env.demo["patient_id"]
    from clinic_engine.mind import exchanges
    docs = exchanges.view(env.store, env.demo["clinic_id"], pid, share_notes=False)
    chat = [d for d in docs if d["task"] == "chat"]
    assert chat and chat[0]["reply"] == GOOD and chat[0]["level"] == 2
    assert all(m["content"] != "walked by the sea today" for m in chat[0]["messages"])


def test_crisis_note_never_reaches_the_model():
    env, rec = chat_env(local=FakeLocal(note=model_says("good", False, "other", "good")))
    body = note(env, "honestly I want to die").json()
    assert body["crisis"] is True and body["crisis_block"] is not None
    assert body["reply"] == {"template_id": "help", "text": REPLY_TEMPLATES["help"]}
    assert chat_requests(rec) == []


def test_model_label_asking_for_help_never_reaches_the_model():
    env, rec = chat_env(local=FakeLocal(note=model_says("low", True, "other", "low_1")))
    body = note(env, "a strange quiet evening").json()
    assert body["crisis"] is True and body["reply"]["template_id"] == "help"
    assert chat_requests(rec) == []


def test_help_note_with_level1_down_never_reaches_the_model():
    env, rec = chat_env(local=FakeLocal(note=None))
    assert note(env, "I need help").json()["crisis"] is True
    assert chat_requests(rec) == []


def test_no_consent_for_outside_processing_gives_the_fixed_line():
    env, rec = chat_env()
    p = env.repo().patient()
    env.repo().put("patient.json", {**p, "allow_outside_processing": False})
    body = note(env, "walked by the sea today").json()
    assert body["reply"] == {"template_id": "ok", "text": REPLY_TEMPLATES["ok"]}
    assert chat_requests(rec) == []


def test_missing_key_or_model_gives_the_fixed_line():
    for kw in ({"gemini_api_key": ""}, {"gemini_model": ""}):
        env, rec = chat_env(**kw)
        body = note(env, "walked by the sea today").json()
        assert body["reply"]["template_id"] == "ok"
        assert chat_requests(rec) == []


def test_chat_model_overrides_gemini_model():
    env, rec = chat_env(chat_model="chat-model")
    note(env, "walked by the sea today")
    assert chat_requests(rec)[0][2].endswith("/models/chat-model:generateContent")


def test_bad_empty_or_failing_answers_fall_back_to_the_fixed_line():
    bad = [
        None,  # API error (503)
        "",  # empty
        "x " * 150,  # too long
        "**Great** walk!",  # not plain text
        "Have a look at https://example.org for tips.",  # link
        "Look at calm.com tonight.",  # link without http
        "That sounds like depression. Talk to your doctor.",  # clinical
        "Maybe take your medication a bit earlier.",  # advice
        "I promise tomorrow will be better.",  # promise
        "I know how you feel.",  # claims to feel
        "As an AI model I cannot walk.",  # talks about being a model
        "Do you ever think about hurting yourself?",  # self-harm question
        "Call 0401234567 if you need anything.",  # a made-up number
        "Nice! What did you see? Was it cold? Who was there?",  # many questions
        "Nice walk 🌊",  # emoji
    ]
    for i, reply in enumerate(bad):
        env, rec = chat_env(reply=reply)
        body = note(env, "walked by the sea today", f"note-bad-{i:04d}").json()
        assert body["reply"] == {"template_id": "ok", "text": REPLY_TEMPLATES["ok"]}, reply
        assert body["crisis"] is False
        assert "reply" not in env.repo().notes()[0]


def test_slow_model_falls_back_within_the_timeout():
    async def slow(request: httpx.Request) -> httpx.Response:
        await asyncio.sleep(2)
        return httpx.Response(200, json={"candidates": [{"content": {"parts": [{"text": GOOD}]}}]})

    env = Env(local=FakeLocal(note=model_says()), chat_mode="gemini",
              gemini_api_key="test-key", gemini_model="test-model", chat_timeout_s=0.2)
    env.outreach.transport = httpx.MockTransport(slow)
    body = note(env, "walked by the sea today").json()
    assert body["reply"]["template_id"] == "ok"


def test_refused_answer_is_logged_by_code_only():
    env, _ = chat_env(reply="That sounds like depression.")
    note(env, "walked by the sea today")
    refusals = [e for e in env.audit(outcome="refused") if e["action"] == "gate_refusal"]
    assert any(e["detail"]["task"] == "chat" and e["reason"] == "banned_vocabulary"
               for e in refusals)
    assert "depression" not in json.dumps(env.audit())


def test_crisis_and_suggestion_unchanged_by_the_model():
    env, _ = chat_env(reply="The help screen is not needed, all is well.")
    fixed_env = Env(local=FakeLocal(note=model_says()))
    a = note(env, "walked by the sea today").json()
    b = note(fixed_env, "walked by the sea today").json()
    assert a["crisis"] == b["crisis"] and a["crisis_block"] == b["crisis_block"]
    assert a["suggestion"] == b["suggestion"]


# ---- the conversation sent ---------------------------------------------------------------

def test_todays_turns_are_passed_capped_and_crisis_notes_left_out():
    replies = iter(["Reply one.", "Reply two.", "Reply three.", "Reply four.", "Reply five."])
    env, rec = chat_env(reply=lambda body: next(replies))
    note(env, "first note", "note-turn-0001")
    env.clock.advance(minutes=5)
    note(env, "second note", "note-turn-0002")
    env.clock.advance(minutes=5)
    note(env, "I need help", "note-turn-0003")  # crisis: never sent, now or later
    env.clock.advance(minutes=5)
    note(env, "third note", "note-turn-0004")
    env.clock.advance(minutes=5)
    note(env, "fourth note", "note-turn-0005")
    env.clock.advance(minutes=5)
    note(env, "fifth note", "note-turn-0006")
    reqs = chat_requests(rec)
    assert len(reqs) == 5
    second = [c["parts"][0]["text"] for c in reqs[1][1]["contents"]]
    assert second == ["first note", "Reply one.", "second note"]
    roles = [c["role"] for c in reqs[1][1]["contents"]]
    assert roles == ["user", "model", "user"]
    last = [c["parts"][0]["text"] for c in reqs[-1][1]["contents"]]
    # At most six earlier turns, then the new note.
    assert last == ["second note", "Reply two.", "third note", "Reply three.",
                    "fourth note", "Reply four.", "fifth note"]
    for _, body, _ in reqs:
        assert "I need help" not in json.dumps(body)
        assert REPLY_TEMPLATES["help"] not in json.dumps(body)


def test_yesterdays_notes_are_not_passed():
    env, rec = chat_env()
    note(env, "yesterday's note", "note-day-0001")
    env.clock.advance(hours=24)
    note(env, "today's note", "note-day-0002")
    sent = chat_requests(rec)[-1][1]["contents"]
    assert [c["parts"][0]["text"] for c in sent] == ["today's note"]


def test_checkin_words_are_not_sent_and_not_in_the_conversation():
    env, rec = chat_env()
    env.repo().put("notes/ck-x.json", {"id": "ck-x", "at": env.clock.now().isoformat(),
                                       "text": "words from a check-in", "source": "checkin",
                                       "text_sha256": "x", "classification": {
                                           "mood": "ok", "topic": "other", "crisis": False,
                                           "asks_for_help": False, "template_id": "ok",
                                           "model": "ok"}})
    note(env, "walked by the sea today")
    assert "words from a check-in" not in json.dumps(chat_requests(rec))


def test_nothing_identifying_is_in_the_prompt():
    env, rec = chat_env()
    p = env.repo().patient()
    env.repo().put("patient.json", {**p, "display_name": "Anna Virtanen"})
    note(env, "walked by the sea today")
    blob = json.dumps(chat_requests(rec))
    p = env.repo().patient()
    for value in (p["id"], p["clinic_id"], p["label"], "Anna Virtanen", "note-chat-0001",
                  env.clock.now().date().isoformat(), p["timezone"]):
        assert value not in blob
    assert "test-key" not in blob  # the key is a header, never in the body


def test_record_value_in_the_words_means_nothing_is_sent():
    env, rec = chat_env()
    p = env.repo().patient()
    env.repo().put("patient.json", {**p, "display_name": "Anna Virtanen"})
    body = note(env, "Anna Virtanen walked by the sea").json()
    assert body["reply"]["template_id"] == "ok"
    assert chat_requests(rec) == []


# ---- the gates on their own ---------------------------------------------------------------

def test_chat_pack_caps_turns_and_starts_with_the_person():
    earlier = []
    for i in range(10):
        earlier += [{"role": "person", "text": f"n{i}"}, {"role": "lanvi", "text": f"r{i}"}]
    pack = INPUT_GATE.chat_pack("now", earlier, [])
    roles = [m["role"] for m in pack.messages]
    assert roles[0] == "system" and len(pack.messages) == 1 + 6 + 1
    assert roles[1] == "user" and pack.messages[-1] == {"role": "user", "content": "now"}
    pack = INPUT_GATE.chat_pack("now", [{"role": "lanvi", "text": "hello"}], [])
    assert [m["role"] for m in pack.messages] == ["system", "user"]


def test_chat_output_gate_accepts_a_warm_short_reply():
    for ok in ("That sounds like a lovely walk.",
               "Thank you for telling me. Maybe a slow breath with me?",
               "I'm Lanvi, a little helper in the app. The clinic's people are there for real help.",
               "Kiitos, kuulostaa mukavalta kävelyltä."):
        assert OUTPUT_GATE.chat(ok).ok, ok
    assert OUTPUT_GATE.chat('"Quoted reply."').value == "Quoted reply."
