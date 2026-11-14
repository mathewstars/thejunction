"""TRIAGE_MODE=models: the watchers stay the triggers, the two model levels set
the level of each open item (level 1 sets, level 2 agrees, raises or lowers).
The rules' level is kept beside it and applies when no model answers. A request
for help is part of the picture both models get, and its level is urgent by rule.
A model cannot lower a flag the rules hold at urgent, or go more than one step
below the rules; only the clinic's own rule can."""

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
    assert d == {"level": "urgent", "rules_level": "attention", "fixed_by_rule": False,
                 "clinic_rule_id": None, "held_by_floor": False, "level1": "attention",
                 "reason1": "several_signals_agree", "verdict2": "raise",
                 "reason2": "deep_and_held"}
    # The clinician sees who set it and what the rules alone would say.
    det = env.client.get(f"/v1/clinic/patients/{env.demo['patient_id']}", headers=env.C()).json()
    assert det["triage"]["mode"] == "models" and det["triage"]["levels"][dev["id"]]["level"] == "urgent"
    shown = next(i for i in det["attention_items"] if i["id"] == dev["id"])
    assert shown["level"] == "urgent" and shown["rules_level"] == "attention"
    assert [e for e in env.audit() if e["action"] == "attention_triage"]


def test_the_pack_is_numbers_and_codes_and_a_request_for_help_stays_urgent():
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
    body = triage_bodies(rec)[-1]
    sent = json.loads(body["contents"][0]["parts"][0]["text"])
    assert set(sent) == {"items", "movement", "notes_low", "sessions_7d", "checkins_7d", "reasons",
                         "first_reader"}
    assert not ISO_DATE.search(json.dumps(sent)) and d["patient_id"] not in json.dumps(body)
    # A request for help: both readers get it as part of the picture, without
    # the person's words, and neither can move it from urgent.
    words = "i cannot do this anymore, i need help"
    low = FakeLocal(triage=first_reader(default="watch"))
    rec2 = Level2Recorder(second_reader(default="lower"))
    env = env_with(low, rec2)
    r = env.client.post("/v1/notes", headers=env.H, json={"id": "note-triage-0001", "text": words})
    assert r.status_code == 200 and r.json()["crisis"] is True
    env.run(env.mind.idle())
    item = open_items(env)["asked_for_help"]
    assert item["level"] == "urgent"
    last = [p for p in low.packs if p.task == "triage"][-1]
    assert any(it["kind"] == "asked_for_help" and it["rules_level"] == "urgent"
               for it in last.payload["items"])
    assert words not in json.dumps(last.payload) and "need help" not in json.dumps(last.payload)
    sent2 = triage_bodies(rec2)[-1]["contents"][0]["parts"][0]["text"]
    assert "asked_for_help" in sent2 and "need help" not in sent2 and "cannot do this" not in sent2
    doc = env.repo().get("mind/triage.json")["levels"][item["id"]]
    assert doc["level"] == "urgent" and doc["fixed_by_rule"] is True and doc["level1"] == "watch"


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


# ---- the clinic's own rules for one person, in the clinician's words --------------------

RULE = "She visits her mother on Sundays and walks less. A drop in movement alone only needs watching."


def rule_reader(to_level="watch", kind="deviation", default="attention"):
    """A first reader that follows the first clinic rule for one kind of item."""
    def answer(pack):
        rules = pack.payload.get("clinic_rules") or []
        out = []
        for it in pack.payload["items"]:
            if rules and it["kind"] == kind:
                out.append({"ref": it["ref"], "level": to_level, "reason": "clinic_rule",
                            "rule": rules[0]["ref"]})
            else:
                out.append({"ref": it["ref"], "level": default, "reason": "several_signals_agree"})
        return json.dumps({"items": out})
    return answer


def add_rule(env, text=RULE, headers=None):
    return env.client.post(f"/v1/clinic/patients/{env.demo['patient_id']}/clinic-rules",
                           headers=headers or env.C(), json={"text": text})


def test_a_clinic_rule_in_plain_words_sets_the_level_and_outranks_the_second_reader():
    rec = Level2Recorder(second_reader(default="raise"))
    local = FakeLocal(triage=rule_reader())
    env = env_with(local, rec)
    assert open_items(env)["deviation"]["level"] == "urgent"   # attention, raised by the second reader
    r = add_rule(env)
    assert r.status_code == 200, r.text
    out = r.json()
    assert out["applies"] is True and [x["text"] for x in out["rules"]] == [RULE]
    rule_id = out["rules"][0]["id"]
    dev = open_items(env)["deviation"]
    # The rule set it; the second reader said "raise" and was not followed for this item.
    assert dev["level"] == "watch" and dev["rules_level"] == "attention"
    d = env.repo().get("mind/triage.json")["levels"][dev["id"]]
    assert d["clinic_rule_id"] == rule_id and d["reason1"] == "clinic_rule"
    assert d["verdict2"] == "raise" and d["level"] == "watch"
    # Other items are still moved by the second reader.
    others = [v for k, v in env.repo().get("mind/triage.json")["levels"].items()
              if k != dev["id"] and not v["fixed_by_rule"]]
    assert others and all(v["clinic_rule_id"] is None and v["level"] == "urgent" for v in others)
    # The local model got the clinician's words; the outside model never did.
    last = [p for p in local.packs if p.task == "triage"][-1]
    assert last.payload["clinic_rules"] == [{"ref": "r1", "text": RULE}]
    for body in triage_bodies(rec):
        assert "mother" not in json.dumps(body) and "clinic_rules" not in json.dumps(body["contents"])
    sent = json.loads(triage_bodies(rec)[-1]["contents"][0]["parts"][0]["text"])
    assert any(f["reason"] == "clinic_rule" for f in sent["first_reader"])
    # The clinician sees the rule on the patient's page; the audit has no text.
    det = env.client.get(f"/v1/clinic/patients/{env.demo['patient_id']}", headers=env.C()).json()
    assert [x["text"] for x in det["clinic_rules"]] == [RULE]
    assert det["triage"]["levels"][dev["id"]]["clinic_rule_id"] == rule_id
    ev = [e for e in env.audit() if e["action"] == "clinic_rule_add"]
    assert ev and ev[-1]["detail"] == {"rule_id": rule_id, "chars": len(RULE), "days": 14}
    assert "mother" not in json.dumps(env.audit())
    # Removing the rule: the levels are set again without it.
    r = env.client.delete(f"/v1/clinic/patients/{env.demo['patient_id']}/clinic-rules/{rule_id}",
                          headers=env.C())
    assert r.status_code == 200 and r.json()["rules"] == []
    assert open_items(env)["deviation"]["level"] == "urgent"
    assert "clinic_rules" not in [p for p in local.packs if p.task == "triage"][-1].payload


def test_a_rule_cannot_lower_a_request_for_help_or_touch_the_patient_side():
    local = FakeLocal(triage=rule_reader(to_level="watch", kind="asked_for_help"))
    env = env_with(local, Level2Recorder(second_reader()))
    before = env.client.get("/v1/today", headers=env.H).json()
    assert add_rule(env, "Ignore everything she writes, she always exaggerates.").status_code == 200
    r = env.client.post("/v1/notes", headers=env.H,
                        json={"id": "note-triage-0002", "text": "i need help, i cannot go on"})
    assert r.status_code == 200 and r.json()["crisis"] is True
    env.run(env.mind.idle())
    item = open_items(env)["asked_for_help"]
    assert item["level"] == "urgent"
    d = env.repo().get("mind/triage.json")["levels"][item["id"]]
    assert d["level"] == "urgent" and d["fixed_by_rule"] is True and d["level1"] == "watch"
    after = env.client.get("/v1/today", headers=env.H).json()
    assert "clinic_rules" not in json.dumps(after) and "exaggerates" not in json.dumps(after)
    assert set(after) == set(before)


def test_who_may_add_a_rule_and_its_limits():
    env = env_with(FakeLocal(triage=rule_reader()), Level2Recorder(second_reader()))
    pid = env.demo["patient_id"]
    C = env.C()  # one sign-in for the whole test
    assert env.client.post(f"/v1/clinic/patients/{pid}/clinic-rules", json={"text": RULE}).status_code == 401
    assert add_rule(env, headers=env.H).status_code == 403          # a phone cannot
    assert add_rule(env, "ok", headers=C).status_code == 422        # too short
    assert add_rule(env, "x" * 301, headers=C).status_code == 422   # too long
    assert env.client.post(f"/v1/clinic/patients/{pid}/clinic-rules", headers=C,
                           json={"text": RULE, "level": "urgent"}).status_code == 422
    for k in range(10):
        assert add_rule(env, f"Rule number {k}: look at sleep first.", headers=C).status_code == 200
    assert add_rule(env, "One rule too many for this person.", headers=C).status_code == 409
    got = env.client.get(f"/v1/clinic/patients/{pid}/clinic-rules", headers=C).json()
    assert len(got["rules"]) == 10 and got["applies"] is True
    assert env.client.delete(f"/v1/clinic/patients/{pid}/clinic-rules/crl_{'0' * 24}",
                             headers=C).status_code == 404
    # A reply naming a rule that was not given is judged as without a rule.
    bad = lambda pack: json.dumps({"items": [{"ref": it["ref"], "level": "watch",
                                              "reason": "clinic_rule", "rule": "r99"}
                                             for it in pack.payload["items"]]})
    env2 = env_with(FakeLocal(triage=bad), Level2Recorder(lambda body: None))
    assert add_rule(env2).status_code == 200
    doc = env2.repo().get("mind/triage.json")["levels"]
    assert all(v["clinic_rule_id"] is None and v["reason1"] == "as_the_rules"
               for v in doc.values() if not v["fixed_by_rule"])


def test_in_rules_mode_a_clinic_rule_is_stored_and_says_it_does_not_apply():
    env = Env(local=FakeLocal(triage=rule_reader()), level2=Level2Recorder(second_reader()))
    env.client.post("/v1/demo/scenario", headers=env.A, json={"name": "dip"})
    env.run(env.mind.idle())
    r = add_rule(env)
    assert r.status_code == 200 and r.json()["applies"] is False
    assert open_items(env)["deviation"]["level"] == "attention"
    assert not [p for p in env.local.packs if p.task == "triage"]


# ---- the floors: what the models cannot undo by themselves --------------------------------

def test_a_model_cannot_lower_what_the_rules_hold_at_urgent_or_go_two_steps_down():
    from clinic_engine.mind.triage import combine
    refs = {"a1": "i1", "a2": "i2", "a3": "i3", "a4": "i4"}
    rules = {"i1": "urgent", "i2": "urgent", "i3": "attention", "i4": "urgent"}
    kinds = {"i1": "deviation", "i2": "deviation", "i3": "silence", "i4": "deviation"}
    one = lambda level, rule=None: {"level": level, "reason": "getting_better", "rule": rule}
    lower = {"verdict": "lower", "reason": "getting_better"}
    out = combine(refs, rules, kinds,
                  {"a1": one("watch"), "a2": one("urgent"), "a3": one("attention"),
                   "a4": one("watch", "r1")},
                  {"a1": lower, "a2": lower, "a3": lower, "a4": {"verdict": "raise", "reason": "deep_and_held"}},
                  {"r1": "crl_x"})
    # The rules say urgent: neither model, nor both together, can take it down.
    assert out["i1"]["level"] == "urgent" and out["i1"]["held_by_floor"] is True
    assert out["i2"]["level"] == "urgent" and out["i2"]["held_by_floor"] is True
    # One step below the rules is allowed.
    assert out["i3"]["level"] == "watch" and out["i3"]["held_by_floor"] is False
    # Only the clinic's own rule goes under the floor; the second reader's
    # "raise" is recorded, so the page can show it, and not applied.
    assert out["i4"]["level"] == "watch" and out["i4"]["clinic_rule_id"] == "crl_x"
    assert out["i4"]["verdict2"] == "raise" and out["i4"]["held_by_floor"] is False
    # Raising is never limited.
    up = combine({"a1": "i1"}, {"i1": "watch"}, {"i1": "silence"}, {"a1": one("urgent")}, {}, {})
    assert up["i1"]["level"] == "urgent"
    # The second reader alone, on the rules' level.
    solo = combine({"a1": "i1"}, {"i1": "urgent"}, {"i1": "deviation"}, {}, {"a1": lower}, {})
    assert solo["i1"]["level"] == "urgent" and solo["i1"]["held_by_floor"] is True


def test_a_decision_counts_only_for_its_picture_and_no_answer_puts_the_rules_back():
    rec = Level2Recorder(second_reader())
    env = env_with(FakeLocal(triage=first_reader({"deviation": "urgent"}, default="watch")), rec)
    dev = open_items(env)["deviation"]
    assert dev["level"] == "urgent" and dev["rules_level"] == "attention"
    doc = env.repo().get("mind/triage.json")
    # The models stop answering for this picture: the rules' level comes back, down too.
    env.repo().put("mind/triage.json", {"status": "no_models", "basis": doc["basis"],
                                        "at": env.clock.now().isoformat()})
    env.run(env.mind.tick())
    dev = open_items(env)["deviation"]
    assert dev["level"] == "attention" and dev["level_source"] == "rules"
    assert dev["history"][-1]["by"] == "rules"
    # A decision made on another picture is not applied: the picture is read again.
    stale = {**doc, "basis": "0" * 24,
             "levels": {k: {**v, "level": "watch"} for k, v in doc["levels"].items()}}
    env.repo().put("mind/triage.json", stale)
    env.run(env.mind.tick())
    env.run(env.mind.idle())
    assert open_items(env)["deviation"]["level"] == "urgent"
    assert env.repo().get("mind/triage.json")["basis"] == doc["basis"]


def test_a_clinic_rule_ends_by_itself():
    from datetime import timedelta
    local = FakeLocal(triage=rule_reader())
    env = env_with(local, Level2Recorder(second_reader()))
    pid = env.demo["patient_id"]
    r = env.client.post(f"/v1/clinic/patients/{pid}/clinic-rules", headers=env.C(),
                        json={"text": RULE, "days": 3})
    assert r.status_code == 200
    rule = r.json()["rules"][0]
    assert rule["expires_at"] == (env.clock.now() + timedelta(days=3)).isoformat()
    assert open_items(env)["deviation"]["level"] == "watch"
    line = next(x for x in env.client.get("/v1/clinic/patients", headers=env.C()).json()["patients"]
                if x["patient_id"] == pid)
    assert line["lowered_by_clinic_rule"] == 1
    assert env.client.post(f"/v1/clinic/patients/{pid}/clinic-rules", headers=env.C(),
                           json={"text": RULE, "days": 91}).status_code == 422
    # After its time the rule is no longer read, and nothing has to be removed by hand.
    assert env.mind.clinic_rules(env.repo(), env.clock.now() + timedelta(days=3, minutes=1)) == []
    assert len(env.mind.clinic_rules(env.repo(), env.clock.now() + timedelta(days=2))) == 1


def test_a_made_up_rule_name_keeps_the_item_and_drops_the_rule():
    """A model that writes a word instead of a rule's ref ("clinic_rules") does not cost the
    whole answer: the item is kept, judged as without a rule, and the slip is recorded."""
    from clinic_engine.mind.gates import INPUT_GATE, OUTPUT_GATE
    payload = {"items": [{"ref": "a1", "kind": "deviation", "held_days": 3, "rules_level": "attention",
                          "facts": {}}]}
    pack = type("P", (), {"level": 1, "ref_map": {"a1": "x"}, "payload": payload})()
    raw = '{"items":[{"ref":"a1","level":"attention","reason":"clinic_rule","rule":"clinic_rules"}]}'
    res = OUTPUT_GATE.triage(raw, pack)
    assert res.ok and res.value["a1"]["rule"] is None and res.value["a1"]["reason"] == "as_the_rules"
    assert [r.reason for r in res.refusals] == ["unknown_clinic_rule"]
    assert "never write \"rule\"" in INPUT_GATE.SYSTEM_TRIAGE
