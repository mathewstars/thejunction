"""What the fine movement measure (docs/face-fine.md) can and cannot do, on
GENERATED streams only.

    python -m clinic_engine.fine_check [--runs 400] [--out FILE.json]

No face was recorded for any of this. The streams are made by this file and by
fine_reference; the results say how the rule and the comparison behave on a
known signal. They say nothing about what a real face does, how noisy the real
sensor is, or whether any of it relates to how a person is.

Questions, each one a thing the first device experiment has to know:

1. How small a brief movement can the rule find at a given noise? Movements of
   a set size are planted in streams shaped like the app's (30 a second) and
   the share found is counted. The planted movement holds its top like a
   block; `shape` repeats part of it with a movement that rises and falls
   smoothly, by its length. A report that overlaps a planted movement too
   little counts as not found ("misplaced" in the output).
2. What does the rule report when nothing was planted? With the kindest noise
   (independent from frame to frame, its size told to the rule exactly), with
   noise that is smooth from frame to frame, and with a stated noise that is
   too small.
3. If a person does not change, how often does one session still look like
   "half the usual or less"? If their true rate of brief movements halves, how
   many sessions does it take to see it? Counts are drawn as if every movement
   came independently at a rate that never changes (Poisson), and again with a
   rate that differs from session to session (gamma-Poisson, shape 3), which
   is the more likely case. The rates themselves (2 to 16 a session) are
   assumptions: nobody has measured one.
4. What a step does (the phone shifts in the hand and every region moves to a
   new level): the weakness already known from fine_reference.

Not simulated, on purpose: how far a region reaches and how fast it moves from
session to session in one person. Nothing is known about that variation, and a
made-up number would decide the answer. Also not simulated: slow drift, a
short jolt of the whole face, blinks, and movements of 0.4 to 1.5 seconds.
"""

from __future__ import annotations

import argparse
import json
import math
import random

from . import fine_reference
from .mind import face_fine

RATE, SECONDS = 30, 45
REGIONS = ["mouth_left", "mouth_right", "cheek_left", "cheek_right", "brow_left", "brow_right"]
SIZES_MM = (0.3, 0.5, 0.75, 1.0, 1.5, 2.0)
NOISES_MM = (0.05, 0.1, 0.2, 0.3, 0.5)
PER_STREAM = 6   # planted movements per stream
APP_REGIONS = 12  # the app sends twelve regions; false reports are given per session of that size


def _stream(rng: random.Random, size: float, noise: float, shape: str = "block",
            frames: int | None = None, smooth: float = 0.0,
            stated: float | None = None) -> tuple[dict, list[dict]]:
    """`smooth` is how much of one frame's noise carries into the next (0: none);
    the spread of the noise stays `noise`. `stated` is the noise the rule is told."""
    n = RATE * SECONDS
    rest = [rng.uniform(0.15, 0.35) for _ in REGIONS]
    rows = [[0.0] * len(REGIONS) for _ in range(n)]
    for j in range(len(REGIONS)):
        e = rng.gauss(0, noise)
        for i in range(n):
            e = smooth * e + math.sqrt(1 - smooth * smooth) * rng.gauss(0, noise)
            rows[i][j] = rest[j] + e
    truth = []
    power = 0.5 if shape == "block" else 2.0
    for k in range(PER_STREAM if size > 0 else 0):
        j = rng.randrange(len(REGIONS))
        i0 = int((3 + 6.5 * k + rng.uniform(0, 3)) * RATE)   # well apart in time
        i1 = i0 + (frames or rng.randint(3, 9))                # 0.1 to 0.3 s
        for i in range(i0, i1):
            rows[i][j] += size * math.sin(math.pi * (i - i0 + 0.5) / (i1 - i0)) ** power
        truth.append({"region": REGIONS[j], "start_s": i0 / RATE, "end_s": i1 / RATE})
    raw = {"source": "mesh", "rate_hz": RATE, "regions": list(REGIONS),
           "noise_mm": noise if stated is None else stated,
           "samples": [[round(max(0.0, v), 2) for v in r] for r in rows]}
    return raw, truth


def _found(rng: random.Random, runs: int, size: float, noise: float, **kw) -> dict:
    planted = found = extra = 0
    for _ in range(runs):
        raw, truth = _stream(rng, size, noise, **kw)
        s = fine_reference.score(face_fine.twitches(raw), truth)
        planted += s["planted"]; found += s["found"]; extra += s["extra"]
    return {"noise_mm": noise, "size_mm": size, "planted": planted,
            "found_share": round(found / planted, 3),
            "misplaced_per_planted": round(extra / planted, 3)}


def size_against_noise(runs: int, seed: int = 7) -> list[dict]:
    rng = random.Random(seed)
    out = [_found(rng, runs, size, noise) for noise in NOISES_MM for size in SIZES_MM]
    out += [_found(rng, runs, size, 1.0) for size in (2.0, 3.0, 4.0, 5.0)]
    return out


def shape(runs: int, seed: int = 9) -> list[dict]:
    """A movement that rises and falls smoothly (sin squared), by its length."""
    rng = random.Random(seed)
    out = []
    for noise, size in ((0.1, 0.75), (0.1, 1.0), (0.1, 2.0), (0.2, 1.0), (0.2, 2.0)):
        for frames in (3, 5, 7, 9):
            r = _found(rng, runs // 2, size, noise, shape="round", frames=frames)
            out.append({**r, "frames": frames, "seconds": round(frames / RATE, 2)})
    return out


def from_noise(runs: int, seed: int = 8) -> list[dict]:
    """Nothing planted: what the rule reports, per 45-second session of twelve regions."""
    rng = random.Random(seed)
    kinds = [("independent, size told exactly", n, 0.0, None) for n in NOISES_MM]
    kinds += [("smooth from frame to frame (0.7), size told exactly", n, 0.7, None) for n in (0.1, 0.2, 0.3)]
    kinds += [("smooth from frame to frame (0.9), size told exactly", 0.2, 0.9, None),
              ("independent, told two thirds of its size", 0.3, 0.0, 0.2),
              ("independent, told half its size", 0.3, 0.0, 0.15),
              ("independent, nothing told (the rule then assumes 0.3)", 0.5, 0.0, 0.3)]
    out = []
    for name, noise, smooth, stated in kinds:
        count = sum(len(face_fine.twitches(_stream(rng, 0.0, noise, smooth=smooth, stated=stated)[0]))
                    for _ in range(runs))
        out.append({"noise": name, "noise_mm": noise, "stated_mm": noise if stated is None else stated,
                    "per_session_of_twelve_regions": round(count / runs * APP_REGIONS / len(REGIONS), 2)})
    return out


def _poisson(rng: random.Random, lam: float) -> int:
    limit, k, p = math.exp(-lam), 0, 1.0
    while True:
        p *= rng.random()
        if p <= limit:
            return k
        k += 1


def _binom_tail(k: int, n: int) -> float:
    """P(X <= k) for X ~ Binomial(n, 1/2)."""
    return sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n


def chance_and_power(runs: int, seed: int = 11) -> dict:
    """Counts of brief movements per session. `per_session` is the person's
    true mean count in one session. `varies`: False is Poisson; True lets the
    rate itself differ from session to session (gamma, shape 3: a spread of
    about 58 % of the rate), on top of the Poisson scatter."""
    rng = random.Random(seed)

    def draw(lam: float, varies: bool) -> int:
        return _poisson(rng, rng.gammavariate(3.0, lam / 3.0) if varies else lam)

    out = {"one_session_half_or_less": [], "sessions_to_see_a_halving": []}
    for varies in (False, True):
        for lam in (2.0, 4.0, 8.0, 16.0):
            for earlier in (3, 5):
                same = halved = n = 0
                for _ in range(runs * 25):
                    before = sorted(draw(lam, varies) for _ in range(earlier))
                    usual = before[earlier // 2]
                    if usual == 0:
                        continue
                    n += 1
                    same += draw(lam, varies) <= usual / 2
                    halved += draw(lam / 2, varies) <= usual / 2
                out["one_session_half_or_less"].append(
                    {"rate_varies": varies, "per_session": lam, "earlier_sessions": earlier,
                     "unchanged_person": round(same / n, 3), "rate_truly_halved": round(halved / n, 3)})
            for each_side in (3, 5, 10, 20, 40):
                hit = false = hit2 = 0
                trials = runs * 10
                for _ in range(trials):
                    a = sum(draw(lam, varies) for _ in range(each_side))
                    b = sum(draw(lam / 2, varies) for _ in range(each_side))
                    c = sum(draw(lam, varies) for _ in range(each_side))
                    hit += (a + b) > 0 and _binom_tail(b, a + b) < 0.05
                    hit2 += (a + b) > 0 and _binom_tail(min(a, b), a + b) < 0.025
                    false += (a + c) > 0 and _binom_tail(c, a + c) < 0.05
                out["sessions_to_see_a_halving"].append(
                    {"rate_varies": varies, "per_session": lam, "sessions_each_side": each_side,
                     "seen_when_halved": round(hit / trials, 3),
                     "seen_when_halved_looking_both_ways": round(hit2 / trials, 3),
                     "said_when_unchanged": round(false / trials, 3)})
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--runs", type=int, default=400)
    ap.add_argument("--out")
    a = ap.parse_args()
    res = {"generated_only": True, "rules_version": face_fine.RULES_VERSION, "runs": a.runs,
           "rate_hz": RATE, "seconds": SECONDS,
           "size_against_noise": size_against_noise(a.runs),
           "shape": shape(a.runs),
           "from_noise": from_noise(a.runs),
           "counts": chance_and_power(a.runs),
           "hard_kinds": fine_reference.run()}
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            json.dump(res, f, indent=1)
    print("found share, block-shaped movement (noise mm / size mm)")
    for r in res["size_against_noise"]:
        print(f"  {r['noise_mm']:4g} / {r['size_mm']:4g}: {r['found_share']:.2f}  misplaced {r['misplaced_per_planted']:.3f}")
    print("found share, smooth movement by length")
    for r in res["shape"]:
        print(f"  {r['noise_mm']:4g} / {r['size_mm']:4g}, {r['seconds']} s: {r['found_share']:.2f}")
    print("nothing planted: reported per 45 s session of twelve regions")
    for r in res["from_noise"]:
        print(f"  {r['noise_mm']:4g} mm, {r['noise']}: {r['per_session_of_twelve_regions']}")
    for r in res["counts"]["one_session_half_or_less"]:
        print(f"  {'varies' if r['rate_varies'] else 'poisson'} {r['per_session']:g}/session, usual of {r['earlier_sessions']}: "
              f"half or less {r['unchanged_person']:.0%} unchanged, {r['rate_truly_halved']:.0%} halved")
    for r in res["counts"]["sessions_to_see_a_halving"]:
        print(f"  {'varies' if r['rate_varies'] else 'poisson'} {r['per_session']:g}/session, {r['sessions_each_side']} each side: "
              f"seen {r['seen_when_halved']:.0%} (both ways {r['seen_when_halved_looking_both_ways']:.0%}), "
              f"said when unchanged {r['said_when_unchanged']:.0%}")
    print("  hard kinds:", res["hard_kinds"])


if __name__ == "__main__":
    main()
