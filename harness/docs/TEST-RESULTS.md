# Test results

Date: 14 Nov 2026, Windows 11 workstation, Python 3.10.5. No Xcode or Swift toolchain on this machine, so the Swift targets were not compiled here (see "Not run"). Everything below was executed.

## 1. Proxy unit tests (`harness/proxy/tests`)

```
python3 -m unittest discover -s harness/proxy/tests -v
Ran 16 tests in 0.566s
OK
```

Covered: health endpoint without secrets; 401 on missing/wrong token; `generateContent` body shape (system instruction, payload embedding, `responseMimeType`, `responseJsonSchema`, `thinkingConfig.thinkingLevel`, no `temperature`); usage parsing incl. thought tokens; `/v1/test` without payload; model allow-list; thinking-level check; identifier guard (phone, email, identifying keys) and its non-firing on ISO dates and FaceMetrics session ids; 413 on oversize body; 400 on bad JSON; 502 pass-through of upstream 429 with message; empty candidates (SAFETY) as error with usage kept; 404; Interactions builder/parser; host allow-list; settings check.

## 2. Example datasets and reference checks (`harness/examples`)

Generated with `make_example_arkit_session.py` (45 s, 30 fps, seed 7) and `make_example_health_export.py` (30 days, seed 11), then `check_examples.py`:

| Check | Result |
|---|---|
| CSV header | 217 columns, 52 `bs_*` blend shapes discovered from the header, every row has 217 cells |
| Columns present | `timestamp_s`, `face_tracked`, `head_world_m00…m33`, `look_at_x`, `wall_clock_unix_s`, `mesh_vertex_count` |
| Alignment | manifest offset 1 794 562 578.500 s (uptime 73 421.5 → 2026-11-14T06:00:00Z); CSV `wall_clock_unix_s` residual median −0.00002 s, max 0.00002 s |
| Frames / duration / rate | 1348 rows, 44.967 s, 29.96 fps effective vs 30 target, median interval 33.3 ms, 2 missing frames (deliberate drop burst), 0 gaps > 1 s |
| Tracking | tracked fraction 0.9666 = manifest; untracked frames have empty (not zero) blend shapes; no empty blend-shape cells on tracked frames |
| Blinks | reference hysteresis detector 16 = recorder's `blinkEvents` 16; 21.3/min; mean duration 113 ms |
| Head | yaw range 21.5° (includes Look left / Look right), std 3.75° |
| Markers | CSV `active_marker` labels = manifest markers; `mouthSmile_L` mean 0.573 inside "Smile" vs 0.025 outside |
| Geometry | `geometry.bin` parses: 5 records × 1220 vertices, 2262 triangles from `geometry.json` |
| Health XML | 5736 records, 19 types, 2026-10-15…2026-11-14; 30 nights, median asleep 7.54 h (largest source per night); steps median 12 225/day by largest source vs 23 935 if both sources were summed; HRV 95 readings, 3.2/day, median 43.9 ms |

All 22 checks passed (exit 0). An earlier generator version scaled blinks down inside the "Neutral face" marker, which made 4 blinks undetectable; fixed before the final run.

## 3. Live Gemini calls through the proxy

Key supplied by Peter on 14 Nov, stored only in `harness/proxy/.env` (git-ignored). Proxy ran locally on 127.0.0.1:8787 with bearer auth on, `GEMINI_API_STYLE=generate_content`, thinking level medium.

### Connection test (`POST /v1/test`)

```
HTTP 200  status=success  model=gemini-4-carbon  upstream=200  latency_ms=13125
usage: prompt 147, thought 552, output 21, total 720   finish=STOP
```

Confirms: the model id `gemini-4-carbon` is accepted by `v1beta/models/{model}:generateContent`, the key works, `responseMimeType: application/json` is honoured, `thinkingConfig.thinkingLevel` is accepted, thought tokens are reported in `usageMetadata.thoughtsTokenCount`.

### Experiment C, combined (`POST /v1/analyze`, `examples/gemini-requests/experiment_c_combined_request.json`)

First attempt was refused by the proxy's own identifier guard (HTTP 400): the payload key `notes` and FaceMetrics session ids like `20261114-060000-synth01` were taken for an identifying key and phone numbers. Fixed: the Swift payload builder now writes `processing_notes`, and the phone pattern needs real phone grouping and ignores ISO dates. Proxy tests extended accordingly. Second attempt:

```
payload 13 768 bytes
HTTP 200  status=success  model=gemini-4-carbon  upstream=200  latency_ms=159078
usage: prompt 6 938, thought 6 665, output 8 131, total 21 734   finish=STOP
validation: valid=True  observations=14  numbers_checked=778  schema_errors=0  unsupported_numbers=0  forbidden_terms=1 (warning)
```

Saved as `examples/gemini-responses/combined_live_20261114-085203.json` (proxy reply + parsed analysis + validation; no key or token).

What the reply did:

- Followed the section-9 schema exactly; `experiment_type` = `combined`; every observation carried `supporting_measurements`, `time_range`, `kind`, `data_quality`, `limitations`.
- Every one of the 778 numbers in the reply exists in the request payload (the validator's main rule).
- Restated the HRV statistics and reference range, the five daily rows, the correlation entries with their paired-day counts, and said plainly that self-reported wellbeing is absent and that longitudinal change cannot be judged for facial features.
- Named confounders: tracking quality on 2026-11-11 (0.91), limited camera frames on 2026-11-14 (0.044), prompted markers, small paired-day counts, multi-source aggregation.
- The one flagged term was a disclaimer: "…represent task-directed physical motion rather than spontaneous facial behavior or any emotional state." The validator logs this as a warning, not a rejection; its allow-list of disclaimer phrasings could learn "rather than".
- One thing to watch: the model labelled the correlation restatements as `direct_observation` (they do restate payload numbers) rather than `hypothesis`. The prompt asks for interpretations to be hypotheses; a stricter rule would be to require `hypothesis` for anything in `cross_modal_patterns`. Easy to add in `GeminiResponseValidator` if wanted.

Cost of the two calls at introductory Carbon pricing: about $0.16 (≈ 7 k input tokens at $2/M, ≈ 15 k thought+output tokens at $10/M).

## 4. Not run

- `HKGeminiHarnessTests` (XCTest, 17 tests covering CSV import, validation numbers, alignment with and without manifest and with clock disagreement, unaligned fallback, blink/head/asymmetry features, Euler decomposition, statistics, sampling-frequency sparsity, sleep attribution and largest-source rule, cumulative daily statistics preference, Apple Health XML parsing, validator accept/reject cases, combined dataset rows and correlations, payload identifier stripping). Needs a Mac: Product ▸ Test.
- The iOS app itself: build, HealthKit permission flow on a device, file import via the document picker, the four screens, the consent sheet, the in-app Gemini calls.
- Import of a real FaceMetrics export (none exists yet; FaceMetrics has not been compiled either).

## 5. How to reproduce

```sh
# proxy tests
python3 -m unittest discover -s harness/proxy/tests -v
# example data and reference checks
cd harness/examples
python3 make_example_arkit_session.py && python3 make_example_health_export.py
python3 check_examples.py arkit-session-synthetic apple-health-export-synthetic.xml
# live calls (needs harness/proxy/.env with GEMINI_API_KEY and PROXY_TOKEN; proxy running)
set -a; . ../proxy/.env; set +a
python3 run_live_example.py --experiment connection_test
python3 run_live_example.py --experiment combined
```
