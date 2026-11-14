# Apple Health data: what the phone and the watch app send

For Peter. Two ways in, both with the device token from pairing (`Authorization: Bearer ...`), and what the server does with the days.

## What is in the system today

- The Lanvi app already sends days. On first run it asks for Apple Health, sends the history once, and then, each time the app comes to the front, the missing days plus the last 14 sent days again, because a watch syncs sleep and HRV late (`ios/Lanvi/Sense/HealthSync.swift`). The server merges each day into what it holds: a field left out keeps its stored value. It sends four values per day to `POST /v1/daily`: steps, walking speed, sleep hours and HRV.
- It does not send while the app is closed. There is no background delivery yet (no `HKObserverQuery`, no background task). If the watch app or the harness should send on its own schedule, use the second endpoint below; any app that holds a device token can call it.
- On the demo server the days of the example patients are example data. Real days arrive as soon as a paired phone opens the app.

## 1. `POST /v1/daily` (the Lanvi app, unchanged)

One day or a batch, upsert by date. See `docs/api/README.md`, step 3.

```json
{"days": [{"date": "2026-11-13", "steps": 6400, "walking_speed_m_s": 1.24, "hrv_ms": 42.0, "sleep_h": 7.1}]}
```

## 2. `POST /v1/health/summary` (the HealthKit harness app, a watch companion)

Post the harness's `HealthDataSummary` JSON as it is (`ios/Lanvi/Sense/Peter/SharedModels.swift`). The server reads only these fields and ignores every other one, so nothing has to be stripped on the phone:

| Field | What |
|---|---|
| `metrics[].typeIdentifier` | The HealthKit identifier, for example `HKQuantityTypeIdentifierRestingHeartRate`. A sleep stage may carry its label after a colon, as the harness writes it (`HKCategoryTypeIdentifierSleepAnalysis:asleepREM`). |
| `metrics[].unit` | As the harness gives it (`count`, `count/min`, `ms`, `m/s`, `hr`, `kcal`, `min`). |
| `metrics[].aggregation` | `sum`, `mean`, `durationHours`, `latest` or `count`. |
| `metrics[].daily[].day` | `yyyy-MM-dd` in the phone's time zone. |
| `metrics[].daily[].mean` | The day's value. The harness already puts the right number here: the sum for summed types, the mean for averaged ones, hours for sleep (`LocalStatistics.dailyValue`). `sum` is used when `mean` is missing. |
| `metrics[].daily[].count` | Optional. |

A short example:

```json
{"metrics": [
  {"typeIdentifier": "HKQuantityTypeIdentifierStepCount", "unit": "count", "aggregation": "sum",
   "daily": [{"day": "2026-11-13", "count": 212, "sum": 6400, "mean": 6400}]},
  {"typeIdentifier": "HKQuantityTypeIdentifierRestingHeartRate", "unit": "count/min", "aggregation": "mean",
   "daily": [{"day": "2026-11-13", "count": 1, "mean": 58}]}
]}
```

The answer:

```json
{"stored": [{"type": "HKQuantityTypeIdentifierStepCount", "days": 1, "last_day": "2026-11-13"},
            {"type": "HKQuantityTypeIdentifierRestingHeartRate", "days": 1, "last_day": "2026-11-13"}],
 "days_updated": ["2026-11-13"], "rejected": [], "status": "within"}
```

What the server does:

- **Every type is stored**, one value per day, upsert by type and day. The most recent 400 days of each type are kept. Source names, device names, single samples and everything else in the summary are not stored.
- **Four types also fill the day records**, with the same checks as `POST /v1/daily`, so the comparison with the person's own normal sees them: `StepCount` (steps), `WalkingSpeed` (m/s), `SleepAnalysis` without a stage label (hours) and `HeartRateVariabilitySDNN` (ms). A value from the summary replaces the stored one for that day; a field the summary does not have keeps its stored value. A day record needs steps: a value for a day that has no steps anywhere stays in the stored type only.
- **A few more types go into the day reading** (below) when they have at least 14 days: `RestingHeartRate`, `ActiveEnergyBurned`, `AppleExerciseTime`, `TimeInDaylight`.
- Sending the same summary again writes nothing new. Send as often as you like.

Limits and errors:

| Case | Answer |
|---|---|
| Body over 4 MiB | 413. Send about 90 days per call, or the types in several calls. |
| More than 200 metrics, or more than 400 days in one metric | 422 |
| A `typeIdentifier` that does not look like a HealthKit identifier | 422 |
| A day value that cannot be true (negative steps, a future date) | 200, with the day in `rejected` and its reason, as in `POST /v1/daily` |
| No token, or a clinician's token | 401, 403 |

Pairing a second app: each app needs its own device token. Ask Mathew for a pairing code for the patient (`POST /v1/pair` turns it into a token once).

## 3. The day reading: Gemini reads the days, code checks every item

The same idea as the frame reading for the face numbers (`docs/face-raw.md`), on days.

- **Code, as before.** Each day is compared with the person's own normal (median and spread of their earlier days). Nothing below changes that, and nothing below reaches the patient, suggestions or lessons. One exception since 14 November: when the model finds something the fixed rules did not flag and code confirms it in the numbers (a lower stretch in the daily numbers that is still going on, or smiles that became faint over the last sessions), the mind opens a flag for the clinic at the lowest level, "noticed by the model, confirmed by code". It never brings an offer to the patient and never an alert by itself.
- **What the model receives.** With the patient's record allowing outside processing and level 2 on (since 14 November the second opinion on lessons is behind the same switch): one row per calendar day for the last 84 days at most, with a day number from 0 and the weekday (1 to 7) instead of a date, and the channels that have enough values: `steps` (rounded to 10), `walk_speed`, `sleep_h`, `hrv`, `rest_hr`, `active_kcal`, `exercise_min`, `daylight_min`. A day without a value is `null`. No dates, ids, names or text. The object has exactly three keys (`days`, `channels`, `rows`) and is checked again right before sending. At least 21 days with steps are needed.
- **What it returns** (`engine/clinic_engine/data/days_prompt.txt`): stretches where a channel changed against the weeks before, each `sustained` or `gradual`, lower or higher; the person's weekly rhythm (weekdays that are low week after week, which are not a change); gaps without data; and two overall words for the last seven days. Numbers only: never a mood, a symptom or a diagnosis.
- **Code checks every item** (`engine/clinic_engine/mind/day_reading.py`, thresholds `dayr_*`):
  - A named stretch is kept when the change is in the numbers: for `sustained`, its median lies at least 1.0 spreads from the days before; for `gradual`, the values fall day by day over at least 7 days and its last third lies 1.0 spreads from its first third. Otherwise it is dropped (`not_in_numbers`, `too_short`, `channel_missing`, `too_little_before`, `same_stretch_twice`).
  - It is "the same" as one of code's when code's own rule (at least 3 days, each 1.5 spreads outside the trailing normal) flagged a stretch that overlaps it by 0.3 of their union. It is "the model's alone" when code's rule flagged nothing there but the check above passes: a change too mild on any single day, or a slow slide. Code's stretches that the model did not name are listed as missed.
  - A weekday in the rhythm is confirmed when its median lies 1.0 spreads under the other days and four of every five of that weekday are low.
  - The overall words are shown as code's, with the model's beside them.
- **When it runs.** After new days arrive, at most every 6 hours per person; and on demand with `POST /v1/demo/analyze {"patient_id": "...", "what": "days"}`. `DAYS_READER=off` turns it off.
- **Where it shows.** Clinician only: `days_reading` in `GET /v1/clinic/patients/{id}` and the panel "Two readers on the daily numbers" on the Overview tab. `health_types` in the same answer lists the stored HealthKit types (counts and last day only).
- **The reference set.** `python -m clinic_engine.days_reference [--model]` makes 24 generated series of 84 days with changes planted at known places (8 sustained dips, 8 slow declines, 8 with nothing planted: weekly rhythm only, two single odd days, or a gap) and scores each reader against the planted truth. Run on 14 November 2026 with `gemini-3.8-flash` (its default thinking), 24 of 24 series read:

  | Reader | Sudden dips found | Slow declines found | Reported with nothing planted |
  |---|---|---|---|
  | Code, fixed rule (in the product) | 8 of 8 | 2 of 8 | 10 of 20 |
  | Code, simple trend scan (not in the product) | 0 of 8 | 7 of 8 | 29 of 36 |
  | Gemini, as reported | 8 of 8 | 8 of 8 | 0 of 16 |
  | Gemini, after code's check | 8 of 8 | 8 of 8 | 0 of 16 |

  The trend scan slides windows of 10 to 28 days over the steps and keeps those that pass code's own test for a slow decline or a dip; it was written after the model's result, to answer "could code find the slow declines alone?". It finds 7 of the 8 declines but marks long stretches around every change, so most of its reports do not line up with what was planted (which is also why it scores 0 on the short dips). A more careful rule would do better. Code's ten wrong reports are mostly short pieces of a slow decline that it flagged without seeing the whole (a piece overlaps the planted span by less than 0.3 of their union, so it counts as wrong). Of 35 planted low weekdays code named 34, and the model named 34 and none that was not planted. Against code's own stretches the model named 13 of 25 and added 5 that only it named and code confirmed; 4 of its stretches on other channels were not in the numbers and were dropped.

  Counted again later the same day on the setting the server now uses (the model asked to think little, about 4 seconds a call), 48 of 48 calls answered:

  | Set | Reader | Sudden dips found | Slow declines found | Reported with nothing planted |
  |---|---|---|---|---|
  | The same 24 series | Gemini, as reported | 8 of 8 | 8 of 8 | 2 of 18 |
  | The same 24 series | Gemini, after code's check | 8 of 8 | 8 of 8 | 0 of 16 |
  | 24 new series (`--seed 6000`), read once | Code, fixed rule | 8 of 8 | 3 of 8 | 5 of 16 |
  | 24 new series | Code, simple trend scan | 0 of 8 | 8 of 8 | 27 of 35 |
  | 24 new series | Gemini, as reported | 8 of 8 | 8 of 8 | 2 of 18 |
  | 24 new series | Gemini, after code's check | 8 of 8 | 5 of 8 | 1 of 14 |

  The new series were generated after the instruction and the check were frozen, and nothing was changed after seeing them. On them code's check did worse than on the first set: it removed one of Gemini's two wrong reports, let the other through, and dropped three slow declines Gemini had named correctly. The check is not yet a judge to trust over the model on slow declines. Low weekdays on the new series: 34 planted, code named 31, the model 33 and none that was not planted.

  What this does not show: anything about real lives. The series are made by that file, with simple noise and one planted change each; real series have illness, travel, holidays and missing weeks. Each series was read once. The first run used the model's default thinking; the later counts above used the fast setting the server now runs.

All thresholds here are estimates. None is calibrated on real series; that is part of the study (`docs/research-proposal.md`).
