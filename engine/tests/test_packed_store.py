"""The packed layout answers exactly like a plain store, and takes in older single records."""
import random

from clinic_engine.store import MemoryStore, PackedStore

P = "clinics/c1/patients/p1/"


def keys_for(n):
    out = [P + "patient.json", "patients/p1.json", P + "mind/state.json", P + "mind/reviews/r1.json"]
    out += [P + f"days/2026-11-{d:02d}.json" for d in range(1, 9)]
    out += [P + f"activities/act-{i:03d}.json" for i in range(n)]
    out += [P + f"audit/202611{d:02d}T101500{i:06d}-ab{i}.json" for d in (12, 13) for i in range(4)]
    out += [P + f"trace/202611{d:02d}T101500{i:06d}-{i:09d}.json" for d in (13, 14) for i in range(3)]
    out += ["clinics/c1/patients/p2/days/2026-11-01.json", "clinics/c1/audit/20261113T1-x.json"]
    return out


def test_same_answers_as_a_plain_store_through_random_operations():
    rng = random.Random(4)
    plain, packed = MemoryStore(), PackedStore(MemoryStore())
    keys = keys_for(12)
    for step in range(600):
        k = rng.choice(keys)
        op = rng.random()
        if op < 0.55:
            doc = {"k": k, "v": step}
            plain.put(k, doc), packed.put(k, doc)
        elif op < 0.7:
            plain.delete(k), packed.delete(k)
        else:
            assert plain.get(k) == packed.get(k)
        if step % 40 == 0:
            for prefix in ("", "clinics/", P, P + "days/", P + "days/2026-11-0", P + "audit/",
                           P + "audit/20261113", P + "trace/", P + "activities/act-00", "patients/"):
                assert plain.list(prefix) == packed.list(prefix), prefix
                assert plain.list_docs(prefix) == packed.list_docs(prefix), prefix
    assert plain.delete_prefix(P + "activities/") == packed.delete_prefix(P + "activities/")
    assert plain.delete_prefix(P + "audit/") == packed.delete_prefix(P + "audit/")
    assert plain.list("") == packed.list("")


def test_records_from_before_packs_are_taken_in_and_nothing_is_lost():
    inner = MemoryStore()
    keys = keys_for(5)
    for i, k in enumerate(keys):
        inner.put(k, {"n": i})
    packed = PackedStore(inner)
    assert packed.list("") == sorted(keys)
    assert [packed.get(k)["n"] for k in keys] == list(range(len(keys)))
    raw = inner.list("")
    assert P + "days.pack.json" in raw and P + "audit/20261112.pack.json" in raw
    assert not [k for k in raw if "/days/" in k or "/activities/" in k]  # singles are gone
    assert P + "patient.json" in raw and P + "mind/state.json" in raw  # not packed
    # a second process on the same store sees a write at once: nothing is held in memory
    other = PackedStore(inner)
    packed.put(P + "days/2026-11-20.json", {"n": 99})
    assert other.get(P + "days/2026-11-20.json") == {"n": 99}
    got = packed.get_many([P + "days/2026-11-01.json", P + "days/2026-11-02.json"])
    got[0]["n"] = -1
    assert packed.get(P + "days/2026-11-01.json")["n"] != -1
