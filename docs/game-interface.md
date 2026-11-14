# Game interface: from ARKit to the server

How one activity travels from the phone to the server in the fox design, what the server makes of it, and what comes back. Checked against the code on Saturday 14 Nov.

Owners: Peter (the capture on the phone), Mathew (the server), Matthew (the game design values in section 8).

This page replaces the earlier one about the AR round, where the rear camera followed the phone through the room. That round is cut. The server still accepts its record (`POST /v1/rounds`, marked deprecated) so an old build does not break; nothing here builds on it. ARKit is now used for one thing only: the front camera reads how the face moves during two activities, when the person allowed it.

The phone's daily data from Apple Health stays the main sensor. An activity adds a small signal and never decides alone.

## 1. What ARKit gives the app

Face tracking with the front (TrueDepth) camera. It needs an iPhone with Face ID and does not run in the simulator.

| ARKit gives | What it is | Sent as |
|---|---|---|
| 52 blend shapes per frame | How far each part of the face is moved, 0 to 1: mouth corners, eyelids, brows, cheeks, jaw and so on | one column each, under ARKit's own names |
| The face anchor's position against the camera | Where the head points | `headPitch`, `headYaw`, `headRoll` in degrees; pitch is positive when the chin goes down |
| `isTracked` per frame | Whether ARKit saw the face | `tracked`, 1 or 0 |
| Frame timestamps | When each frame was taken | used on the phone to make steady rows at 30 a second; not sent |

Not used and never sent or stored: the camera image, video, the face mesh, landmarks, depth. The app shows no camera preview, only a small indicator while the camera is on.

The numbers are good enough to compare a person with themselves. They are not good enough to compare two people or two phones, and the server never does.

## 2. What the app records during each activity

The app computes nothing from the face and judges nothing. It logs and sends. All judgement is on the server, where it can be tested and changed later.

| Activity | Type | Length | What the app logs |
|---|---|---|---|
| Sparks and snow | `focus` | 45 seconds | correct taps, wrong taps (a snowflake), misses (a spark that faded), the reaction time of each tap in ms, finished or stopped; face frames |
| Breathe with Lanvi | `breathing` | about a minute, 6 breaths | seconds played, breaths completed, finished or stopped; face frames |
| Evening check-in | `checkin` | about a minute | up to three good things and one plan (each tapped from a list or typed), and the answer about yesterday's plan. No face. |

Face frames, in the app today (`ios/Lanvi/Sense/`, described in `ios/SENSORS.md`):

- Asked once before the first game, with "Not now" as an equal answer. A switch on the Help screen turns it off.
- One row per 1/30 second: all 52 blend shapes to 3 decimals, then the three angles.
- A pleasant moment is marked when Lanvi cheers in the game (`moments_ms`, at most 20). The server looks for a smile after each.
- Only the last `duration_s` + 1 seconds are kept, at most 9,000 rows.
- No face tracked, camera refused, or no TrueDepth camera: no frames, and the game is the same.

Checked so far: unit tests and one session sent to a local server from the app's own encoder. The capture on a real phone has a test list in `ios/SENSORS.md` and no recorded result in the repo yet.

## 3. The activity record (app to server)

`POST /v1/activities`, device token, one record per activity, also when stopped early. Field by field with limits and errors: `docs/app-api.md`, section 5. The face part in full: `docs/face-raw.md`.

```json
{
  "id": "4f1c7f9e-2b7a-4d0e-9a51-0c3e5f7a9b21",
  "type": "focus",
  "started_at": "2026-11-14T09:12:03Z",
  "duration_s": 45.2,
  "completed": true,
  "ended_by": "finished",
  "correct_taps": 17, "wrong_taps": 1, "misses": 2,
  "reaction_ms": [512, 498, 530, 476, 551],
  "face_raw": {
    "rate_hz": 30,
    "channels": ["mouthSmileLeft", "mouthSmileRight", "eyeBlinkLeft", "eyeBlinkRight",
                 "cheekSquintLeft", "cheekSquintRight", "headPitch", "headYaw", "headRoll"],
    "samples": [
      [0.041, 0.052, 0.083, 0.071, 0.020, 0.024, 6.2, -1.4, 0.8],
      [0.312, 0.288, 0.074, 0.069, 0.183, 0.191, 6.0, -1.3, 0.9]
    ],
    "tracked": [1, 1],
    "moments_ms": [40]
  }
}
```

| Field | Meaning |
|---|---|
| `ended_by` | `finished`, `user_stopped` or `interrupted` |
| `suggestion_id` | optional: the suggestion this was played from |
| `reaction_ms` | one entry per tap, at most 200. The server leaves out taps faster than 120 ms and needs at least 5 to compute a median. |
| `face_raw.channels` | the names of the columns. Four are required: `mouthSmileLeft`, `mouthSmileRight`, `eyeBlinkLeft`, `eyeBlinkRight`. A measure that needs a missing channel comes back empty, so send them all. |
| `face_raw.samples` | one row per frame, oldest first, at most 12,000 |
| `face` | instead of `face_raw`, from an older phone: a summary the phone computed. Still accepted. Never both. |

The same record sent again is answered without new XP and the frames are stored once. The same `id` with different content is refused (409).

## 4. What the server does with it

Steps 1 to 5 are code. No model takes part.

| Step | What happens |
|---|---|
| **1. Check** | A record that cannot be true is refused (422) and logged: in the future, longer than 30 minutes, more reaction times than taps, more than 10 taps a second, played longer than the activity lasted, frames that last much longer than the activity. |
| **2. Face summary** | From `face_raw` the server computes 16 measures and the tracking quality: smiles (how often, how long, how strong, whether they reach the eyes, whether one follows a pleasant moment), blinks, looking down, brows, how much the face and the head moved. Rules and thresholds: `docs/face-raw.md`. The frames are kept as their own object, so the summary can be computed again when a rule changes. |
| **3. Features** | Focus: median and spread of reaction time, error rate. Breathing: time played. Check-in: number of good things, plan made, yesterday's plan done. |
| **4. Own normal** | Each feature and each face measure is compared with the same person's earlier sessions of the same type (the last 20 at most). At least 5 are needed. The result is a robust z-score. A face summary with tracking quality under 0.6 is stored and shown but never used. |
| **5. Watchers** | See below. |
| **6. Session reading** | Optional, a model, checked by code. See below. |
| **7. Frame reading** | Optional, a model, checked by code, for the clinician only. See below. |

Typed check-in words do not stay in the record. They are stored as notes and checked for help-seeking words like any note (`docs/app-api.md`, section 8).

### The watchers

The first two look at the last 3 sessions with a z-score and need 2 of them.

| Watcher | Opens when |
|---|---|
| `slower_reactions` | median reaction time 1.5 or more above own normal |
| `face_flat` | facial activity or smile rate 1.5 or more below own normal, with good tracking |
| `checkins_stopped` | no check-in for 3 days after at least 3 in the two weeks before |
| `plans_not_done` | the last 3 answers about a plan were "no" |
| `not_played` | 3 offered activities in a row left unplayed |

These open an item for the clinician at the lowest level, "watch". Alone they never rise, never cause a suggestion and never produce text for the person. They rise to "attention" only while the daily data also shows a held drop in movement. Slower reactions or a flatter face also let that drop be noticed one low day earlier (2 low days of the last 5 instead of 3).

### The session reading (level 2, optional)

A model compares one session's numbers with the person's earlier ones and says, in fixed words, whether anything changed.

- **Runs when:** a focus or breathing session has a face summary, the server's outside model is on (`OUTREACH_MODE`, off by default), and the patient's record allows outside processing. Otherwise the answer says `off` or `not_allowed` and the code path above stands.
- **Sees:** this session's rounded numbers (reaction time, spread, error rate or time played, six face values, tracking quality) and up to 5 earlier sessions of the same type, named only by position (-1, -2, ...). No id, date, time of day or text.
- **Returns:** `reactions`, `expression`, `eyes`, `compared_to_usual`, each a fixed word or `unclear`; from which earlier session the change started; a confidence; and which numbers support each claim.
- **Code checks every claim** against its own z-scores. A claim of change needs a z of 1.0 or more. What code cannot confirm is set to `unclear` and logged.
- **Used for:** a confirmed "slower" or "less expressive" counts as a hit for the two watchers above. The clinician sees the reading with what was dropped.

### The frame reading (level 2, optional, clinician only)

Here Gemini reads the frames themselves and code checks each item. Full text: `docs/face-raw.md`, "What a model sees", and `docs/api/README.md`, "The frame reading".

- **Runs when:** the session came with `face_raw`, the outside model is on, `FRAMES_READER` is not `off`, and the patient's record allows outside processing. In the background, after the record is stored.
- **Sees:** a reduced stream, not the frames as sent. Up to 15 named columns (time, smile, each mouth corner, cheek, frown, blink, look down, two brow values, jaw, three head angles, tracked), averaged to 5 rows a second, rounded, at most 400 rows, plus the pleasant moments in seconds. No id, date, clock time or text.
- **Returns:** each smile with start, end, whether it reaches the eyes and which side; a blink count; stretches of 2 seconds or more (looking down, brows down, inner brows raised, head down, still face, eyes closed, not tracked); for each pleasant moment whether a smile followed; five overall words. It is told to judge a smile against this person's own resting level, and never to name a mood.
- **Code checks each item** against its own detection on the full-rate frames:
  - A reported smile is confirmed when it overlaps a smile code found by at least 0.3 of their joint span. Code's values for eyes and side replace the model's.
  - **Faint smiles.** Code's own rule needs the smile signal to reach 0.25. A reported smile that touches no smile of code's is tested against the resting level around it (the 8 seconds before and after). It is kept apart as a faint smile when it rises above rest by 0.05 on average and 0.10 at its peak, lasts 0.3 seconds, and both mouth corners take part. If its peak does reach 0.25 but code's rule did not count it as a smile, it is marked brief instead. Otherwise it is dropped with a reason.
  - A stretch is kept when code finds the same thing in most of it. Blink counts are shown side by side.
- **Used for:** the clinician sees both readers on one session and how often they agree. It changes nothing else: not the face summary, not attention, not suggestions, not lessons, and nothing the person sees.

Neither reader is the truth. The thresholds of the fixed rule and the two faint-smile margins are estimates and have not been calibrated on recordings of people.

## 5. What comes back to the app

At once, in the answer to `POST /v1/activities`:

| Field | What |
|---|---|
| `xp_gained`, `xp_total` | XP for showing up: the same whatever the score, finished or not |
| `stage`, `next_stage_at`, `glow`, `wandering` | Lanvi's growth after this record |
| `line` | one line for Lanvi to say, from a fixed set, chosen by type and by how it ended |
| `crisis`, `crisis_block` | true with the help block when typed check-in words ask for help |
| `reading` | `pending`, `off`, `not_allowed` or `not_applicable` |

Later, if the app asks: `GET /v1/activities/{id}/reading` gives a status and, when ready, one neutral line. The app does not ask today.

Nothing about the face, reaction times or mood comes back, in any call. `GET /v1/today` may later carry a suggestion, but only when the daily data moved.

## 6. What the clinician sees

On the patient page, per activity type: each session with date, finished or not, its headline numbers and their z against own normal, and how many were offered, played and finished in the last 7 and 28 days. For focus and breathing also the face measures with the tracking quality, where they came from (`raw` or `summary`), the frame counts (never the frames), the checked session reading, and the frame reading with its agreement numbers. Check-ins show the tapped items; typed words only when the patient's record allows it. A clinician can download one session's frames for research; each download is logged.

XP and stage are shown as small facts, not as clinical signals.

## 7. What is not built or not checked

- A screen where the person gives or withdraws consent for outside processing. In the prototype the example data sets the flag.
- Calibration of any face threshold against recordings of people.
- The face capture on a real iPhone, as far as the repo shows.
- `ended_by: "interrupted"` is accepted by the server; the app never sends it.

## 8. Game design values (Matthew)

The values of the old section 5 (the light configurations, catch distance, how long a light lives) belonged to the AR round. None applies to the fox design. They remain in the server only for old builds.

Values that shape the game now. Those on the server are in `engine/clinic_engine/mind/lanvi_config.py`:

| Value | Now | Where | Status |
|---|---|---|---|
| XP: focus, breathing, check-in | 10 each | server | from `docs/game-design.md` |
| XP: yesterday's plan done | 15 | server | from `docs/game-design.md` |
| XP: a day walked or slept around own normal | 5 | server | from `docs/game-design.md` |
| Stages | kit 0, young fox 100, grown fox 300 | server | from `docs/game-design.md`; "tune later" |
| XP awards per day | 2 focus, 2 breathing, 1 check-in | server | Mathew's choice. **Matthew to confirm.** |
| Shortest activity that earns XP | 5 seconds | server | Mathew's choice. **Matthew to confirm.** |
| Glow full at | 50 XP | server | Mathew's choice. **Matthew to confirm.** |
| A wandering lasts | 3 hours | server | Mathew's choice ("a few hours" in the design). **Matthew to confirm.** |
| "Welcome back" line after | 3 days away | server | Mathew's choice. **Matthew to confirm.** |
| What helps, and what is suggested first | moving: walk, daylight. music: breathing, sparks. people: call someone. quiet: breathing, check-in | server | Mathew's choice. **Matthew to confirm.** |
| Sparks and snow length | 45 seconds | app | from `docs/game-design.md` |
| Breathe with Lanvi | 6 breaths | app | from `docs/game-design.md` |
| Lanvi's lines, the five stories, the check-in lists | `engine/clinic_engine/data/lanvi_lines.json`, `checkin_catalog.json` | server | drafts. **Matthew to review the wording.** |

Still to decide, Matthew:

1. Tail glow. The handbook (`ios/HANDOFF.md`) says no light or glow on the fox's tail. Several server lines say "my tail glows", and the growth meter is called `glow`. Keep the word, or change the lines?
2. Which moments in each game count as pleasant (`moments_ms`). Today: when Lanvi cheers.
3. Whether the day limits and the 5-second floor fit the "never earn less on a bad day" rule as you mean it.
4. Naming the fox and the tail colour from the design: not in the app or the server. Cut, or later?

## 9. Open points

1. **Peter:** run the device list in `ios/SENSORS.md`, above all the sign of `headPitch` (looking down must be positive). The app takes the angles from the camera's portrait view matrix; `docs/face-raw.md` describes the inverse camera transform. Check that both give the same sign on a phone.
2. **Aalto mentors:** which measures they would trust: reaction time, smiles, facial activity, check-ins.
3. **Mathew:** the server needs 5 earlier sessions of a type before it has an own normal. For the demo the seed data supplies them, marked as example data.
4. **All:** the two readings send numbers to Gemini. In the demo that is example data. With real patients it needs their consent and an agreement with the provider. "No identifier in the data" is what we can state; it is not a legal finding of anonymity. Say so in the pitch.
