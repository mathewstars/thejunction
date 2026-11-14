"""The reference set for the day reading: generated series of daily numbers
with changes planted at known places, so both readers can be scored against
something that is neither of them.

    python -m clinic_engine.days_reference              # code alone
    python -m clinic_engine.days_reference --model      # code and the level-2 model

Each series is 84 days of one invented person: steps, walking speed and sleep
with day-to-day noise and a weekly rhythm (one or two weekdays on which this
person always walks less). Planted on top, in the steps:

- "sustained": for 6 to 10 days the person walks clearly less;
- "gradual": over 16 to 24 days the steps slide down a little every few days;
- "none": nothing changes (the weekly rhythm is all there is);
- "odd_day": nothing changes, but two single days are very low;
- "gap": nothing changes, and four days in a row have no data.

The planted spans are the truth. Nothing here is a measurement of a person,
and real series will be messier: this says how the readers handle a known
signal, not how well either reads someone's life.

With --model each series goes to level 2 through the same gates as a real one.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import random
import sys
from datetime import date, timedelta

from .mind import day_reading as dr
from .mind.gates import INPUT_GATE, OUTPUT_GATE, GateError

DAYS = 84
KINDS = ("sustained",) * 8 + ("gradual",) * 8 + ("none",) * 4 + ("odd_day",) * 2 + ("gap",) * 2
START = date(2026, 1, 5)  # a Monday; the dates are never sent
MATCH_IOU = 0.3


def make_series(seed: int, kind: str) -> tuple[dict, list[dict]]:
    """One generated person: (day records by ISO date, the planted stretches)."""
    rng = random.Random(seed)
    base = rng.uniform(5500, 9000)
    noise = rng.uniform(0.07, 0.11)
    low_days = rng.sample(range(1, 8), rng.choice([1, 2]))
    low_by = rng.uniform(0.22, 0.32)
    factor = [1.0] * DAYS
    truth: list[dict] = []
    if kind == "sustained":
        a = rng.randint(40, 68)
        b = a + rng.randint(6, 10) - 1
        depth = rng.uniform(0.5, 0.65)
        for i in range(a, b + 1):
            factor[i] = depth
        truth.append({"start_d": a, "end_d": b, "shape": "sustained"})
    elif kind == "gradual":
        n = rng.randint(16, 24)
        a = DAYS - n - rng.randint(0, 6)
        end = rng.uniform(0.6, 0.7)
        for i in range(a, DAYS):
            factor[i] = 1 - (1 - end) * min(1.0, (i - a + 1) / n)
        truth.append({"start_d": a, "end_d": DAYS - 1, "shape": "gradual"})
    odd = rng.sample(range(35, DAYS - 3), 2) if kind == "odd_day" else []
    gap = range(50, 54) if kind == "gap" else range(0)
    days: dict[str, dict] = {}
    for i in range(DAYS):
        d = START + timedelta(days=i)
        if i in gap:
            continue
        f = factor[i] * (1 - low_by if d.isoweekday() in low_days else 1.0)
        steps = base * f * (1 + rng.gauss(0, noise))
        if i in odd:
            steps = base * 0.25
        days[d.isoformat()] = {
            "date": d.isoformat(), "steps": int(max(200, steps)),
            "walking_speed_m_s": round(rng.gauss(1.25, 0.03) * (0.9 + 0.1 * factor[i]), 3),
            "sleep_h": round(max(3.0, rng.gauss(7.0, 0.5)), 2)}
    return days, truth


def _iou(a0: int, a1: int, b0: int, b1: int) -> float:
    inter = min(a1, b1) - max(a0, b0) + 1
    return inter / (max(a1, b1) - min(a0, b0) + 1) if inter > 0 else 0.0


def score(spans: list[tuple[int, int]], truth: list[dict]) -> dict:
    """Reported stretches of lower steps against the planted ones, one to one."""
    used: set[int] = set()
    false = 0
    for a, b in spans:
        best = max(((j, _iou(a, b, t["start_d"], t["end_d"])) for j, t in enumerate(truth)
                    if j not in used), key=lambda x: x[1], default=(None, 0.0))
        if best[0] is not None and best[1] >= MATCH_IOU:
            used.add(best[0])
        else:
            false += 1
    out = {"reported": len(spans), "false": false}
    for shape in ("sustained", "gradual"):
        out[f"{shape}_planted"] = sum(1 for t in truth if t["shape"] == shape)
        out[f"{shape}_found"] = sum(1 for j in used if truth[j]["shape"] == shape)
    return out


def trend_scan(payload: dict) -> list[tuple[int, int]]:
    """A second code reader, not in the product: slide windows of 10 to 28 days
    over the steps and keep those that pass code's own test for a slow decline
    or a sustained dip (day_reading.check_stretch); windows that touch are
    joined. Written to answer "could code find the slow declines alone?" with a
    number, as the rest-relative rule does for the face numbers."""
    view = dr.code_view(payload)
    n = payload["days"]
    hits: list[tuple[int, int]] = []
    for length in (10, 14, 21, 28):
        for a in range(0, n - length + 1):
            for shape in ("gradual", "sustained"):
                ok, _why = dr.check_stretch(view, {"start_d": a, "end_d": a + length - 1,
                                                   "channel": "steps", "direction": "lower",
                                                   "shape": shape})
                if ok is not None:
                    hits.append((a, a + length - 1))
                    break
    spans: list[list[int]] = []
    for a, b in sorted(hits):
        if spans and a <= spans[-1][1] + 1:
            spans[-1][1] = max(spans[-1][1], b)
        else:
            spans.append([a, b])
    return [(a, b) for a, b in spans]


def _lower_steps(items: list[dict]) -> list[tuple[int, int]]:
    return [(s["start_d"], s["end_d"]) for s in items
            if s["channel"] == "steps" and s["direction"] == "lower"]


def _add(total: dict, part: dict) -> None:
    for k, v in part.items():
        total[k] = total.get(k, 0) + v


async def run(with_model: bool, series: int = len(KINDS)) -> dict:
    outreach = None
    if with_model:
        from .config import Settings
        from .outreach import Outreach
        outreach = Outreach(Settings.from_env())
        if not outreach.gemini_on:
            raise SystemExit("level 2 is not configured (OUTREACH_MODE, GEMINI_API_KEY, GEMINI_MODEL)")
    out: dict = {"series": 0, "days_each": DAYS, "code_vs_truth": {}, "trend_scan_vs_truth": {},
                 "model_vs_truth": {},
                 "model_after_check_vs_truth": {}, "weekday": {"planted": 0, "code": 0, "model": 0,
                                                              "model_wrong": 0},
                 "read": 0, "failed": 0, "agreement": {}}
    if outreach is not None:
        out["model"] = outreach.level2_model
    for k, kind in enumerate(KINDS[:series]):
        days, truth = make_series(3000 + k, kind)
        out["series"] += 1
        payload = dr.reduce(days, {})
        view = dr.code_view(payload)
        _add(out["code_vs_truth"], score(_lower_steps(view["stretches"]), truth))
        _add(out["trend_scan_vs_truth"], score(trend_scan(payload), truth))
        # The weekly rhythm: weekdays on which the generator made this person walk less.
        rng = random.Random(3000 + k)
        rng.uniform(0, 1), rng.uniform(0, 1)
        low_days = set(rng.sample(range(1, 8), rng.choice([1, 2])))
        out["weekday"]["planted"] += len(low_days)
        out["weekday"]["code"] += len(low_days & set(view["weekly"].get("steps", [])))
        if outreach is None:
            continue
        try:
            pack = INPUT_GATE.days_pack(days, {})
            text = await outreach.gemini_complete(pack)
            res = OUTPUT_GATE.days_reading(text, pack)
        except GateError:
            res = None
        if res is None or not res.ok:
            out["failed"] += 1
            why = res.refusals[0].reason if res is not None and res.refusals else "refused"
            print(f"series {k} {kind}: no usable reply ({why}; {outreach.last_frames_meta})",
                  file=sys.stderr)
            continue
        out["read"] += 1
        said = json.loads(text[text.find("{"):text.rfind("}") + 1])
        _add(out["model_vs_truth"], score(_lower_steps(said["stretches"]), truth))
        _add(out["model_after_check_vs_truth"],
             score(_lower_steps(res.value["reading"]["stretches"]), truth))
        named = {d for w in said["weekly"] if w["channel"] == "steps" for d in w["low_weekdays"]}
        out["weekday"]["model"] += len(low_days & named)
        out["weekday"]["model_wrong"] += len(named - low_days)
        _add(out["agreement"], {a: v for a, v in res.value["agreement"].items()
                                if isinstance(v, int)})
        print(f"series {k} {kind}: read", file=sys.stderr)
    return out


def _line(name: str, t: dict) -> str:
    def share(a, b):
        return f"{a} of {b}" if b else "none planted"
    return (f"| {name} | {share(t['sustained_found'], t['sustained_planted'])} | "
            f"{share(t['gradual_found'], t['gradual_planted'])} | {t['false']} of {t['reported']} |")


def table(out: dict) -> str:
    rows = ["| Reader | Sustained dips found | Slow declines found | Reported with nothing planted |",
            "|---|---|---|---|", _line("Code, fixed rule", out["code_vs_truth"]),
            _line("Code, trend scan (not in the product)", out["trend_scan_vs_truth"])]
    if out.get("model_vs_truth"):
        rows.append(_line(f"Model ({out['model']}), as reported", out["model_vs_truth"]))
        rows.append(_line("Model, after code's check", out["model_after_check_vs_truth"]))
    return "\n".join(rows)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--model", action="store_true", help="also send every series to level 2")
    ap.add_argument("--series", type=int, default=len(KINDS))
    ap.add_argument("--out", help="write the result as JSON to this file")
    args = ap.parse_args()
    out = asyncio.run(run(args.model, args.series))
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(out, f, indent=1)
    print(f"{out['series']} generated series of {out['days_each']} days"
          + (f", {out['read']} read by the model, {out['failed']} failed" if args.model else ""))
    print(table(out))
    w = out["weekday"]
    print(f"weekly rhythm: {w['planted']} low weekdays planted; code names {w['code']}"
          + (f"; the model names {w['model']} and {w['model_wrong']} that were not planted"
             if args.model else ""))
    if out.get("agreement"):
        print("model against code:", json.dumps(out["agreement"]))


if __name__ == "__main__":
    main()
