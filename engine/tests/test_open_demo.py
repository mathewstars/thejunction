"""The open demo: a visitor reads the generated example patients without a
login and can change nothing. It never sees a real or test-play patient."""

from conftest import NOW, Env

from clinic_engine import seed


def _visitor(env):
    r = env.client.post("/v1/clinic/visit")
    assert r.status_code == 200, r.text
    return {"Authorization": "Bearer " + r.json()["session_token"]}


def test_it_is_off_unless_switched_on():
    env = Env()
    assert env.client.post("/v1/clinic/visit").status_code == 404
    off = Env(demo_public=True, demo_enabled=False)
    assert off.client.post("/v1/clinic/visit").status_code == 404


def test_a_visitor_reads_the_examples_and_nothing_else():
    env = Env(demo_public=True, extra=1)
    c = env.demo["clinic_id"]
    real = seed.create_patient(env.store, c, "Patient Z-900", "Europe/Helsinki", NOW, example=False)
    test_play = seed.create_patient(env.store, c, "Patient T-001", "Europe/Helsinki", NOW, example=True)
    k = f"clinics/{c}/patients/{test_play}/patient.json"
    rec = env.store.get(k); rec["test_play"] = True; env.store.put(k, rec)
    V = _visitor(env)
    me = env.client.get("/v1/clinic/me", headers=V).json()
    assert me["read_only"] is True and me["demo"]["enabled"] is False
    assert me["demo"]["patient_id"] == env.demo["patient_id"]
    listed = {p["patient_id"] for p in env.client.get("/v1/clinic/patients", headers=V).json()["patients"]}
    assert env.demo["patient_id"] in listed and set(env.demo["extra_patient_ids"]) <= listed
    assert real not in listed and test_play not in listed
    assert env.client.get(f"/v1/clinic/patients/{env.demo['patient_id']}", headers=V).status_code == 200
    for hidden in (real, test_play, env.demo["mock_patient_id"]):
        assert env.client.get(f"/v1/clinic/patients/{hidden}", headers=V).status_code == 404
        assert env.client.get(f"/v1/clinic/patients/{hidden}/trace", headers=V).status_code == 404
    # a real profile is shown only once its record says so
    rec = env.store.get(k); rec["open_demo"] = True; env.store.put(k, rec)
    listed = {p["patient_id"] for p in env.client.get("/v1/clinic/patients", headers=V).json()["patients"]}
    assert test_play in listed and real not in listed
    assert env.client.get(f"/v1/clinic/patients/{test_play}", headers=V).status_code == 200
    # the clinician still sees them all
    seen = {p["patient_id"] for p in env.client.get("/v1/clinic/patients", headers=env.C()).json()["patients"]}
    assert {real, test_play} <= seen


def test_a_visitor_can_change_nothing():
    env = Env(demo_public=True)
    V, pid = _visitor(env), env.demo["patient_id"]
    before = env.client.get(f"/v1/clinic/patients/{pid}", headers=env.C()).json()
    calls = [("post", f"/v1/clinic/patients/{pid}/associations/run", {}),
             ("post", f"/v1/clinic/patients/{pid}/ratings", {"date": "2026-11-10", "scale": "phq9", "score": 5}),
             ("post", f"/v1/clinic/patients/{pid}/clinic-rules", {"text": "rest"}),
             ("post", "/v1/demo/reset", {}), ("post", "/v1/demo/scenario", {"name": "dip"}),
             ("post", "/v1/demo/tick", {}), ("post", "/v1/review/run", {"patient_id": pid}),
             ("post", "/v1/notes", {"id": "note-visitor-0001", "text": "hello"}),
             ("post", "/v1/activities", {}), ("put", "/v1/preferences", {})]
    for method, path, body in calls:
        r = getattr(env.client, method)(path, headers=V, json=body)
        assert r.status_code == 403, (path, r.status_code, r.text)
    assert env.client.get("/v1/today", headers=V).status_code == 403          # not a device either
    after = env.client.get(f"/v1/clinic/patients/{pid}", headers=env.C()).json()
    assert before == after


def test_a_visit_ends():
    env = Env(demo_public=True, demo_visit_minutes=1)
    V = _visitor(env)
    assert env.client.get("/v1/clinic/patients", headers=V).status_code == 200
    env.clock.advance(minutes=2)
    assert env.client.get("/v1/clinic/patients", headers=V).status_code == 401
