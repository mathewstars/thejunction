"""Compute the fine movement summaries again from the stored streams.

    python -m clinic_engine.fine_resummarize [--all]

The stream of every session is kept as its own object so that this can be done
when the rules in mind/face_fine.py change. Without --all only summaries made
by an older rules version are done again. Nothing else on the record changes,
and nothing is judged from the summary (research only, docs/face-fine.md).
"""

from __future__ import annotations

import argparse

from .config import Settings
from .mind import face_fine
from .store import make_store


def run(mind, store, every: bool = False) -> dict:
    done = same = missing = 0
    for key in store.list("clinics/"):
        if not key.endswith("/patient.json"):
            continue
        parts = key.split("/")           # clinics/{c}/patients/{p}/patient.json
        repo = mind.repo(parts[1], parts[3])
        for a in repo.activities():
            if not a.get("face_fine"):
                continue
            if not every and a["face_fine"].get("rules") == face_fine.RULES_VERSION:
                same += 1
                continue
            stream = repo.get(f"facefine/{a['id']}.json")
            if not stream:
                missing += 1
                continue
            cur = repo.get(f"activities/{a['id']}.json")
            cur.update(face_fine=face_fine.summarize(stream), face_fine_info=face_fine.describe(stream))
            repo.put(f"activities/{a['id']}.json", cur)
            done += 1
    return {"done_again": done, "already_current": same, "stream_missing": missing,
            "rules_version": face_fine.RULES_VERSION}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--all", action="store_true", help="also summaries already on the current rules")
    a = ap.parse_args()
    from .app import create_app
    settings = Settings.from_env()
    store = make_store(settings)
    mind = create_app(settings=settings, store=store, start_ticker=False).state.ctx.mind
    print(run(mind, store, every=a.all))


if __name__ == "__main__":
    main()
