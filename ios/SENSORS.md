# Lanvi's two sensors

For Peter and the captain. Apple Health (how much the person moves and sleeps) and the face during the two games. Both are asked for once, in Lanvi's voice, both can be skipped, and the app works the same without them.

## What came from Peter's harness

From `harness/HKGeminiHarness/` on branch `finalish-testing-app`, copied as he wrote it into `ios/Lanvi/Sense/Peter/` (only a credit line added at the top of each file):

| File | Module |
|---|---|
| `SharedModels.swift`, `JSONValue.swift` | Models |
| `LocalStatistics.swift` | Statistics |
| `HealthKitManager.swift`, `HealthTypeCatalog.swift`, `HealthSummaryBuilder.swift`, `AppleHealthXMLImporter.swift`, `FileExport.swift` | HealthKit |

They build as their own framework target, `Harness` (`ios/project.yml`), so his names (`JSONValue`, `DateRange`, ...) never clash with the app's. They compiled on the first try.

Not taken: the Gemini client, prompts, schema, validator, Keychain store and the proxy. In Lanvi only the server talks to Gemini; the app holds no Gemini key, proxy address or client. (`SharedModels.swift` still declares the Gemini request and response types as plain data, because it is kept whole; nothing in the app uses them.) Also not taken: the ARKit CSV importer and the feature analysers, because the phone no longer computes face features (see below).

## Apple Health

| What | Where |
|---|---|
| First-run screen ("I only look at how much you move and sleep...") | `HealthAskView` in `Sense/SenseViews.swift`, shown by `LanviSense` in `Sense/SenseRoot.swift` after the welcome |
| Permission sheet | `HarnessHealthSource.requestAccess` (`Sense/HarnessHealth.swift`) → Peter's `HealthKitManager.requestHealthPermissions(types:)`, limited to four types: steps, walking speed, HRV (SDNN), sleep analysis |
| Reading days | `HarnessHealthSource.days` → Peter's `fetchDailyStatistics` (steps, sources merged by HealthKit), `fetchHistoricalSamples` (walking speed, HRV, sleep) and `generateHealthDataSummary` (daily means) |
| Turning them into server days | `HealthDayAdapter.days` (`Sense/HarnessHealth.swift`) |
| Sending | `HealthSync.sync` (`Sense/HealthSync.swift`): the history once (up to 400 days), then the missing days on every open, retried quietly |

Sent to `POST /v1/daily`: `{"days":[{"date","steps","walking_speed_m_s","hrv_ms","sleep_h"}]}`. Days without steps are skipped; HRV and sleep are left out when there is no watch. On every open (cold start, or back from the background) the app sends the days not sent yet plus the last 14 sent days again, since a watch hands sleep and HRV to the phone late; the server merges by date, a field left out keeps the stored value, so nothing is blanked. Last night's sleep belongs to the morning it ended, which is today, and today goes out on the first open tomorrow.

One difference from the harness: hours asleep. A watch writes a night as many stage pieces, and `HealthSummaryBuilder` credits each piece to the day it ended, so a piece that ends before midnight lands on the evening before. The adapter joins the pieces into one night first (`SleepMath`) and credits the whole night to the morning. Peter, worth the same fix in the harness.

Simulator and offline demo: `SampleHealthSource` (`Sense/HealthDays.swift`) gives believable days behind the same interface (`-sampleDays N`, `-sampleDip`).

## Face during Sparks and snow and Breathe with Lanvi

The phone computes nothing from the face. It sends the raw numbers per frame and the server computes every measure (`docs/face-raw.md`).

| What | Where |
|---|---|
| The question ("May I watch your face while we play?") and "Not now" | `FaceAskView` in `Sense/SenseViews.swift`, shown once by `FaceSenseHost` around the two games (`Screens/ActivityRouter.swift`) |
| The off switch | `FaceSenseSwitch` on the Help screen (`Screens/Home/HomeOverlays.swift`) |
| Tracking | `FaceTracker` (`Sense/FaceTracker.swift`): ARKit face tracking with no preview, after Peter's `ARSessionController` and `HeadPoseProcessor`; head angles with his `MathSupport.eulerAngles` |
| Frames to rows | `FaceRawRecorder` (`Sense/FaceRawRecorder.swift`) |
| Pleasant moments | `FaceSense.mark()` from the cheers in `FocusGameView` and `BreatheView` |
| Attaching to the record | `FaceSense.attach(to:)` |

Sent as `face_raw` on the `focus` or `breathing` record to `POST /v1/activities`: `rate_hz` 30, `channels` (all 52 ARKit blend shapes with the names the server and the harness use, e.g. `eyeBlinkLeft` from ARKit's `eyeBlink_L`, as in Peter's `BlendShapeCatalog.friendlyName`, then `headPitch`, `headYaw`, `headRoll` in degrees), `samples` (one row per 1/30 s, blend shapes to 3 decimals, angles to 2), `tracked` (left out when every frame was tracked), `moments_ms` (up to 20). At most 9,000 rows (5 minutes, about 3 MB). Only the last `duration_s` + 1 seconds are kept, so the frames never outlast the activity.

Never sent or stored: the camera image, video, the face mesh, landmarks. No face, no tracking, an interruption or a phone without TrueDepth: no `face_raw`, and the game is unchanged.

Sending: a record with frames is 0.4 to 3 MB, so `LanviClient` posts it through a session with a 90 s request timeout (the small calls keep 6 s). A refused record with frames (413, 422) goes once more without them, same id, so the activity itself always arrives (`LanviClient.withoutFaceFallback`). In a debug build the console says what happened: `lanvi-sense: face_raw N frames ...` when frames were attached, `lanvi-net: ...` when a send failed or was retried, and nothing between them means the tracker gave no frames (no yes, camera off in Settings, an interruption, or the face not in view).

## Fine facial movement

Beside `face_raw`, the same tracker now sends `face_fine` (`docs/face-fine.md`): for fourteen named regions (the two mouth corners among them) and every frame, one number, how far the region is from the person's own resting shape, in millimetres.

| What | Where |
|---|---|
| The mesh to numbers | `FaceFineRecorder` (in `Sense/FaceRawRecorder.swift`, so the generated project file needs no change) |
| Feeding it | `FaceTracker`, the same `ARSession` callback that feeds the raw frames: `anchor.geometry.vertices`, read and reduced at once |
| Attaching | `FaceSense.attach(to:)` sets `faceFine` when the game also gave raw frames |
| Off | launch argument `-noFaceFine` |

- This is the one place where the phone computes from the face. The mesh is the shape of a face, so it is never sent and never stored: it lives in memory for the callback, the resting shape (the median of the first 45 tracked frames) lives until the game ends, and both are then forgotten.
- Regions are found by where they lie on the resting face (fractions of its width and height, `FaceFineRecorder.boxes`). **These boxes are a first guess and have not been checked on a device.** A DEBUG build prints how many vertices each region caught (`lanvi-sense: face_fine regions ...`); a region with fewer than 3 is left out, and without both mouth regions nothing is sent.
- A server that does not take `face_fine` yet answers 422. The record then goes again without it, and only then without the raw frames, so nothing else is lost (`LanviClient.smaller`).
- The person is not asked anything new: it runs under the same yes as the face question. Before real use, that question should say that movement is also measured more finely (see the research proposal).

On a device: play a game with the camera allowed and look for `lanvi-sense: face_fine N rows, R regions, noise X mm` in the Xcode console, then `GET /v1/clinic/patients/{id}/activities/{activity_id}/face-fine` on the server.

## Checked here

- 19 unit tests (`ios/LanviTests/FaceRawTests.swift`, `HealthTests.swift`): the channel list equals the one in `docs/face-raw.md`, 60 Hz frames become 30 Hz rows, gaps stay in time, limits and trimming, the JSON keys, Peter's output to server days including a night across midnight.
- Local engine: the app sent 10 sample days (`GET /v1/today` went `no_data` → `no_baseline`), then 30 (`within`). A 40-second focus record with `face_raw` encoded by the app's own code was accepted (200, +10 XP) and the server computed the face summary from it (`face_source: raw`).

## Device test list (ARKit face tracking does not run in the simulator)

On an iPhone with Face ID, with a server configured in `ios/Config.xcconfig`:

1. First open after the welcome: the Health screen appears. "Show Lanvi my steps" → the system sheet lists only Steps, Walking Speed, Heart Rate Variability and Sleep. Allow. Home appears without waiting.
2. Clinician page for that patient: the past days are there (steps, walking speed; HRV and sleep only with a watch).
3. Close and reopen the app the next day: only the missing days are sent (server log: one `POST /v1/daily`).
4. Start Sparks and snow: the face question appears once. "Yes, you may" → the camera permission sheet → the game starts; a tiny indicator shows while the camera is on. The game feels exactly as before (no stutter).
5. Play to the end, smiling at a cheer. Clinician page: the session shows face values, `face_source: raw`, frames about 30 per second, tracked share near 1.
6. Look down at the phone for a whole game: `head_pitch_deg` comes out positive. If it is negative, the pitch sign in `FaceTracker` needs flipping.
7. Breathe with Lanvi: the same, without being asked again.
8. Help → switch "Lanvi watches my face in games" off → play: no indicator, no face values for that session.
9. Deny the camera in Settings → play: the game is unchanged, no face values.
10. Cover the camera for a whole game: no face values (nothing tracked); half covered: values with a lower tracked share.
11. Background the app mid-game and come back: the game ends as it does today; no face values for an interrupted session.
12. Airplane mode, play, then reconnect: the record (with its frames) arrives later from the outbox.
