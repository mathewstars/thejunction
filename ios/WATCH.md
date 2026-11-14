# Lanvi on the Apple Watch: live heart data during the games

For Peter and the captain. A tiny watch app records heart rate (and HRV when the watch writes one) while a game runs on the phone; the phone lines it up with the game's moments (`GameMoments`) and the ARKit face frames (`face_raw`) under one session id and sends it all in the activity record (`sensors`, see `docs/sensors.md`). The server computes the summary and, with consent, asks Gemini for a reading that code checks.

Nothing was rebuilt: the games, `GameMoments`, the face capture (PR #9) and the server's activity route are used as they are. Without a watch the app behaves exactly as before.

## The flow

1. The person taps the one thing for today on Home. `ActivityRouter` wraps the activity in `SensorSessionHost`, which creates the **session id** (the record's `id`) and starts a `SensorSession` listening to `GameMoments`.
2. With an Apple Watch paired and Lanvi installed on it, the phone shows **"Open Lanvi on your Apple Watch and tap Start"** (`WatchGateView`) and tells the watch which game is waiting. "Play without my watch" skips the wait.
3. The person opens Lanvi on the watch and taps **Start recording**. The watch starts an `HKWorkoutSession` with an `HKLiveWorkoutBuilder` (Mind and Body, indoor) and two anchored HealthKit queries, and says "started".
4. The phone hears it and shows the game. The game's own Start button is unchanged; the `focusStarted` / `breatheStarted` / `checkinStarted` moment marks the exact start. The face capture starts as in PR #9.
5. During the game the watch sends every real HealthKit sample (heart rate; HRV SDNN whenever one appears) with HealthKit's own times and uuid, live while the phone is reachable, queued otherwise.
6. When the game ends the phone attaches the face frames, tells the watch to stop, waits up to 2.5 s for its last flush, puts `sensors` on the record and hands it to `AppStore.finish`, which posts it (`POST /v1/activities`, retried from the outbox when offline). The server summarizes and schedules the sensor reading.

## Clocks and alignment

Three sources, two clocks. Game moments carry both a wall-clock `date` and `uptime` (`CACurrentMediaTime()`, the same clock as `ARFrame.timestamp`). Face frames have uptime only. Watch samples have wall clock only.

- The record's `started_at` is the wall-clock anchor. The start moment fired at the same instant, so its `uptime` gives `sensors.clock.started_uptime_s`, the monotonic anchor.
- Each moment goes as `t_ms` from the anchor on the monotonic clock (exact) and `wall_ms` on the wall clock. Their difference shows drift; the server refuses more than 2 s.
- Each watch sample goes as `t_ms` from `started_at` on the wall clock, exactly as HealthKit stamped it. iPhone and Apple Watch clocks are kept together by the system; the server keeps them as sent.
- The first kept face frame goes as `face_offset_ms` on the monotonic clock, so frame `i` is at `face_offset_ms + i * 1000 / rate_hz` and a moment at `t_ms` lands on frame `(t_ms - face_offset_ms) * rate_hz / 1000`. `FaceSense.attach` exposes that anchor (`lastFaceAnchorUptime`) through two small additions to PR #9's `FaceRawRecorder` and `FaceTracker` (`faceRawAnchored`, `finishAnchored`); nothing else in the face code changed.

The pure function behind all this is `SensorSession.sensors(...)`; `ios/LanviTests/SensorSessionTests.swift` checks it.

## Files

| Where | What |
|---|---|
| `ios/Shared/WatchProtocol.swift` | The words both sides use (dictionaries of plist types; sample rows with HealthKit's times and uuid). Compiled into both targets. |
| `ios/Lanvi/Sense/Watch/WatchLink.swift` | The phone's `WCSession`: status (no watch, no app, ready), reachability, pushes the session context, takes samples, drops duplicates by uuid. Activated at launch in `RootView`. |
| `ios/Lanvi/Sense/Watch/SensorSession.swift` | One session: id, `GameMoments` token, watch samples, the clock maths, `attach(to:)`. |
| `ios/Lanvi/Sense/Watch/WatchGate.swift` | `SensorSessionHost` (wraps an activity) and `WatchGateView` (the waiting screen, in Lanvi's scene). |
| `ios/Lanvi/Screens/ActivityRouter.swift` | Wraps the three activities in the host; `finish` orders face, watch flush, record. |
| `ios/Lanvi/Net/APIModels.swift` | `API.Sensors` and the field on `ActivityIn`. |
| `ios/LanviWatch/` | The watch app: `WorkoutRecorder` (workout session, live builder, anchored queries), `PhoneLink` (`WCSession`, batches, retry, final flush), `WatchHome` (the screen), `LanviWatchApp`. |
| `ios/project.yml` | The `LanviWatch` target (watchOS 10, single target, embedded in Lanvi). |

## Build

`cd ios && xcodegen generate`, then open `Lanvi.xcodeproj`. This branch was written on Windows without Xcode, so the committed `Lanvi.xcodeproj` is still main's and does not know the new files: regenerate first. Expect first-build fixes of the usual kind (an `await` here, an isolation note there).

Launch arguments: `-watchAsk` shows the waiting screen before a game even without a watch; `-screen watch` opens it on its own (screenshots). `-demo` never waits for a watch.

## What works where

| | Simulator | iPhone alone | iPhone + Apple Watch |
|---|---|---|---|
| Games, face frames, `GameMoments` on the record | moments yes, face no | yes | yes |
| Waiting screen | with `-watchAsk` | never (no watch: straight to the game) | yes |
| Heart rate, HRV, watch flow | no (the paired-watch simulator can run the UI but gives no HealthKit heart samples) | no | **needs a real watch** |
| Server summary and sensor reading | yes (engine tests send a synthetic block) | yes | yes |

Not checked here (no Mac, no Xcode, no watch): that the two targets build, that WatchConnectivity pairs the two apps, that `HKLiveWorkoutBuilder` streams heart rate at the expected rate on a wrist, and the waiting-screen look on a device. Checked here: the server side end to end with synthetic sessions (`engine/tests/test_sensors.py`), and the message format and clock maths by reading.

## Device test list

1. Pair a watch, install Lanvi on it (it is embedded in the phone app). Start Sparks and snow: the waiting screen shows "Waiting for your watch"; open Lanvi on the watch: "Your watch is listening"; tap Start recording: the game appears within a second.
2. Play to the end, tap Done. Clinician page, this session: `sensors.heart_rate.samples_in_activity` about one per second or two, `trend`, `moments.count` about 20 to 25, `moments.heart_rate_after.spark_caught.n` = the catches.
3. Breathe with Lanvi: `sensors.breaths` has six rows with a heart rate each.
4. With the face allowed: `sensors.alignment.face_offset_ms` is set and small (a few hundred ms, negative when the camera started before Start).
5. Walk the phone out of Bluetooth range mid-game, come back, finish: the samples arrive (the watch queues them); `samples` on the record may be fewer if they land after the 2.5 s wait; later arrivals are dropped, never duplicated.
6. "Play without my watch": no waiting, record without `watch`, moments still on it.
7. Watch app alone, no game waiting: Start is disabled and the screen says to start a game on the phone first.
8. With the server's `OUTREACH_MODE=gemini` and the patient's consent: the session's `sensor_reading` becomes `ready` with the fixed words; its `dropped` list shows what code did not confirm.

## Honest notes

- HRV: watchOS writes an SDNN sample only occasionally (often during rest, rarely inside a one-minute game). The screen says "none yet" until one exists and shows its time. No HRV is ever computed on the phone or watch from beat intervals.
- The workout is saved to Health as a short Mind and Body workout; that is the price of workout-rate heart sampling. It can be discarded instead (`finishWorkout` → `discardWorkout`) if the captain prefers.
- The watch must be opened by hand. iOS cannot launch a watch app from the phone.
