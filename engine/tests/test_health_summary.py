"""POST /v1/health/summary: the HealthKit harness app's summary, any HealthKit
type with one value per day. Stored per type; the four known types fill the
day records through the same checks as POST /v1/daily."""

from datetime import timedelta

from conftest import NOW, Env

TODAY = NOW.date()


def day(n):
    return (TODAY - timedelta(days=n)).isoformat()


def summary(**over):
    """As the harness encodes it: many fields the server does not read."""
    metrics = [
        {"typeIdentifier": "HKQuantityTypeIdentifierStepCount", "displayName": "Steps",
         "category": "Activity", "unit": "count", "aggregation": "sum", "sampleCount": 400,
         "sources": ["Peter's Apple Watch"], "weekly": [], "firstDate": 785000000.0,
         "daily": [{"day": day(1), "count": 200, "sum": 5100.0, "mean": 5100.0, "median": 20.0},
                   {"day": day(2), "count": 180, "sum": 4300.4, "mean": 4300.4}]},
        {"typeIdentifier": "HKQuantityTypeIdentifierRestingHeartRate", "unit": "count/min",
         "aggregation": "mean", "daily": [{"day": day(1), "count": 1, "mean": 58.0},
                                          {"day": day(2), "count": 1, "mean": 61.0}]},
        {"typeIdentifier": "HKCategoryTypeIdentifierSleepAnalysis", "unit": "hr",
         "aggregation": "durationHours", "daily": [{"day": day(1), "count": 9, "sum": 6.4,
                                                    "mean": 6.4}]},
        {"typeIdentifier": "HKCategoryTypeIdentifierSleepAnalysis:asleepREM", "unit": "hr",
         "aggregation": "durationHours", "daily": [{"day": day(1), "count": 3, "mean": 1.2}]},
        {"typeIdentifier": "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", "unit": "ms",
         "aggregation": "mean", "daily": [{"day": day(20), "count": 2, "mean": 44.0}]},
    ]
    body = {"generatedAt": 785000000.0, "timeZoneIdentifier": "Europe/Helsinki",
            "range": {"start": 1.0, "end": 2.0}, "metrics": metrics, "unavailableTypes": [],
            "emptyTypes": [], "workoutCount": 0, "workoutsByActivity": {}, "totalSamples": 0,
            "notes": ["Sleep: 2 sources"]}
    body.update(over)
    return body


def test_every_type_is_stored_and_the_four_known_ones_fill_the_days():
    env = Env()
    before = env.repo().days()
    r = env.client.post("/v1/health/summary", headers=env.H, json=summary())
    assert r.status_code == 200, r.text
    out = r.json()
    assert {s["type"] for s in out["stored"]} == {m["typeIdentifier"] for m in summary()["metrics"]}
    assert out["days_updated"] == [day(20), day(2), day(1)] and out["rejected"] == []
    days = env.repo().days()
    assert days[day(1)]["steps"] == 5100 and days[day(1)]["sleep_h"] == 6.4
    assert days[day(2)]["steps"] == 4300
    # A field the summary does not have keeps its stored value.
    assert days[day(2)]["walking_speed_m_s"] == before[day(2)]["walking_speed_m_s"]
    # HRV for a day that exists is filled in; nothing else of that day changes.
    assert days[day(20)]["hrv_ms"] == 44.0 and days[day(20)]["steps"] == before[day(20)]["steps"]
    rest = env.repo().get("health/HKQuantityTypeIdentifierRestingHeartRate.json")
    assert rest["days"] == {day(2): 61.0, day(1): 58.0} and rest["unit"] == "count/min"
    assert env.repo().get("health/HKCategoryTypeIdentifierSleepAnalysis_asleepREM.json")
    # Nothing of the summary beyond the numbers is kept.
    assert "Apple Watch" not in str([env.store.get(k) for k in env.store.list(env.repo().p + "health/")])
    # The same upload again writes no day.
    r = env.client.post("/v1/health/summary", headers=env.H, json=summary())
    assert r.json()["days_updated"] == []
    ev = [e for e in env.audit() if e["action"] == "health_summary"]
    assert ev and ev[0]["detail"]["types"] == 5


def test_refusals():
    env = Env()
    bad = summary()
    bad["metrics"][0]["typeIdentifier"] = "steps; drop table"
    assert env.client.post("/v1/health/summary", headers=env.H, json=bad).status_code == 422
    assert env.client.post("/v1/health/summary", json=summary()).status_code == 401
    assert env.client.post("/v1/health/summary", headers=env.C(), json=summary()).status_code == 403
    # A value that cannot be true is rejected for that day, as in POST /v1/daily.
    odd = summary()
    odd["metrics"][0]["daily"][0]["mean"] = -5.0
    out = env.client.post("/v1/health/summary", headers=env.H, json=odd).json()
    assert [x["date"] for x in out["rejected"]] == [day(1)]
    # Values for a day that has no steps anywhere stay in the stored type only.
    far = {"metrics": [{"typeIdentifier": "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
                        "aggregation": "mean", "daily": [{"day": day(300), "mean": 40.0}]}]}
    out = env.client.post("/v1/health/summary", headers=env.H, json=far).json()
    assert out["days_updated"] == [] and out["stored"][0]["days"] >= 1
    assert day(300) not in env.repo().days()
