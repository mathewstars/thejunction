"""Reads for the clinician page: side by side in S3, and once per request."""
import io
import json

from clinic_engine.mind.repo import PatientRepo
from clinic_engine.store import MemoryStore, S3Store


class FakeS3:
    class exceptions:
        class NoSuchKey(Exception):
            pass

    def __init__(self, objs):
        self.objs = objs

    def get_object(self, Bucket, Key):
        if Key not in self.objs:
            raise self.exceptions.NoSuchKey()
        return {"Body": io.BytesIO(json.dumps(self.objs[Key]).encode())}


def test_get_many_keeps_the_order_and_reports_missing_keys():
    objs = {f"a/{n:03d}.json": {"n": n} for n in range(60)}
    st = S3Store("http://x", "b", "k", "s", client=FakeS3(objs))
    keys = sorted(objs) + ["a/none.json"]
    got = st.get_many(keys)
    assert [d["n"] for d in got[:-1]] == list(range(60)) and got[-1] is None


def test_snapshot_reads_a_folder_once_and_forgets_on_write():
    class Counting(MemoryStore):
        lists = 0

        def list(self, prefix):
            Counting.lists += 1
            return super().list(prefix)

    st = Counting()
    repo = PatientRepo(st, "c", "p")
    repo.put("days/2026-11-01.json", {"date": "2026-11-01", "steps": 1})
    snap = repo.snapshot()
    first = snap.days()
    first["2026-11-01"]["steps"] = 99  # a caller's change stays with the caller
    n = Counting.lists
    assert snap.days()["2026-11-01"]["steps"] == 1 and Counting.lists == n
    snap.put("days/2026-11-02.json", {"date": "2026-11-02", "steps": 2})
    assert len(snap.days()) == 2 and snap.snapshot() is snap
