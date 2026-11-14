"""Reference checks for the example datasets, in Python, so the numbers the Swift code must reproduce are
known before the app is first built on a Mac. Standard library only.

    python3 check_examples.py arkit-session-synthetic apple-health-export-synthetic.xml

Prints a report and exits non-zero if any check fails.
"""

from __future__ import annotations

import csv
import json
import math
import statistics
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from datetime import datetime, timezone

FAILS: list[str] = []


def check(cond: bool, msg: str) -> None:
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def detect_blinks(times, left, right, onset=0.5, offset=0.3, dmin=0.03, dmax=0.5):
    events, open_, start = [], False, 0.0
    for t, l, r in zip(times, left, right):
        m = max(l, r)
        if not open_ and m >= onset:
            open_, start = True, t
        elif open_ and l <= offset and r <= offset:
            open_ = False
            events.append((start, t))
    return [e for e in events if dmin <= e[1] - e[0] <= dmax]


def check_arkit(folder: str) -> dict:
    print(f"ARKit session folder: {folder}")
    with open(f"{folder}/samples.csv", newline="", encoding="utf-8") as fh:
        reader = csv.reader(fh)
        header = next(reader)
        rows = list(reader)
    idx = {n: i for i, n in enumerate(header)}
    bs_cols = [h for h in header if h.startswith("bs_")]
    print(f"  columns={len(header)} rows={len(rows)} blend_shapes={len(bs_cols)}")
    check(len(bs_cols) == 52, "52 blend-shape columns discovered from the header")
    check(all(len(r) == len(header) for r in rows), "every row has the header's cell count")
    for col in ("timestamp_s", "face_tracked", "head_world_m00", "head_world_m33", "look_at_x", "wall_clock_unix_s", "mesh_vertex_count"):
        check(col in idx, f"column present: {col}")

    ts = [float(r[idx["timestamp_s"]]) for r in rows]
    wall = [float(r[idx["wall_clock_unix_s"]]) for r in rows]
    tracked = [r[idx["face_tracked"]] == "1" for r in rows]
    with open(f"{folder}/session.json", encoding="utf-8") as fh:
        manifest = json.load(fh)
    created = datetime.strptime(manifest["createdAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    offset = created - manifest["recordingStartTimestamp"]
    residuals = [w - t - offset for t, w in zip(ts, wall)]
    med_res = statistics.median(residuals)
    print(f"  alignment: manifest offset={offset:.3f}s  csv residual median={med_res:.4f}s max={max(abs(x) for x in residuals):.4f}s")
    check(abs(med_res) < 0.01, "manifest anchor and per-row wall clock agree (< 10 ms)")
    check(manifest["sampleCount"] == len(rows), "manifest sampleCount equals CSV rows")

    pauses = manifest.get("pauses", [])
    paused = sum(p["endTimestamp"] - p["startTimestamp"] for p in pauses)
    duration = ts[-1] - ts[0] - paused
    fps = (len(rows) - 1) / duration
    intervals = []
    gaps = 0
    for a, b in zip(ts, ts[1:]):
        if any(a <= p["endTimestamp"] + 0.05 and b >= p["startTimestamp"] - 0.05 for p in pauses):
            continue
        intervals.append(b - a)
        if b - a > 1.0:
            gaps += 1
    expected = 1 / manifest["configuration"]["targetSampleRate"]
    missing = sum(max(0, round(dt / expected) - 1) for dt in intervals if dt > 1.5 * expected)
    print(f"  duration={duration:.2f}s (paused {paused:.1f}s)  effective_fps={fps:.2f}  median_interval={statistics.median(intervals) * 1000:.1f}ms  missing_frames={missing}  gaps>1s={gaps}")
    check(abs(fps - manifest["configuration"]["targetSampleRate"]) < 0.5, "effective frame rate close to the target")
    check(gaps == 0, "no gaps over 1 s outside pauses")

    tr_frac = sum(tracked) / len(rows)
    print(f"  tracked fraction={tr_frac:.4f} (manifest {manifest['trackedSampleCount'] / manifest['sampleCount']:.4f})")
    check(abs(tr_frac - manifest["trackedSampleCount"] / manifest["sampleCount"]) < 1e-6, "tracked fraction matches manifest")
    empty_bs_on_tracked = sum(1 for r, t in zip(rows, tracked) if t and any(r[idx[c]] == "" for c in bs_cols))
    check(empty_bs_on_tracked == 0, "no empty blend-shape cells on tracked frames")
    empty_bs_on_untracked = sum(1 for r, t in zip(rows, tracked) if not t and all(r[idx[c]] == "" for c in bs_cols))
    check(empty_bs_on_untracked == len(rows) - sum(tracked), "untracked frames have empty (not zero) blend shapes")

    tt = [t for t, k in zip(ts, tracked) if k]
    L = [float(r[idx["bs_eyeBlink_L"]]) for r, k in zip(rows, tracked) if k]
    R = [float(r[idx["bs_eyeBlink_R"]]) for r, k in zip(rows, tracked) if k]
    blinks = detect_blinks(tt, L, R)
    span = tt[-1] - tt[0]
    rate = len(blinks) / span * 60
    print(f"  blinks (reference hysteresis)={len(blinks)}  rate={rate:.1f}/min  mean_dur={statistics.mean(e - s for s, e in blinks) * 1000:.0f}ms  manifest blinkEvents={len(manifest['blinkEvents'])}")
    check(abs(len(blinks) - len(manifest["blinkEvents"])) <= 2, "reference blink count within 2 of the recorder's list")

    yaws = [math.atan2(-float(r[idx["head_world_m20"]]), math.hypot(float(r[idx["head_world_m21"]]), float(r[idx["head_world_m22"]]))) for r, k in zip(rows, tracked) if k]
    print(f"  head yaw range={math.degrees(max(yaws) - min(yaws)):.1f} deg  std={math.degrees(statistics.pstdev(yaws)):.2f} deg")
    check(10 < math.degrees(max(yaws) - min(yaws)) < 40, "head yaw range plausible for the synthetic motion (incl. look left/right)")

    markers = Counter(r[idx["active_marker"]] for r in rows if r[idx["active_marker"]])
    print(f"  markers in CSV: {dict(markers)}")
    check(set(markers) == {m["label"] for m in manifest["markers"]}, "CSV marker labels equal manifest markers")
    smile_in = statistics.mean(float(r[idx["bs_mouthSmile_L"]]) for r, k in zip(rows, tracked) if k and r[idx["active_marker"]] == "Smile")
    smile_out = statistics.mean(float(r[idx["bs_mouthSmile_L"]]) for r, k in zip(rows, tracked) if k and r[idx["active_marker"]] != "Smile")
    print(f"  mouthSmile_L mean inside Smile marker={smile_in:.3f} outside={smile_out:.3f}")
    check(smile_in > smile_out * 3, "smile coefficient clearly higher inside the Smile marker")

    try:
        with open(f"{folder}/geometry.bin", "rb") as fh:
            data = fh.read()
        import struct
        off, recs = 0, 0
        while off < len(data):
            ts_, si, vc = struct.unpack_from("<dii", data, off)
            off += 16 + vc * 12
            recs += 1
        with open(f"{folder}/geometry.json", encoding="utf-8") as fh:
            gj = json.load(fh)
        print(f"  geometry: records={recs} vertex_count={vc} triangles={len(gj['triangle_indices']) // 3}")
        check(recs == gj["record_count"] and vc == 1220, "geometry.bin parses with 1220 vertices per record")
    except FileNotFoundError:
        print("  geometry: none")
    return {"rows": len(rows), "columns": len(header), "duration_s": round(duration, 3), "effective_fps": round(fps, 3), "tracked_fraction": round(tr_frac, 4),
            "blinks": len(blinks), "blink_rate_per_min": round(rate, 2), "offset_s": offset, "residual_median_s": round(med_res, 6),
            "recorded_start_utc": datetime.fromtimestamp(ts[0] + offset, tz=timezone.utc).isoformat()}


def check_health(xml_path: str) -> dict:
    print(f"Apple Health export: {xml_path}")
    counts: Counter = Counter()
    sleep_by_wake_day = defaultdict(lambda: defaultdict(float))
    steps_by_day_source = defaultdict(lambda: defaultdict(int))
    hrv = []
    first, last = None, None
    for _, el in ET.iterparse(xml_path, events=("end",)):
        if el.tag == "Record":
            t = el.get("type")
            counts[t] += 1
            s = datetime.strptime(el.get("startDate"), "%Y-%m-%d %H:%M:%S %z")
            e = datetime.strptime(el.get("endDate"), "%Y-%m-%d %H:%M:%S %z")
            first = s if first is None or s < first else first
            last = e if last is None or e > last else last
            if t == "HKCategoryTypeIdentifierSleepAnalysis" and el.get("value") in ("HKCategoryValueSleepAnalysisAsleepCore", "HKCategoryValueSleepAnalysisAsleepDeep", "HKCategoryValueSleepAnalysisAsleepREM", "HKCategoryValueSleepAnalysisAsleepUnspecified"):
                sleep_by_wake_day[e.date().isoformat()][el.get("sourceName")] += (e - s).total_seconds() / 3600
            if t == "HKQuantityTypeIdentifierStepCount":
                steps_by_day_source[s.date().isoformat()][el.get("sourceName")] += int(el.get("value"))
            if t == "HKQuantityTypeIdentifierHeartRateVariabilitySDNN":
                hrv.append(float(el.get("value")))
            el.clear()
        elif el.tag == "Workout":
            counts["Workout"] += 1
            el.clear()
    total = sum(counts.values())
    print(f"  records={total} types={len(counts)} range={first.date()}..{last.date()}")
    check(counts["HKCategoryTypeIdentifierSleepAnalysis"] > 0 and counts["HKQuantityTypeIdentifierHeartRateVariabilitySDNN"] > 0, "sleep and HRV present")
    nights = {d: max(src.values()) for d, src in sleep_by_wake_day.items()}
    print(f"  sleep nights={len(nights)} median asleep (largest source per night)={statistics.median(nights.values()):.2f} h")
    check(all(4 < h < 11 for h in nights.values()), "every night's asleep hours between 4 and 11")
    steps = {d: max(src.values()) for d, src in steps_by_day_source.items()}
    naive = {d: sum(src.values()) for d, src in steps_by_day_source.items()}
    print(f"  steps days={len(steps)} median/day (largest source)={statistics.median(steps.values()):.0f}  naive double-count={statistics.median(naive.values()):.0f}")
    check(statistics.median(naive.values()) > 1.7 * statistics.median(steps.values()), "overlapping sources would double count steps if summed naively")
    print(f"  HRV n={len(hrv)} median={statistics.median(hrv):.1f} ms  per day={len(hrv) / len(nights):.1f}")
    check(len(hrv) / len(nights) < 6, "HRV is sparse (a few readings per day), not continuous")
    return {"records": total, "types": len(counts), "nights": len(nights), "median_sleep_h": round(statistics.median(nights.values()), 2),
            "median_steps": statistics.median(steps.values()), "hrv_n": len(hrv), "hrv_median_ms": round(statistics.median(hrv), 1),
            "first": first.isoformat(), "last": last.isoformat()}


def main() -> int:
    folder = sys.argv[1] if len(sys.argv) > 1 else "arkit-session-synthetic"
    xml_path = sys.argv[2] if len(sys.argv) > 2 else "apple-health-export-synthetic.xml"
    report = {"arkit": check_arkit(folder), "health": check_health(xml_path), "failures": FAILS}
    print(json.dumps(report, indent=2))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
