"""How the rule behind "less facial movement" behaves, on GENERATED numbers.

    python -m clinic_engine.fine_flat_check [--runs 5000] [--spread 0.6]

The rule (mind/activities.fine_recent, thresholds.fine_flat_z) compares the
middle reach of a person's last five sessions with their own usual. This file
draws people whose reach differs from session to session by `spread` on its
logarithm (0.6 is what ten real games of one person showed on 14 November
2026), lets the reach of the last five drop to a set share, and counts how
often the rule speaks up. A share of 1 is a person who has not changed.

No face was recorded for this. It says what the rule does with numbers of a
known spread, not whether the reach of a real face falls when a person is
worse, which nobody has measured.
"""

from __future__ import annotations

import argparse
import json
import math
import random

from .mind.activities import fine_recent
from .mind.thresholds import T

SHARES = (1.0, 0.75, 0.5, 0.35, 0.2)


def _session(reach: float) -> dict:
    return {"face_fine": {"quality": "good", "asymmetry": {},
                          "regions": {"mouth_left": {"reach_mm": reach, "speed_mm_s": 0.0,
                                                     "twitches_per_min": 0.0}}}}


def run(runs: int = 5000, spread: float = 0.6, earlier: int = 10, seed: int = 15) -> dict:
    rng = random.Random(seed)
    out = {}
    for share in SHARES:
        hits = 0
        for _ in range(runs):
            before = [_session(0.5 * math.exp(rng.gauss(0, spread))) for _ in range(earlier)]
            last = [_session(0.5 * share * math.exp(rng.gauss(0, spread)))
                    for _ in range(T.fine_flat_window)]
            r = fine_recent(before + last, T)
            hits += r is not None and r["z"] <= T.fine_flat_z
        out[str(share)] = round(100 * hits / runs, 1)
    return {"generated_only": True, "runs": runs, "spread_ln": spread, "earlier_sessions": earlier,
            "window": T.fine_flat_window, "needed_z": T.fine_flat_z,
            "flagged_percent_by_share_of_usual_reach": out}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--runs", type=int, default=5000)
    ap.add_argument("--spread", type=float, default=0.6)
    a = ap.parse_args()
    print(json.dumps(run(a.runs, a.spread), indent=2))


if __name__ == "__main__":
    main()
