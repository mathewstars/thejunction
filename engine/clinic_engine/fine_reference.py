"""A workbench for reading the fine movement stream (docs/face-fine.md), ready
before real recordings exist. Nothing here is used by the running server.

    python -m clinic_engine.fine_reference                    # code alone on generated sessions
    python -m clinic_engine.fine_reference --payload 1003     # what a model would be given
    python -m clinic_engine.fine_reference --reply 1003 reply.json   # check a model's answer
    python -m clinic_engine.fine_reference --stream file.json        # the same on a stored stream
    python -m clinic_engine.fine_reference --stream file.json --reply-file reply.json

What it gives you:

- sessions with brief movements planted at known places, so that a detector
  can be scored against something that is not itself;
- the code detector (mind/face_fine.twitches) scored against those places;
- `payload`: the stream as a model would get it, with the draft instruction
  in data/fine_prompt.txt;
- `verify`: every item a model reports, checked against the numbers. An item
  that code also finds is confirmed; any other item is dropped. Nothing a
  model says is kept on its say-so.

What it does not do: send anything to a model. To read sessions with the
server's level 2, the stream needs its own input and output gate
(mind/gates.py), as the frame reading has. That is the next step, on purpose
not taken here.

What it does not measure: anything about real faces. The streams are made by
this file. The slow movements, steps and noise are there to check that they
are NOT reported as brief movements.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import sys
from pathlib import Path

from .mind import face_fine

REGIONS = ["mouth_left", "mouth_right", "cheek_left", "cheek_right", "brow_left", "brow_right"]
SECONDS = 45
RATE = 60
MATCH_IOU = 0.3   # a reported span is a planted movement at this overlap over the union
PROMPT = Path(__file__).resolve().parent / "data" / "fine_prompt.txt"


def make_session(seed: int, hard: str | None = None) -> tuple[dict, list[dict]]:
    """One generated stream and its planted brief movements:
    [{"region", "start_s", "end_s", "peak_mm"}]. `hard` adds one thing that is
    not a brief movement: "expression" (slow rises), "step" (the phone moved:
    every region shifts and stays) or "noisy" (a noise floor three times higher)."""
    rng = random.Random(seed)
    n = SECONDS * RATE
    noise = rng.uniform(0.04, 0.08) * (3 if hard == "noisy" else 1)
    rest = [rng.uniform(0.15, 0.35) for _ in REGIONS]
    rows = [[max(0.0, rest[j] + rng.gauss(0, noise)) for j in range(len(REGIONS))] for _ in range(n)]
    truth = []
    taken: list[tuple[int, float]] = []
    for _ in range(rng.randint(3, 7)):
        j = rng.randrange(len(REGIONS))
        at = rng.uniform(2, SECONDS - 2)
        if any(k == j and abs(at - a) < 1.5 for k, a in taken):
            continue
        taken.append((j, at))
        long = rng.uniform(0.08, 0.30)
        peak = rng.uniform(0.9, 2.5) + (3 * noise if hard == "noisy" else 0)
        i0, i1 = int(at * RATE), int((at + long) * RATE)
        for i in range(i0, i1):
            rows[i][j] += peak * math.sin(math.pi * (i - i0 + 0.5) / (i1 - i0)) ** 0.5
        truth.append({"region": REGIONS[j], "start_s": round(i0 / RATE, 2),
                      "end_s": round(i1 / RATE, 2), "peak_mm": round(peak, 2)})
    if hard == "expression":
        for _ in range(3):
            j, at, long = rng.randrange(2), rng.uniform(3, SECONDS - 8), rng.uniform(1.5, 4)
            for i in range(int(at * RATE), int((at + long) * RATE)):
                rows[i][j] += 2.5 * math.sin(math.pi * (i / RATE - at) / long)
    if hard == "step":
        at = int(rng.uniform(15, 30) * RATE)
        for i in range(at, n):
            for j in range(len(REGIONS)):
                rows[i][j] += 0.8
    raw = {"source": "mesh", "rate_hz": RATE, "regions": list(REGIONS), "noise_mm": round(noise, 3),
           "samples": [[round(v, 3) for v in r] for r in rows]}
    return raw, sorted(truth, key=lambda t: t["start_s"])


def _iou(a0: float, a1: float, b0: float, b1: float) -> float:
    inter = max(0.0, min(a1, b1) - max(a0, b0))
    union = max(a1, b1) - min(a0, b0)
    return inter / union if union > 0 else 0.0


def _same(a: dict, b: dict) -> bool:
    return a["region"] == b["region"] and \
        _iou(a["start_s"], a["end_s"], b["start_s"], b["end_s"]) >= MATCH_IOU


def score(found: list[dict], truth: list[dict]) -> dict:
    """Planted movements found, planted movements missed, and items reported
    where nothing was planted."""
    hit = sum(1 for t in truth if any(_same(f, t) for f in found))
    extra = sum(1 for f in found if not any(_same(f, t) for t in truth))
    return {"planted": len(truth), "found": hit, "missed": len(truth) - hit, "extra": extra}


def payload(raw: dict, block_s: float = 0.05) -> dict:
    """The stream as a model would be given it: numbers and fixed names only.
    Rows are blocks of `block_s` seconds carrying each region's largest value,
    so a brief movement is not averaged away and the object stays small."""
    rate = float(raw["rate_hz"])
    step = max(1, int(round(block_s * rate)))
    frames = []
    for i in range(0, len(raw["samples"]), step):
        block = raw["samples"][i:i + step]
        frames.append([round(i / rate, 2)] + [round(max(r[j] for r in block), 2)
                                              for j in range(len(raw["regions"]))])
    return {"rate_hz": round(rate / step, 2), "regions": list(raw["regions"]),
            "noise_mm": raw.get("noise_mm"), "frames": frames}


def verify(reply: dict, raw: dict) -> dict:
    """Check every item a model reported against the numbers. Confirmed: code
    finds a brief movement in the same region at that time. Dropped, with the
    reason: everything else. Also what code found that the model did not say."""
    code = face_fine.twitches(raw)
    seconds = len(raw["samples"]) / float(raw["rate_hz"])
    confirmed, dropped = [], []
    items = reply.get("twitches") if isinstance(reply, dict) else None
    if not isinstance(items, list) or len(items) > 60:
        return {"ok": False, "reason": "not_the_asked_shape", "confirmed": [], "dropped": [],
                "code_only": code}
    for it in items:
        ok_shape = isinstance(it, dict) and set(it) == {"region", "start_s", "end_s"} \
            and isinstance(it["start_s"], (int, float)) and isinstance(it["end_s"], (int, float))
        if not ok_shape or it["region"] not in raw["regions"]:
            dropped.append({"item": None, "reason": "not_the_asked_shape"})
        elif not (0 <= it["start_s"] < it["end_s"] <= seconds + 0.5):
            dropped.append({"item": it, "reason": "outside_the_recording"})
        elif any(_same(it, c) for c in code):
            confirmed.append(it)
        else:
            dropped.append({"item": it, "reason": "not_in_the_numbers"})
    return {"ok": True, "confirmed": confirmed, "dropped": dropped,
            "code_only": [c for c in code if not any(_same(c, it) for it in confirmed)]}


def run(sessions: int = 40) -> dict:
    """Code alone against the planted movements, on a clean set and on the hard kinds."""
    plan = [("clean", 1000 + k, None) for k in range(sessions)]
    plan += [(kind, 2000 + k, kind) for kind in ("expression", "step", "noisy") for k in range(5)]
    out: dict = {}
    for name, seed, kind in plan:
        raw, truth = make_session(seed, kind)
        s = score(face_fine.twitches(raw), truth)
        t = out.setdefault(name, {"sessions": 0, "planted": 0, "found": 0, "missed": 0, "extra": 0})
        t["sessions"] += 1
        for k in ("planted", "found", "missed", "extra"):
            t[k] += s[k]
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--payload", type=int, metavar="SEED", help="print the instruction and the "
                    "object a model would be given for the generated session with this seed")
    ap.add_argument("--reply", nargs=2, metavar=("SEED", "FILE"), help="check a model's JSON reply "
                    "for that generated session")
    ap.add_argument("--stream", metavar="FILE", help="a stored stream (the `stream` object of "
                    "GET .../face-fine): print what code finds and the payload")
    ap.add_argument("--reply-file", metavar="FILE", help="with --stream: a model's reply to check")
    ap.add_argument("--hard", choices=("expression", "step", "noisy"))
    a = ap.parse_args()
    if a.stream:
        raw = json.loads(Path(a.stream).read_text("utf-8"))
        raw = raw.get("stream", raw)
        if a.reply_file:
            print(json.dumps(verify(json.loads(Path(a.reply_file).read_text("utf-8")), raw), indent=1))
        else:
            print(json.dumps({"summary": face_fine.summarize(raw), "code_finds": face_fine.twitches(raw),
                              "payload": payload(raw)}, indent=1))
        return
    if a.payload is not None:
        raw, _ = make_session(a.payload, a.hard)
        print(PROMPT.read_text("utf-8"))
        print(json.dumps(payload(raw)))
        return
    if a.reply:
        raw, truth = make_session(int(a.reply[0]), a.hard)
        res = verify(json.loads(Path(a.reply[1]).read_text("utf-8")), raw)
        res["confirmed_vs_planted"] = score(res["confirmed"], truth)
        print(json.dumps(res, indent=1))
        return
    res = run()
    for name, t in res.items():
        print(f"{name:10} sessions {t['sessions']:3}  planted {t['planted']:4}  found {t['found']:4}  "
              f"missed {t['missed']:3}  reported where nothing was planted {t['extra']:3}")
    print("Generated streams only: this says how the rule handles a known signal, "
          "nothing about a real face.", file=sys.stderr)


if __name__ == "__main__":
    main()
