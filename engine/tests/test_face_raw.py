"""Raw face frames through the API: the phone sends what ARKit gives, the
server computes the summary, keeps the frames outside the packs, and the
frames never reach the audit, the trace, the logs or the clinician's patient
views. They reach a model only as the reduced stream of the level-2 frame
reading, with consent (test_frames_reading.py has the rest)."""

import json
import logging
import os
from datetime import timedelta

import pytest

from clinic_engine.mind.face_features import summarize
from clinic_engine.mind.gates import INPUT_GATE, GateError

from conftest import NOW, Env
from face_synth import MARKER, make_raw

MARK = repr(MARKER)  # "0.0123457"


def focus_raw(aid, minutes_ago=30, raw=None, **kw):
    rec = {"id": aid, "type": "focus",
           "started_at": (NOW - timedelta(minutes=minutes_ago)).isoformat(),
           "duration_s": 45.0, "completed": True, "ended_by": "finished",
           "correct_taps": 17, "wrong_taps": 1, "misses": 2,
           "reaction_ms": [500 + 7 * i for i in range(17)],
           "face_raw": raw if raw is not None else session_frames()}
    rec.update(kw)
    return rec


def session_frames(seed=7):
    return make_raw(seconds=45, smiles=[(8, 1.2, 0.55, 0.45, 0.3), (25, 0.9, 0.5, 0.5)],
                    blinks=[(s, 0.1) for s in range(2, 45, 4)], lively=True,
                    moments_ms=[7000, 30000], marker=True, seed=seed)


def post(env, rec):
    return env.client.post("/v1/activities", headers=env.H, json=rec)


def raw_key(env, aid):
    return env.repo().p + f"faceraw/{aid}.json"


def test_raw_session_is_accepted_and_the_server_computes_the_summary(env):
    rec = focus_raw("act-raw-000001")
    r = post(env, rec)
    assert r.status_code == 200, r.text
    assert len(json.dumps(rec)) > env.settings.max_body_bytes  # the larger limit applies here
    stored = env.repo().get("activities/act-raw-000001.json")
    assert stored["face"] == summarize(rec["face_raw"])
    assert stored["face_source"] == "raw" and "face_raw" not in stored
    assert stored["face_raw_info"] == {"rate_hz": 30, "frames": 1350, "tracked_share": 1.0,
                                       "channels": 55}
    assert stored["face_quality"] == "good"
    assert MARK not in json.dumps(stored)
    # The frames: their own object, as sent, plus counts.
    raw = env.store.get(raw_key(env, "act-raw-000001"))
    assert raw["samples"] == rec["face_raw"]["samples"] and raw["frames"] == 1350
    assert raw["channel_count"] == 55 and raw["tracked"] is None


def test_raw_object_lives_outside_the_packs():
    env = Env()
    assert post(env, focus_raw("act-raw-000002")).status_code == 200
    key = raw_key(env, "act-raw-000002")
    inner = getattr(env.store, "inner", env.store)
    assert inner.get(key) is not None  # a single object, also on the packed layout
    for k in inner.list(env.repo().p):
        if k != key:
            assert MARK not in json.dumps(inner.get(k)), k
    if os.environ.get("TEST_PACKED_STORE"):
        assert inner.get(env.repo().p + "activities.pack.json") is not None


def test_z_values_once_a_baseline_exists(env):
    env.store.delete_prefix(env.repo().p + "activities/")  # no seeded sessions
    for i in range(6):
        r = post(env, focus_raw(f"act-raw-base-{i}", minutes_ago=300 - 40 * i,
                                raw=session_frames(seed=i)))
        assert r.status_code == 200, r.text
    recs = [env.repo().get(f"activities/act-raw-base-{i}.json") for i in range(6)]
    assert all(v is None for v in recs[0]["face_z"].values())
    assert recs[4]["face_z"].get("facial_activity") is None  # 4 earlier sessions: not yet
    assert recs[5]["face_z"]["facial_activity"] is not None
    assert recs[5]["usual"]["face.smile_rate_per_min"]["n"] == 5


def test_face_and_face_raw_together_are_refused(env):
    rec = focus_raw("act-raw-000003", face={"tracking_quality": 0.9})
    r = post(env, rec)
    assert r.status_code == 422 and "not both" in r.json()["error"]["message"]
    assert env.store.get(raw_key(env, "act-raw-000003")) is None


def test_bad_frames_are_refused_with_a_clear_message(env):
    raw = session_frames()
    raw["channels"][3] = "smileyFace"
    r = post(env, focus_raw("act-raw-000004", raw=raw))
    assert r.status_code == 422 and "channels[3] is not" in r.json()["error"]["message"]
    assert "smileyFace" not in r.text  # the input is never echoed
    raw = session_frames()
    raw["samples"][9] = raw["samples"][9][:-1]
    r = post(env, focus_raw("act-raw-000005", raw=raw))
    assert r.status_code == 422 and "samples[9] has 54 values" in r.json()["error"]["message"]
    raw = session_frames()
    raw["samples"][2][0] = 3.0
    assert post(env, focus_raw("act-raw-000006", raw=raw)).status_code == 422
    r = env.client.post("/v1/activities", headers={**env.H, "Content-Type": "application/json"},
                        content=json.dumps(focus_raw("act-raw-000007")).replace(
                            MARK, "NaN", 1))
    assert r.status_code == 422 and "finite" in r.json()["error"]["message"]
    checkin = {"id": "act-raw-000008", "type": "checkin", "started_at": NOW.isoformat(),
               "duration_s": 30.0, "completed": True, "ended_by": "finished",
               "face_raw": session_frames()}
    assert post(env, checkin).status_code == 422
    # Frames for much longer than the activity: implausible.
    r = post(env, focus_raw("act-raw-000009", duration_s=10.0))
    assert r.status_code == 422 and "face_frames_longer" in r.text


def test_limits_body_size_and_other_routes_keep_theirs(env):
    raw = make_raw(seconds=2, channels=["mouthSmileLeft", "mouthSmileRight", "eyeBlinkLeft",
                                        "eyeBlinkRight"])
    raw["samples"] = raw["samples"] * 201  # 12,060 rows
    r = post(env, focus_raw("act-raw-000010", raw=raw))
    assert r.status_code == 422
    big = "x" * (env.settings.max_body_bytes + 10)
    r = env.client.post("/v1/notes", headers={**env.H, "Content-Type": "application/json"},
                        content=json.dumps({"id": "note-big-0001", "text": big}))
    assert r.status_code == 413
    r = env.client.post("/v1/activities", headers={**env.H, "Content-Type": "application/json"},
                        content=b" " * (env.settings.max_face_raw_body_bytes + 1))
    assert r.status_code == 413


def test_idempotent_by_id_without_storing_the_frames_twice(env):
    rec = focus_raw("act-raw-000011")
    a = post(env, rec)
    b = post(env, rec)
    assert a.status_code == b.status_code == 200 and b.json()["xp_gained"] == 0
    assert a.json()["id"] == b.json()["id"]
    assert len(env.store.list(env.repo().p + "faceraw/")) == 1
    other = focus_raw("act-raw-000011", raw=session_frames(seed=99))
    assert post(env, other).status_code == 409
    assert env.store.get(raw_key(env, "act-raw-000011"))["samples"] == rec["face_raw"]["samples"]


def test_summary_sessions_work_as_before(env):
    face = {"smile_rate_per_min": 2.5, "facial_activity": 0.5, "tracking_quality": 0.9}
    rec = focus_raw("act-sum-000001", face=face)
    del rec["face_raw"]
    assert post(env, rec).status_code == 200
    stored = env.repo().get("activities/act-sum-000001.json")
    assert stored["face"]["smile_rate_per_min"] == 2.5 and stored["face_source"] == "summary"
    assert "face_raw" not in stored and "face_raw_info" not in stored
    assert post(env, rec).json()["xp_gained"] == 0  # same record, same hash


def test_clinician_sees_counts_and_downloads_the_frames(env):
    rec = focus_raw("act-raw-000012")
    assert post(env, rec).status_code == 200
    C, pid = env.C(), env.demo["patient_id"]
    detail = env.client.get(f"/v1/clinic/patients/{pid}", headers=C)
    assert detail.status_code == 200
    assert MARK not in detail.text and '"samples"' not in detail.text
    sessions = detail.json()["activities"]["focus"]["sessions"]
    s = next(x for x in sessions if x["id"] == "act-raw-000012")
    assert s["face_source"] == "raw"
    assert s["raw"] == {"rate_hz": 30, "frames": 1350, "tracked_share": 1.0, "channels": 55}
    assert s["face"]["smile_rate_per_min"] is not None
    seeded = next(x for x in sessions if x["id"] != "act-raw-000012" and x["face"])
    assert seeded["face_source"] == "summary" and seeded["raw"] is None
    assert MARK not in env.client.get("/v1/clinic/patients", headers=C).text

    url = f"/v1/clinic/patients/{pid}/activities/act-raw-000012/face-raw"
    r = env.client.get(url, headers=C)
    assert r.status_code == 200
    body = r.json()
    assert body["samples"] == rec["face_raw"]["samples"]
    assert body["channels"] == rec["face_raw"]["channels"] and body["frames"] == 1350
    reads = [a for a in env.audit() if a["action"] == "face_raw_read"]
    assert reads and reads[-1]["detail"] == {"activity_id": "act-raw-000012"}


def test_face_raw_download_scope_tenant_and_404(env):
    assert post(env, focus_raw("act-raw-000013")).status_code == 200
    C, pid = env.C(), env.demo["patient_id"]
    url = f"/v1/clinic/patients/{pid}/activities/act-raw-000013/face-raw"
    assert env.client.get(url, headers=env.H).status_code == 403  # device token
    assert env.client.get(url, headers=env.A).status_code == 403  # admin token
    assert env.client.get(url).status_code == 401
    other = env.demo["mock_patient_id"]
    r = env.client.get(f"/v1/clinic/patients/{other}/activities/act-raw-000013/face-raw",
                       headers=C)
    assert r.status_code == 404  # another clinic's patient: not found
    seeded = next(a for a in env.repo().activities() if a.get("face"))
    for aid in (seeded["id"], "act-unknown-0001"):
        r = env.client.get(f"/v1/clinic/patients/{pid}/activities/{aid}/face-raw", headers=C)
        assert r.status_code == 404


def test_frames_never_in_audit_trace_or_logs(caplog):
    env = Env()
    with caplog.at_level(logging.DEBUG):
        assert post(env, focus_raw("act-raw-000014")).status_code == 200
        C, pid = env.C(), env.demo["patient_id"]
        env.client.get(f"/v1/clinic/patients/{pid}/activities/act-raw-000014/face-raw",
                       headers=C)
        trace = env.client.get(f"/v1/clinic/patients/{pid}/trace?limit=100", headers=C)
    assert trace.status_code == 200 and MARK not in trace.text and "samples" not in trace.text
    assert MARK not in json.dumps(env.audit()) and MARK not in json.dumps(env.global_audit())
    assert MARK not in caplog.text
    stored = [env.store.get(k) for k in env.store.list(env.repo().p + "trace/")]
    assert MARK not in json.dumps(stored)


FRAMES_PROMPT_START = "ROLE\n\nYou read a short recording of how one person"


def _bodies_with_frames(l2):
    """Level-2 request bodies whose user message carries a frame stream."""
    out = []
    for _h, body, _u in l2.requests:
        user = json.dumps(body.get("contents") or "")
        if '\\"frames\\"' in user or '"frames"' in user:
            out.append(body)
    return out


@pytest.mark.parametrize("reader", ["local", "auto"])
@pytest.mark.parametrize("allow", [True, False])
def test_frames_reach_a_model_only_in_the_level2_frame_reading_with_consent(reader, allow):
    """The exact rule (it replaced "no pack may contain frames"): raw frames go
    to a model ONLY as the reduced stream of the frame reading, ONLY to level 2,
    ONLY with the patient's consent to outside processing. Every other pack, at
    either level, carries none; level 1 never gets any."""
    from clinic_engine.mind import frame_reading as fr
    from conftest import FakeLocal, Level2Recorder
    l2 = Level2Recorder(reply=None)
    env = Env(local=FakeLocal(), level2=l2, session_reader=reader)
    repo = env.repo()
    p = repo.patient()
    p["allow_outside_processing"] = allow
    repo.put("patient.json", p)
    post(env, focus_raw("act-raw-000015"))
    env.run(env.mind.idle())
    env.run(env.mind.run_appraisal(env.repo(), "on_demand"))
    rec = env.repo().get("activities/act-raw-000015.json")
    # Level 1: every pack it was offered; none holds frames.
    tasks = [pk.task for pk in env.local.packs]
    assert "association" in tasks and "frames_reading" not in tasks
    local_sent = json.dumps([pk.messages for pk in env.local.packs])
    assert MARK not in local_sent and '"samples"' not in local_sent
    assert '"frames"' not in local_sent and '\\"frames\\"' not in local_sent
    # Level 2: frames only in the frame reading, only with consent.
    with_frames = _bodies_with_frames(l2)
    if allow:
        # The service fails here, so the same checked stream is sent once more.
        assert len(with_frames) == 2
        assert with_frames[0]["contents"] == with_frames[1]["contents"]
        body = with_frames[0]
        assert body["systemInstruction"]["parts"][0]["text"].startswith(FRAMES_PROMPT_START)
        payload = json.loads(body["contents"][0]["parts"][0]["text"])
        assert list(payload) == list(fr.PAYLOAD_KEYS)
        assert set(payload["channels"]) <= set(fr.CHANNELS)
        assert len(payload["frames"]) <= env.mind.th.frames_max_frames
        INPUT_GATE.check_frames_outbound(payload)
    else:
        assert with_frames == []
        assert rec["frames_reading"] == {"status": "not_allowed"}
    for _h, body, _u in l2.requests:
        blob = json.dumps(body)
        assert MARK not in blob and '"samples"' not in blob and "face_raw" not in blob
        if body not in with_frames:
            assert not body["systemInstruction"]["parts"][0]["text"].startswith(
                FRAMES_PROMPT_START)
    # The session pack is built from the summary only, even from a record that
    # still carried the frames.
    raw = env.store.get(raw_key(env, "act-raw-000015"))
    pack = INPUT_GATE.session_pack({**rec, "face_raw": raw, "samples": raw["samples"]}, [])
    assert MARK not in json.dumps(pack.messages) and "samples" not in json.dumps(pack.payload)
    # The other outbound checks refuse frames outright.
    for bad in ({"session": {"samples": [[0.5]]}}, {"session": {"face_raw": {}}},
                {"session": {"frames": [[0.5]]}}):
        with pytest.raises(GateError):
            INPUT_GATE.check_session_outbound(bad)
    for bad in ({"frames": [[0.5]]}, {"evidence": [{"samples": [[0.5]]}]}):
        with pytest.raises(GateError):
            INPUT_GATE.check_outbound(bad)
    # The frame pack itself is level 2 only.
    fpack = INPUT_GATE.frames_pack(rec, raw)
    assert fpack.level == 2 and fpack.task == "frames_reading" and not fpack.images


def test_recompute_from_the_stored_frames(env):
    rec = focus_raw("act-raw-000016")
    assert post(env, rec).status_code == 200
    repo = env.repo()
    a = repo.get("activities/act-raw-000016.json")
    a["face"] = {**a["face"], "smile_rate_per_min": 99.0}  # as if computed by an older rule
    repo.put("activities/act-raw-000016.json", a)
    pid = env.demo["patient_id"]
    r = env.client.post("/v1/demo/recompute-face", headers=env.A, json={"patient_id": pid})
    assert r.status_code == 200 and r.json() == {"patient_id": pid, "recomputed": 1}
    again = repo.get("activities/act-raw-000016.json")
    assert again["face"] == summarize(rec["face_raw"]) and again["face_source"] == "raw"
    assert again["face_z"] == a["face_z"]
    assert any(x["action"] == "demo_recompute_face" for x in env.global_audit())
    # Same auth as the other demo routes: not a device, not another clinic's patient.
    assert env.client.post("/v1/demo/recompute-face", headers=env.H,
                           json={"patient_id": pid}).status_code == 403
    C = env.C()
    assert env.client.post("/v1/demo/recompute-face", headers=C,
                           json={"patient_id": env.demo["mock_patient_id"]}).status_code == 404


def test_demo_reset_wipes_the_frames(env):
    assert post(env, focus_raw("act-raw-000017")).status_code == 200
    assert env.store.list(env.repo().p + "faceraw/")
    assert env.client.post("/v1/demo/reset", headers=env.A).status_code == 200
    assert env.store.list(env.repo().p + "faceraw/") == []
