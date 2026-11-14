# App and server: how they talk

For Peter. This is what the server does today in the fox design (`docs/game-design.md`), checked against the code in `engine/clinic_engine` on Saturday 14 Nov. The longer guide is `docs/api/README.md`. The exact contract is `docs/api/openapi.json`. If something here does not fit what the phone can do, say so and we change the server.

- **Demo server:** `https://lanvi.app`. Try every call in the browser at `https://lanvi.app/docs`.
- **Pairing code:** ask Mathew. It is not in the repo and must never be.
- All data on the demo server is example data.
- The calls the app already makes are in `ios/Lanvi/Net/LanviClient.swift` and `ios/Lanvi/Sense/HealthSync.swift`. Where the app does not use a call yet, this page says so.

## The basics

| Topic | Rule |
|---|---|
| Transport | HTTPS, JSON in and out |
| Who you are | `Authorization: Bearer <device token>` on every call except pairing and `/healthz`. No call takes a patient id: the token decides whose data it is. |
| Ids the app creates | 8 to 64 characters from `A-Z a-z 0-9 _ -`. A UUID fits. |
| Sending twice | Safe. Activities, feedback and notes are stored by their `id`, days by their `date`. |
| Times | ISO 8601 with a zone, for example `2026-11-14T09:12:03Z`. A time without a zone is refused. The server answers with `+00:00`. |
| Dates | The person's local calendar day, `YYYY-MM-DD` |
| Size limit | 256 KiB per request. `POST /v1/activities` alone takes up to 4 MiB, because of the face frames. |
| Rate limit | 120 requests a minute per token, with a burst of 60. Pairing: 10 a minute per address. |
| Unknown fields | Refused with 422. Send exactly the fields listed here. |

## The order of calls

| When | Call | In the app today |
|---|---|---|
| First start | `POST /v1/devices/pair` | yes, with the code from the build config |
| First start, once | `PUT /v1/preferences` | yes ("What usually helps you?") |
| First start, then every open | `POST /v1/daily` | yes |
| Every open, and after an activity | `GET /v1/today` | yes |
| Before the first check-in | `GET /v1/checkin/options` | yes |
| An activity ended | `POST /v1/activities` | yes |
| After an activity with face data | `GET /v1/activities/{id}/reading` | no, and not needed |
| A story came back | `POST /v1/lanvi/wanderings/{id}/answer` | yes |
| "I did it" or "Not today" on a suggestion | `POST /v1/feedback` | yes |
| Each chat message | `POST /v1/notes` | yes |
| "What Lanvi noticed" opens | `GET /v1/mind`, lesson reject, question answer | yes |
| The person's own rules | `POST /v1/mind/rules`, `DELETE /v1/mind/rules/{id}` | no |

## 1. Pair the phone

`POST /v1/devices/pair`, no token.

```json
{"pairing_code": "XXXX-XXXX-XXXX", "device_label": "iPhone 15", "platform": "ios"}
```

| Field | Rule |
|---|---|
| `pairing_code` | 12 to 20 characters, as given by the clinic. Works once. Valid 24 hours by default. |
| `device_label` | 1 to 40 characters: letters, digits, space, `.` `_` `-`. Not a person's name. |
| `platform` | `"ios"` |

Answer: `{"device_token": "...", "patient_id": "pat_..."}`. Keep the token in the Keychain. It is shown once. A wrong, used or expired code gives 400 `invalid_pairing_code`.

## 2. What helps (onboarding)

`PUT /v1/preferences`. Up to four of `music`, `moving`, `people`, `quiet`, each once, in the order chosen. An empty list is allowed. It sets the starting order of suggestions until the server has learned something. Sending it again replaces it.

```json
{"helps": ["quiet", "moving"]}
```

```json
{"helps": ["quiet", "moving"], "line": {"template_id": "preferences.quiet", "text": "Got it. I'll start with quiet breathing."}}
```

## 3. Send days from Apple Health

`POST /v1/daily`, 1 to 400 days per call.

```json
{"days": [
  {"date": "2026-11-12", "steps": 4210, "walking_speed_m_s": 1.12},
  {"date": "2026-11-13", "steps": 3890, "walking_speed_m_s": 1.08, "hrv_ms": 41.0, "sleep_h": 6.8}
]}
```

| Field | Rule | Accepted range |
|---|---|---|
| `date` | Required. Sending the same date again replaces it. Not more than 1 day ahead, not older than 400 days. | |
| `steps` | Required, whole number | 0 to 80,000 |
| `walking_speed_m_s` | Optional, metres per second | 0.1 to 3.0 |
| `hrv_ms` | Optional (SDNN), only with a watch | 5 to 250 |
| `sleep_h` | Optional, hours asleep, only with a watch | 0 to 18 |

```json
{"accepted": ["2026-11-12", "2026-11-13"], "rejected": [], "status": "within"}
```

A day that cannot be true comes back in `rejected` with a `reason` (for example `negative_steps`, `implausible_sleep_h`, `future_date`, `too_old`, `conflicting_duplicate`) and is not stored. The rest of the batch is still accepted. Send today as well; it is replaced as the day goes on.

## 4. Ask what to show

`GET /v1/today`. A real answer from a local test server with the example patient (`round_config` shortened):

```json
{
  "status": "within",
  "suggestion": {"id": "sug_bf77e64c0e43a422f41dfb86", "action": "breathing",
                 "text": "Want to breathe with me for a minute?", "created_at": "2026-11-13T09:00:00+00:00"},
  "lanvi": {
    "xp": 600, "stage": "grown_fox", "next_stage_at": null, "glow": 0.0,
    "wandering": {"state": "back", "id": "wander-0012", "returns_at": "2026-11-13T07:00:00+00:00",
                  "story": {"id": "story.cabin", "text": "I found a little cabin with smoke rising from the chimney. Someone had left a candle in the window.",
                            "question": "Was it left for travellers like me?",
                            "answers": [{"id": "a", "text": "I think so"}, {"id": "b", "text": "Maybe for someone else"}]}},
    "line": {"template_id": "back.1", "text": "I'm back. I have a little story for you."},
    "plan_to_ask": {"checkin_id": "example-act-020", "plan_id": "coffee_outside"}
  },
  "round_config": {"config_id": "standard"},
  "attention": "Your days look like your usual.",
  "crisis": {"text": "Lanvi is not an emergency service. In an emergency, call 112. Otherwise, contact your clinic.",
             "contacts": [{"label": "Emergency number", "phone": "112"}], "reviewed_by_clinician": false},
  "product_name": "Lanvi"
}
```

| Field | What the app does with it |
|---|---|
| `status` | `no_baseline` (fewer than 14 days yet), `within`, `outside` (a clear drop in movement), `no_data` (no day received for 3 days or more). Missing data is never shown as `within`. |
| `attention` | One sentence about the days, already worded for the person. One fixed sentence per status. |
| `suggestion` | `null`, or one: `id`, `action`, `text`, `created_at`. Never more than one open. Show `text` as it is. It expires after 20 hours or at the end of the day. |
| `suggestion.action` | `breathing`, `focus_game`, `checkin`, `walk_10min`, `daylight_10min`, `call_someone`. The first three open an activity. |
| `lanvi.xp`, `stage`, `next_stage_at` | Counted by the server. The app only shows them. Stages: `kit` from 0, `young_fox` from 100, `grown_fox` from 300. `next_stage_at` is null at the last stage. XP never goes down. |
| `lanvi.glow` | 0 to 1. It fills by 0.2 for every 10 XP. When full, a wandering starts. |
| `lanvi.wandering` | `state` is `home`, `away` (until `returns_at`, 3 hours) or `back` (a `story` waits). `id` and `returns_at` are null at home. |
| `lanvi.line` | What Lanvi says today, from a fixed set. When a suggestion is open it is the suggestion's text. |
| `lanvi.plan_to_ask` | Yesterday's plan, to ask about in tonight's check-in, or null. `plan_id` is null when the plan was typed; the app has the words on the phone. |
| `crisis` | The help screen content. Always present. Keep the last one so Help works offline. `reviewed_by_clinician: false` means draft wording; show it as such. |
| `product_name` | The name to show. The server reads it from its settings; the code default is still `Angel`. |
| `round_config` | Ignore. See "Earlier design" below. The real object has more fields than shown. |

## 5. Report an activity

`POST /v1/activities`, one record per activity. Send it also when the person stops early. Fields of every record:

| Field | Rule |
|---|---|
| `id` | your id |
| `type` | `focus`, `breathing` or `checkin` |
| `started_at` | time with a zone; not in the future, not older than 400 days |
| `duration_s` | seconds, 0 to 1800 |
| `completed` | true or false |
| `ended_by` | `finished`, `user_stopped`, `interrupted` |
| `suggestion_id` | optional: the suggestion it was played from. This marks the suggestion as done; no feedback call is needed. An unknown id gives 404. |

Fields per type:

| Type | Field | Rule |
|---|---|---|
| `focus` | `correct_taps`, `wrong_taps`, `misses` | whole numbers, 0 to 1000. `wrong_taps` is a tapped snowflake, `misses` a spark that faded. |
| `focus` | `reaction_ms` | list of whole milliseconds (0 to 10,000 each), at most 200, not more entries than taps. The server computes the statistics. |
| `breathing` | `time_played_s` | 0 to 3600, not more than `duration_s` + 1 |
| `breathing` | `breaths_completed` | optional, 0 to 200 |
| `focus`, `breathing` | `face_raw` or `face` | optional, see below. Never both. Never on a check-in. |
| `checkin` | `good_things` | 0 to 3 items |
| `checkin` | `plan` | one item or null |
| `checkin` | `plan_done` | `yes`, `no` or `not_asked` (the default): the answer about yesterday's plan |

A check-in item is `{"catalog_id": "walked"}` (ids from `GET /v1/checkin/options`, which returns `good_things` and `plans`, each a list of `{id, label}`) or `{"text": "a few words"}` (1 to 120 characters). Never both in one item.

A focus record with face frames (three frames only, to show the shape):

```json
{
  "id": "4f1c7f9e-2b7a-4d0e-9a51-0c3e5f7a9b21", "type": "focus",
  "started_at": "2026-11-13T08:55:03Z", "duration_s": 45.2, "completed": true, "ended_by": "finished",
  "correct_taps": 17, "wrong_taps": 1, "misses": 2, "reaction_ms": [512, 498, 530, 476, 551],
  "face_raw": {
    "rate_hz": 30,
    "channels": ["mouthSmileLeft", "mouthSmileRight", "eyeBlinkLeft", "eyeBlinkRight", "headPitch", "headYaw", "headRoll"],
    "samples": [[0.041, 0.052, 0.083, 0.071, 6.2, -1.4, 0.8], [0.047, 0.055, 0.092, 0.08, 6.1, -1.3, 0.8], [0.312, 0.288, 0.074, 0.069, 6.0, -1.3, 0.9]],
    "tracked": [1, 1, 1], "moments_ms": [40]
  }
}
```

A breathing record and a check-in record:

```json
{"id": "b7d2a1c4-63f0-4e0a-8d1e-5a9c2f4e7b10", "type": "breathing", "started_at": "2026-11-13T08:57:00Z",
 "duration_s": 61.0, "completed": true, "ended_by": "finished", "time_played_s": 60.0, "breaths_completed": 6}
```

```json
{"id": "c3e8f5a2-17b4-4c6d-9e2f-8a1b0d3c5e7f", "type": "checkin", "started_at": "2026-11-13T18:58:00Z",
 "duration_s": 52.0, "completed": true, "ended_by": "finished",
 "good_things": [{"catalog_id": "walked"}, {"catalog_id": "good_food"}, {"text": "my sister called"}],
 "plan": {"catalog_id": "coffee_outside"}, "plan_done": "not_asked"}
```

The answer (to the focus record above):

```json
{"id": "4f1c7f9e-2b7a-4d0e-9a51-0c3e5f7a9b21", "type": "focus", "xp_gained": 10, "xp_total": 610,
 "stage": "grown_fox", "next_stage_at": null, "glow": 0.2, "wandering": "back",
 "line": {"template_id": "focus_done", "text": "Thanks for playing with me. The sparks liked that."},
 "crisis": false, "crisis_block": null, "reading": "off"}
```

| Field | Meaning |
|---|---|
| `xp_gained` | XP this record earned now. 10 for each activity type, finished or not, whatever the score. 0 when the record was sent before, when the activity lasted under 5 seconds (not for a check-in), or after the day's limit: 2 focus, 2 breathing, 1 check-in. |
| `xp_total`, `stage`, `next_stage_at`, `glow` | as in `/v1/today`. They include other awards that became due: 15 when `plan_done` is `yes` for yesterday's plan, 5 for a day walked or slept around the person's own normal. |
| `wandering` | `home`, `away` or `back`. When it changed, call `/v1/today` for the detail. |
| `line` | one line for Lanvi to say now, from a fixed set |
| `crisis`, `crisis_block` | true, with the help block, when typed check-in words ask for help. Open Help at once. |
| `reading` | `pending`, `off`, `not_allowed` or `not_applicable`. See below. |

**`face_raw`** is what the phone sends when the person allowed the camera: the numbers ARKit gives per frame, nothing computed. The server computes every face measure and keeps the frames. Shape, channel names, how to get the head angles, limits and every error message: `docs/face-raw.md`. In short: `rate_hz` 5 to 60, at most 60 `channels` (the 52 ARKit blend shapes plus `headPitch`, `headYaw`, `headRoll`), four required channels (`mouthSmileLeft`, `mouthSmileRight`, `eyeBlinkLeft`, `eyeBlinkRight`), at most 12,000 `samples`, optional `tracked` (one 0 or 1 per frame), optional `moments_ms` (at most 20). The frames may not last longer than 1.2 times `duration_s` plus 5 seconds.

**`face`** is the older way: a summary the phone computed. Still accepted, numbers only. `tracking_quality` (0 to 1) is required; below 0.6 the summary is kept but not used. The first six optional fields: `smile_rate_per_min` (0 to 120), `smile_intensity` (0 to 1), `facial_activity` (0 to 1), `blink_rate_per_min` (0 to 120), `look_down_share` (0 to 1), `head_tilt_deg` (-90 to 90). The ten newer ones, all optional:

| Field | Range | What |
|---|---|---|
| `smile_time_share` | 0 to 1 | share of the time smiling |
| `eye_smile_share` | 0 to 1 | share of smiles with a cheek raise |
| `smile_response_share` | 0 to 1 | share of marked pleasant moments followed by a smile |
| `smile_response_latency_s` | 0 to 30 | median delay from such a moment to the smile |
| `brow_down_share` | 0 to 1 | share of the time with brows drawn down |
| `inner_brow_up_share` | 0 to 1 | share of the time with inner brows raised |
| `blink_duration_ms` | 0 to 2000 | median blink length |
| `head_pitch_deg` | -90 to 90 | average head angle; looking down is higher |
| `head_movement` | 0 to 1 | how much the head moved |
| `smile_asymmetry` | 0 to 1 | left-right difference of smiles |

**The reading.** `GET /v1/activities/{id}/reading` returns `{"status": ..., "line": ...}`. `status` is `pending`, `ready`, `failed`, `off`, `not_allowed` or `not_applicable`. When `ready`, `line` is one neutral sentence per type ("Thanks for playing Sparks and snow with me."). It never says anything about the face. The app does not call this today and loses nothing: it is a model's reading for the clinician, and it is off unless the server's outside model is switched on.

## 6. A story came back

When `lanvi.wandering.state` is `back`, show the story and its two answers, then send `POST /v1/lanvi/wanderings/{id}/answer` with `{"answer": "a"}` or `{"answer": "b"}`. The answer holds `id`, `answer` and the new `wandering` object. A wrong id, or no story waiting, gives 404.

## 7. Answer a suggestion

`POST /v1/feedback`, for a suggestion that was not played as an activity (a walk, daylight, a call) or was declined.

```json
{"id": "fb-7f3a91c2", "suggestion_id": "sug_bf77e64c0e43a422f41dfb86", "answer": "not_today", "felt": "rough"}
```

| Field | Values |
|---|---|
| `answer` | `did_it`, `not_today`, `something_else` |
| `felt` | optional: `rough`, `ok`, `good` |

Answer: `{"ok": true}`. An unknown suggestion gives 404. The app sends `did_it` and `not_today` today, never `something_else` or `felt`.

## 8. A few typed words, and the help path

`POST /v1/notes`. The chat screen sends each message as one note.

```json
{"id": "note-5c1d0a77", "text": "slept badly, quiet day"}
```

`text` is 1 to 280 characters. Answer:

```json
{"reply": {"template_id": "neutral", "text": "Thank you. I keep your words safe."},
 "crisis": false, "crisis_block": null, "suggestion": null}
```

- Show `reply.text` as Lanvi's answer.
- `suggestion` is the open suggestion, if there is one, in the same shape as in `/v1/today`.
- **Help path.** When the words ask for help or speak of self-harm, `crisis` is `true`, `crisis_block` holds the help block and the reply is the fixed help line. Open the Help screen at once and show nothing else first, also not the suggestion. A word list in code decides this (English, Finnish, Slovak; a draft, not yet reviewed by a clinician); a model can add to it but cannot switch it off. The clinic sees an "asked for help" item marked for review the same day.
- The same holds for typed check-in items: they are checked the same way and can set `crisis` on the activity answer.

Free text exists only here and in the typed check-in items.

**Chat mode.** It exists in the code and is off by default (`CHAT_MODE=fixed`): the reply is one of six fixed lines and the words never leave the server. With `CHAT_MODE=gemini` on the server, a note that did not open Help, from a person whose record allows outside processing, goes to Gemini with today's earlier turns (at most six), and Gemini writes the reply. Code checks it (at most 200 characters, plain text, no links, a banned-word list) and falls back to the fixed line on any doubt or after 4 seconds. The reply then has `template_id: "gemini"`. The response shape is the same, so the app needs no change. Whether it is on at the demo server: ask Mathew. Detail: `docs/api/README.md`, "Lanvi's reply".

## 9. What Lanvi noticed

`GET /v1/mind` returns `rules`, `lessons` (`id`, `text`, `action`, `effect`, `context`, `config_id`, `evidence_count`, `created_at`) and open `questions` (`id`, `text`, `answers`: always `yes`, `no`, `not_sure`). Show the texts as given.

| Action in the app | Call |
|---|---|
| "Not true" on a lesson | `POST /v1/mind/lessons/{lesson_id}/reject`, no body |
| Answer a question | `POST /v1/mind/questions/{question_id}/answer` with `{"answer": "yes"}` |
| Add a rule (not in the app) | `POST /v1/mind/rules` with `{"rule": {"type": "quiet_hours", "params": {"from": "21:00", "to": "08:00"}}}` |
| Remove a rule (not in the app) | `DELETE /v1/mind/rules/{rule_id}` |

Rule types: `quiet_hours {from, to}`, `seated_only {weekdays}`, `max_suggestions_per_day {n: 0 to 5}`, `no_action {action}`. At most 20 rules. The person's rules always beat what the server learned.

## What the app must handle

Every error has one shape, and the same `request_id` is in the `X-Request-Id` header. Give it to Mathew when something fails.

```json
{"error": {"code": "unauthorized", "message": "A bearer token is required.", "request_id": "e7cde9f5e783"}}
```

| HTTP | `code` | What to do |
|---|---|---|
| 400 | `invalid_pairing_code`, `too_many_rules` | Ask for a new code. |
| 401 | `unauthorized` | The token is missing or unknown. Pair again; this needs a new code. |
| 403 | `forbidden` | Wrong kind of token. A bug. |
| 404 | `not_found` | Not there, or not yours. For an activity with an old `suggestion_id`: send it again without it. |
| 409 | `conflict` | This `id` was used for a different record. Do not resend; a new record needs a new id. |
| 413 | `body_too_large` | Do not resend. For an activity, send it again without `face_raw`. |
| 422 | `invalid_request`, `implausible_activity` | A field is wrong, unknown or cannot be true. The message names the place, never your values. Do not resend unchanged. |
| 429 | `rate_limited` | Wait a few seconds and retry. |
| 500 | `server_error` | Retry later. |

- **Retries and sending twice.** The same activity again gives 200 with `xp_gained: 0`. The same note again gives the same reply. The same feedback id again is accepted. So keep the id with the record and retry freely after a timeout.
- **No network.** Keep activities and feedback on disk and send them on the next open. The app does this (`Net/ActivityOutbox.swift`). Health days are caught up on the next open. A chat message that failed is marked and can be sent again with its id.
- **Help screen.** Always reachable, built from the last `crisis` block received.
- **Text.** Everything the server sends for the person (`attention`, `suggestion.text`, `lanvi.line`, `line`, `reply.text`, stories, lesson and question texts) is shown as it is. The app adds no clinical wording of its own.

## What the server never asks from the phone

No name, email or phone number, no location, no camera image, no video, no face mesh or landmarks, no raw Apple Health samples. Only daily totals, the activity record, the face numbers per frame when the person allowed the camera, and the words the person typed.

## Earlier design (do not build on it)

`POST /v1/rounds` and `GET /v1/rounds/{id}/analysis` still answer, and `GET /v1/today` still carries `round_config`, so a build of the AR "catch the lights" design does not break. They are marked deprecated and are not part of the fox design.

## Points to confirm, Peter

1. A 401 after pairing: the app tries to pair again with the code from the build config, which works only once. Do we need a screen to type a new code, or is a rebuild fine for the demo?
2. Head pitch sign on a real phone: looking down must be positive (`ios/SENSORS.md`, device test 6). Not yet checked on a device as far as the repo shows.
3. The app never sends `ended_by: "interrupted"`: `Screens/ActivityRouter.swift` sends `finished` or `user_stopped` only. Fine for the weekend, or do you want it?
4. `moments_ms`: the app marks a moment when Lanvi cheers. Is that the right pleasant moment for the smile response?
5. Walking speed, HRV and sleep: left out on days Apple Health has none. Confirm on a phone without a watch that steps and walking speed arrive.
6. Size: the app caps `face_raw` at 9,000 rows (about 3 MB). The server limit is 12,000 rows and 4 MiB. Tell us if a real session is refused with 413.
