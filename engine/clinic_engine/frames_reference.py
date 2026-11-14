"""The reference set for the frame reading: sessions with smiles planted at
known places, so both readers can be scored against something that is neither
of them.

    python -m clinic_engine.frames_reference              # code alone
    python -m clinic_engine.frames_reference --model      # code and the level-2 model
    python -m clinic_engine.frames_reference --model --out reference.json

Each session is a synthetic stream of ARKit-like numbers: a resting level that
differs from session to session, jitter, a slow drift, blinks, a stretch of
looking down, and smiles that rise and fall smoothly. Some smiles are strong
(they pass code's fixed onset) and some are faint (they rise clearly above the
session's resting level but stay under the onset). The planted spans are the
truth.

What it measures:

- code against the truth: the fixed rule of the face summary;
- the model against the truth: what it reported, before any check;
- the model after code's check: its smiles that code found too, plus the faint
  ones whose rise code confirmed in the numbers;
- the model against code: the agreement the clinician page shows.

What it does not measure: anything about real faces. The streams are made by
this file. A number from here says how the two readers handle a known signal,
not how well either reads a person.

With --model the reduced stream of every session goes to level 2 through the
same gates as a real session (frames_pack, the outbound check, the output
gate). The streams are synthetic, so no patient data is involved.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import random
import sys

from .mind import face_features as ff
from .mind import frame_reading as fr
from .mind.gates import INPUT_GATE, OUTPUT_GATE, GateError
from .mind.thresholds import T

SESSIONS = 40
SECONDS = 45
RATE = 30
MATCH_IOU = 0.3  # a reported span is a planted smile at this overlap over the union


def make_session(seed: int) -> tuple[dict, list[dict]]:
    """One synthetic session and its planted smiles:
    [{"start_s", "end_s", "peak", "kind": "strong" | "faint"}]."""
    rng = random.Random(seed)
    n = SECONDS * RATE
    rest = rng.uniform(0.03, 0.10)
    jitter = rng.uniform(0.006, 0.016)
    channels = list(ff.BLEND_SHAPES) + list(ff.HEAD_CHANNELS)
    cols: dict[str, list[float]] = {}
    for c in channels:
        if c in ff.HEAD_CHANNELS:
            base = {"headPitch": 6.0, "headYaw": -2.0, "headRoll": 2.0}[c]
            cols[c] = [base + rng.gauss(0, 0.3) + 2 * math.sin(i / RATE / 7) for i in range(n)]
        else:
            level = rest if c.startswith("mouthSmile") else rng.uniform(0.02, 0.08)
            phase = rng.uniform(0, 6.28)
            cols[c] = [level + 0.012 * math.sin(i / RATE / 9 + phase) + rng.gauss(0, jitter)
                       for i in range(n)]
    # Planted smiles: two to four strong and one to three faint, never touching.
    truth: list[dict] = []
    wanted = ["strong"] * rng.randint(2, 4) + ["faint"] * rng.randint(1, 3)
    rng.shuffle(wanted)
    slot = (SECONDS - 4) / len(wanted)
    for k, kind in enumerate(wanted):
        dur = rng.uniform(1.0, 2.4)
        start = 2 + k * slot + rng.uniform(0, max(0.1, slot - dur - 1.0))
        amp = rng.uniform(0.30, 0.55) if kind == "strong" else \
            rng.uniform(0.10, T.smile_onset - rest - 0.035)
        ramp = rng.uniform(0.25, 0.5)
        skew = rng.uniform(-0.04, 0.04)
        with_cheek = kind == "strong" and rng.random() < 0.5
        a, b = int(start * RATE), int((start + dur) * RATE)
        for i in range(a, min(n, b)):
            t = (i - a) / RATE
            env = min(1.0, t / ramp, (dur - t) / ramp)
            env = 0.5 - 0.5 * math.cos(math.pi * max(0.0, env))
            cols["mouthSmileLeft"][i] += (amp + skew) * env
            cols["mouthSmileRight"][i] += (amp - skew) * env
            if with_cheek:
                cols["cheekSquintLeft"][i] += 0.3 * env
                cols["cheekSquintRight"][i] += 0.3 * env
        # The truth span: where the rise is above a fifth of its height.
        edge = ramp * math.acos(1 - 2 * 0.2) / math.pi
        truth.append({"start_s": round(start + edge, 2), "end_s": round(start + dur - edge, 2),
                      "peak": round(rest + amp, 2), "kind": kind})
    for s in range(3, SECONDS, rng.randint(3, 6)):
        first = int((s + rng.random()) * RATE)
        for i in range(first, first + 4):
            if i < n:
                cols["eyeBlinkLeft"][i] = cols["eyeBlinkRight"][i] = 0.9
    raw = {"rate_hz": RATE, "channels": channels,
           "samples": [[round(min(1.0, max(0.0, cols[c][i])), 3) if c not in ff.HEAD_CHANNELS
                        else round(cols[c][i], 2) for c in channels] for i in range(n)],
           "moments_ms": []}
    return raw, truth


def _iou(a0: float, a1: float, b0: float, b1: float) -> float:
    inter = max(0.0, min(a1, b1) - max(a0, b0))
    return inter / (max(a1, b1) - min(a0, b0)) if inter > 0 else 0.0


def score(spans: list[tuple[float, float]], truth: list[dict]) -> dict:
    """Reported spans against the planted smiles, one to one."""
    used: set[int] = set()
    false = 0
    for a, b in spans:
        best = max(((j, _iou(a, b, t["start_s"], t["end_s"])) for j, t in enumerate(truth)
                    if j not in used), key=lambda x: x[1], default=(None, 0.0))
        if best[0] is not None and best[1] >= MATCH_IOU:
            used.add(best[0])
        else:
            false += 1
    out = {"reported": len(spans), "false": false}
    for kind in ("strong", "faint"):
        out[f"{kind}_planted"] = sum(1 for t in truth if t["kind"] == kind)
        out[f"{kind}_found"] = sum(1 for j in used if truth[j]["kind"] == kind)
    return out


def _add(total: dict, part: dict) -> None:
    for k, v in part.items():
        total[k] = total.get(k, 0) + v


def _line(name: str, t: dict) -> str:
    def share(a, b):
        return f"{a} of {b} ({100 * a / b:.0f}%)" if b else "none planted"
    return (f"| {name} | {share(t['strong_found'], t['strong_planted'])} | "
            f"{share(t['faint_found'], t['faint_planted'])} | {t['false']} of {t['reported']} |")


async def run(with_model: bool, sessions: int) -> dict:
    outreach = None
    if with_model:
        from .config import Settings
        from .outreach import Outreach
        outreach = Outreach(Settings.from_env())
        if not outreach.gemini_on:
            raise SystemExit("level 2 is not configured (OUTREACH_MODE, GEMINI_API_KEY, GEMINI_MODEL)")
    code_total: dict = {}
    model_total: dict = {}
    kept_total: dict = {}
    agreements: list[dict] = []
    failed = 0
    for seed in range(sessions):
        raw, truth = make_session(1000 + seed)
        view = fr.code_view(raw)
        _add(code_total, score([(s["start_s"], s["end_s"]) for s in view["smiles"]], truth))
        if outreach is None:
            continue
        try:
            pack = INPUT_GATE.frames_pack({"type": "focus"}, raw)
            text = await outreach.gemini_complete(pack)
            res = OUTPUT_GATE.frames_reading(text, pack, raw)
        except GateError:
            res = None
        if res is None or not res.ok:
            failed += 1
            print(f"session {seed}: no usable reply", file=sys.stderr)
            continue
        # What the model said, before the check: read it again without the gate's verdicts.
        said = json.loads(fr_text(text))["smiles"]
        _add(model_total, score([(s["start_s"], s["end_s"]) for s in said], truth))
        rd = res.value["reading"]
        _add(kept_total, score([(s["start_s"], s["end_s"])
                                for s in rd["smiles"] + rd["faint_smiles"]], truth))
        agreements.append(res.value["agreement"])
        print(f"session {seed}: read", file=sys.stderr)
    out = {"sessions": sessions, "seconds_each": SECONDS, "code_vs_truth": code_total}
    if outreach is not None:
        out.update(model=outreach.level2_model, sessions_read=sessions - failed,
                   sessions_failed=failed, model_vs_truth=model_total,
                   model_after_check_vs_truth=kept_total,
                   model_vs_code=fr.aggregate(agreements))
    return out


def fr_text(text: str) -> str:
    """The JSON object inside a reply (the output gate already accepted it)."""
    a, b = text.find("{"), text.rfind("}")
    return text[a:b + 1]


def table(out: dict) -> str:
    rows = ["| Reader | Strong smiles found | Faint smiles found | Reported with no planted smile |",
            "|---|---|---|---|", _line("Code (fixed rule)", out["code_vs_truth"])]
    if out.get("model_vs_truth"):
        rows.append(_line(f"Model ({out['model']}), as reported", out["model_vs_truth"]))
        rows.append(_line("Model, after code's check", out["model_after_check_vs_truth"]))
    return "\n".join(rows)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--model", action="store_true", help="also send every session to level 2")
    ap.add_argument("--sessions", type=int, default=SESSIONS)
    ap.add_argument("--out", help="write the result as JSON to this file")
    args = ap.parse_args()
    out = asyncio.run(run(args.model, args.sessions))
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(out, f, indent=1)
    print(f"{out['sessions']} synthetic sessions of {out['seconds_each']} s"
          + (f", {out['sessions_read']} read by the model" if "sessions_read" in out else ""))
    print(table(out))
    if out.get("model_vs_code"):
        print("model against code:", json.dumps(out["model_vs_code"]))


if __name__ == "__main__":
    main()
