# Sensors on an activity: the watch's heart and the game's moments

For the iOS developer and for Mathew. During Sparks and snow, Breathe with Lanvi or the evening check-in, the phone may send, with the activity record, what the Apple Watch measured and what happened in the game, and when. **The phone computes nothing from it.** The server checks the numbers, computes the summary, keeps the rows for research, and (with consent and Gemini on) runs the sensor reading. The iOS side is described in `ios/WATCH.md`.

Send numbers and fixed codes only. Never a name, a device name, typed words, or the labels the person tapped.

## Where it goes

`sensors` is one optional field of the activity record sent to `POST /v1/activities` (`docs/api/README.md`, step 5). It is allowed on all three types. It sits next to `face_raw` (`docs/face-raw.md`); the two share one clock anchor so face frames, heart samples and game moments line up.

## The shape

```json
{
  "id": "6d0a3c1e-6a0e-4b1e-9c7a-2f8a2d5b1c44",
  "type": "focus",
  "started_at": "2026-11-14T09:12:03.412Z",
  "duration_s": 45.2,
  "completed": true, "ended_by": "finished",
  "correct_taps": 17, "wrong_taps": 1, "misses": 2, "reaction_ms": [512, 498, 530],
  "sensors": {
    "clock": {"started_uptime_s": 48213.412},
    "watch": {"source": "apple_watch", "workout": true, "started_ms": -8200},
    "heart_rate": [[-8000, 71.0], [-3000, 72.0], [2000, 74.0], [7000, 78.0]],
    "hrv_sdnn": [[-6000, 38.5]],
    "moments": [
      {"name": "focus_started", "t_ms": 0, "wall_ms": 0},
      {"name": "spark_caught", "t_ms": 1840, "wall_ms": 1841, "value": 512},
      {"name": "snow_tapped", "t_ms": 9020, "wall_ms": 9020},
      {"name": "focus_ended", "t_ms": 45200, "wall_ms": 45201, "value": 1}
    ],
    "face_offset_ms": -412
  }
}
```

| Field | Required | What |
|---|---|---|
| `clock.started_uptime_s` | yes | The phone's monotonic clock (`CACurrentMediaTime()`, the clock of `ARFrame.timestamp`) at `started_at`. With `started_at` (wall clock) this is the one anchor every time below refers to. |
| `watch` | no | `source` is always `apple_watch`; `workout` true when recorded inside an `HKWorkoutSession`; `started_ms` when the watch began, ms from `started_at` (negative: before the game). |
| `heart_rate` | no | `[t_ms, bpm]` rows, oldest first. `t_ms` is HealthKit's own sample start time minus `started_at`, wall clock. At most 2000. |
| `hrv_sdnn` | no | `[t_ms, sdnn_ms]` rows, the same way. The watch writes HRV only now and then; this is usually empty. At most 100. |
| `moments` | no | Every game moment (`ios/Lanvi/Screens/Games/GameMoments.swift`): `name` from the list below, `t_ms` on the monotonic clock (exact), `wall_ms` on the wall clock (so clock drift is visible), the small `value` it carried (reaction ms for `spark_caught`, breath number for the breath moments, 1 or 0 finished for the `_ended` moments) or the check-in `step` (`plan_question`, `good_things`, `plan`, `goodnight`). At most 400. |
| `face_offset_ms` | no | The first `face_raw` frame, ms from `started_at` on the monotonic clock. Frame `i` is then at `face_offset_ms + i * 1000 / rate_hz`. Only with `face_raw`. |

Moment names: `focus_started`, `spark_caught`, `snow_tapped`, `spark_missed`, `focus_ended` (focus); `breathe_started`, `breath_in`, `breath_hold`, `breath_out`, `breathe_ended` (breathing); `checkin_started`, `checkin_step`, `checkin_ended` (checkin). A moment from another activity type is refused.

## What the server does

1. **Checks** (`mind/sensors.py`, `check_sensors`): heart rate 25 to 250 bpm, HRV 0 to 500 ms, every time between 10 minutes before `started_at` and 60 seconds after the end, rows in time order, known moment names for the activity's type, the two clocks of a moment within 2 seconds, `face_offset_ms` only with frames. A failure rejects the record (422 `implausible_activity`, reason in the message) and is logged like any other rejection.
2. **Keeps the rows** as their own object, `sensors/{activity_id}.json`, outside the activity record and outside every model pack. Clinicians can download it: `GET /v1/clinic/patients/{id}/activities/{activity_id}/sensors` (audited).
3. **Summary** (`summarize`), stored on the record as `sensors_summary`: heart rate inside the activity (mean, median, min and max with their times, the first and last 15 seconds and their difference, `trend` rising/falling/steady/unclear at 3 bpm, least-squares slope, coverage), the resting stretch before Start, the HRV samples as they are, moment counts by name, heart rate in the 5 seconds after each kind of moment against the session mean, one row per breath for Breathe with Lanvi, and the alignment facts. Shown on the clinician page as `sensors` per session. Nothing in the mind reads it: no attention, no suggestion, no lesson changes because of it.
4. **Sensor reading** (`mind/sensor_reading.py`, prompt `data/sensors_prompt.txt`), clinician-only, like the frame reading: with `OUTREACH_MODE=gemini` and the patient's outside-processing consent, Gemini receives an anonymous object (activity type, duration, heart-rate rows in seconds from the start rounded to whole beats and thinned to 150 rows, HRV rows, the moments as `[t_s, code]`, the game's own numbers, the five face summary numbers when the face was tracked well) and answers in fixed words: the heart-rate trend with copied start, end and peak values, heart rate after each kind of moment, whether the heart slows over the breaths, HRV present or not, a face-and-heart pattern, data quality, confidence. **Code checks every item** against its own view of the same object (`verify`): a claim code cannot confirm becomes `unclear`, a copied number that is not in the data becomes null, and each drop is logged. Stored as `sensor_reading` on the record and shown to the clinician; never to the patient. `SENSOR_READER=off` turns it off.

## Limits

Body size follows the activity route: 256 KiB, or 4 MiB when `face_raw` is present. A full session (a minute of heart rate every second, a few hundred moments) is well under 50 KB.
