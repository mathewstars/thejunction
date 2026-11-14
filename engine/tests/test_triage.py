"""TRIAGE_MODE=models: the watchers stay the triggers, the two model levels set
the level of each open item (level 1 sets, level 2 agrees, raises or lowers).
The rules' level is kept beside it and applies when no model answers; a request
for help is urgent by rule and is never sent to a model."""

import json
import re

from conftest import Env, FakeLocal, Level2Recorder

ISO_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")


def first_reader(levels=None, default="attention", reason="several_signals_agree"):
    def answer(pack):
        return json.dumps({"items": [
            {"ref": it["ref"], "level": (levels or {}).get(it["kind"], default), "reason": reason}
            for it in pack.payload["items"]]})
    return answer


def second_reader(verdicts=None, default="agree"):
    def answer(body):
        text = json.dumps(body.get("systemInstruction") or "")
        if "You are the second reader" not in text:
            return json.dumps({"objections": []})
        data = json.loads(body["contents"][0]["parts"][0]["text"])
        return json.dumps({"items": [
            {"ref": it["ref"], "verdict": (verdicts or {}).get(it["kind"], default),
             "reason": "deep_and_held"} for it in data["items"]]})
    return answer


def env_with(local, level2, allow=True):
    env = Env(local=local, level2=level2, triage_mode="models")
    env.repo().put("patient.json", {**env.repo().patient(), "allow_outside_processing": allow})
    r = env.client.post("/v1/demo/scenario", headers=env.A, json={"name": "dip"})
    assert r.status_code == 200, r.text
    env.run(env.mind.idle())
    return env


def open_items(env):
    return {i["kind"]: i for i in env.repo().items() if i["state"] == "open"}


def triage_bodies(rec):
    return [b for _h, b, _u in rec.requests
            if "You are the second reader" in json.dumps(b.get("systemInstruction") or "")]


def test_the_two_model_levels_set_the_level_up_and_down():
    rec = Level2Recorder(second_reader({"deviation": "raise"}))
    env = env_with(FakeLocal(triage=first_reader({"deviation": "attention"}, default="watch")), rec)
    items = open_items(env)
    dev = items["deviation"]
    # Level 1 said attention, level 2 raised it by one step.
    assert dev["level"] == "urgent" and dev["level_source"] == "models"
    assert dev["rules_level"] == "attention"
    assert dev["history"][-1] == {"at": dev["level_changed_at"], "event": "level",
                                  "level": "urgent", "by": "models"}
    # An item the rules hold at attention can be set lower by the models.
    lowered = [i for k, i in items.items() if k != "deviation" and i.get("rules_level") == "attention"]
    assert lowered and all(i["level"] == "watch" for i in lowered)
    doc = env.repo().get("mind/triage.json")
    assert doc["status"] == "ready" and doc["models"]["level2"] == "test-model"
    d = doc["levels"][dev["id"]]
    assert d == {"level": "urgent", "rules_level": "attention", "level1": "attention",
                 "reason1": "several_signals_agree", "verdict2": "raise",
                 "reason2": "deep_and_held"}
    # The clinician sees who set it and what the rules alone would say.
    det = env.client.get(f"/v1/clinic/patients/{env.demo['patient_id']}", headers=env.C()).json()
    assert det["triage"]["mode"] == "models" and det["triage"]["levels"][dev["id"]]["level"] == "urgent"
    shown = next(i for i in det["attention_items"] if i["id"] == dev["id"])
    assert shown["level"] == "urgent" and shown["rules_level"] == "attention"
    assert [e for e in env.audit() if e["action"] == "attention_triage"]


def test_the_pack_is_numbers_and_codes_and_help_is_never_sent():
    rec = Level2Recorder(second_reader())
    local = FakeLocal(triage=first_reader())
    env = env_with(local, rec)
    packs = [p for p in local.packs if p.task == "triage"]
    assert packs
    text = json.dumps(packs[-1].payload)
    d = env.demo
    for ident in (d["patient_id"], d["clinic_id"], "att_", "Patient"):
        assert ident not in text
    assert not ISO_DATE.search(text)
    assert "asked_for_help" not in text
    body = triage_bodies(rec)[-1]
    sent = json.loads(body["contents"][0]["parts"][0]["text"])
    assert set(sent) == {"items", "movement", "notes_low", "sessions_7d", "checkins_7d", "reasons",
                         "first_reader"}
    assert not ISO_DATE.search(json.dumps(sent)) and d["patient_id"] not in json.dumps(body)
    # A request for help: urgent by rule, whatever the models say, and not in the pack.
    r = env.client.post("/v1/notes", headers=env.H, json={"id": "note-triage-0001", "text": "i cannot do this anymore, i need help"})
    assert r.status_code == 200, r.text
    env.run(env.mind.idle())
    items = open_items(env)
    assert items["asked_for_help"]["level"] == "urgent"
    assert all("asked_for_help" not in json.dumps(p.payload) for p in local.packs if p.task == "triage")


def test_no_model_answer_leaves_the_rules_level_and_one_reader_is_enough():
    # Neither reader answers: the rules' levels stand.
    env = env_with(FakeLocal(), Level2Recorder(lambda body: None))
    dev = open_items(env)["deviation"]
    assert dev["level"] == "attention" and dev.get("level_source") is None
    assert env.repo().get("mind/triage.json")["status"] == "no_models"
    # Only the second reader answers: it moves the rules' level by one step.
    env = env_with(FakeLocal(), Level2Recorder(second_reader({"deviation": "raise"})))
    assert open_items(env)["deviation"]["level"] == "urgent"
    # No consent: nothing goes outside; the first reader alone decides.
    rec = Level2Recorder(second_reader({"deviation": "raise"}))
    env = env_with(FakeLocal(triage=first_reader(default="watch")), rec, allow=False)
    assert open_items(env)["deviation"]["level"] == "watch"
    assert not triage_bodies(rec)


def test_a_reply_outside_the_form_is_refused_and_the_picture_is_not_read_twice():
    bad = lambda pack: json.dumps({"items": [{"ref": "a1", "level": "severe depression",
                                              "reason": "several_signals_agree"}]})
    env = env_with(FakeLocal(triage=bad), Level2Recorder(lambda body: None))
    assert open_items(env)["deviation"]["level"] == "attention"
    assert [e for e in env.audit(outcome="refused") if (e.get("detail") or {}).get("task") == "triage"
            or e.get("action") == "triage"]
    # The same picture is not sent again: one triage per change.
    rec = Level2Recorder(second_reader())
    local = FakeLocal(triage=first_reader())
    env = env_with(local, rec)
    n = len([p for p in local.packs if p.task == "triage"])
    env.client.get("/v1/today", headers=env.H)
    env.run(env.mind.tick())
    assert len([p for p in local.packs if p.task == "triage"]) == n


def test_rules_mode_is_unchanged():
    rec = Level2Recorder(second_reader({"deviation": "raise"}))
    env = Env(local=FakeLocal(triage=first_reader(default="watch")), level2=rec)
    env.repo().put("patient.json", {**env.repo().patient(), "allow_outside_processing": True})
    env.client.post("/v1/demo/scenario", headers=env.A, json={"name": "dip"})
    env.run(env.mind.idle())
    dev = open_items(env)["deviation"]
    assert dev["level"] == "attention" and "rules_level" not in dev
    assert env.repo().get("mind/triage.json") is None and not triage_bodies(rec)
