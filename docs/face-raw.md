# Raw face frames: what the phone sends

For the iOS developer. During a focus or breathing activity, when the person allowed the camera, the phone sends the raw numbers ARKit gives for each frame. **The phone computes nothing from the face.** The server computes every face measure, and keeps the frames, so the rules can be changed later and every session analysed again.

Send numbers only. Never an image, a video, the face mesh or geometry, a name or any identifier.

## Where it goes

`face_raw` is one field of the activity record sent to `POST /v1/activities` (see `docs/api/README.md`, step 5). It is allowed on `focus` and `breathing` records only. Send `face_raw` or the older `face` summary, never both (both give 422).

## The shape

```json
{
  "id": "4f1c7f9e-2b7a-4d0e-9a51-0c3e5f7a9b21",
  "type": "focus",
  "started_at": "2026-11-14T09:12:03Z",
  "duration_s": 45.2,
  "completed": true,
  "ended_by": "finished",
  "correct_taps": 17, "wrong_taps": 1, "misses": 2,
  "reaction_ms": [512, 498, 530],
  "face_raw": {
    "rate_hz": 30,
    "channels": ["mouthSmileLeft", "mouthSmileRight", "eyeBlinkLeft", "eyeBlinkRight",
                 "cheekSquintLeft", "cheekSquintRight", "browDownLeft", "browDownRight",
                 "browInnerUp", "eyeLookDownLeft", "eyeLookDownRight", "jawOpen",
                 "headPitch", "headYaw", "headRoll"],
    "samples": [
      [0.041, 0.052, 0.083, 0.071, 0.020, 0.024, 0.061, 0.058, 0.112, 0.214, 0.207, 0.031, 6.2, -1.4, 0.8],
      [0.047, 0.055, 0.092, 0.080, 0.021, 0.025, 0.060, 0.057, 0.109, 0.219, 0.211, 0.029, 6.1, -1.3, 0.8],
      [0.312, 0.288, 0.074, 0.069, 0.183, 0.191, 0.044, 0.041, 0.097, 0.205, 0.199, 0.052, 6.0, -1.3, 0.9]
    ],
    "tracked": [1, 1, 1],
    "moments_ms": [40]
  }
}
```

| Field | Required | What |
|---|---|---|
| `rate_hz` | yes | Frames per second of `samples`, 5 to 60. |
| `channels` | yes | The names of the values in each row, in order. |
| `samples` | yes | One row per frame, oldest first, each with exactly as many numbers as `channels`. |
| `tracked` | no | One 0 or 1 per frame: `ARFaceAnchor.isTracked`. Leave it out when every frame was tracked. |
| `moments_ms` | no | Up to 20 times, in ms from the first frame, of pleasant moments in the activity (for example a spark burst or Lanvi's happy animation). The server looks for a smile after each. |

## Channels

Send every blend shape ARKit reports, with the identifiers exactly as ARKit names them (`ARFaceAnchor.BlendShapeLocation.rawValue`), plus the three head angles:

```
browDownLeft browDownRight browInnerUp browOuterUpLeft browOuterUpRight cheekPuff
cheekSquintLeft cheekSquintRight eyeBlinkLeft eyeBlinkRight eyeLookDownLeft eyeLookDownRight
eyeLookInLeft eyeLookInRight eyeLookOutLeft eyeLookOutRight eyeLookUpLeft eyeLookUpRight
eyeSquintLeft eyeSquintRight eyeWideLeft eyeWideRight jawForward jawLeft jawOpen jawRight
mouthClose mouthDimpleLeft mouthDimpleRight mouthFrownLeft mouthFrownRight mouthFunnel
mouthLeft mouthLowerDownLeft mouthLowerDownRight mouthPressLeft mouthPressRight mouthPucker
mouthRight mouthRollLower mouthRollUpper mouthShrugLower mouthShrugUpper mouthSmileLeft
mouthSmileRight mouthStretchLeft mouthStretchRight mouthUpperUpLeft mouthUpperUpRight
noseSneerLeft noseSneerRight tongueOut
headPitch headYaw headRoll
```

- Blend shapes are 0 to 1, as ARKit gives them.
- `headPitch`, `headYaw`, `headRoll` are degrees, -180 to 180. `headPitch` is positive when the chin goes down (looking down at the phone).
- Required: `mouthSmileLeft`, `mouthSmileRight`, `eyeBlinkLeft`, `eyeBlinkRight`. Every other channel is optional, but a measure that needs a missing channel comes back null, so send them all.
- Head angles: take the face anchor's transform relative to the camera (`simd_inverse(frame.camera.transform) * faceAnchor.transform`), read its rotation as Euler angles (pitch about x, yaw about y, roll about z), convert radians to degrees, and flip the sign of pitch if needed so that looking down is positive.

## Rate and size

- 30 frames per second is enough. Sample at a steady rate; if ARKit runs at 60, keep every second frame.
- Round blend shapes to 3 decimals and angles to 1 or 2. A 60-second activity with all 55 channels at 30 Hz is about 0.6 MB of JSON.
- Limits: at most 60 channels, 12,000 samples (400 seconds at 30 Hz) and 20 moments. The body of `POST /v1/activities` may be up to 4 MiB; with all 55 channels at 3 decimals, 12,000 samples is about 4 MB, the edge of the limit. Larger bodies give 413.
- The frames should not last much longer than `duration_s` (more than 1.2 times plus 5 seconds is refused). The 3-frame example above is valid but too short for any measure: with less than 5 seconds of tracked frames only `tracking_quality` is computed.

## Errors

All give 422 `invalid_request`, with a message that names the position (never your values), unless noted. The message starts with where the problem is, for example `focus.face_raw: Value error, ...`:

| Problem | Example message |
|---|---|
| Unknown channel name | `channels[3] is not an ARKit blend-shape name or one of headPitch, headYaw, headRoll` |
| A channel twice | `channels[7] repeats an earlier channel` |
| A required channel missing | `channels must include eyeBlinkRight` |
| A row of the wrong length | `samples[9] has 14 values; channels has 15` |
| NaN or infinity | `samples[3][0] is not a finite number` |
| Blend shape outside 0 to 1 (more than 0.02 over) | `samples[3][0] (mouthSmileLeft) is outside 0..1` |
| Angle outside -180 to 180 | `samples[3][12] (headPitch) is outside -180..180 degrees` |
| `tracked` not one per frame | `tracked has 2 values; samples has 1350` |
| Too many channels, samples or moments | `focus.face_raw.channels: List should have at most 60 items after validation, not 61` |
| `face` and `face_raw` together | `send either face (a summary) or face_raw (raw frames), not both` |
| `face_raw` on a check-in | 422 `invalid_request` |
| Frames much longer than the activity | 422 `implausible_activity`: `face_frames_longer_than_activity` |
| Body too large | 413 `body_too_large` |

Re-sending the same record with the same frames is safe: the answer has `xp_gained: 0` and the frames are stored once. The same `id` with different frames is 409.

The Lanvi app sends a record with frames through a session with a 90 s request timeout (the small calls get 6 s), because the body is 0.4 to 3 MB and an upload that times out is kept and fails the same way on every open. When the server refuses a record with frames (413 or 422), the app sends it once more without them, same id, so the activity itself is never lost; the reason is in the debug log (`lanvi-net:`). A reverse proxy in front of the engine must allow bodies above 4 MiB on this route (`deploy/apache-vhost.conf`).

## What the server computes

The server computes the same summary an older phone sent as `face`, so everything after it (the person's own normal, the watchers, the session reading, the research appraisal) works as before. The thresholds live in `engine/clinic_engine/mind/thresholds.py`; the code in `engine/clinic_engine/mind/face_features.py`. The event rules follow the FaceMetrics research app in `facemetrics/`.

General rules:

- Only tracked frames are used. With less than 5 seconds of tracked frames, every measure is null except `tracking_quality`.
- A smile or blink is found with hysteresis: it starts at the first frame at or above the onset value and ends at the first frame at or below the offset value. An event never crosses frames that were not tracked: a smile is closed at the last tracked frame, a blink is dropped (its length is unknown).
- Movement is measured on blocks of about 0.1 seconds (3 frames at 30 Hz, 6 at 60 Hz, 1 frame below 10 Hz), so the frame rate does not change the result much.

| Measure | Rule | Threshold |
|---|---|---|
| `tracking_quality` | Share of frames with `tracked` = 1. Below 0.6 the session is kept but never used for the person's own normal. | - |
| `smile_rate_per_min` | Smiles per tracked minute. Smile signal = mean of `mouthSmileLeft` and `mouthSmileRight`. | onset 0.25, offset 0.15, at least 0.3 s |
| `smile_time_share` | Share of tracked time inside smiles. | as above |
| `smile_intensity` | Mean smile signal inside smiles; null with no smile. | as above |
| `smile_asymmetry` | Mean of \|`mouthSmileLeft` - `mouthSmileRight`\| inside smiles; null with no smile. | as above |
| `eye_smile_share` | Share of smiles in which the mean of `cheekSquintLeft` and `cheekSquintRight` inside the smile reaches the threshold (a smile that reaches the eyes). Null with no smile or without those channels. | 0.2 |
| `smile_response_share` | Share of `moments_ms` followed by a smile that starts within the window. Moments after the last frame or on an untracked frame are not counted. Null without moments. | 2.5 s |
| `smile_response_latency_s` | Median time from a moment to the smile that answered it. Null when none was answered. | 2.5 s |
| `blink_rate_per_min` | Blinks per tracked minute. Blink signal = the larger of `eyeBlinkLeft` and `eyeBlinkRight` (a blink starts when either eye closes and ends when both are open). Closures longer than 0.5 s are not blinks. | onset 0.5, offset 0.3, 0.03 to 0.5 s |
| `blink_duration_ms` | Median blink length. Null with no blink. | as above |
| `look_down_share` | Share of tracked frames where the mean of `eyeLookDownLeft` and `eyeLookDownRight` is at or above the threshold. | 0.3 |
| `brow_down_share` | Same with the mean of `browDownLeft` and `browDownRight`. | 0.3 |
| `inner_brow_up_share` | Same with `browInnerUp`. | 0.3 |
| `lip_down_share` | Same with the mean of `mouthFrownLeft` and `mouthFrownRight` (lip corners pulled down). Estimated, not calibrated; expected to be 0 in most sessions. Not in the hypothesis list. | 0.3 |
| `lip_press_share` | Same with the mean of `mouthPressLeft` and `mouthPressRight` (lips pressed together). Estimated, not calibrated; also rises with concentration and closed-mouth smiles. Not in the hypothesis list. | 0.3 |
| `facial_activity` | Mean change per second of every blend shape except the two blink channels, between neighbouring 0.1 s blocks, divided by 0.5 and clipped to 0 to 1. A still face (ARKit jitter, about 0.05 per second) gives about 0.1; a lively face (talking, smiling, about 0.3 per second) about 0.6. Estimated, not yet calibrated on recordings. | full scale 0.5 per second |
| `head_pitch_deg` | Mean `headPitch` (looking down is higher). | - |
| `head_tilt_deg` | Mean of \|`headRoll`\|. | - |
| `head_movement` | Mean angular speed of the head between neighbouring 0.1 s blocks (pitch, yaw and roll together, degrees per second), divided by 30 and clipped to 0 to 1. A still head gives about 0.1, a lively one (about 18 degrees per second) about 0.6. Estimated, not yet calibrated. | full scale 30 deg/s |

## What happens to the frames

- The summary is stored on the activity record (with `face_source: "raw"`); the frames are stored as their own object for that activity, as sent.
- The frames go to a model only as described in "What a model sees" below. The reduced stream sent to the model is kept with the model's reply in the stored exchanges, for the clinician. The frames never appear in the audit log, the decision trace, the server logs, or the clinician's patient list and detail (the detail shows counts only: rate, frames, tracked share, number of channels).
- A clinician of the person's clinic can download one session's frames for research: `GET /v1/clinic/patients/{patient_id}/activities/{activity_id}/face-raw`. Each download is audited.
- When the rules change, `POST /v1/demo/recompute-face {"patient_id": "..."}` (admin, or a clinician of the demo clinic) computes the summary of every raw session again from the stored frames.

## What a model sees

The project reads the frames with a model (level 2: Gemini, or the local stand-in); code is the checker and the fallback. The face summary above is always computed by code and is not changed by the model.

- **The reduced stream.** Not the frames as sent: a JSON object with `activity` (`focus` or `breathing`), `rate_hz`, `channels`, `frames` and `moments_s` (seconds), nothing else. Up to 15 named channels: `t` (seconds from the first frame, so the model reads times and does not count rows; never a clock time), then, each only when its source channels exist: `smile` (mean of `mouthSmileLeft` and `mouthSmileRight`), `smile_left`, `smile_right`, `cheek` (mean `cheekSquint`), `frown` (mean `mouthFrown`), `blink` (the more closed eye), `look_down`, `brow_down`, `brow_inner_up`, `jaw_open`, `head_pitch`, `head_yaw`, `head_roll`, and `tracked`. Blocks of frames are averaged to 5 rows per second (`blink` takes the block's maximum, so a short blink is not averaged away), values rounded to 2 decimals (angles to 1), at most 400 rows (a longer recording gets a lower rate, and the rate used is sent). A 45-second session is 225 rows, about 16,000 characters. No id, date, clock time, name or text. Two things this does not cover: the call is made right after the upload, so the service can see when it arrived; and "no identifier" is what we can state, not a legal finding of anonymity.
- **The prompt** is `engine/clinic_engine/data/frames_prompt.txt`: the model describes movement only (smiles with start, end, whether they reach the eyes and which side; blink count; stretches such as looking down or a still face; answers to the pleasant moments; a few fixed overall words). Never a mood, a symptom or a diagnosis. It is asked to judge a smile against this person's own resting level, not against a fixed number. The request also carries the reply's shape as a response schema; the call is tried once more when the service is busy or the reply is empty.
- **The consent switch.** The stream is sent only when the patient's record allows outside processing (`allow_outside_processing`) and level 2 is on (`OUTREACH_MODE=gemini` with a key and a model, or the local stand-in; the default is off). In this prototype the example data sets that flag; a screen where the patient grants and withdraws it is not built yet. `FRAMES_READER=off` turns the frame reading off while level 2 stays on (the default is `auto`). Without consent nothing is sent and the reading is `not_allowed`. The stream never goes to level 1 and is never part of any other model task. It is checked again right before sending (fixed keys, known channel names in order, rounded numbers in range, size).
- **Code checks every item** against its own detection on the full-rate frames, with the thresholds in `thresholds.py` (`frames_*`). Anything that is not the exact JSON shape, or has a time outside the recording, is refused whole. The result is shown to the clinician only (`frames_reading` in the patient detail, and the panel "Two readers on one session" on the Activity tab). It never reaches the patient and never changes suggestions or lessons. One exception since 14 November: when the model finds something the fixed rules did not flag and code confirms it in the numbers (a lower stretch in the daily numbers that is still going on, or smiles that became faint over the last sessions), the mind opens a flag for the clinic at the lowest level, "noticed by the model, confirmed by code". It never brings an offer to the patient and never an alert by itself.
  - A reported smile is the same smile as one code found when the two spans overlap by at least 0.3 of their union, each of code's smiles once. So a sliver inside a smile does not count, and neither does a span several times wider than it. Its `reaches_eyes` and side are set to code's, and the difference in start and end is recorded.
  - **Faint smiles.** Code's rule has a fixed onset (0.25). A reported smile that touches no smile of code's is tested against the local resting level: the median of the smile signal within 8 seconds before the span and within 8 seconds after it, the higher of the two (a smile returns to rest on both sides; a step in the baseline, as when the phone moves, does not). When the span lies above that rest by at least 0.05 on average and 0.10 at its peak, for at least 0.3 s, and both mouth corners carry the rise, it is kept apart: as a faint smile when its peak stays under the fixed onset ("reported by the model, under the fixed rule, rise confirmed in the numbers"), or as a brief smile when it passes the onset but is shorter than the rule's minimum length. Otherwise it is dropped, and so is a second report of the same rise. One more case: a report that lies inside a smile of code's at least four times longer (and at least 5 s long) is not dropped as a poor match at once, because the fixed rule reads a mouth that rests near its onset as one long smile. It is tested against the local rest with twice the peak margin and kept apart as `inside_long` when the rise and the return are in the numbers. Faint smiles never change the face summary. The two margins are estimates, not calibrated; ARKit jitter on a resting mouth is about 0.02.
  - Each stretch is kept only when it lasts at least 2 seconds and code finds the same thing in most of it. Blink counts stand side by side.
  - The overall words are shown as code's, with the model's beside them. They are not part of the item agreement.
- **The agreement.** Per session: how many of the model's smiles code also found (precision, over the smiles at code's level), how many of code's smiles the model also reported (recall), the mean difference in start time, and the faint smiles. Over all sessions of a patient the same, with the number of sessions (`activities.frames_agreement`). These compare two methods. Neither is the truth: the fixed rule's thresholds are not calibrated on recordings.
- **The reference set.** `python -m clinic_engine.frames_reference` makes synthetic sessions with smiles planted at known places, strong ones and faint ones, and scores each reader against the planted truth; `--model` also sends them to level 2 through the same gates. There are two sets: 40 clean sessions, and 10 hard ones that add things which are not smiles but move the same numbers (talking, a step in the baseline when the phone moves, a mouth that rests close to the fixed onset). A second code rule, with its onset relative to the session's resting level, is scored beside the product's fixed rule. It is not in the product; it was written after the model showed what the fixed rule misses, to answer "could code do that alone?" with a number.

  Run on 14 November 2026 with `gemini-3.8-flash`, 50 of 50 calls answered, about 28 seconds a call:

  | Reader | Clean: strong found | Clean: faint found | Clean: reported with no planted smile | Hard: strong found | Hard: faint found | Hard: reported with no planted smile |
  |---|---|---|---|---|---|---|
  | Code, fixed rule (the product's summary) | 121 of 121 | 0 of 89 | 0 of 121 | 20 of 28 | 0 of 13 | 3 of 23 |
  | Code, rule relative to the person's rest | 121 of 121 | 89 of 89 | 0 of 210 | 28 of 28 | 13 of 13 | 22 of 63 |
  | Gemini, as reported | 121 of 121 | 89 of 89 | 0 of 210 | 28 of 28 | 13 of 13 | 0 of 41 |
  | Gemini, after code's check | 121 of 121 | 89 of 89 | 0 of 210 | 28 of 28 | 13 of 13 | 0 of 41 |

  What this shows: on a clean signal a rule relative to the person's rest does as well as the model. On the hard set that rule reports 22 things that are not smiles, the fixed rule misses 8 strong smiles (it reads a mouth that rests high as one long smile), and the model makes neither mistake. Against the fixed rule the model's agreement is: clean set, all 121 of code's smiles reported and matched, mean difference in start 0.16 s; hard set, 20 of code's 23 smiles reported (the 3 it left out were not planted smiles).

  Counted again later the same day, 70 of 70 calls answered:

  - **On the setting the server now uses** (the model asked to think little, about 4 seconds a call instead of about 28), the same 50 sessions: the smile counts are identical to the table above in every cell. Blink counts are worse: Gemini's count agreed with code's in 29 of 50 sessions, against 50 of 50 with default thinking.
  - **A second hard set**, 20 sessions on new seeds (`--sessions 0 --hard-seed 5000 --hard-count 20`), generated after the instruction and the check were frozen and read once on the fast setting: the fixed rule 44 of 59 strong, 0 of 31 faint, 6 wrong reports of 50; the rule relative to rest 59 of 59, 31 of 31, 32 wrong of 122; Gemini 59 of 59, 31 of 31, 0 wrong of 90, unchanged by code's check. Blink counts agreed in 8 of 20.

  - **A third hard set**, 12 sessions with a yawn, chewing or fading light (`--sessions 0 --hard-seed 7000 --hard-count 12 --hard-kinds yawn,chewing,drift --repeat 3`). The instruction does not name any of these. Each session was read three times on the fast setting, 36 of 36 calls answered: the fixed rule 34 of 34 strong, 0 of 20 faint, no wrong report; the rule relative to rest 34 of 34, 20 of 20, 12 wrong of 66; Gemini over the three reads 102 of 102 strong, 58 of 60 faint, 0 wrong of 160, unchanged by code's check. The same smiles came back in all three reads in 11 of 12 sessions.

  What it does not show:
  - Anything about real faces. The streams are made by that file: smooth rises, simple noise. Real recordings will be worse for every reader, and no number here says how well any of them reads a person.
  - A blind test of the first hard set. The prompt names talking and a shift of the resting level as things that are not smiles, and the first and second hard sets contain exactly those. The model was told what to look for; the two code rules were not changed to handle them. The third set uses disturbances the prompt does not name, but two of them resemble what it does name (a yawn is a moving jaw; fading light is a level that rises and stays), the generated chewing turned out too weak to mislead any reader, and no disturbance overlaps a smile. It is a near test, not the unknown.
  - Robustness from read to read. The first two sets were read once. The third was read three times, but the calls run at temperature 0, so three reads are close to one read repeated; one session of twelve still differed.
  - How the check was arrived at. Code's check was changed once after the first full run (the "inside a longer smile" rule), on the first sets. Nothing was changed after the second or the third set.
- **Where the stream is kept.** Every model exchange is stored for the clinician (`GET /v1/clinic/patients/{id}/exchanges`), and for the frame reading that exchange holds the reduced stream as sent and the model's raw reply. Each read of the exchanges is audited.
