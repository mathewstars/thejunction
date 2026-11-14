"""HTTP layer: auth scopes, tenant isolation, idempotency, error shape,
headers, limits, the device flow, the clinician views and progress."""

from datetime import timedelta

from clinic_engine.security import hash_password, resolve_token, sha256_hex, verify_password
from clinic_engine.service import create_pairing_code
from clinic_engine.store import DirStore, MemoryStore

from conftest import NOW, TODAY, Env


def test_healthz_and_security_headers(env):
    r = env.client.get("/healthz")
    assert r.status_code == 200 and r.json()["product"] == "Angel"
    for h in ("x-content-type-options", "x-frame-options", "content-security-policy",
              "x-request-id", "referrer-policy"):
        assert h in r.headers
    assert "access-control-allow-origin" not in r.headers  # CORS closed by default


def test_error_shape_has_request_id(env):
    r = env.client.get("/v1/today")
    body = r.json()
    assert r.status_code == 401
    assert set(body["error"]) == {"code", "message", "request_id"}
    assert body["error"]["request_id"] == r.headers["x-request-id"]


def test_tokens_stored_only_as_hashes(env):
    tok = env.demo["device_token"]
    assert env.store.get(f"tokens/{sha256_hex(tok)}.json")["scope"] == "device"
    assert all(tok not in str(env.store.get(k)) for k in env.store.list(""))


def test_scopes_are_enforced(env):
    C = env.C()
    assert env.client.get("/v1/clinic/patients", headers=env.H).status_code == 403
    assert env.client.get("/v1/today", headers=C).status_code == 403
    # The demo clinician may use the demo endpoints while demo mode is on
    # (see test_web.py for the full matrix); a device never may.
    assert env.client.post("/v1/demo/tick", headers=env.H).status_code == 403
    assert env.client.get("/v1/clinic/patients", headers=env.A).status_code == 403
    assert any(e["reason"] == "wrong_scope:device" for e in env.audit(outcome="refused"))


def test_bad_and_expired_tokens(env):
    r = env.client.get("/v1/today", headers={"Authorization": "Bearer nope"})
    assert r.status_code == 401
    C = env.C()
    env.clock.advance(minutes=env.settings.session_ttl_minutes + 1)
    assert env.client.get("/v1/clinic/patients", headers=C).status_code == 401
    assert any(e["reason"] == "invalid_token" for e in env.global_audit())


def test_clinician_sees_only_own_clinic(env):
    C = env.C()
    lines = env.client.get("/v1/clinic/patients", headers=C).json()["patients"]
    pids = {x["patient_id"] for x in lines}
    assert env.demo["patient_id"] in pids and env.demo["mock_patient_id"] not in pids
    r = env.client.get(f"/v1/clinic/patients/{env.demo['mock_patient_id']}", headers=C)
    assert r.status_code == 404
    from clinic_engine.audit import list_audit
    assert any(e["reason"] == "patient_not_in_clinic"
               for e in list_audit(env.store, env.demo["clinic_id"], None, outcome="refused"))


def test_login_wrong_password_refused_and_audited(env):
    r = env.client.post("/v1/clinic/login", json={"username": "demo-clinician", "password": "x"})
    assert r.status_code == 401
    r = env.client.post("/v1/clinic/login", json={"username": "nobody", "password": "x"})
    assert r.status_code == 401
    assert any(e["reason"] == "bad_credentials" for e in env.global_audit())


def test_password_hashing():
    h = hash_password("s3cret")
    assert h.startswith("scrypt$") and verify_password("s3cret", h) and not verify_password("x", h)


def test_strict_models_forbid_extra_fields(env):
    r = env.client.post("/v1/daily", headers=env.H,
                        json={"days": [{"date": TODAY.isoformat(), "steps": 1, "mood": "sad"}]})
    assert r.status_code == 422
    r = env.client.post("/v1/feedback", headers=env.H, json={
        "id": "fb-00000001", "suggestion_id": "sug_" + "0" * 24, "answer": "did_it",
        "comment": "free text is not allowed"})
    assert r.status_code == 422


def test_body_size_limit():
    env = Env(max_body_bytes=2048)
    big = {"days": [{"date": TODAY.isoformat(), "steps": 1000}] * 200}
    r = env.client.post("/v1/daily", headers=env.H, json=big)
    assert r.status_code == 413 and r.json()["error"]["code"] == "body_too_large"


def test_rate_limit_per_token():
    env = Env(rate_per_minute=1, rate_burst=3)
    codes = [env.client.get("/v1/today", headers=env.H).status_code for _ in range(5)]
    assert codes[:3] == [200, 200, 200] and 429 in codes[3:]


def test_pairing_flow_and_replay(env):
    code = create_pairing_code(env.app.state.ctx, env.demo["clinic_id"], env.demo["patient_id"])
    body = {"pairing_code": code, "device_label": "iPhone 15", "platform": "ios"}
    r = env.client.post("/v1/devices/pair", json=body)
    assert r.status_code == 200 and r.json()["patient_id"] == env.demo["patient_id"]
    tok = r.json()["device_token"]
    p = resolve_token(env.store, tok, NOW)
    assert p.scope == "device" and p.patient_id == env.demo["patient_id"]
    again = env.client.post("/v1/devices/pair", json=body)
    assert again.status_code == 400
    assert any(e["reason"] == "pairing_code_replayed" for e in env.global_audit())


def test_daily_batch_upsert_and_rejections(env):
    days = [{"date": (TODAY - timedelta(days=k)).isoformat(), "steps": 7000 + k,
             "walking_speed_m_s": 1.25} for k in range(30)]
    days.append({"date": (TODAY + timedelta(days=9)).isoformat(), "steps": 100})
    days.append({"date": TODAY.isoformat(), "steps": 1})  # conflicts with the first entry
    r = env.client.post("/v1/daily", headers=env.H, json={"days": days})
    body = r.json()
    assert r.status_code == 200
    reasons = {x["reason"] for x in body["rejected"]}
    assert {"future_date", "conflicting_duplicate"} <= reasons
    assert len(body["accepted"]) == 29
    assert body["status"] in ("within", "no_baseline", "outside")


def test_today_always_has_crisis_and_suggestion_on_dip(env):
    t = env.client.get("/v1/today", headers=env.H).json()
    assert t["crisis"]["text"] and t["crisis"]["contacts"][0]["phone"] == "112"
    assert t["status"] == "within" and t["suggestion"] is None
    env.client.post("/v1/demo/scenario", headers=env.A, json={"name": "dip"})
    t = env.client.get("/v1/today", headers=env.H).json()
    assert t["status"] == "outside" and t["suggestion"]["action"] == "breathing"
    assert t["lanvi"]["line"]["text"] and t["lanvi"]["xp"] > 0
    assert t["crisis"]["reviewed_by_clinician"] is False


def test_feedback_idempotent_and_learning_runs(env):
    env.client.post("/v1/demo/scenario", headers=env.A, json={"name": "dip"})
    s = env.client.get("/v1/today", headers=env.H).json()["suggestion"]
    fb = {"id": "fb-0000-0001", "suggestion_id": s["id"], "answer": "did_it", "felt": "ok"}
    env.clock.advance(minutes=5)
    assert env.client.post("/v1/feedback", headers=env.H, json=fb).status_code == 200
    assert env.client.post("/v1/feedback", headers=env.H, json=fb).status_code == 200
    assert len(env.repo().feedback()) == 1
    assert env.repo().reviews()[-1]["trigger"] == "feedback"
    other = {**fb, "suggestion_id": "sug_" + "1" * 24}
    assert env.client.post("/v1/feedback", headers=env.H, json=other).status_code == 404


def test_mind_rules_lessons_questions(env):
    m = env.client.get("/v1/mind", headers=env.H).json()
    assert m["lessons"] and all(x["text"] and x["evidence_count"] >= 1 for x in m["lessons"])
    r = env.client.post("/v1/mind/rules", headers=env.H, json={
        "rule": {"type": "no_action", "params": {"action": "breathing"}}})
    assert r.status_code == 200
    rid = r.json()["id"]
    env.client.post("/v1/demo/scenario", headers=env.A, json={"name": "dip"})
    s = env.client.get("/v1/today", headers=env.H).json()
    assert s["suggestion"]["action"] != "breathing"
    assert s["round_config"]["config_id"]  # deprecated, still sent for older apps
    old = env.client.post("/v1/mind/rules", headers=env.H, json={
        "rule": {"type": "no_action", "params": {"action": "ar_round"}}})
    assert old.status_code == 422  # the cut AR round is no longer an action
    assert env.client.delete(f"/v1/mind/rules/{rid}", headers=env.H).status_code == 200
    bad = env.client.post("/v1/mind/rules", headers=env.H, json={
        "rule": {"type": "no_action", "params": {"action": "anything"}}})
    assert bad.status_code == 422
    q = m["questions"][0]
    r = env.client.post(f"/v1/mind/questions/{q['id']}/answer", headers=env.H, json={"answer": "yes"})
    assert r.status_code == 200
    lid = m["lessons"][0]["id"]
    assert env.client.post(f"/v1/mind/lessons/{lid}/reject", headers=env.H).status_code == 200
    assert lid not in {x["id"] for x in env.client.get("/v1/mind", headers=env.H).json()["lessons"]}


def test_clinician_list_detail_ack_and_progress(env):
    env.client.post("/v1/demo/scenario", headers=env.A, json={"name": "dip"})
    C = env.C()
    line = next(x for x in env.client.get("/v1/clinic/patients", headers=C).json()["patients"]
                if x["patient_id"] == env.demo["patient_id"])
    assert line["status"] == "outside" and line["attention"]
    dev = next(a for a in line["attention"] if a["kind"] == "deviation")
    d = env.client.get(f"/v1/clinic/patients/{env.demo['patient_id']}", headers=C).json()
    prog = d["progress"]
    assert prog["series"] and set(prog["series"][-1]) >= {"date", "z", "movement_z", "example"}
    assert len(prog["weekly"]) == 6 and {"mean_movement_z", "days_with_data", "days_missing"} <= set(prog["weekly"][0])
    assert any(e["kind"] == "deviation" and e["end"] is None for e in prog["episodes"])
    assert prog["actions"]["breathing"]["done"] >= 3
    assert all(x["provenance"]["model"] for x in d["lessons"])
    r = env.client.post(f"/v1/clinic/attention/{dev['id']}/ack", headers=C)
    assert r.status_code == 200
    line = next(x for x in env.client.get("/v1/clinic/patients", headers=C).json()["patients"]
                if x["patient_id"] == env.demo["patient_id"])
    assert line["status"] == "outside"  # the data still decides
    assert not any(a["kind"] == "deviation" for a in line["attention"])


def test_review_run_and_tick_admin(env):
    r = env.client.post("/v1/review/run", headers=env.A, json={"patient_id": env.demo["patient_id"]})
    assert r.status_code == 200 and "accepted" in r.json()
    assert env.client.post("/v1/demo/tick", headers=env.A).status_code == 200
    assert env.client.post("/v1/demo/reset", headers=env.A).status_code == 200


def test_dirstore_and_memorystore_behave_alike(tmp_path):
    for s in (MemoryStore(), DirStore(str(tmp_path))):
        s.put("clinics/a/patients/b/days/2026-11-01.json", {"x": 1})
        s.put("clinics/a/patients/b/days/2026-11-02.json", {"x": 2})
        s.put("clinics/a/patients/c/days/2026-11-02.json", {"x": 3})
        assert s.list("clinics/a/patients/b/") == ["clinics/a/patients/b/days/2026-11-01.json",
                                                   "clinics/a/patients/b/days/2026-11-02.json"]
        assert s.get("clinics/a/patients/b/days/2026-11-02.json") == {"x": 2}
        s.delete("clinics/a/patients/b/days/2026-11-02.json")
        assert s.get("clinics/a/patients/b/days/2026-11-02.json") is None
        for bad in ("../etc/passwd", "/abs", "a/../../b"):
            try:
                s.get(bad)
                assert False, "should refuse"
            except ValueError:
                pass


def test_s3store_with_stubbed_client():
    import io
    import json
    import boto3
    from botocore.stub import Stubber
    from botocore.response import StreamingBody
    from clinic_engine.store import S3Store
    client = boto3.client("s3", region_name="us-east-1", aws_access_key_id="x",
                          aws_secret_access_key="y", endpoint_url="http://localhost:9")
    st = Stubber(client)
    raw = json.dumps({"a": 1}).encode()
    st.add_response("put_object", {}, {"Bucket": "b", "Key": "k/x.json", "Body": json.dumps({"a": 1}, sort_keys=True).encode(),
                                       "ContentType": "application/json"})
    st.add_response("get_object", {"Body": StreamingBody(io.BytesIO(raw), len(raw))},
                    {"Bucket": "b", "Key": "k/x.json"})
    st.add_response("list_objects_v2", {"Contents": [{"Key": "k/x.json"}], "IsTruncated": False},
                    {"Bucket": "b", "Prefix": "k/"})
    with st:
        s = S3Store("", "b", "", "", client=client)
        s.put("k/x.json", {"a": 1})
        assert s.get("k/x.json") == {"a": 1}
        assert s.list("k/") == ["k/x.json"]


def test_open_pairing_connects_any_phone_to_the_named_patient():
    """Linking switched off: any code pairs to the one named patient; an unknown label
    leaves the one-time codes in force."""
    from clinic_engine.seed import DEMO_LABEL
    env = Env(open_pairing_patient=DEMO_LABEL)
    body = {"pairing_code": "OPEN-OPEN-OPEN", "device_label": "phone", "platform": "ios"}
    for _ in range(2):  # not one-time
        r = env.client.post("/v1/devices/pair", json=body)
        assert r.status_code == 200 and r.json()["patient_id"] == env.demo["patient_id"]
    token = r.json()["device_token"]
    assert env.client.get("/v1/today", headers={"authorization": f"Bearer {token}"}).status_code == 200

    env = Env(open_pairing_patient="No such label")
    r = env.client.post("/v1/devices/pair", json=body)
    assert r.status_code == 400 and r.json()["error"]["code"] == "invalid_pairing_code"
