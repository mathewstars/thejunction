"""Fine facial movement (research only): the phone sends millimetres per
region and frame, computed on the phone from the TrueDepth mesh or depth map.
The server checks the stream, keeps it as its own object, puts a summary of
movement on the activity record, and uses it for nothing else."""

import json
import math
import random
from datetime import timedelta

from clinic_engine.mind import face_fine

from conftest import NOW

REGIONS = ["mouth_left", "mouth_right", "brow_left", "brow_right"]


def make_fine(seconds=45, rate=60, twitches=(), smile=None, noise=0.05, seed=3, regions=REGIONS):
    """A synthetic stream: every region rests near 0.2 mm with a little noise.
    `twitches` are (region index, at second, height mm), each 0.15 s long;
    `smile` is (at second, seconds long, left mm, right mm), a slow movement."""
    rng = random.Random(seed)
    n = int(seconds * rate)
    rows = [[max(0.0, 0.2 + rng.gauss(0, noise)) for _ in regions] for _ in range(n)]
    for j, at, height in twitches:
        for i in range(int(at * rate), int((at + 0.15) * rate)):
            rows[i][j] += height
    if smile:
        at, long, left, right = smile
        for i in range(int(at * rate), int((at + long) * rate)):
            k = math.sin(math.pi * (i / rate - at) / long)
            rows[i][0] += left * k
            rows[i][1] += right * k
    return {"source": "mesh", "rate_hz": rate, "regions": list(regions),
            "samples": [[round(v, 3) for v in r] for r in rows], "noise_mm": noise}


def focus_fine(aid, fine=None, **kw):
    rec = {"id": aid, "type": "focus", "started_at": (NOW - timedelta(minutes=30)).isoformat(),
           "duration_s": 45.0, "completed": True, "ended_by": "finished",
           "correct_taps": 17, "wrong_taps": 0, "misses": 2,
           "reaction_ms": [500 + 7 * i for i in range(17)],
           "face_fine": fine if fine is not None else make_fine()}
    rec.update(kw)
    return rec


def post(env, rec):
    return env.client.post("/v1/activities", headers=env.H, json=rec)


# ---- the summary -------------------------------------------------------------------------

def test_a_still_face_has_no_twitches_and_little_reach():
    s = face_fine.summarize(make_fine())
    assert s["quality"] == "good" and s["rules"] == face_fine.RULES_VERSION
    for name in REGIONS:
        r = s["regions"][name]
        assert r["twitches_per_min"] == 0 and r["reach_mm"] < 0.2
        assert 0.15 < r["level_mm"] < 0.25


def test_planted_twitches_are_counted_on_their_region_only():
    fine = make_fine(twitches=[(0, 5, 1.5), (0, 20, 1.2), (0, 33, 2.0), (2, 12, 1.4)])
    s = face_fine.summarize(fine)
    assert s["regions"]["mouth_left"]["twitches_per_min"] == 4.0   # 3 in 45 s
    assert s["regions"]["brow_left"]["twitches_per_min"] == 1.33   # 1 in 45 s
    assert s["regions"]["mouth_right"]["twitches_per_min"] == 0
    assert s["regions"]["brow_right"]["twitches_per_min"] == 0


def test_a_slow_movement_is_not_a_twitch_and_one_side_shows_as_asymmetry():
    s = face_fine.summarize(make_fine(smile=(10, 6, 3.0, 0.6)))
    assert s["regions"]["mouth_left"]["twitches_per_min"] == 0
    assert s["regions"]["mouth_left"]["reach_mm"] > s["regions"]["mouth_right"]["reach_mm"] > 0
    assert 0.4 < s["asymmetry"]["mouth"] < 1
    assert abs(s["asymmetry"]["brow"]) < 0.5


def test_too_little_tracked_time_gives_nulls_and_noise_is_named():
    fine = make_fine(seconds=20)
    fine["tracked"] = [1] * 100 + [0] * (len(fine["samples"]) - 100)   # under 2 s tracked
    s = face_fine.summarize(fine)
    assert s["quality"] == "short" and all(v is None for v in s["regions"].values())
    # The noise is read from the stream itself, whatever the phone states.
    rng = random.Random(4)
    loud = make_fine()
    loud["samples"] = [[round(6 + rng.gauss(0, 1.5), 3) for _ in r] for r in loud["samples"]]
    loud["noise_mm"] = 0.05
    s = face_fine.summarize(loud)
    assert s["quality"] == "noisy" and 1.2 < s["noise_mm"] < 1.8 and s["noise_stated_mm"] == 0.05
    quiet = make_fine(noise=0.05)
    quiet["noise_mm"] = 1.9          # what the first real games stated
    s = face_fine.summarize(quiet)
    assert s["quality"] == "good" and s["noise_mm"] < 0.1 and s["noise_stated_mm"] == 1.9


def test_check_names_positions_only():
    fine = make_fine(seconds=6)
    assert face_fine.check(fine) is None
    bad = {**fine, "regions": ["mouth_left", "mouth_right", "brow_left", "nostril"]}
    assert face_fine.check(bad).startswith("regions[3]")
    assert "nostril" not in face_fine.check(bad)
    assert face_fine.check({**fine, "regions": ["brow_left", "brow_right", "jaw", "nose"]}) \
        == "regions must include mouth_left, mouth_right"
    rows = [list(r) for r in fine["samples"]]
    rows[4][1] = 80.0
    assert face_fine.check({**fine, "samples": rows}).startswith("samples[4][1]")
    assert face_fine.check({**fine, "tracked": [1, 1]}) == "tracked must have one value per sample"


# ---- through the API ---------------------------------------------------------------------

def test_fine_stream_is_stored_apart_and_summarised_on_the_record(env):
    fine = make_fine(twitches=[(0, 5, 1.5)])
    assert post(env, focus_fine("act-fine-000001", fine)).status_code == 200
    stored = env.repo().get("activities/act-fine-000001.json")
    assert stored["face_fine"] == face_fine.summarize(fine)
    assert stored["face_fine_info"] == {"source": "mesh", "rate_hz": 60, "frames": 2700,
                                        "tracked_share": 1.0, "regions": 4}
    assert "samples" not in json.dumps(stored["face_fine"])
    obj = env.repo().get("facefine/act-fine-000001.json")
    assert obj["samples"] == fine["samples"] and obj["frames"] == 2700
    # It changes nothing else: no face summary, no face quality from it.
    assert stored.get("face") is None and stored.get("face_source") is None


def test_the_same_record_again_is_idempotent_and_without_it_nothing_changes(env):
    rec = focus_fine("act-fine-000002")
    assert post(env, rec).status_code == 200
    assert post(env, rec).status_code == 200
    plain = focus_fine("act-fine-000003")
    del plain["face_fine"]
    assert post(env, plain).status_code == 200
    stored = env.repo().get("activities/act-fine-000003.json")
    assert "face_fine" not in stored and "face_fine_info" not in stored
    assert env.repo().get("facefine/act-fine-000003.json") is None


def test_values_that_cannot_be_true_are_refused(env):
    bad = make_fine(seconds=6)
    bad["samples"][3][0] = 99.0
    assert post(env, focus_fine("act-fine-000004", bad)).status_code == 422
    assert post(env, focus_fine("act-fine-000005", {**make_fine(seconds=6), "mesh": [[1, 2, 3]]})
                ).status_code == 422                       # no extra fields: no geometry gets in
    long = focus_fine("act-fine-000006", make_fine(seconds=120))   # far longer than the activity
    assert post(env, long).status_code == 422


def test_clinician_download_is_scoped_and_audited(env):
    fine = make_fine()
    assert post(env, focus_fine("act-fine-000007", fine)).status_code == 200
    C, pid = env.C(), env.demo["patient_id"]
    url = f"/v1/clinic/patients/{pid}/activities/act-fine-000007/face-fine"
    r = env.client.get(url, headers=C)
    assert r.status_code == 200
    body = r.json()
    assert body["stream"]["samples"] == fine["samples"]
    assert body["summary"] == face_fine.summarize(fine) and body["info"]["frames"] == 2700
    reads = [a for a in env.audit() if a["action"] == "face_fine_read"]
    assert reads and reads[-1]["detail"] == {"activity_id": "act-fine-000007"}
    assert env.client.get(url, headers=env.H).status_code == 403   # the device may not read it
    assert env.client.get(url).status_code == 401
    other = f"/v1/clinic/patients/{pid}/activities/act-fine-000099/face-fine"
    assert env.client.get(other, headers=C).status_code == 404


def test_fine_and_raw_can_come_together(env):
    from face_synth import make_raw
    rec = focus_fine("act-fine-000008")
    rec["face_raw"] = make_raw(seconds=45, smiles=[(8, 1.2, 0.55, 0.45, 0.3)],
                               blinks=[(s, 0.1) for s in range(2, 45, 4)], seed=5)
    assert post(env, rec).status_code == 200
    stored = env.repo().get("activities/act-fine-000008.json")
    assert stored["face_source"] == "raw" and stored["face_fine"]["quality"] == "good"


# ---- the workbench for the detection work (fine_reference) ---------------------------------

def test_code_finds_the_planted_movements_and_reports_nothing_else():
    from clinic_engine import fine_reference as R
    res = R.run(sessions=10)
    assert res["clean"]["missed"] == 0 and res["clean"]["extra"] == 0
    # Slow expressions and a higher noise floor do not become brief movements.
    assert res["expression"]["extra"] == 0 and res["noisy"]["extra"] == 0
    # After the phone shifts every region sits at a new level. The level is followed
    # over ten seconds, so the movements after the step are found and the step itself
    # is not reported. (Before rules version 4 nine of 28 were missed.)
    assert res["step"]["extra"] == 0 and res["step"]["missed"] == 0


def test_a_models_reply_is_checked_item_by_item():
    from clinic_engine import fine_reference as R
    raw, truth = R.make_session(1003)
    said = [{"region": t["region"], "start_s": t["start_s"], "end_s": t["end_s"]} for t in truth]
    reply = {"twitches": said + [{"region": "brow_left", "start_s": 40.0, "end_s": 40.2},
                                 {"region": "brow_left", "start_s": 90.0, "end_s": 90.2},
                                 {"region": "ear", "start_s": 1.0, "end_s": 1.1}]}
    v = R.verify(reply, raw)
    assert v["ok"] and v["confirmed"] == said and v["code_only"] == []
    assert [d["reason"] for d in v["dropped"]] == ["not_in_the_numbers", "outside_the_recording",
                                                   "not_the_asked_shape"]
    assert R.verify({"twitches": "none"}, raw)["ok"] is False
    assert R.verify({"twitches": []}, raw)["code_only"] == face_fine.twitches(raw)


def test_the_payload_holds_numbers_and_fixed_names_only():
    from clinic_engine import fine_reference as R
    raw, _ = R.make_session(1001)
    p = R.payload(raw)
    assert set(p) == {"rate_hz", "regions", "noise_mm", "frames"} and p["regions"] == raw["regions"]
    assert len(p["frames"]) == 900 and all(len(r) == 1 + len(raw["regions"]) for r in p["frames"])
    assert R.PROMPT.read_text("utf-8").startswith("DRAFT")


# ---- shown beside the person's own earlier sessions (the clinician page) -----------------

def test_the_top_of_a_slow_small_expression_is_not_a_brief_movement():
    # It crosses the line for under 0.4 s, but the whole rise lasts seconds.
    s = face_fine.summarize(make_fine(smile=(10, 3, 0.75, 0.75)))
    assert s["regions"]["mouth_left"]["twitches_per_min"] == 0


def test_own_usual_needs_three_earlier_sessions_and_is_their_middle():
    hs = [face_fine.headline(face_fine.summarize(make_fine(twitches=[(0, 5 + 3 * i, 1.5) for i in range(k)],
                                                           seed=k))) for k in (1, 2, 6)]
    assert [h["twitches_per_min"] for h in hs] == [1.33, 2.67, 8.0]
    assert face_fine.usual(hs[:2])["twitches_per_min"] is None
    assert face_fine.usual(hs)["twitches_per_min"] == 2.67
    short = make_fine(seconds=20)
    short["tracked"] = [0] * len(short["samples"])
    assert face_fine.headline(face_fine.summarize(short)) is None


def test_the_page_gets_each_session_beside_the_earlier_ones_and_never_the_stream(env):
    for k in range(4):
        rec = focus_fine(f"act-fine-own-{k:03d}", make_fine(twitches=[(0, 5, 1.5)] * (k > 2), seed=k),
                         started_at=(NOW - timedelta(days=4 - k, minutes=30)).isoformat())
        assert post(env, rec).status_code == 200
    r = env.client.get(f"/v1/clinic/patients/{env.demo['patient_id']}", headers=env.C())
    assert r.status_code == 200 and '"samples"' not in r.text
    mine = [s for s in r.json()["activities"]["focus"]["sessions"] if s["id"].startswith("act-fine-own-")]
    # The example person's own generated sessions come before these four.
    first = mine[0]["fine"]["earlier"]
    counts = [s["fine"]["earlier"] - first for s in mine]
    assert counts == sorted(counts) and len(set(counts)) == 4 and counts[-1] >= 3
    assert mine[3]["fine"]["values"]["twitches_per_min"] == 1.33 and mine[3]["fine"]["usual"]["twitches_per_min"] is not None
    assert mine[3]["fine"]["frames"] == 2700 and mine[3]["fine"]["source"] == "mesh"
    # The example person's generated sessions carry a fine stream too, kept like a real one.
    plain = [s for s in r.json()["activities"]["focus"]["sessions"] if not s["id"].startswith("act-fine-")]
    assert plain and all(s["fine"] and s["fine"]["values"] for s in plain)
    assert env.repo().get(f"facefine/{plain[0]['id']}.json")["samples"]


def test_the_example_person_has_generated_fine_movement_and_code_marks_it(env):
    from clinic_engine import seed_frames
    c = env.demo["clinic_id"]
    pid = seed_frames.create(env.store, c, "Europe/Helsinki", NOW)
    C = env.C()
    sessions = env.client.get(f"/v1/clinic/patients/{pid}", headers=C).json()["activities"]["focus"]["sessions"]
    assert len(sessions) == 6 and all(s["fine"]["regions"] == 14 and s["example"] for s in sessions)
    assert sessions[-1]["fine"]["values"]["reach_mm"] < sessions[-1]["fine"]["usual"]["reach_mm"]
    got = env.client.get(f"/v1/clinic/patients/{pid}/activities/{seed_frames.session_ids()[0]}/face-fine",
                         headers=C).json()
    assert got["stream"]["rate_hz"] == 30 and len(got["twitches"]) >= 3
    assert set(got["twitches"][0]) == {"region", "start_s", "end_s", "peak_mm"}


def test_a_partly_tracked_or_noisy_session_counts_toward_the_own_usual_with_its_label_shown(env):
    part = make_fine(seed=11)
    n = len(part["samples"])
    part["tracked"] = [not n // 2 <= i < n // 2 + n // 4 for i in range(n)]   # three quarters tracked
    rng = random.Random(12)
    loud = make_fine(seed=12)
    loud["samples"] = [[round(6 + rng.gauss(0, 1.5), 3) for _ in r] for r in loud["samples"]]
    streams = [make_fine(seed=10), part, loud, make_fine(seed=13)]
    for k, fine in enumerate(streams):
        rec = focus_fine(f"act-fine-cnt-{k:03d}", fine,
                         started_at=(NOW - timedelta(days=4 - k, minutes=50)).isoformat())
        assert post(env, rec).status_code == 200
    r = env.client.get(f"/v1/clinic/patients/{env.demo['patient_id']}", headers=env.C())
    mine = [s["fine"] for s in r.json()["activities"]["focus"]["sessions"] if s["id"].startswith("act-fine-cnt-")]
    assert [f["quality"] for f in mine] == ["good", "partly", "noisy", "good"]
    assert [f["counts"] for f in mine] == [True, True, True, True]
    assert all(f["values"] for f in mine)                      # each one is still shown
    assert mine[3]["earlier"] - mine[0]["earlier"] >= 3        # all three before it count

# ---- brief movements of the mouth corners ---------------------------------------------------

CORNER = ["mouth_left", "mouth_right", "mouth_corner_left", "mouth_corner_right",
          "cheek_left", "cheek_right", "brow_left", "brow_right"]


def test_mouth_corner_movements_are_named_by_side():
    # corner left alone at 5 s, corner right alone at 12 s, both corners together at 20 s
    fine = make_fine(regions=CORNER, twitches=[(2, 5, 1.5), (3, 12, 1.2), (2, 20, 1.4), (3, 20.03, 1.1)])
    mc = face_fine.mouth_corners(fine)
    assert mc["regions"] == ["mouth_corner_left", "mouth_corner_right"]
    assert [e["side"] for e in mc["events"]] == ["left", "right", "both"] and mc["whole_face_dropped"] == 0
    assert abs(mc["events"][0]["start_s"] - 5) < 0.05 and mc["events"][2]["peak_mm"] > 1.2
    s = face_fine.summarize(fine)["mouth_corners"]
    assert (s["left"], s["right"], s["both"], s["per_min"]) == (1, 1, 1, 4.0)


def test_a_jolt_of_the_whole_face_is_not_a_mouth_corner_movement():
    jolt = [(j, 15, 1.3) for j in range(len(CORNER))]            # every region at once
    fine = make_fine(regions=CORNER, twitches=[(2, 5, 1.5)] + jolt)
    mc = face_fine.mouth_corners(fine)
    assert [e["side"] for e in mc["events"]] == ["left"] and mc["whole_face_dropped"] == 1
    # One other region moving at the same moment is not the whole face.
    fine = make_fine(regions=CORNER, twitches=[(2, 5, 1.5), (6, 5, 1.5)])
    assert len(face_fine.mouth_corners(fine)["events"]) == 1


def test_without_corner_regions_the_mouth_halves_are_used_and_slow_smiles_are_not_counted():
    fine = make_fine(twitches=[(0, 5, 1.5)], smile=(20, 5, 3.0, 2.5))
    mc = face_fine.mouth_corners(fine)
    assert mc["regions"] == ["mouth_left", "mouth_right"]
    assert [e["side"] for e in mc["events"]] == ["left"]


def test_corner_regions_pass_the_api_and_reach_the_page(env):
    fine = make_fine(regions=CORNER, twitches=[(2, 5, 1.5), (3, 12, 1.2)])
    assert post(env, focus_fine("act-fine-corner-1", fine)).status_code == 200
    C, pid = env.C(), env.demo["patient_id"]
    got = env.client.get(f"/v1/clinic/patients/{pid}/activities/act-fine-corner-1/face-fine", headers=C).json()
    assert [e["side"] for e in got["mouth_corners"]["events"]] == ["left", "right"]
    sessions = env.client.get(f"/v1/clinic/patients/{pid}", headers=C).json()["activities"]["focus"]["sessions"]
    mine = [x for x in sessions if x["id"] == "act-fine-corner-1"][0]
    assert mine["fine"]["mouth_corners"]["left"] == 1 and mine["fine"]["mouth_corners"]["right"] == 1


def test_frames_just_after_tracking_returns_are_left_out_and_a_slow_creep_is_not_movement():
    raw = make_fine(seconds=40, rate=30, noise=0.02, seed=21)
    n = len(raw["samples"])
    raw["tracked"] = [not 300 <= i < 330 for i in range(n)]
    for i in range(330, 336):                       # the mesh jumps as tracking comes back
        raw["samples"][i] = [v + 4.0 for v in raw["samples"][i]]
    assert 331 not in face_fine.kept(raw) and 345 in face_fine.kept(raw)
    assert face_fine.twitches(raw) == []
    still = face_fine.summarize(raw)["regions"]["mouth_left"]["reach_mm"]
    creep = make_fine(seconds=40, rate=30, noise=0.02, seed=21)
    creep["samples"] = [[round(v + 1.5 * i / n, 3) for v in r] for i, r in enumerate(creep["samples"])]
    crept = face_fine.summarize(creep)["regions"]["mouth_left"]["reach_mm"]
    assert still < 0.1 and crept < 0.1              # 1.5 mm of creep adds no reach


def test_stored_summaries_can_be_made_again_from_the_kept_streams(env):
    from clinic_engine import fine_resummarize
    assert post(env, focus_fine("act-fine-again-01", make_fine(seed=31))).status_code == 200
    rec = env.repo().get("activities/act-fine-again-01.json")
    rec["face_fine"] = {**rec["face_fine"], "rules": 1, "quality": "noisy"}   # as an older version left it
    env.repo().put("activities/act-fine-again-01.json", rec)
    res = fine_resummarize.run(env.mind, env.store)
    assert res["done_again"] >= 1
    again = env.repo().get("activities/act-fine-again-01.json")["face_fine"]
    assert again["rules"] == face_fine.RULES_VERSION and again["quality"] == "good"


# ---- the reach decides "less facial movement" ----------------------------------------------

def test_the_rule_on_the_reach_behaves_as_the_page_says_on_generated_numbers():
    from clinic_engine import fine_flat_check
    res = fine_flat_check.run(runs=1500)["flagged_percent_by_share_of_usual_reach"]
    assert res["1.0"] < 8                      # an unchanged person: about 1 look in 20
    assert 30 < res["0.5"] < 60                # a halving: under half... and not nothing
    assert 60 < res["0.35"] < 85               # a drop to a third: about 7 of 10
    assert res["0.2"] > 90


def test_a_person_with_the_fine_stream_is_judged_by_its_reach_and_one_low_session_is_not_enough(env):
    from clinic_engine.mind.activities import fine_recent
    acts = env.repo().activities()
    assert any(a.get("fine_reach_mm") for a in acts)            # the example person sends the stream
    assert "face_flat" not in {i["kind"] for i in env.repo().items() if i["state"] == "open"}
    env.client.post("/v1/demo/scenario", headers=env.A, json={"name": "dip"})
    item = next(i for i in env.repo().items() if i["state"] == "open" and i["kind"] == "face_flat")
    d = item["detail"]
    assert d["from"] == "fine" and d["of_last"] == 5 and d["reach_mm"] < 0.5 * d["usual_mm"]
    r = fine_recent(env.repo().activities())
    assert r["z"] <= -2.5
    # The generated stream is kept beside the session and the summary comes from it.
    a = next(a for a in reversed(env.repo().activities()) if a.get("face_fine"))
    stream = env.repo().get(f"facefine/{a['id']}.json")
    assert face_fine.summarize(stream)["regions"] == a["face_fine"]["regions"]
