"""The reference set for the frame reading: sessions with smiles planted at
known places, so both readers can be scored against something that is neither
of them.

    python -m clinic_engine.frames_reference              # code alone
    python -m clinic_engine.frames_reference --model      # code and the level-2 model
    python -m clinic_engine.frames_reference --model --out reference.json

Each session is a synthetic stream of ARKit-like numbers: a resting level that
differs from session to session, jitter, a slow drift, blinks, and smiles that
rise and fall smoothly. Some smiles are strong (they pass code's fixed onset)
and some are faint (they rise clearly above the session's resting level but
stay under the onset). The planted spans are the truth.

Two sets. The clean set (40 sessions) has nothing else in it. The hard set (10
sessions) adds things that are not smiles but move the same numbers: talking
(the jaw opens and closes and the mouth corners are pulled with it), a step in
the baseline (the phone moved), and a person whose mouth rests high, close to
the fixed onset.

What it measures:

- code against the truth: the fixed rule of the face summary;
- a second code rule against the truth: the same rule with its onset set
  relative to the session's own resting level. It is not in the product. It was
  written after the model showed what the fixed rule misses, to answer "could
  code do that alone?" with a number;
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
HARD = ("talking",) * 4 + ("step",) * 3 + ("high_rest",) * 3
SECONDS = 45
RATE = 30
MATCH_IOU = 0.3  # a reported span is a planted smile at this overlap over the union


def make_session(seed: int, hard: str | None = None, wanted: list[str] | None = None,
                 moments: bool = False) -> tuple[dict, list[dict]]:
    """One synthetic session and its planted smiles:
    [{"start_s", "end_s", "peak", "kind": "strong" | "faint"}]. `hard` adds one
    thing that is not a smile: "talking", "step" or "high_rest". `wanted` sets the
    smiles to plant, in order ("strong" or "faint"), instead of drawing them.
    With `moments`, a pleasant moment is marked 0.8 s before every second smile,
    and one more where no smile follows."""
    rng = random.Random(seed)
    n = SECONDS * RATE
    rest = rng.uniform(0.20, 0.23) if hard == "high_rest" else rng.uniform(0.03, 0.10)
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
    drawn = ["strong"] * rng.randint(2, 4) + ["faint"] * rng.randint(1, 3)
    if hard == "high_rest":
        drawn = ["strong"] * rng.randint(2, 3)  # nothing can be faint under this rest
    rng.shuffle(drawn)
    wanted = list(wanted) if wanted is not None else drawn
    # The hard part takes the last ten seconds; the smiles keep to the time before it.
    span = SECONDS - (12 if hard in ("talking", "step", "yawn", "chewing", "drift") else 0)
    slot = (span - 4) / max(1, len(wanted))
    for k, kind in enumerate(wanted):
        dur = rng.uniform(1.0, 2.4)
        start = 2 + k * slot + rng.uniform(0, max(0.1, slot - dur - 1.0))
        amp = rng.uniform(0.30, 0.55) if kind == "strong" else \
            rng.uniform(0.10, max(0.11, T.smile_onset - rest - 0.035))
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
    if hard == "talking":
        # Ten seconds of speech: the jaw opens and closes about four times a
        # second, and syllables pull both mouth corners for a third to half a second.
        t0 = SECONDS - 11
        for i in range(t0 * RATE, (t0 + 10) * RATE):
            t = (i - t0 * RATE) / RATE
            cols["jawOpen"][i] += 0.18 + 0.16 * math.sin(2 * math.pi * 4.1 * t)
            cols["mouthFunnel"][i] += 0.08 * (1 + math.sin(2 * math.pi * 2.3 * t))
        at = t0 + 0.4
        while at < t0 + 9.2:
            dur, amp = rng.uniform(0.33, 0.55), rng.uniform(0.09, 0.15)
            for i in range(int(at * RATE), int((at + dur) * RATE)):
                env = math.sin(math.pi * (i / RATE - at) / dur)
                cols["mouthSmileLeft"][i] += amp * env
                cols["mouthSmileRight"][i] += amp * env
            at += dur + rng.uniform(0.5, 1.1)
    if hard == "step":
        # The phone moved: every mouth value sits higher from here to the end.
        up = rng.uniform(0.10, 0.14)
        for i in range((SECONDS - 11) * RATE, n):
            cols["mouthSmileLeft"][i] += up
            cols["mouthSmileRight"][i] += up
    # Three more things that are not smiles. The instruction the model gets does
    # NOT name these (it names talking and a shifted resting level only), so a
    # set made of them asks whether the model copes with what it was not told.
    if hard == "yawn":
        # Two yawns of three seconds: the jaw opens wide, the mouth stretches,
        # and the corners are pulled a little with it.
        for t0 in (SECONDS - 11, SECONDS - 6):
            for i in range(t0 * RATE, min(n, (t0 + 3) * RATE)):
                env = math.sin(math.pi * (i / RATE - t0) / 3)
                cols["jawOpen"][i] += 0.6 * env
                for c in ("mouthStretchLeft", "mouthStretchRight"):
                    cols[c][i] += 0.3 * env
                for c in ("mouthSmileLeft", "mouthSmileRight"):
                    cols[c][i] += 0.10 * env
    if hard == "chewing":
        # Ten seconds of chewing: the jaw moves about one and a half times a
        # second and one mouth corner at a time is pulled with each bite.
        t0 = SECONDS - 11
        for i in range(t0 * RATE, (t0 + 10) * RATE):
            t = (i - t0 * RATE) / RATE
            cols["jawOpen"][i] += 0.10 + 0.08 * math.sin(2 * math.pi * 1.5 * t)
            bite = int(t * 1.5)
            pull = 0.11 * max(0.0, math.sin(2 * math.pi * 1.5 * t))
            cols["mouthSmileLeft" if bite % 2 else "mouthSmileRight"][i] += pull
    if hard == "drift":
        # The light fades: the tracker's mouth values creep up over eleven seconds.
        a0 = (SECONDS - 11) * RATE
        for i in range(a0, n):
            up = 0.12 * (i - a0) / (n - a0)
            cols["mouthSmileLeft"][i] += up
            cols["mouthSmileRight"][i] += up
    for s in range(3, SECONDS, rng.randint(3, 6)):
        first = int((s + rng.random()) * RATE)
        for i in range(first, first + 4):
            if i < n:
                cols["eyeBlinkLeft"][i] = cols["eyeBlinkRight"][i] = 0.9
    raw = {"rate_hz": RATE, "channels": channels,
           "samples": [[round(min(1.0, max(0.0, cols[c][i])), 3) if c not in ff.HEAD_CHANNELS
                        else round(cols[c][i], 2) for c in channels] for i in range(n)],
           "moments_ms": []}
    if moments:
        marks = [int((t["start_s"] - 0.8) * 1000) for t in truth[::2] if t["start_s"] > 1.0]
        free = [s for s in range(3, SECONDS - 4)
                if all(not (t["start_s"] - 4 < s < t["end_s"] + 1) for t in truth)]
        if free:
            marks.append(free[len(free) // 2] * 1000)
        raw["moments_ms"] = sorted(marks)
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


def rest_relative(raw: dict) -> list[tuple[float, float]]:
    """The second code rule: the fixed rule's hysteresis with the onset and the
    offset set above the session's own resting level (its median)."""
    view = fr.code_view(raw)
    rate = view["rate"]
    runs = ff._runs(view["tracked"])
    on, off = view["rest"] + 0.07, view["rest"] + 0.03
    return [(s / rate, e / rate) for s, e in ff._events(view["smile"], runs, on, off, True)
            if (e - s) / rate >= T.smile_min_s]


def _add(total: dict, part: dict) -> None:
    for k, v in part.items():
        total[k] = total.get(k, 0) + v


def _line(name: str, t: dict) -> str:
    def share(a, b):
        return f"{a} of {b} ({100 * a / b:.0f}%)" if b else "none planted"
    return (f"| {name} | {share(t['strong_found'], t['strong_planted'])} | "
            f"{share(t['faint_found'], t['faint_planted'])} | {t['false']} of {t['reported']} |")


async def run(with_model: bool, sessions: int, hard: bool = True, hard_seed: int = 2000,
              hard_count: int | None = None, hard_kinds: tuple[str, ...] | None = None,
              repeat: int = 1) -> dict:
    """hard_seed and hard_count make a hard set on other seeds than the usual
    ten (a set nobody looked at while the instruction and the check were written)."""
    outreach = None
    if with_model:
        from .config import Settings
        from .outreach import Outreach
        outreach = Outreach(Settings.from_env())
        if not outreach.gemini_on:
            raise SystemExit("level 2 is not configured (OUTREACH_MODE, GEMINI_API_KEY, GEMINI_MODEL)")
    plan = [("clean", 1000 + k, None) for k in range(sessions)]
    if hard:
        pool = hard_kinds or HARD
        kinds = pool if hard_count is None and hard_kinds is None else \
            [pool[k % len(pool)] for k in range(hard_count or len(pool))]
        plan += [("hard", hard_seed + k, kind) for k, kind in enumerate(kinds)]
    out: dict = {"seconds_each": SECONDS, "sets": {}}
    if outreach is not None:
        out["model"] = outreach.level2_model
    import time
    for name, seed, kind in plan:
        st = out["sets"].setdefault(name, {
            "sessions": 0, "code_vs_truth": {}, "rest_rule_vs_truth": {}, "model_vs_truth": {},
            "model_after_check_vs_truth": {}, "agreements": [], "sessions_read": 0,
            "sessions_failed": 0, "seconds": [], "same_in_every_read": 0, "read_times": repeat})
        st["sessions"] += 1
        raw, truth = make_session(seed, kind)
        view = fr.code_view(raw)
        _add(st["code_vs_truth"], score([(s["start_s"], s["end_s"]) for s in view["smiles"]], truth))
        _add(st["rest_rule_vs_truth"], score(rest_relative(raw), truth))
        if outreach is None:
            continue
        reads: list[list[tuple[float, float]]] = []
        for r in range(repeat):
            t0 = time.monotonic()
            try:
                pack = INPUT_GATE.frames_pack({"type": "focus"}, raw)
                text = await outreach.gemini_complete(pack)
                res = OUTPUT_GATE.frames_reading(text, pack, raw)
            except GateError:
                res = None
            st["seconds"].append(round(time.monotonic() - t0, 1))
            if res is None or not res.ok:
                st["sessions_failed"] += 1
                why = res.refusals[0].reason if res is not None and res.refusals else "refused"
                print(f"{name} {seed} {kind or ''}: no usable reply ({why}; "
                      f"{outreach.last_frames_meta})", file=sys.stderr)
                continue
            st["sessions_read"] += 1
            # What the model said, before the check.
            said = [(x["start_s"], x["end_s"]) for x in json.loads(fr_text(text))["smiles"]]
            reads.append(said)
            _add(st["model_vs_truth"], score(said, truth))
            rd = res.value["reading"]
            _add(st["model_after_check_vs_truth"],
                 score([(x["start_s"], x["end_s"]) for x in rd["smiles"] + rd["faint_smiles"]],
                       truth))
            st["agreements"].append(res.value["agreement"])
            print(f"{name} {seed} {kind or ''}: read in {st['seconds'][-1]} s", file=sys.stderr)
        # The same smiles in every read: the same number, each overlapping its
        # counterpart in the first read by half of their union.
        if len(reads) == repeat and all(
                len(r) == len(reads[0]) and all(
                    any(_iou(a0, a1, b0, b1) >= 0.5 for b0, b1 in reads[0]) for a0, a1 in r)
                for r in reads[1:]):
            st["same_in_every_read"] += 1
    for st in out["sets"].values():
        st["model_vs_code"] = fr.aggregate(st.pop("agreements"))
        secs = st.pop("seconds")
        st["median_seconds"] = sorted(secs)[len(secs) // 2] if secs else None
    return out


def fr_text(text: str) -> str:
    """The JSON object inside a reply (the output gate already accepted it)."""
    a, b = text.find("{"), text.rfind("}")
    return text[a:b + 1]


def table(st: dict, model: str | None) -> str:
    rows = ["| Reader | Strong smiles found | Faint smiles found | Reported with no planted smile |",
            "|---|---|---|---|", _line("Code, fixed rule (the product's summary)", st["code_vs_truth"]),
            _line("Code, rule relative to the person's rest (not in the product)",
                  st["rest_rule_vs_truth"])]
    if st.get("model_vs_truth"):
        rows.append(_line(f"Model ({model}), as reported", st["model_vs_truth"]))
        rows.append(_line("Model, after code's check", st["model_after_check_vs_truth"]))
    return "\n".join(rows)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--model", action="store_true", help="also send every session to level 2")
    ap.add_argument("--sessions", type=int, default=SESSIONS, help="sessions in the clean set")
    ap.add_argument("--no-hard", action="store_true", help="leave the hard set out")
    ap.add_argument("--hard-seed", type=int, default=2000, help="first seed of the hard set")
    ap.add_argument("--hard-count", type=int, default=None, help="sessions in the hard set")
    ap.add_argument("--hard-kinds", default=None,
                    help="comma list of what the hard set holds: talking, step, high_rest "
                         "(the usual three), yawn, chewing, drift (not named in the instruction)")
    ap.add_argument("--repeat", type=int, default=1, help="read every session this many times")
    ap.add_argument("--out", help="write the result as JSON to this file")
    args = ap.parse_args()
    kinds = tuple(k.strip() for k in args.hard_kinds.split(",")) if args.hard_kinds else None
    out = asyncio.run(run(args.model, args.sessions, not args.no_hard, args.hard_seed,
                          args.hard_count, kinds, args.repeat))
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(out, f, indent=1)
    for name, st in out["sets"].items():
        print(f"\n{name} set: {st['sessions']} synthetic sessions of {out['seconds_each']} s"
              + (f", {st['sessions_read']} read by the model, {st['sessions_failed']} failed, "
                 f"median {st['median_seconds']} s a call" if args.model else ""))
        print(table(st, out.get("model")))
        if args.model and args.repeat > 1:
            print(f"each session read {args.repeat} times (the model's rows count every read); "
                  f"the same smiles in every read: {st['same_in_every_read']} of {st['sessions']} sessions")
        if st.get("model_vs_code"):
            print("model against code:", json.dumps(st["model_vs_code"]))


if __name__ == "__main__":
    main()
