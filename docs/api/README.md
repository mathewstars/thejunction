# Clinic engine API: guide for the iOS app

The full contract is `openapi.json` in this folder (exported from the running code with `python -m clinic_engine.export_openapi`). This page is the short version: auth, the calls in order, examples, errors.

The product is Lanvi, a small Arctic fox on the phone (`docs/game-design.md`). The server reads the name from `PRODUCT_NAME` (set it to `Lanvi`; the code default is still `Angel`) and returns it in `GET /v1/today`.

## Run it locally

```sh
cd engine
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
export STORE=dir STORE_DIR=./data             # local folder store (git-ignored)
.venv/bin/python -m clinic_engine.seed --extra 3 --pairing-code   # prints tokens ONCE
.venv/bin/uvicorn clinic_engine.app:app_from_env --factory --host 127.0.0.1 --port 8080
.venv/bin/python -m pytest -q                  # tests, fully offline
```

Interactive docs while it runs: `http://127.0.0.1:8080/docs`. The clinician web page is at `http://127.0.0.1:8080/` (see "The clinician page" below).

## The demo server

The engine also runs on a demo server: `https://lanvi.app`. Someone close who also hears (a first, small version): with `FAMILY_CONTACTS` set to `Name=telegram chat id;Name=chat id`, a clinician can choose one of those people for a patient (`GET /v1/clinic/family-contacts`, `PUT /v1/clinic/patients/{id}/family-contact`); when the clinic is sent a "needs review" message about that patient, the person gets one line on Telegram that names nobody and says nothing about health. On that server linking is switched off for now: with `OPEN_PAIRING_PATIENT` set to a patient's label, `POST /v1/devices/pair` connects every phone to that one patient and does not look at the code (empty, the default, means one-time codes are checked). Interactive docs: `https://lanvi.app/docs`. Every call under `/v1` needs a bearer token; ask Mathew for the pairing code and the clinician login, they are not in this repo. All data on it is example data.

## Auth

Every call except `/healthz`, `/v1/devices/pair` and `/v1/clinic/login` needs

```
Authorization: Bearer <token>
```

| Token | Where it comes from | What it may call |
|---|---|---|
| device | `POST /v1/devices/pair`, once per phone | the device and mind calls below, for its own patient only |
| clinician | `POST /v1/clinic/login`, short-lived | `/v1/clinic/...`, for its own clinic only |
| admin | printed once by the seed script | `/v1/demo/...`, `/v1/review/run` |
| clinician of the seeded demo clinic | `POST /v1/clinic/login` | also `/v1/demo/...` and `/v1/review/run`, for patients of that clinic only, and only while `DEMO_ENABLED` is true. With demo mode off these stay admin-only. |

Tokens are 256-bit random strings. The server stores only their SHA-256 hash. Keep the device token in the Keychain. No device call takes a patient id: the token decides whose data it is.

## The calls, in order

1. **Pair once.** The clinic gives the person a one-time code.
   ```sh
   curl -X POST $B/v1/devices/pair -H 'Content-Type: application/json' \
     -d '{"pairing_code":"ABCD-EFGH-JKLM","device_label":"iPhone 15","platform":"ios"}'
   # {"device_token":"...","patient_id":"pat_..."}
   ```
   The code works once and expires (24 h by default). A second use is refused.

2. **Send daily data** (Apple Health). One day, or a batch of history on first launch (up to 400 days). Merged by date: a field left out keeps the stored value, an unchanged day is not written again, so re-sending days is fine (the app re-sends the last 14 days on every open).
   ```sh
   curl -X POST $B/v1/daily -H "Authorization: Bearer $DT" -H 'Content-Type: application/json' \
     -d '{"days":[{"date":"2026-11-13","steps":6400,"walking_speed_m_s":1.24,"hrv_ms":42,"sleep_h":7.1}]}'
   # {"accepted":["2026-11-13"],"rejected":[],"status":"within"}
   ```
   `hrv_ms` and `sleep_h` are optional (watch only). Values that cannot be true (negative, absurd, future dates, two different values for one date in one batch) come back in `rejected` with a reason and are never used.

3. **Onboarding: what helps** (once, may be sent again to change it).
   ```sh
   curl -X PUT $B/v1/preferences -H "Authorization: Bearer $DT" -H 'Content-Type: application/json' \
     -d '{"helps":["moving","quiet"]}'
   # {"helps":["moving","quiet"],"line":{"template_id":"preferences.moving","text":"Got it. I'll start with walks."}}
   ```
   `helps`: up to four of `music | moving | people | quiet`, in the order chosen. It sets the starting order of suggestions until the first lesson exists.

4. **Ask what to show.**
   ```sh
   curl $B/v1/today -H "Authorization: Bearer $DT"
   ```
   ```json
   {"status": "outside",
    "suggestion": {"id": "sug_...", "action": "breathing", "text": "Want to breathe with me for a minute?", "created_at": "..."},
    "lanvi": {"xp": 385, "stage": "grown_fox", "next_stage_at": null, "glow": 0.7,
              "wandering": {"state": "back", "id": "wander-0006", "returns_at": "...",
                            "story": {"id": "story.reindeer", "text": "I met a reindeer by a frozen lake. ...",
                                      "question": "Should I help her count tomorrow?",
                                      "answers": [{"id": "a", "text": "Yes, help her"}, {"id": "b", "text": "Let her count alone"}]}},
              "line": {"template_id": "back.1", "text": "I'm back. I have a little story for you."},
              "plan_to_ask": {"checkin_id": "...", "plan_id": "coffee_outside"}},
    "round_config": {"...": "deprecated, for apps of the earlier AR design"},
    "attention": "Your movement has been lower than your usual for a few days.",
    "crisis": {"text": "Lanvi is not an emergency service. In an emergency, call 112. Otherwise, contact your clinic.",
               "contacts": [{"label": "Emergency number", "phone": "112"}], "reviewed_by_clinician": false},
    "product_name": "Lanvi"}
   ```
   - `status`: `no_baseline` (fewer than 14 days yet), `within`, `outside`, `no_data`. Missing data is always `no_data`, never `within`.
   - `suggestion` is at most one, or null. Show `text` as is. Actions: `breathing`, `focus_game`, `checkin`, `walk_10min`, `daylight_10min`, `call_someone`.
   - `lanvi` (the server counts XP; the app only shows it):

     | Field | Meaning |
     |---|---|
     | `xp` | total XP, never goes down |
     | `stage` | `kit` (0), `young_fox` (100), `grown_fox` (300) |
     | `next_stage_at` | XP of the next stage, or null at the last one |
     | `glow` | 0 to 1; full starts a wandering |
     | `wandering.state` | `home`, `away` (until `returns_at`), `back` (a story waits) |
     | `wandering.id`, `wandering.returns_at` | while away or back |
     | `wandering.story` | when back: `id`, `text`, `question`, two `answers` (`a`, `b`) |
     | `line` | `{template_id, text}`: what Lanvi says today, from the fixed set |
     | `plan_to_ask` | yesterday's plan to ask about tonight (`plan_id` is null when it was typed), or null |

   - `crisis` is **always** present. While `reviewed_by_clinician` is false, show it as draft wording.
   - XP rules (design values in `engine/clinic_engine/mind/lanvi_config.py`): Revontulet played 10, Breathe with Lanvi 10, evening check-in 10, yesterday's plan done 15, a day walked or slept around own normal 5. Same XP whatever the score; stopped early still counts. Each record counts once, and per day at most 2 focus, 2 breathing and 1 check-in award. No streaks.

5. **After an activity, send it.** One record per activity, idempotent by your `id`.
   ```sh
   curl -X POST $B/v1/activities -H "Authorization: Bearer $DT" -H 'Content-Type: application/json' -d @activity.json
   # {"id":"...","type":"focus","xp_gained":10,"xp_total":350,"stage":"grown_fox","next_stage_at":null,"glow":0.9,
   #  "wandering":"home","line":{"template_id":"focus_done","text":"Thanks for playing with me. The fox fires liked that."},
   #  "crisis":false,"crisis_block":null,"reading":"off"}
   ```
   Two rules the models do not show: `duration_s` above 1800 is refused (422 `implausible_activity`), and an activity shorter than 5 seconds is stored but earns no XP.

   Fields (every record):

   | Field | Type |
   |---|---|
   | `id` | your id, 8 to 64 of `A-Z a-z 0-9 _ -` |
   | `type` | `focus`, `breathing` or `checkin` |
   | `started_at` | ISO time with a zone |
   | `duration_s` | number |
   | `completed` | bool |
   | `ended_by` | `finished`, `user_stopped`, `interrupted` |
   | `suggestion_id` | optional: the suggestion it was played from |

   `focus` (Revontulet; the app sends its measures in the `revontulet` object below, and a record without it is still taken and read from the taps alone): `correct_taps` (launches and embers tapped), `wrong_taps` (always 0), `misses` (embers not tapped; whole numbers), `reaction_ms` (list of whole milliseconds, at most 200; the server computes the statistics), optional `face_raw` (or, from older clients, `face`).

   `revontulet` (optional, only on `focus`, only from the Revontulet game): what that game measures beyond taps and reaction times. Leave it out (or send null) and the record means exactly what it did before; a record without it hashes as before. Numbers only, no touch paths or positions; every object refuses unknown fields (422 `invalid_request`). What each measure is and the study idea behind it: [`docs/revontulet-measures.md`](../revontulet-measures.md).

   ```json
   "revontulet": {
     "rounds": [{"effort": "hard", "choice_ms": 940, "trace_start_ms": 960, "trace_ms": 1220, "trace_length_pt": 279.3,
                 "trace_mean_speed_pt_s": 228.9, "trace_peak_speed_pt_s": 455.0, "trace_lifts": 0,
                 "pull_pt": 108.2, "pull_hold_ms": 540, "embers_shown": 2, "embers_hit": 2, "bonus": true}],
     "strokes": [{"ms": 1450, "length_pt": 410.0, "mean_speed_pt_s": 282.8}],
     "broke_through_s": 52.4, "fox_finished": false, "pt_per_cm": 64.2, "touch_radius_mean_pt": 21.3, "touch_radius_var": 4.7}
   ```

   | Field | Limits |
   |---|---|
   | `rounds` | 0 to 3. `effort` `easy` or `hard` and `choice_ms` (0 to 120000) required. Optional: `trace_start_ms` (0 to 120000, the half-circle appearing to the first touch on it), `trace_ms` (0 to 120000), `trace_length_pt` (0 to 20000, default 0), `trace_mean_speed_pt_s` (0 to 20000), `trace_peak_speed_pt_s` (0 to 50000), `trace_lifts` (0 to 100, default 0), `pull_pt` (0 to 2000), `pull_hold_ms` (0 to 120000), `embers_shown` and `embers_hit` (0 to 5, default 0, hit at most shown), `bonus` (default false) |
   | `strokes` | 0 to 10, each `ms` (0 to 60000), `length_pt` (0 to 20000), `mean_speed_pt_s` (0 to 20000) |
   | `broke_through_s` | 0 to 600 or null. More than `duration_s` + 1: 422 `implausible_activity` (`broke_through_after_end`) |
   | `fox_finished` | true when time ran out and the fox's own spark broke the wall; false or null otherwise |
   | `pt_per_cm` | 10 to 400 or null |
   | `touch_radius_mean_pt`, `touch_radius_var` | 0 to 200 and 0 to 10000, or null |

   With `revontulet`, `reaction_ms` holds only the ember taps (flash to finger); the first touch on each half-circle is `trace_start_ms`. Stored with the activity and returned on the clinician's focus sessions. Not yet used for the day, suggestions, XP or the own normal.

   `breathing` (Breathe with Lanvi): `time_played_s`, optional `breaths_completed`, optional `face_raw` (or `face`).

   `checkin` (evening, once a day): `good_things` (0 to 3 items), `plan` (one item or null), `plan_done` (`yes | no | not_asked`, about yesterday's plan). An item is either `{"catalog_id": "walked"}` (ids from `GET /v1/checkin/options`) or `{"text": "a few words"}` (at most 120 characters), never both.

   `face_raw` (only on focus and breathing, only when the person allowed the camera): the raw numbers ARKit gives per frame. **The phone computes nothing on the face; the server computes every face measure** and keeps the frames so the rules can change and sessions can be analysed again. Shape, channel list, limits and the rules the server applies: [`docs/face-raw.md`](../face-raw.md). In short:

   ```json
   "face_raw": {"rate_hz": 30,
                "channels": ["mouthSmileLeft", "mouthSmileRight", "eyeBlinkLeft", "eyeBlinkRight", "headPitch", "headYaw", "headRoll"],
                "samples": [[0.04, 0.05, 0.08, 0.07, 6.2, -1.4, 0.8], [0.05, 0.05, 0.09, 0.08, 6.1, -1.3, 0.8]],
                "tracked": [1, 1], "moments_ms": [40]}
   ```

   Channels are the 52 ARKit blend-shape names plus `headPitch`, `headYaw`, `headRoll` (degrees); `mouthSmileLeft`, `mouthSmileRight`, `eyeBlinkLeft`, `eyeBlinkRight` are required. At most 60 channels, 12,000 samples and 20 moments; this route accepts bodies up to 4 MiB (all other routes keep 256 KiB). Unknown or repeated channel names, a row of the wrong length, a number that is not finite, a blend shape outside 0 to 1 (a 0.02 overshoot is allowed and clamped) or an angle outside -180 to 180 give 422 `invalid_request` with a message naming the position. `face` and `face_raw` together: 422. Frames lasting much longer than `duration_s`: 422 `implausible_activity` (`face_frames_longer_than_activity`). Re-sending the same record (same frames) answers with `xp_gained: 0`; the frames are stored once.

   `face_fine` (optional, on focus and breathing): fine facial movement the phone computed from the TrueDepth mesh or depth map. One distance in millimetres per named region and frame, how far the region is from the person's own resting shape with the head's movement taken out. No mesh, depth or coordinates are accepted. The server sums it up and keeps it. One flag reads its reach ("less facial movement", over the last five sessions against the person's own usual); no model reads it. Shape, region names, limits and errors: `docs/face-fine.md`.

   `face` (older clients: a summary the phone computed; still accepted, numbers only, no frames, images or landmarks): `smile_rate_per_min`, `smile_intensity` (0-1), `facial_activity` (0-1), `blink_rate_per_min`, `look_down_share` (0-1), `head_tilt_deg`, all optional, and `tracking_quality` (0-1, required). Below 0.6 the summary is kept but not used.

   - Re-sending the same record answers with `xp_gained: 0`; a different record under a used id is 409.
   - Implausible values reject the record with 422 `implausible_activity` (logged).
   - `crisis: true` (with `crisis_block`) when typed check-in words ask for help: show the help screen at once, as for a note.
   - `reading`: `pending` when the level-2 session reading runs in the background, `off`, `not_allowed`, or `not_applicable` (a check-in, or no face summary or frames). Poll `GET /v1/activities/{id}/reading` for `{"status":"ready","line":"..."}`; the line is neutral and from a fixed set.

6. **A story came back.** When `lanvi.wandering.state` is `back`:
   ```sh
   curl -X POST $B/v1/lanvi/wanderings/wander-0006/answer -H "Authorization: Bearer $DT" \
     -H 'Content-Type: application/json' -d '{"answer":"a"}'
   ```

7. **Earlier AR design (deprecated).** `POST /v1/rounds` and `GET /v1/rounds/{id}/analysis` still work so an older app does not break. Do not build on them.

8. **Answer the suggestion** (when it was not played as an activity). Enums only. Idempotent by your `id`.
   ```sh
   curl -X POST $B/v1/feedback -H "Authorization: Bearer $DT" -H 'Content-Type: application/json' \
     -d '{"id":"fb-7f3a91c2","suggestion_id":"sug_...","answer":"did_it","felt":"ok"}'
   ```
   `answer`: `did_it | not_today | something_else`. `felt` (optional): `rough | ok | good`.

9. **A few words (optional).** See "Free text" below.
   ```sh
   curl -X POST $B/v1/notes -H "Authorization: Bearer $DT" -H 'Content-Type: application/json' \
     -d '{"id":"note-5c1d0a77","text":"slept badly, quiet day"}'
   # {"reply":{"template_id":"low_1","text":"..."},"crisis":false,"crisis_block":null,"suggestion":null}
   ```
   When `crisis` is true, show `crisis_block` right away.

10. **"What works for you"** screen.
   ```sh
   curl $B/v1/mind -H "Authorization: Bearer $DT"
   # {"rules":[...],"lessons":[{"id":"les_...","text":"Breathe with Lanvi seemed to suit you, so it comes first now.","evidence_count":3,...}],
   #  "questions":[{"id":"q_...","text":"Was a short walk too much on some days?","answers":["yes","no","not_sure"]}]}
   curl -X POST $B/v1/mind/lessons/les_.../reject   -H "Authorization: Bearer $DT"
   curl -X POST $B/v1/mind/questions/q_.../answer  -H "Authorization: Bearer $DT" -H 'Content-Type: application/json' -d '{"answer":"yes"}'
   curl -X POST $B/v1/mind/rules -H "Authorization: Bearer $DT" -H 'Content-Type: application/json' \
     -d '{"rule":{"type":"quiet_hours","params":{"from":"21:00","to":"08:00"}}}'
   curl -X DELETE $B/v1/mind/rules/rule_... -H "Authorization: Bearer $DT"
   ```
   Rule templates: `quiet_hours {from, to}`, `seated_only {weekdays: [mon..sun]}`, `max_suggestions_per_day {n: 0..5}`, `no_action {action}`. The person's rules always beat what the mind has learned. A rejected lesson does not come back from the same evidence.

Ids you generate (`id` of activities, feedback, notes) are 8 to 64 characters of `A-Z a-z 0-9 _ -`; a UUID works.

## Free text, and why everything else is enums

Free text exists in exactly two places: `POST /v1/notes` `text` (at most 280 characters) and the typed items of a check-in (`good_things[].text`, `plan.text`, at most 120 characters each). Both go through the same code. Everything else is numbers, dates, ids and enums, and every request model rejects unknown fields. This removes the prompt-injection surface on purpose: nothing a person types can steer what the server does.

How the text is treated (a typed check-in item is stored as a note with `source: "checkin"`; the activity record keeps only a reference):

- It is untrusted data. It is never an instruction, never placed into a system prompt, and never copied into lessons, summaries, notifications or logs.
- Where it goes depends on one server setting, `CHAT_MODE` (see "Lanvi's reply: fixed or written by Gemini" below). With `CHAT_MODE=fixed`, the default, it never leaves the server (the level-2 input gate refuses any pack that would carry it). With `CHAT_MODE=gemini`, a note can go to Gemini, an outside model, so that Gemini writes Lanvi's reply. Typed check-in words never leave the server in either mode.
- It is only classified: a word-list check in code (English, Finnish, Slovak; a draft list in `engine/clinic_engine/data/note_lexicon.json`, not yet reviewed by a clinician) plus, when available, the local model through the gates. The model may only return a fixed JSON of enums: `mood`, `asks_for_help`, `topic`, and one reply template id from a list.
- The word list has two groups: `help_seeking` (help-seeking and self-harm language) and `low_mood` (words of a low day).
- When `crisis` is true: only help-seeking or self-harm language opens the help screen.
  - A `help_seeking` hit always gives `crisis: true`, whatever the model says, and also when the model is down or its answer is refused.
  - A model answer with `asks_for_help: true` also gives `crisis: true`.
  - `low_mood` words alone, or an unclear or refused model answer on a note with no help-seeking hit, give `crisis: false`. Such a note still sets the mood to `low` and counts as evidence: several low notes open or raise an attention item (`low_notes`) for the clinician.
- With `CHAT_MODE=fixed` the reply is a vetted template picked by code, never generated text. A check-in's reply is always a fixed line.
- The clinician sees that a note exists, its time, its classification and Lanvi's reply (marked "fixed line" or "written by Gemini, checked by code"). The text itself only when the patient record allows it (`share_notes`, default off).

### Lanvi's reply: fixed or written by Gemini (`CHAT_MODE`)

`CHAT_MODE=fixed` (default): everything above holds. Nothing a person types is sent to an outside model, and the reply is one of the fixed lines.

`CHAT_MODE=gemini` makes the note a short conversation. The order is fixed in code:

1. The note is classified exactly as above: the word list and the local model decide `crisis`. If the note opens the help screen (`crisis: true`, or any help-seeking hit), it never reaches Gemini, and the reply is the fixed help line. The model cannot switch the help screen off.
2. Only for the other notes, and only when the patient record allows outside processing (`allow_outside_processing`, the same consent as the session reading), the server asks Gemini for Lanvi's reply.
3. Code checks the answer before the person sees it: at most 200 characters, plain text, no links, no long numbers, at most one question, and a word list (clinical and diagnostic words, medical and medication advice, promises, claims to feel what the person feels, talk about being a model, anything about self-harm). Any refusal, an empty answer, an error, no answer within 4 seconds (`CHAT_TIMEOUT_S`), or a missing key or model id gives the fixed line. The person never sees an error.

What is sent to Gemini in `gemini` mode: a fixed instruction (Lanvi is a small Arctic fox, not a human and not a therapist; one or two warm sentences), the words of the note just written, and today's earlier turns of the conversation (the person's earlier notes from today and Lanvi's replies to them, at most six, never a note that opened the help screen). Each text is cut to 300 characters.

What is never sent: names, the clinic's label for the person, any id, dates, the time zone, check-in words, notes from other days, mood or topic labels, numbers from the phone, or anything else from the record. If the person's words contain the record's own name, label or an id, nothing is sent and the reply is the fixed line.

The reply is `{"template_id": "gemini", "text": ...}` in the same response shape, so the app needs no change. It is stored with the note. The full exchange (what was sent and what came back) is kept with the patient's other model exchanges; the person's words in it are hidden from the clinician unless `share_notes` allows them. The audit and the trace keep codes only.

To switch it on, put in the server's `.env`: `CHAT_MODE=gemini`, `GEMINI_API_KEY`, and a model id in `CHAT_MODEL` (or `GEMINI_MODEL`). `CHAT_THINKING` (for example `low`) asks the chat model to think less so it answers sooner; empty, the default, sends no such setting. It does not need `OUTREACH_MODE`.

## The open demo (no login, read only)

`DEMO_PUBLIC=true` (off by default, and only while `DEMO_ENABLED` is on) opens the page at `/demo`. The page asks `POST /v1/clinic/visit` for a visitor token, valid two hours. A visitor may `GET` what a clinician of the demo clinic may `GET`, and nothing else: every other method answers 403, on every endpoint. It sees the generated example patients only. A profile that holds a real person's data (a patient, or the team's test play) is shown only when its patient record carries `open_demo: true`, which the person it belongs to has to agree to. The demo panel is never offered. Tests: `engine/tests/test_open_demo.py`.

## The clinician page

The engine serves a plain web page for clinicians at `/` (files in `engine/clinic_engine/web/`, no build step, no outside resources, its own strict Content-Security-Policy). It uses only these calls:

| Call | What the page uses it for |
|---|---|
| `GET /healthz` | Product name on the login screen |
| `POST /v1/clinic/login` | Session token, kept in memory and `sessionStorage` only |
| `GET /v1/clinic/me` | Product name, clinic name, and whether the demo panel may be shown (`demo.enabled`) |
| `GET /v1/clinic/patients` | One line per patient, those needing a look first. Also `spark` (28 daily movement z-scores, null for missing days), `since` (oldest held item), `level` (highest held level) and `reason_short` (at most 6 words, from a fixed set) |
| `GET /v1/clinic/patients/{id}` | Detail; `progress.band` gives the own-normal band for the charts. `activities` has per type (`focus`, `breathing`, `checkin`) the sessions with date, completed, headline `values` and their `z` against own normal (or null), the face summary with tracking quality, the checked session reading, and `counts` (offered, played when offered, played, finished) for the last 7 and 28 days. Each focus or breathing session has `face_source` (`raw`: computed by the server from frames, `summary`: sent by the phone, or null) and, for raw sessions, `raw` `{rate_hz, frames, tracked_share, channels}` (counts only, never the frames), and `frames_reading` (below). Each focus session also has `revontulet`: the Revontulet measures as sent, or null for other focus games. `lanvi` has `xp` and `stage` (small facts, not clinical signals) |
| `GET /v1/clinic/patients/{id}/trace` | The decision trace; every chain has a `headline` (at most 6 words) and an `outcome` (`attention_opened`, `attention_raised`, `attention_closed`, `suggested`, `message_sent`, `refused`, `nothing`) |
| `GET /v1/clinic/patients/{id}/rounds/{round_id}` | Round detail; `usual_round` (or null) gives a usual round of the same mode for the second trail |
| `GET /v1/clinic/patients/{id}/activities/{activity_id}/face-raw` | Research download: the stored raw frames of one session as the phone sent them, plus `frames`, `channel_count`, `tracked_frames`. 404 when the session has no frames. Each download is audited (activity id only, no values) |
| `GET /v1/clinic/patients/{id}/activities/{activity_id}/face-fine` | Research download: the server's summary of fine facial movement for one session (`summary`, `info`) and the stream as the phone sent it (`stream`). 404 when the session was sent without `face_fine`. Audited. |
| `POST /v1/clinic/attention/{id}/ack` | The Acknowledge button |
| `/v1/demo/...`, `/v1/review/run` | The demo panel, only for the demo clinic while demo mode is on. `POST /v1/demo/recompute-face {"patient_id"}` computes the face summary of every raw session of the patient again from the stored frames with the current thresholds and returns `{"patient_id", "recomputed": n}`. `POST /v1/demo/analyze {"patient_id", "activity_id", "what": "frames"}` runs the frame reading of one raw session now and returns its `frames_reading` (`what` defaults to `session`, the session reading) |

### Who sets the level of an attention item (`TRIAGE_MODE`)

No model can open or close an attention item: the watchers open them, and an item closes when the change is gone or a clinician acknowledges it (a request for help closes only by a clinician). `TRIAGE_MODE` decides who sets each item's level:

- `rules` (the default): the fixed rules in `engine/clinic_engine/mind/watchers.py` (`escalate`).
- `models`: the two model levels. Level 1 (the local model) reads the whole picture and sets `watch`, `attention` or `urgent` for every open item, with one of ten fixed reason codes. Level 2 (Gemini, only when the patient's record allows outside processing) reads the same picture with level 1's answer and answers `agree`, `raise` or `lower` (one step). The picture is numbers and fixed codes only: per item its kind, days held, the rules' level and the item's own numeric facts; the last 14 days of movement against own normal (rounded to 0.5); three counts. No ids, dates, names or text; checked by `check_triage_outbound`. A new triage runs when that picture changes.
- Kept in code in both modes: no model opens or closes an item; a request for help is part of the picture both models get (the item only, never the person's words), and its own level is always `urgent`, whatever a model answers (`fixed_by_rule` in the stored decision); the rules' own level is stored beside the models' (`rules_level`); replies outside the fixed form are refused.
- Two floors under the models (`engine/clinic_engine/mind/triage.py`): an item the fixed rules hold at `urgent` stays `urgent`, and no level ends more than one step below the rules' level. Only a clinic rule goes lower. `held_by_floor` is true when the models asked for less than a floor allows. `python -m clinic_engine.triage_check` checks both levels on generated pictures (worse must not mean lower, repeat reads, a rule's side effect); the run of 14 November 2026 is `docs/checks/triage-check-2026-11-14.json`.
- A decision counts only for the picture it was made on. For a changed picture the rules' level applies until the new triage lands, and when no model answers for the current picture (`status: no_models`) levels the models had set go back to the rules' level at the next pass, up or down. An item the rules open at `urgent` is reported before any model is asked.

**The clinic's own rules for one person.** A clinician can write a rule in plain words: `POST /v1/clinic/patients/{id}/clinic-rules {"text": "...", "days": 14}` (3 to 300 characters, at most 10 per person; `days` 1 to 90, 14 when left out, after which the rule stops being read; each rule carries `by`, `at` and `expires_at`), `GET` the same path, `DELETE .../clinic-rules/{rule_id}`. With `TRIAGE_MODE=models` the local model reads the rules when it sets the levels and names the rule an item's level follows; that item carries `clinic_rule_id`, and the second model's verdict is recorded (`verdict2`) and not applied to it. Code checks that the named rule exists, not that it was read as its author meant, so the page shows the rule, its author, the rules' level and a second model's `raise` on the item, and `GET /v1/clinic/patients` has `lowered_by_clinic_rule` (how many items a rule holds below the rules' level) for each person. The text is given to the local model only: the level-2 pack never holds it (the outbound check refuses the key), and the audit log records the rule's id and length, not its words. A rule changes levels, and with them the list order and whether a message is sent: it cannot open or close an item, cannot lower a request for help, and nothing of it reaches the patient. In `rules` mode the rules are stored and `applies` is false. Checked on the demo server on 14 November 2026 with the real models: a rule in English and the same rule in Slovak each set one item's level, a rule about something the person does not have changed nothing, removing a rule restored the earlier level, and four repeated runs on the same picture gave the same levels.

`GET /v1/clinic/patients/{id}` has `triage` {`mode`, `status` (`ready` or `no_models`), `at`, `models`, `levels` {item id: {`level`, `rules_level`, `fixed_by_rule`, `clinic_rule_id`, `held_by_floor`, `level1`, `reason1`, `verdict2`, `reason2`}}}, and each attention item has `rules_level` and `level_source` (`models` when the models set it). The demo server runs with `TRIAGE_MODE=models` since 14 November 2026.

### Apple Health summary and the day reading

`POST /v1/health/summary` (device token) takes the HealthKit harness app's summary: any HealthKit type with one value per day. Every type is stored; steps, walking speed, sleep and HRV also fill the day records. With consent, level 2 reads the daily numbers of the last weeks (the day reading) and code checks every item; `GET /v1/clinic/patients/{id}` has `days_reading` and `health_types`, and `POST /v1/demo/analyze {"patient_id", "what": "days"}` runs it now. Fields, limits and rules: [`docs/health-data.md`](../health-data.md).

### The frame reading (clinician only)

For a focus or breathing session sent with `face_raw`, the level-2 model (Gemini, or the local stand-in) reads a reduced stream of the frames and code checks every item it reports against its own detection on the full-rate frames. Two methods read the same numbers: code with a fixed rule, the model against the person's own resting level. A smile the model reports under code's fixed onset is tested by code against the session's resting level and kept apart as a faint smile when the rise is in the numbers. It runs in the background after the activity is stored, only when level 2 is on (`FRAMES_READER=auto`, the default) and the patient allowed outside processing. What the model receives and must return: [`docs/face-raw.md`](../face-raw.md#what-a-model-sees). The face summary is computed by code either way and does not change. Nothing of it reaches the patient, suggestions or lessons. One exception since 14 November: when the model finds something the fixed rules did not flag and code confirms it in the numbers (a lower stretch in the daily numbers that is still going on, or smiles that became faint over the last sessions), the mind opens a flag for the clinic at the lowest level, "noticed by the model, confirmed by code". It never brings an offer to the patient and never an alert by itself. The attention kind is `model_noticed`, with `detail` {`daily_channel`, `daily_shape`, `daily_days`} and/or {`faint_sessions`, `faint_smiles`}.

Each focus or breathing session in `GET /v1/clinic/patients/{id}` has `frames_reading`, always with these keys:

```json
{"status": "ready", "reason": null, "read_by": "level2", "model": "gemini-...", "checked_by": "code",
 "at": "2026-11-14T09:13:00+00:00",
 "agreement": {"smiles_reported": 5, "smiles_confirmed": 2, "smiles_corrected": 1, "smiles_matched": 3,
               "smiles_faint": 1, "smiles_dropped": 1, "smiles_missed": 0, "smiles_code": 3,
               "smile_precision": 0.75, "smile_recall": 1.0, "smile_start_error_s": 0.1,
               "segments_reported": 1, "segments_confirmed": 1,
               "blinks_model": 11, "blinks_code": 11, "moments_reported": 2, "moments_agree": 2,
               "overall_same": 4},
 "overall": {"expression": "still", "smiling": "often", "gaze": "mostly_up", "tracking": "good",
             "confidence": "medium"},
 "overall_checks": {"expression": {"model": "still", "code": "still", "status": "same"}, "...": {}},
 "blinks": {"model": 11, "code": 11, "status": "confirmed"},
 "smiles": [{"start_s": 8.0, "end_s": 9.2, "reaches_eyes": true, "side": "both",
             "status": "confirmed", "corrected": [], "overlap": 0.86, "code_start_s": 8.1,
             "code_end_s": 9.2, "start_error_s": -0.1, "end_error_s": 0.0}],
 "faint_smiles": [{"start_s": 21.4, "end_s": 23.0, "status": "faint", "peak": 0.22, "rise": 0.17}],
 "missed_smiles": [],
 "resting_smile": 0.05,
 "segments": [{"start_s": 15.0, "end_s": 19.0, "what": "looking_down", "code_share": 1.0}],
 "moments": [{"at_s": 7.0, "smiled": true, "model": true, "status": "confirmed"}],
 "dropped": [{"item": "smile", "start_s": 40.0, "end_s": 41.0, "reason": "no_rise_in_numbers"}]}
```

- `status`: `pending`, `ready`, `failed` (with `reason`: `no_reply`, `not_json_object`, `schema:...`, `time_outside_recording`, `end_not_after_start`, `input_refused`), `off` (level 2 off), `not_allowed` (no consent; nothing was sent) or `not_applicable` (no raw frames). Until `ready`, `agreement`, `overall`, `overall_checks` and `blinks` are null and the lists empty.
- `smiles` holds the reported smiles that code found too: the same smile when the two spans overlap by at least 0.3 of their union, each of code's smiles once. `start_s` and `end_s` are the model's, `code_start_s` and `code_end_s` code's, and the two errors their difference. A smile is `corrected` when code's `reaches_eyes` or `side` differed (the shown values are code's; `corrected` names the fields).
- `faint_smiles` holds the reported smiles that touch no smile of code's but whose rise code confirmed: over the span the smile signal lies above the local resting level by at least 0.05 on average and 0.10 at its peak, and both mouth corners carry the rise. The local resting level (`rest`) is the median within 8 seconds before the span and within 8 seconds after it, the higher of the two, so a step in the baseline is not a smile. Each has `status`: `faint` (the peak stays under the fixed onset) `brief` (it passes the onset but the smile is shorter than the rule's minimum length) or `inside_long` (a clear rise and return inside a far longer stretch that the fixed rule counted as one smile), with `peak` and `rise`. A second report of the same rise is dropped. `resting_smile` is the session's median, for the picture. They never change the face summary or its smile count. `missed_smiles` are code's smiles the model did not report.
- `dropped` reasons for a smile: `no_rise_in_numbers`, `poor_overlap` (it touches a smile of code's but is a sliver of it or far wider), `same_smile_twice`. For a segment: `code_share_too_low`, `too_short` (under 2 seconds; 0.5 for `eyes_closed` and `not_tracked`), `channel_missing`, `not_tracked`, `outside_recording`.
- `agreement`: `smiles_faint`, `smiles_brief` and `smiles_inside_long` count the kinds kept apart (all three are left out of the precision); `smiles_not_in_numbers` and `smiles_poor_match` split the dropped smiles into those with no rise in the numbers and those that matched a real smile poorly (a sliver, far too wide, or twice). `smile_precision` is the share of the model's smiles at code's level (reported minus faint and brief) that code also found; `smile_recall` the share of code's smiles the model also reported; `smile_start_error_s` the mean absolute difference in where a matched smile starts. Either share is null when there is nothing to divide by.
- `segments` holds only the items code confirmed. `overall` shows code's word; `overall_checks` has the model's beside it with `same` or `different`. The overall words are two summaries side by side, not part of the item agreement: code computes `expression` from every blend shape and the model sees ten channels.
- `activities.frames_agreement` in the same answer sums the agreement over every session of the patient the model has read: `sessions`, the smile counts, `smile_precision`, `smile_recall`, `smile_start_error_s`, `blink_sessions_agree`; null when the model has read none. `blinks` keeps the model's count with code's beside it. `moments.smiled` is code's answer, `model` the model's.
- `dropped` reasons for a moment: `not_a_sent_moment`, `not_tracked`.
- Never the frames. The exact exchange with the model (prompt, stream and reply) is kept with the other model exchanges for the clinician; the trace and the audit hold counts and codes only.

## Reference ratings and the association appraisal (clinician only)

Research output for the clinician: for one person over time, did the measures the app takes (face summary, focus game, check-ins, daily data) move together with that person's symptom state, in the direction the literature expects (`engine/clinic_engine/data/association_hypotheses.json`)? It is a within-person description, not validated and not a diagnosis. It never reaches the patient, never changes a suggestion, never opens, raises or closes attention and never feeds lessons.

| Call | Who | What |
|---|---|---|
| `POST /v1/clinic/patients/{id}/ratings` | clinician of the clinic | `{"date":"2026-11-13","scale":"phq9","score":9}`. Scales `phq9` (0 to 27), `phq2` (0 to 6), `clinician_global` (1 to 7). One per day and scale (a second one replaces it). Out of range or a future date: 422 `implausible_rating` |
| `GET /v1/clinic/patients/{id}/ratings` | clinician | `{"ratings":[{id,date,scale,score,created_at,example}]}`, oldest first |
| `DELETE /v1/clinic/patients/{id}/ratings/{rating_id}` | clinician | `{"id":...,"deleted":true}` |
| `GET /v1/clinic/patients/{id}/associations` | clinician | The latest appraisal (`status: none` until it has run) |
| `POST /v1/clinic/patients/{id}/associations/run` | clinician of the clinic, or admin | Computes it now and returns it. It also runs by itself once a day per patient after the tick, in the background |

How it works: code builds one row per day (measures averaged per day, face values only from sessions with good tracking) and a reference: a rating scale with at least 4 ratings (each rating stands for the days within 3 days of it), otherwise the proxy `movement_z` (then steps and walking speed are the reference and are not tested). Per measure code computes `n` paired days, Spearman `rho` oriented so that positive means "moves as expected when symptoms are worse", a bootstrap 95% interval, a permutation p-value adjusted with Benjamini-Hochberg (`p_adj`), `lead_days` (-3 to 3, negative = the measure moves first), `contrast` (Cliff's delta, days with attention held against other days) and `quality`. Below 8 paired days a row is `insufficient`. Code then appraises the table itself. When the local model is configured it gets the prompt file and a JSON object of numbers and codes only (no ids, dates, names or text), and code checks its answer: a wrong `agreement`, a `strength` above what the interval supports, a `confidence` above the cap (`high` needs a rating reference, three independent lines and 20 paired days; a proxy allows at most `medium`), a wrong `independent_lines` or `strongest` are replaced by code's value and listed in `corrections`; `*_source` / `overall.sources` say per field `model`, `code` or `code_corrected`. An unusable answer gives the code-only appraisal (`appraised_by: "code"`).

Response fields: `status`, `appraised_by`, `checked_by`, `generated_at`, `design` {type, days, sessions, first_day, last_day, rows_tested, min_n}, `reference` {key, label, kind, worse_is, ratings}, `rows` [{key, label, group, expected, support, why, status, n, rho, ci_low, ci_high, p_adj, lead_days, contrast, quality, agreement, strength, agreement_source, strength_source, caveats [{code, text, by}]}], `overall` {pattern, confidence, independent_lines, strongest, leads_reference, main_alternative, main_alternative_text, next_step, sources}, `data_notes` [{code, text}], `corrections` [{where, key, field, model, code, reason}], `hypotheses_reviewed_by_clinician`, `disclaimer`, `inputs` {reference, n_days, n_sessions, generated_at, model}.

The face summary (`face` on focus and breathing activities) also accepts, all optional and numbers only: `smile_time_share`, `eye_smile_share`, `smile_response_share`, `smile_response_latency_s`, `brow_down_share`, `inner_brow_up_share`, `blink_duration_ms`, `head_pitch_deg`, `head_movement`, `smile_asymmetry`, `lip_down_share`, `lip_press_share`. Each is compared with the person's own normal like the others.

## Errors

Every error has the same shape, and the same `request_id` is in the `X-Request-Id` header:

```json
{"error": {"code": "invalid_request", "message": "days.0.steps: Input should be a valid integer", "request_id": "9f2c4e1a0b7d"}}
```

| HTTP | `code` | When |
|---|---|---|
| 400 | `invalid_pairing_code`, `too_many_rules` | |
| 401 | `unauthorized` | missing, unknown or expired token |
| 403 | `forbidden` | right token, wrong scope |
| 404 | `not_found` | not found, or not yours (the server does not say which) |
| 409 | `conflict` | an id you sent before is reused for something else |
| 413 | `body_too_large` | body over 256 KB |
| 422 | `invalid_request`, `implausible_activity`, `implausible_round` | shape, enum or plausibility failures; the input is never echoed |
| 429 | `rate_limited` | per token (about 120 a minute), and per address for pairing and login |
| 500 | `server_error` | |

Every write and every refusal is written to an audit log (codes and ids only, never bodies or note text).

## What the server does with the data (one paragraph)

Each day is compared with the person's own normal (median and MAD of their earlier days, robust z-scores). Each activity is compared with the person's own earlier sessions of the same type (reaction time, errors, time played, good things, and the face summary when tracking was good). Watchers hold attention items (`deviation`, `novelty`, `silence`, `oddity`, `ignored`, `asked_for_help`, `low_notes`, and for activities `slower_reactions`, `face_flat`, `checkins_stopped`, `plans_not_done`, `not_played`) with a level `watch`, `attention` or `urgent` ("needs review today", never an emergency or a diagnosis). Activity signals alone stay at `watch`; they rise only while the daily data also shows a drop. Nothing about mood or the face is ever shown to the person. Code picks one action from a fixed catalog; the local model may only choose one of Lanvi's fixed lines for it (`engine/clinic_engine/data/lanvi_lines.json`), through an output gate, with the first line as the fallback. Learning builds an evidence table, and every lesson (from code or a model) is recomputed by code before it is used. Every model call, at both levels, passes an input gate (allowlisted, and for Gemini anonymized) and an output gate (strict JSON schema and content checks), in `engine/clinic_engine/mind/gates.py`. With consent, level 2 also reads a reduced stream of a session's raw face frames (the frame reading, clinician only); code checks every item it reports.
