"""POST /v1/daily merges into the stored day: a field the upload leaves out keeps
its value, so the phone can re-send recent days on every open (a watch may sync
last night's sleep or HRV late) without blanking anything. A day identical to
what is stored is accepted but not written again."""

from datetime import timedelta

from conftest import NOW, Env

TODAY = NOW.date()


def day(n):
    return (TODAY - timedelta(days=n)).isoformat()


def post(env, *days):
    r = env.client.post("/v1/daily", headers=env.H, json={"days": list(days)})
    assert r.status_code == 200, r.text
    return r.json()


def day_events(env):
    return [e for e in env.audit() if e["action"] == "day" and e["outcome"] == "ok"]


def test_a_missing_field_keeps_the_stored_value():
    env = Env()
    out = post(env, {"date": day(1), "steps": 6400, "walking_speed_m_s": 1.2, "sleep_h": 7.1})
    assert out["accepted"] == [day(1)]
    rec = env.repo().days()[day(1)]
    assert rec["sleep_h"] == 7.1 and rec["hrv_ms"] is None and rec["source"] == "device"

    # The same day again without sleep (the watch has not synced): sleep stays.
    out = post(env, {"date": day(1), "steps": 6400, "walking_speed_m_s": 1.2})
    assert out["accepted"] == [day(1)]
    rec = env.repo().days()[day(1)]
    assert rec["sleep_h"] == 7.1 and rec["steps"] == 6400

    # A value that arrives later is added; a changed value replaces the stored one.
    post(env, {"date": day(1), "steps": 6500, "hrv_ms": 41.0})
    rec = env.repo().days()[day(1)]
    assert (rec["steps"], rec["walking_speed_m_s"], rec["hrv_ms"], rec["sleep_h"]) == \
        (6500, 1.2, 41.0, 7.1)


def test_an_unchanged_day_is_accepted_but_not_written_again():
    env = Env()
    d = {"date": day(2), "steps": 5000, "walking_speed_m_s": 1.1, "hrv_ms": 40.0, "sleep_h": 6.9}
    post(env, d)
    first = env.repo().days()[day(2)]["received_at"]
    n = len(day_events(env))

    out = post(env, d)
    assert out["accepted"] == [day(2)]
    assert env.repo().days()[day(2)]["received_at"] == first
    assert len(day_events(env)) == n, "nothing new: no audit line, no reading"

    # Part of the batch new, part unchanged: only the new day counts.
    out = post(env, d, {"date": day(3), "steps": 4000})
    assert out["accepted"] == [day(3), day(2)] or set(out["accepted"]) == {day(2), day(3)}
    assert day_events(env)[-1]["detail"]["days"] == 1


def test_a_seeded_example_day_is_replaced_whole():
    env = Env()
    days = env.repo().days()
    example = next(ds for ds, r in sorted(days.items()) if r.get("example"))
    post(env, {"date": example, "steps": 3000})
    rec = env.repo().days()[example]
    assert rec["steps"] == 3000 and rec["example"] is False
    assert rec["sleep_h"] is None, "invented sleep is not kept under a real day"
