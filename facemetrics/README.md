# FaceMetrics

ARKit facial-behaviour research instrument for iPhone. It reads everything the TrueDepth camera and ARKit expose about a face, shows it live as an instrument dashboard, derives temporal measurements, and records sessions to CSV and JSON for analysis elsewhere.

It is a data-acquisition tool. It does not classify emotions, detect depression or give any wellbeing score. Every derived number is labelled as application-derived and its formula is documented in the export.

## Requirements

- iPhone with Face ID (TrueDepth camera). ARKit face tracking does not run in the simulator.
- iOS 17 or later.
- Xcode 16 or later on a Mac (the project uses Xcode 16 folder-synchronised groups).

## Build and run

1. Open `facemetrics/FaceMetrics.xcodeproj` in Xcode.
2. Select the FaceMetrics target, set your Team under Signing & Capabilities (automatic signing).
3. Plug in the iPhone, pick it as the run destination, press Run.
4. Allow camera access on first launch. Tracking starts as soon as the app is on screen.

This project was written on a machine without Xcode. It has been reviewed line by line but has not yet been compiled; the first build on a Mac may surface small fixes. Please report them in the repo.

## What the app shows

| Section | Contents |
|---|---|
| Overview | Live camera preview with optional mesh and eye-ray overlay, session state, face/camera tracking state, FPS, frame counts, interruptions, dropped-frame estimate, facial activity, head attitude, gaze angles |
| Blend shapes | Every key in `ARFaceAnchor.blendShapes` (52 on current SDKs, enumerated at runtime, nothing hardcoded), searchable, sortable, filterable by Eyes / Eyebrows / Mouth / Cheeks / Nose / Other, each with value, level bar, sparkline, min, max, mean, per-frame delta, velocity, acceleration, window statistics and activation count |
| Geometry | Real-time `ARFaceGeometry` mesh in wireframe, solid, vertex-point and displacement-heat-map modes, rotatable and zoomable, following the head or stabilised, plus vertex/triangle counts, update count, per-frame vertex displacement, bounding box and the raw 4x4 anchor transform |
| Eyes | Gaze target plot relative to the camera, per-eye direction dials, eye positions, left/right divergence, gaze speed and variability, blink detector with event list and statistics, all eye coefficients |
| Movement | Pitch/yaw/roll traces, angular speed, head amplitude, frequency, variability, stability, baseline-relative pose, facial activity and variability traces, left/right asymmetry per group and per pair |
| Analytics | Totals for the run, average FPS, data completeness, tracking-quality score with its formula, tracked/untracked timeline, frame-interval trace, per-coefficient statistics table, event counts, ARSession lifecycle log |
| Record | Sample rate (5 to 60 per second, default 30), JSON stream toggle, opt-in face geometry recording, participant label and notes, start / pause / resume / stop, list of recorded sessions with share sheet and delete |
| Experiment | Preset action markers (neutral face, smile, blink, raise eyebrows, open mouth, look left/right/up/down, speak, relax) plus custom labels, as instant markers or held intervals, with frame-accurate timestamps |

The settings sheet (slider icon in the status strip) selects the camera video format from `ARFaceTrackingConfiguration.supportedVideoFormats`, toggles light estimation, and sets the analysis window, activation thresholds and blink thresholds.

## Architecture

```
FaceMetrics/
  App/            FaceMetricsApp, RootView (status strip, section tabs, transport bar), Info.plist
  Tracking/       ARSessionController   ARSession lifecycle, delegate on a dedicated serial queue
                  FaceTrackingManager   per-frame orchestration, FaceSample assembly, throttled UI snapshots
                  BlendShapeCollector   enumerates blendShapes, per-coefficient running statistics and history
                  HeadPoseProcessor     world and camera-view pose, Euler angles, velocities, windowed movement metrics
                  EyeTrackingProcessor  eye transforms, lookAtPoint, derived gaze vectors, gaze metrics
                  FaceGeometryProcessor mesh copy behind a lock for rendering and opt-in recording
                  FaceSample, TrackingSnapshot, BlendShapeCatalog
  Analysis/       TemporalFeatureEngine derivatives, hysteresis activation events, windowed statistics, low-activity periods
                  BlinkDetectionEngine  hysteresis blink events, durations, intervals, clustering, asymmetry
                  AsymmetryAnalyzer     every _L/_R pair plus jaw/mouth direction pairs, grouped
                  TrackingQualityMonitor frame intervals, dropped-frame estimate, interruptions, app-derived score
  Recording/      SessionRecorder       buffered writing on a utility queue, rate limiting, pause intervals, manifest
                  CSVExporter           column schema with unit and origin for every column
                  JSONExporter          streaming per-sample objects, SessionManifest
                  SessionStore          list, share, delete sessions in Documents/FaceMetricsSessions
                  ExperimentMarkerManager
  Dashboard/      DashboardViewModel, Theme, reusable instrument components, one view per section
  Support/        MathSupport (Euler decomposition, vector helpers), RingBuffer, RunningStatistics, TimeAlignedHistory
```

Threading: ARKit delivers frames on `ARSessionController.delegateQueue`. All collectors and engines run there and never touch SwiftUI. The manager publishes a value-type `TrackingSnapshot` to the main thread at a configurable rate (15 Hz by default) independent of the camera rate. The recorder gets every `FaceSample` and does its own rate gating and file writing on a separate utility queue. No `ARFrame` is retained beyond the delegate callback, so ARKit never stalls.

## Export format

Each session is a folder `Documents/FaceMetricsSessions/<yyyyMMdd-HHmmss-xxxxxx>/`, visible in the Files app and shareable from the Record section.

| File | Contents |
|---|---|
| `samples.csv` | One row per kept frame. Fixed columns, then every blend shape as `bs_<arkitIdentifier>`, then derived metrics, then environment and camera data. Empty cell = measurement unavailable on that frame. Never zero-filled. |
| `samples.json` | Same data as a JSON array of nested objects, `null` for unavailable values. Optional. |
| `session.json` | Manifest: device, app version, camera format, configuration, sample counts, pauses, the full column dictionary (name, unit, origin `arkit` or `derived`, description), per-coefficient statistics, markers with recording-relative times, blink events, low-activity periods, ARSession lifecycle events, summary, notes on limitations. |
| `geometry.bin` + `geometry.json` | Only when geometry recording was opted in. Binary records of all vertex positions per sample; `geometry.json` documents the layout and holds the triangle indices once. |

Coordinate conventions are documented per column in `session.json`. In short: `head_world_*` is the ARKit world transform (gravity-aligned origin at session start); `head_view_*` is relative to the portrait camera view (+X right, +Y up, camera looks down -Z); eye transforms and `look_at` are in face-anchor space (+Z out of the face). Pitch is rotation about X, yaw about Y, roll about Z.

## What ARKit provides and what is derived

Raw from ARKit: blend-shape coefficients (0 to 1), face anchor transform, `isTracked`, 1220-vertex mesh with fixed topology, left and right eye transforms, `lookAtPoint`, camera tracking state and limited reason, camera intrinsics, image resolution, exposure duration and offset, EXIF values, light estimate (ambient intensity, colour temperature, primary light direction and intensity), presence of depth data, session interruptions and errors, frame timestamps.

Derived by the app (all labelled `derived` in the export): Euler angles, angular velocity and acceleration, linear velocity, baseline-relative pose, per-eye forward vectors (+Z axis of each eye transform), combined gaze direction (eye midpoint toward `lookAtPoint`), gaze yaw/pitch, left/right divergence, gaze crossing point on the camera plane, first and second derivatives of coefficients, activation events with hysteresis, window min/max/mean/std, facial activity (mean |d/dt|), total variation, amplitude, zero-crossing movement frequency, transition rate, low-activity periods, blink events and their statistics, asymmetry per pair and group, head movement amplitude/frequency/variability/stability, dropped-frame estimate, tracking-quality score.

Not available from ARKit, so not claimed: pupil position or size, screen-calibrated gaze, per-vertex or per-coefficient confidence, any tracking-confidence score (the app's quality score is its own formula: `0.5 * trackedFraction + 0.3 * (1 - droppedFraction) + 0.2 * cameraStateWeight` over the last 2 s).

Eye-tracking caveat: ARKit estimates eye orientation from the face model. It is good enough to see left/right/up/down and vergence changes; it is not accurate enough to say which screen element someone looks at. The camera-plane crossing point typically has several centimetres of error.

## Privacy

- All processing is on-device. Nothing is uploaded.
- Camera frames are never stored. The preview is render-only.
- Recording is visible in the status strip and on the preview.
- Face geometry (identifiable) is written only when switched on for a session, and the toggle warns about it.
- Sessions can be deleted one by one or all at once in the Record section.
- The participant label is free text; do not enter names.

## Known limits of this version

- One face only (`maximumNumberOfTrackedFaces = 1`).
- Portrait orientation only; view-space angles assume the phone is held upright.
- The blend-shape column set is fixed at the first tracked sample of a recording. If a later frame reported a coefficient that was not in that set, it is counted in `session.json` under `unknownBlendShapeKeysSeen` and present in `samples.json`, but not in the CSV.
- Long recordings write continuously; a 30-minute session at 30 samples per second is roughly 60 MB of CSV and 120 MB of JSON. Turn the JSON stream off for long runs.
