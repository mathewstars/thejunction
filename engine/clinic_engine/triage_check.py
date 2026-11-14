"""A check of the two model levels on generated pictures (no patient data).

    python -m clinic_engine.triage_check --pictures 40 --out triage-check.json

It asks two questions that need no clinician and no patient:

1. Worse must not mean lower. Every picture is made twice: as it is, and
   strictly worse (the movement drop deeper and longer, more low notes, the
   same flags). No flag may end at a lower level in the worse picture.
2. A rule about one flag must not move another. Half of the pictures are also
   read with one clinic rule about the movement drop; every other flag must
   keep the level it had without the rule.

Both are counted twice: for what the models asked for, and for the level after
code's floors (mind/triage.py), which is what the clinic sees. The pictures
are generated from a seed and have the same form as the ones the engine sends
(mind/gates.py, triage_payload). The models are the configured ones, called
through the same gates as in the engine.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import random

from .mind.gates import INPUT_GATE, OUTPUT_GATE
from .mind.triage import LEVELS, combine

RULE = ("The drop in movement is expected: planned rest after an operation. "
        "It only needs watching.")
OTHERS = ("low_notes", "silence", "slower_reactions", "face_flat", "novelty", "weak_rounds")


def half(v: float) -> float:
    return round(v * 2) / 2


def deviation_level(low_days: int, mean_z: float, held: int) -> str:
    """The fixed rules' level for a movement drop (mind/thresholds.py)."""
    return "urgent" if (mean_z <= -2.5 and low_days >= 4) or held >= 10 else "attention"


def make_picture(seed: int, worse: bool = False) -> dict:
    """One generated picture. worse=True: the same person and flags, with the
    movement drop one unit deeper, three days longer, and two more low notes."""
    rnd = random.Random(seed)
    low_days = rnd.choice((3, 3, 4, 5))
    depth = rnd.choice((-1.5, -2.0, -2.0, -2.5, -3.0))
    held = rnd.choice((1, 2, 3, 5, 7))
    notes = rnd.choice((0, 0, 1, 2))
    kinds = rnd.sample(OTHERS, rnd.choice((0, 1, 2, 3)))
    facts = {"low_notes": {"low_notes": max(2, notes)},
             "silence": {"days_without_data": rnd.choice((3, 4)), "other_contact": True},
             "slower_reactions": {"max_z": rnd.choice((2.0, 2.5, 3.0)), "of_last": 3,
                                  "slower_sessions": 2},
             "face_flat": {"flat_sessions": 2, "of_last": 3},
             "novelty": {"direction": "down", "metric": "steps"},
             "weak_rounds": {"rounds": 2}}
    other_level = {"low_notes": "attention", "silence": "watch", "slower_reactions": "attention",
                   "face_flat": "attention", "novelty": "watch", "weak_rounds": "attention"}
    other_held = {k: rnd.choice((0, 1, 2, 3)) for k in OTHERS}
    usual = [half(rnd.uniform(-0.6, 0.6)) for _ in range(14)]
    sessions, checkins = rnd.choice((2, 4, 6)), rnd.choice((0, 2, 4))
    if worse:
        low_days, depth, held, notes = 5, depth - 1.0, held + 3, notes + 2
        if "low_notes" in kinds:
            facts["low_notes"] = {"low_notes": facts["low_notes"]["low_notes"] + 2}
    movement = usual[:14 - low_days] + [half(depth)] * low_days
    rows = [{"kind": "deviation", "held_days": held,
             "rules_level": deviation_level(low_days, depth, held),
             "facts": {"low_days": low_days, "mean_low_z": depth}}]
    rows += [{"kind": k, "held_days": other_held[k] + (3 if worse else 0),
              "rules_level": other_level[k], "facts": facts[k]} for k in kinds]
    rows.sort(key=lambda r: r["kind"])
    for i, r in enumerate(rows, 1):
        r["ref"] = f"a{i}"
    return {"items": [{k: r[k] for k in ("ref", "kind", "held_days", "rules_level", "facts")}
                      for r in rows],
            "movement": movement, "notes_low": notes, "sessions_7d": sessions,
            "checkins_7d": checkins, "reasons": list(INPUT_GATE.TRIAGE_REASONS)}


async def read(local, outreach, payload: dict, rule: bool = False) -> dict | None:
    """Both levels on one picture, through the engine's gates. Returns
    {kind: {"asked": level the models asked for, "level": after the floors,
    "rules_level", "rule": level 1 named the clinic rule}} or None when level 1
    did not answer in the form."""
    body = dict(payload)
    if rule:
        body["clinic_rules"] = [{"ref": "r1", "text": RULE}]
    refs = {it["ref"]: it["ref"] for it in body["items"]}
    rules = {it["ref"]: it["rules_level"] for it in body["items"]}
    kinds = {it["ref"]: it["kind"] for it in body["items"]}
    pack1 = INPUT_GATE.triage_pack(body, refs, 1)
    res1 = OUTPUT_GATE.triage(await local.complete(pack1, json_mode=True, max_tokens=900), pack1)
    if not res1.ok or len(res1.value) != len(refs):
        return None
    first = res1.value
    shown = [{"ref": r, "level": first[r]["level"], "reason": first[r]["reason"]} for r in refs]
    pack2 = INPUT_GATE.triage_pack(body, refs, 2, shown)
    res2 = OUTPUT_GATE.triage(await outreach.gemini_complete(pack2), pack2, second=True)
    second = res2.value if res2.ok else {}
    out = combine(refs, rules, kinds, first, second, {"r1": "rule"})
    got = {}
    for ref, d in out.items():
        asked = LEVELS.index(d["level1"])
        if d["verdict2"] and not d["clinic_rule_id"]:
            asked = max(0, min(2, asked + {"agree": 0, "raise": 1, "lower": -1}[d["verdict2"]]))
        got[kinds[ref]] = {"asked": LEVELS[asked], "level": d["level"],
                           "rules_level": d["rules_level"], "rule": bool(d["clinic_rule_id"]),
                           "second": d["verdict2"]}
    return got


async def run(pictures: int, seed: int) -> dict:
    from .config import Settings
    from .llm.local import LocalModel
    from .outreach import Outreach
    settings = Settings.from_env()
    local, outreach = LocalModel(settings), Outreach(settings)
    if not getattr(local, "configured", False) or not outreach.gemini_on:
        raise SystemExit("both model levels must be configured")
    out = {"pictures": pictures, "first_seed": seed, "generated": True,
           "models": {"level1": settings.local_llm_model, "level2": outreach.level2_model},
           "worse": {"pairs_read": 0, "pairs_not_read": 0, "flags": 0,
                     "lower_as_asked": 0, "lower_after_floors": 0,
                     "second_reader_answered": 0, "differs_from_rules": 0, "cases": []},
           "rule": {"pictures_read": 0, "pictures_not_read": 0, "rule_followed": 0,
                    "other_flags": 0, "other_flags_moved_as_asked": 0,
                    "other_flags_moved_after_floors": 0, "cases": []}}
    w, r = out["worse"], out["rule"]
    for k in range(pictures):
        base_p, worse_p = make_picture(seed + k), make_picture(seed + k, worse=True)
        base, worse = await read(local, outreach, base_p), await read(local, outreach, worse_p)
        if base is None or worse is None:
            w["pairs_not_read"] += 1
        else:
            w["pairs_read"] += 1
            for kind, b in base.items():
                x = worse[kind]
                w["flags"] += 1
                w["second_reader_answered"] += b["second"] is not None
                w["differs_from_rules"] += b["level"] != b["rules_level"]
                asked = LEVELS.index(x["asked"]) < LEVELS.index(b["asked"])
                after = LEVELS.index(x["level"]) < LEVELS.index(b["level"])
                w["lower_as_asked"] += asked
                w["lower_after_floors"] += after
                if asked or after:
                    w["cases"].append({"seed": seed + k, "kind": kind, "as_it_is": b, "worse": x})
        if k % 2 == 0 and base is not None:
            ruled = await read(local, outreach, base_p, rule=True)
            if ruled is None:
                r["pictures_not_read"] += 1
                continue
            r["pictures_read"] += 1
            r["rule_followed"] += ruled["deviation"]["rule"]
            for kind, b in base.items():
                if kind == "deviation":
                    continue
                x = ruled[kind]
                r["other_flags"] += 1
                r["other_flags_moved_as_asked"] += x["asked"] != b["asked"]
                r["other_flags_moved_after_floors"] += x["level"] != b["level"]
                if x["level"] != b["level"] or x["asked"] != b["asked"]:
                    r["cases"].append({"seed": seed + k, "kind": kind, "without_rule": b,
                                       "with_rule": x})
        print(f"picture {k + 1}/{pictures}", flush=True)
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--pictures", type=int, default=40)
    ap.add_argument("--seed", type=int, default=7000)
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    res = asyncio.run(run(a.pictures, a.seed))
    text = json.dumps(res, indent=1)
    if a.out:
        with open(a.out, "w") as f:
            f.write(text + "\n")
    print(json.dumps({k: {x: y for x, y in v.items() if x != "cases"} if isinstance(v, dict) else v
                      for k, v in res.items()}, indent=1))


if __name__ == "__main__":
    main()
