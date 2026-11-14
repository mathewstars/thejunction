"""Revontulet's measures on the focus record: accepted, checked, stored whole,
returned to the clinician, and nothing changes for a record without them."""

import copy
from datetime import timedelta

import pytest
from conftest import NOW, Env

ROUND_EASY = {"effort": "easy", "choice_ms": 2310, "trace_start_ms": 1840, "trace_ms": 1650, "trace_length_pt": 288.4,
              "trace_mean_speed_pt_s": 174.8, "trace_peak_speed_pt_s": 362.0, "trace_lifts": 0,
              "pull_pt": 96.5, "pull_hold_ms": 820, "embers_shown": 0, "embers_hit": 0,
              "bonus": False}
ROUND_HARD = {"effort": "hard", "choice_ms": 940, "trace_start_ms": 960, "trace_ms": 1220, "trace_length_pt": 279.3,
              "trace_mean_speed_pt_s": 228.9, "trace_peak_speed_pt_s": 455.0, "trace_lifts": 1,
              "pull_pt": 108.2, "pull_hold_ms": 540, "embers_shown": 2, "embers_hit": 1,
              "bonus": True}
MEASURES = {
    "rounds": [ROUND_EASY, ROUND_HARD, {**ROUND_HARD, "embers_hit": 2, "trace_lifts": 0}],
    "strokes": [{"ms": 1450, "length_pt": 410.0, "mean_speed_pt_s": 282.8},
                {"ms": 1720, "length_pt": 395.5, "mean_speed_pt_s": 229.9},
                {"ms": 1900, "length_pt": 402.1, "mean_speed_pt_s": 211.6}],
    "broke_through_s": 52.4, "fox_finished": False, "pt_per_cm": 64.2, "touch_radius_mean_pt": 21.3,
    "touch_radius_var": 4.7,
}


@pytest.fixture
def env():
    """The demo patient without the seeded example games (they are Revontulet
    games too), so every count of earlier games below is this file's own."""
    e = Env()
    base = f"clinics/{e.demo['clinic_id']}/patients/{e.demo['patient_id']}/activities/"
    for key in e.store.list(base):
        if (e.store.get(key) or {}).get("type") == "focus":
            e.store.delete(key)
    return e


def game(aid, measures=MEASURES, **kw):
    """A focus record shaped as the app sends a Revontulet game today
    (ActivityRouter.record): about 90 s, launches + embers hit as correct
    taps, no wrong taps, untapped embers as misses, and only the ember taps
    in reaction_ms (the first touch on each half-circle is trace_start_ms)."""
    rec = {"id": aid, "type": "focus", "started_at": (NOW - timedelta(minutes=5)).isoformat(),
           "duration_s": 90.2, "completed": True, "ended_by": "finished",
           "correct_taps": 6, "wrong_taps": 0, "misses": 1,
           "reaction_ms": [410, 380, 350]}
    if measures is not None:
        rec["revontulet"] = copy.deepcopy(measures)
    rec.update(kw)
    return rec


def post(env, rec):
    return env.client.post("/v1/activities", headers=env.H, json=rec)


def test_a_full_game_is_accepted_and_stored_whole(env):
    r = post(env, game("rv-full-000001"))
    assert r.status_code == 200, r.text
    assert r.json()["type"] == "focus" and r.json()["xp_gained"] > 0
    stored = env.repo().get("activities/rv-full-000001.json")
    assert stored["revontulet"] == MEASURES
    # Read as Revontulet: the error rate is embers missed over embers shown
    # (1 of 4; the three launches cannot go wrong), and its three ember taps are
    # enough for a middle reaction time (revontulet_min_reactions is 2).
    assert stored["features"]["error_rate"] == 0.25
    assert stored["features"]["reactions_used"] == 3
    assert stored["features"]["median_reaction_ms"] == 380.0
    assert stored["features"]["reaction_spread_ms"] is None  # the spread needs four


def test_no_embers_means_no_error_rate_and_sparks_keeps_its_own_rule(env):
    easy = copy.deepcopy(MEASURES)
    easy["rounds"] = [ROUND_EASY, ROUND_EASY, ROUND_EASY]
    assert post(env, game("rv-easy-000001", measures=easy, correct_taps=3, misses=0,
                          reaction_ms=[])).status_code == 200
    f = env.repo().get("activities/rv-easy-000001.json")["features"]
    assert f["error_rate"] is None and f["median_reaction_ms"] is None
    # A Sparks and snow record keeps its own rule: five reaction times, taps over taps.
    assert post(env, game("rv-plain-00001", measures=None)).status_code == 200
    f = env.repo().get("activities/rv-plain-00001.json")["features"]
    assert f["median_reaction_ms"] is None and f["error_rate"] == round(1 / 7, 3)


def test_the_two_focus_games_are_never_compared_with_each_other(env):
    """A real Revontulet game on 14 November, set after Sparks and snow games,
    came out 2.9 away on error rate only because the game had changed."""
    sparks = dict(measures=None, duration_s=45.0, correct_taps=16, wrong_taps=1, misses=1,
                  reaction_ms=[500 + 7 * i for i in range(16)])
    for k in range(6):
        assert post(env, game(f"kind-sparks-{k:04d}", started_at=_days_ago(20 - k), **sparks)).status_code == 200
    assert post(env, game("kind-rv-0000001", started_at=_days_ago(10))).status_code == 200
    first = env.repo().get("activities/kind-rv-0000001.json")
    assert first["baseline_sessions"] == 0 and first["usual"] == {}
    assert all(v is None for v in first["z"].values())
    for k in range(2, 7):
        assert post(env, game(f"kind-rv-{k:07d}", started_at=_days_ago(10 - k))).status_code == 200
    sixth = env.repo().get("activities/kind-rv-0000006.json")
    assert sixth["baseline_sessions"] == 5 and sixth["usual"]["error_rate"]["n"] == 5
    assert sixth["z"]["error_rate"] == 0.0 and sixth["z"]["median_reaction_ms"] == 0.0
    # And the other way: a Sparks game after them sees only the Sparks games.
    assert post(env, game("kind-sparks-last", started_at=_days_ago(1), **sparks)).status_code == 200
    last = env.repo().get("activities/kind-sparks-last.json")
    assert last["baseline_sessions"] == 6 and last["usual"]["median_reaction_ms"]["n"] == 6


def test_leaving_during_the_strokes_after_the_wall_burst_is_not_stopping_early(env):
    """Seven of the nine real games on 14 November ended `user_stopped` with all
    three rounds played and the wall broken."""
    left = game("rv-left-000001", duration_s=56.6, completed=False, ended_by="user_stopped")
    assert post(env, left).status_code == 200
    assert env.repo().get("activities/rv-left-000001.json")["features"]["completed"] is True
    early = copy.deepcopy(MEASURES)
    early.update(rounds=early["rounds"][:1], strokes=[], broke_through_s=None, fox_finished=None)
    gave_up = game("rv-early-00001", measures=early, duration_s=14.0, completed=False,
                   ended_by="user_stopped", correct_taps=1, misses=0, reaction_ms=[])
    assert post(env, gave_up).status_code == 200
    assert env.repo().get("activities/rv-early-00001.json")["features"]["completed"] is False
    d = env.client.get(f"/v1/clinic/patients/{env.demo['patient_id']}", headers=env.C()).json()
    done = {s["id"]: s["completed"] for s in d["activities"]["focus"]["sessions"]}
    assert done["rv-left-000001"] is True and done["rv-early-00001"] is False


def test_a_coached_round_and_a_flick_are_left_out_of_the_four_numbers(env):
    m = copy.deepcopy(MEASURES)
    # The first-time coach showed round one: traced, but no trace_start_ms.
    m["rounds"][0] = {**ROUND_EASY, "trace_start_ms": None, "choice_ms": 9000,
                      "trace_mean_speed_pt_s": 900.0}
    m["strokes"].append({"ms": 121, "length_pt": 149.0, "mean_speed_pt_s": 1233.0})
    assert post(env, game("rv-coach-00001", measures=m)).status_code == 200
    f = env.repo().get("activities/rv-coach-00001.json")["revontulet_features"]
    assert f["choice_ms"] == 940.0 and f["trace_speed_cm_s"] == round(228.9 / 64.2, 3)
    assert f["stroke_speed_cm_s"] == round((282.8 + 229.9 + 211.6) / 3 / 64.2, 3)
    assert f["hard_share"] == round(2 / 3, 3)  # the choice in a coached round still counts


def test_a_games_few_ember_taps_give_a_reaction_time(env):
    """A game has at most six ember taps, so two are enough for the median (the
    other focus game, with about seventeen taps, keeps needing five). The spread
    needs four. An easy-only game sends none and gets none."""
    post(env, game("rv-rt-00000001", reaction_ms=[410, 380]))
    f = env.repo().get("activities/rv-rt-00000001.json")["features"]
    assert f["median_reaction_ms"] == 395.0 and f["reactions_used"] == 2
    assert f["reaction_spread_ms"] is None
    post(env, game("rv-rt-00000002", reaction_ms=[410, 380, 350, 300, 420, 360], correct_taps=9))
    f = env.repo().get("activities/rv-rt-00000002.json")["features"]
    assert f["median_reaction_ms"] == 370.0 and f["reaction_spread_ms"] is not None
    post(env, game("rv-rt-00000003", reaction_ms=[], misses=0, correct_taps=3))
    assert env.repo().get("activities/rv-rt-00000003.json")["features"]["median_reaction_ms"] is None
    # Anticipations (under 120 ms) still do not count.
    post(env, game("rv-rt-00000004", reaction_ms=[80, 410]))
    assert env.repo().get("activities/rv-rt-00000004.json")["features"]["median_reaction_ms"] is None
    # Without the measures the record is the old game: five reactions or nothing.
    post(env, game("rv-rt-00000005", measures=None, reaction_ms=[410, 380, 350]))
    assert env.repo().get("activities/rv-rt-00000005.json")["features"]["median_reaction_ms"] is None


def test_a_record_without_the_measures_means_what_it_always_did(env):
    r = post(env, game("rv-none-000001", measures=None))
    assert r.status_code == 200, r.text
    stored = env.repo().get("activities/rv-none-000001.json")
    assert "revontulet" not in stored
    # null is the same as leaving it out, down to the content hash.
    assert post(env, game("rv-none-000001", measures=None, revontulet=None)).json()[
        "xp_gained"] == 0


def test_optional_fields_may_be_left_out(env):
    slim = {"rounds": [{"effort": "hard", "choice_ms": 1200}], "broke_through_s": None}
    assert post(env, game("rv-slim-000001", measures=slim)).status_code == 200
    rv = env.repo().get("activities/rv-slim-000001.json")["revontulet"]
    assert rv["rounds"][0]["embers_shown"] == 0 and rv["rounds"][0]["bonus"] is False
    assert rv["rounds"][0]["trace_start_ms"] is None
    assert rv["strokes"] == [] and rv["pt_per_cm"] is None and rv["fox_finished"] is None


def test_unknown_fields_are_refused_at_every_level(env):
    for where in ("top", "round", "stroke"):
        m = copy.deepcopy(MEASURES)
        target = {"top": m, "round": m["rounds"][0], "stroke": m["strokes"][0]}[where]
        target["path"] = [1.0, 2.0]
        r = post(env, game(f"rv-unk-{where}-01", measures=m))
        assert r.status_code == 422, where
        assert r.json()["error"]["code"] == "invalid_request"


def test_out_of_range_values_are_refused(env):
    bad = [("rounds", [ROUND_EASY] * 4), ("strokes", MEASURES["strokes"] * 4),
           ("pt_per_cm", 5.0), ("touch_radius_mean_pt", -1.0), ("broke_through_s", 601),
           ("fox_finished", "maybe")]
    for i, (k, v) in enumerate(bad):
        m = {**copy.deepcopy(MEASURES), k: v}
        assert post(env, game(f"rv-range-0000{i}", measures=m)).status_code == 422, k
    m = copy.deepcopy(MEASURES)
    m["rounds"][0].update(effort="medium")
    assert post(env, game("rv-range-effort", measures=m)).status_code == 422
    m = copy.deepcopy(MEASURES)
    m["rounds"][1].update(embers_shown=1, embers_hit=2)
    assert post(env, game("rv-range-embers", measures=m)).status_code == 422
    m = copy.deepcopy(MEASURES)
    m["rounds"][0].update(trace_start_ms=120001)
    assert post(env, game("rv-range-start", measures=m)).status_code == 422
    m = copy.deepcopy(MEASURES)
    m["strokes"][0].update(ms=60001)
    assert post(env, game("rv-range-stroke", measures=m)).status_code == 422


def test_bursting_after_the_game_ended_is_implausible(env):
    m = {**MEASURES, "broke_through_s": 120.0}
    r = post(env, game("rv-late-000001", measures=m))
    assert r.status_code == 422
    assert r.json()["error"]["code"] == "implausible_activity"
    assert "broke_through_after_end" in r.json()["error"]["message"]


def test_only_on_focus(env):
    rec = {"id": "rv-breath-0001", "type": "breathing",
           "started_at": (NOW - timedelta(minutes=5)).isoformat(), "duration_s": 60.0,
           "completed": True, "ended_by": "finished", "time_played_s": 60.0,
           "revontulet": MEASURES}
    assert post(env, rec).status_code == 422


def test_resending_is_safe_and_a_changed_measure_is_a_conflict(env):
    assert post(env, game("rv-again-00001")).json()["xp_gained"] > 0
    assert post(env, game("rv-again-00001")).json()["xp_gained"] == 0
    m = copy.deepcopy(MEASURES)
    m["rounds"][0]["choice_ms"] += 1
    assert post(env, game("rv-again-00001", measures=m)).status_code == 409


def test_the_clinician_sees_the_measures(env):
    assert post(env, game("rv-clin-000001")).status_code == 200
    assert post(env, game("rv-clin-000002", measures=None,
                          started_at=(NOW - timedelta(minutes=3)).isoformat())).status_code == 200
    pid = env.demo["patient_id"]
    detail = env.client.get(f"/v1/clinic/patients/{pid}", headers=env.C())
    assert detail.status_code == 200
    sessions = {s["id"]: s for s in detail.json()["activities"]["focus"]["sessions"]}
    assert sessions["rv-clin-000001"]["revontulet"] == MEASURES
    assert sessions["rv-clin-000002"]["revontulet"] is None
    breathing = detail.json()["activities"]["breathing"]["sessions"]
    assert all("revontulet" not in s for s in breathing)


def test_round_trip_through_the_folder_and_packed_stores(env, tmp_path):
    from clinic_engine.store import DirStore, MemoryStore, PackedStore
    assert post(env, game("rv-store-00001")).status_code == 200
    rec = env.repo().get("activities/rv-store-00001.json")
    key = "clinics/c1/patients/p1/activities/rv-store-00001.json"
    for store in (DirStore(str(tmp_path)), PackedStore(MemoryStore())):
        store.put(key, rec)
        back = store.get(key)
        assert back == rec and back["revontulet"] == MEASURES
        assert [d["id"] for d in store.list_docs("clinics/c1/patients/p1/activities/")] == [
            "rv-store-00001"]


# ---- own normal for Revontulet ------------------------------------------------------------

def _days_ago(n):
    return (NOW - timedelta(days=n, minutes=5)).isoformat()


def test_own_normal_needs_eight_earlier_revontulet_games(env):
    for k in range(8):
        assert post(env, game(f"rv-own-{k:06d}", started_at=_days_ago(12 - k))).status_code == 200
    eighth = env.repo().get("activities/rv-own-000007.json")
    assert eighth["revontulet_features"] == {"hard_share": round(2 / 3, 3), "choice_ms": 940.0,
                                             "trace_speed_cm_s": round((174.8 + 228.9 + 228.9) / 3 / 64.2, 3),
                                             "stroke_speed_cm_s": round((282.8 + 229.9 + 211.6) / 3 / 64.2, 3),
                                             "pt_per_cm": 64.2}
    assert eighth["revontulet_baseline_sessions"] == 7
    assert all(v is None for v in eighth["revontulet_z"].values()) and eighth["revontulet_usual"] == {}
    # The ninth game has eight earlier ones: an all-easy, slow game is far under own normal.
    slow = copy.deepcopy(MEASURES)
    for r in slow["rounds"]:
        r.update(effort="easy", embers_shown=0, embers_hit=0, trace_mean_speed_pt_s=100.0)
    assert post(env, game("rv-own-000008", measures=slow, started_at=_days_ago(1))).status_code == 200
    ninth = env.repo().get("activities/rv-own-000008.json")
    assert ninth["revontulet_usual"]["hard_share"]["n"] == 8
    assert ninth["revontulet_z"]["hard_share"] < -2 and ninth["revontulet_z"]["trace_speed_cm_s"] < -2
    # No fixed start yet: it needs twelve earlier games.
    assert ninth["revontulet_start"] == {} and all(v is None for v in ninth["revontulet_start_z"].values())
    # The day is judged as before: the focus z is untouched by these numbers.
    assert set(ninth["z"]) == {"median_reaction_ms", "reaction_spread_ms", "error_rate"}


def test_the_fixed_start_is_games_three_to_twelve_and_does_not_move(env):
    slow = copy.deepcopy(MEASURES)
    for r in slow["rounds"]:
        r.update(trace_mean_speed_pt_s=100.0)
    for k in range(12):
        assert post(env, game(f"rv-start-{k:05d}", started_at=_days_ago(40 - k))).status_code == 200
    for k in range(12, 34):  # a long slow stretch: the moving range follows it, the start does not
        assert post(env, game(f"rv-start-{k:05d}", measures=slow, started_at=_days_ago(40 - k))).status_code == 200
    last = env.repo().get("activities/rv-start-00033.json")
    assert last["revontulet_start"]["trace_speed_cm_s"]["n"] == 10
    assert abs(last["revontulet_z"]["trace_speed_cm_s"]) < 0.5        # usual among the recent games
    assert last["revontulet_start_z"]["trace_speed_cm_s"] < -2        # far under the start


def test_sparks_games_never_enter_revontulet_normal_and_get_no_such_keys(env):
    for k in range(9):
        assert post(env, game(f"rv-sparks-{k:06d}", measures=None, started_at=_days_ago(10 - k))).status_code == 200
    assert post(env, game("rv-after-sparks-01", started_at=_days_ago(0))).status_code == 200
    plain = env.repo().get("activities/rv-sparks-000008.json")
    assert not [k for k in plain if k.startswith("revontulet")]
    rv = env.repo().get("activities/rv-after-sparks-01.json")
    assert rv["revontulet_baseline_sessions"] == 0 and rv["revontulet_usual"] == {}


def test_speeds_are_none_without_the_phone_size(env):
    m = copy.deepcopy(MEASURES)
    m["pt_per_cm"] = None
    assert post(env, game("rv-nosize-00001", measures=m)).status_code == 200
    f = env.repo().get("activities/rv-nosize-00001.json")["revontulet_features"]
    assert f["trace_speed_cm_s"] is None and f["stroke_speed_cm_s"] is None and f["hard_share"] is not None


def test_a_game_cut_short_has_no_share_of_harder_choices(env):
    m = copy.deepcopy(MEASURES)
    m["rounds"] = [m["rounds"][1]]
    assert post(env, game("rv-short-00001", measures=m)).status_code == 200
    f = env.repo().get("activities/rv-short-00001.json")["revontulet_features"]
    assert f["hard_share"] is None and f["choice_ms"] == 940.0


def test_a_new_phone_starts_both_references_again(env):
    for k in range(13):
        assert post(env, game(f"rv-phone-{k:05d}", started_at=_days_ago(30 - k))).status_code == 200
    old = env.repo().get("activities/rv-phone-00012.json")
    assert old["revontulet_baseline_sessions"] == 12 and old["revontulet_start"]
    other = copy.deepcopy(MEASURES)
    other["pt_per_cm"] = 58.0                       # another phone
    assert post(env, game("rv-phone-00013", measures=other, started_at=_days_ago(2))).status_code == 200
    new = env.repo().get("activities/rv-phone-00013.json")
    assert new["revontulet_baseline_sessions"] == 0
    assert new["revontulet_usual"] == {} and new["revontulet_start"] == {}
    assert all(v is None for v in new["revontulet_z"].values())


def test_the_rules_behave_as_the_page_says_on_generated_games():
    """Guards the numbers the clinician page quotes (docs/revontulet-measures.md).
    Loose bounds: 300 runs, and the point is to notice a rule that got much worse."""
    from clinic_engine.revontulet_check import run
    out = run(runs=300)                       # game-to-game variation as in the first real games
    assert out["unchanged_any_label"] < 0.20
    assert out["unchanged_pooled_label"] < 0.06          # counting gives 2.8% exactly
    assert out["slide_last_three_together_slower"] > 0.80
    # at the end of the slide three games together see more than one game does
    assert out["slide_last_three_together_slower"] > out["slide_last_three_tracing_slower_start"]
    steady = run(runs=300, spread=0.5)
    assert steady["slide_last_three_tracing_slower_start"] > 0.90
