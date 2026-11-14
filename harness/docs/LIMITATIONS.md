# Known limitations

## Not yet done here

- **The Swift code has not been compiled.** This machine has no Xcode or Swift toolchain. All ~5,000 lines were written and reviewed without a compiler; expect a round of small fixes on the first Mac build (typical: a missing `import`, an optional that needs unwrapping, a SwiftUI builder that needs a `Group`, a HealthKit identifier whose availability annotation differs). The XCTest suite in `HKGeminiHarnessTests` exists for exactly this and should be run first.
- **No HealthKit data was read.** HealthKit needs a real iPhone (or a simulator with data entered by hand). The HealthKit path was tested only through the Apple Health XML importer with a synthetic export and the shared `HealthSummaryBuilder`.
- **No real FaceMetrics recording was imported.** The FaceMetrics app itself has not been compiled on a Mac yet, so no genuine `samples.csv` exists. The example session is synthetic, generated with the exact column list transcribed from `CSVExporter.swift`. If the first real export differs (an extra column, a renamed one), the importer keeps unknown columns and reports them; only the typed accessors would need a tweak.
- **Gemini was called twice**, both through the proxy with the real key: one connection test and one Experiment C on the illustrative request. The iOS app has not yet talked to the proxy from a device.

## Design limits

- **Alignment precision.** `createdAt` is written when recording starts and `recordingStartTimestamp` is the first kept sample; they can differ by a few frames. The per-row `wall_clock_unix_s` is used only as a cross-check (the brief asked for the manifest to define the relationship). A device whose clock jumped during a recording produces a warning, not a correction.
- **Euler convention.** Head angles are decomposed as intrinsic Z-Y-X from the raw world transform. FaceMetrics' own `head_world_*_rad` columns may use another order; both are kept, and amplitude/variability features are insensitive to the convention for the small angles seen in front-camera recordings.
- **Blink detector thresholds** (onset 0.5, offset 0.3, 0.03–0.5 s) are the same defaults as FaceMetrics but the implementation is independent; counts can differ by a blink or two from the recorder's `blinkEvents`.
- **Sleep from two sources** takes the longer source per night; this avoids double counting but can hide disagreement between devices. Per-source totals are not exported yet.
- **XML cumulative metrics** (steps etc.) use the largest-single-source rule because the XML has no statistics engine; HealthKit-origin data uses HealthKit's merge.
- **Daily facial values** are means of 60 s windows of that day's recordings. Recordings are short and sparse compared with health data; most correlations will have too few paired days and are reported with their count and no coefficient.
- **Correlations are descriptive.** Spearman/Pearson on daily values, lag 0 and 1 day, minimum 7 paired days, no significance test and no multiple-comparison correction. The prompt and the schema force Gemini to treat them as hypotheses.
- **Memory.** `ARKitFrame.values` keeps every cell. 30 minutes at 30 fps is about 100 MB in memory on the phone. Fine for a test harness; the main app should stream.
- **XML import holds all samples in memory** after streaming them from disk. A multi-year export with millions of records will need the `range` filter or a type filter.
- **Geometry** features are crude (inter-record displacement, bounding box, a left/right centroid difference). They exist to show the pipeline, not to measure anything.
- **Validator number matching** accepts a number if any payload number matches within 0.5 % or after rounding to the reply's precision, or ×/÷ 100. A reply can still cite a correct number for the wrong metric; the validator does not check attribution.
- **Interactions API path** in the proxy follows the public Gemini 4 guide but was not exercised live; `generate_content` is the tested default.
- **No background fetching, no persistence** of imported data between launches (settings and the proxy token persist).

## Things to decide with Matthew

- Whether the main app should keep raw CSV rows after feature extraction or only `FacialFeatureWindow`s.
- Marker protocol: comparing days only works if each day's recording follows the same script (the synthetic example uses Neutral face / Smile / Look left / Look right).
- Where the proxy runs for the demo (next to the engine behind the existing HTTPS vhost is the natural place) and who holds the token.
