"""The `sensors` block (docs/sensors.md): the Apple Watch's heart data and the game
moments arrive with the activity, the server checks and summarizes them, keeps the
rows outside the record and every pack, and the level-2 sensor reading reads them
behind the outside-processing consent, with every item checked by code."""

import json
import re
from datetime import timedelta

from clinic_engine.mind import sensor_reading as sr
from clinic_engine.mind.gates import INPUT_GATE, GateError
from clinic_engine.mind.sensors import check_sensors, summarize

from conftest import NOW, Env, Level2Recorder

ISO_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
AID = "act-watch-00001"


def heart(start_s=-10, end_s=44, step_s=2.0, start_bpm=70.0, end_bpm=86.0):
    """Rows [t_ms, bpm], a straight rise from start to end."""
    rows, t = [], float(start_s)
    while t <= end_s:
        frac = (t - start_s) / (end_s - start_s)
        rows.append([int(t * 1000), round(start_bpm + (end_bpm - start_bpm) * frac, 1)])
        t += step_s
    return rows


def focus_moments():
    out = [{"name": "focus_started", "t_ms": 0, "wall_ms": 0}]
    for i in range(17):
        out.append({"name": "spark_caught", "t_ms": 2000 + i * 2400, "wall_ms": 2001 + i * 2400,
                    "value": 500 + 7 * i})
    out += [{"name": "snow_tapped", "t_ms": 14000, "wall_ms": 14000},
            {"name": "spark_missed", "t_ms": 20500, "wall_ms": 20501},
            {"name": "spark_missed", "t_ms": 33100, "wall_ms": 33100},
            {"name": "focus_ended", "t_ms": 45000, "wall_ms": 45002, "value": 1}]
    return out


def sensors(hr=None, hrv=None, moments=None, face_offset=None, watch=True):
    block = {"clock": {"started_uptime_s": 48213.412},
             "heart_rate": heart() if hr is None else hr,
             "hrv_sdnn": hrv if hrv is not None else [],
             "moments": focus_moments() if moments is None else moments}
    if watch:
        block["watch"] = {"source": "apple_watch", "workout": True, "started_ms": -8200}
    if face_offset is not None:
        block["face_offset_ms"] = face_offset
    return block


def focus(aid=AID, minutes_ago=30, block=None, **kw):
    rec = {"id": aid, "type": "focus",
           "started_at": (NOW - timedelta(minutes=minutes_ago)).isoformat(),
           "duration_s": 45.0, "completed": True, "ended_by": "finished",
           "correct_taps": 17, "wrong_taps": 1, "misses": 2,
           "reaction_ms": [500 + 7 * i for i in range(17)],
           "sensors": sensors() if block is None else block}
    rec.update(kw)
    return rec


def breathing(aid="act-watch-br001", minutes_ago=20, hr=None):
    moments = [{"name": "breathe_started", "t_ms": 0, "wall_ms": 0}]
    for n in range(1, 7):
        base = 2000 + (n - 1) * 11000
        moments += [{"name": "breath_in", "t_ms": base, "wall_ms": base, "value": n},
                    {"name": "breath_hold", "t_ms": base + 4000, "wall_ms": base + 4000, "value": n},
                    {"name": "breath_out", "t_ms": base + 5500, "wall_ms": base + 5500, "value": n}]
    moments.append({"name": "breathe_ended", "t_ms": 68000, "wall_ms": 68001, "value": 1})
    block = sensors(hr=hr if hr is not None else heart(-5, 68, 2.0, 80.0, 70.0), moments=moments)
    return {"id": aid, "type": "breathing",
            "started_at": (NOW - timedelta(minutes=minutes_ago)).isoformat(),
            "duration_s": 68.0, "completed": True, "ended_by": "finished", "time_played_s": 68.0,
            "breaths_completed": 6, "sensors": block}


def post(env, rec):
    return env.client.post("/v1/activities", headers=env.H, json=rec)


GOOD = {"heart_rate": {"trend": "rising", "start_bpm": 73.0, "end_bpm": 86.0, "peak_bpm": 86.0,
                       "peak_at_s": 44.0},
        "around_moments": [{"moment": "focus_started", "heart_rate": "lower"},
                           {"moment": "spark_caught", "heart_rate": "same"},
                           {"moment": "snow_tapped", "heart_rate": "same"},
                           {"moment": "spark_missed", "heart_rate": "same"},
                           {"moment": "focus_ended", "heart_rate": "unclear"}],
        "breathing_pattern": "not_applicable", "hrv": "none", "face_and_heart": "unclear",
        "data_quality": "good", "confidence": "medium"}


# ---- the record ---------------------------------------------------------------------------

def test_sensors_are_accepted_summarized_and_kept_outside_the_record(env):
    rec = focus()
    r = post(env, rec)
    assert r.status_code == 200, r.text
    assert r.json()["xp_gained"] == 10
    stored = env.repo().get(f"activities/{AID}.json")
    assert "sensors" not in stored
    s = stored["sensors_summary"]
    assert s["source"] == "apple_watch" and s["watch_started_s"] == -8.2
    hr = s["heart_rate"]
    assert hr["samples"] == 28 and hr["samples_in_activity"] == 23
    assert hr["before_start_bpm"] is not None and hr["trend"] == "rising"
    assert hr["first_bpm"] < hr["last_bpm"] and hr["change_bpm"] > 3
    assert hr["max_bpm"] == 86.0 and hr["max_at_s"] == 44.0
    assert s["hrv_sdnn"] == {"samples": 0, "latest_ms": None, "latest_at_s": None, "mean_ms": None}
    assert s["moments"]["count"] == 22 and s["moments"]["by_name"]["spark_caught"] == 17
    assert s["moments"]["heart_rate_after"]["spark_caught"]["n"] == 17
    assert s["moments"]["max_clock_drift_ms"] == 2
    assert s["alignment"] == {"started_uptime_s": 48213.412, "face_offset_ms": None,
                              "moments_on_face_clock": False}
    assert stored["sensors_info"] == {"heart_rate_samples": 28, "hrv_samples": 0, "moments": 22,
                                      "watch": True}
    # The rows: their own object, as sent, plus counts.
    block = env.repo().get(f"sensors/{AID}.json")
    assert block["heart_rate"] == rec["sensors"]["heart_rate"]
    # The block keeps the model's full shape (absent fields as null), the rows unchanged.
    kept = [{k: v for k, v in m.items() if v is not None} for m in block["moments"]]
    assert kept == rec["sensors"]["moments"] and block["activity_id"] == AID
    assert block["counts"] == {"heart_rate_samples": 28, "hrv_samples": 0, "moments": 22, "watch": True}
    # Without Gemini the reading is off; the clinician sees the summary.
    assert stored["sensor_reading"] == {"status": "off"}
    d = env.client.get(f"/v1/clinic/patients/{env.demo['patient_id']}", headers=env.C()).json()
    sess = next(x for x in d["activities"]["focus"]["sessions"] if x["id"] == AID)
    assert sess["sensors"]["heart_rate"]["trend"] == "rising"
    assert sess["sensors"]["moments"]["count"] == 22
    assert sess["sensor_reading"]["status"] == "off"


def test_the_same_record_again_earns_nothing_and_a_plain_record_is_unchanged(env):
    assert post(env, focus()).status_code == 200
    r = post(env, focus())
    assert r.status_code == 200 and r.json()["xp_gained"] == 0
    plain = {k: v for k, v in focus("act-watch-plain1").items() if k != "sensors"}
    r = post(env, plain)
    assert r.status_code == 200
    stored = env.repo().get("activities/act-watch-plain1.json")
    assert "sensors_summary" not in stored and "sensor_reading" not in stored
    d = env.client.get(f"/v1/clinic/patients/{env.demo['patient_id']}", headers=env.C()).json()
    sess = next(x for x in d["activities"]["focus"]["sessions"] if x["id"] == "act-watch-plain1")
    assert sess["sensors"] is None and sess["sensor_reading"]["status"] == "not_applicable"


def test_breathing_gets_one_row_per_breath_with_its_heart_rate(env):
    r = post(env, breathing())
    assert r.status_code == 200, r.text
    s = env.repo().get("activities/act-watch-br001.json")["sensors_summary"]
    assert [b["breath"] for b in s["breaths"]] == [1, 2, 3, 4, 5, 6]
    assert s["breaths"][0]["start_s"] == 2.0 and s["breaths"][0]["end_s"] == 13.0
    assert s["breaths"][-1]["end_s"] == 68.0
    assert s["breaths"][0]["hr_mean_bpm"] > s["breaths"][-1]["hr_mean_bpm"]
    assert s["heart_rate"]["trend"] == "falling"


def test_checkin_may_carry_the_watch_too(env):
    moments = [{"name": "checkin_started", "t_ms": 0, "wall_ms": 0},
               {"name": "checkin_step", "t_ms": 10, "wall_ms": 10, "step": "good_things"},
               {"name": "checkin_step", "t_ms": 20000, "wall_ms": 20000, "step": "plan"},
               {"name": "checkin_ended", "t_ms": 40000, "wall_ms": 40000, "value": 1}]
    rec = {"id": "act-watch-ck0001", "type": "checkin",
           "started_at": (NOW - timedelta(minutes=10)).isoformat(),
           "duration_s": 40.0, "completed": True, "ended_by": "finished",
           "good_things": [{"catalog_id": "walked"}], "plan": None, "plan_done": "not_asked",
           "sensors": sensors(hr=heart(0, 40, 3.0, 66, 64), moments=moments)}
    r = post(env, rec)
    assert r.status_code == 200, r.text
    s = env.repo().get("activities/act-watch-ck0001.json")["sensors_summary"]
    assert s["moments"]["by_name"]["checkin_step"] == 2 and s["heart_rate"]["trend"] == "steady"


def test_values_that_cannot_be_true_are_refused():
    env = Env()
    cases = [
        (sensors(hr=[[0, 300.0]]), "heart_rate_implausible"),
        (sensors(hr=[[900_000, 70.0]]), "heart_rate_outside_activity"),
        (sensors(hr=[[5000, 70.0], [2000, 71.0]]), "heart_rate_not_in_order"),
        (sensors(hrv=[[1000, 900.0]]), "hrv_sdnn_implausible"),
        (sensors(moments=[{"name": "breath_in", "t_ms": 0, "wall_ms": 0}]),
         "moment_from_another_activity"),
        (sensors(moments=[{"name": "spark_caught", "t_ms": 0, "wall_ms": 9000}]),
         "moment_clocks_disagree"),
        (sensors(face_offset=-400), "face_offset_without_frames"),
    ]
    for i, (block, reason) in enumerate(cases):
        r = post(env, focus(f"act-watch-bad{i:04d}", block=block))
        assert r.status_code == 422, (reason, r.text)
        assert reason in r.json()["error"]["message"], (reason, r.text)
    # The shape is the model's: an unknown field, a bad name, a row of three.
    for bad in ({"clock": {"started_uptime_s": 1}, "extra": 1},
                {"clock": {"started_uptime_s": 1}, "moments": [{"name": "Spark!", "t_ms": 0, "wall_ms": 0}]},
                {"clock": {"started_uptime_s": 1}, "heart_rate": [[0, 70, 1]]}):
        assert post(env, focus("act-watch-shape0", block=bad)).status_code == 422
    assert check_sensors(sensors(), {"type": "focus", "duration_s": 45.0}) is None
    assert check_sensors(sensors(moments=[{"name": "checkin_step", "t_ms": 0, "wall_ms": 0,
                                           "step": "nope"}]),
                         {"type": "checkin", "duration_s": 45.0}) == "unknown_checkin_step"


def test_summary_without_heart_rate_or_moments_is_honest():
    s = summarize({"clock": {"started_uptime_s": 1.0}}, {"type": "focus", "duration_s": 45.0})
    assert s["heart_rate"] is None and s["hrv_sdnn"]["samples"] == 0
    assert s["moments"]["count"] == 0 and s["moments"]["heart_rate_after"] == {}
    s = summarize({"clock": {"started_uptime_s": 1.0}, "heart_rate": [[1000, 70.0], [3000, 71.0]],
                   "hrv_sdnn": [[2000, 41.5]]}, {"type": "focus", "duration_s": 45.0})
    assert s["heart_rate"]["trend"] == "unclear" and s["heart_rate"]["slope_bpm_per_min"] is None
    assert s["hrv_sdnn"] == {"samples": 1, "latest_ms": 41.5, "latest_at_s": 2.0, "mean_ms": 41.5}


# ---- the sensor reading (level 2) ------------------------------------------------------------

def sensor_bodies(rec):
    out = []
    for _host, body, _url in rec.requests:
        sys_text = json.dumps(body.get("systemInstruction") or "")
        if "You read the record of one short game session" in sys_text:
            out.append((body, json.loads(body["contents"][0]["parts"][0]["text"])))
    return out


def reading_env(reply, allow=True, record=None):
    rec = Level2Recorder(reply)
    env = Env(level2=rec)
    if not allow:
        env.repo().put("patient.json", {**env.repo().patient(), "allow_outside_processing": False})
    r = post(env, record or focus())
    assert r.status_code == 200, r.text
    return env, rec


def test_the_reading_is_sent_anonymous_checked_by_code_and_stored_for_the_clinician():
    env, rec = reading_env(json.dumps(GOOD))
    (body, payload), = sensor_bodies(rec)
    blob = json.dumps(body)
    d = env.demo
    for ident in (d["patient_id"], d["clinic_id"], AID, "started_at", "48213", "uuid", "Patient"):
        assert ident not in blob, ident
    assert not ISO_DATE.search(blob) and not re.search(r"\d{2}:\d{2}", blob)
    assert set(payload) == {"activity", "duration_s", "finished", "heart_rate", "hrv_sdnn", "moments",
                            "gameplay"}
    assert payload["heart_rate"][0] == [-10.0, 70.0] and payload["moments"][0] == [0.0, "focus_started"]
    assert payload["gameplay"] == {"correct_taps": 17, "wrong_taps": 1, "misses": 2,
                                   "median_reaction_ms": 556.0}
    assert body["generationConfig"]["responseSchema"] == sr.RESPONSE_SCHEMA
    stored = env.repo().get(f"activities/{AID}.json")
    sr_ = stored["sensor_reading"]
    assert sr_["status"] == "ready" and sr_["read_by"] == "level2" and sr_["checked_by"] == "code"
    assert sr_["reading"]["heart_rate"]["trend"] == "rising"
    assert sr_["reading"]["heart_rate"]["peak_bpm"] == 86.0 and sr_["dropped"] == []
    assert sr_["agreement"]["moments_in_data"] == 5 and sr_["agreement"]["moments_missed"] == 0
    # The clinician sees it; the trace has the step; the mind did not move.
    view = env.client.get(f"/v1/clinic/patients/{env.demo['patient_id']}", headers=env.C()).json()
    sess = next(x for x in view["activities"]["focus"]["sessions"] if x["id"] == AID)
    assert sess["sensor_reading"]["status"] == "ready"
    t = env.client.get(f"/v1/clinic/patients/{env.demo['patient_id']}/trace?changed_only=false",
                       headers=env.C()).json()
    steps = [e for c in t["chains"] for e in c["entries"] if e["layer"] == "level2"
             and e["detail"].get("task") == "sensor_reading"]
    assert steps and steps[0]["code"] == "accepted" and steps[0]["detail"]["anonymized"] is True
    assert "reading" not in env.client.get(f"/v1/today", headers=env.H).json()


def test_claims_code_cannot_confirm_are_dropped_and_logged():
    bad = json.loads(json.dumps(GOOD))
    bad["heart_rate"].update(trend="falling", peak_bpm=99.0, start_bpm=70.0)
    bad["around_moments"][1]["heart_rate"] = "higher"
    bad["around_moments"].append({"moment": "breath_in", "heart_rate": "same"})
    bad["hrv"] = "present"
    bad["face_and_heart"] = "lively_face_higher_hr"
    env, _ = reading_env(json.dumps(bad))
    sr_ = env.repo().get(f"activities/{AID}.json")["sensor_reading"]
    assert sr_["status"] == "ready"
    r = sr_["reading"]
    assert r["heart_rate"]["trend"] == "unclear" and r["heart_rate"]["peak_bpm"] is None
    assert r["heart_rate"]["start_bpm"] is None and r["heart_rate"]["peak_at_s"] is None
    assert next(m for m in r["around_moments"] if m["moment"] == "spark_caught")["heart_rate"] == "unclear"
    assert all(m["moment"] != "breath_in" for m in r["around_moments"])
    assert r["hrv"] == "none" and r["face_and_heart"] == "unclear"
    reasons = {(d["item"], d["reason"]) for d in sr_["dropped"]}
    assert ("trend", "code_disagrees") in reasons and ("peak_bpm", "not_in_numbers") in reasons
    assert ("around_moments", "moment_not_in_data") in reasons and ("hrv", "code_disagrees") in reasons
    assert any(e["reason"].startswith("item_dropped:") for e in env.audit(outcome="refused"))


def test_prose_and_wrong_shapes_are_refused():
    env, _ = reading_env("The person is clearly anxious: heart rate up.")
    sr_ = env.repo().get(f"activities/{AID}.json")["sensor_reading"]
    assert sr_["status"] == "failed" and sr_["reason"] == "not_json_object"
    env, _ = reading_env(json.dumps({**GOOD, "hrv": "sometimes"}))
    assert env.repo().get(f"activities/{AID}.json")["sensor_reading"]["reason"].startswith("schema:")


def test_without_consent_or_without_gemini_nothing_leaves():
    env, rec = reading_env(json.dumps(GOOD), allow=False)
    assert sensor_bodies(rec) == []
    assert env.repo().get(f"activities/{AID}.json")["sensor_reading"] == {"status": "not_allowed"}
    env = Env()
    assert post(env, focus()).status_code == 200
    assert env.repo().get(f"activities/{AID}.json")["sensor_reading"] == {"status": "off"}


def test_breathing_reading_compares_the_breaths():
    good = {"heart_rate": {"trend": "falling", "start_bpm": None, "end_bpm": None, "peak_bpm": None,
                           "peak_at_s": None},
            "around_moments": [], "breathing_pattern": "slows_with_breaths", "hrv": "none",
            "face_and_heart": "unclear", "data_quality": "good", "confidence": "high"}
    env, rec = reading_env(json.dumps(good), record=breathing())
    (_, payload), = sensor_bodies(rec)
    assert payload["activity"] == "breathing" and payload["gameplay"] == {"breaths_completed": 6,
                                                                           "time_played_s": 68.0}
    code = sr.code_view(payload)
    assert code["breathing_pattern"] == "slows_with_breaths" and code["trend"] == "falling"
    sr_ = env.repo().get("activities/act-watch-br001.json")["sensor_reading"]
    assert sr_["status"] == "ready" and sr_["reading"]["breathing_pattern"] == "slows_with_breaths"
    assert sr_["agreement"]["moments_missed"] == 5 and sr_["dropped"] == []


def test_the_outbound_check_refuses_anything_off_the_allowlist():
    payload = sr.build_payload(focus(), sensors())
    INPUT_GATE.check_sensors_outbound(payload)
    def refused(change, reason):
        p = json.loads(json.dumps(payload))
        change(p)
        try:
            INPUT_GATE.check_sensors_outbound(p)
        except GateError as ge:
            assert ge.refusal.reason == reason, (ge.refusal.reason, reason)
            return
        raise AssertionError(f"not refused: {reason}")
    refused(lambda p: p.update(alias="x"), "top_level_keys")
    refused(lambda p: p.update(activity="walk"), "string_not_allowed")
    refused(lambda p: p["heart_rate"].append([2000.0, 70.0]), "heart_rate_time_not_allowed")
    refused(lambda p: p["heart_rate"].__setitem__(0, [-10.0, 70.5]), "heart_rate_value_not_allowed")
    refused(lambda p: p["moments"].append([1.0, "patient name"]), "moment_not_allowed")
    refused(lambda p: p["gameplay"].update(started_at=1), "gameplay_keys")
    refused(lambda p: p.update(face={"name": 1.0}), "face_keys")
    # Thinning keeps the stream within the cap, oldest first.
    long = sensors(hr=heart(-10, 45, 0.25))
    p = sr.build_payload(focus(block=long), long)
    assert len(p["heart_rate"]) <= sr.MAX_HR_ROWS and p["heart_rate"][0][0] == -10.0
    INPUT_GATE.check_sensors_outbound(p)


def test_the_clinician_can_download_the_rows_and_it_is_audited():
    env = Env()
    assert post(env, focus()).status_code == 200
    pid = env.demo["patient_id"]
    r = env.client.get(f"/v1/clinic/patients/{pid}/activities/{AID}/sensors", headers=env.C())
    assert r.status_code == 200, r.text
    assert r.json()["heart_rate"][0] == [-10000, 70.0] and r.json()["moments"][1]["value"] == 500
    assert env.client.get(f"/v1/clinic/patients/{pid}/activities/act-watch-nope01/sensors",
                          headers=env.C()).status_code == 404
    assert any(e["action"] == "sensors_read" for e in env.audit())
    # The device may not read it.
    assert env.client.get(f"/v1/clinic/patients/{pid}/activities/{AID}/sensors",
                          headers=env.H).status_code in (401, 403)
