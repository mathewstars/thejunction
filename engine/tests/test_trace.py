"""The decision trace: one chain per trigger, layers in order, refusals
recorded, no note text, tenant-scoped, and it never breaks ingest."""

import json
from datetime import timedelta

from clinic_engine import seed
from clinic_engine.mind import trace as trace_mod
from clinic_engine.mind.trace import LAYERS

from conftest import NOW, TODAY, Env, FakeLocal

SECRET = "zebra-umbrella-7"


def get_trace(env, headers=None, **params):
    pid = env.demo["patient_id"]
    q = "&".join(f"{k}={v}" for k, v in params.items())
    r = env.client.get(f"/v1/clinic/patients/{pid}/trace" + ("?" + q if q else ""),
                       headers=headers or env.C())
    assert r.status_code == 200, r.text
    return r.json()


def dip_days():
    """Five clearly low days ending today, as a phone would upload them."""
    return [{"date": (TODAY - timedelta(days=k)).isoformat(), "steps": 2400 + 10 * k,
             "walking_speed_m_s": 1.0} for k in range(5)]


def test_daily_upload_that_opens_attention_is_one_chain_in_layer_order():
    env = Env()
    before = {c["chain_id"] for c in get_trace(env, limit=100)["chains"]}
    r = env.client.post("/v1/daily", headers=env.H, json={"days": dip_days()})
    assert r.status_code == 200 and r.json()["status"] == "outside"
    new = [c for c in get_trace(env, limit=100)["chains"] if c["chain_id"] not in before]
    assert len(new) == 1
    ch = new[0]
    assert ch["trigger"] == "day" and ch["changed"] is True
    layers = [e["layer"] for e in ch["entries"]]
    assert layers == sorted(layers, key=LAYERS.index)  # stacked in loop order
    firsts = [layers.index(x) for x in ("trigger", "watchers", "attention", "response")]
    assert firsts == sorted(firsts)
    trig = ch["entries"][0]
    assert trig["layer"] == "trigger" and trig["detail"]["last_day"] == TODAY.isoformat()
    w = next(e for e in ch["entries"] if e["layer"] == "watchers")
    assert w["code"] == "fired"
    assert any(f["watcher"] == "deviation" and f["op"] == "open" for f in w["detail"]["fired"])
    assert "silence" in w["detail"]["quiet"]
    assert w["detail"]["facts"]["deviation"]["low_days"] >= 3
    opened = next(e for e in ch["entries"] if e["layer"] == "attention" and e["code"] == "opened"
                  and e["detail"]["kind"] == "deviation")
    assert opened["detail"]["level"] == "attention" and opened["detail"]["rule"] == "sustained_drop"
    resp = next(e for e in ch["entries"] if e["layer"] == "response")
    assert resp["code"] == "suggested" and resp["notable"]
    opened_ids = {e["detail"]["attention_id"] for e in ch["entries"] if e["code"] == "opened"}
    assert resp["detail"]["attention_id"] in opened_ids  # answers an item this chain opened
    assert resp["detail"]["ranking"]["ranked"][0] == resp["detail"]["action"]
    # The current state explains the held item and links to its chain.
    cur = {c["attention_id"]: c for c in get_trace(env)["current"]}
    dev = cur[opened["detail"]["attention_id"]]
    assert dev["opened_chain_id"] == ch["chain_id"] and dev["level_rule"] == "sustained_drop"
    target = cur[resp["detail"]["attention_id"]]
    assert target["last_action"]["code"] == "suggested"


def test_refused_model_answer_shows_in_level1_with_reason():
    env = Env(local=FakeLocal(wording="You might feel less depressed after a breath."))
    env.client.post("/v1/demo/scenario", headers=env.A, json={"name": "dip"})
    chains = get_trace(env, changed_only="true")["chains"]
    l1 = [e for c in chains for e in c["entries"] if e["layer"] == "level1"
          and e["detail"].get("task") == "wording"]
    assert l1 and l1[0]["code"] == "refused" and l1[0]["notable"]
    assert "line_not_in_set" in l1[0]["detail"]["reasons"]
    assert l1[0]["detail"]["used"] == "template"
    assert l1[0]["detail"]["saw"]["fields"] == ["action", "lines"]
    assert chains[0]["headline"] and len(chains[0]["headline"].split()) <= 6
    assert {c["outcome"] for c in chains} <= {"attention_opened", "attention_raised",
                                              "attention_closed", "suggested", "message_sent",
                                              "refused", "nothing"}


def test_note_text_never_in_any_trace_entry():
    env = Env(local=FakeLocal(note=json.dumps({"mood": "low", "asks_for_help": False,
                                               "topic": "sleep", "reply_template": "ok"})))
    for i, text in enumerate([f"I feel so exhausted {SECRET}", f"I need help {SECRET} tonight"]):
        r = env.client.post("/v1/notes", headers=env.H,
                            json={"id": f"note-000{i}-abcd", "text": text})
        assert r.status_code == 200
    pid, c = env.demo["patient_id"], env.demo["clinic_id"]
    stored = [env.store.get(k) for k in env.store.list(trace_mod.prefix(c, pid))]
    assert stored and SECRET not in json.dumps(stored)
    assert "exhausted" not in json.dumps(stored)
    t = get_trace(env, limit=100)
    assert SECRET not in json.dumps(t)
    notes = [ch for ch in t["chains"] if ch["trigger"] == "note"]
    assert len(notes) == 2
    trig = notes[0]["entries"][0]
    assert trig["layer"] == "trigger" and set(trig["detail"]) <= {
        "note_id", "mood", "topic", "crisis", "asks_for_help", "model"}
    # The help note opened an urgent item; the notifier step is in the same chain.
    help_chain = notes[0]
    assert any(e["layer"] == "attention" and e["detail"].get("kind") == "asked_for_help"
               for e in help_chain["entries"])
    assert any(e["layer"] == "notifier" for e in help_chain["entries"])
    assert any(e["layer"] == "level1" and e["detail"].get("task") == "note"
               for e in help_chain["entries"])


def test_other_clinic_cannot_read_trace(env):
    seed.create_clinician(env.store, env.demo["mock_clinic_id"], "other-clinician",
                          "other clinic password", NOW)
    tok = env.client.post("/v1/clinic/login", json={"username": "other-clinician",
                                                     "password": "other clinic password"})
    O = {"Authorization": "Bearer " + tok.json()["session_token"]}
    pid = env.demo["patient_id"]
    assert env.client.get(f"/v1/clinic/patients/{pid}/trace", headers=O).status_code == 404
    assert env.client.get(f"/v1/clinic/patients/{pid}/trace", headers=env.H).status_code == 403
    assert env.client.get(f"/v1/clinic/patients/{pid}/trace", headers=env.A).status_code == 403
    assert env.client.get(f"/v1/clinic/patients/{pid}/trace").status_code == 401
    # Bad filters are refused before anything is read.
    assert env.client.get(f"/v1/clinic/patients/{pid}/trace?chain_id=../x",
                          headers=env.C()).status_code == 422
    from clinic_engine.audit import list_audit
    reasons = [e["reason"] for e in list_audit(env.store, env.demo["mock_clinic_id"], None,
                                               outcome="refused")]
    assert "patient_not_in_clinic" in reasons


def test_filters_and_seeded_trace(env):
    t = get_trace(env)
    assert t["chains"], "the seeded demo already has a trace"
    env.client.post("/v1/demo/scenario", headers=env.A, json={"name": "dip"})
    changed = get_trace(env, changed_only="true")["chains"]
    assert changed and all(c["changed"] for c in changed)
    full = changed[0]
    assert {"trigger", "watchers", "attention", "response", "level1"} <= {
        e["layer"] for e in full["entries"]}
    one = get_trace(env, chain_id=full["chain_id"])["chains"]
    assert [c["chain_id"] for c in one] == [full["chain_id"]]
    att = next(e["detail"]["attention_id"] for e in full["entries"] if e["layer"] == "attention")
    by_item = get_trace(env, attention_id=att)["chains"]
    assert by_item and all(any(e["detail"].get("attention_id") == att for e in c["entries"])
                           for c in by_item)


def test_trace_failure_never_breaks_ingest(monkeypatch):
    env = Env()

    def boom(*a, **k):
        raise RuntimeError("store down for trace")

    monkeypatch.setattr(trace_mod.Tracer, "write", boom)
    monkeypatch.setattr(trace_mod, "watcher_facts", boom)
    r = env.client.post("/v1/daily", headers=env.H, json={"days": dip_days()})
    assert r.status_code == 200 and r.json()["status"] == "outside"
    assert any(i["kind"] == "deviation" for i in env.repo().items())


def test_trace_does_not_change_decisions(monkeypatch):
    """The same upload gives the same attention and suggestion with the trace off."""
    def run(off):
        env = Env()
        if off:
            monkeypatch.setattr(trace_mod.Chain, "add", lambda *a, **k: None)
        env.client.post("/v1/daily", headers=env.H, json={"days": dip_days()})
        items = sorted((i["kind"], i["level"], i["state"]) for i in env.repo().items())
        sugs = [(s["action"], s["status"]) for s in env.repo().suggestions()]
        monkeypatch.undo()
        return items, sugs

    assert run(False) == run(True)
