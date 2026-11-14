# Integration guide

How to take the harness modules into the main Lanvi app. Each module is one or two Swift files with no dependency on the harness UI. Copy `Models/` first; everything else depends on it.

## 1. Files to copy

| Module | Files | Depends on | Frameworks |
|---|---|---|---|
| Models | `Models/SharedModels.swift`, `Models/JSONValue.swift` | – | Foundation |
| Statistics | `Analysis/LocalStatistics.swift` | Models | Foundation |
| HealthKit | `HealthKit/HealthKitManager.swift`, `HealthTypeCatalog.swift`, `HealthSummaryBuilder.swift`, `AppleHealthXMLImporter.swift`, `Support/FileExport.swift` | Models, Statistics | HealthKit (manager only; the others are Foundation) |
| ARKit import | `ARKit/ARKitDatasetImporter.swift`, `Support/CSVReader.swift`, `Analysis/TimestampAlignment.swift`, `Analysis/FacialFeatureAnalyzer.swift`, `Analysis/GeometryFeatureExtractor.swift` | Models, Statistics | Foundation |
| Combined | `Analysis/CombinedDatasetBuilder.swift` | Models, Statistics, HealthTypeCatalog | Foundation |
| Gemini | `Gemini/GeminiAnalyzer.swift`, `GeminiPrompts.swift`, `GeminiSchema.swift`, `GeminiPayloadBuilder.swift`, `GeminiResponseValidator.swift`, `Support/KeychainStore.swift` | Models | Foundation, Security |

The app target needs the HealthKit capability (`com.apple.developer.healthkit` entitlement) and `NSHealthShareUsageDescription` in Info.plist. `HealthKitManager` is wrapped in `#if canImport(HealthKit)` so the file also compiles in a macOS test target.

## 2. Data flow

```
HealthKit ──HealthKitManager.fetchAllAvailableHistoricalData──▶ [HealthSample] + daily statistics
export.xml ──AppleHealthXMLImporter──────────────────────────▶ [HealthSample]
                      │  HealthSummaryBuilder / generateHealthDataSummary
                      ▼
               HealthDataSummary (per metric: stats, daily, weekly, coverage, sampling, outliers, change)

samples.csv ──ARKitDatasetImporter.importARKitCSV───▶ ARKitSession (frames, columns, blend shapes)
session.json ─importSessionJSON + attach────────────▶   + manifest, TimestampAlignment, ARKitValidationReport
geometry.bin ─importGeometryFile + attach (opt-in)──▶   + ARKitGeometrySummary (vertices stay in ARKitGeometryData)
                      │  FacialFeatureAnalyzer (5/15/30/60 s windows) via generateARKitSummary
                      ▼
               ARKitSessionSummary (numbers only)

HealthDataSummary + [ARKitSessionSummary] ──CombinedDatasetBuilder.buildCombinedDataset──▶ CombinedDataset
                                            BaselineBuilder.build ─────────────────────▶ BaselineProfile
                      │  GeminiPayloadBuilder (trims, strips identifiers)
                      ▼
               GeminiAnalysisRequest ──consent──▶ GeminiAnalyzer.send ──▶ proxy ──▶ Gemini
                                                        ◀── GeminiAnalysisResponse (+ StructuredAnalysis, ResponseValidationReport)
```

## 3. Public functions

### HealthKitManager (`@MainActor`, read-only)

```swift
let hk = HealthKitManager()
hk.checkHealthKitAvailability()                                   // HealthKitAvailability
try await hk.requestHealthPermissions()                           // PermissionResult (read-only, all catalog types)
await hk.discoverAvailableHealthTypes(recentDays: 30)             // [HealthTypeDiscovery]: latest sample, source, recent count
try await hk.fetchHistoricalSamples(type: d, from: a, to: b)      // [HealthSample], 7-day chunks, oldest first
await hk.fetchAllAvailableHealthData(from: a, to: b)              // see below
try await hk.fetchRecentSamples(type: d, limit: 50)
try await hk.fetchWorkouts(from: a, to: b)
try await hk.fetchDailyStatistics(type: steps, from: a, to: b)    // HealthKit-merged daily sums for cumulative types
hk.generateHealthDataSummary(samples:dailyStatistics:range:unavailableTypes:emptyTypes:)
try hk.exportHealthData(samples:summary:format: .json | .csv)     // URL in Documents/HKGeminiExports
try await hk.importAppleHealthXML(file: url, range: nil)          // (samples, AppleHealthXMLImporter.Result)
```

`fetchAllAvailableHistoricalData` is the one-call version: it returns `HistoricalFetchResult` with samples, daily statistics for cumulative types, `countsByType`, `unavailableTypes` (not on this iOS), `emptyTypes` (readable but no samples: HealthKit does not distinguish "denied" from "empty") and per-type errors.

Types are declared once in `HealthTypeCatalog.all` (identifier, display name, group, unit, daily aggregation). Add a type there and every function picks it up.

Double counting: steps/energy/distance from iPhone + Watch overlap. Daily values come from `HKStatisticsCollectionQuery` (HealthKit merges sources) when available; for XML imports the builder takes the largest single source per day and says so in `notes`. Sleep from two sources takes the source with the most sleep per night and is attributed to the wake-up day.

### ARKitDatasetImporter

```swift
let im = ARKitDatasetImporter()
var s = try im.importARKitCSV(file: csvURL)                        // ARKitSession, header-driven, unknown columns kept
let m = try im.importSessionJSON(file: jsonURL)                    // ARKitSessionManifest (lenient)
im.attach(manifest: m, fileName: "session.json", to: &s)          // refreshes alignment + validation
let g = try im.importGeometryFile(file: binURL)                    // ARKitGeometryData (vertices never enter ARKitSession)
im.attach(geometry: g, fileName: "geometry.bin", to: &s)
im.validateARKitDataset(s)                                        // ARKitValidationReport
im.extractFacialFeatureWindows(s)                                 // [windowSeconds: [FacialFeatureWindow]]
im.generateARKitSummary(s, geometry: g)                           // ARKitSessionSummary for Gemini
try im.exportNormalizedARKitData(s)                               // JSON with wall-clock per frame + raw cells
try im.importSessionFolder(folderURL, includeGeometry: false)     // convenience for a whole FaceMetrics folder
```

Memory: `ARKitFrame.values` keeps every cell as `Double?`. A 30-minute recording at 30 fps (54k rows × 217 columns) is roughly 100 MB in memory. For the main app, consider dropping `values` after feature extraction or streaming windows directly from `CSVReader`.

### Timestamp alignment

```swift
let a = TimestampAligner.align(session: s)   // also stored in s.alignment
a.method                                      // .sessionManifest | .markerWallClock | .csvWallClock | .unaligned
a.uptimeToUnixOffsetSeconds                   // wall = uptime + offset
a.wallClock(forUptime: frame.timestampUptime)
a.crossCheckResidualMedianSeconds             // CSV wall clock vs. chosen anchor; warning above 2 s
```

Priority: `session.json` `createdAt` + `recordingStartTimestamp` → a marker with `wallClock` → the CSV `wall_clock_unix_s` column → unaligned. Pauses from the manifest are subtracted from durations and excluded from gap detection.

### FacialFeatureAnalyzer

`windows(session:windowSeconds:)` tiles the recording on the uptime clock; `sessionLevelWindow(session:)` is the whole recording. Each `FacialFeatureWindow` holds blink (own hysteresis detector), eye openness, head movement (Euler from the raw world transform), facial movement, per-coefficient dynamics, left/right asymmetry, gaze changes, tracking quality, `supportingMeasurements` (column names used) and `exportedDerivedMeans` (the recorder's own derived columns, kept apart). Thresholds are in `FacialFeatureAnalyzer.Configuration`.

### CombinedDatasetBuilder / BaselineBuilder

```swift
let ds = CombinedDatasetBuilder(calendar: cal, aggregationWindowSeconds: 3600, facialWindowSeconds: 60)
    .buildCombinedDataset(healthData: summary, arKitData: summaries, healthSamples: samples, baseline: baseline)
ds.dailyRows      // day → health values, previous-day health values, mean facial features, session ids
ds.bins           // hourly (configurable) bins with health and facial aggregates
ds.correlations   // health × facial, lag 0 and lag 1 day, Spearman + Pearson, paired-day count, note
let baseline = BaselineBuilder(calendar: cal).build(health: summary, arKit: summaries)
```

Keys: health metrics use the HealthKit identifier without its prefix (`HeartRateVariabilitySDNN`, `SleepAnalysis` = asleep hours, `StepCount`); facial keys are in `CombinedDatasetBuilder.facialKeys`.

### GeminiAnalyzer (`@MainActor`)

```swift
let g = GeminiAnalyzer()                      // GeminiConfiguration.load(): proxy URL, model, thinking level
g.proxyToken = "…"                            // Keychain
await g.testConnection()
await g.analyzeHealthKitData(summary, baseline: baseline)
await g.analyzeARKitData(summaries)
await g.analyzeCombinedDataset(ds)
await g.generatePersonalBaseline(baseline)
g.compareAnalysisResults(r1, with: r2)        // AnalysisComparison, local
g.validateResponse(text, request: req)        // (StructuredAnalysis?, ResponseValidationReport)
```

For a consent step, build first and send later: `let req = try g.requestForCombined(ds)` → show `req.dataCategories`, `req.inputDataRange`, `req.payloadBytes`, `req.payload` → `await g.send(req)`. Every `GeminiAnalysisResponse` records model, request/response timestamps, latency, token usage (prompt, thought, output), HTTP and upstream status, raw text, parsed `StructuredAnalysis` and the validator's report. `requests`/`responses` are kept in memory; `exportHistory()` writes them.

## 4. Proxy wire format

See `proxy/README.md`. In short: `POST {base}/v1/analyze` with `Authorization: Bearer <token>` and

```json
{"request_id": "…", "experiment": "combined", "model": "gemini-4-carbon", "thinking_level": "medium",
 "system_instruction": "…", "user_prompt": "…", "payload": {…}, "response_schema": {…}}
```

Reply: `{"request_id", "status": "success", "model", "text", "usage": {"prompt_tokens", "output_tokens", "thought_tokens", "total_tokens"}, "latency_ms", "upstream_status", "finish_reason", "error"}`.

The engine (`engine/clinic_engine/outreach.py`) already has an outbound Gemini path with its own gates. If you prefer one service, port `run_analysis()` from `gemini_proxy.py` into a FastAPI route there; the request/reply shape above is all the app depends on.

## 5. Response format (section 9)

`StructuredAnalysis` mirrors the brief: `experiment_type`, `baseline_summary`, `health_observations`, `facial_behavior_observations`, `cross_modal_patterns`, `longitudinal_changes`, `potential_confounders`, `data_quality`, `uncertainties`, `recommended_tracking`, `plain_language_explanation`. Each observation has `observation`, `supporting_measurements`, `time_range`, `kind` (`direct_observation` | `hypothesis`), `data_quality`, `limitations`. The schema is sent to Gemini as `responseJsonSchema` and enforced again locally; numbers in the reply must exist in the payload (rounding and percent scaling allowed; small integers ≤ 31 are warnings).

## 6. Privacy checklist

- HealthKit and ARKit data stay in memory on the device; exports go to the app's Documents folder only.
- `GeminiPayloadBuilder` never emits participant labels, notes, device names, source bundle ids or raw frames. The proxy scans for emails, phone numbers and identifying keys as a second line and refuses.
- Geometry is loaded only after an explicit warning and only its aggregates (`GeometryDerivedFeatures`) can be sent, in a separate experiment.
- The Gemini API key lives in the proxy's `.env`. The app holds a proxy token in the Keychain.
- The proxy logs ids, status, latency and token counts; payloads only with `LOG_PAYLOADS=1`.
