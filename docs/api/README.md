# Clinic engine API: guide for the iOS app

The full contract is `openapi.json` in this folder (exported from the running code with `python -m clinic_engine.export_openapi`). This page is the short version: auth, the calls in order, examples, errors.

The product name is not decided; the server reads it from `PRODUCT_NAME` (default `Angel`) and returns it in `GET /v1/today`.

## Run it locally

```sh
cd engine
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
export STORE=dir STORE_DIR=./data             # local folder store (git-ignored)
.venv/bin/python -m clinic_engine.seed --extra 3 --pairing-code   # prints tokens ONCE
.venv/bin/uvicorn clinic_engine.app:app_from_env --factory --host 127.0.0.1 --port 8080
.venv/bin/python -m pytest -q                  # tests, fully offline
```

Interactive docs while it runs: `http://127.0.0.1:8080/docs`.

## The demo server

The engine also runs on a demo server: `https://angel.victronlab.sk`. Interactive docs: `https://angel.victronlab.sk/docs`. Every call under `/v1` needs a bearer token; ask Mathew for the pairing code and the clinician login, they are not in this repo. All data on it is example data.

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

Tokens are 256-bit random strings. The server stores only their SHA-256 hash. Keep the device token in the Keychain. No device call takes a patient id: the token decides whose data it is.

## The calls, in order

1. **Pair once.** The clinic gives the person a one-time code.
   ```sh
   curl -X POST $B/v1/devices/pair -H 'Content-Type: application/json' \
     -d '{"pairing_code":"ABCD-EFGH-JKLM","device_label":"iPhone 15","platform":"ios"}'
   # {"device_token":"...","patient_id":"pat_..."}
   ```
   The code works once and expires (24 h by default). A second use is refused.

2. **Send daily data** (Apple Health). One day, or a batch of history on first launch (up to 400 days). Upsert by date, so re-sending a day is fine.
   ```sh
   curl -X POST $B/v1/daily -H "Authorization: Bearer $DT" -H 'Content-Type: application/json' \
     -d '{"days":[{"date":"2026-11-13","steps":6400,"walking_speed_m_s":1.24,"hrv_ms":42,"sleep_h":7.1}]}'
   # {"accepted":["2026-11-13"],"rejected":[],"status":"within"}
   ```
   `hrv_ms` and `sleep_h` are optional (watch only). Values that cannot be true (negative, absurd, future dates, two different values for one date in one batch) come back in `rejected` with a reason and are never used.

3. **Ask what to show.**
   ```sh
   curl $B/v1/today -H "Authorization: Bearer $DT"
   ```
   ```json
   {"status": "outside",
    "suggestion": {"id": "sug_...", "action": "ar_round", "text": "How about a two-minute round of catching lights in your room?", "created_at": "..."},
    "round_config": {"config_id": "near_gentle", "mode_hint": "standing", "layout_seed": 47776, "lights_total": 10,
                     "distance_band": "near", "height_band": "mid", "light_life_s": 9, "catch_radius_m": 0.35, "duration_s": 120},
    "attention": "Your movement has been lower than your usual for a few days.",
    "crisis": {"text": "Angel is not an emergency service. In an emergency, call 112. Otherwise, contact your clinic.",
               "contacts": [{"label": "Emergency number", "phone": "112"}], "reviewed_by_clinician": false},
    "product_name": "Angel"}
   ```
   - `status`: `no_baseline` (fewer than 14 days yet), `within`, `outside`, `no_data`. Missing data is always `no_data`, never `within`.
   - `suggestion` is at most one, or null. Show `text` as is.
   - `crisis` is **always** present. While `reviewed_by_clinician` is false, show it as draft wording.

4. **Play a round, then send it** (schema 2, see `docs/game-interface.md` section 3). Send `config` exactly as received. Idempotent by your `id`.
   ```sh
   curl -X POST $B/v1/rounds -H "Authorization: Bearer $DT" -H 'Content-Type: application/json' -d @round.json
   # {"id":"...","quality":"good","energy_bucket":"usual","analysis":"off","after_round":{"template_id":"done","text":"Round done. Well done for showing up."}}
   ```
   - `screen` mode: no `path`, and `dist_m` / `height_m` are null.
   - Implausible values reject the round with 422 `implausible_round`.
   - `analysis` is `pending` when the level-2 movement reading runs (in the background), else `off` or `not_allowed`. Poll `GET /v1/rounds/{id}/analysis` for `{"status":"ready","line":"..."}`; `line` is from a fixed set.

5. **Answer the suggestion.** Enums only. Idempotent by your `id`.
   ```sh
   curl -X POST $B/v1/feedback -H "Authorization: Bearer $DT" -H 'Content-Type: application/json' \
     -d '{"id":"fb-7f3a91c2","suggestion_id":"sug_...","answer":"did_it","felt":"ok"}'
   ```
   `answer`: `did_it | not_today | something_else`. `felt` (optional): `rough | ok | good`.

6. **A few words (optional).** See "The one free-text field" below.
   ```sh
   curl -X POST $B/v1/notes -H "Authorization: Bearer $DT" -H 'Content-Type: application/json' \
     -d '{"id":"note-5c1d0a77","text":"slept badly, quiet day"}'
   # {"reply":{"template_id":"low_1","text":"..."},"crisis":false,"crisis_block":null,"suggestion":null}
   ```
   When `crisis` is true, show `crisis_block` right away.

7. **"What works for you"** screen.
   ```sh
   curl $B/v1/mind -H "Authorization: Bearer $DT"
   # {"rules":[...],"lessons":[{"id":"les_...","text":"Catching lights seemed to suit you, so it comes first now.","evidence_count":3,...}],
   #  "questions":[{"id":"q_...","text":"Was a short walk too much on some days?","answers":["yes","no","not_sure"]}]}
   curl -X POST $B/v1/mind/lessons/les_.../reject   -H "Authorization: Bearer $DT"
   curl -X POST $B/v1/mind/questions/q_.../answer  -H "Authorization: Bearer $DT" -H 'Content-Type: application/json' -d '{"answer":"yes"}'
   curl -X POST $B/v1/mind/rules -H "Authorization: Bearer $DT" -H 'Content-Type: application/json' \
     -d '{"rule":{"type":"quiet_hours","params":{"from":"21:00","to":"08:00"}}}'
   curl -X DELETE $B/v1/mind/rules/rule_... -H "Authorization: Bearer $DT"
   ```
   Rule templates: `quiet_hours {from, to}`, `seated_only {weekdays: [mon..sun]}`, `max_suggestions_per_day {n: 0..5}`, `no_action {action}`. The person's rules always beat what the mind has learned. A rejected lesson does not come back from the same evidence.

Ids you generate (`id` of rounds, feedback, notes) are 8 to 64 characters of `A-Z a-z 0-9 _ -`; a UUID works.

## The one free-text field, and why everything else is enums

There is exactly **one** free-text field in the whole API: `POST /v1/notes` `text`, at most 280 characters. Everything else is numbers, dates, ids and enums, and every request model rejects unknown fields. This removes the prompt-injection surface on purpose: nothing a person types can steer what the server does.

How the note is treated:

- It is untrusted data. It is never an instruction, never placed into a system prompt, never copied into lessons, summaries, notifications or logs, and it never leaves the server (the level-2 input gate refuses any pack that would carry it).
- It is only classified: a word-list check in code (English, Finnish, Slovak; a draft list in `engine/clinic_engine/data/note_lexicon.json`, not yet reviewed by a clinician) plus, when available, the local model through the gates. The model may only return a fixed JSON of enums: `mood`, `asks_for_help`, `topic`, and one reply template id from a list.
- Fail-safe: if either says the person asks for help, or the model answer is refused or unclear on a note the word list flags, `crisis` is true. Over-triggering is accepted; missing is not.
- The reply is a vetted template picked by code, never generated text. This is deliberately not a chat.
- The clinician sees that a note exists, its time and its classification. The text itself only when the patient record allows it (`share_notes`, default off).

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
| 422 | `invalid_request`, `implausible_round` | shape, enum or plausibility failures; the input is never echoed |
| 429 | `rate_limited` | per token (about 120 a minute), and per address for pairing and login |
| 500 | `server_error` | |

Every write and every refusal is written to an audit log (codes and ids only, never bodies or note text).

## What the server does with the data (one paragraph)

Each day is compared with the person's own normal (median and MAD of their earlier days, robust z-scores). Watchers hold attention items (`deviation`, `novelty`, `silence`, `oddity`, `ignored`, `asked_for_help`, round watchers) with a level `watch`, `attention` or `urgent` ("needs review today", never an emergency or a diagnosis). Code picks one action from a fixed catalog; the local model may only word it, through an output gate with a fixed-template fallback. Learning builds an evidence table, and every lesson (from code or a model) is recomputed by code before it is used. Every model call, at both levels, passes an input gate (allowlisted, and for Gemini anonymized) and an output gate (strict JSON schema and content checks), in `engine/clinic_engine/mind/gates.py`.
