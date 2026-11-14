# Fine facial movement: what the phone may send (research only)

For the iOS developer. This is the server side of the idea in `docs/research-proposal.md`, "A finer signal we would try next". It is an experiment: the server takes the numbers, sums them up, keeps them and shows them on the clinician page beside the person's own earlier sessions. No flag, level, reading or model uses them.

The rule that does not change: **no face shape leaves the phone.** A mesh and a depth map are the shape of a face. So this is the one place where the phone computes before it sends. What leaves is, for a few named regions and for every frame, one distance in millimetres.

## Where it goes

`face_fine` is one more optional field of the activity record sent to `POST /v1/activities`, on `focus` and `breathing` records only. It can come with `face_raw`, with `face`, or alone. A record without it is treated exactly as before.

```json
{
  "id": "4f1c7f9e-2b7a-4d0e-9a51-0c3e5f7a9b21",
  "type": "focus",
  "started_at": "2026-11-14T19:12:03Z",
  "duration_s": 90.0,
  "completed": true,
  "ended_by": "finished",
  "correct_taps": 6, "wrong_taps": 0, "misses": 1,
  "reaction_ms": [512, 498, 530, 470, 601, 455],
  "face_fine": {
    "source": "mesh",
    "rate_hz": 60,
    "regions": ["mouth_left", "mouth_right", "cheek_left", "cheek_right", "brow_left", "brow_right"],
    "samples": [
      [0.21, 0.19, 0.11, 0.12, 0.08, 0.07],
      [0.24, 0.20, 0.11, 0.12, 0.08, 0.08],
      [1.31, 0.42, 0.35, 0.14, 0.09, 0.08]
    ],
    "tracked": [1, 1, 1],
    "noise_mm": 0.25
  }
}
```

| Field | Required | What |
|---|---|---|
| `source` | yes | `mesh` (the ARKit face mesh) or `depth` (the TrueDepth depth map). |
| `rate_hz` | yes | Frames per second of `samples`, 5 to 60. |
| `regions` | yes | The names of the values in each row, in order, from the list below. `mouth_left` and `mouth_right` are required. 2 to 12 names, none twice. |
| `samples` | yes | One row per frame, oldest first, one number per region: millimetres, 0 to 50. At most 12,000 rows. |
| `tracked` | no | One 0 or 1 per frame. Leave it out when every frame was tracked. |
| `noise_mm` | no | The noise floor you measured in this session (see below), 0 to 5. Send it if you can: the twitch rule uses it. |

No other field is accepted. In particular no vertices, no coordinates, no depth values, no image.

## Regions

```
mouth_left  mouth_right  lip_upper  lip_lower  cheek_left  cheek_right
brow_left   brow_right   eyelid_left  eyelid_right  jaw  nose
```

Left and right are the person's own left and right, as in ARKit's blend-shape names.

## What one number means

For one region in one frame: **how far the region is from this person's resting shape, after the head's movement is taken out, in millimetres.** Zero means the region is where it rests.

A way to compute it from the mesh (`ARFaceGeometry.vertices`):

1. The vertices are already in the face anchor's own coordinates, so the head's movement is out. They are in metres; multiply by 1000.
2. Pick a fixed set of vertex indices for each region once (the mesh topology never changes), and keep it in the app.
3. The resting shape: per vertex, the median position over the first two or three seconds of the session, while the face is still. Keep it on the phone; never send it.
4. Per frame and region: the mean, over the region's vertices, of the distance between the vertex and its resting position.
5. `noise_mm`: the same number computed over frames you know to be still (for example the two seconds used for the resting shape), averaged over regions.

**In the app this is built** (`FaceFineRecorder`, `ios/SENSORS.md`), with two differences from the recipe: the resting shape is the median of the first 45 tracked frames (1.5 seconds at 30 a second), and regions are found by where they lie on the resting face instead of by fixed vertex numbers. It compiles for a device and its unit tests pass; it has not run on a phone yet, so the region boxes are unchecked.

From the depth map (`ARFrame.capturedDepthData`), the idea is the same with one more step: project each region into the depth image, and send how far the measured surface is from where the resting shape would be. The depth map does not arrive on every frame; set `rate_hz` to the rate you really have.

**What we expect, and have not measured:** ARKit builds the mesh from the same fit as the blend shapes, so `mesh` may show little that `face_raw` does not already show. The depth map is the independent measurement. That is the first thing to find out (see the first experiment in the research proposal), and it is why `source` is in the record.

## Size and limits

- 60 frames a second for 90 seconds with 12 regions at 2 decimals is about 0.4 MB. The body of `POST /v1/activities` may be up to 4 MiB in total, together with `face_raw`.
- The stream should not last much longer than `duration_s` (more than 1.2 times plus 5 seconds is refused).

## Errors

All give 422 `invalid_request` with a message that names the position, never your values, unless noted.

| Problem | Message |
|---|---|
| A name that is not in the list | `regions[3] is not one of the region names in docs/face-fine.md` |
| A region twice | `regions[2] repeats an earlier region` |
| A required region missing | `regions must include mouth_left, mouth_right` |
| A row of the wrong length | `samples[9] must have 6 values, one per region` |
| A value that is not a distance | `samples[3][0] must be a distance from 0 to 50 mm` |
| `tracked` not one per frame | `tracked must have one value per sample` |
| Any other field | `Extra inputs are not permitted` |
| Stream much longer than the activity | 422 `implausible_activity`: `fine_frames_longer_than_activity` |

Re-sending the same record is safe, as for any activity. The same `id` with a different stream is 409.

## What the server does with it

1. Stores the stream as sent, as its own object (`facefine/{activity_id}.json`), outside the activity record.
2. Puts a summary on the activity record (`face_fine`) and counts (`face_fine_info`: source, rate, frames, tracked share, number of regions).

The summary (`clinic_engine/mind/face_fine.py`), on tracked frames only, after a running median of three frames:

| Per region | What |
|---|---|
| `level_mm` | Where the region usually sits in this session (the median). |
| `reach_mm` | How far above that it goes (95th percentile minus the median). |
| `speed_mm_s` | How fast it moves at its fastest (95th percentile of the change per second). |
| `twitches_per_min` | Brief movements: at least 0.5 mm above the usual level and at least 3 times `noise_mm` (0.3 mm when not sent), lasting from 2 frames to 0.4 seconds. Anything longer is an expression, not a twitch. Since rules version 2 the whole rise must be brief too (at half that height, at most 0.8 seconds): the generated example showed that the top of a slow, small expression was being counted. |

And for each left and right pair, `asymmetry`: -1 when only the right side moves, 0 when both move alike, +1 when only the left side moves.

`quality` is `good`, `partly` (under nine tenths of the frames tracked), `noisy` (`noise_mm` above 1) or `short` (under 5 seconds tracked; every measure is then null).

These thresholds are first guesses. They are not set on recordings of people. Because the stream is kept, the summary can be computed again when they change.

## On the clinician page

Activity, then Focus game or Breathing: the panel "Fine facial movement (research)". For one session it shows four numbers (mean reach over the regions, brief movements per minute over all regions, mean top speed, left against right at the mouth), each beside this person's own usual value: the middle of their earlier sessions, given once there are three. A button loads the trace of the two mouth corners with code's brief movements marked (the download is audited). Nothing is coloured, ranked or judged, and the panel says that nobody has shown these numbers to mean anything.

**What can be seen today is generated.** `python -m clinic_engine.seed_frames` gives the example person (Leo Virtanen, Example F-001) six sessions with a generated stream each, shaped like the app's (twelve regions, 30 a second), livelier in the first three. No real face has been recorded.

## Reading it back

`GET /v1/clinic/patients/{id}/activities/{activity_id}/face-fine` (clinician session): `summary`, `info`, `stream` and `twitches` (where code's rule finds brief movements). 404 when the activity was sent without `face_fine`. Each download is written to the audit log with the activity id and no values.

## For the detection work: a workbench that already runs

Ready before any real recording, in `engine/`. Nothing in it is used by the running server.

```
python -m clinic_engine.fine_reference                     # the code rule on generated sessions
python -m clinic_engine.fine_reference --payload 1003      # instruction + object for a model
python -m clinic_engine.fine_reference --reply 1003 reply.json    # check a model's answer
python -m clinic_engine.fine_reference --stream stream.json       # the same on a stored stream
```

- **Generated sessions** with brief movements planted at known places, plus three kinds that must not be reported: slow expressions, a step (the phone moved) and a higher noise floor.
- **The code rule** (`face_fine.twitches`) scored against the planted places. On 14 November: clean 196 of 196 found and nothing else reported; expressions and noise the same; **after a step it missed 9 of 28**, because the usual level is taken over the whole session. That is the first thing to improve, and a test keeps it visible.
- **A draft instruction** for a model, `engine/clinic_engine/data/fine_prompt.txt`, and `payload()`, which builds what the model would be given (numbers and fixed names only, about 40 KB for 45 seconds).
- **`verify()`**: every item a model reports is checked against the numbers. An item that code also finds is confirmed; every other item is dropped with its reason. Paste a reply from any model into a file and run `--reply` to see it work.
- **With real data**: save the `stream` from the download below and run `--stream`.

Not done on purpose: sending the stream to the server's level 2. That needs its own input and output gate in `mind/gates.py`, as the frame reading has, and it should be written once real streams show what the payload has to carry.

## What it is not

It does not describe mood, symptoms or risk, and nothing on the server treats it as if it did. It is a measurement to compare with the blend shapes and, later and only with consent, with the weekly questionnaire.
