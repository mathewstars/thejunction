"""Reference conversion of a FaceMetrics session into the engine's `face_raw` (same algorithm as
HKGeminiHarness/Engine/EngineAdapters.swift: name mapping, camera-relative head angles in degrees,
nearest-frame resampling onto a steady grid, untracked gaps as tracked=0) and a check against the
engine's own code: `face_features.check_raw` must accept it and `face_features.summarize` computes
the server-side face summary. No server needed; the engine modules are pure Python.

    python3 make_face_raw_from_session.py arkit-session-synthetic --rate 30 --kind breathing
"""

from __future__ import annotations

import argparse
import bisect
import csv
import json
import math
import os
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE_MIND = os.path.join(HERE, "..", "..", "engine", "clinic_engine", "mind")


def load_engine_face_features():
    """Loads thresholds.py and face_features.py from the engine without importing the package
    (which would pull in FastAPI). face_features does `from .thresholds import T, Thresholds`."""
    import types
    th = types.ModuleType("thresholds")
    sys.modules["thresholds"] = th  # dataclasses look the module up by name while the class is built
    with open(os.path.join(ENGINE_MIND, "thresholds.py"), encoding="utf-8") as fh:
        exec(compile(fh.read(), "thresholds.py", "exec"), th.__dict__)
    ff = types.ModuleType("face_features")
    sys.modules["face_features"] = ff
    with open(os.path.join(ENGINE_MIND, "face_features.py"), encoding="utf-8") as fh:
        src = fh.read().replace("from .thresholds import", "from thresholds import")
    exec(compile(src, "face_features.py", "exec"), ff.__dict__)
    return ff


def engine_name(arkit_id: str) -> str:
    if arkit_id.endswith("_L"):
        return arkit_id[:-2] + "Left"
    if arkit_id.endswith("_R"):
        return arkit_id[:-2] + "Right"
    return arkit_id


def build_face_raw(folder: str, rate: float, moments_from_markers: bool) -> tuple[dict, dict]:
    with open(os.path.join(folder, "samples.csv"), newline="", encoding="utf-8") as fh:
        reader = csv.reader(fh)
        header = next(reader)
        rows = list(reader)
    idx = {n: i for i, n in enumerate(header)}
    bs = [(engine_name(h[3:]), idx[h]) for h in header if h.startswith("bs_")]
    ff = load_engine_face_features()
    allowed = set(ff.BLEND_SHAPES)
    dropped = [n for n, _ in bs if n not in allowed]
    bs = [(n, i) for n, i in bs if n in allowed]
    channels = [n for n, _ in bs] + ["headPitch", "headYaw", "headRoll"]
    use_view = all(k in idx for k in ("head_view_pitch_rad", "head_view_yaw_rad", "head_view_roll_rad"))
    head_cols = [idx["head_view_pitch_rad"], idx["head_view_yaw_rad"], idx["head_view_roll_rad"]] if use_view else None

    ts = [float(r[idx["timestamp_s"]]) for r in rows]
    tracked_flag = [r[idx["face_tracked"]] == "1" for r in rows]
    span = ts[-1] - ts[0]
    n = int(round(span * rate)) + 1
    warnings = []
    if n > 12000:
        rate = max(5.0, math.floor((12000 - 1) / span * 10) / 10)
        n = int(round(span * rate)) + 1
        warnings.append(f"rate lowered to {rate} Hz to fit 12000 samples")
    if n > 12000:
        n = 12000
        warnings.append("truncated to 12000 samples")
    tol = 0.75 / rate
    samples, tracked = [], []
    for k in range(n):
        t = ts[0] + k / rate
        j = bisect.bisect_left(ts, t)
        cands = [c for c in (j - 1, j) if 0 <= c < len(ts)]
        c = min(cands, key=lambda c: abs(ts[c] - t))
        r = rows[c]
        ok = abs(ts[c] - t) <= tol and tracked_flag[c] and all(r[i] != "" for _, i in bs)
        if not ok:
            samples.append([0.0] * len(channels))
            tracked.append(0)
            continue
        row = [round(min(1.0, max(0.0, float(r[i]))), 3) for _, i in bs]
        if head_cols and all(r[i] != "" for i in head_cols):
            angles = [float(r[i]) for i in head_cols]
        else:
            m = [float(r[idx[f"head_world_m{a}{b}"]]) for a in range(4) for b in range(4)]
            yaw = math.atan2(-m[8], math.hypot(m[9], m[10]))
            pitch = math.atan2(m[9], m[10])
            roll = math.atan2(m[4], m[0])
            angles = [pitch, yaw, roll]
        row += [round(math.degrees(a), 2) for a in angles]
        samples.append(row)
        tracked.append(1)
    raw = {"rate_hz": rate, "channels": channels, "samples": samples}
    if any(t == 0 for t in tracked):
        raw["tracked"] = tracked
    with open(os.path.join(folder, "session.json"), encoding="utf-8") as fh:
        manifest = json.load(fh)
    if moments_from_markers:
        ms = sorted(int(round((m["startTimestamp"] - ts[0]) * 1000)) for m in manifest.get("markers", []))
        raw["moments_ms"] = [m for m in ms if 0 <= m <= span * 1000][:20]
    report = {"channels": len(channels), "blend_shapes": len(bs), "dropped": dropped, "samples": n, "rate_hz": rate,
              "tracked_fraction": round(sum(tracked) / n, 4), "span_s": round(span, 3),
              "head_angle_source": "head_view_*_rad" if use_view else "head_world transform", "warnings": warnings}
    return raw, {"manifest": manifest, "report": report, "ff": ff, "span": span, "start_uptime": ts[0]}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("folder", nargs="?", default=os.path.join(HERE, "arkit-session-synthetic"))
    ap.add_argument("--rate", type=float, default=30)
    ap.add_argument("--kind", choices=["breathing", "focus"], default="breathing")
    ap.add_argument("--moments", action="store_true", help="marker starts as moments_ms")
    a = ap.parse_args()

    raw, ctx = build_face_raw(a.folder, a.rate, a.moments)
    ff, manifest, report = ctx["ff"], ctx["manifest"], ctx["report"]
    print("face_raw:", json.dumps(report))

    problem = ff.check_raw(raw)
    print("engine check_raw:", problem or "accepted")
    summary = ff.summarize(raw)
    describe = ff.describe(raw)
    print("engine face summary:", json.dumps(summary, indent=1))
    print("engine describe:", json.dumps(describe))

    created = datetime.strptime(manifest["createdAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    offset = created.timestamp() - manifest["recordingStartTimestamp"]
    started = datetime.fromtimestamp(ctx["start_uptime"] + offset, tz=timezone.utc)
    dur = round(min(1800.0, ctx["span"]), 1)
    paused = sum(p["endTimestamp"] - p["startTimestamp"] for p in manifest.get("pauses", []))
    activity = {"id": ("fm-" + manifest["id"])[:64], "type": a.kind, "started_at": started.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "duration_s": dur, "completed": True, "ended_by": "finished"}
    if a.kind == "breathing":
        activity["time_played_s"] = round(min(dur, ctx["span"] - paused), 1)
    else:
        activity.update(correct_taps=0, wrong_taps=0, misses=0, reaction_ms=[])
    activity["face_raw"] = raw
    body = json.dumps(activity, separators=(",", ":"))
    frames_ok = len(raw["samples"]) / raw["rate_hz"] <= dur * 1.2 + 5
    print(f"activity body: {len(body)} bytes; frames-vs-duration rule ok: {frames_ok}; id ok: {bool(__import__('re').match(r'^[A-Za-z0-9_-]{8,64}$', activity['id']))}")

    os.makedirs(os.path.join(HERE, "engine-requests"), exist_ok=True)
    os.makedirs(os.path.join(HERE, "engine-responses"), exist_ok=True)
    with open(os.path.join(HERE, "engine-requests", f"activity_{a.kind}_face_raw.json"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(body + "\n")
    with open(os.path.join(HERE, "engine-responses", "face_summary_computed_by_engine_code.json"), "w", encoding="utf-8", newline="\n") as fh:
        json.dump({"_about": "Output of engine/clinic_engine/mind/face_features.summarize() run locally on engine-requests/activity_*_face_raw.json. "
                             "This is what the server stores as the activity's `face` (face_source: raw).",
                   "build_report": report, "describe": describe, "face_summary": summary}, fh, indent=2)
    return 0 if problem is None and frames_ok else 1


if __name__ == "__main__":
    sys.exit(main())
