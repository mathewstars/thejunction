# Game interface: from ARKit to the mind

How one AR round travels from the phone to the server, what the server makes of it, and where the two model levels come in. Working name of the product: Angel (not final).

Owners: Peter (the app side), Mathew (the server side), Matthew (the game design values marked "design").

Earlier we said the round is only a response and reports almost nothing. This document goes further: the round still is the response, and it also gives the server a small, clean signal about how the person moved. The phone's daily data stays the main sensor.

## 1. What ARKit gives the app

With the rear camera and world tracking, ARKit gives the app the following. This is from our knowledge of the platform; Peter confirms each line on his phone.

| ARKit gives | What it is | We use it for |
|---|---|---|
| Camera pose per frame | Position and orientation of the phone in the room, in metres, many times a second | The path the person walked, speed, pauses |
| Tracking state | Normal, or limited with a reason (too fast, too dark, starting up) | Deciding whether a round can be trusted |
| Floor planes | Horizontal surfaces it found, with their size | The play area: where lights may be placed |
| Raycasts | A point in the room where a ray from the screen hits a surface | Placing lights at a real distance and height |
| Light estimate | How bright the room is | Marking rounds played in poor light |
| Frame timestamps | Exact time of every frame | Timing of every event |

What the app derives itself: the distance between the phone and a light. A light is caught when the phone comes within the catch distance (design, start with 0.35 m).

What we do not use: the camera image, the room mesh, any location. None of them leaves the phone, and none is stored.

The phone is held in the hand, so "how the phone moved" stands for "how the person moved". That is good enough to compare a person with themselves. It is not good enough to compare two people or two phones, and we never do.

## 2. What the app does during a round

1. **Look around (about 10 seconds).** The person turns slowly. The app waits for normal tracking and a floor plane, and works out the play area.
2. **Ask the server how to play.** `GET /v1/today` returns `round_config` (section 5). The app places the lights from it.
3. **Play.** Lights appear one at a time. For each light the app logs when it appeared, where it was, when the person first moved towards it and when it was caught or expired.
4. **Sample the path.** Twice a second the app stores the phone's position relative to where the round started.
5. **Send one record** when the round ends, also when the person stops early.

The app does no analysis. It only logs. All judgement is on the server, where it can be tested.

## 3. The round record (app to server)

`POST /v1/rounds`, device token, idempotent by `id`.

```json
{
  "id": "5b1c0c9e-8d0a-4c57-9a55-3f0f6d1f2a10",
  "schema": 2,
  "suggestion_id": "s_41",
  "started_at": "2026-11-14T09:12:03Z",
  "duration_s": 118.4,
  "mode": "standing",
  "completed": true,
  "ended_by": "finished",

  "config": {
    "config_id": "standard",
    "layout_seed": 1234,
    "lights_total": 12
  },

  "tracking": {
    "normal_ratio": 0.93,
    "limited_reasons": ["excessive_motion"],
    "play_area_m2": 9.5,
    "light": "ok",
    "lidar": false
  },

  "lights": [
    {
      "i": 0,
      "spawn_t": 2.1,
      "dist_m": 1.8,
      "height_m": 1.2,
      "first_move_t": 2.9,
      "end_t": 6.4,
      "caught": true
    }
  ],

  "path": {
    "hz": 2,
    "points": [[0.0, 0.0, 0.0], [0.1, -0.2, 0.0]]
  }
}
```

Field notes:

| Field | Meaning |
|---|---|
| `mode` | `standing`, `seated` (AR, lights within reach) or `screen` (no camera, lights tapped on the display) |
| `ended_by` | `finished`, `user_stopped` or `interrupted` (call, app closed, tracking lost) |
| `suggestion_id` | The suggestion this round answers, or null when the person just played |
| `config` | Exactly what the server sent, so the server knows what the person was asked to do |
| `tracking.normal_ratio` | Share of the round with normal tracking, 0 to 1 |
| `tracking.light` | `dim`, `ok` or `bright`, from the light estimate |
| `lights[].spawn_t`, `first_move_t`, `end_t` | Seconds from the start of the round. `first_move_t` is the first moment the phone moved clearly towards the light (design, start with 0.15 m of approach). Null if the person never moved. |
| `lights[].dist_m`, `height_m` | Where the light was when it appeared: distance from the phone and height above the floor |
| `path.points` | `[x, z, y]` in metres relative to the start of the round, rounded to 0.1. At most 240 points. Left out in `screen` mode. |

Times are seconds with one decimal, distances are metres. In `screen` mode `dist_m` and `height_m` are null and the path is left out.

Privacy: the path is relative to the start point and carries no map of the room. It leaves the clinic's server only for the movement reading in section 6, only when that is switched on, and only after it has been made anonymous.

## 4. What the server does with a round

All of this is code. No model takes part in steps 1 to 5.

| Step | What happens |
|---|---|
| **1. Check** | Values that cannot be true are rejected. A round with `normal_ratio` under 0.7, a play area under 2 m² or `interrupted` is kept but marked low quality and never enters the baseline. |
| **2. Features** | Per light: reaction time (`first_move_t - spawn_t`) and travel speed (`dist_m / (end_t - first_move_t)`). Per round: share of lights caught, median reaction time, median travel speed, share of the play area covered, share of the time standing still, vertical range, and fade (speed in the second half against the first half). |
| **3. Own normal** | Each feature is compared with the same person's earlier good rounds in the same mode. At least five rounds are needed. The result is a robust z-score per feature. |
| **4. Round energy** | One summary of speed, reaction and coverage against the person's own normal, as a bucket: `low`, `usual`, `high`. |
| **5. Attention** | Watchers look at the round next to the daily data: two weak rounds in a row; weak rounds while the daily data looks normal (or the other way round); a growing fade; several rounds stopped early; rounds offered but not played. Each can open or raise an attention item. |

The round never decides alone. The daily data from Apple Health is the main sensor; the round adds evidence and can raise attention earlier.

## 5. What the server sends back: `round_config`

Part of `GET /v1/today`. Code picks it from a fixed list. This is how the game adapts to the person.

```json
{
  "config_id": "standard",
  "mode_hint": "standing",
  "layout_seed": 1234,
  "lights_total": 12,
  "distance_band": "mid",
  "height_band": "mid",
  "light_life_s": 8,
  "catch_radius_m": 0.35
}
```

| `config_id` | Lights | Distance | Height | For |
|---|---|---|---|---|
| `seated_gentle` | 8 | within reach | low to mid | A hard day, or the person's own rule |
| `near_gentle` | 10 | near (up to 1 m) | mid | After a weak round, or while status is `outside` |
| `standard` | 12 | mid (1 to 2.5 m) | mid | The usual round |
| `wide` | 12 | across the play area | mid | After two strong rounds |
| `wide_high` | 14 | across the play area | low to high | Strong and steady |

The values in this table are design values for Matthew to tune.

Rules for picking: start from the person's usual config; step down one after a low-energy round or while status is `outside`; step up one after two high-energy rounds; the person's rules always win (for example "seated only"); lessons may prefer a config or a time of day. The same `layout_seed` gives the same layout, so rounds can be compared.

## 6. Where the two model levels come in

Every model call passes two code gates. The input gate builds what the model may see. The output gate checks what comes back before anything is used. Nothing the person typed ever goes to a model outside the clinic.

| | Level 1: local model | Level 2: Gemini (optional, off by default) |
|---|---|---|
| **Job** | Words the one line shown after the round. Proposes lessons and questions in a fixed shape. | **Reads the movement of a round** (below). Gives a second opinion on proposed lessons. |
| **Sees** | Labels for this person's recent rounds and days: energy bucket, rounded z-scores, mode, config, finished or not, what was offered and answered | The anonymous movement trace of one round, and optionally a usual round next to it. Never ids, dates, the clinic, the device or any text. |
| **May not do** | Choose the action, choose the config, change a threshold, close attention | The same |
| **Checked by** | Output gate: fixed shape, known action and config names, evidence recomputed by code, no clinical words | Output gate: fixed shape, and every claim compared with what code computed from the same round |

Code is the judge at the end. Every refusal at either gate is logged and shown to the next review.

### The movement reading (level 2)

This is the real job for Gemini: read how the person moved through a round, the way a physiotherapist would look at a recording, and say it in a fixed vocabulary.

**What goes out, after the input gate:**

- The path, turned by a random angle and with a fresh random alias, so two requests cannot be linked and the layout of the room cannot be read from it.
- The per-light log: when each light appeared, how far and how high it was, when the person first moved and when it was caught.
- The same for one usual round of the same person, when a comparison is wanted.
- Optionally the two paths drawn as two small trail pictures, so the model can also look at the shape.
- Times only as seconds from the start of the round. No date, no time of day.

**What must come back, as one JSON object and nothing else:**

```json
{
  "pattern": "slowing",
  "fade_from_light": 7,
  "reach": "avoids_high",
  "turning": "mostly_right",
  "compared_to_usual": "smaller_and_slower",
  "confidence": "medium",
  "evidence": [
    {"claim": "slowing", "lights": [7, 8, 9, 10, 11]},
    {"claim": "avoids_high", "lights": [3, 6, 9]}
  ]
}
```

| Field | Allowed values |
|---|---|
| `pattern` | `steady`, `slowing`, `stop_start`, `hesitant_start`, `rushed`, `minimal_movement`, `unclear` |
| `fade_from_light` | The index of the light where the person started to slow, or null |
| `reach` | `full`, `avoids_high`, `avoids_low`, `avoids_far`, `unclear` |
| `turning` | `both`, `mostly_left`, `mostly_right`, `little`, `unclear` |
| `compared_to_usual` | `similar`, `smaller`, `slower`, `smaller_and_slower`, `larger`, `faster`, `unclear` |
| `confidence` | `low`, `medium`, `high` |
| `evidence[].claim` | One of the values used above, with the lights that show it |

**What the output gate does with it:**

1. Anything that is not exactly this shape is refused.
2. Every claim is checked against code. "Slowing from light 7" must agree with the travel speeds the server computed; "avoids high" must agree with the catch rate of the high lights. A claim that code cannot confirm is dropped and logged.
3. What survives is stored with the round as a movement reading, marked "read by a model, checked by code".

**What it is used for:**

- The clinician sees the reading next to the trail of the round.
- The patient sees one plain line, picked from a fixed set by the pattern. Never the reading itself.
- It joins the evidence for attention and for lessons, for example: "slows down in the second half of evening rounds".

**If level 2 is off or does not answer:** the round is processed by code alone, exactly as in section 4. Nothing waits for the model.

**Consent:** the movement reading runs only for a patient whose record allows outside processing. The switch for the whole server is `OUTREACH_MODE`.

### API for the reading

| Call | Who | What |
|---|---|---|
| `POST /v1/rounds` | App | Returns at once with `analysis: "pending"`, `"off"` or `"not_allowed"`. The reading runs in the background. |
| `GET /v1/rounds/{id}/analysis` | App | `status` (`pending`, `ready`, `off`, `failed`) and, when ready, the plain line for the patient. |
| `GET /v1/clinic/patients/{patient_id}/rounds/{id}` | Clinician | The round, its features, the path for drawing the trail, and the full checked reading with what was dropped. |
| `POST /v1/demo/analyze` | Demo | Runs the reading again for a round, so it can be shown live. |

## 7. What the clinician sees from rounds

Per patient: rounds played against rounds offered, the energy bucket per round over time, and the path of a chosen round drawn as a simple trail. Two trails side by side (a usual round and a recent one) show the change without a number. Next to them, the checked movement reading from level 2, when it is on.

## 8. Open points

1. **Peter:** confirm the ARKit lines in section 1, and that path sampling at 2 Hz and the per-light log are easy to produce.
2. **Peter:** how `first_move_t` is detected in practice. If it is hard, send null and the server uses time to catch.
3. **Matthew:** the config table in section 5, the catch distance and how long a light lives.
4. **Aalto mentors:** which of the round features they would trust: reaction time, speed, coverage or fade.
6. **All:** the movement reading sends an anonymous movement trace to Gemini. For the demo that is example data and our own. With real patients it needs their consent and an agreement with the provider; say so in the pitch.
5. **Mathew:** the server needs five good rounds per mode for a baseline; for the demo the seed script supplies them, marked as example data.
