"""The day reading: the level-2 model reads the daily numbers of the last weeks
(data/days_prompt.txt), code checks every item against the same numbers.
Clinician-only; behind the outside-processing consent; nothing else changes."""

import copy
import json
import re

import pytest

from clinic_engine.days_reference import KINDS, make_series
from clinic_engine.mind import day_reading as dr
from clinic_engine.mind.gates import INPUT_GATE, OUTPUT_GATE, GateError

from conftest import Env, Level2Recorder

ISO_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
SUSTAINED = make_series(3000, "sustained")   # planted: days 59 to 67
GRADUAL = make_series(3008, "gradual")       # planted: days 63 to 83; code's rule flags 69 to 77
QUIET = make_series(3016, "none")

GOOD = {"stretches": [{"start_d": 59, "end_d": 67, "channel": "steps", "direction": "lower",
                       "shape": "sustained"}],
        "weekly": [{"channel": "steps", "low_weekdays": [6, 7]}], "gaps": [],
        "overall": {"movement": "as_usual", "sleep": "as_usual", "confidence": "medium"}}


def reply(**changes):
    r = copy.deepcopy(GOOD)
    r.update(changes)
    return r


def check(model_reply, series=SUSTAINED):
    pack = INPUT_GATE.days_pack(series[0], {})
    text = model_reply if isinstance(model_reply, str) else json.dumps(model_reply)
    return OUTPUT_GATE.days_reading(text, pack)


def is_days_body(body) -> bool:
    return "You read several weeks of one person" in json.dumps(body.get("systemInstruction") or "")


def days_env(days_reply=GOOD, allow=True):
    def answer(body):
        if is_days_body(body):
            return days_reply if isinstance(days_reply, str) or days_reply is None \
                else json.dumps(days_reply)
        return json.dumps({"objections": []})
    rec = Level2Recorder(answer)
    env = Env(level2=rec)
    env.repo().put("patient.json", {**env.repo().patient(), "allow_outside_processing": allow})
    rec.requests.clear()
    return env, rec


def run(env):
    r = env.client.post("/v1/demo/analyze", headers=env.A,
                        json={"patient_id": env.demo["patient_id"], "what": "days"})
    assert r.status_code == 200, r.text
    return r.json()


# ---- the pack ----------------------------------------------------------------------------

def test_the_pack_holds_day_indexes_weekdays_and_rounded_numbers_only():
    days, _ = SUSTAINED
    health = {"HKQuantityTypeIdentifierRestingHeartRate": {"days": {d: 58.4 for d in days}},
              "HKQuantityTypeIdentifierBodyMass": {"days": {d: 81.0 for d in days}}}
    p = dr.reduce(days, health)
    assert list(p) == ["days", "channels", "rows"] and p["days"] == 84 == len(p["rows"])
    assert p["channels"] == ["d", "wd", "steps", "walk_speed", "sleep_h", "rest_hr"]  # no body mass
    assert p["rows"][0][:2] == [0, 1] and p["rows"][6][:2] == [6, 7] and p["rows"][7][1] == 1
    assert all(r[2] % 10 == 0 and r[5] == 58 for r in p["rows"])
    text = INPUT_GATE.days_pack(days, health).messages[1]["content"]
    assert not ISO_DATE.search(text)
    assert set(re.findall(r'"([^"]*)"', text)) <= set(dr.ORDER) | set(dr.PAYLOAD_KEYS)
    INPUT_GATE.check_days_outbound(p)
    # Too few days: nothing to send.
    assert dr.reduce(dict(list(days.items())[:10]), {}) is None
    # A gap stays in the stream as rows without values.
    g = dr.reduce(make_series(3022, "gap")[0], {})
    assert g["rows"][51][2:] == [None, None, None] and g["rows"][51][0] == 51


@pytest.mark.parametrize("mutate, reason", [
    (lambda p: p.update(alias="p-1"), "top_level_keys"),
    (lambda p: p["channels"].__setitem__(2, "weight"), "channel_not_allowed"),
    (lambda p: p["channels"].reverse(), "channel_order"),
    (lambda p: p["rows"][3].__setitem__(0, 20261114), "day_index_not_allowed"),
    (lambda p: p["rows"][3].__setitem__(1, 9), "weekday_not_allowed"),
    (lambda p: p["rows"][3].__setitem__(2, 7001.5), "value_not_allowed"),
    (lambda p: p["rows"][3].__setitem__(2, "many"), "value_not_a_number"),
    (lambda p: p["rows"][3].__setitem__(4, 30.0), "value_not_allowed"),
    (lambda p: p["rows"].pop(), "days_count"),
    (lambda p: p["rows"][3].append(1), "row_shape"),
])
def test_the_outbound_check_refuses_anything_else(mutate, reason):
    p = dr.reduce(SUSTAINED[0], {})
    mutate(p)
    with pytest.raises(GateError) as e:
        INPUT_GATE.check_days_outbound(p)
    assert e.value.refusal.reason == reason and e.value.refusal.task == "days_reading"


# ---- the checker -----------------------------------------------------------------------------

def test_a_stretch_code_also_found_is_the_same_and_an_invented_one_is_dropped():
    invented = {"start_d": 20, "end_d": 26, "channel": "steps", "direction": "lower",
                "shape": "sustained"}
    r = check(reply(stretches=GOOD["stretches"] + [invented]))
    assert r.ok
    k = r.value["reading"]["stretches"]
    assert [(s["start_d"], s["status"]) for s in k] == [(59, "same")] and k[0]["z"] <= -2
    assert r.value["dropped"] == [{"item": "stretch", **invented, "reason": "not_in_numbers"}]
    ag = r.value["agreement"]
    assert ag["stretches_same"] == 1 and ag["stretches_not_in_numbers"] == 1
    assert ag["stretch_precision"] == 0.5 and ag["stretch_recall"] == 1.0
    assert ag["weekdays_confirmed"] == 2 and ag["weekdays_missed"] == 0
    assert any(x.reason == "item_dropped:stretch:not_in_numbers" for x in r.refusals)


def test_a_slow_decline_the_fixed_rule_does_not_flag_is_kept_as_the_models_alone():
    view = dr.code_view(dr.reduce(GRADUAL[0], {}))
    assert [(s["start_d"], s["end_d"]) for s in view["stretches"]] == [(69, 77)]
    slow = {"start_d": 40, "end_d": 60, "channel": "sleep_h", "direction": "lower",
            "shape": "gradual"}
    whole = {"start_d": 63, "end_d": 83, "channel": "steps", "direction": "lower",
             "shape": "gradual"}
    r = check(reply(stretches=[whole, slow], weekly=[]), GRADUAL)
    k = r.value["reading"]["stretches"]
    # The whole decline overlaps code's piece of it by enough to be the same stretch.
    assert k[0]["status"] == "same" and k[0]["shape"] == "gradual" and k[0]["rho"] <= -0.5
    assert r.value["dropped"][0]["reason"] == "not_in_numbers"
    # Another person, a four-week slide: code's rule flags only short pieces of it
    # (and one stray run weeks earlier). The whole slide is the model's alone,
    # and code confirms it in the numbers.
    other = make_series(3009, "gradual")  # planted: days 56 to 83
    view = dr.code_view(dr.reduce(other[0], {}))
    assert [(s["start_d"], s["end_d"]) for s in view["stretches"]] == [(16, 18), (73, 76), (78, 80)]
    slide = {"start_d": 56, "end_d": 83, "channel": "steps", "direction": "lower",
             "shape": "gradual"}
    r = check(reply(stretches=[slide], weekly=[]), other)
    k = r.value["reading"]["stretches"][0]
    assert k["status"] == "model_only" and k["days"] == 28 and k["rho"] <= -0.5
    assert r.value["agreement"]["stretches_model_only"] == 1
    assert r.value["agreement"]["stretches_missed"] == 3
    assert r.value["agreement"]["stretch_precision"] is None


def test_weekdays_gaps_repeats_and_short_stretches():
    r = check(reply(weekly=[{"channel": "steps", "low_weekdays": [3, 6]}],
                    stretches=GOOD["stretches"] * 2 + [
                        {"start_d": 60, "end_d": 61, "channel": "steps", "direction": "lower",
                         "shape": "sustained"},
                        {"start_d": 60, "end_d": 66, "channel": "hrv", "direction": "lower",
                         "shape": "sustained"}],
                    gaps=[{"start_d": 30, "end_d": 33}]))
    assert r.value["reading"]["weekly"] == [{"channel": "steps", "low_weekdays": [6],
                                              "not_confirmed": [3]}]
    assert r.value["reading"]["weekly_missed"] == {"steps": [7]}
    assert [d["reason"] for d in r.value["dropped"]] == [
        "same_stretch_twice", "too_short", "channel_missing", "days_have_data"]
    g = check(reply(stretches=[], weekly=[], gaps=[{"start_d": 50, "end_d": 53}]),
              make_series(3022, "gap"))
    assert g.value["reading"]["gaps"] == [{"start_d": 50, "end_d": 53, "status": "confirmed"}]
    # A quiet series: a reported dip is not in the numbers.
    q = check(reply(weekly=[]), QUIET)
    assert q.value["reading"]["stretches"] == [] and q.value["agreement"]["stretches_code"] == 0


@pytest.mark.parametrize("bad, reason", [
    ("She seems to be doing worse lately.", "not_json_object"),
    (json.dumps({**GOOD, "mood": "low"}), "schema:extra_forbidden"),
    (json.dumps({k: v for k, v in GOOD.items() if k != "gaps"}), "schema:missing"),
    (json.dumps(reply(stretches=[{**GOOD["stretches"][0], "end_d": 200}])), "day_outside_window"),
    (json.dumps(reply(stretches=[{**GOOD["stretches"][0], "end_d": 40}])), "end_before_start"),
    (json.dumps(reply(weekly=[{"channel": "steps", "low_weekdays": [0]}])), "weekday_not_1_to_7"),
    (json.dumps(reply(stretches=[{**GOOD["stretches"][0], "channel": "mood"}])),
     "schema:literal_error"),
])
def test_unusable_replies_are_refused(bad, reason):
    r = check(bad)
    assert not r.ok and r.refusals[0].reason.startswith(reason)


# ---- the whole path --------------------------------------------------------------------------

def test_the_reading_is_stored_for_the_clinician_and_nothing_else_changes():
    quiet = {"stretches": [], "weekly": [], "gaps": [],
             "overall": {"movement": "as_usual", "sleep": "unclear", "confidence": "low"}}
    env, rec = days_env(quiet)
    before = env.client.get("/v1/today", headers=env.H).json()
    out = run(env)
    assert out["status"] == "ready" and out["read_by"] == "level2" and out["checked_by"] == "code"
    body = [b for _h, b, _u in rec.requests if is_days_body(b)]
    assert len(body) == 1
    assert body[0]["generationConfig"]["responseSchema"] == dr.RESPONSE_SCHEMA
    sent = body[0]["contents"][0]["parts"][0]["text"]
    d = env.demo
    for ident in (d["patient_id"], d["clinic_id"], "Patient", "alias"):
        assert ident not in json.dumps(body[0])
    assert not ISO_DATE.search(sent)
    pid = d["patient_id"]
    det = env.client.get(f"/v1/clinic/patients/{pid}", headers=env.C()).json()
    f = det["days_reading"]
    assert f["status"] == "ready" and f["agreement"]["stretches_reported"] == 0
    assert f["stream"]["first_date"] and f["stream"]["rows"] == json.loads(sent)["rows"]
    assert det["health_types"] == []
    # Trace and audit: counts and codes only.
    t = env.client.get(f"/v1/clinic/patients/{pid}/trace?changed_only=false&limit=100",
                       headers=env.C()).json()
    l2 = [e for c in t["chains"] if c["trigger"] == "days_reading" for e in c["entries"]
          if e["layer"] == "level2"]
    assert l2 and l2[0]["code"] == "accepted" and l2[0]["detail"]["days"] == f["stream"]["days"]
    assert json.dumps(f["stream"]["rows"][5]) not in json.dumps(t)
    assert [e for e in env.audit() if e["action"] == "days_reading"]
    # The patient side is the same as before.
    assert env.client.get("/v1/today", headers=env.H).json() == before
    assert "days_reading" not in json.dumps(before)


def test_no_consent_or_level2_off_sends_nothing():
    env, rec = days_env(allow=False)
    assert run(env) == {"status": "not_allowed"}
    assert not [b for _h, b, _u in rec.requests if is_days_body(b)]
    det = env.client.get(f"/v1/clinic/patients/{env.demo['patient_id']}", headers=env.C()).json()
    assert det["days_reading"]["status"] == "not_allowed" and det["days_reading"]["stream"] is None
    off = Env()
    assert off.client.post("/v1/demo/analyze", headers=off.A, json={
        "patient_id": off.demo["patient_id"], "what": "days"}).json() == {"status": "off"}


def test_new_days_bring_a_new_reading_at_most_every_few_hours():
    env, rec = days_env()
    from datetime import timedelta
    from conftest import NOW
    day = {"date": (NOW.date() - timedelta(days=1)).isoformat(), "steps": 5005}
    assert env.client.post("/v1/daily", headers=env.H, json={"days": [day]}).status_code == 200
    assert len([b for _h, b, _u in rec.requests if is_days_body(b)]) == 1
    day["steps"] = 5010
    assert env.client.post("/v1/daily", headers=env.H, json={"days": [day]}).status_code == 200
    assert len([b for _h, b, _u in rec.requests if is_days_body(b)]) == 1  # not again so soon


# ---- the reference set ----------------------------------------------------------------------

def test_the_reference_set_is_fixed_and_the_fixed_rule_misses_most_slow_declines():
    import asyncio
    from clinic_engine import days_reference as ref
    assert make_series(3003, "sustained") == make_series(3003, "sustained")
    out = asyncio.run(ref.run(False))
    assert out["series"] == len(KINDS) == 24
    code = out["code_vs_truth"]
    assert code["sustained_found"] == code["sustained_planted"] == 8
    assert code["gradual_found"] < code["gradual_planted"] == 8
    assert out["weekday"]["planted"] == 35 and out["weekday"]["code"] >= 33
    # A reader that names every planted span: code's check keeps every one.
    for k, kind in enumerate(KINDS):
        days, truth = make_series(3000 + k, kind)
        said = reply(stretches=[{**t, "channel": "steps", "direction": "lower"} for t in truth],
                     weekly=[])
        res = check(said, (days, truth))
        assert len(res.value["reading"]["stretches"]) == len(truth), (k, kind)
