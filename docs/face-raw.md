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
| `facial_activity` | Mean change per second of every blend shape except the two blink channels, between neighbouring 0.1 s blocks, divided by 0.5 and clipped to 0 to 1. A still face (ARKit jitter, about 0.05 per second) gives about 0.1; a lively face (talking, smiling, about 0.3 per second) about 0.6. Estimated, not yet calibrated on recordings. | full scale 0.5 per second |
| `head_pitch_deg` | Mean `headPitch` (looking down is higher). | - |
| `head_tilt_deg` | Mean of \|`headRoll`\|. | - |
| `head_movement` | Mean angular speed of the head between neighbouring 0.1 s blocks (pitch, yaw and roll together, degrees per second), divided by 30 and clipped to 0 to 1. A still head gives about 0.1, a lively one (about 18 degrees per second) about 0.6. Estimated, not yet calibrated. | full scale 30 deg/s |

## What happens to the frames

- The summary is stored on the activity record (with `face_source: "raw"`); the frames are stored as their own object for that activity, as sent.
- The frames never go to any model, never appear in the audit log, the decision trace, the server logs, or the clinician's patient list and detail (the detail shows counts only: rate, frames, tracked share, number of channels).
- A clinician of the person's clinic can download one session's frames for research: `GET /v1/clinic/patients/{patient_id}/activities/{activity_id}/face-raw`. Each download is audited.
- When the rules change, `POST /v1/demo/recompute-face {"patient_id": "..."}` (admin, or a clinician of the demo clinic) computes the summary of every raw session again from the stored frames.
