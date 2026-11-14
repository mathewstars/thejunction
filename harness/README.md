# HKGeminiHarness — HealthKit + Gemini integration test harness

A standalone iOS test app plus reusable Swift modules that prove one thing: recordings from the existing FaceMetrics ARKit app (`facemetrics/`) can be imported, aligned in time with Apple Health history, analysed locally, and reviewed by Gemini through a key-holding proxy. Nothing here tracks faces; the ARKit app is untouched.

Written at the Junction hackathon, 14 Nov 2026, on a Windows machine without Xcode. The Python parts (proxy, example data, reference checks) ran here; the Swift parts are reviewed line by line but **compile for the first time on Matthew's Mac**. See `docs/TEST-RESULTS.md` for what was actually executed.

## Layout

```
harness/
  HKGeminiHarness.xcodeproj/        Xcode 16 project, two targets (app + unit tests), folder-synchronised
  HKGeminiHarness/
    App/        HKGeminiHarnessApp (entry, 4 tabs), Info.plist, entitlements (HealthKit read)
    Models/     SharedModels.swift (all Codable models), JSONValue.swift
    HealthKit/  HealthKitManager, HealthTypeCatalog, HealthSummaryBuilder, AppleHealthXMLImporter
    ARKit/      ARKitDatasetImporter (samples.csv, session.json, geometry.bin/json, validation, summary, export)
    Analysis/   FacialFeatureAnalyzer, LocalStatistics, TimestampAlignment, CombinedDatasetBuilder (+BaselineBuilder),
                GeometryFeatureExtractor
    Gemini/     GeminiAnalyzer (proxy client), GeminiPrompts, GeminiSchema, GeminiPayloadBuilder, GeminiResponseValidator
    Support/    AppState, CSVReader (streaming), FileExport, KeychainStore
    UI/         HealthKitScreen, ARKitImportScreen, GeminiExperimentsScreen, CombinedDatasetScreen, ConsentSheet, SettingsSheet
  HKGeminiHarnessTests/              XCTest suite for the pure modules (no HealthKit, no network)
  proxy/                             gemini_proxy.py (stdlib), .env.example, tests, README
  examples/                          synthetic FaceMetrics session, synthetic Apple Health export, generators,
                                     reference checker, example Gemini request and replies (one live)
  docs/                              INTEGRATION.md, TEST-RESULTS.md, LIMITATIONS.md
```

## Build and run (Mac)

1. Open `harness/HKGeminiHarness.xcodeproj` in Xcode 16+. Set your Team on both targets (automatic signing). The app target has the HealthKit capability in its entitlements; the bundle id is `com.thejunction.hkgeminiharness`, change it if it clashes.
2. Run on an iPhone (HealthKit works in the simulator too, with empty data). iOS 17+.
3. Product ▸ Test runs `HKGeminiHarnessTests` (pure logic; needs no device data).
4. Start the proxy (see `proxy/README.md`), then in the app's Settings (gear icon) enter the proxy URL and token.

Expect first-build fixes: this code was never compiled here. The usual suspects are listed in `docs/LIMITATIONS.md`.

## Walk-through

| Tab | What to do | What you should see |
|---|---|---|
| HealthKit | Request permissions → Discover types → set a range → Fetch | Per type: sample count, latest timestamp, source; "none/denied" where HealthKit returned nothing. Metric detail: daily chart, stats, coverage, sampling, outliers. Export writes JSON/CSV to Files › HKGeminiHarness › HKGeminiExports. Import `export.xml` to test without a watch. |
| ARKit Import | Import `examples/arkit-session-synthetic/samples.csv` (or the folder), attach `session.json`, optionally load geometry | Validation report (frames, fps, gaps, tracking, lighting), time alignment (method, offset, residual), features per 5/15/30/60 s window with a chart, raw columns and first frames |
| Gemini | Test connection → A → B → C | A consent sheet before every send listing categories, time range, size, destination, with the exact payload inspectable. Then status, latency, tokens, validator verdict, parsed observations, raw request/response JSON. |
| Combined | Pick range and sessions → Align & join | Daily rows (health + previous day + facial), bins, correlations with paired-day counts, personal baseline, scatter chart, export dataset + report |

## Design rules the code follows

- **Raw stays raw.** Every CSV cell is kept (`ARKitFrame.values` in header order), unknown columns included. Derived numbers live in separate structs (`FacialFeatureWindow`, `HealthMetricSummary.daily`, …) and the recorder's own derived columns are reported apart from this module's calculations.
- **Nothing is invented.** Empty HealthKit types are listed as empty, never as zero. Untracked frames have no coefficients. Correlations with fewer than 7 paired days carry no coefficient.
- **Uptime ≠ Unix time.** `timestamp_s` is `ARFrame.timestamp` (seconds since boot). `TimestampAligner` anchors it with `session.json` (`createdAt` + `recordingStartTimestamp`), cross-checks against the CSV's `wall_clock_unix_s`, and reports the residual. Without an anchor the session is `unaligned` and left out of the join.
- **Gemini reads statistics.** `LocalStatistics` computes mean/median/SD/IQR/MAD/percentiles, rolling means, daily and weekly aggregates, longitudinal change, robust outliers, Spearman/Pearson, sampling frequency and coverage on device. The prompt forbids new numbers; `GeminiResponseValidator` rejects replies whose numbers are not in the payload.
- **No emotions, no diagnoses.** Feature names describe movement. The prompt forbids inferring mood or disorders; the validator flags such vocabulary.
- **Consent before every send.** `ConsentSheet` shows categories, range, payload size, proxy and model, and lists what never leaves the phone (video, mesh, raw rows, identifiers, API key).

## Gemini model

Default `gemini-4-carbon`, verified on 14 Nov 2026 against Google's model list (GA, paid tier; `generateContent` supported; thinking level low/medium/high; sampling parameters ignored). It is configurable in the app's Settings and pinned/allow-listed on the proxy (`GEMINI_MODEL`, `GEMINI_ALLOWED_MODELS`). A live connection test and one live Experiment C run were made from this repository; see `docs/TEST-RESULTS.md`.

## For Matthew

`docs/INTEGRATION.md` is the hand-over: which files to copy, their public functions, the data flow, and the wire format of the proxy.
