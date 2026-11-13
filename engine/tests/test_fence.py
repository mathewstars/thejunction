"""The fence: invariants that nothing the mind learns can break."""

import dataclasses
import json
from datetime import datetime, timedelta

import pytest

from clinic_engine.mind.catalog import ACTIONS
from clinic_engine.mind.respond import rank_actions
from clinic_engine.mind.thresholds import T

from conftest import NOW, Env, FakeLocal


def all_avoid_lessons():
    return [{"id": f"les_{a}", "action": a, "effect": "avoid", "context": "any",
             "status": "active", "evidence_ids": [], "evidence_count": 3, "text": "x",
             "source": "code", "review_id": "rev_x", "created_at": NOW.isoformat(),
             "expires_at": (NOW + timedelta(days=30)).isoformat(), "rationale_code": "offered_not_done"}
            for a in ACTIONS]


def test_lessons_cannot_add_or_remove_actions():
    t = datetime(2026, 11, 13, 10)
    assert set(rank_actions([], all_avoid_lessons(), t)) == set(ACTIONS)


def test_thresholds_are_frozen():
    with pytest.raises(dataclasses.FrozenInstanceError):
        T.low_day_z = -99  # type: ignore[misc]


def test_lessons_cannot_silence_suggestions_entirely(env):
    doc = {"lessons": all_avoid_lessons()}
    env.repo().put("mind/lessons.json", doc)
    env.client.post("/v1/demo/scenario", headers=env.A, json={"name": "dip"})
    assert env.client.get("/v1/today", headers=env.H).json()["suggestion"] is not None


def test_lessons_do_not_change_what_the_clinician_sees(env):
    env.client.post("/v1/demo/scenario", headers=env.A, json={"name": "dip"})
    C = env.C()
    pid = env.demo["patient_id"]

    def view():
        line = next(x for x in env.client.get("/v1/clinic/patients", headers=C).json()["patients"]
                    if x["patient_id"] == pid)
        return line["status"], [(a["kind"], a["level"]) for a in line["attention"]]

    before = view()
    env.repo().put("mind/lessons.json", {"lessons": all_avoid_lessons()})
    env.run(env.mind.tick())
    assert view() == before
    assert before[0] == "outside"


def test_deviation_always_reaches_clinician_list():
    env = Env(extra=3)
    C = env.C()
    lines = env.client.get("/v1/clinic/patients", headers=C).json()["patients"]
    by_label = {x["label"]: x for x in lines}
    assert by_label["Example B-022"]["status"] == "outside"
    assert by_label["Example B-023"]["status"] == "no_data"
    assert lines[0]["level"] in ("urgent", "attention")  # most urgent first


@pytest.mark.parametrize("state", ["within", "outside", "no_data", "no_baseline"])
def test_crisis_block_always_present(state):
    env = Env()
    repo = env.repo()
    if state == "outside":
        env.client.post("/v1/demo/scenario", headers=env.A, json={"name": "dip"})
    elif state == "no_data":
        env.clock.advance(days=5)
    elif state == "no_baseline":
        for d in sorted(repo.days())[:-8]:
            repo.delete(f"days/{d}.json")
    t = env.client.get("/v1/today", headers=env.H).json()
    assert t["status"] == state
    assert t["crisis"]["text"] and t["crisis"]["contacts"]


def test_patient_rules_beat_lessons_end_to_end(env):
    prefer_walk = [{**x, "action": "walk_10min", "effect": "prefer", "id": "les_w"}
                   for x in all_avoid_lessons()[:1]]
    env.repo().put("mind/lessons.json", {"lessons": prefer_walk})
    env.client.post("/v1/mind/rules", headers=env.H, json={
        "rule": {"type": "no_action", "params": {"action": "walk_10min"}}})
    env.client.post("/v1/demo/scenario", headers=env.A, json={"name": "dip"})
    assert env.client.get("/v1/today", headers=env.H).json()["suggestion"]["action"] != "walk_10min"


def test_every_lesson_has_provenance_and_rejection_sticks(env):
    lessons = env.repo().lessons_doc()["lessons"]
    assert lessons
    for x in lessons:
        assert x["review_id"].startswith("rev_") and x["source"] in ("code", "local")
        assert x["evidence_ids"]
    lid = next(x["id"] for x in lessons if x["action"] == "breathing")
    env.client.post(f"/v1/mind/lessons/{lid}/reject", headers=env.H)
    env.run(env.mind.run_review(env.repo(), "again"))
    active = [x for x in env.repo().lessons_doc()["lessons"]
              if x["status"] == "active" and x["action"] == "breathing" and x["effect"] == "prefer"]
    assert active == []


def test_model_cannot_close_attention_or_change_thresholds():
    reply = json.dumps({"lessons": [], "questions": [], "close_attention": ["all"],
                        "thresholds": {"low_day_z": -9}})
    env = Env(local=FakeLocal(review=reply))
    env.client.post("/v1/demo/scenario", headers=env.A, json={"name": "dip"})
    before = [(i["id"], i["state"]) for i in env.repo().items()]
    review = env.run(env.mind.run_review(env.repo(), "t"))
    assert any(r["reason"].startswith("schema:extra_forbidden") for r in review["refused"])
    assert [(i["id"], i["state"]) for i in env.repo().items()] == before
    assert T.low_day_z == -1.5
