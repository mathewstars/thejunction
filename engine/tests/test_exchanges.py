"""The raw model exchange is kept per patient and note words are hidden unless shared."""
from clinic_engine.mind import exchanges as ex
from clinic_engine.mind import trace as trace_mod
from clinic_engine.mind.gates import Pack


def test_recorder_keeps_the_exchange_inside_a_chain_and_hides_note_words(env):
    d = env.demo
    rec = ex.Recorder(env.store, env.clock)
    note = Pack(1, "note", [{"role": "system", "content": "sys"},
                            {"role": "user", "content": "secret words"}], {})
    rec(note, "{}", 12, "m", 1)  # no chain running: nothing is kept
    assert ex.view(env.store, d["clinic_id"], d["patient_id"], True) == []
    with env.mind.tracer.chain(d["clinic_id"], d["patient_id"], "note") as ch:
        rec(note, '{"mood":"low"}', 12.4, "m", 1)
        rec(Pack(1, "review", [{"role": "user", "content": "{}"}], {}), None, 5, "m", 1)
    hidden = ex.view(env.store, d["clinic_id"], d["patient_id"], share_notes=False)
    assert len(hidden) == 2 and {x["chain_id"] for x in hidden} == {ch.id}
    n = next(x for x in hidden if x["task"] == "note")
    assert n["words_hidden"] and n["messages"][1]["content"] == ex.HIDDEN
    assert n["messages"][0]["content"] == "sys" and n["reply"] == '{"mood":"low"}'
    shown = ex.view(env.store, d["clinic_id"], d["patient_id"], share_notes=True, task="note")
    assert shown[0]["messages"][1]["content"] == "secret words"
    assert trace_mod._current.get() is None


def test_exchanges_route_is_clinician_only(env):
    d = env.demo
    url = f"/v1/clinic/patients/{d['patient_id']}/exchanges"
    assert env.client.get(url, headers=env.H).status_code == 403
    r = env.client.get(url, headers=env.C())
    assert r.status_code == 200 and r.json()["exchanges"] == []
